#define _DARWIN_C_SOURCE 1

#include "ssh_forward.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

#define TUNNEL_BUFFER (32u * 1024u)
/* A closing tunnel waits this long for the server's CLOSE. Then it is given
 * up on: its slot is freed, and its channel - which libssh2 cannot free
 * without that reply - is left to libssh2_session_free. */
#define CLOSE_TIMEOUT_MS 10000
/* Channels given up on, at most. Each may still hold up to its window of
 * data inside libssh2, so past this closing tunnels keep their slots, and
 * new connections wait. */
#define MAX_ABANDONED 8u
/* A listener whose accept failed for want of resources (descriptors,
 * memory) stays readable; it is left alone this long rather than spun on. */
#define ACCEPT_BACKOFF_MS 1000

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
    int64_t close_deadline;  /* once closing */
} tunnel;

typedef struct {
    int fd;
    uint16_t local_port;
    char *remote_host;
    uint16_t remote_port;
    int64_t retry_at;  /* not accepted from before this (ms); 0 = now */
} listener;

struct mr_forwarder {
    LIBSSH2_SESSION *ssh;
    listener *listeners;
    size_t listener_count;
    /* Closing tunnels too: their channels are still on the session. */
    tunnel *tunnels[MR_SSH_MAX_TUNNELS];
    size_t tunnel_count;
    /* Closing tunnels given up on: their channels stay on the session. */
    size_t abandoned;
    /* The tunnel whose channel open is in flight. libssh2 keeps that state
     * per session, not per call, so channels open one at a time: two opens
     * interleaved could hand one tunnel the channel meant for the other. */
    tunnel *opening;
    int (*congested)(void *context);
    void *context;
};

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Whether another socket listens on the port on all addresses (0.0.0.0, or
 * [::] taking IPv4 too). With SO_REUSEADDR a bind to 127.0.0.1 would still
 * succeed and take that socket's loopback connections; a probe bound to
 * 0.0.0.0, with the same option, fails just then - and not for what the
 * option is there for: our own earlier connections left in TIME_WAIT. */
static int wildcard_taken(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;  /* the real bind will say */
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    int taken = bind(fd, (struct sockaddr *)&address, sizeof address) != 0 && errno == EADDRINUSE;
    close(fd);
    return taken;
}

static int open_listener(uint16_t port, int *error) {
    if (port != 0 && wildcard_taken(port)) {
        *error = EADDRINUSE;
        return -1;
    }
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
    void (*report)(void *context, size_t index, int32_t error),
    int (*congested)(void *context), void *context) {
    mr_forwarder *forwarder = calloc(1, sizeof *forwarder);
    if (!forwarder) return NULL;
    forwarder->ssh = ssh;
    forwarder->congested = congested;
    forwarder->context = context;
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
        int64_t now = now_ms();
        for (size_t i = 0; i < f->listener_count; i++) {
            if (now < f->listeners[i].retry_at) continue;  /* backing off */
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
        if (t->state != TUNNEL_CLOSING) t->close_deadline = now_ms() + CLOSE_TIMEOUT_MS;
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
    int64_t now = now_ms();
    for (size_t i = 0; i < f->listener_count; i++) {
        listener *l = &f->listeners[i];
        if (now < l->retry_at) continue;
        l->retry_at = 0;
        /* At the limit, connections are left in the listen queue. */
        while (f->tunnel_count < MR_SSH_MAX_TUNNELS) {
            struct sockaddr_in peer;
            socklen_t length = sizeof peer;
            int fd = accept(l->fd, (struct sockaddr *)&peer, &length);
            if (fd < 0) {
                /* Out of descriptors or memory, the connection stays queued
                 * and the listener readable. */
                if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR &&
                    errno != ECONNABORTED) {
                    l->retry_at = now + ACCEPT_BACKOFF_MS;
                }
                break;
            }
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            tunnel *t = calloc(1, sizeof *t);
            if (!t || set_nonblocking(fd) != 0) {
                free(t);
                close(fd);
                l->retry_at = now + ACCEPT_BACKOFF_MS;
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
 * to send, 1 while a send waits (for the window, a reply or the session's
 * send queue), or -1 when the channel failed.
 *
 * KEEP THIS THE ONLY CALLER of libssh2_channel_write and
 * libssh2_channel_send_eof for tunnels, and call it from one place only
 * (step_tunnel, for closing tunnels too). A libssh2 send interrupted by
 * EAGAIN must be finished by repeating the same call with the same bytes:
 * libssh2_channel_write keeps the packet it began in the channel, sized by
 * the first call, and libssh2 knows a partly sent packet by its address -
 * the EOF packet's lives on libssh2_channel_send_eof's stack, so even the
 * call path matters. The session's send queue (send_callback in
 * ssh_bridge.c) now keeps libssh2 from holding partly sent packets, but a
 * write begun before a key exchange still waits in the channel. */
static int flush_up(mr_forwarder *f, tunnel *t, int *progress) {
    while (t->up_offset < t->up_length) {
        if (f->congested && f->congested(f->context)) return 1;
        ssize_t n = libssh2_channel_write(t->channel, (const char *)t->up + t->up_offset,
                                          t->up_length - t->up_offset);
        /* 0: the window is used up. */
        if (n == LIBSSH2_ERROR_EAGAIN || n == 0) return 1;
        if (n < 0) return -1;
        t->up_offset += (size_t)n;
        *progress = 1;
    }
    t->up_length = t->up_offset = 0;
    if (t->client_eof && !t->eof_sent) {
        int rc = libssh2_channel_send_eof(t->channel);
        if (rc == LIBSSH2_ERROR_EAGAIN) return 1;
        if (rc != 0) return -1;
        t->eof_sent = 1;
        *progress = 1;
    }
    return 0;
}

/* A closing tunnel: lets a pending send finish, then closes and frees the
 * channel. Returns -1 once it is freed, else 0. */
static int finish_close(tunnel *t, int pending) {
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
            if (error == LIBSSH2_ERROR_EAGAIN) return 0;
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
    /* The one call of flush_up: see there. */
    int pending = t->close_started ? 0 : flush_up(f, t, &progress);
    if (t->state == TUNNEL_CLOSING) return finish_close(t, pending);
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

/* Gives up on a closing tunnel past its deadline, if there is room for one
 * more abandoned channel: the tunnel is freed, the channel left as it is -
 * no further libssh2 call on it, so nothing of it is half done - for
 * libssh2_session_free. Returns 1 when the tunnel was removed. */
static int abandon_if_overdue(mr_forwarder *f, size_t index, int64_t now) {
    tunnel *t = f->tunnels[index];
    if (t->state != TUNNEL_CLOSING || now < t->close_deadline || f->abandoned >= MAX_ABANDONED) return 0;
    f->abandoned++;
    free(t);
    f->tunnels[index] = f->tunnels[--f->tunnel_count];
    return 1;
}

int mr_forwarder_step(mr_forwarder *f) {
    if (!f) return 0;
    int64_t now = now_ms();
    int progress = 0;
    for (size_t i = 0; i < f->tunnel_count;) {
        if (abandon_if_overdue(f, i, now)) {
            progress = 1;
            continue;
        }
        i++;
    }
    progress |= accept_connections(f);
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

int mr_forwarder_timeout_ms(const mr_forwarder *f) {
    if (!f) return -1;
    int64_t earliest = -1;
    /* Past the limit, closing tunnels wait for their CLOSE however long. */
    for (size_t i = 0; i < f->tunnel_count && f->abandoned < MAX_ABANDONED; i++) {
        const tunnel *t = f->tunnels[i];
        if (t->state == TUNNEL_CLOSING && (earliest < 0 || t->close_deadline < earliest)) {
            earliest = t->close_deadline;
        }
    }
    /* A listener backing off, polled again once that is over. */
    for (size_t i = 0; i < f->listener_count && f->tunnel_count < MR_SSH_MAX_TUNNELS; i++) {
        int64_t at = f->listeners[i].retry_at;
        if (at && (earliest < 0 || at < earliest)) earliest = at;
    }
    if (earliest < 0) return -1;
    int64_t left = earliest - now_ms();
    return left <= 0 ? 0 : (int)left;
}

int mr_forwarder_data_waiting(const mr_forwarder *f) {
    if (!f) return 0;
    for (size_t i = 0; i < f->tunnel_count; i++) {
        const tunnel *t = f->tunnels[i];
        /* Only tunnels step_tunnel would read now: one whose client is not
         * taking what it has would count for ever. */
        if (t->state != TUNNEL_OPEN || t->down_offset < t->down_length || t->channel_eof) continue;
        unsigned long queued = 0;
        libssh2_channel_window_read_ex(t->channel, &queued, NULL);
        if (queued > 0 || libssh2_channel_eof(t->channel) == 1) return 1;
    }
    return 0;
}

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
