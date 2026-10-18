#include "bridge_internal.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct mr_rdp_session {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_owned_config config;
    mr_rdp_callbacks callbacks;
    void *callback_context;
    mr_rdp_backend *backend;

    mr_rdp_session_state state;
    mr_rdp_transport_security transport_security;
    unsigned int api_calls_in_flight;
    int has_run;
    int run_active;
    int run_thread_valid;
    pthread_t run_thread;
    int destroying;
    int stop_requested;
    int backend_stop_sent;
    int writable;
    uint64_t next_telemetry_sequence;

    int challenge_active;
    int challenge_answered;
    uint64_t challenge_id;
    uint64_t next_challenge_id;
    mr_rdp_certificate_decision challenge_decision;
};

typedef struct mr_rdp_certificate_snapshot {
    mr_rdp_der_blob *chain;
    size_t chain_count;
} mr_rdp_certificate_snapshot;

static size_t mr_min_size(size_t left, size_t right)
{
    return left < right ? left : right;
}

static size_t mr_bounded_string_length(const char *value, size_t maximum)
{
    size_t length = 0;
    if (value == NULL) {
        return maximum + 1u;
    }
    while (length <= maximum && value[length] != '\0') {
        ++length;
    }
    return length;
}

static void mr_secure_zero(void *memory, size_t length)
{
    volatile uint8_t *bytes = (volatile uint8_t *)memory;
    while (length > 0u) {
        *bytes = 0u;
        ++bytes;
        --length;
    }
}

typedef struct mr_sha256_context {
    uint32_t state[8];
    uint64_t total_bytes;
    uint8_t block[64];
    size_t block_length;
} mr_sha256_context;

static uint32_t mr_sha256_rotate_right(uint32_t value, unsigned int count)
{
    return (value >> count) | (value << (32u - count));
}

static uint32_t mr_sha256_load_big_endian(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24u) |
        ((uint32_t)bytes[1] << 16u) |
        ((uint32_t)bytes[2] << 8u) |
        (uint32_t)bytes[3];
}

static void mr_sha256_transform(mr_sha256_context *context, const uint8_t block[64])
{
    static const uint32_t constants[64] = {
        0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
        0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
        0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
        0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
        0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
        0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
        0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
        0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
        0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
        0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
        0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
        0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
        0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
        0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
        0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
        0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
    };
    uint32_t words[64];
    uint32_t a;
    uint32_t b;
    uint32_t c;
    uint32_t d;
    uint32_t e;
    uint32_t f;
    uint32_t g;
    uint32_t h;
    size_t index;

    for (index = 0u; index < 16u; ++index) {
        words[index] = mr_sha256_load_big_endian(block + (index * 4u));
    }
    for (; index < 64u; ++index) {
        const uint32_t x = words[index - 15u];
        const uint32_t y = words[index - 2u];
        const uint32_t sigma0 = mr_sha256_rotate_right(x, 7u) ^
            mr_sha256_rotate_right(x, 18u) ^ (x >> 3u);
        const uint32_t sigma1 = mr_sha256_rotate_right(y, 17u) ^
            mr_sha256_rotate_right(y, 19u) ^ (y >> 10u);
        words[index] = words[index - 16u] + sigma0 +
            words[index - 7u] + sigma1;
    }

    a = context->state[0];
    b = context->state[1];
    c = context->state[2];
    d = context->state[3];
    e = context->state[4];
    f = context->state[5];
    g = context->state[6];
    h = context->state[7];
    for (index = 0u; index < 64u; ++index) {
        const uint32_t sum1 = mr_sha256_rotate_right(e, 6u) ^
            mr_sha256_rotate_right(e, 11u) ^ mr_sha256_rotate_right(e, 25u);
        const uint32_t choice = (e & f) ^ ((~e) & g);
        const uint32_t temporary1 = h + sum1 + choice + constants[index] + words[index];
        const uint32_t sum0 = mr_sha256_rotate_right(a, 2u) ^
            mr_sha256_rotate_right(a, 13u) ^ mr_sha256_rotate_right(a, 22u);
        const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t temporary2 = sum0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temporary1;
        d = c;
        c = b;
        b = a;
        a = temporary1 + temporary2;
    }
    context->state[0] += a;
    context->state[1] += b;
    context->state[2] += c;
    context->state[3] += d;
    context->state[4] += e;
    context->state[5] += f;
    context->state[6] += g;
    context->state[7] += h;
    mr_secure_zero(words, sizeof(words));
}

static void mr_sha256_init(mr_sha256_context *context)
{
    static const uint32_t initial_state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u
    };
    memset(context, 0, sizeof(*context));
    memcpy(context->state, initial_state, sizeof(initial_state));
}

static void mr_sha256_update(
    mr_sha256_context *context,
    const uint8_t *bytes,
    size_t length)
{
    context->total_bytes += (uint64_t)length;
    while (length > 0u) {
        const size_t available = sizeof(context->block) - context->block_length;
        const size_t copied = length < available ? length : available;
        memcpy(context->block + context->block_length, bytes, copied);
        context->block_length += copied;
        bytes += copied;
        length -= copied;
        if (context->block_length == sizeof(context->block)) {
            mr_sha256_transform(context, context->block);
            context->block_length = 0u;
        }
    }
}

static void mr_sha256_final(
    mr_sha256_context *context,
    uint8_t digest[MR_RDP_SHA256_BYTES])
{
    const uint64_t total_bits = context->total_bytes * 8u;
    size_t index;
    context->block[context->block_length++] = 0x80u;
    if (context->block_length > 56u) {
        memset(context->block + context->block_length, 0,
               sizeof(context->block) - context->block_length);
        mr_sha256_transform(context, context->block);
        context->block_length = 0u;
    }
    memset(context->block + context->block_length, 0, 56u - context->block_length);
    for (index = 0u; index < 8u; ++index) {
        context->block[63u - index] = (uint8_t)(total_bits >> (index * 8u));
    }
    mr_sha256_transform(context, context->block);
    for (index = 0u; index < 8u; ++index) {
        digest[index * 4u] = (uint8_t)(context->state[index] >> 24u);
        digest[index * 4u + 1u] = (uint8_t)(context->state[index] >> 16u);
        digest[index * 4u + 2u] = (uint8_t)(context->state[index] >> 8u);
        digest[index * 4u + 3u] = (uint8_t)context->state[index];
    }
    mr_secure_zero(context, sizeof(*context));
}

mr_rdp_status mr_rdp_sha256(
    const uint8_t *bytes,
    size_t length,
    uint8_t digest[MR_RDP_SHA256_BYTES])
{
    mr_sha256_context context;
    if (digest == NULL || (bytes == NULL && length != 0u)) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((uint64_t)length > UINT64_MAX / 8u) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    mr_sha256_init(&context);
    mr_sha256_update(&context, bytes, length);
    mr_sha256_final(&context, digest);
    return MR_RDP_STATUS_OK;
}

static void mr_secure_free(char **value, size_t *length)
{
    if (*value != NULL) {
        mr_secure_zero(*value, *length + 1u);
        free(*value);
        *value = NULL;
    }
    *length = 0u;
}

static void mr_owned_config_clear_password(mr_rdp_owned_config *config)
{
    if (config == NULL) {
        return;
    }
    mr_secure_free(&config->password, &config->password_length);
    mr_secure_free(&config->gateway_password, &config->gateway_password_length);
}

static void mr_owned_config_destroy(mr_rdp_owned_config *config)
{
    if (config == NULL) {
        return;
    }
    mr_owned_config_clear_password(config);
    if (config->username != NULL) {
        mr_secure_zero(config->username, config->username_length + 1u);
        free(config->username);
    }
    if (config->domain != NULL) {
        mr_secure_zero(config->domain, config->domain_length + 1u);
        free(config->domain);
    }
    mr_secure_free(&config->gateway_username, &config->gateway_username_length);
    mr_secure_free(&config->gateway_domain, &config->gateway_domain_length);
    free(config->gateway_hostname);
    free(config->proxy_hostname);
    free(config->drive_path);
    free(config->drive_name);
    free(config->remote_program);
    free(config->remote_arguments);
    free(config->hostname);
    memset(config, 0, sizeof(*config));
}

static mr_rdp_status mr_copy_string_span(
    const char *source,
    size_t length,
    char **out_copy)
{
    char *copy;
    if (out_copy == NULL || source == NULL || length == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    copy = (char *)malloc(length + 1u);
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(copy, source, length);
    copy[length] = '\0';
    *out_copy = copy;
    return MR_RDP_STATUS_OK;
}

static void mr_certificate_snapshot_destroy(mr_rdp_certificate_snapshot *snapshot)
{
    size_t index;
    if (snapshot == NULL || snapshot->chain == NULL) {
        return;
    }
    for (index = 0; index < snapshot->chain_count; ++index) {
        uint8_t *bytes = (uint8_t *)(uintptr_t)snapshot->chain[index].bytes;
        if (bytes != NULL) {
            mr_secure_zero(bytes, snapshot->chain[index].length);
            free(bytes);
        }
    }
    free(snapshot->chain);
    snapshot->chain = NULL;
    snapshot->chain_count = 0u;
}

static mr_rdp_status mr_certificate_snapshot_create(
    const mr_rdp_der_blob *chain,
    size_t chain_count,
    mr_rdp_certificate_snapshot *out_snapshot)
{
    size_t index;
    size_t total = 0u;
    mr_rdp_der_blob *copy;

    if (out_snapshot == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    memset(out_snapshot, 0, sizeof(*out_snapshot));
    if (chain == NULL || chain_count == 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (chain_count > MR_RDP_MAX_CERTIFICATE_CHAIN) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }

    for (index = 0; index < chain_count; ++index) {
        if (chain[index].bytes == NULL || chain[index].length == 0u) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
        if (chain[index].length > MR_RDP_MAX_CERTIFICATE_DER_BYTES) {
            return MR_RDP_ERROR_LIMIT_EXCEEDED;
        }
        if (chain[index].length > MR_RDP_MAX_CERTIFICATE_CHAIN_BYTES - total) {
            return MR_RDP_ERROR_LIMIT_EXCEEDED;
        }
        total += chain[index].length;
    }

    copy = (mr_rdp_der_blob *)calloc(chain_count, sizeof(*copy));
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    out_snapshot->chain = copy;
    out_snapshot->chain_count = chain_count;

    for (index = 0; index < chain_count; ++index) {
        uint8_t *der = (uint8_t *)malloc(chain[index].length);
        if (der == NULL) {
            mr_certificate_snapshot_destroy(out_snapshot);
            return MR_RDP_ERROR_OUT_OF_MEMORY;
        }
        memcpy(der, chain[index].bytes, chain[index].length);
        copy[index].bytes = der;
        copy[index].length = chain[index].length;
    }
    return MR_RDP_STATUS_OK;
}

static struct timespec mr_deadline_after_milliseconds(uint32_t milliseconds)
{
    struct timespec deadline;
    uint64_t nanoseconds;
    (void)clock_gettime(CLOCK_REALTIME, &deadline);
    nanoseconds = (uint64_t)deadline.tv_nsec +
        ((uint64_t)(milliseconds % 1000u) * 1000000u);
    deadline.tv_sec += (time_t)(milliseconds / 1000u) +
        (time_t)(nanoseconds / 1000000000u);
    deadline.tv_nsec = (long)(nanoseconds % 1000000000u);
    return deadline;
}

static void mr_emit_state(mr_rdp_session *session, mr_rdp_session_state state)
{
    mr_rdp_state_callback callback;
    mr_rdp_state_event event;

    (void)pthread_mutex_lock(&session->mutex);
    session->state = state;
    session->writable = state == MR_RDP_SESSION_CONNECTED &&
        !session->stop_requested && !session->destroying;
    callback = session->callbacks.on_state_changed;
    (void)pthread_mutex_unlock(&session->mutex);

    if (callback != NULL) {
        memset(&event, 0, sizeof(event));
        event.struct_size = (uint32_t)sizeof(event);
        event.state = state;
        event.generation = session->config.generation;
        event.transport_security = state == MR_RDP_SESSION_CONNECTED
            ? session->transport_security
            : MR_RDP_TRANSPORT_UNKNOWN;
        callback(session->callback_context, &event);
    }
}

static void mr_emit_error(mr_rdp_session *session, mr_rdp_status status, int32_t native_code)
{
    mr_rdp_error_callback callback = session->callbacks.on_error;
    mr_rdp_error_event event;
    if (callback == NULL) {
        return;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.generation = session->config.generation;
    event.status = status;
    event.native_code = native_code;
    callback(session->callback_context, &event);
}

static mr_rdp_status mr_bridge_present_certificate(
    void *context,
    mr_rdp_certificate_role role,
    const mr_rdp_der_blob *chain,
    size_t chain_count)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_certificate_snapshot snapshot;
    mr_rdp_certificate_challenge challenge;
    mr_rdp_certificate_callback callback;
    mr_rdp_status status;
    struct timespec deadline;
    uint64_t challenge_id;
    int wait_status = 0;
    int invoke_callback;

    if (role != MR_RDP_CERTIFICATE_ROLE_SERVER &&
        (role != MR_RDP_CERTIFICATE_ROLE_GATEWAY || session->config.gateway_hostname == NULL)) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    status = mr_certificate_snapshot_create(chain, chain_count, &snapshot);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }

    (void)pthread_mutex_lock(&session->mutex);
    if (session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        mr_certificate_snapshot_destroy(&snapshot);
        return MR_RDP_ERROR_STOPPED;
    }
    if (session->challenge_active) {
        (void)pthread_mutex_unlock(&session->mutex);
        mr_certificate_snapshot_destroy(&snapshot);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    ++session->next_challenge_id;
    if (session->next_challenge_id == 0u) {
        ++session->next_challenge_id;
    }
    challenge_id = session->next_challenge_id;
    session->challenge_active = 1;
    session->challenge_answered = 0;
    session->challenge_id = challenge_id;
    session->challenge_decision = MR_RDP_CERTIFICATE_REJECT;
    callback = session->callbacks.on_certificate_challenge;
    (void)pthread_mutex_unlock(&session->mutex);

    mr_emit_state(session, MR_RDP_SESSION_AWAITING_CERTIFICATE);

    (void)pthread_mutex_lock(&session->mutex);
    invoke_callback = !session->stop_requested && !session->destroying;
    (void)pthread_mutex_unlock(&session->mutex);

    if (invoke_callback && callback != NULL) {
        memset(&challenge, 0, sizeof(challenge));
        challenge.struct_size = (uint32_t)sizeof(challenge);
        challenge.generation = session->config.generation;
        challenge.challenge_id = challenge_id;
        challenge.role = role;
        if (role == MR_RDP_CERTIFICATE_ROLE_GATEWAY) {
            challenge.hostname = session->config.gateway_hostname;
            challenge.hostname_length = session->config.gateway_hostname_length;
            challenge.port = session->config.gateway_port;
        } else {
            challenge.hostname = session->config.hostname;
            challenge.hostname_length = session->config.hostname_length;
            challenge.port = session->config.port;
        }
        challenge.chain = snapshot.chain;
        challenge.chain_count = snapshot.chain_count;
        callback(session->callback_context, &challenge);
    }

    deadline = mr_deadline_after_milliseconds(session->config.certificate_timeout_ms);
    (void)pthread_mutex_lock(&session->mutex);
    if (callback == NULL && !session->challenge_answered) {
        session->challenge_answered = 1;
        session->challenge_decision = MR_RDP_CERTIFICATE_REJECT;
    }
    while (!session->stop_requested && !session->destroying &&
           !session->challenge_answered && wait_status == 0) {
        wait_status = pthread_cond_timedwait(&session->condition, &session->mutex, &deadline);
    }

    if (session->stop_requested || session->destroying) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (wait_status != 0 && wait_status != ETIMEDOUT) {
        status = MR_RDP_ERROR_BACKEND;
    } else if (!session->challenge_answered) {
        status = MR_RDP_ERROR_TIMEOUT;
    } else if (session->challenge_decision == MR_RDP_CERTIFICATE_REJECT) {
        status = MR_RDP_ERROR_CERTIFICATE_REJECTED;
    } else {
        status = MR_RDP_STATUS_OK;
    }
    session->challenge_active = 0;
    session->challenge_answered = 0;
    session->challenge_id = 0u;
    session->challenge_decision = MR_RDP_CERTIFICATE_REJECT;
    (void)pthread_cond_broadcast(&session->condition);
    (void)pthread_mutex_unlock(&session->mutex);

    mr_certificate_snapshot_destroy(&snapshot);
    return status;
}

static mr_rdp_status mr_bridge_connected(void *context, mr_rdp_transport_security transport)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    int stopped;
    (void)pthread_mutex_lock(&session->mutex);
    session->transport_security = transport;
    stopped = session->stop_requested || session->destroying;
    (void)pthread_mutex_unlock(&session->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    mr_emit_state(session, MR_RDP_SESSION_CONNECTED);
    (void)pthread_mutex_lock(&session->mutex);
    stopped = session->stop_requested || session->destroying;
    (void)pthread_mutex_unlock(&session->mutex);
    return stopped ? MR_RDP_ERROR_STOPPED : MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_desktop_frame(
    const mr_rdp_session *session,
    const mr_rdp_desktop_frame *frame)
{
    size_t minimum_stride;
    size_t required_length;
    size_t index;

    if (session == NULL || frame == NULL || frame->struct_size < sizeof(*frame) ||
        frame->reserved != 0u || frame->reserved2 != 0u ||
        frame->generation != session->config.generation ||
        frame->surface_generation == 0u || frame->frame_id == 0u ||
        frame->width == 0u || frame->height == 0u ||
        frame->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        frame->height > MR_RDP_MAX_DESKTOP_DIMENSION ||
        frame->bytes == NULL || frame->dirty_rects == NULL ||
        frame->dirty_rect_count == 0u ||
        frame->dirty_rect_count > MR_RDP_MAX_DESKTOP_DIRTY_RECTS) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if ((size_t)frame->width > SIZE_MAX / 4u) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    minimum_stride = (size_t)frame->width * 4u;
    if ((size_t)frame->stride < minimum_stride) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if ((size_t)frame->stride > SIZE_MAX / (size_t)frame->height) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    required_length = (size_t)frame->stride * (size_t)frame->height;
    if (required_length > MR_RDP_MAX_DESKTOP_FRAME_BYTES ||
        frame->length > MR_RDP_MAX_DESKTOP_FRAME_BYTES) {
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    if (frame->length < required_length) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    for (index = 0u; index < frame->dirty_rect_count; ++index) {
        const mr_rdp_rect *rect = &frame->dirty_rects[index];
        if (rect->width == 0u || rect->height == 0u ||
            rect->x >= frame->width || rect->y >= frame->height ||
            rect->width > frame->width - rect->x ||
            rect->height > frame->height - rect->y) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_present_frame(
    void *context,
    const mr_rdp_desktop_frame *frame)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_desktop_frame view;
    mr_rdp_desktop_frame_callback callback;
    mr_rdp_status status;

    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    status = mr_validate_desktop_frame(session, frame);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }

    (void)pthread_mutex_lock(&session->mutex);
    if (session->state != MR_RDP_SESSION_CONNECTED ||
        session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_STOPPED;
    }
    callback = session->callbacks.on_desktop_frame;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }

    memset(&view, 0, sizeof(view));
    view.struct_size = (uint32_t)sizeof(view);
    view.generation = frame->generation;
    view.surface_generation = frame->surface_generation;
    view.frame_id = frame->frame_id;
    view.width = frame->width;
    view.height = frame->height;
    view.stride = frame->stride;
    view.bytes = frame->bytes;
    view.length = frame->length;
    view.dirty_rects = frame->dirty_rects;
    view.dirty_rect_count = frame->dirty_rect_count;
    callback(session->callback_context, &view);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_next_telemetry_sequence(
    mr_rdp_session *session,
    uint64_t *out_sequence)
{
    if (session == NULL || out_sequence == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (!session->run_active || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_STOPPED;
    }
    if (session->next_telemetry_sequence == UINT64_MAX) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_LIMIT_EXCEEDED;
    }
    ++session->next_telemetry_sequence;
    *out_sequence = session->next_telemetry_sequence;
    (void)pthread_mutex_unlock(&session->mutex);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_channel_event(
    void *context,
    mr_rdp_channel_kind channel,
    mr_rdp_channel_transition transition)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_channel_callback callback;
    mr_rdp_channel_event event;
    mr_rdp_status status;
    uint64_t sequence;
    if (channel < MR_RDP_CHANNEL_CLIPRDR || channel > MR_RDP_CHANNEL_MACRDPX ||
        transition > MR_RDP_CHANNEL_CONNECTED) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    status = mr_next_telemetry_sequence(session, &sequence);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_channel_event;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.channel = channel;
    event.transition = transition;
    event.generation = session->config.generation;
    event.sequence = sequence;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_probe_event(
    void *context,
    const mr_rdp_backend_clipboard_probe *probe,
    mr_rdp_clipboard_probe_stage stage,
    mr_rdp_status result)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_probe_callback callback;
    mr_rdp_clipboard_probe_event event;
    mr_rdp_status status;
    uint64_t sequence;
    if (probe == NULL || probe->probe_id == 0u ||
        probe->utf16le_byte_count < 4u ||
        probe->utf16le_byte_count > MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES ||
        stage < MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT ||
        stage > MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT || result > MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    status = mr_next_telemetry_sequence(session, &sequence);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_probe_event;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.stage = stage;
    event.status = result;
    event.generation = session->config.generation;
    event.sequence = sequence;
    event.probe_id = probe->probe_id;
    event.payload_byte_count = probe->utf16le_byte_count;
    memcpy(event.payload_sha256, probe->payload_sha256, sizeof(event.payload_sha256));
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

/* MS-RDPBCGR 2.2.1.3.2 allows exactly these device scale factors. */
static int mr_valid_device_scale_factor(uint32_t factor)
{
    return factor == 100u || factor == 140u || factor == 180u;
}

static int mr_valid_desktop_scale_factor(uint32_t factor)
{
    return factor >= MR_RDP_MIN_DESKTOP_SCALE_FACTOR &&
           factor <= MR_RDP_MAX_DESKTOP_SCALE_FACTOR;
}

static mr_rdp_status mr_validate_display_resize_request(
    const mr_rdp_display_resize_request *request)
{
    if (request == NULL || request->struct_size < sizeof(*request) ||
        request->reserved != 0u || request->request_id == 0u ||
        request->width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        (request->width & 1u) != 0u ||
        request->height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->height > MR_RDP_MAX_DESKTOP_DIMENSION ||
        (request->desktop_scale_factor != 0u &&
         !mr_valid_desktop_scale_factor(request->desktop_scale_factor)) ||
        (request->device_scale_factor != 0u &&
         !mr_valid_device_scale_factor(request->device_scale_factor))) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (request->secondary_width == 0u && request->secondary_height == 0u) {
        return MR_RDP_STATUS_OK;
    }
    if (request->secondary_width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->secondary_width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        (request->secondary_width & 1u) != 0u ||
        request->secondary_height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->secondary_height > MR_RDP_MAX_DESKTOP_DIMENSION ||
        request->width + request->secondary_width > MR_RDP_MAX_VIRTUAL_DESKTOP_WIDTH) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_display_resize_event(
    void *context,
    const mr_rdp_display_resize_request *request,
    mr_rdp_status result)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_display_resize_callback callback;
    mr_rdp_display_resize_event event;
    mr_rdp_status status;
    uint64_t sequence;
    if (mr_validate_display_resize_request(request) != MR_RDP_STATUS_OK ||
        result > MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    status = mr_next_telemetry_sequence(session, &sequence);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_display_resize_event;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.status = result;
    event.generation = session->config.generation;
    event.sequence = sequence;
    event.request_id = request->request_id;
    event.width = request->width;
    event.height = request->height;
    event.secondary_width = request->secondary_width;
    event.secondary_height = request->secondary_height;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_invoke_check(mr_rdp_session *session)
{
    int stopped;
    (void)pthread_mutex_lock(&session->mutex);
    stopped = session->stop_requested || session->destroying;
    (void)pthread_mutex_unlock(&session->mutex);
    return stopped ? MR_RDP_ERROR_STOPPED : MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_cursor_event(
    void *context,
    const mr_rdp_cursor_event *event)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_cursor_callback callback;
    mr_rdp_cursor_event view;
    if (session == NULL || event == NULL ||
        event->struct_size < sizeof(*event) ||
        event->generation != session->config.generation) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (event->kind == MR_RDP_CURSOR_SHAPE) {
        if (event->width == 0u || event->height == 0u ||
            event->width > MR_RDP_MAX_CURSOR_DIMENSION ||
            event->height > MR_RDP_MAX_CURSOR_DIMENSION ||
            event->hotspot_x >= event->width ||
            event->hotspot_y >= event->height ||
            event->stride < event->width * 4u ||
            event->bytes == NULL ||
            event->length < (size_t)event->stride * (size_t)event->height) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    } else if (event->kind != MR_RDP_CURSOR_HIDDEN &&
               event->kind != MR_RDP_CURSOR_DEFAULT) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_cursor;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&view, 0, sizeof(view));
    view.struct_size = (uint32_t)sizeof(view);
    view.kind = event->kind;
    view.generation = event->generation;
    if (event->kind == MR_RDP_CURSOR_SHAPE) {
        view.width = event->width;
        view.height = event->height;
        view.hotspot_x = event->hotspot_x;
        view.hotspot_y = event->hotspot_y;
        view.stride = event->stride;
        view.bytes = event->bytes;
        view.length = (size_t)event->stride * (size_t)event->height;
    }
    callback(session->callback_context, &view);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_audio_packet(
    void *context,
    const mr_rdp_audio_packet *packet)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_audio_callback callback;
    mr_rdp_audio_packet view;
    size_t frame_bytes;
    if (session == NULL || packet == NULL ||
        packet->struct_size < sizeof(*packet) ||
        packet->generation != session->config.generation ||
        packet->bits_per_sample != 16u ||
        packet->channels < 1u || packet->channels > 2u ||
        packet->samples_per_second < 8000u ||
        packet->samples_per_second > 192000u ||
        packet->bytes == NULL || packet->length == 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    frame_bytes = (size_t)packet->channels * 2u;
    if (packet->length % frame_bytes != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_audio;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&view, 0, sizeof(view));
    view.struct_size = (uint32_t)sizeof(view);
    view.generation = packet->generation;
    view.samples_per_second = packet->samples_per_second;
    view.channels = packet->channels;
    view.bits_per_sample = packet->bits_per_sample;
    view.bytes = packet->bytes;
    view.length = packet->length;
    callback(session->callback_context, &view);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_remote_formats(
    void *context,
    int has_text,
    int has_image,
    int has_files)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_remote_formats_callback callback;
    mr_rdp_clipboard_remote_formats_event event;
    mr_rdp_status status;
    uint64_t sequence;
    status = mr_next_telemetry_sequence(session, &sequence);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_remote_formats;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.has_text = has_text ? 1u : 0u;
    event.has_image = has_image ? 1u : 0u;
    event.has_files = has_files ? 1u : 0u;
    event.generation = session->config.generation;
    event.sequence = sequence;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_offer_event(
    void *context,
    uint64_t offer_id,
    mr_rdp_clipboard_offer_stage stage,
    mr_rdp_status result)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_offer_callback callback;
    mr_rdp_clipboard_offer_event event;
    if (session == NULL || offer_id == 0u ||
        stage < MR_RDP_CLIPBOARD_OFFER_ACCEPTED ||
        stage > MR_RDP_CLIPBOARD_OFFER_FAILED || result > MR_RDP_STATUS_OK ||
        (stage == MR_RDP_CLIPBOARD_OFFER_FAILED) == (result == MR_RDP_STATUS_OK)) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_offer;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.stage = stage;
    event.generation = session->config.generation;
    event.offer_id = offer_id;
    event.status = result;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_text(
    void *context,
    uint64_t request_id,
    mr_rdp_status result,
    const uint8_t *utf16le_bytes,
    size_t utf16le_byte_count)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_text_callback callback;
    mr_rdp_clipboard_text_event event;
    if (session == NULL || request_id == 0u || result > MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (result == MR_RDP_STATUS_OK) {
        if ((utf16le_bytes == NULL) != (utf16le_byte_count == 0u) ||
            (utf16le_byte_count & 1u) != 0u ||
            utf16le_byte_count > MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    } else if (utf16le_bytes != NULL || utf16le_byte_count != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_text;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.status = result;
    event.generation = session->config.generation;
    event.request_id = request_id;
    event.utf16le_bytes = utf16le_byte_count == 0u ? NULL : utf16le_bytes;
    event.utf16le_byte_count = utf16le_byte_count;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_image(
    void *context,
    uint64_t request_id,
    mr_rdp_status result,
    mr_rdp_clipboard_image_format format,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_image_callback callback;
    mr_rdp_clipboard_image_event event;
    if (session == NULL || request_id == 0u || result > MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (result == MR_RDP_STATUS_OK) {
        if (bytes == NULL || byte_count == 0u ||
            byte_count > MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES ||
            (format != MR_RDP_CLIPBOARD_IMAGE_PNG && format != MR_RDP_CLIPBOARD_IMAGE_DIB)) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    } else if (bytes != NULL || byte_count != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_image;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.status = result;
    event.generation = session->config.generation;
    event.request_id = request_id;
    event.format = result == MR_RDP_STATUS_OK ? format : 0u;
    event.bytes = bytes;
    event.byte_count = byte_count;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_clipboard_file(
    void *context,
    uint64_t request_id,
    mr_rdp_status result,
    uint32_t index,
    uint32_t count,
    int is_last,
    const char *name,
    size_t name_length,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_clipboard_file_callback callback;
    mr_rdp_clipboard_file_event event;
    if (session == NULL || request_id == 0u || result > MR_RDP_STATUS_OK ||
        count > MR_RDP_MAX_CLIPBOARD_FILES) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (result == MR_RDP_STATUS_OK) {
        if (index >= count || name == NULL || name_length == 0u ||
            name_length > MR_RDP_MAX_CLIPBOARD_FILE_NAME_BYTES ||
            memchr(name, '\0', name_length) != NULL ||
            (bytes == NULL) != (byte_count == 0u) ||
            byte_count > MR_RDP_MAX_CLIPBOARD_FILES_BYTES ||
            (is_last != 0) != (index + 1u == count)) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    } else if (!is_last || bytes != NULL || byte_count != 0u || name != NULL) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_clipboard_file;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.status = result;
    event.generation = session->config.generation;
    event.request_id = request_id;
    event.index = index;
    event.count = count;
    event.is_last = is_last ? 1u : 0u;
    event.name = name;
    event.name_length = name_length;
    event.bytes = bytes;
    event.byte_count = byte_count;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_bridge_audio_capture(
    void *context,
    int is_open,
    uint32_t samples_per_second,
    uint16_t channels,
    uint16_t bits_per_sample)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_audio_capture_callback callback;
    mr_rdp_audio_capture_event event;
    if (session == NULL ||
        (is_open && (samples_per_second < 8000u || samples_per_second > 192000u ||
                     channels < 1u || channels > 2u || bits_per_sample != 16u))) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_audio_capture;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.is_open = is_open ? 1u : 0u;
    event.generation = session->config.generation;
    if (is_open) {
        event.samples_per_second = samples_per_second;
        event.channels = channels;
        event.bits_per_sample = bits_per_sample;
    }
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

/* ABI 6. Only server-to-client types reach the application. */
static int mr_macrdpx_from_server(mrx_message_type type)
{
    return type == MRX_MSG_HELLO || type == MRX_MSG_STREAM_STATUS ||
        type == MRX_MSG_INPUT_SOURCE;
}

static int mr_macrdpx_to_server(mrx_message_type type)
{
    return type == MRX_MSG_KEYBOARD_INFO || type == MRX_MSG_KEY ||
        type == MRX_MSG_MODIFIERS || type == MRX_MSG_POINTER ||
        type == MRX_MSG_SCROLL || type == MRX_MSG_GESTURE ||
        type == MRX_MSG_STREAM_CONFIG;
}

static mr_rdp_status mr_bridge_macrdpx_message(
    void *context,
    const mrx_message *message,
    uint32_t negotiated_caps)
{
    mr_rdp_session *session = (mr_rdp_session *)context;
    mr_rdp_macrdpx_callback callback;
    mr_rdp_macrdpx_event event;
    uint8_t scratch[MRX_HEADER_BYTES + 2u * MRX_MAX_NAME_BYTES];
    size_t written = 0u;
    if (session == NULL || message == NULL || !mr_macrdpx_from_server(message->type) ||
        (negotiated_caps & ~session->config.macrdpx_caps) != 0u ||
        mrx_encode(message, scratch, sizeof(scratch), &written) != MRX_OK) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    if (mr_bridge_invoke_check(session) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_lock(&session->mutex);
    callback = session->callbacks.on_macrdpx;
    (void)pthread_mutex_unlock(&session->mutex);
    if (callback == NULL) {
        return MR_RDP_STATUS_OK;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.negotiated_caps = negotiated_caps;
    event.generation = session->config.generation;
    event.message = message;
    callback(session->callback_context, &event);
    return MR_RDP_STATUS_OK;
}

void mr_rdp_clipboard_image_offer_init(mr_rdp_clipboard_image_offer *offer)
{
    if (offer == NULL) {
        return;
    }
    memset(offer, 0, sizeof(*offer));
    offer->struct_size = (uint32_t)sizeof(*offer);
}

void mr_rdp_clipboard_files_offer_init(mr_rdp_clipboard_files_offer *offer)
{
    if (offer == NULL) {
        return;
    }
    memset(offer, 0, sizeof(*offer));
    offer->struct_size = (uint32_t)sizeof(*offer);
}

void mr_rdp_config_init(mr_rdp_config *config)
{
    if (config == NULL) {
        return;
    }
    memset(config, 0, sizeof(*config));
    config->struct_size = (uint32_t)sizeof(*config);
    config->abi_version = MR_RDP_BRIDGE_ABI_VERSION;
    config->port = (uint16_t)MR_RDP_DEFAULT_PORT;
    config->certificate_timeout_ms = MR_RDP_DEFAULT_CERTIFICATE_TIMEOUT_MS;
    config->desktop_width = MR_RDP_DEFAULT_DESKTOP_WIDTH;
    config->desktop_height = MR_RDP_DEFAULT_DESKTOP_HEIGHT;
    config->keyboard_profile = MR_RDP_KEYBOARD_JAPANESE;
    config->channel_flags = MR_RDP_CHANNEL_FLAG_AUDIO | MR_RDP_CHANNEL_FLAG_CLIPBOARD;
    config->desktop_scale_factor = MR_RDP_DEFAULT_SCALE_FACTOR;
    config->device_scale_factor = MR_RDP_DEFAULT_SCALE_FACTOR;
    config->security_policy = MR_RDP_SECURITY_SECURE_AUTOMATIC;
}

void mr_rdp_callbacks_init(mr_rdp_callbacks *callbacks)
{
    if (callbacks == NULL) {
        return;
    }
    memset(callbacks, 0, sizeof(*callbacks));
    callbacks->struct_size = (uint32_t)sizeof(*callbacks);
    callbacks->abi_version = MR_RDP_BRIDGE_ABI_VERSION;
}

void mr_rdp_key_event_init(mr_rdp_key_event *event)
{
    if (event == NULL) {
        return;
    }
    memset(event, 0, sizeof(*event));
    event->struct_size = (uint32_t)sizeof(*event);
}

void mr_rdp_pointer_event_init(mr_rdp_pointer_event *event)
{
    if (event == NULL) {
        return;
    }
    memset(event, 0, sizeof(*event));
    event->struct_size = (uint32_t)sizeof(*event);
}

void mr_rdp_clipboard_probe_init(mr_rdp_clipboard_probe *probe)
{
    if (probe == NULL) {
        return;
    }
    memset(probe, 0, sizeof(*probe));
    probe->struct_size = (uint32_t)sizeof(*probe);
}

void mr_rdp_display_resize_request_init(mr_rdp_display_resize_request *request)
{
    if (request == NULL) {
        return;
    }
    memset(request, 0, sizeof(*request));
    request->struct_size = (uint32_t)sizeof(*request);
}

void mr_rdp_unicode_event_init(mr_rdp_unicode_event *event)
{
    if (event == NULL) {
        return;
    }
    memset(event, 0, sizeof(*event));
    event->struct_size = (uint32_t)sizeof(*event);
}

void mr_rdp_touch_event_init(mr_rdp_touch_event *event)
{
    if (event == NULL) {
        return;
    }
    memset(event, 0, sizeof(*event));
    event->struct_size = (uint32_t)sizeof(*event);
}

void mr_rdp_pen_event_init(mr_rdp_pen_event *event)
{
    if (event == NULL) {
        return;
    }
    memset(event, 0, sizeof(*event));
    event->struct_size = (uint32_t)sizeof(*event);
}

void mr_rdp_clipboard_offer_init(mr_rdp_clipboard_offer *offer)
{
    if (offer == NULL) {
        return;
    }
    memset(offer, 0, sizeof(*offer));
    offer->struct_size = (uint32_t)sizeof(*offer);
}

/* A span that is either absent (NULL/0, when allowed) or 1...maximum bytes
 * with no embedded NUL. */
static int mr_valid_span(const char *bytes, size_t length, size_t maximum, int optional)
{
    if (bytes == NULL || length == 0u) {
        return optional && bytes == NULL && length == 0u;
    }
    return length <= maximum && memchr(bytes, '\0', length) == NULL;
}

static mr_rdp_status mr_validate_gateway(const mr_rdp_config *config)
{
    const int same = (config->gateway_flags & MR_RDP_GATEWAY_FLAG_SAME_CREDENTIALS) != 0u;
    size_t hostname_length;
    if (config->reserved_abi4 != 0u ||
        (config->gateway_flags &
         ~(mr_rdp_gateway_flags)(MR_RDP_GATEWAY_FLAG_SAME_CREDENTIALS |
                                 MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL)) != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->gateway_hostname == NULL) {
        return config->gateway_flags == 0u && config->gateway_port == 0u &&
                config->gateway_username == NULL && config->gateway_username_length == 0u &&
                config->gateway_domain == NULL && config->gateway_domain_length == 0u &&
                config->gateway_password == NULL && config->gateway_password_length == 0u
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    hostname_length = mr_bounded_string_length(config->gateway_hostname, 253u);
    if (hostname_length == 0u || hostname_length > 253u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (same) {
        return config->gateway_username == NULL && config->gateway_username_length == 0u &&
                config->gateway_domain == NULL && config->gateway_domain_length == 0u &&
                config->gateway_password == NULL && config->gateway_password_length == 0u
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return mr_valid_span(config->gateway_username, config->gateway_username_length,
                         MR_RDP_MAX_USERNAME_BYTES, 0) &&
            mr_valid_span(config->gateway_domain, config->gateway_domain_length,
                          MR_RDP_MAX_DOMAIN_BYTES, 1) &&
            mr_valid_span(config->gateway_password, config->gateway_password_length,
                          MR_RDP_MAX_PASSWORD_BYTES, 0)
        ? MR_RDP_STATUS_OK
        : MR_RDP_ERROR_INVALID_ARGUMENT;
}

static mr_rdp_status mr_validate_proxy(const mr_rdp_config *config)
{
    size_t hostname_length;
    if (config->reserved_abi7 != 0u ||
        config->proxy_username != NULL || config->proxy_username_length != 0u ||
        config->proxy_password != NULL || config->proxy_password_length != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->proxy_type == MR_RDP_PROXY_NONE) {
        return config->proxy_hostname == NULL && config->proxy_port == 0u
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->proxy_type != MR_RDP_PROXY_SOCKS5) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    hostname_length = mr_bounded_string_length(config->proxy_hostname, 253u);
    return hostname_length == 0u || hostname_length > 253u
        ? MR_RDP_ERROR_INVALID_ARGUMENT
        : MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_drive(const mr_rdp_config *config)
{
    size_t index;
    if ((config->channel_flags & MR_RDP_CHANNEL_FLAG_DRIVE) == 0u) {
        return config->drive_path == NULL && config->drive_path_length == 0u &&
                config->drive_name == NULL && config->drive_name_length == 0u
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (!mr_valid_span(config->drive_path, config->drive_path_length,
                       MR_RDP_MAX_DRIVE_PATH_BYTES, 0) ||
        config->drive_path[0] != '/' ||
        !mr_valid_span(config->drive_name, config->drive_name_length,
                       MR_RDP_MAX_DRIVE_NAME_BYTES, 0)) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    for (index = 0u; index < config->drive_name_length; ++index) {
        const char c = config->drive_name[index];
        if (c < 0x20 || c > 0x7e || strchr("\\/:*?\"<>|;", c) != NULL) {
            return MR_RDP_ERROR_INVALID_ARGUMENT;
        }
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_config(const mr_rdp_config *config, size_t *out_hostname_length)
{
    size_t hostname_length;
    if (config == NULL || out_hostname_length == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->struct_size < sizeof(*config) ||
        config->abi_version != MR_RDP_BRIDGE_ABI_VERSION ||
        config->reserved != 0u || config->generation == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    hostname_length = mr_bounded_string_length(config->hostname, 253u);
    if (hostname_length == 0u || hostname_length > 253u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->certificate_timeout_ms > 600000u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->keyboard_profile < MR_RDP_KEYBOARD_JAPANESE ||
        config->keyboard_profile > MR_RDP_KEYBOARD_AUTOMATIC ||
        (config->channel_flags &
         ~(mr_rdp_channel_flags)(MR_RDP_CHANNEL_FLAG_AUDIO |
                                 MR_RDP_CHANNEL_FLAG_CLIPBOARD |
                                 MR_RDP_CHANNEL_FLAG_DRIVE |
                                 MR_RDP_CHANNEL_FLAG_TOUCH |
                                 MR_RDP_CHANNEL_FLAG_MICROPHONE |
                                 MR_RDP_CHANNEL_FLAG_H264 |
                                 MR_RDP_CHANNEL_FLAG_MACRDPX)) != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (((config->channel_flags & MR_RDP_CHANNEL_FLAG_MACRDPX) != 0u) !=
            (config->macrdpx_caps != 0u) ||
        config->reserved_abi6 != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (mr_validate_gateway(config) != MR_RDP_STATUS_OK ||
        mr_validate_proxy(config) != MR_RDP_STATUS_OK ||
        mr_validate_drive(config) != MR_RDP_STATUS_OK ||
        !mr_valid_span(config->remote_program, config->remote_program_length,
                       MR_RDP_MAX_REMOTE_PROGRAM_BYTES, 1) ||
        !mr_valid_span(config->remote_arguments, config->remote_arguments_length,
                       MR_RDP_MAX_REMOTE_PROGRAM_BYTES, 1) ||
        (config->remote_program == NULL && config->remote_arguments != NULL)) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (!mr_valid_desktop_scale_factor(config->desktop_scale_factor) ||
        !mr_valid_device_scale_factor(config->device_scale_factor) ||
        config->security_policy < MR_RDP_SECURITY_SECURE_AUTOMATIC ||
        config->security_policy > MR_RDP_SECURITY_LEGACY_ALLOWED ||
        config->reserved_abi3 != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->desktop_width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        config->desktop_width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        config->desktop_height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        config->desktop_height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->username == NULL || config->username_length == 0u ||
        config->username_length > MR_RDP_MAX_USERNAME_BYTES ||
        memchr(config->username, '\0', config->username_length) != NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((config->domain == NULL) != (config->domain_length == 0u) ||
        config->domain_length > MR_RDP_MAX_DOMAIN_BYTES ||
        (config->domain != NULL &&
         memchr(config->domain, '\0', config->domain_length) != NULL)) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (config->password == NULL || config->password_length == 0u ||
        config->password_length > MR_RDP_MAX_PASSWORD_BYTES ||
        memchr(config->password, '\0', config->password_length) != NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_hostname_length = hostname_length;
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_copy_callbacks(
    const mr_rdp_callbacks *callbacks,
    mr_rdp_callbacks *out_callbacks)
{
    memset(out_callbacks, 0, sizeof(*out_callbacks));
    out_callbacks->struct_size = (uint32_t)sizeof(*out_callbacks);
    out_callbacks->abi_version = MR_RDP_BRIDGE_ABI_VERSION;
    if (callbacks == NULL) {
        return MR_RDP_STATUS_OK;
    }
    if (callbacks->struct_size <
            offsetof(mr_rdp_callbacks, on_desktop_frame) +
                sizeof(callbacks->on_desktop_frame) ||
        callbacks->abi_version != MR_RDP_BRIDGE_ABI_VERSION) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    memcpy(out_callbacks, callbacks,
           mr_min_size(callbacks->struct_size, sizeof(*out_callbacks)));
    out_callbacks->struct_size = (uint32_t)sizeof(*out_callbacks);
    out_callbacks->abi_version = MR_RDP_BRIDGE_ABI_VERSION;
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_create_internal(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    mr_rdp_backend_factory factory,
    const void *factory_context,
    mr_rdp_session **out_session)
{
    mr_rdp_session *session;
    mr_rdp_backend_host host;
    mr_rdp_status status;
    size_t hostname_length;
    int mutex_initialized = 0;
    int condition_initialized = 0;

    if (out_session == NULL || factory == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_session = NULL;
    status = mr_validate_config(config, &hostname_length);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }

    session = (mr_rdp_session *)calloc(1u, sizeof(*session));
    if (session == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    status = mr_copy_callbacks(callbacks, &session->callbacks);
    if (status != MR_RDP_STATUS_OK) {
        free(session);
        return status;
    }
    session->config.hostname = (char *)malloc(hostname_length + 1u);
    if (session->config.hostname == NULL) {
        free(session);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(session->config.hostname, config->hostname, hostname_length + 1u);
    session->config.hostname_length = hostname_length;
    session->config.generation = config->generation;
    session->config.port = config->port == 0u ? (uint16_t)MR_RDP_DEFAULT_PORT : config->port;
    session->config.certificate_timeout_ms = config->certificate_timeout_ms == 0u
        ? MR_RDP_DEFAULT_CERTIFICATE_TIMEOUT_MS
        : config->certificate_timeout_ms;
    session->config.desktop_width = config->desktop_width;
    session->config.desktop_height = config->desktop_height;
    session->config.keyboard_profile = config->keyboard_profile;
    session->config.channel_flags = config->channel_flags;
    session->config.desktop_scale_factor = config->desktop_scale_factor;
    session->config.device_scale_factor = config->device_scale_factor;
    session->config.security_policy = config->security_policy;
    session->config.username_length = config->username_length;
    status = mr_copy_string_span(
        config->username, config->username_length, &session->config.username);
    if (status != MR_RDP_STATUS_OK) {
        goto fail;
    }
    if (config->domain != NULL) {
        session->config.domain_length = config->domain_length;
        status = mr_copy_string_span(
            config->domain, config->domain_length, &session->config.domain);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
    }
    session->config.password_length = config->password_length;
    status = mr_copy_string_span(
        config->password, config->password_length, &session->config.password);
    if (status != MR_RDP_STATUS_OK) {
        goto fail;
    }
    if (config->gateway_hostname != NULL) {
        session->config.gateway_hostname_length =
            mr_bounded_string_length(config->gateway_hostname, 253u);
        status = mr_copy_string_span(
            config->gateway_hostname, session->config.gateway_hostname_length,
            &session->config.gateway_hostname);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
        session->config.gateway_port = config->gateway_port == 0u
            ? (uint16_t)MR_RDP_DEFAULT_GATEWAY_PORT
            : config->gateway_port;
        session->config.gateway_flags = config->gateway_flags;
        if (config->gateway_username != NULL) {
            session->config.gateway_username_length = config->gateway_username_length;
            status = mr_copy_string_span(
                config->gateway_username, config->gateway_username_length,
                &session->config.gateway_username);
            if (status != MR_RDP_STATUS_OK) {
                goto fail;
            }
        }
        if (config->gateway_domain != NULL) {
            session->config.gateway_domain_length = config->gateway_domain_length;
            status = mr_copy_string_span(
                config->gateway_domain, config->gateway_domain_length,
                &session->config.gateway_domain);
            if (status != MR_RDP_STATUS_OK) {
                goto fail;
            }
        }
        if (config->gateway_password != NULL) {
            session->config.gateway_password_length = config->gateway_password_length;
            status = mr_copy_string_span(
                config->gateway_password, config->gateway_password_length,
                &session->config.gateway_password);
            if (status != MR_RDP_STATUS_OK) {
                goto fail;
            }
        }
    }
    if (config->remote_program != NULL) {
        session->config.remote_program_length = config->remote_program_length;
        status = mr_copy_string_span(
            config->remote_program, config->remote_program_length,
            &session->config.remote_program);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
        if (config->remote_arguments != NULL) {
            session->config.remote_arguments_length = config->remote_arguments_length;
            status = mr_copy_string_span(
                config->remote_arguments, config->remote_arguments_length,
                &session->config.remote_arguments);
            if (status != MR_RDP_STATUS_OK) {
                goto fail;
            }
        }
    }
    if (config->drive_path != NULL) {
        session->config.drive_path_length = config->drive_path_length;
        status = mr_copy_string_span(
            config->drive_path, config->drive_path_length, &session->config.drive_path);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
        session->config.drive_name_length = config->drive_name_length;
        status = mr_copy_string_span(
            config->drive_name, config->drive_name_length, &session->config.drive_name);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
    }
    if (config->proxy_type == MR_RDP_PROXY_SOCKS5) {
        session->config.proxy_type = config->proxy_type;
        session->config.proxy_hostname_length =
            mr_bounded_string_length(config->proxy_hostname, 253u);
        status = mr_copy_string_span(
            config->proxy_hostname, session->config.proxy_hostname_length,
            &session->config.proxy_hostname);
        if (status != MR_RDP_STATUS_OK) {
            goto fail;
        }
        session->config.proxy_port = config->proxy_port == 0u
            ? (uint16_t)MR_RDP_DEFAULT_PROXY_PORT
            : config->proxy_port;
    }
    session->config.macrdpx_caps = config->macrdpx_caps;
    session->callback_context = context;
    session->state = MR_RDP_SESSION_CREATED;

    if (pthread_mutex_init(&session->mutex, NULL) != 0) {
        status = MR_RDP_ERROR_BACKEND;
        goto fail;
    }
    mutex_initialized = 1;
    if (pthread_cond_init(&session->condition, NULL) != 0) {
        status = MR_RDP_ERROR_BACKEND;
        goto fail;
    }
    condition_initialized = 1;

    memset(&host, 0, sizeof(host));
    host.context = session;
    host.present_certificate = mr_bridge_present_certificate;
    host.connected = mr_bridge_connected;
    host.present_frame = mr_bridge_present_frame;
    host.channel_event = mr_bridge_channel_event;
    host.clipboard_probe_event = mr_bridge_clipboard_probe_event;
    host.display_resize_event = mr_bridge_display_resize_event;
    host.cursor_event = mr_bridge_cursor_event;
    host.audio_packet = mr_bridge_audio_packet;
    host.clipboard_remote_formats = mr_bridge_clipboard_remote_formats;
    host.clipboard_offer_event = mr_bridge_clipboard_offer_event;
    host.clipboard_text = mr_bridge_clipboard_text;
    host.clipboard_image = mr_bridge_clipboard_image;
    host.clipboard_file = mr_bridge_clipboard_file;
    host.audio_capture = mr_bridge_audio_capture;
    host.macrdpx_message = mr_bridge_macrdpx_message;
    status = factory(&session->config, &host, factory_context, &session->backend);
    if (status != MR_RDP_STATUS_OK || session->backend == NULL ||
        session->backend->vtable == NULL ||
        session->backend->vtable->run == NULL ||
        session->backend->vtable->request_stop == NULL ||
        session->backend->vtable->send_key == NULL ||
        session->backend->vtable->send_pointer == NULL ||
        session->backend->vtable->start_clipboard_probe == NULL ||
        session->backend->vtable->request_display_resize == NULL ||
        session->backend->vtable->send_unicode == NULL ||
        session->backend->vtable->set_audio_focused == NULL ||
        session->backend->vtable->offer_clipboard_text == NULL ||
        session->backend->vtable->request_clipboard_text == NULL ||
        session->backend->vtable->send_touch == NULL ||
        session->backend->vtable->offer_clipboard_image == NULL ||
        session->backend->vtable->offer_clipboard_files == NULL ||
        session->backend->vtable->request_clipboard_image == NULL ||
        session->backend->vtable->request_clipboard_files == NULL ||
        session->backend->vtable->send_audio_capture == NULL ||
        session->backend->vtable->send_pen == NULL ||
        session->backend->vtable->send_macrdpx == NULL ||
        session->backend->vtable->destroy == NULL) {
        if (status == MR_RDP_STATUS_OK) {
            status = MR_RDP_ERROR_BACKEND;
        }
        goto fail;
    }
    /* A successful backend factory must own everything it needs after return.
     * FreeRDP has copied this span into rdpSettings, so retain no duplicate
     * session-owned password for the lifetime of the connection. */
    mr_owned_config_clear_password(&session->config);
    *out_session = session;
    return MR_RDP_STATUS_OK;

fail:
    if (session->backend != NULL && session->backend->vtable != NULL &&
        session->backend->vtable->destroy != NULL) {
        session->backend->vtable->destroy(session->backend);
    }
    if (condition_initialized) {
        (void)pthread_cond_destroy(&session->condition);
    }
    if (mutex_initialized) {
        (void)pthread_mutex_destroy(&session->mutex);
    }
    mr_owned_config_destroy(&session->config);
    free(session);
    return status;
}

mr_rdp_status mr_rdp_session_create(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    mr_rdp_session **out_session)
{
    return mr_rdp_session_create_internal(
        config, callbacks, context, mr_rdp_backend_create_default, NULL, out_session);
}

mr_rdp_status mr_rdp_session_run(mr_rdp_session *session)
{
    mr_rdp_status status;
    int stopped_before_run;
    int stop_requested;

    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (session->has_run || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    session->has_run = 1;
    session->run_active = 1;
    session->run_thread_valid = 1;
    session->run_thread = pthread_self();
    stopped_before_run = session->stop_requested;
    (void)pthread_mutex_unlock(&session->mutex);

    if (!stopped_before_run) {
        mr_emit_state(session, MR_RDP_SESSION_CONNECTING);
        (void)pthread_mutex_lock(&session->mutex);
        stop_requested = session->stop_requested || session->destroying;
        (void)pthread_mutex_unlock(&session->mutex);
        status = stop_requested
            ? MR_RDP_ERROR_STOPPED
            : session->backend->vtable->run(session->backend);
    } else {
        status = MR_RDP_ERROR_STOPPED;
    }

    (void)pthread_mutex_lock(&session->mutex);
    stop_requested = session->stop_requested || session->destroying;
    (void)pthread_mutex_unlock(&session->mutex);

    if (stop_requested) {
        mr_emit_state(session, MR_RDP_SESSION_STOPPING);
        mr_emit_state(session, MR_RDP_SESSION_STOPPED);
        status = MR_RDP_STATUS_OK;
    } else if (status == MR_RDP_STATUS_OK) {
        mr_emit_state(session, MR_RDP_SESSION_STOPPED);
    } else {
        mr_emit_state(session, MR_RDP_SESSION_FAILED);
        mr_emit_error(
            session,
            status,
            session->backend != NULL ? session->backend->last_native_error : 0);
    }

    (void)pthread_mutex_lock(&session->mutex);
    session->writable = 0;
    session->run_active = 0;
    session->run_thread_valid = 0;
    (void)pthread_cond_broadcast(&session->condition);
    (void)pthread_mutex_unlock(&session->mutex);
    return status;
}

static void mr_api_call_finished(mr_rdp_session *session)
{
    (void)pthread_mutex_lock(&session->mutex);
    if (session->api_calls_in_flight > 0u) {
        --session->api_calls_in_flight;
    }
    (void)pthread_cond_broadcast(&session->condition);
    (void)pthread_mutex_unlock(&session->mutex);
}

mr_rdp_status mr_rdp_session_request_stop(mr_rdp_session *session)
{
    mr_rdp_backend *backend = NULL;
    int invoke_backend = 0;
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&session->mutex);
    session->stop_requested = 1;
    session->writable = 0;
    (void)pthread_cond_broadcast(&session->condition);
    if (!session->backend_stop_sent && session->backend != NULL) {
        session->backend_stop_sent = 1;
        ++session->api_calls_in_flight;
        backend = session->backend;
        invoke_backend = 1;
    }
    (void)pthread_mutex_unlock(&session->mutex);
    if (invoke_backend) {
        backend->vtable->request_stop(backend);
        mr_api_call_finished(session);
    }
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_respond_certificate(
    mr_rdp_session *session,
    uint64_t generation,
    uint64_t challenge_id,
    mr_rdp_certificate_decision decision)
{
    if (session == NULL ||
        decision > MR_RDP_CERTIFICATE_ACCEPT_PIN) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (session->destroying || session->stop_requested ||
        !session->challenge_active || session->challenge_answered ||
        generation != session->config.generation ||
        challenge_id != session->challenge_id) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_STALE_CHALLENGE;
    }
    session->challenge_decision = decision;
    session->challenge_answered = 1;
    (void)pthread_cond_broadcast(&session->condition);
    (void)pthread_mutex_unlock(&session->mutex);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_cancel_challenge(
    mr_rdp_session *session,
    uint64_t generation,
    uint64_t challenge_id)
{
    return mr_rdp_session_respond_certificate(
        session, generation, challenge_id, MR_RDP_CERTIFICATE_REJECT);
}

static mr_rdp_status mr_validate_key_event(const mr_rdp_key_event *event)
{
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->code == 0u || event->code > 0xffu ||
        event->extended > 1u || event->extended1 > 1u ||
        (event->extended != 0u && event->extended1 != 0u) ||
        event->action > MR_RDP_KEY_UP || event->reserved[0] != 0u ||
        event->reserved[1] != 0u || event->reserved[2] != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_pointer_event(const mr_rdp_pointer_event *event)
{
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->kind > MR_RDP_POINTER_WHEEL || event->reserved != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (event->kind == MR_RDP_POINTER_MOVE) {
        if (event->button != MR_RDP_POINTER_BUTTON_NONE ||
            event->wheel_x != 0 || event->wheel_y != 0 ||
            event->action != MR_RDP_KEY_DOWN) {
            return MR_RDP_ERROR_INVALID_ARGUMENT;
        }
    } else if (event->kind == MR_RDP_POINTER_BUTTON) {
        if (event->button < MR_RDP_POINTER_BUTTON_LEFT ||
            event->button > MR_RDP_POINTER_BUTTON_MIDDLE ||
            event->action > MR_RDP_KEY_UP ||
            event->wheel_x != 0 || event->wheel_y != 0) {
            return MR_RDP_ERROR_INVALID_ARGUMENT;
        }
    } else if (event->button != MR_RDP_POINTER_BUTTON_NONE ||
               (event->wheel_x == 0 && event->wheel_y == 0) ||
               event->wheel_x < -MR_RDP_MAX_WHEEL_DELTA ||
               event->wheel_x > MR_RDP_MAX_WHEEL_DELTA ||
               event->wheel_y < -MR_RDP_MAX_WHEEL_DELTA ||
               event->wheel_y > MR_RDP_MAX_WHEEL_DELTA ||
               event->action != MR_RDP_KEY_DOWN) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_send_key(
    mr_rdp_session *session,
    const mr_rdp_key_event *event)
{
    mr_rdp_backend *backend;
    mr_rdp_status status = mr_validate_key_event(event);
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (!session->writable || session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    backend = session->backend;
    ++session->api_calls_in_flight;
    (void)pthread_mutex_unlock(&session->mutex);
    status = backend->vtable->send_key(backend, event);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_send_pointer(
    mr_rdp_session *session,
    const mr_rdp_pointer_event *event)
{
    mr_rdp_backend *backend;
    mr_rdp_status status = mr_validate_pointer_event(event);
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (!session->writable || session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    backend = session->backend;
    ++session->api_calls_in_flight;
    (void)pthread_mutex_unlock(&session->mutex);
    status = backend->vtable->send_pointer(backend, event);
    mr_api_call_finished(session);
    return status;
}

static mr_rdp_status mr_validate_utf16le_text(
    const uint8_t *bytes,
    size_t byte_count,
    size_t maximum)
{
    size_t offset;
    if (bytes == NULL || byte_count < 4u || byte_count > maximum ||
        (byte_count & 1u) != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (bytes[byte_count - 2u] != 0u || bytes[byte_count - 1u] != 0u) {
        return MR_RDP_ERROR_INVALID_DATA;
    }
    for (offset = 0u; offset + 2u < byte_count; offset += 2u) {
        const uint16_t code_unit = (uint16_t)bytes[offset] |
            ((uint16_t)bytes[offset + 1u] << 8u);
        if (code_unit == 0u) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
        if (code_unit >= 0xd800u && code_unit <= 0xdbffu) {
            uint16_t low_surrogate;
            if (offset + 4u >= byte_count) {
                return MR_RDP_ERROR_INVALID_DATA;
            }
            low_surrogate = (uint16_t)bytes[offset + 2u] |
                ((uint16_t)bytes[offset + 3u] << 8u);
            if (low_surrogate < 0xdc00u || low_surrogate > 0xdfffu) {
                return MR_RDP_ERROR_INVALID_DATA;
            }
            offset += 2u;
        } else if (code_unit >= 0xdc00u && code_unit <= 0xdfffu) {
            return MR_RDP_ERROR_INVALID_DATA;
        }
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_clipboard_probe(
    const mr_rdp_clipboard_probe *probe)
{
    if (probe == NULL || probe->struct_size < sizeof(*probe) ||
        probe->reserved != 0u || probe->probe_id == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return mr_validate_utf16le_text(
        probe->utf16le_bytes,
        probe->utf16le_byte_count,
        MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES);
}

mr_rdp_status mr_rdp_session_start_clipboard_probe(
    mr_rdp_session *session,
    const mr_rdp_clipboard_probe *probe)
{
    mr_rdp_backend *backend;
    mr_rdp_backend_clipboard_probe backend_probe;
    mr_rdp_status status = mr_validate_clipboard_probe(probe);
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    memset(&backend_probe, 0, sizeof(backend_probe));
    backend_probe.probe_id = probe->probe_id;
    backend_probe.utf16le_bytes = probe->utf16le_bytes;
    backend_probe.utf16le_byte_count = probe->utf16le_byte_count;
    status = mr_rdp_sha256(
        probe->utf16le_bytes,
        probe->utf16le_byte_count,
        backend_probe.payload_sha256);
    if (status != MR_RDP_STATUS_OK) {
        mr_secure_zero(&backend_probe, sizeof(backend_probe));
        return status;
    }

    (void)pthread_mutex_lock(&session->mutex);
    if (!session->writable || session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        mr_secure_zero(&backend_probe, sizeof(backend_probe));
        return MR_RDP_ERROR_INVALID_STATE;
    }
    backend = session->backend;
    ++session->api_calls_in_flight;
    (void)pthread_mutex_unlock(&session->mutex);
    status = backend->vtable->start_clipboard_probe(backend, &backend_probe);
    mr_secure_zero(&backend_probe, sizeof(backend_probe));
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_request_display_resize(
    mr_rdp_session *session,
    const mr_rdp_display_resize_request *request)
{
    mr_rdp_backend *backend;
    mr_rdp_status status = mr_validate_display_resize_request(request);
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    (void)pthread_mutex_lock(&session->mutex);
    if (!session->writable || session->stop_requested || session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    backend = session->backend;
    ++session->api_calls_in_flight;
    (void)pthread_mutex_unlock(&session->mutex);
    status = backend->vtable->request_display_resize(backend, request);
    mr_api_call_finished(session);
    return status;
}

/* Registers an API call against the live backend, or reports why not. */
static mr_rdp_status mr_api_call_begin(
    mr_rdp_session *session,
    int require_writable,
    mr_rdp_backend **out_backend)
{
    (void)pthread_mutex_lock(&session->mutex);
    if (session->stop_requested || session->destroying ||
        session->backend == NULL ||
        (require_writable && !session->writable)) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    *out_backend = session->backend;
    ++session->api_calls_in_flight;
    (void)pthread_mutex_unlock(&session->mutex);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_send_unicode(
    mr_rdp_session *session,
    const mr_rdp_unicode_event *event)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || event == NULL ||
        event->struct_size < sizeof(*event) ||
        event->code_unit == 0u || event->reserved != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->send_unicode(backend, event);
    mr_api_call_finished(session);
    return status;
}

static mr_rdp_status mr_validate_touch_event(const mr_rdp_touch_event *event)
{
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->contact_id > MR_RDP_MAX_TOUCH_CONTACT_ID ||
        event->x > MR_RDP_MAX_VIRTUAL_DESKTOP_WIDTH ||
        event->y > MR_RDP_MAX_DESKTOP_DIMENSION ||
        event->action > MR_RDP_TOUCH_CANCEL ||
        event->reserved[0] != 0u || event->reserved[1] != 0u || event->reserved[2] != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_validate_pen_event(const mr_rdp_pen_event *event)
{
    if (event == NULL || event->struct_size < sizeof(*event) ||
        event->x > MR_RDP_MAX_VIRTUAL_DESKTOP_WIDTH ||
        event->y > MR_RDP_MAX_DESKTOP_DIMENSION ||
        event->pressure > MR_RDP_MAX_PEN_PRESSURE ||
        event->tilt_x < -90 || event->tilt_x > 90 ||
        event->tilt_y < -90 || event->tilt_y > 90 ||
        event->rotation > 359u ||
        event->action > MR_RDP_PEN_UP ||
        (event->flags & ~(mr_rdp_pen_flags)(MR_RDP_PEN_FLAG_BARREL | MR_RDP_PEN_FLAG_ERASER)) != 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_send_touch(
    mr_rdp_session *session,
    const mr_rdp_touch_event *event)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || mr_validate_touch_event(event) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_TOUCH) == 0u) {
        return MR_RDP_ERROR_UNSUPPORTED;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->send_touch(backend, event);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_send_pen(
    mr_rdp_session *session,
    const mr_rdp_pen_event *event)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || mr_validate_pen_event(event) != MR_RDP_STATUS_OK) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_TOUCH) == 0u) {
        return MR_RDP_ERROR_UNSUPPORTED;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->send_pen(backend, event);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_set_audio_focused(
    mr_rdp_session *session,
    uint8_t focused)
{
    mr_rdp_backend *backend = NULL;
    if (session == NULL || focused > 1u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if (mr_api_call_begin(session, 0, &backend) != MR_RDP_STATUS_OK) {
        /* A stopping session plays nothing either way. */
        return MR_RDP_STATUS_OK;
    }
    backend->vtable->set_audio_focused(backend, focused);
    mr_api_call_finished(session);
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_session_offer_clipboard_text(
    mr_rdp_session *session,
    const mr_rdp_clipboard_offer *offer)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_backend_clipboard_offer backend_offer;
    mr_rdp_status status;
    if (session == NULL || offer == NULL ||
        offer->struct_size < sizeof(*offer) || offer->reserved != 0u ||
        offer->offer_id == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    status = mr_validate_utf16le_text(
        offer->utf16le_bytes,
        offer->utf16le_byte_count,
        MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) == 0u) {
        return MR_RDP_ERROR_INVALID_STATE;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    memset(&backend_offer, 0, sizeof(backend_offer));
    backend_offer.offer_id = offer->offer_id;
    backend_offer.utf16le_bytes = offer->utf16le_bytes;
    backend_offer.utf16le_byte_count = offer->utf16le_byte_count;
    status = backend->vtable->offer_clipboard_text(backend, &backend_offer);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_request_clipboard_text(
    mr_rdp_session *session,
    uint64_t request_id)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || request_id == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) == 0u) {
        return MR_RDP_ERROR_INVALID_STATE;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->request_clipboard_text(backend, request_id);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_offer_clipboard_image(
    mr_rdp_session *session,
    const mr_rdp_clipboard_image_offer *offer)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || offer == NULL ||
        offer->struct_size < sizeof(*offer) || offer->reserved != 0u ||
        offer->offer_id == 0u ||
        (offer->png_bytes == NULL) != (offer->png_byte_count == 0u) ||
        (offer->dib_bytes == NULL) != (offer->dib_byte_count == 0u) ||
        (offer->png_bytes == NULL && offer->dib_bytes == NULL) ||
        offer->png_byte_count > MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES ||
        offer->dib_byte_count > MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) == 0u) {
        return MR_RDP_ERROR_INVALID_STATE;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->offer_clipboard_image(backend, offer);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_offer_clipboard_files(
    mr_rdp_session *session,
    const mr_rdp_clipboard_files_offer *offer)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    size_t index;
    uint64_t total = 0u;
    if (session == NULL || offer == NULL ||
        offer->struct_size < sizeof(*offer) || offer->reserved != 0u ||
        offer->offer_id == 0u || offer->files == NULL ||
        offer->file_count == 0u || offer->file_count > MR_RDP_MAX_CLIPBOARD_FILES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    for (index = 0u; index < offer->file_count; ++index) {
        const mr_rdp_clipboard_file *file = &offer->files[index];
        if (!mr_valid_span(file->name, file->name_length, MR_RDP_MAX_CLIPBOARD_FILE_NAME_BYTES, 0) ||
            memchr(file->name, '/', file->name_length) != NULL ||
            memchr(file->name, '\\', file->name_length) != NULL ||
            (file->bytes == NULL) != (file->byte_count == 0u)) {
            return MR_RDP_ERROR_INVALID_ARGUMENT;
        }
        total += file->byte_count;
        if (total > MR_RDP_MAX_CLIPBOARD_FILES_BYTES) {
            return MR_RDP_ERROR_LIMIT_EXCEEDED;
        }
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) == 0u) {
        return MR_RDP_ERROR_INVALID_STATE;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->offer_clipboard_files(backend, offer);
    mr_api_call_finished(session);
    return status;
}

/* files: 0 for the image, 1 for files. The backend is read only once the
 * call is registered in flight, like every other entry point. */
static mr_rdp_status mr_clipboard_request(
    mr_rdp_session *session,
    uint64_t request_id,
    int files)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || request_id == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) == 0u) {
        return MR_RDP_ERROR_INVALID_STATE;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = files
        ? backend->vtable->request_clipboard_files(backend, request_id)
        : backend->vtable->request_clipboard_image(backend, request_id);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_request_clipboard_image(
    mr_rdp_session *session,
    uint64_t request_id)
{
    return mr_clipboard_request(session, request_id, 0);
}

mr_rdp_status mr_rdp_session_request_clipboard_files(
    mr_rdp_session *session,
    uint64_t request_id)
{
    return mr_clipboard_request(session, request_id, 1);
}

mr_rdp_status mr_rdp_session_send_audio_capture(
    mr_rdp_session *session,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    if (session == NULL || bytes == NULL || byte_count == 0u ||
        byte_count > MR_RDP_MAX_AUDIO_CAPTURE_PACKET_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_MICROPHONE) == 0u) {
        return MR_RDP_ERROR_UNSUPPORTED;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->send_audio_capture(backend, bytes, byte_count);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_send_macrdpx(
    mr_rdp_session *session,
    const mrx_message *message)
{
    mr_rdp_backend *backend = NULL;
    mr_rdp_status status;
    uint8_t scratch[64];
    size_t written = 0u;
    if (session == NULL || message == NULL || !mr_macrdpx_to_server(message->type) ||
        mrx_encode(message, scratch, sizeof(scratch), &written) != MRX_OK) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    if ((session->config.channel_flags & MR_RDP_CHANNEL_FLAG_MACRDPX) == 0u) {
        return MR_RDP_ERROR_UNSUPPORTED;
    }
    status = mr_api_call_begin(session, 1, &backend);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }
    status = backend->vtable->send_macrdpx(backend, message);
    mr_api_call_finished(session);
    return status;
}

mr_rdp_status mr_rdp_session_destroy(mr_rdp_session *session)
{
    mr_rdp_backend *backend;
    int invoke_backend = 0;
    if (session == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }

    (void)pthread_mutex_lock(&session->mutex);
    if (session->run_active && session->run_thread_valid &&
        pthread_equal(session->run_thread, pthread_self()) != 0) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    if (session->destroying) {
        (void)pthread_mutex_unlock(&session->mutex);
        return MR_RDP_ERROR_INVALID_STATE;
    }
    session->destroying = 1;
    session->stop_requested = 1;
    session->writable = 0;
    (void)pthread_cond_broadcast(&session->condition);
    if (!session->backend_stop_sent && session->backend != NULL) {
        session->backend_stop_sent = 1;
        ++session->api_calls_in_flight;
        invoke_backend = 1;
    }
    backend = session->backend;
    (void)pthread_mutex_unlock(&session->mutex);

    if (invoke_backend) {
        backend->vtable->request_stop(backend);
        mr_api_call_finished(session);
    }

    (void)pthread_mutex_lock(&session->mutex);
    while (session->run_active || session->api_calls_in_flight != 0u ||
           session->challenge_active) {
        (void)pthread_cond_wait(&session->condition, &session->mutex);
    }
    session->backend = NULL;
    (void)pthread_mutex_unlock(&session->mutex);

    if (backend != NULL) {
        backend->vtable->destroy(backend);
    }
    mr_owned_config_destroy(&session->config);
    (void)pthread_cond_destroy(&session->condition);
    (void)pthread_mutex_destroy(&session->mutex);
    mr_secure_zero(session, sizeof(*session));
    free(session);
    return MR_RDP_STATUS_OK;
}

const char *mr_rdp_status_name(mr_rdp_status status)
{
    switch (status) {
        case MR_RDP_STATUS_OK: return "ok";
        case MR_RDP_ERROR_INVALID_ARGUMENT: return "invalid_argument";
        case MR_RDP_ERROR_OUT_OF_MEMORY: return "out_of_memory";
        case MR_RDP_ERROR_INVALID_STATE: return "invalid_state";
        case MR_RDP_ERROR_STOPPED: return "stopped";
        case MR_RDP_ERROR_TIMEOUT: return "timeout";
        case MR_RDP_ERROR_STALE_CHALLENGE: return "stale_challenge";
        case MR_RDP_ERROR_BACKEND_UNAVAILABLE: return "backend_unavailable";
        case MR_RDP_ERROR_BACKEND: return "backend";
        case MR_RDP_ERROR_INVALID_DATA: return "invalid_data";
        case MR_RDP_ERROR_LIMIT_EXCEEDED: return "limit_exceeded";
        case MR_RDP_ERROR_CERTIFICATE_REJECTED: return "certificate_rejected";
        case MR_RDP_ERROR_UNSUPPORTED: return "unsupported";
        default: return "unknown";
    }
}
