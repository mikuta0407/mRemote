#ifndef MREMOTE_SSH_BRIDGE_H
#define MREMOTE_SSH_BRIDGE_H

/*
 * The C ABI over libssh2 (docs/ssh-design.md section 6.1).
 *
 * One mr_ssh_session is one connection with one interactive shell. libssh2
 * itself is touched only by the thread that calls mr_ssh_session_run; every
 * other function here is safe from any thread and only queues work for it.
 *
 * Callbacks run on the run thread, one at a time, and never after
 * mr_ssh_session_run has returned. Every pointer a callback receives is valid
 * only until it returns: copy what you keep.
 *
 * A challenge (host key, authentication, keyboard-interactive) blocks the run
 * thread until it is answered with the matching challenge ID, cancelled, or
 * the session is stopped. An answer is accepted once; a second answer, or an
 * answer to a challenge that is no longer pending, returns
 * MR_SSH_ERROR_STALE_CHALLENGE.
 *
 * Raw-pointer lifetime stays with the caller: the caller must stop issuing
 * calls before mr_ssh_session_destroy, as the RDP bridge requires.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MR_SSH_BRIDGE_ABI_VERSION 1u
#define MR_SSH_DEFAULT_PORT 22u
#define MR_SSH_MAX_HOST_BYTES 1024u
#define MR_SSH_MAX_USERNAME_BYTES 1024u
#define MR_SSH_MAX_TERM_BYTES 64u
#define MR_SSH_MAX_SECRET_BYTES (64u * 1024u)
#define MR_SSH_MAX_PASSPHRASE_BYTES 4096u
#define MR_SSH_MAX_KBD_PROMPTS 16u
#define MR_SSH_MAX_KBD_ANSWER_BYTES 4096u
/* Keystrokes and pastes waiting for the network. Past this, writes are
 * refused rather than buffered without bound. */
#define MR_SSH_MAX_INPUT_QUEUE_BYTES (1024u * 1024u)
#define MR_SSH_MIN_TERMINAL_DIMENSION 1u
#define MR_SSH_MAX_TERMINAL_DIMENSION 4096u
#define MR_SSH_DEFAULT_CONNECT_TIMEOUT_MS 15000u
/* How long a challenge may wait for the user. The server's own login grace
 * time is usually shorter. */
#define MR_SSH_CHALLENGE_TIMEOUT_MS (5u * 60u * 1000u)

typedef struct mr_ssh_session mr_ssh_session;
typedef int32_t mr_ssh_status;

enum {
    MR_SSH_STATUS_OK = 0,
    MR_SSH_ERROR_INVALID_ARGUMENT = -1,
    MR_SSH_ERROR_OUT_OF_MEMORY = -2,
    MR_SSH_ERROR_INVALID_STATE = -3,
    MR_SSH_ERROR_STOPPED = -4,
    MR_SSH_ERROR_STALE_CHALLENGE = -5,
    MR_SSH_ERROR_QUEUE_FULL = -6
};

typedef uint32_t mr_ssh_state;
enum {
    MR_SSH_STATE_CONNECTING = 1,
    /* The server's identity is settled; signing in. */
    MR_SSH_STATE_AUTHENTICATING = 2,
    /* The shell is open. */
    MR_SSH_STATE_CONNECTED = 3,
    /* Ended without a fault: the shell exited, the server closed the channel,
     * or the caller stopped the session (error MR_SSH_FAILURE_CANCELLED).
     * detail is the shell's exit status, or -1 when there is none. */
    MR_SSH_STATE_CLOSED = 4,
    /* Ended by a fault. error says which; detail is the libssh2 error code or
     * errno behind it, for diagnostics only. */
    MR_SSH_STATE_FAILED = 5
};

typedef uint32_t mr_ssh_failure;
enum {
    MR_SSH_FAILURE_NONE = 0,
    MR_SSH_FAILURE_NAME_RESOLUTION = 1,
    MR_SSH_FAILURE_REFUSED = 2,
    MR_SSH_FAILURE_UNREACHABLE = 3,
    MR_SSH_FAILURE_TIMEOUT = 4,
    /* No key exchange, cipher, MAC or host key algorithm both sides allow. */
    MR_SSH_FAILURE_NEGOTIATION = 5,
    MR_SSH_FAILURE_HOST_KEY_REJECTED = 6,
    MR_SSH_FAILURE_AUTHENTICATION = 7,
    /* The server refused the session channel, the PTY or the shell. */
    MR_SSH_FAILURE_CHANNEL = 8,
    MR_SSH_FAILURE_PROTOCOL = 9,
    /* The connection dropped after it was established. */
    MR_SSH_FAILURE_DISCONNECTED = 10,
    MR_SSH_FAILURE_CANCELLED = 11,
    MR_SSH_FAILURE_INTERNAL = 12
};

/* Sign-in methods, as a bit set. */
typedef uint32_t mr_ssh_auth_method;
enum {
    MR_SSH_AUTH_PUBLICKEY = 1u << 0,
    MR_SSH_AUTH_KEYBOARD_INTERACTIVE = 1u << 1,
    MR_SSH_AUTH_PASSWORD = 1u << 2
};

typedef struct {
    uint32_t struct_size;
    /* Copied during create. host is a name or an IP literal, without
     * brackets. */
    const char *host;
    uint16_t port;
    const char *username;
    /* TERM, e.g. "xterm-256color". */
    const char *term;
    uint16_t columns;
    uint16_t rows;
    uint16_t pixel_width;
    uint16_t pixel_height;
    /* 0 turns keepalive off. */
    uint32_t keepalive_seconds;
    /* 0 means MR_SSH_DEFAULT_CONNECT_TIMEOUT_MS. */
    uint32_t connect_timeout_ms;
} mr_ssh_config;

typedef uint32_t mr_ssh_host_key_type;
enum {
    MR_SSH_HOST_KEY_UNKNOWN = 0,
    MR_SSH_HOST_KEY_RSA = 1,
    MR_SSH_HOST_KEY_ECDSA_256 = 2,
    MR_SSH_HOST_KEY_ECDSA_384 = 3,
    MR_SSH_HOST_KEY_ECDSA_521 = 4,
    MR_SSH_HOST_KEY_ED25519 = 5
};

typedef struct {
    mr_ssh_host_key_type type;
    /* The SSH wire name, e.g. "ssh-ed25519". NUL-terminated. */
    const char *type_name;
    /* The public key blob as sent by the server. The caller hashes it. */
    const uint8_t *blob;
    size_t blob_length;
} mr_ssh_host_key;

typedef uint32_t mr_ssh_host_key_decision;
enum {
    MR_SSH_HOST_KEY_REJECT = 0,
    MR_SSH_HOST_KEY_ACCEPT = 1
};

typedef struct {
    /* What the server offers, limited to what this bridge supports. */
    mr_ssh_auth_method offered;
    /* 1 for the first request, counting up. */
    uint32_t attempt;
    /* The method the previous answer used, if the server refused it; 0 on
     * the first request. */
    mr_ssh_auth_method rejected;
} mr_ssh_auth_request;

typedef struct {
    /* Exactly one method. 0 cancels the sign-in. */
    mr_ssh_auth_method method;
    /* PASSWORD: the password. PUBLICKEY: the private key file's contents
     * (OpenSSH or PEM). Unused for KEYBOARD_INTERACTIVE. Copied, and wiped
     * after use. */
    const uint8_t *secret;
    size_t secret_length;
    /* PUBLICKEY only; NULL/0 for an unencrypted key. */
    const uint8_t *passphrase;
    size_t passphrase_length;
} mr_ssh_auth_answer;

typedef struct {
    const uint8_t *text;
    size_t length;
    /* Nonzero when the answer may be shown as typed. */
    int32_t echo;
} mr_ssh_kbd_prompt;

typedef struct {
    const uint8_t *name;
    size_t name_length;
    const uint8_t *instruction;
    size_t instruction_length;
    const mr_ssh_kbd_prompt *prompts;
    size_t prompt_count;
} mr_ssh_kbd_request;

typedef struct {
    void (*on_state)(void *context, mr_ssh_state state, mr_ssh_failure failure, int32_t detail);
    void (*on_host_key)(void *context, uint64_t challenge_id, const mr_ssh_host_key *key);
    void (*on_auth_request)(void *context, uint64_t challenge_id, const mr_ssh_auth_request *request);
    /* May arrive with prompt_count 0 (an instruction only); answer it with
     * no answers. */
    void (*on_keyboard_interactive)(void *context, uint64_t challenge_id, const mr_ssh_kbd_request *request);
    /* The shell's output, stdout and stderr merged. Returns how many bytes
     * were taken. Fewer than length pauses reading - the server stops once
     * its window fills - until mr_ssh_session_resume_output. */
    size_t (*on_output)(void *context, const uint8_t *bytes, size_t length);
} mr_ssh_callbacks;

uint32_t mr_ssh_bridge_abi_version(void);

/* Copies config and callbacks. on_state, on_host_key, on_auth_request and
 * on_output are required. */
mr_ssh_status mr_ssh_session_create(
    const mr_ssh_config *config,
    const mr_ssh_callbacks *callbacks,
    void *context,
    mr_ssh_session **out_session);

/* Connects, signs in, runs the shell, and returns when the session has ended
 * (after the final on_state). Once per session. */
mr_ssh_status mr_ssh_session_run(mr_ssh_session *session);

mr_ssh_status mr_ssh_session_answer_host_key(
    mr_ssh_session *session, uint64_t challenge_id, mr_ssh_host_key_decision decision);
mr_ssh_status mr_ssh_session_answer_auth(
    mr_ssh_session *session, uint64_t challenge_id, const mr_ssh_auth_answer *answer);
/* answers[i] has lengths[i] bytes; count must equal the prompt count. */
mr_ssh_status mr_ssh_session_answer_keyboard_interactive(
    mr_ssh_session *session, uint64_t challenge_id,
    const uint8_t *const *answers, const size_t *lengths, size_t count);
/* Rejects a host key, or abandons the sign-in. */
mr_ssh_status mr_ssh_session_cancel_challenge(mr_ssh_session *session, uint64_t challenge_id);

/* Queues bytes for the shell, in order. MR_SSH_ERROR_QUEUE_FULL takes none
 * of them. */
mr_ssh_status mr_ssh_session_write(mr_ssh_session *session, const uint8_t *bytes, size_t length);
mr_ssh_status mr_ssh_session_resize(
    mr_ssh_session *session, uint16_t columns, uint16_t rows,
    uint16_t pixel_width, uint16_t pixel_height);
/* After on_output took fewer bytes than offered. */
mr_ssh_status mr_ssh_session_resume_output(mr_ssh_session *session);
/* Idempotent. Wakes a pending challenge and the I/O wait. */
mr_ssh_status mr_ssh_session_request_stop(mr_ssh_session *session);

/* Stops the session, waits for run to return, and frees it. Not from the run
 * thread or a callback. */
mr_ssh_status mr_ssh_session_destroy(mr_ssh_session *session);

#ifdef __cplusplus
}
#endif

#endif
