#define _DARWIN_C_SOURCE 1

#include "ssh_forward.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

#define TUNNEL_BUFFER (32u * 1024u)

/* OPENING also covers waiting for a turn to open. CLOSING: the client is
 * gone, and the channel is being closed without blocking. */
typedef enum { TUNNEL_OPENING, TUNNEL_OPEN, TUNNEL_CLOSING } tunnel_state;

typedef struct {
    int fd;               /* -1 once closed */
    LIBSSH2_CHANNEL *channel;
    tunnel_state state;
    size_t forward;
    uint16_t peer_port;
    /* client -> channel */
    uint8_t up[TUNNEL_BUFFER];
    size_t up_length, up_offset;
    int client_eof;
    int eof_sent;
    /* channel -> client */
    uint8_t down[TUNNEL_BUFFER];
    size_t down_length, down_offset;
    int channel_eof;
    int close_started;
} tunnel;

typedef struct {
    int fd;
    uint16_t local_port;
    char *remote_host;
    uint16_t remote_port;
} listener;

struct mr_forwarder {
    LIBSSH2_SESSION *ssh;
    listener *listeners;
    size_t listener_count;
    /* Closing tunnels too: their channels are still on the session. */
    tunnel *tunnels[MR_SSH_MAX_TUNNELS];
    size_t tunnel_count;
    /* The tunnel whose channel open is in flight. libssh2 keeps that state
     * per session, not per call, so channels open one at a time: two opens
     * interleaved could hand one tunnel the channel meant for the other. */
    tunnel *opening;
    int wants_write;
};

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int open_listener(uint16_t port, int *error) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        *error = errno;
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    /* Loopback only: a forward is for this device, never for its network. */
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 8) != 0 ||
        set_nonblocking(fd) != 0) {
        *error = errno;
        close(fd);
        return -1;
    }
    *error = 0;
    return fd;
}

mr_forwarder *mr_forwarder_create(
    LIBSSH2_SESSION *ssh, const mr_ssh_forward *forwards, size_t count,
    void (*report)(void *context, size_t index, int32_t error), void *context) {
    mr_forwarder *forwarder = calloc(1, sizeof *forwarder);
    if (!forwarder) return NULL;
    forwarder->ssh = ssh;
    if (count) {
        forwarder->listeners = calloc(count, sizeof *forwarder->listeners);
        if (!forwarder->listeners) {
            free(forwarder);
            return NULL;
        }
    }
    for (size_t i = 0; i < count; i++) {
        listener *l = &forwarder->listeners[forwarder->listener_count];
        int error = 0;
        l->remote_host = strdup(forwards[i].remote_host);
        l->fd = l->remote_host ? open_listener(forwards[i].local_port, &error) : -1;
        if (!l->remote_host) error = ENOMEM;
        if (report) report(context, i, error);
        if (l->fd < 0) {
            free(l->remote_host);
            l->remote_host = NULL;
            continue;
        }
        l->local_port = forwards[i].local_port;
        l->remote_port = forwards[i].remote_port;
        forwarder->listener_count++;
    }
    return forwarder;
}

size_t mr_forwarder_max_fds(const mr_forwarder *forwarder) {
    return forwarder ? forwarder->listener_count + forwarder->tunnel_count : 0;
}

size_t mr_forwarder_fill_pollfds(mr_forwarder *f, struct pollfd *fds) {
    if (!f) return 0;
    size_t n = 0;
    if (f->tunnel_count < MR_SSH_MAX_TUNNELS) {
        for (size_t i = 0; i < f->listener_count; i++) {
            fds[n].fd = f->listeners[i].fd;
            fds[n].events = POLLIN;
            fds[n].revents = 0;
            n++;
        }
    }
    for (size_t i = 0; i < f->tunnel_count; i++) {
        tunnel *t = f->tunnels[i];
        short events = 0;
        if (t->state == TUNNEL_OPEN && !t->client_eof && t->up_length == 0) events |= POLLIN;
        if (t->state == TUNNEL_OPEN && t->down_length > t->down_offset) events |= POLLOUT;
        /* Not even with no events: a hung-up socket would still report
         * POLLHUP, and poll would never block. */
        if (!events) continue;
        fds[n].fd = t->fd;
        fds[n].events = events;
        fds[n].revents = 0;
        n++;
    }
    return n;
}

/* After an EAGAIN: whether the send is waiting for the socket to drain,
 * rather than for the window or for a reply. */
static void note_blocked(mr_forwarder *f) {
    if (libssh2_session_block_directions(f->ssh) & LIBSSH2_SESSION_BLOCK_OUTBOUND) f->wants_write = 1;
}

/* Drops the client side. A tunnel with a channel stays in the list, closing,
 * until step_tunnel has closed and freed it; returns 1 when the tunnel was
 * removed instead. */
static int retire_tunnel(mr_forwarder *f, size_t index) {
    tunnel *t = f->tunnels[index];
    if (t->fd >= 0) {
        close(t->fd);
        t->fd = -1;
    }
    if (t->channel) {
        t->state = TUNNEL_CLOSING;
        return 0;
    }
    if (f->opening == t) f->opening = NULL;
    free(t);
    f->tunnels[index] = f->tunnels[--f->tunnel_count];
    return 1;
}

static int accept_connections(mr_forwarder *f) {
    int progress = 0;
    for (size_t i = 0; i < f->listener_count; i++) {
        /* At the limit, connections are left in the listen queue. */
        while (f->tunnel_count < MR_SSH_MAX_TUNNELS) {
            struct sockaddr_in peer;
            socklen_t length = sizeof peer;
            int fd = accept(f->listeners[i].fd, (struct sockaddr *)&peer, &length);
            if (fd < 0) break;
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            tunnel *t = calloc(1, sizeof *t);
            if (!t || set_nonblocking(fd) != 0) {
                free(t);
                close(fd);
                break;
            }
            t->fd = fd;
            t->forward = i;
            t->state = TUNNEL_OPENING;
            t->peer_port = ntohs(peer.sin_port);
            f->tunnels[f->tunnel_count++] = t;
            progress = 1;
        }
    }
    return progress;
}

/* Sends what the client sent, then its EOF. Returns 0 when nothing is left
 * to send, 1 while a send waits, or -1 when the channel failed.
 *
 * libssh2 can finish a partly sent packet only when the same call is
 * repeated - it knows the packet by its address, and the EOF packet lives on
 * libssh2_channel_send_eof's stack - and until then refuses every other send
 * on the session. So this is called from one place only, for closing
 * tunnels too, and a tunnel is not closed while it has a send pending. */
static int flush_up(mr_forwarder *f, tunnel *t, int *progress) {
    while (t->up_offset < t->up_length) {
        ssize_t n = libssh2_channel_write(t->channel, (const char *)t->up + t->up_offset,
                                          t->up_length - t->up_offset);
        /* 0: the window is used up. */
        if (n == LIBSSH2_ERROR_EAGAIN || n == 0) {
            note_blocked(f);
            return 1;
        }
        if (n < 0) return -1;
        t->up_offset += (size_t)n;
        *progress = 1;
    }
    t->up_length = t->up_offset = 0;
    if (t->client_eof && !t->eof_sent) {
        int rc = libssh2_channel_send_eof(t->channel);
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            note_blocked(f);
            return 1;
        }
        if (rc != 0) return -1;
        t->eof_sent = 1;
        *progress = 1;
    }
    return 0;
}

/* A closing tunnel: lets a pending send finish, then closes and frees the
 * channel. Returns -1 once it is freed, else 0. */
static int finish_close(mr_forwarder *f, tunnel *t, int pending) {
    /* With the window used up nothing can be half sent - libssh2 builds a
     * packet only within the window and shrinks the window once it is out -
     * so the client's last bytes are dropped rather than waited for. */
    if (pending > 0 &&
        !(t->up_offset < t->up_length && libssh2_channel_window_write(t->channel) == 0)) {
        return 0;
    }
    /* Each step makes the same calls until they stop saying EAGAIN: the
     * close sends EOF and CLOSE, then waits for the server's CLOSE. */
    t->close_started = 1;
    if (libssh2_channel_close(t->channel) == LIBSSH2_ERROR_EAGAIN ||
        libssh2_channel_free(t->channel) == LIBSSH2_ERROR_EAGAIN) {
        note_blocked(f);
        return 0;
    }
    t->channel = NULL;
    return -1;
}

/* Returns 1 on progress, 0 idle, -1 to retire this tunnel, or a negative
 * libssh2 error below -1 that ends the session. */
static int step_tunnel(mr_forwarder *f, tunnel *t) {
    int progress = 0;
    if (t->state == TUNNEL_OPENING) {
        if (f->opening && f->opening != t) return 0;  /* not its turn */
        f->opening = t;
        listener *l = &f->listeners[t->forward];
        t->channel = libssh2_channel_direct_tcpip_ex(
            f->ssh, l->remote_host, l->remote_port, "127.0.0.1", t->peer_port);
        if (!t->channel) {
            int error = libssh2_session_last_errno(f->ssh);
            if (error == LIBSSH2_ERROR_EAGAIN) {
                note_blocked(f);
                return 0;
            }
            f->opening = NULL;
            /* A dead connection ends the session. Anything else - the server
             * refusing (AllowTcpForwarding no) or nothing listening at the
             * destination - fails this connection only. */
            if (error == LIBSSH2_ERROR_SOCKET_SEND || error == LIBSSH2_ERROR_SOCKET_RECV ||
                error == LIBSSH2_ERROR_SOCKET_DISCONNECT) {
                return error;
            }
            return -1;
        }
        f->opening = NULL;
        t->state = TUNNEL_OPEN;
        progress = 1;
    }

    /* Client to channel. */
    if (t->state == TUNNEL_OPEN && t->up_length == 0 && !t->client_eof) {
        ssize_t n = read(t->fd, t->up, sizeof t->up);
        if (n > 0) {
            t->up_length = (size_t)n;
            t->up_offset = 0;
            progress = 1;
        } else if (n == 0) {
            t->client_eof = 1;
            progress = 1;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }
    }
    int pending = t->close_started ? 0 : flush_up(f, t, &progress);
    if (t->state == TUNNEL_CLOSING) return finish_close(f, t, pending);
    if (pending < 0) return -1;

    /* Channel to client. Not read while the client is not taking what it
     * already has: the window then stops the far end. */
    int read_eof = 0;
    if (t->down_offset == t->down_length) {
        t->down_offset = t->down_length = 0;
        ssize_t n = libssh2_channel_read(t->channel, (char *)t->down, sizeof t->down);
        if (n > 0) {
            t->down_length = (size_t)n;
            progress = 1;
        } else if (n == 0) {
            read_eof = 1;
        } else if (n != LIBSSH2_ERROR_EAGAIN) {
            return -1;
        }
    }
    while (t->down_offset < t->down_length) {
        ssize_t n = write(t->fd, t->down + t->down_offset, t->down_length - t->down_offset);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            return -1;
        }
        t->down_offset += (size_t)n;
        progress = 1;
    }
    /* Only once a read said 0, not EAGAIN: a read that would block may have
     * left a window adjustment half sent, which only another read finishes. */
    if (!t->channel_eof && read_eof && libssh2_channel_eof(t->channel)) {
        t->channel_eof = 1;
        shutdown(t->fd, SHUT_WR);
        progress = 1;
    }
    /* Done both ways: the far end's EOF passed on, and everything the client
     * sent forwarded, then its EOF. */
    if (t->channel_eof && t->eof_sent) return -1;
    return progress;
}

int mr_forwarder_step(mr_forwarder *f) {
    if (!f) return 0;
    f->wants_write = 0;
    int progress = accept_connections(f);
    for (size_t i = 0; i < f->tunnel_count;) {
        int rc = step_tunnel(f, f->tunnels[i]);
        if (rc < -1) return rc;
        if (rc == -1) {
            progress = 1;
            if (retire_tunnel(f, i)) continue;
        } else if (rc > 0) {
            progress = 1;
        }
        i++;
    }
    return progress;
}

int mr_forwarder_wants_write(const mr_forwarder *f) { return f ? f->wants_write : 0; }

void mr_forwarder_destroy(mr_forwarder *f) {
    if (!f) return;
    /* The channels are not closed here: a close could start a send nothing
     * would finish. libssh2_session_free frees them with the session. */
    for (size_t i = 0; i < f->tunnel_count; i++) {
        if (f->tunnels[i]->fd >= 0) close(f->tunnels[i]->fd);
        free(f->tunnels[i]);
    }
    for (size_t i = 0; i < f->listener_count; i++) {
        close(f->listeners[i].fd);
        free(f->listeners[i].remote_host);
    }
    free(f->listeners);
    free(f);
}
