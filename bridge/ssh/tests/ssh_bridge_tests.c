/*
 * The SSH bridge against a real sshd (run_integration.sh starts it). Each test
 * runs one session on its own thread and plays the app's part from here:
 * answering challenges, writing to the shell, taking output.
 */

#define _DARWIN_C_SOURCE 1

#include "mremote/ssh_bridge.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static int g_failures;
static const char *g_dir;
static const char *g_user;
static uint16_t g_port;

#define CHECK(condition, ...)                                                       \
    do {                                                                            \
        if (!(condition)) {                                                         \
            fprintf(stderr, "  FAIL %s:%d: %s: ", __FILE__, __LINE__, #condition);  \
            fprintf(stderr, __VA_ARGS__);                                           \
            fprintf(stderr, "\n");                                                  \
            g_failures++;                                                           \
        }                                                                           \
    } while (0)

typedef enum { PLAN_KEY, PLAN_REJECT_HOST, PLAN_CANCEL_AUTH, PLAN_STOP_IN_AUTH } plan_kind;

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    mr_ssh_session *session;
    plan_kind plan;
    const char *key_name;      /* first key to offer */
    const char *fallback_key;  /* offered after a rejection, if any */
    const char *passphrase;

    mr_ssh_state last_state;
    mr_ssh_failure failure;
    int32_t detail;
    int connected;
    int ended;
    mr_ssh_host_key_type host_key_type;
    char host_key_name[64];
    uint32_t auth_requests;
    mr_ssh_auth_method last_rejected;
    mr_ssh_auth_method offered;

    int32_t forward_errors[4];
    int forward_reports;

    char *output;
    size_t output_length;
    size_t output_capacity;
    /* Output throttling: take at most this many bytes per call while > 0
     * and refuse all while `blocked`. */
    int blocked;
    size_t refused_calls;
    /* While set, on_output holds the run thread (setting `stalled`). */
    int stall;
    int stalled;
} harness;

static char *read_file(const char *name, size_t *length) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    char *data = malloc((size_t)size + 1);
    if (fread(data, 1, (size_t)size, file) != (size_t)size) {
        fclose(file);
        free(data);
        return NULL;
    }
    fclose(file);
    data[size] = 0;
    *length = (size_t)size;
    return data;
}

static void on_state(void *context, mr_ssh_state state, mr_ssh_failure failure, int32_t detail) {
    harness *h = context;
    pthread_mutex_lock(&h->lock);
    h->last_state = state;
    if (state == MR_SSH_STATE_CONNECTED) h->connected = 1;
    if (state == MR_SSH_STATE_CLOSED || state == MR_SSH_STATE_FAILED) {
        h->ended = 1;
        h->failure = failure;
        h->detail = detail;
    }
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
}

static void on_host_key(void *context, uint64_t id, const mr_ssh_host_key *key) {
    harness *h = context;
    h->host_key_type = key->type;
    snprintf(h->host_key_name, sizeof h->host_key_name, "%s", key->type_name);
    mr_ssh_host_key_decision decision =
        h->plan == PLAN_REJECT_HOST ? MR_SSH_HOST_KEY_REJECT : MR_SSH_HOST_KEY_ACCEPT;
    mr_ssh_status status = mr_ssh_session_answer_host_key(h->session, id, decision);
    CHECK(status == MR_SSH_STATUS_OK, "answer_host_key=%d", status);
    status = mr_ssh_session_answer_host_key(h->session, id, decision);
    CHECK(status == MR_SSH_ERROR_STALE_CHALLENGE, "second answer=%d", status);
}

static void answer_with_key(harness *h, uint64_t id, const char *name) {
    size_t length = 0;
    char *key = read_file(name, &length);
    CHECK(key != NULL, "read %s", name);
    if (!key) return;
    mr_ssh_auth_answer answer = {
        .method = MR_SSH_AUTH_PUBLICKEY,
        .secret = (const uint8_t *)key,
        .secret_length = length,
        .passphrase = (const uint8_t *)h->passphrase,
        .passphrase_length = h->passphrase ? strlen(h->passphrase) : 0,
    };
    mr_ssh_status status = mr_ssh_session_answer_auth(h->session, id, &answer);
    CHECK(status == MR_SSH_STATUS_OK, "answer_auth=%d", status);
    free(key);
}

static void on_auth_request(void *context, uint64_t id, const mr_ssh_auth_request *request) {
    harness *h = context;
    pthread_mutex_lock(&h->lock);
    h->auth_requests++;
    h->last_rejected = request->rejected;
    h->offered = request->offered;
    pthread_mutex_unlock(&h->lock);

    switch (h->plan) {
    case PLAN_CANCEL_AUTH:
        if (request->attempt > 1) {
            mr_ssh_status status = mr_ssh_session_cancel_challenge(h->session, id);
            CHECK(status == MR_SSH_STATUS_OK, "cancel=%d", status);
            return;
        }
        answer_with_key(h, id, h->key_name);
        return;
    case PLAN_STOP_IN_AUTH:
        mr_ssh_session_request_stop(h->session);
        return;
    default:
        answer_with_key(h, id, request->attempt == 1 || !h->fallback_key ? h->key_name : h->fallback_key);
        return;
    }
}

static size_t on_output(void *context, const uint8_t *bytes, size_t length) {
    harness *h = context;
    pthread_mutex_lock(&h->lock);
    while (h->stall) {
        h->stalled = 1;
        pthread_cond_broadcast(&h->cond);
        pthread_cond_wait(&h->cond, &h->lock);
    }
    if (h->blocked) {
        h->refused_calls++;
        pthread_mutex_unlock(&h->lock);
        return 0;
    }
    if (h->output_length + length + 1 > h->output_capacity) {
        size_t capacity = h->output_capacity ? h->output_capacity : 65536;
        while (capacity < h->output_length + length + 1) capacity *= 2;
        h->output = realloc(h->output, capacity);
        h->output_capacity = capacity;
    }
    memcpy(h->output + h->output_length, bytes, length);
    h->output_length += length;
    h->output[h->output_length] = 0;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
    return length;
}

static void on_forward(void *context, size_t index, int32_t error) {
    harness *h = context;
    pthread_mutex_lock(&h->lock);
    if (index < 4) h->forward_errors[index] = error;
    h->forward_reports++;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
}

static void *run_thread(void *argument) {
    harness *h = argument;
    mr_ssh_session_run(h->session);
    return NULL;
}

static void harness_start_with(harness *h, plan_kind plan, const char *key, uint16_t port,
                               const mr_ssh_forward *forwards, size_t forward_count);

static void harness_start(harness *h, plan_kind plan, const char *key, uint16_t port) {
    harness_start_with(h, plan, key, port, NULL, 0);
}

static void harness_start_with(harness *h, plan_kind plan, const char *key, uint16_t port,
                               const mr_ssh_forward *forwards, size_t forward_count) {
    memset(h, 0, sizeof *h);
    pthread_mutex_init(&h->lock, NULL);
    pthread_cond_init(&h->cond, NULL);
    h->plan = plan;
    h->key_name = key;
    mr_ssh_config config = {
        .struct_size = sizeof config,
        .host = "127.0.0.1",
        .port = port,
        .username = g_user,
        .term = "xterm-256color",
        .columns = 80,
        .rows = 24,
        .keepalive_seconds = 5,
        .connect_timeout_ms = 5000,
        .forwards = forwards,
        .forward_count = forward_count,
    };
    mr_ssh_callbacks callbacks = {
        .on_state = on_state,
        .on_host_key = on_host_key,
        .on_auth_request = on_auth_request,
        .on_output = on_output,
        .on_forward = on_forward,
    };
    mr_ssh_status status = mr_ssh_session_create(&config, &callbacks, h, &h->session);
    CHECK(status == MR_SSH_STATUS_OK, "create=%d", status);
}

/* CPU time this process has used, in seconds. */
static double cpu_seconds(void) {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return (double)usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
           (double)usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static void deadline_in(struct timespec *ts, int seconds) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    ts->tv_sec = tv.tv_sec + seconds;
    ts->tv_nsec = (long)tv.tv_usec * 1000;
}

/* Waits for the session to end, or for `needle` to appear in the output. */
static int wait_for(harness *h, const char *needle, int seconds) {
    struct timespec deadline;
    deadline_in(&deadline, seconds);
    pthread_mutex_lock(&h->lock);
    int found = 0;
    for (;;) {
        if (needle && h->output && strstr(h->output, needle)) {
            found = 1;
            break;
        }
        if (!needle && h->ended) {
            found = 1;
            break;
        }
        if (needle && h->ended) break;
        if (pthread_cond_timedwait(&h->cond, &h->lock, &deadline) != 0) break;
    }
    pthread_mutex_unlock(&h->lock);
    return found;
}

static void harness_finish(harness *h, pthread_t thread) {
    pthread_join(thread, NULL);
    mr_ssh_status status = mr_ssh_session_destroy(h->session);
    CHECK(status == MR_SSH_STATUS_OK, "destroy=%d", status);
    free(h->output);
}

static void write_text(harness *h, const char *text) {
    mr_ssh_status status = mr_ssh_session_write(h->session, (const uint8_t *)text, strlen(text));
    CHECK(status == MR_SSH_STATUS_OK, "write=%d", status);
}

/* ---- tests ------------------------------------------------------------- */

static void test_key_signs_in_and_runs_a_command(const char *key, const char *passphrase) {
    printf("key sign-in with %s\n", key);
    harness h;
    harness_start(&h, PLAN_KEY, key, g_port);
    h.passphrase = passphrase;
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);

    CHECK(wait_for(&h, NULL, 0) == 0 || !h.ended, "ended early");
    /* $((6*7)) so the echo of the command itself does not match. */
    write_text(&h, "echo mr-$((6*7))\n");
    CHECK(wait_for(&h, "mr-42", 15), "no command output; state=%u failure=%u detail=%d",
          h.last_state, h.failure, h.detail);
    CHECK(h.connected, "never connected");
    CHECK(h.host_key_type == MR_SSH_HOST_KEY_ED25519, "host key type %u", h.host_key_type);
    CHECK(strcmp(h.host_key_name, "ssh-ed25519") == 0, "host key name %s", h.host_key_name);
    CHECK(h.offered & MR_SSH_AUTH_PUBLICKEY, "publickey not offered (%u)", h.offered);

    write_text(&h, "exit 3\n");
    CHECK(wait_for(&h, NULL, 15), "did not end");
    CHECK(h.last_state == MR_SSH_STATE_CLOSED, "state %u", h.last_state);
    CHECK(h.failure == MR_SSH_FAILURE_NONE, "failure %u", h.failure);
    CHECK(h.detail == 3, "exit status %d", h.detail);
    harness_finish(&h, thread);
}

static void test_a_rejected_key_is_reported_and_another_tried(void) {
    printf("rejected key, then a good one\n");
    harness h;
    harness_start(&h, PLAN_KEY, "user_unknown", g_port);
    h.fallback_key = "user_ed25519";
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "echo mr-$((6*7)); exit\n");
    CHECK(wait_for(&h, "mr-42", 15), "no output; failure=%u", h.failure);
    CHECK(h.auth_requests == 2, "auth requests %u", h.auth_requests);
    CHECK(h.last_rejected == MR_SSH_AUTH_PUBLICKEY, "rejected %u", h.last_rejected);
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
}

static void test_cancelling_the_sign_in_closes_as_cancelled(void) {
    printf("cancel the sign-in\n");
    harness h;
    harness_start(&h, PLAN_CANCEL_AUTH, "user_unknown", g_port);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    CHECK(wait_for(&h, NULL, 15), "did not end");
    CHECK(h.last_state == MR_SSH_STATE_CLOSED, "state %u", h.last_state);
    CHECK(h.failure == MR_SSH_FAILURE_CANCELLED, "failure %u", h.failure);
    CHECK(!h.connected, "connected");
    harness_finish(&h, thread);
}

static void test_a_rejected_host_key_fails_before_sign_in(void) {
    printf("reject the host key\n");
    harness h;
    harness_start(&h, PLAN_REJECT_HOST, "user_ed25519", g_port);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    CHECK(wait_for(&h, NULL, 15), "did not end");
    CHECK(h.last_state == MR_SSH_STATE_FAILED, "state %u", h.last_state);
    CHECK(h.failure == MR_SSH_FAILURE_HOST_KEY_REJECTED, "failure %u", h.failure);
    CHECK(h.auth_requests == 0, "asked to sign in");
    harness_finish(&h, thread);
}

static void test_a_stop_during_a_challenge_ends_the_run(void) {
    printf("stop while a challenge is pending\n");
    harness h;
    harness_start(&h, PLAN_STOP_IN_AUTH, "user_ed25519", g_port);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    CHECK(wait_for(&h, NULL, 15), "did not end");
    CHECK(h.failure == MR_SSH_FAILURE_CANCELLED, "failure %u", h.failure);
    harness_finish(&h, thread);
}

static void test_a_refused_port_is_reported(void) {
    printf("refused connection\n");
    harness h;
    harness_start(&h, PLAN_KEY, "user_ed25519", 1);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    CHECK(wait_for(&h, NULL, 15), "did not end");
    CHECK(h.last_state == MR_SSH_STATE_FAILED, "state %u", h.last_state);
    CHECK(h.failure == MR_SSH_FAILURE_REFUSED, "failure %u detail %d", h.failure, h.detail);
    harness_finish(&h, thread);
}

static void test_a_resize_reaches_the_pty(void) {
    printf("resize\n");
    harness h;
    harness_start(&h, PLAN_KEY, "user_ed25519", g_port);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "echo ready-$((1+1))\n");
    CHECK(wait_for(&h, "ready-2", 15), "not ready");
    mr_ssh_status status = mr_ssh_session_resize(h.session, 132, 43, 0, 0);
    CHECK(status == MR_SSH_STATUS_OK, "resize=%d", status);
    usleep(300 * 1000);
    write_text(&h, "stty size; exit\n");
    CHECK(wait_for(&h, "43 132", 15), "size not applied: %s", h.output ? h.output : "");
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
}

/* Output the caller refuses must wait, not vanish: every byte arrives once
 * reading resumes, however long the pause. */
static void test_refused_output_is_held_not_lost(void) {
    printf("backpressure\n");
    harness h;
    harness_start(&h, PLAN_KEY, "user_ed25519", g_port);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "stty -echo; echo go-$((2+2))\n");
    CHECK(wait_for(&h, "go-4", 15), "not ready");

    pthread_mutex_lock(&h.lock);
    h.blocked = 1;
    size_t before = h.output_length;
    pthread_mutex_unlock(&h.lock);
    const size_t total = 3u * 1024u * 1024u;
    char command[128];
    snprintf(command, sizeof command, "head -c %zu /dev/zero | tr '\\0' a; echo; echo end-$((3+3)); exit\n", total);
    write_text(&h, command);
    sleep(1);
    /* Paused, the run thread must sleep, not spin on a readable socket. */
    double cpu = cpu_seconds();
    sleep(1);
    cpu = cpu_seconds() - cpu;
    CHECK(cpu < 0.3, "%.2f s of CPU in a second while paused", cpu);
    pthread_mutex_lock(&h.lock);
    size_t refused = h.refused_calls;
    h.blocked = 0;
    pthread_mutex_unlock(&h.lock);
    CHECK(refused >= 1, "output was never offered while blocked");
    mr_ssh_session_resume_output(h.session);

    CHECK(wait_for(&h, "end-6", 30), "did not finish; state=%u failure=%u detail=%d tail=%s", h.last_state, h.failure, h.detail,
          h.output_length > 200 ? h.output + h.output_length - 200 : (h.output ? h.output : ""));
    /* The longest run of 'a': a prompt may hold the letter too. */
    size_t count = 0, run = 0;
    pthread_mutex_lock(&h.lock);
    for (size_t i = before; i < h.output_length; i++) {
        run = h.output[i] == 'a' ? run + 1 : 0;
        if (run > count) count = run;
    }
    pthread_mutex_unlock(&h.lock);
    CHECK(count == total, "got %zu of %zu bytes", count, total);
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
}

/* An echo server on 127.0.0.1, standing in for what is behind the SSH
 * server (an RDP host, say). */
typedef struct {
    int listener;
    uint16_t port;
    /* Sent first on each connection when nonzero, to tell servers apart. */
    char tag;
} echo_server;

typedef struct {
    int fd;
    char tag;
} echo_client;

static void *echo_connection(void *argument) {
    echo_client client = *(echo_client *)argument;
    free(argument);
    int fd = client.fd;
    if (client.tag && write(fd, &client.tag, 1) != 1) {
        close(fd);
        return NULL;
    }
    {
        char buffer[16384];
        ssize_t n;
        while ((n = read(fd, buffer, sizeof buffer)) > 0) {
            ssize_t off = 0;
            while (off < n) {
                ssize_t w = write(fd, buffer + off, (size_t)(n - off));
                if (w <= 0) break;
                off += w;
            }
        }
        close(fd);
    }
    return NULL;
}

/* One thread per connection: the forward carries several at once. */
static void *echo_thread(void *argument) {
    echo_server *server = argument;
    for (;;) {
        int fd = accept(server->listener, NULL, NULL);
        if (fd < 0) return NULL;
        echo_client *client = malloc(sizeof *client);
        client->fd = fd;
        client->tag = server->tag;
        pthread_t thread;
        pthread_create(&thread, NULL, echo_connection, client);
        pthread_detach(thread);
    }
}

static uint16_t bound_port(int fd) {
    struct sockaddr_in address;
    socklen_t length = sizeof address;
    getsockname(fd, (struct sockaddr *)&address, &length);
    return ntohs(address.sin_port);
}

static int listen_loopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_len = sizeof address, .sin_family = AF_INET,
                                   .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int connect_loopback(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = { .sin_len = sizeof address, .sin_family = AF_INET,
                                   .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) {
        close(fd);
        return -1;
    }
    struct timeval timeout = { .tv_sec = 10 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    return fd;
}

static void test_a_local_forward_carries_data_both_ways(void) {
    printf("port forward\n");
    echo_server server = { .listener = listen_loopback(0) };
    server.port = bound_port(server.listener);
    pthread_t echo;
    pthread_create(&echo, NULL, echo_thread, &server);

    /* A free port for the forward, and one already taken. */
    int probe = listen_loopback(0);
    uint16_t local = bound_port(probe);
    close(probe);
    int taken = listen_loopback(0);
    uint16_t taken_port = bound_port(taken);

    mr_ssh_forward forwards[2] = {
        { .local_port = local, .remote_host = "127.0.0.1", .remote_port = server.port },
        { .local_port = taken_port, .remote_host = "127.0.0.1", .remote_port = server.port },
    };
    harness h;
    harness_start_with(&h, PLAN_KEY, "user_ed25519", g_port, forwards, 2);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "echo fwd-$((1+2))\n");
    CHECK(wait_for(&h, "fwd-3", 15), "not connected");
    CHECK(h.forward_reports == 2, "forward reports %d", h.forward_reports);
    CHECK(h.forward_errors[0] == 0, "forward 0 error %d", h.forward_errors[0]);
    CHECK(h.forward_errors[1] != 0, "a taken port was reported as listening");

    /* Two connections at once, each with a megabyte through it. */
    const size_t total = 1024u * 1024u;
    for (int round = 0; round < 2; round++) {
        int a = connect_loopback(local);
        int b = connect_loopback(local);
        CHECK(a >= 0 && b >= 0, "connect through the forward");
        if (a < 0 || b < 0) break;
        uint8_t *payload = malloc(total);
        for (size_t i = 0; i < total; i++) payload[i] = (uint8_t)(i * 31 + round);
        uint8_t *echoed = malloc(total);
        int fds[2] = { a, b };
        for (int k = 0; k < 2; k++) {
            size_t sent = 0, received = 0;
            while (received < total) {
                if (sent < total) {
                    size_t chunk = total - sent < 65536 ? total - sent : 65536;
                    ssize_t w = write(fds[k], payload + sent, chunk);
                    if (w > 0) sent += (size_t)w;
                }
                ssize_t r = read(fds[k], echoed + received, total - received);
                if (r <= 0) break;
                received += (size_t)r;
            }
            CHECK(received == total, "echoed %zu of %zu", received, total);
            CHECK(memcmp(payload, echoed, total) == 0, "data changed on the way");
        }
        close(a);
        close(b);
        free(payload);
        free(echoed);
    }

    write_text(&h, "exit\n");
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
    CHECK(connect_loopback(local) < 0, "the forward still listens after the session");
    close(taken);
    shutdown(server.listener, SHUT_RDWR);
    close(server.listener);
    pthread_join(echo, NULL);
}

static uint16_t free_port(void) {
    int probe = listen_loopback(0);
    uint16_t port = bound_port(probe);
    close(probe);
    return port;
}

static void stop_echo_server(echo_server *server, pthread_t thread) {
    shutdown(server->listener, SHUT_RDWR);
    close(server->listener);
    pthread_join(thread, NULL);
}

/* Channels opening at the same time through different forwards each reach
 * their own destination: libssh2 keeps one open in flight per session. */
static void test_concurrent_opens_reach_their_own_destinations(void) {
    printf("concurrent forwards to different destinations\n");
    echo_server x = { .listener = listen_loopback(0), .tag = 'X' };
    echo_server y = { .listener = listen_loopback(0), .tag = 'Y' };
    x.port = bound_port(x.listener);
    y.port = bound_port(y.listener);
    pthread_t x_thread, y_thread;
    pthread_create(&x_thread, NULL, echo_thread, &x);
    pthread_create(&y_thread, NULL, echo_thread, &y);
    uint16_t local_x = free_port(), local_y = free_port();
    mr_ssh_forward forwards[2] = {
        { .local_port = local_x, .remote_host = "127.0.0.1", .remote_port = x.port },
        { .local_port = local_y, .remote_host = "127.0.0.1", .remote_port = y.port },
    };
    harness h;
    harness_start_with(&h, PLAN_KEY, "user_ed25519", g_port, forwards, 2);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "echo pair-$((2+5))\n");
    CHECK(wait_for(&h, "pair-7", 15), "not connected");

    /* Within the listen queues (8 each), all connected before any is read. */
    enum { PAIRS = 8 };
    for (int round = 0; round < 3; round++) {
        int fds[2 * PAIRS];
        for (int i = 0; i < PAIRS; i++) {
            fds[2 * i] = connect_loopback(local_x);
            fds[2 * i + 1] = connect_loopback(local_y);
        }
        int wrong = 0;
        for (int i = 0; i < 2 * PAIRS; i++) {
            char tag = 0;
            if (fds[i] < 0 || read(fds[i], &tag, 1) != 1) {
                CHECK(0, "connection %d got nothing", i);
                continue;
            }
            if (tag != (i % 2 ? 'Y' : 'X')) wrong++;
        }
        CHECK(wrong == 0, "%d connection(s) reached the other destination", wrong);
        for (int i = 0; i < 2 * PAIRS; i++) {
            if (fds[i] >= 0) close(fds[i]);
        }
    }

    write_text(&h, "exit\n");
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
    stop_echo_server(&x, x_thread);
    stop_echo_server(&y, y_thread);
}

/* Past MR_SSH_MAX_TUNNELS, connections wait in the listen queue - not
 * accepted and dropped - and are served once others close. */
static void test_connections_past_the_limit_wait_their_turn(void) {
    printf("connections past the tunnel limit\n");
    echo_server server = { .listener = listen_loopback(0) };
    server.port = bound_port(server.listener);
    pthread_t echo;
    pthread_create(&echo, NULL, echo_thread, &server);
    uint16_t local = free_port();
    mr_ssh_forward forward = { .local_port = local, .remote_host = "127.0.0.1", .remote_port = server.port };
    harness h;
    harness_start_with(&h, PLAN_KEY, "user_ed25519", g_port, &forward, 1);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "echo limit-$((4+4))\n");
    CHECK(wait_for(&h, "limit-8", 15), "not connected");

    /* LIMIT - BURST open one by one, then 2 * BURST at once, so that the
     * limit is reached with connections still queued. */
    enum { LIMIT = MR_SSH_MAX_TUNNELS, BURST = 4, FIRST = LIMIT - BURST, TOTAL = LIMIT + BURST };
    int fds[TOTAL];
    int open_count = 0;
    for (int i = 0; i < FIRST; i++) {
        fds[i] = connect_loopback(local);
        char byte = 'p';
        if (fds[i] < 0 || write(fds[i], &byte, 1) != 1 || read(fds[i], &byte, 1) != 1 || byte != 'p') {
            CHECK(0, "tunnel %d did not echo", i);
            break;
        }
        open_count++;
    }
    CHECK(open_count == FIRST, "%d tunnels open", open_count);
    if (open_count == FIRST) {
        /* The run thread held in on_output while the burst queues up. */
        pthread_mutex_lock(&h.lock);
        h.stall = 1;
        pthread_mutex_unlock(&h.lock);
        write_text(&h, "echo stall\n");
        struct timespec deadline;
        deadline_in(&deadline, 15);
        pthread_mutex_lock(&h.lock);
        while (!h.stalled && pthread_cond_timedwait(&h.cond, &h.lock, &deadline) == 0) {}
        CHECK(h.stalled, "the run thread did not stall");
        pthread_mutex_unlock(&h.lock);
        for (int i = FIRST; i < TOTAL; i++) fds[i] = connect_loopback(local);
        pthread_mutex_lock(&h.lock);
        h.stall = 0;
        pthread_cond_broadcast(&h.cond);
        pthread_mutex_unlock(&h.lock);
        for (int i = FIRST; i < TOTAL; i++) {
            char byte = 'q';
            CHECK(fds[i] >= 0 && write(fds[i], &byte, 1) == 1, "burst connection %d", i);
        }
        usleep(500 * 1000);
        int served = 0, waiting = 0;
        for (int i = FIRST; i < TOTAL; i++) {
            struct pollfd p = { .fd = fds[i], .events = POLLIN, .revents = 0 };
            if (fds[i] < 0 || poll(&p, 1, 0) == 0) {
                waiting++;
                continue;
            }
            char byte = 0;
            CHECK(read(fds[i], &byte, 1) == 1 && byte == 'q', "burst connection %d was dropped", i);
            served++;
            fds[i] = -fds[i] - 2;  /* served: skipped below, closed at the end */
        }
        CHECK(served == BURST && waiting == BURST, "served %d, waiting %d", served, waiting);
        /* Room for the rest. */
        for (int i = 0; i < BURST; i++) close(fds[i]);
        for (int i = FIRST; i < TOTAL; i++) {
            if (fds[i] < -1) continue;
            char byte = 0;
            CHECK(fds[i] >= 0 && read(fds[i], &byte, 1) == 1 && byte == 'q', "connection %d not served", i);
        }
        for (int i = BURST; i < TOTAL; i++) {
            int fd = fds[i] < -1 ? -fds[i] - 2 : fds[i];
            if (fd >= 0) close(fd);
        }
    } else {
        for (int i = 0; i < open_count; i++) close(fds[i]);
    }

    /* The session itself is unharmed. */
    write_text(&h, "echo after-$((5+5)); exit\n");
    CHECK(wait_for(&h, "after-10", 15), "shell gone after the forwards");
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
    stop_echo_server(&server, echo);
}

/* While the shell's output is paused, its data waits but forwards still move:
 * they share the one connection. */
static void test_a_forward_works_while_output_is_paused(void) {
    printf("forward while output is paused\n");
    echo_server server = { .listener = listen_loopback(0) };
    server.port = bound_port(server.listener);
    pthread_t echo;
    pthread_create(&echo, NULL, echo_thread, &server);
    uint16_t local = free_port();
    mr_ssh_forward forward = { .local_port = local, .remote_host = "127.0.0.1", .remote_port = server.port };
    harness h;
    harness_start_with(&h, PLAN_KEY, "user_ed25519", g_port, &forward, 1);
    pthread_t thread;
    pthread_create(&thread, NULL, run_thread, &h);
    write_text(&h, "stty -echo; echo paused-$((3+4))\n");
    CHECK(wait_for(&h, "paused-7", 15), "not connected");

    pthread_mutex_lock(&h.lock);
    h.blocked = 1;
    pthread_mutex_unlock(&h.lock);
    write_text(&h, "head -c 3000000 /dev/zero | tr '\\0' b; echo; echo done-$((4+5))\n");
    sleep(1);

    const size_t total = 256u * 1024u;
    uint8_t *payload = malloc(total), *echoed = malloc(total);
    for (size_t i = 0; i < total; i++) payload[i] = (uint8_t)(i * 7);
    int fd = connect_loopback(local);
    size_t sent = 0, received = 0;
    while (fd >= 0 && received < total) {
        if (sent < total) {
            ssize_t w = write(fd, payload + sent, total - sent < 65536 ? total - sent : 65536);
            if (w > 0) sent += (size_t)w;
        }
        ssize_t r = read(fd, echoed + received, total - received);
        if (r <= 0) break;
        received += (size_t)r;
    }
    CHECK(received == total && memcmp(payload, echoed, total) == 0, "echoed %zu of %zu", received, total);
    if (fd >= 0) close(fd);
    free(payload);
    free(echoed);

    pthread_mutex_lock(&h.lock);
    h.blocked = 0;
    pthread_mutex_unlock(&h.lock);
    mr_ssh_session_resume_output(h.session);
    CHECK(wait_for(&h, "done-9", 30), "shell output lost after the pause");
    write_text(&h, "exit\n");
    wait_for(&h, NULL, 15);
    harness_finish(&h, thread);
    stop_echo_server(&server, echo);
}

static void test_invalid_arguments_are_refused(void) {
    printf("argument checks\n");
    mr_ssh_session *session = NULL;
    mr_ssh_config config = { .struct_size = sizeof config, .host = "h", .port = 22,
                             .username = "u", .columns = 80, .rows = 24 };
    mr_ssh_callbacks callbacks = { .on_state = on_state, .on_host_key = on_host_key,
                                   .on_auth_request = on_auth_request, .on_output = on_output };
    CHECK(mr_ssh_session_create(NULL, &callbacks, NULL, &session) == MR_SSH_ERROR_INVALID_ARGUMENT, "null config");
    mr_ssh_config no_user = config;
    no_user.username = "";
    CHECK(mr_ssh_session_create(&no_user, &callbacks, NULL, &session) == MR_SSH_ERROR_INVALID_ARGUMENT, "empty user");
    mr_ssh_config zero_rows = config;
    zero_rows.rows = 0;
    CHECK(mr_ssh_session_create(&zero_rows, &callbacks, NULL, &session) == MR_SSH_ERROR_INVALID_ARGUMENT, "rows");
    mr_ssh_callbacks missing = callbacks;
    missing.on_output = NULL;
    CHECK(mr_ssh_session_create(&config, &missing, NULL, &session) == MR_SSH_ERROR_INVALID_ARGUMENT, "callbacks");

    CHECK(mr_ssh_session_create(&config, &callbacks, NULL, &session) == MR_SSH_STATUS_OK, "valid");
    CHECK(mr_ssh_session_answer_host_key(session, 1, MR_SSH_HOST_KEY_ACCEPT) == MR_SSH_ERROR_STALE_CHALLENGE, "stale");
    CHECK(mr_ssh_session_resize(session, 0, 10, 0, 0) == MR_SSH_ERROR_INVALID_ARGUMENT, "resize");
    uint8_t *big = calloc(1, MR_SSH_MAX_INPUT_QUEUE_BYTES + 1);
    CHECK(mr_ssh_session_write(session, big, MR_SSH_MAX_INPUT_QUEUE_BYTES + 1) == MR_SSH_ERROR_QUEUE_FULL, "queue");
    free(big);
    mr_ssh_auth_answer nul_password = { .method = MR_SSH_AUTH_PASSWORD,
                                        .secret = (const uint8_t *)"a\0b", .secret_length = 3 };
    CHECK(mr_ssh_session_answer_auth(session, 1, &nul_password) == MR_SSH_ERROR_INVALID_ARGUMENT, "NUL");
    CHECK(mr_ssh_session_destroy(session) == MR_SSH_STATUS_OK, "destroy unstarted");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    g_dir = getenv("MR_SSH_TEST_DIR");
    g_user = getenv("MR_SSH_TEST_USER");
    const char *port = getenv("MR_SSH_TEST_PORT");
    if (!g_dir || !g_user || !port) {
        fprintf(stderr, "run through run_integration.sh\n");
        return 2;
    }
    g_port = (uint16_t)atoi(port);
    /* The tunnel limit test holds a few hundred descriptors: clients, the
     * bridge's tunnels and the echo server's ends. */
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur < 1024) {
        limit.rlim_cur = limit.rlim_max < 1024 ? limit.rlim_max : 1024;
        setrlimit(RLIMIT_NOFILE, &limit);
    }
    CHECK(mr_ssh_bridge_abi_version() == MR_SSH_BRIDGE_ABI_VERSION, "abi");

    test_invalid_arguments_are_refused();
    test_key_signs_in_and_runs_a_command("user_ed25519", NULL);
    test_key_signs_in_and_runs_a_command("user_rsa", NULL);
    test_key_signs_in_and_runs_a_command("user_ecdsa", NULL);
    test_key_signs_in_and_runs_a_command("user_encrypted", "correct horse");
    test_a_rejected_key_is_reported_and_another_tried();
    test_cancelling_the_sign_in_closes_as_cancelled();
    test_a_rejected_host_key_fails_before_sign_in();
    test_a_stop_during_a_challenge_ends_the_run();
    test_a_refused_port_is_reported();
    test_a_resize_reaches_the_pty();
    test_refused_output_is_held_not_lost();
    test_a_local_forward_carries_data_both_ways();
    test_concurrent_opens_reach_their_own_destinations();
    test_connections_past_the_limit_wait_their_turn();
    test_a_forward_works_while_output_is_paused();

    if (g_failures) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
