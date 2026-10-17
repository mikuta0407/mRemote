#define __STDC_WANT_LIB_EXT1__ 1
#define _DARWIN_C_SOURCE 1

#include "mremote/ssh_bridge.h"
#include "ssh_forward.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <libssh2.h>

/* Algorithms, strongest first. Nothing SHA-1 based, no DSA, no CBC: an old
 * server that offers only those fails with MR_SSH_FAILURE_NEGOTIATION rather
 * than being met halfway (docs/ssh-design.md section 6.1). */
static const char kKexPreference[] =
    "mlkem768x25519-sha256,curve25519-sha256,curve25519-sha256@libssh.org,"
    "ecdh-sha2-nistp256,ecdh-sha2-nistp384,ecdh-sha2-nistp521,"
    "diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,"
    "diffie-hellman-group18-sha512,diffie-hellman-group14-sha256";
static const char kHostKeyPreference[] =
    "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,"
    "rsa-sha2-512,rsa-sha2-256";
static const char kCipherPreference[] =
    "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,"
    "aes256-ctr,aes192-ctr,aes128-ctr";
static const char kMacPreference[] =
    "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,"
    "hmac-sha2-256,hmac-sha2-512";
static const char kSignPreference[] =
    "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,"
    "rsa-sha2-512,rsa-sha2-256";

#define READ_CHUNK (32u * 1024u)
#define WRITE_CHUNK (32u * 1024u)
#define MAX_AUTH_ATTEMPTS 8u
#define CLOSE_TIMEOUT_MS 1000

typedef enum {
    CHALLENGE_NONE = 0,
    CHALLENGE_HOST_KEY,
    CHALLENGE_AUTH,
    CHALLENGE_KBD
} challenge_kind;

typedef struct {
    int answered;
    int cancelled;
    mr_ssh_host_key_decision decision;
    mr_ssh_auth_method method;
    uint8_t *secret;
    size_t secret_length;
    uint8_t *passphrase;
    size_t passphrase_length;
    uint8_t **kbd_answers;
    size_t *kbd_lengths;
    size_t kbd_count;
} challenge_answer;

struct mr_ssh_session {
    pthread_mutex_t lock;
    pthread_cond_t cond;

    char *host;
    uint16_t port;
    char *username;
    char *term;
    mr_ssh_forward *forwards;
    size_t forward_count;
    uint32_t keepalive_seconds;
    uint32_t connect_timeout_ms;
    mr_ssh_callbacks callbacks;
    void *context;

    int wake_pipe[2];

    /* Under lock. */
    int stop_requested;
    int run_started;
    int running;
    pthread_t run_thread;
    uint64_t next_challenge_id;
    uint64_t pending_challenge_id;
    challenge_kind pending_kind;
    size_t pending_kbd_count;
    challenge_answer answer;
    uint8_t *input;
    size_t input_length;
    size_t input_capacity;
    int resize_pending;
    uint16_t columns, rows, pixel_width, pixel_height;
    int resume_requested;

    /* Run thread only. */
    int socket_fd;
    LIBSSH2_SESSION *ssh;
    LIBSSH2_CHANNEL *channel;
    uint8_t *held_output;
    size_t held_length;
    size_t held_offset;
    int kbd_cancelled;
    /* The keyboard-interactive call's deadline, restarted after each round
     * the user answers: their think time does not count against it. */
    int64_t kbd_deadline;
};

static pthread_once_t g_libssh2_once = PTHREAD_ONCE_INIT;
static int g_libssh2_ready;

static void libssh2_global_init(void) {
    g_libssh2_ready = libssh2_init(0) == 0;
}

uint32_t mr_ssh_bridge_abi_version(void) { return MR_SSH_BRIDGE_ABI_VERSION; }

/* ---- small helpers ---------------------------------------------------- */

static void wipe(void *bytes, size_t length) {
    if (bytes && length) memset_s(bytes, length, 0, length);
}

static void wipe_free(void *bytes, size_t length) {
    wipe(bytes, length);
    free(bytes);
}

/* libssh2's allocator: what it frees is wiped first. Keyboard-interactive
 * answers are handed to it to free, and its packet buffers hold passwords.
 * Each block keeps its size in a header that preserves malloc's alignment. */
#define ALLOC_HEADER 16u

static LIBSSH2_ALLOC_FUNC(wiping_alloc) {
    (void)abstract;
    if (count > SIZE_MAX - ALLOC_HEADER) return NULL;
    uint8_t *block = malloc(ALLOC_HEADER + count);
    if (!block) return NULL;
    memcpy(block, &count, sizeof count);
    return block + ALLOC_HEADER;
}

static LIBSSH2_FREE_FUNC(wiping_free) {
    (void)abstract;
    if (!ptr) return;
    uint8_t *block = (uint8_t *)ptr - ALLOC_HEADER;
    size_t count;
    memcpy(&count, block, sizeof count);
    wipe_free(block, ALLOC_HEADER + count);
}

static LIBSSH2_REALLOC_FUNC(wiping_realloc) {
    if (!ptr) return wiping_alloc(count, abstract);
    size_t old;
    memcpy(&old, (uint8_t *)ptr - ALLOC_HEADER, sizeof old);
    void *grown = wiping_alloc(count, abstract);
    if (!grown) return NULL;
    memcpy(grown, ptr, old < count ? old : count);
    wiping_free(ptr, abstract);
    return grown;
}

static char *copy_string(const char *source, size_t limit) {
    if (!source) return NULL;
    size_t length = strnlen(source, limit + 1);
    if (length == 0 || length > limit) return NULL;
    char *copy = malloc(length + 1);
    if (copy) memcpy(copy, source, length + 1);
    return copy;
}

static uint8_t *copy_bytes(const uint8_t *source, size_t length) {
    uint8_t *copy = malloc(length ? length : 1);
    if (copy && length) memcpy(copy, source, length);
    return copy;
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void wake(mr_ssh_session *s) {
    const char byte = 1;
    ssize_t ignored = write(s->wake_pipe[1], &byte, 1);
    (void)ignored;
}

static void drain_wake_pipe(mr_ssh_session *s) {
    char buffer[64];
    while (read(s->wake_pipe[0], buffer, sizeof buffer) > 0) {}
}

static int stop_requested(mr_ssh_session *s) {
    pthread_mutex_lock(&s->lock);
    int stop = s->stop_requested;
    pthread_mutex_unlock(&s->lock);
    return stop;
}

static void clear_answer(challenge_answer *answer) {
    wipe_free(answer->secret, answer->secret_length);
    wipe_free(answer->passphrase, answer->passphrase_length);
    if (answer->kbd_answers) {
        for (size_t i = 0; i < answer->kbd_count; i++) {
            wipe_free(answer->kbd_answers[i], answer->kbd_lengths[i]);
        }
    }
    free(answer->kbd_answers);
    free(answer->kbd_lengths);
    memset(answer, 0, sizeof *answer);
}

static void report_state(mr_ssh_session *s, mr_ssh_state state, mr_ssh_failure failure, int32_t detail) {
    if (s->callbacks.on_state) s->callbacks.on_state(s->context, state, failure, detail);
}

/* ---- challenges --------------------------------------------------------- */

static uint64_t open_challenge(mr_ssh_session *s, challenge_kind kind, size_t kbd_count) {
    pthread_mutex_lock(&s->lock);
    clear_answer(&s->answer);
    uint64_t id = ++s->next_challenge_id;
    s->pending_challenge_id = id;
    s->pending_kind = kind;
    s->pending_kbd_count = kbd_count;
    pthread_mutex_unlock(&s->lock);
    return id;
}

/* Waits for the answer to the open challenge. Returns 0 with the answer moved
 * into *out, or -1 when stopped or timed out (the challenge is closed either
 * way, so a late answer is stale). */
static int await_challenge(mr_ssh_session *s, challenge_answer *out) {
    struct timespec deadline;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    deadline.tv_sec = tv.tv_sec + MR_SSH_CHALLENGE_TIMEOUT_MS / 1000;
    deadline.tv_nsec = (long)tv.tv_usec * 1000;

    pthread_mutex_lock(&s->lock);
    int result = 0;
    while (!s->answer.answered && !s->stop_requested) {
        if (pthread_cond_timedwait(&s->cond, &s->lock, &deadline) == ETIMEDOUT) {
            result = -1;
            break;
        }
    }
    if (s->stop_requested) result = -1;
    if (result == 0) {
        *out = s->answer;
        memset(&s->answer, 0, sizeof s->answer);
    } else {
        clear_answer(&s->answer);
    }
    s->pending_challenge_id = 0;
    s->pending_kind = CHALLENGE_NONE;
    pthread_mutex_unlock(&s->lock);
    return result;
}

/* Under lock: the answer slot for challenge_id, or NULL when it is stale. */
static challenge_answer *answer_slot(mr_ssh_session *s, uint64_t challenge_id, challenge_kind kind) {
    if (challenge_id == 0 || challenge_id != s->pending_challenge_id) return NULL;
    if (kind != CHALLENGE_NONE && s->pending_kind != kind) return NULL;
    if (s->answer.answered) return NULL;
    return &s->answer;
}

mr_ssh_status mr_ssh_session_answer_host_key(
    mr_ssh_session *s, uint64_t challenge_id, mr_ssh_host_key_decision decision) {
    if (!s || (decision != MR_SSH_HOST_KEY_ACCEPT && decision != MR_SSH_HOST_KEY_REJECT)) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&s->lock);
    challenge_answer *slot = answer_slot(s, challenge_id, CHALLENGE_HOST_KEY);
    if (!slot) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_STALE_CHALLENGE;
    }
    slot->decision = decision;
    slot->answered = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_answer_auth(
    mr_ssh_session *s, uint64_t challenge_id, const mr_ssh_auth_answer *answer) {
    if (!s || !answer) return MR_SSH_ERROR_INVALID_ARGUMENT;
    switch (answer->method) {
    case 0:
        break;
    case MR_SSH_AUTH_PASSWORD:
    case MR_SSH_AUTH_PUBLICKEY:
        if (!answer->secret || answer->secret_length == 0 ||
            answer->secret_length > MR_SSH_MAX_SECRET_BYTES) {
            return MR_SSH_ERROR_INVALID_ARGUMENT;
        }
        if (answer->passphrase_length > MR_SSH_MAX_PASSPHRASE_BYTES ||
            (answer->passphrase_length && !answer->passphrase)) {
            return MR_SSH_ERROR_INVALID_ARGUMENT;
        }
        break;
    case MR_SSH_AUTH_KEYBOARD_INTERACTIVE:
        break;
    default:
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    /* A password must not carry NULs: libssh2 takes it with a length, but a
     * server that reads it as a C string would see a different password. */
    if (answer->method == MR_SSH_AUTH_PASSWORD &&
        memchr(answer->secret, 0, answer->secret_length)) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }

    uint8_t *secret = NULL, *passphrase = NULL;
    if (answer->secret_length && answer->method != MR_SSH_AUTH_KEYBOARD_INTERACTIVE && answer->method) {
        secret = copy_bytes(answer->secret, answer->secret_length);
        if (!secret) return MR_SSH_ERROR_OUT_OF_MEMORY;
    }
    if (answer->method == MR_SSH_AUTH_PUBLICKEY && answer->passphrase_length) {
        /* NUL-terminated: libssh2 takes the passphrase as a C string. */
        passphrase = malloc(answer->passphrase_length + 1);
        if (!passphrase) {
            wipe_free(secret, answer->secret_length);
            return MR_SSH_ERROR_OUT_OF_MEMORY;
        }
        memcpy(passphrase, answer->passphrase, answer->passphrase_length);
        passphrase[answer->passphrase_length] = 0;
    }

    pthread_mutex_lock(&s->lock);
    challenge_answer *slot = answer_slot(s, challenge_id, CHALLENGE_AUTH);
    if (!slot) {
        pthread_mutex_unlock(&s->lock);
        wipe_free(secret, answer->secret_length);
        wipe_free(passphrase, answer->passphrase_length + 1);
        return MR_SSH_ERROR_STALE_CHALLENGE;
    }
    slot->method = answer->method;
    slot->cancelled = answer->method == 0;
    slot->secret = secret;
    slot->secret_length = secret ? answer->secret_length : 0;
    slot->passphrase = passphrase;
    slot->passphrase_length = passphrase ? answer->passphrase_length + 1 : 0;
    slot->answered = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_answer_keyboard_interactive(
    mr_ssh_session *s, uint64_t challenge_id,
    const uint8_t *const *answers, const size_t *lengths, size_t count) {
    if (!s || count > MR_SSH_MAX_KBD_PROMPTS || (count && (!answers || !lengths))) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    for (size_t i = 0; i < count; i++) {
        if (lengths[i] > MR_SSH_MAX_KBD_ANSWER_BYTES || (lengths[i] && !answers[i])) {
            return MR_SSH_ERROR_INVALID_ARGUMENT;
        }
    }
    uint8_t **copies = count ? calloc(count, sizeof *copies) : NULL;
    size_t *copied_lengths = count ? calloc(count, sizeof *copied_lengths) : NULL;
    if (count && (!copies || !copied_lengths)) {
        free(copies);
        free(copied_lengths);
        return MR_SSH_ERROR_OUT_OF_MEMORY;
    }
    for (size_t i = 0; i < count; i++) {
        copies[i] = copy_bytes(answers[i], lengths[i]);
        copied_lengths[i] = lengths[i];
        if (!copies[i]) {
            for (size_t j = 0; j < i; j++) wipe_free(copies[j], copied_lengths[j]);
            free(copies);
            free(copied_lengths);
            return MR_SSH_ERROR_OUT_OF_MEMORY;
        }
    }

    pthread_mutex_lock(&s->lock);
    challenge_answer *slot = answer_slot(s, challenge_id, CHALLENGE_KBD);
    if (!slot || count != s->pending_kbd_count) {
        mr_ssh_status status = slot ? MR_SSH_ERROR_INVALID_ARGUMENT : MR_SSH_ERROR_STALE_CHALLENGE;
        pthread_mutex_unlock(&s->lock);
        for (size_t i = 0; i < count; i++) wipe_free(copies[i], copied_lengths[i]);
        free(copies);
        free(copied_lengths);
        return status;
    }
    slot->kbd_answers = copies;
    slot->kbd_lengths = copied_lengths;
    slot->kbd_count = count;
    slot->answered = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_cancel_challenge(mr_ssh_session *s, uint64_t challenge_id) {
    if (!s) return MR_SSH_ERROR_INVALID_ARGUMENT;
    pthread_mutex_lock(&s->lock);
    challenge_answer *slot = answer_slot(s, challenge_id, CHALLENGE_NONE);
    if (!slot) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_STALE_CHALLENGE;
    }
    slot->cancelled = 1;
    slot->decision = MR_SSH_HOST_KEY_REJECT;
    slot->method = 0;
    slot->answered = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return MR_SSH_STATUS_OK;
}

/* ---- thread-safe controls ---------------------------------------------- */

mr_ssh_status mr_ssh_session_write(mr_ssh_session *s, const uint8_t *bytes, size_t length) {
    if (!s || (length && !bytes)) return MR_SSH_ERROR_INVALID_ARGUMENT;
    if (length == 0) return MR_SSH_STATUS_OK;
    pthread_mutex_lock(&s->lock);
    if (s->stop_requested) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_STOPPED;
    }
    if (length > MR_SSH_MAX_INPUT_QUEUE_BYTES - s->input_length) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_QUEUE_FULL;
    }
    size_t needed = s->input_length + length;
    if (needed > s->input_capacity) {
        size_t capacity = s->input_capacity ? s->input_capacity : 4096;
        while (capacity < needed) capacity *= 2;
        if (capacity > MR_SSH_MAX_INPUT_QUEUE_BYTES) capacity = MR_SSH_MAX_INPUT_QUEUE_BYTES;
        uint8_t *grown = malloc(capacity);
        if (!grown) {
            pthread_mutex_unlock(&s->lock);
            return MR_SSH_ERROR_OUT_OF_MEMORY;
        }
        /* Not realloc: the old buffer held keystrokes, and is wiped. */
        if (s->input_length) memcpy(grown, s->input, s->input_length);
        wipe_free(s->input, s->input_capacity);
        s->input = grown;
        s->input_capacity = capacity;
    }
    memcpy(s->input + s->input_length, bytes, length);
    s->input_length += length;
    pthread_mutex_unlock(&s->lock);
    wake(s);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_resize(
    mr_ssh_session *s, uint16_t columns, uint16_t rows, uint16_t pixel_width, uint16_t pixel_height) {
    if (!s || columns < MR_SSH_MIN_TERMINAL_DIMENSION || rows < MR_SSH_MIN_TERMINAL_DIMENSION ||
        columns > MR_SSH_MAX_TERMINAL_DIMENSION || rows > MR_SSH_MAX_TERMINAL_DIMENSION) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&s->lock);
    s->columns = columns;
    s->rows = rows;
    s->pixel_width = pixel_width;
    s->pixel_height = pixel_height;
    s->resize_pending = 1;
    pthread_mutex_unlock(&s->lock);
    wake(s);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_resume_output(mr_ssh_session *s) {
    if (!s) return MR_SSH_ERROR_INVALID_ARGUMENT;
    pthread_mutex_lock(&s->lock);
    s->resume_requested = 1;
    pthread_mutex_unlock(&s->lock);
    wake(s);
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_request_stop(mr_ssh_session *s) {
    if (!s) return MR_SSH_ERROR_INVALID_ARGUMENT;
    pthread_mutex_lock(&s->lock);
    s->stop_requested = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    wake(s);
    return MR_SSH_STATUS_OK;
}

/* ---- create / destroy ---------------------------------------------------- */

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* The strings create copied. */
static void free_copies(mr_ssh_session *s) {
    for (size_t i = 0; i < s->forward_count; i++) free((char *)s->forwards[i].remote_host);
    free(s->forwards);
    free(s->host);
    free(s->username);
    free(s->term);
}

mr_ssh_status mr_ssh_session_create(
    const mr_ssh_config *config, const mr_ssh_callbacks *callbacks, void *context,
    mr_ssh_session **out_session) {
    if (!out_session) return MR_SSH_ERROR_INVALID_ARGUMENT;
    *out_session = NULL;
    if (!config || !callbacks || config->struct_size < sizeof(mr_ssh_config)) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    if (!callbacks->on_state || !callbacks->on_host_key || !callbacks->on_auth_request ||
        !callbacks->on_output) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    if (config->forward_count > MR_SSH_MAX_FORWARDS || (config->forward_count && !config->forwards)) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    for (size_t i = 0; i < config->forward_count; i++) {
        const mr_ssh_forward *f = &config->forwards[i];
        if (f->local_port == 0 || f->remote_port == 0 || !f->remote_host ||
            strnlen(f->remote_host, MR_SSH_MAX_HOST_BYTES + 1) == 0 ||
            strnlen(f->remote_host, MR_SSH_MAX_HOST_BYTES + 1) > MR_SSH_MAX_HOST_BYTES) {
            return MR_SSH_ERROR_INVALID_ARGUMENT;
        }
    }
    if (config->port == 0 ||
        config->columns < MR_SSH_MIN_TERMINAL_DIMENSION || config->rows < MR_SSH_MIN_TERMINAL_DIMENSION ||
        config->columns > MR_SSH_MAX_TERMINAL_DIMENSION || config->rows > MR_SSH_MAX_TERMINAL_DIMENSION) {
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    pthread_once(&g_libssh2_once, libssh2_global_init);
    if (!g_libssh2_ready) return MR_SSH_ERROR_INVALID_STATE;

    mr_ssh_session *s = calloc(1, sizeof *s);
    if (!s) return MR_SSH_ERROR_OUT_OF_MEMORY;
    s->socket_fd = -1;
    s->wake_pipe[0] = s->wake_pipe[1] = -1;
    s->host = copy_string(config->host, MR_SSH_MAX_HOST_BYTES);
    s->username = copy_string(config->username, MR_SSH_MAX_USERNAME_BYTES);
    s->term = copy_string(config->term ? config->term : "xterm-256color", MR_SSH_MAX_TERM_BYTES);
    if (!s->host || !s->username || !s->term) {
        free_copies(s);
        free(s);
        return MR_SSH_ERROR_INVALID_ARGUMENT;
    }
    s->port = config->port;
    s->columns = config->columns;
    s->rows = config->rows;
    s->pixel_width = config->pixel_width;
    s->pixel_height = config->pixel_height;
    s->keepalive_seconds = config->keepalive_seconds;
    s->connect_timeout_ms = config->connect_timeout_ms ? config->connect_timeout_ms
                                                       : MR_SSH_DEFAULT_CONNECT_TIMEOUT_MS;
    s->callbacks = *callbacks;
    s->context = context;
    if (config->forward_count) {
        s->forwards = calloc(config->forward_count, sizeof *s->forwards);
        if (!s->forwards) {
            free_copies(s);
            free(s);
            return MR_SSH_ERROR_OUT_OF_MEMORY;
        }
        s->forward_count = config->forward_count;
        for (size_t i = 0; i < config->forward_count; i++) {
            s->forwards[i] = config->forwards[i];
            /* Checked above, so NULL here means out of memory. */
            s->forwards[i].remote_host = copy_string(config->forwards[i].remote_host, MR_SSH_MAX_HOST_BYTES);
            if (!s->forwards[i].remote_host) {
                free_copies(s);
                free(s);
                return MR_SSH_ERROR_OUT_OF_MEMORY;
            }
        }
    }

    if (pipe(s->wake_pipe) != 0 || set_nonblocking(s->wake_pipe[0]) != 0 ||
        set_nonblocking(s->wake_pipe[1]) != 0) {
        if (s->wake_pipe[0] >= 0) close(s->wake_pipe[0]);
        if (s->wake_pipe[1] >= 0) close(s->wake_pipe[1]);
        free_copies(s);
        free(s);
        return MR_SSH_ERROR_OUT_OF_MEMORY;
    }
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);
    *out_session = s;
    return MR_SSH_STATUS_OK;
}

mr_ssh_status mr_ssh_session_destroy(mr_ssh_session *s) {
    if (!s) return MR_SSH_ERROR_INVALID_ARGUMENT;
    pthread_mutex_lock(&s->lock);
    if (s->running && pthread_equal(s->run_thread, pthread_self())) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_INVALID_STATE;
    }
    s->stop_requested = 1;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    wake(s);

    pthread_mutex_lock(&s->lock);
    while (s->running) pthread_cond_wait(&s->cond, &s->lock);
    clear_answer(&s->answer);
    pthread_mutex_unlock(&s->lock);

    wipe_free(s->input, s->input_capacity);
    close(s->wake_pipe[0]);
    close(s->wake_pipe[1]);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->cond);
    free_copies(s);
    free(s);
    return MR_SSH_STATUS_OK;
}

/* ---- the run thread: I/O ------------------------------------------------- */

/* Waits until the socket is ready in the directions libssh2 is blocked on
 * (plus extra_events), or the wake pipe fires, or timeout_ms passes (-1
 * waits for ever). Returns -1 when a stop is requested. */
static int wait_io(mr_ssh_session *s, short extra_events, int timeout_ms, mr_forwarder *forwarder);

static int wait_socket(mr_ssh_session *s, short extra_events, int timeout_ms) {
    return wait_io(s, extra_events, timeout_ms, NULL);
}

/* wait_socket, plus a forwarder's listeners and tunnels. */
static int wait_io(mr_ssh_session *s, short extra_events, int timeout_ms, mr_forwarder *forwarder) {
    struct pollfd fds[2 + MR_SSH_MAX_FORWARDS + MR_SSH_MAX_TUNNELS];
    short events = extra_events;
    if (s->ssh) {
        int directions = libssh2_session_block_directions(s->ssh);
        if (directions & LIBSSH2_SESSION_BLOCK_INBOUND) events |= POLLIN;
        if (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) events |= POLLOUT;
    }
    fds[0].fd = s->socket_fd;
    fds[0].events = events;
    fds[0].revents = 0;
    fds[1].fd = s->wake_pipe[0];
    fds[1].events = POLLIN;
    fds[1].revents = 0;
    nfds_t count = 2 + (nfds_t)mr_forwarder_fill_pollfds(forwarder, fds + 2);
    int rc = poll(fds, count, timeout_ms);
    if (rc > 0 && (fds[1].revents & POLLIN)) drain_wake_pipe(s);
    if (stop_requested(s)) return -1;
    return rc;
}

/* Runs a non-blocking libssh2 call until it stops saying EAGAIN. Breaks out
 * with rc = LIBSSH2_ERROR_EAGAIN on stop or when deadline (ms, 0 = none)
 * passes, which callers treat as cancelled/timed out. */
#define SSH_RETRY(s, rc, deadline, call)                                          \
    do {                                                                          \
        for (;;) {                                                                \
            (rc) = (call);                                                        \
            if ((rc) != LIBSSH2_ERROR_EAGAIN) break;                              \
            int remaining_ = -1;                                                  \
            if ((deadline) != 0) {                                                \
                int64_t left_ = (deadline) - now_ms();                            \
                if (left_ <= 0) break;                                            \
                remaining_ = (int)left_;                                          \
            }                                                                     \
            if (wait_socket((s), 0, remaining_) < 0) break;                       \
        }                                                                         \
    } while (0)

static mr_ssh_failure failure_for_errno(int err) {
    switch (err) {
    case ECONNREFUSED: return MR_SSH_FAILURE_REFUSED;
    case ETIMEDOUT: return MR_SSH_FAILURE_TIMEOUT;
    case ENETUNREACH:
    case EHOSTUNREACH:
    case ENETDOWN:
    case EHOSTDOWN:
    case EADDRNOTAVAIL: return MR_SSH_FAILURE_UNREACHABLE;
    default: return MR_SSH_FAILURE_UNREACHABLE;
    }
}

/* Connects to the first address that answers. Returns 0, or -1 with
 * failure and detail set. */
static int connect_socket(mr_ssh_session *s, mr_ssh_failure *failure, int32_t *detail) {
    char port[8];
    snprintf(port, sizeof port, "%u", (unsigned)s->port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    struct addrinfo *results = NULL;
    /* Blocks, and a stop cannot interrupt it: it is noticed once the
     * resolver returns, which its own timeouts bound. Until then destroy
     * waits too. */
    int gai = getaddrinfo(s->host, port, &hints, &results);
    if (stop_requested(s)) {
        if (results) freeaddrinfo(results);
        *failure = MR_SSH_FAILURE_CANCELLED;
        return -1;
    }
    if (gai != 0 || !results) {
        *failure = MR_SSH_FAILURE_NAME_RESOLUTION;
        *detail = gai;
        return -1;
    }

    int64_t deadline = now_ms() + s->connect_timeout_ms;
    int last_error = ETIMEDOUT;
    for (struct addrinfo *ai = results; ai; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            last_error = errno;
            continue;
        }
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
        if (set_nonblocking(fd) != 0) {
            last_error = errno;
            close(fd);
            continue;
        }
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) {
            s->socket_fd = fd;
            freeaddrinfo(results);
            return 0;
        }
        if (errno != EINPROGRESS) {
            last_error = errno;
            close(fd);
            continue;
        }
        s->socket_fd = fd;
        for (;;) {
            int64_t left = deadline - now_ms();
            if (left <= 0) {
                last_error = ETIMEDOUT;
                break;
            }
            int rc = wait_socket(s, POLLOUT, (int)left);
            if (rc < 0) {
                close(fd);
                s->socket_fd = -1;
                freeaddrinfo(results);
                *failure = MR_SSH_FAILURE_CANCELLED;
                return -1;
            }
            if (rc == 0) continue;
            int err = 0;
            socklen_t len = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
            if (err == 0) {
                /* poll may have returned for the wake pipe alone. */
                struct pollfd check = { .fd = fd, .events = POLLOUT, .revents = 0 };
                if (poll(&check, 1, 0) > 0 && (check.revents & POLLOUT)) {
                    freeaddrinfo(results);
                    return 0;
                }
                continue;
            }
            last_error = err;
            break;
        }
        close(fd);
        s->socket_fd = -1;
        if (now_ms() >= deadline) break;
    }
    freeaddrinfo(results);
    *failure = failure_for_errno(last_error);
    *detail = last_error;
    return -1;
}

static mr_ssh_failure failure_for_libssh2(int rc) {
    switch (rc) {
    case LIBSSH2_ERROR_KEX_FAILURE:
    case LIBSSH2_ERROR_METHOD_NOT_SUPPORTED:
    case LIBSSH2_ERROR_METHOD_NONE:
        return MR_SSH_FAILURE_NEGOTIATION;
    case LIBSSH2_ERROR_TIMEOUT:
        return MR_SSH_FAILURE_TIMEOUT;
    case LIBSSH2_ERROR_SOCKET_DISCONNECT:
    case LIBSSH2_ERROR_SOCKET_RECV:
    case LIBSSH2_ERROR_SOCKET_SEND:
    case LIBSSH2_ERROR_SOCKET_TIMEOUT:
        return MR_SSH_FAILURE_DISCONNECTED;
    case LIBSSH2_ERROR_ALLOC:
        return MR_SSH_FAILURE_INTERNAL;
    default:
        return MR_SSH_FAILURE_PROTOCOL;
    }
}

static mr_ssh_host_key_type host_key_type(int libssh2_type) {
    switch (libssh2_type) {
    case LIBSSH2_HOSTKEY_TYPE_RSA: return MR_SSH_HOST_KEY_RSA;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return MR_SSH_HOST_KEY_ECDSA_256;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return MR_SSH_HOST_KEY_ECDSA_384;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return MR_SSH_HOST_KEY_ECDSA_521;
    case LIBSSH2_HOSTKEY_TYPE_ED25519: return MR_SSH_HOST_KEY_ED25519;
    default: return MR_SSH_HOST_KEY_UNKNOWN;
    }
}

static const char *host_key_name(mr_ssh_host_key_type type) {
    switch (type) {
    case MR_SSH_HOST_KEY_RSA: return "ssh-rsa";
    case MR_SSH_HOST_KEY_ECDSA_256: return "ecdsa-sha2-nistp256";
    case MR_SSH_HOST_KEY_ECDSA_384: return "ecdsa-sha2-nistp384";
    case MR_SSH_HOST_KEY_ECDSA_521: return "ecdsa-sha2-nistp521";
    case MR_SSH_HOST_KEY_ED25519: return "ssh-ed25519";
    default: return "unknown";
    }
}

static int set_preferences(LIBSSH2_SESSION *ssh) {
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_KEX, kKexPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_HOSTKEY, kHostKeyPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_CRYPT_CS, kCipherPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_CRYPT_SC, kCipherPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_MAC_CS, kMacPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_MAC_SC, kMacPreference) != 0) return -1;
    if (libssh2_session_method_pref(ssh, LIBSSH2_METHOD_SIGN_ALGO, kSignPreference) != 0) return -1;
    return 0;
}

/* ---- the run thread: authentication ------------------------------------ */

static mr_ssh_auth_method parse_methods(const char *list) {
    mr_ssh_auth_method methods = 0;
    if (!list) return 0;
    const char *p = list;
    while (*p) {
        const char *end = strchr(p, ',');
        size_t length = end ? (size_t)(end - p) : strlen(p);
        if (length == 9 && strncmp(p, "publickey", 9) == 0) methods |= MR_SSH_AUTH_PUBLICKEY;
        else if (length == 8 && strncmp(p, "password", 8) == 0) methods |= MR_SSH_AUTH_PASSWORD;
        else if (length == 20 && strncmp(p, "keyboard-interactive", 20) == 0) {
            methods |= MR_SSH_AUTH_KEYBOARD_INTERACTIVE;
        }
        if (!end) break;
        p = end + 1;
    }
    return methods;
}


static int64_t step_deadline(void) { return now_ms() + MR_SSH_CHALLENGE_TIMEOUT_MS; }

/* libssh2 calls this from inside libssh2_userauth_keyboard_interactive_ex, on
 * the run thread, once per round of prompts. It blocks on the user. The
 * responses' text must come from the session allocator, wiping_alloc, which
 * libssh2 frees it with - wiped. */
static LIBSSH2_USERAUTH_KBDINT_RESPONSE_FUNC(kbd_callback) {
    mr_ssh_session *s = *abstract;
    size_t count = num_prompts > 0 ? (size_t)num_prompts : 0;
    if (s->kbd_cancelled || count > MR_SSH_MAX_KBD_PROMPTS || !s->callbacks.on_keyboard_interactive) {
        s->kbd_cancelled = 1;
        return;
    }
    mr_ssh_kbd_prompt list[MR_SSH_MAX_KBD_PROMPTS];
    for (size_t i = 0; i < count; i++) {
        list[i].text = prompts[i].text;
        list[i].length = prompts[i].length;
        list[i].echo = prompts[i].echo ? 1 : 0;
    }
    mr_ssh_kbd_request request = {
        .name = (const uint8_t *)name,
        .name_length = name_len > 0 ? (size_t)name_len : 0,
        .instruction = (const uint8_t *)instruction,
        .instruction_length = instruction_len > 0 ? (size_t)instruction_len : 0,
        .prompts = list,
        .prompt_count = count,
    };
    uint64_t id = open_challenge(s, CHALLENGE_KBD, count);
    s->callbacks.on_keyboard_interactive(s->context, id, &request);
    challenge_answer answer;
    memset(&answer, 0, sizeof answer);
    if (await_challenge(s, &answer) != 0 || answer.cancelled) {
        s->kbd_cancelled = 1;
        clear_answer(&answer);
        return;
    }
    s->kbd_deadline = step_deadline();
    for (size_t i = 0; i < count && i < answer.kbd_count; i++) {
        char *text = wiping_alloc(answer.kbd_lengths[i] ? answer.kbd_lengths[i] : 1, abstract);
        if (!text) break;
        if (answer.kbd_lengths[i]) memcpy(text, answer.kbd_answers[i], answer.kbd_lengths[i]);
        responses[i].text = text;
        responses[i].length = (unsigned int)answer.kbd_lengths[i];
    }
    clear_answer(&answer);
}

/* Returns 0 once signed in, or -1 with failure and detail set. */
static int authenticate(mr_ssh_session *s, mr_ssh_failure *failure, int32_t *detail) {
    unsigned int username_length = (unsigned int)strlen(s->username);
    const char *list = NULL;
    int64_t deadline = step_deadline();
    for (;;) {
        list = libssh2_userauth_list(s->ssh, s->username, username_length);
        if (list || libssh2_session_last_errno(s->ssh) != LIBSSH2_ERROR_EAGAIN) break;
        int64_t left = deadline - now_ms();
        if (left <= 0 || wait_socket(s, 0, (int)left) < 0) break;
    }
    if (!list) {
        if (libssh2_userauth_authenticated(s->ssh)) return 0;  /* "none" was enough */
        if (stop_requested(s)) {
            *failure = MR_SSH_FAILURE_CANCELLED;
        } else {
            int rc = libssh2_session_last_errno(s->ssh);
            *failure = rc == LIBSSH2_ERROR_EAGAIN ? MR_SSH_FAILURE_TIMEOUT : failure_for_libssh2(rc);
            *detail = rc;
        }
        return -1;
    }
    mr_ssh_auth_method offered = parse_methods(list);
    if (!offered) {
        *failure = MR_SSH_FAILURE_AUTHENTICATION;
        return -1;
    }

    mr_ssh_auth_method rejected = 0;
    for (uint32_t attempt = 1; attempt <= MAX_AUTH_ATTEMPTS; attempt++) {
        mr_ssh_auth_request request = { .offered = offered, .attempt = attempt, .rejected = rejected };
        uint64_t id = open_challenge(s, CHALLENGE_AUTH, 0);
        s->callbacks.on_auth_request(s->context, id, &request);
        challenge_answer answer;
        if (await_challenge(s, &answer) != 0) {
            *failure = stop_requested(s) ? MR_SSH_FAILURE_CANCELLED : MR_SSH_FAILURE_TIMEOUT;
            return -1;
        }
        if (answer.cancelled || answer.method == 0 || !(answer.method & offered)) {
            clear_answer(&answer);
            *failure = MR_SSH_FAILURE_CANCELLED;
            return -1;
        }

        int rc = 0;
        deadline = step_deadline();
        switch (answer.method) {
        case MR_SSH_AUTH_PASSWORD:
            SSH_RETRY(s, rc, deadline,
                      libssh2_userauth_password_ex(s->ssh, s->username, username_length,
                                                   (const char *)answer.secret,
                                                   (unsigned int)answer.secret_length, NULL));
            break;
        case MR_SSH_AUTH_PUBLICKEY:
            SSH_RETRY(s, rc, deadline,
                      libssh2_userauth_publickey_frommemory(
                          s->ssh, s->username, username_length, NULL, 0,
                          (const char *)answer.secret, answer.secret_length,
                          answer.passphrase ? (const char *)answer.passphrase : NULL));
            break;
        case MR_SSH_AUTH_KEYBOARD_INTERACTIVE:
            s->kbd_cancelled = 0;
            s->kbd_deadline = deadline;
            SSH_RETRY(s, rc, s->kbd_deadline,
                      libssh2_userauth_keyboard_interactive_ex(s->ssh, s->username, username_length,
                                                              kbd_callback));
            break;
        default:
            rc = LIBSSH2_ERROR_METHOD_NOT_SUPPORTED;
            break;
        }
        mr_ssh_auth_method used = answer.method;
        clear_answer(&answer);

        if (rc == 0 && libssh2_userauth_authenticated(s->ssh)) return 0;
        if (stop_requested(s) || (used == MR_SSH_AUTH_KEYBOARD_INTERACTIVE && s->kbd_cancelled)) {
            *failure = MR_SSH_FAILURE_CANCELLED;
            return -1;
        }
        switch (rc) {
        case LIBSSH2_ERROR_AUTHENTICATION_FAILED:
        case LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED:
        case LIBSSH2_ERROR_PASSWORD_EXPIRED:
        case LIBSSH2_ERROR_FILE:          /* a key libssh2 could not read */
        case LIBSSH2_ERROR_METHOD_NOT_SUPPORTED:
            rejected = used;
            continue;
        case LIBSSH2_ERROR_EAGAIN:
            *failure = MR_SSH_FAILURE_TIMEOUT;
            return -1;
        default:
            *failure = failure_for_libssh2(rc);
            *detail = rc;
            return -1;
        }
    }
    *failure = MR_SSH_FAILURE_AUTHENTICATION;
    return -1;
}

/* ---- the run thread: the shell ----------------------------------------- */

static int open_shell(mr_ssh_session *s, mr_ssh_failure *failure, int32_t *detail) {
    int64_t deadline = step_deadline();
    for (;;) {
        s->channel = libssh2_channel_open_session(s->ssh);
        if (s->channel || libssh2_session_last_errno(s->ssh) != LIBSSH2_ERROR_EAGAIN) break;
        int64_t left = deadline - now_ms();
        if (left <= 0 || wait_socket(s, 0, (int)left) < 0) break;
    }
    if (!s->channel) {
        *failure = stop_requested(s) ? MR_SSH_FAILURE_CANCELLED : MR_SSH_FAILURE_CHANNEL;
        *detail = libssh2_session_last_errno(s->ssh);
        return -1;
    }
    int rc;
    SSH_RETRY(s, rc, deadline, libssh2_channel_handle_extended_data2(s->channel, LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE));

    pthread_mutex_lock(&s->lock);
    uint16_t columns = s->columns, rows = s->rows, pw = s->pixel_width, ph = s->pixel_height;
    s->resize_pending = 0;
    pthread_mutex_unlock(&s->lock);

    SSH_RETRY(s, rc, deadline,
              libssh2_channel_request_pty_ex(s->channel, s->term, (unsigned int)strlen(s->term),
                                             NULL, 0, columns, rows, pw, ph));
    if (rc == 0) SSH_RETRY(s, rc, deadline, libssh2_channel_shell(s->channel));
    if (rc != 0) {
        *failure = stop_requested(s) ? MR_SSH_FAILURE_CANCELLED : MR_SSH_FAILURE_CHANNEL;
        *detail = rc;
        return -1;
    }
    return 0;
}

static void report_forward(void *context, size_t index, int32_t error) {
    mr_ssh_session *s = context;
    if (s->callbacks.on_forward) s->callbacks.on_forward(s->context, index, error);
}

/* Hands held output to the caller. Returns 1 when all of it was taken. */
static int deliver_held(mr_ssh_session *s) {
    while (s->held_offset < s->held_length) {
        size_t remaining = s->held_length - s->held_offset;
        size_t taken = s->callbacks.on_output(s->context, s->held_output + s->held_offset, remaining);
        if (taken > remaining) taken = remaining;
        if (taken == 0) return 0;
        s->held_offset += taken;
    }
    s->held_offset = s->held_length = 0;
    return 1;
}

/* The connected loop. Returns when the shell ends, the connection drops, or a
 * stop is requested; reports the final state itself. */
static void run_shell(mr_ssh_session *s) {
    uint8_t *buffer = malloc(READ_CHUNK);
    s->held_output = malloc(READ_CHUNK);
    if (!buffer || !s->held_output) {
        free(buffer);
        free(s->held_output);
        s->held_output = NULL;
        report_state(s, MR_SSH_STATE_FAILED, MR_SSH_FAILURE_INTERNAL, 0);
        return;
    }
    if (s->keepalive_seconds) libssh2_keepalive_config(s->ssh, 1, s->keepalive_seconds);
    mr_forwarder *forwarder = NULL;
    if (s->forward_count) {
        forwarder = mr_forwarder_create(s->ssh, s->forwards, s->forward_count, report_forward, s);
        /* Out of memory: the shell goes on without them. */
        if (!forwarder) {
            for (size_t i = 0; i < s->forward_count; i++) report_forward(s, i, ENOMEM);
        }
    }

    int paused = 0;
    for (;;) {
        if (stop_requested(s)) {
            report_state(s, MR_SSH_STATE_CLOSED, MR_SSH_FAILURE_CANCELLED, -1);
            break;
        }

        /* The caller made room. */
        pthread_mutex_lock(&s->lock);
        int resume = s->resume_requested;
        s->resume_requested = 0;
        int resize = s->resize_pending;
        uint16_t columns = s->columns, rows = s->rows, pw = s->pixel_width, ph = s->pixel_height;
        pthread_mutex_unlock(&s->lock);
        if (paused && resume && deliver_held(s)) paused = 0;

        /* A send that would block waits on the socket's POLLOUT only when it
         * is the socket it waits for, as libssh2 says right after the EAGAIN:
         * a write whose window is used up waits for inbound data, and polling
         * POLLOUT on a writable socket would spin. Saying it later is not
         * enough, since later calls overwrite those directions. */
        int fatal = 0;
        int resize_blocked = 0;
        int want_pollout = 0;
        if (resize) {
            int rc = libssh2_channel_request_pty_size_ex(s->channel, columns, rows, pw, ph);
            resize_blocked = rc == LIBSSH2_ERROR_EAGAIN;
            if (resize_blocked) {
                if (libssh2_session_block_directions(s->ssh) & LIBSSH2_SESSION_BLOCK_OUTBOUND) want_pollout = 1;
            } else {
                pthread_mutex_lock(&s->lock);
                /* Only if no newer size came in meanwhile. */
                if (s->columns == columns && s->rows == rows && s->pixel_width == pw &&
                    s->pixel_height == ph) {
                    s->resize_pending = 0;
                }
                pthread_mutex_unlock(&s->lock);
            }
        }

        /* Input. */
        int want_write = 0;
        for (;;) {
            uint8_t chunk[WRITE_CHUNK];
            pthread_mutex_lock(&s->lock);
            size_t length = s->input_length < WRITE_CHUNK ? s->input_length : WRITE_CHUNK;
            if (length) memcpy(chunk, s->input, length);
            pthread_mutex_unlock(&s->lock);
            if (!length) break;
            ssize_t n = libssh2_channel_write_ex(s->channel, 0, (const char *)chunk, length);
            wipe(chunk, length);
            /* 0: the window is used up. */
            if (n == LIBSSH2_ERROR_EAGAIN || n == 0) {
                want_write = 1;
                if (libssh2_session_block_directions(s->ssh) & LIBSSH2_SESSION_BLOCK_OUTBOUND) want_pollout = 1;
                break;
            }
            if (n < 0) {
                report_state(s, MR_SSH_STATE_FAILED, failure_for_libssh2((int)n), (int32_t)n);
                fatal = 1;
                break;
            }
            pthread_mutex_lock(&s->lock);
            memmove(s->input, s->input + n, s->input_length - (size_t)n);
            s->input_length -= (size_t)n;
            pthread_mutex_unlock(&s->lock);
        }
        if (fatal) break;

        /* Output. While paused nothing is read: libssh2 stops adjusting the
         * window, and the server stops sending once it is used up. */
        while (!paused) {
            ssize_t n = libssh2_channel_read_ex(s->channel, 0, (char *)buffer, READ_CHUNK);
            if (n == LIBSSH2_ERROR_EAGAIN || n == 0) break;
            if (n < 0) {
                report_state(s, MR_SSH_STATE_FAILED, failure_for_libssh2((int)n), (int32_t)n);
                fatal = 1;
                break;
            }
            memcpy(s->held_output, buffer, (size_t)n);
            s->held_length = (size_t)n;
            s->held_offset = 0;
            if (!deliver_held(s)) paused = 1;
        }
        /* While paused the transport is still read, without taking the
         * shell's data: a read of 0 bytes. Forwards and keepalive replies
         * keep moving, a hang-up is noticed, and the socket does not stay
         * readable, which would make poll spin. What arrives for the shell
         * queues inside libssh2, bounded by the window, which grows back
         * only by what the caller has taken. */
        if (paused && !fatal) {
            ssize_t n = libssh2_channel_read_ex(s->channel, 0, (char *)buffer, 0);
            if (n < 0 && n != LIBSSH2_ERROR_EAGAIN) {
                report_state(s, MR_SSH_STATE_FAILED, failure_for_libssh2((int)n), (int32_t)n);
                fatal = 1;
            }
        }
        if (fatal) break;

        /* Forwards. Their reads can pull the shell's packets in too, so any
         * progress loops round before polling again. */
        int forwarded = mr_forwarder_step(forwarder);
        if (forwarded < 0) {
            report_state(s, MR_SSH_STATE_FAILED, failure_for_libssh2(forwarded), forwarded);
            break;
        }

        if (!paused && libssh2_channel_eof(s->channel)) {
            int exit_status = -1;
            int rc;
            int64_t deadline = now_ms() + CLOSE_TIMEOUT_MS;
            SSH_RETRY(s, rc, deadline, libssh2_channel_close(s->channel));
            if (rc == 0) {
                SSH_RETRY(s, rc, deadline, libssh2_channel_wait_closed(s->channel));
                exit_status = libssh2_channel_get_exit_status(s->channel);
            }
            report_state(s, MR_SSH_STATE_CLOSED, MR_SSH_FAILURE_NONE, exit_status);
            break;
        }

        int timeout_ms = -1;
        if (s->keepalive_seconds) {
            int next = 0;
            int rc = libssh2_keepalive_send(s->ssh, &next);
            if (rc != 0 && rc != LIBSSH2_ERROR_EAGAIN) {
                report_state(s, MR_SSH_STATE_FAILED, failure_for_libssh2(rc), rc);
                break;
            }
            timeout_ms = next > 0 ? next * 1000 : 1000;
        }
        pthread_mutex_lock(&s->lock);
        int more = (s->resize_pending && !resize_blocked) || (s->input_length && !want_write) || (paused && s->resume_requested);
        pthread_mutex_unlock(&s->lock);
        if (more || forwarded > 0) continue;

        /* Always readable: paused or not, the loop reads whatever arrives. */
        short extra = POLLIN;
        if (want_pollout || mr_forwarder_wants_write(forwarder)) extra |= POLLOUT;
        if (wait_io(s, extra, timeout_ms, forwarder) < 0) continue;  /* the loop reports the stop */
    }
    mr_forwarder_destroy(forwarder);
    wipe_free(buffer, READ_CHUNK);
    wipe_free(s->held_output, READ_CHUNK);
    s->held_output = NULL;
}

static void close_connection(mr_ssh_session *s) {
    if (s->ssh) {
        int64_t deadline = now_ms() + CLOSE_TIMEOUT_MS;
        int rc;
        /* Best effort and bounded: the server may already be gone. A stop
         * request must not make this spin, so wait directly. */
        for (;;) {
            rc = libssh2_session_disconnect_ex(s->ssh, SSH_DISCONNECT_BY_APPLICATION, "closed", "");
            if (rc != LIBSSH2_ERROR_EAGAIN) break;
            int64_t left = deadline - now_ms();
            if (left <= 0) break;
            struct pollfd fd = { .fd = s->socket_fd, .events = POLLOUT, .revents = 0 };
            poll(&fd, 1, (int)left);
        }
        /* With the socket shut, closing a channel still open - the shell
         * after a stop, a forward - fails at once instead of waiting for the
         * server, so the frees below finish: in non-blocking mode an EAGAIN
         * from libssh2_session_free would leak the session. */
        if (s->socket_fd >= 0) shutdown(s->socket_fd, SHUT_RDWR);
        if (s->channel) {
            libssh2_channel_free(s->channel);
            s->channel = NULL;
        }
        libssh2_session_free(s->ssh);
        s->ssh = NULL;
    }
    if (s->socket_fd >= 0) {
        close(s->socket_fd);
        s->socket_fd = -1;
    }
}

mr_ssh_status mr_ssh_session_run(mr_ssh_session *s) {
    if (!s) return MR_SSH_ERROR_INVALID_ARGUMENT;
    pthread_mutex_lock(&s->lock);
    if (s->run_started) {
        pthread_mutex_unlock(&s->lock);
        return MR_SSH_ERROR_INVALID_STATE;
    }
    s->run_started = 1;
    s->running = 1;
    s->run_thread = pthread_self();
    pthread_mutex_unlock(&s->lock);

    mr_ssh_failure failure = MR_SSH_FAILURE_NONE;
    int32_t detail = 0;
    report_state(s, MR_SSH_STATE_CONNECTING, MR_SSH_FAILURE_NONE, 0);

    if (stop_requested(s)) {
        failure = MR_SSH_FAILURE_CANCELLED;
        goto failed;
    }
    if (connect_socket(s, &failure, &detail) != 0) goto failed;

    s->ssh = libssh2_session_init_ex(wiping_alloc, wiping_free, wiping_realloc, s);
    if (!s->ssh || set_preferences(s->ssh) != 0) {
        failure = MR_SSH_FAILURE_INTERNAL;
        goto failed;
    }
    libssh2_session_set_blocking(s->ssh, 0);

    {
        int rc;
        int64_t deadline = now_ms() + s->connect_timeout_ms;
        SSH_RETRY(s, rc, deadline, libssh2_session_handshake(s->ssh, s->socket_fd));
        if (rc != 0) {
            if (stop_requested(s)) failure = MR_SSH_FAILURE_CANCELLED;
            else if (rc == LIBSSH2_ERROR_EAGAIN) failure = MR_SSH_FAILURE_TIMEOUT;
            else failure = failure_for_libssh2(rc);
            detail = rc;
            goto failed;
        }
    }

    {
        size_t length = 0;
        int type = 0;
        const char *blob = libssh2_session_hostkey(s->ssh, &length, &type);
        mr_ssh_host_key_type key_type = host_key_type(type);
        if (!blob || length == 0 || key_type == MR_SSH_HOST_KEY_UNKNOWN) {
            failure = MR_SSH_FAILURE_NEGOTIATION;
            goto failed;
        }
        mr_ssh_host_key key = {
            .type = key_type,
            .type_name = host_key_name(key_type),
            .blob = (const uint8_t *)blob,
            .blob_length = length,
        };
        uint64_t id = open_challenge(s, CHALLENGE_HOST_KEY, 0);
        s->callbacks.on_host_key(s->context, id, &key);
        challenge_answer answer;
        if (await_challenge(s, &answer) != 0) {
            failure = stop_requested(s) ? MR_SSH_FAILURE_CANCELLED : MR_SSH_FAILURE_TIMEOUT;
            goto failed;
        }
        int accepted = !answer.cancelled && answer.decision == MR_SSH_HOST_KEY_ACCEPT;
        clear_answer(&answer);
        if (!accepted) {
            failure = MR_SSH_FAILURE_HOST_KEY_REJECTED;
            goto failed;
        }
    }

    report_state(s, MR_SSH_STATE_AUTHENTICATING, MR_SSH_FAILURE_NONE, 0);
    if (authenticate(s, &failure, &detail) != 0) goto failed;
    if (open_shell(s, &failure, &detail) != 0) goto failed;

    report_state(s, MR_SSH_STATE_CONNECTED, MR_SSH_FAILURE_NONE, 0);
    run_shell(s);
    goto done;

failed:
    if (failure == MR_SSH_FAILURE_CANCELLED) {
        report_state(s, MR_SSH_STATE_CLOSED, MR_SSH_FAILURE_CANCELLED, -1);
    } else {
        report_state(s, MR_SSH_STATE_FAILED, failure, detail);
    }
done:
    close_connection(s);
    pthread_mutex_lock(&s->lock);
    s->running = 0;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
    return MR_SSH_STATUS_OK;
}
