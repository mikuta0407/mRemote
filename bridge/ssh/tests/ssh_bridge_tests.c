/*
 * The SSH bridge against a real sshd (run_integration.sh starts it). Each test
 * runs one session on its own thread and plays the app's part from here:
 * answering challenges, writing to the shell, taking output.
 */

#define _DARWIN_C_SOURCE 1

#include "mremote/ssh_bridge.h"

#include <pthread.h>
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

    char *output;
    size_t output_length;
    size_t output_capacity;
    /* Output throttling: take at most this many bytes per call while > 0
     * and refuse all while `blocked`. */
    int blocked;
    size_t refused_calls;
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

static void *run_thread(void *argument) {
    harness *h = argument;
    mr_ssh_session_run(h->session);
    return NULL;
}

static void harness_start(harness *h, plan_kind plan, const char *key, uint16_t port) {
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
    };
    mr_ssh_callbacks callbacks = {
        .on_state = on_state,
        .on_host_key = on_host_key,
        .on_auth_request = on_auth_request,
        .on_output = on_output,
    };
    mr_ssh_status status = mr_ssh_session_create(&config, &callbacks, h, &h->session);
    CHECK(status == MR_SSH_STATUS_OK, "create=%d", status);
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
    sleep(2);
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

    if (g_failures) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
