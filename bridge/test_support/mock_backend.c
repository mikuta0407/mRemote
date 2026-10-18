#include "bridge_internal.h"
#include "mremote/rdp_bridge_mock.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MR_RDP_MOCK_COMMAND_CAPACITY 16u
#define MR_RDP_MOCK_MAX_CHANNEL_TRANSITIONS 64u

typedef uint8_t mr_rdp_mock_command_kind;
enum {
    MR_RDP_MOCK_COMMAND_CLIPBOARD_PROBE = 1,
    MR_RDP_MOCK_COMMAND_DISPLAY_RESIZE = 2,
    MR_RDP_MOCK_COMMAND_CLIPBOARD_OFFER = 3,
    MR_RDP_MOCK_COMMAND_CLIPBOARD_REQUEST = 4,
    MR_RDP_MOCK_COMMAND_IMAGE_REQUEST = 5,
    MR_RDP_MOCK_COMMAND_FILES_REQUEST = 6
};

typedef struct mr_rdp_mock_command {
    mr_rdp_mock_command_kind kind;
    union {
        mr_rdp_backend_clipboard_probe clipboard_probe;
        mr_rdp_display_resize_request display_resize;
        mr_rdp_backend_clipboard_offer clipboard_offer;
        uint64_t clipboard_request_id;
    } value;
} mr_rdp_mock_command;

typedef struct mr_rdp_mock_backend {
    mr_rdp_backend base;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    mr_rdp_backend_host host;
    mr_rdp_der_blob *certificate_chain;
    size_t certificate_chain_count;
    uint32_t delay_before_certificate_ms;
    void *observer_context;
    mr_rdp_mock_stop_observer on_request_stop;
    mr_rdp_mock_key_observer on_send_key;
    mr_rdp_mock_pointer_observer on_send_pointer;
    mr_rdp_mock_config_observer on_config;
    mr_rdp_mock_clipboard_probe_observer on_start_clipboard_probe;
    mr_rdp_mock_display_resize_observer on_request_display_resize;
    mr_rdp_mock_unicode_observer on_send_unicode;
    mr_rdp_mock_audio_focus_observer on_set_audio_focused;
    mr_rdp_mock_session_config_observer on_session_config;
    mr_rdp_mock_clipboard_offer_observer on_offer_clipboard_text;
    mr_rdp_mock_scale_observer on_scale_config;
    mr_rdp_mock_security_observer on_security_policy;
    mr_rdp_mock_touch_observer on_send_touch;
    mr_rdp_mock_pen_observer on_send_pen;
    mr_rdp_mock_connection_observer on_connection_config;
    mr_rdp_der_blob *gateway_certificate_chain;
    size_t gateway_certificate_chain_count;
    const mr_rdp_cursor_event *cursor_event;
    const mr_rdp_audio_packet *audio_packet;
    const uint8_t *remote_clipboard_utf16le;
    size_t remote_clipboard_utf16le_byte_count;
    /* ABI 5. */
    const uint8_t *remote_image_png;
    size_t remote_image_png_byte_count;
    const mr_rdp_clipboard_file *remote_files;
    size_t remote_file_count;
    uint32_t audio_capture_rate;
    mr_rdp_mock_image_offer_observer on_offer_clipboard_image;
    mr_rdp_mock_files_offer_observer on_offer_clipboard_files;
    mr_rdp_mock_capture_observer on_send_audio_capture;
    /* ABI 6. */
    const mrx_message *macrdpx_messages;
    size_t macrdpx_message_count;
    mr_rdp_mock_macrdpx_observer on_send_macrdpx;
    int audio_focused;
    mr_rdp_owned_config config;
    mr_rdp_desktop_frame desktop_frame;
    mr_rdp_mock_channel_transition *channel_transitions;
    size_t channel_transition_count;
    mr_rdp_mock_command commands[MR_RDP_MOCK_COMMAND_CAPACITY];
    size_t command_head;
    size_t command_count;
    int has_desktop_frame;
    int stop_requested;
} mr_rdp_mock_backend;

static void mr_mock_secure_zero(void *memory, size_t length)
{
    volatile uint8_t *bytes = (volatile uint8_t *)memory;
    while (length > 0u) {
        *bytes++ = 0u;
        --length;
    }
}

static void mr_mock_command_destroy(mr_rdp_mock_command *command)
{
    if (command == NULL) {
        return;
    }
    if (command->kind == MR_RDP_MOCK_COMMAND_CLIPBOARD_PROBE) {
        mr_rdp_backend_clipboard_probe *probe = &command->value.clipboard_probe;
        uint8_t *bytes = (uint8_t *)(uintptr_t)probe->utf16le_bytes;
        if (bytes != NULL) {
            mr_mock_secure_zero(bytes, probe->utf16le_byte_count);
            free(bytes);
        }
    } else if (command->kind == MR_RDP_MOCK_COMMAND_CLIPBOARD_OFFER) {
        mr_rdp_backend_clipboard_offer *offer = &command->value.clipboard_offer;
        uint8_t *bytes = (uint8_t *)(uintptr_t)offer->utf16le_bytes;
        if (bytes != NULL) {
            mr_mock_secure_zero(bytes, offer->utf16le_byte_count);
            free(bytes);
        }
    }
    mr_mock_secure_zero(command, sizeof(*command));
}

static void mr_mock_discard_commands_locked(mr_rdp_mock_backend *backend)
{
    while (backend->command_count > 0u) {
        mr_rdp_mock_command *command = &backend->commands[backend->command_head];
        mr_mock_command_destroy(command);
        backend->command_head = (backend->command_head + 1u) %
            MR_RDP_MOCK_COMMAND_CAPACITY;
        --backend->command_count;
    }
    backend->command_head = 0u;
}

static void mr_mock_owned_config_destroy(mr_rdp_owned_config *config)
{
    if (config == NULL) {
        return;
    }
    if (config->hostname != NULL) {
        mr_mock_secure_zero(config->hostname, config->hostname_length + 1u);
        free(config->hostname);
    }
    if (config->username != NULL) {
        mr_mock_secure_zero(config->username, config->username_length + 1u);
        free(config->username);
    }
    if (config->domain != NULL) {
        mr_mock_secure_zero(config->domain, config->domain_length + 1u);
        free(config->domain);
    }
    if (config->password != NULL) {
        mr_mock_secure_zero(config->password, config->password_length + 1u);
        free(config->password);
    }
    {
        char *spans[] = {
            config->gateway_hostname, config->gateway_username, config->gateway_domain,
            config->gateway_password, config->drive_path, config->drive_name
        };
        size_t lengths[] = {
            config->gateway_hostname_length, config->gateway_username_length,
            config->gateway_domain_length, config->gateway_password_length,
            config->drive_path_length, config->drive_name_length
        };
        size_t index;
        for (index = 0u; index < sizeof(spans) / sizeof(spans[0]); ++index) {
            if (spans[index] != NULL) {
                mr_mock_secure_zero(spans[index], lengths[index] + 1u);
                free(spans[index]);
            }
        }
    }
    memset(config, 0, sizeof(*config));
}

static mr_rdp_status mr_mock_copy_config_span(
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

static mr_rdp_status mr_mock_owned_config_copy(
    const mr_rdp_owned_config *source,
    mr_rdp_owned_config *destination)
{
    mr_rdp_status status;
    if (source == NULL || destination == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *destination = *source;
    destination->hostname = NULL;
    destination->username = NULL;
    destination->domain = NULL;
    destination->password = NULL;
    destination->gateway_hostname = NULL;
    destination->gateway_username = NULL;
    destination->gateway_domain = NULL;
    destination->gateway_password = NULL;
    destination->drive_path = NULL;
    destination->drive_name = NULL;
    status = mr_mock_copy_config_span(
        source->hostname, source->hostname_length, &destination->hostname);
    if (status == MR_RDP_STATUS_OK) {
        status = mr_mock_copy_config_span(
            source->username, source->username_length, &destination->username);
    }
    if (status == MR_RDP_STATUS_OK && source->domain != NULL) {
        status = mr_mock_copy_config_span(
            source->domain, source->domain_length, &destination->domain);
    }
    if (status == MR_RDP_STATUS_OK) {
        status = mr_mock_copy_config_span(
            source->password, source->password_length, &destination->password);
    }
    {
        const char *sources[] = {
            source->gateway_hostname, source->gateway_username, source->gateway_domain,
            source->gateway_password, source->drive_path, source->drive_name
        };
        const size_t lengths[] = {
            source->gateway_hostname_length, source->gateway_username_length,
            source->gateway_domain_length, source->gateway_password_length,
            source->drive_path_length, source->drive_name_length
        };
        char **targets[] = {
            &destination->gateway_hostname, &destination->gateway_username,
            &destination->gateway_domain, &destination->gateway_password,
            &destination->drive_path, &destination->drive_name
        };
        size_t index;
        for (index = 0u; status == MR_RDP_STATUS_OK && index < 6u; ++index) {
            if (sources[index] != NULL) {
                status = mr_mock_copy_config_span(sources[index], lengths[index], targets[index]);
            }
        }
    }
    if (status != MR_RDP_STATUS_OK) {
        mr_mock_owned_config_destroy(destination);
    }
    return status;
}

static struct timespec mr_mock_deadline_after_milliseconds(uint32_t milliseconds)
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

static mr_rdp_status mr_mock_process_command(
    mr_rdp_mock_backend *backend,
    mr_rdp_mock_command *command)
{
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (command->kind == MR_RDP_MOCK_COMMAND_CLIPBOARD_PROBE) {
        static const mr_rdp_clipboard_probe_stage stages[] = {
            MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT,
            MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE,
            MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST,
            MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT
        };
        size_t index;
        mr_rdp_backend_clipboard_probe *probe = &command->value.clipboard_probe;
        if (backend->on_start_clipboard_probe != NULL) {
            backend->on_start_clipboard_probe(
                backend->observer_context,
                probe->probe_id,
                probe->utf16le_bytes,
                probe->utf16le_byte_count,
                probe->payload_sha256);
        }
        for (index = 0u; index < sizeof(stages) / sizeof(stages[0]); ++index) {
            status = backend->host.clipboard_probe_event(
                backend->host.context,
                probe,
                stages[index],
                MR_RDP_STATUS_OK);
            if (status != MR_RDP_STATUS_OK) {
                break;
            }
        }
    } else if (command->kind == MR_RDP_MOCK_COMMAND_DISPLAY_RESIZE) {
        mr_rdp_display_resize_request *request = &command->value.display_resize;
        if (backend->on_request_display_resize != NULL) {
            backend->on_request_display_resize(backend->observer_context, request);
        }
        status = backend->host.display_resize_event(
            backend->host.context, request, MR_RDP_STATUS_OK);
    } else if (command->kind == MR_RDP_MOCK_COMMAND_CLIPBOARD_OFFER) {
        mr_rdp_backend_clipboard_offer *offer = &command->value.clipboard_offer;
        if (backend->on_offer_clipboard_text != NULL) {
            backend->on_offer_clipboard_text(
                backend->observer_context,
                offer->offer_id,
                offer->utf16le_bytes,
                offer->utf16le_byte_count);
        }
        status = backend->host.clipboard_offer_event(
            backend->host.context, offer->offer_id,
            MR_RDP_CLIPBOARD_OFFER_ACCEPTED, MR_RDP_STATUS_OK);
        if (status == MR_RDP_STATUS_OK) {
            status = backend->host.clipboard_offer_event(
                backend->host.context, offer->offer_id,
                MR_RDP_CLIPBOARD_OFFER_DELIVERED, MR_RDP_STATUS_OK);
        }
    } else if (command->kind == MR_RDP_MOCK_COMMAND_IMAGE_REQUEST) {
        status = backend->remote_image_png == NULL
            ? backend->host.clipboard_image(
                  backend->host.context, command->value.clipboard_request_id,
                  MR_RDP_ERROR_UNSUPPORTED, 0u, NULL, 0u)
            : backend->host.clipboard_image(
                  backend->host.context, command->value.clipboard_request_id,
                  MR_RDP_STATUS_OK, MR_RDP_CLIPBOARD_IMAGE_PNG,
                  backend->remote_image_png, backend->remote_image_png_byte_count);
    } else if (command->kind == MR_RDP_MOCK_COMMAND_FILES_REQUEST) {
        if (backend->remote_file_count == 0u) {
            status = backend->host.clipboard_file(
                backend->host.context, command->value.clipboard_request_id,
                MR_RDP_ERROR_UNSUPPORTED, 0u, 0u, 1, NULL, 0u, NULL, 0u);
        } else {
            size_t index;
            status = MR_RDP_STATUS_OK;
            for (index = 0u; index < backend->remote_file_count && status == MR_RDP_STATUS_OK; ++index) {
                const mr_rdp_clipboard_file *file = &backend->remote_files[index];
                status = backend->host.clipboard_file(
                    backend->host.context, command->value.clipboard_request_id,
                    MR_RDP_STATUS_OK, (uint32_t)index, (uint32_t)backend->remote_file_count,
                    index + 1u == backend->remote_file_count,
                    file->name, file->name_length, file->bytes, file->byte_count);
            }
        }
    } else if (command->kind == MR_RDP_MOCK_COMMAND_CLIPBOARD_REQUEST) {
        if (backend->remote_clipboard_utf16le == NULL) {
            status = backend->host.clipboard_text(
                backend->host.context, command->value.clipboard_request_id,
                MR_RDP_ERROR_UNSUPPORTED, NULL, 0u);
        } else {
            status = backend->host.clipboard_text(
                backend->host.context, command->value.clipboard_request_id,
                MR_RDP_STATUS_OK,
                backend->remote_clipboard_utf16le_byte_count == 0u
                    ? NULL : backend->remote_clipboard_utf16le,
                backend->remote_clipboard_utf16le_byte_count);
        }
    } else {
        status = MR_RDP_ERROR_BACKEND;
    }
    mr_mock_command_destroy(command);
    return status;
}

static mr_rdp_status mr_mock_wait_for_command(
    mr_rdp_mock_backend *backend,
    mr_rdp_mock_command *out_command)
{
    (void)pthread_mutex_lock(&backend->mutex);
    while (!backend->stop_requested && backend->command_count == 0u) {
        (void)pthread_cond_wait(&backend->condition, &backend->mutex);
    }
    if (backend->stop_requested) {
        mr_mock_discard_commands_locked(backend);
        (void)pthread_mutex_unlock(&backend->mutex);
        return MR_RDP_ERROR_STOPPED;
    }
    *out_command = backend->commands[backend->command_head];
    memset(&backend->commands[backend->command_head], 0,
           sizeof(backend->commands[backend->command_head]));
    backend->command_head = (backend->command_head + 1u) %
        MR_RDP_MOCK_COMMAND_CAPACITY;
    --backend->command_count;
    (void)pthread_mutex_unlock(&backend->mutex);
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_run(mr_rdp_backend *base)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_status status;
    int wait_status = 0;
    struct timespec deadline;

    if (backend->on_session_config != NULL) {
        backend->on_session_config(
            backend->observer_context,
            backend->config.keyboard_profile,
            backend->config.channel_flags);
    }
    if (backend->on_scale_config != NULL) {
        backend->on_scale_config(
            backend->observer_context,
            backend->config.desktop_scale_factor,
            backend->config.device_scale_factor);
    }
    if (backend->on_security_policy != NULL) {
        backend->on_security_policy(
            backend->observer_context, backend->config.security_policy);
    }
    if (backend->on_connection_config != NULL) {
        mr_rdp_mock_connection_config view;
        memset(&view, 0, sizeof(view));
        view.gateway_hostname = backend->config.gateway_hostname;
        view.gateway_port = backend->config.gateway_port;
        view.gateway_flags = backend->config.gateway_flags;
        view.gateway_username = backend->config.gateway_username;
        view.gateway_domain = backend->config.gateway_domain;
        view.gateway_password = backend->config.gateway_password;
        view.drive_path = backend->config.drive_path;
        view.drive_name = backend->config.drive_name;
        view.proxy_hostname = backend->config.proxy_hostname;
        view.proxy_port = backend->config.proxy_port;
        backend->on_connection_config(backend->observer_context, &view);
    }
    if (backend->on_config != NULL) {
        backend->on_config(
            backend->observer_context,
            backend->config.username,
            backend->config.username_length,
            backend->config.domain,
            backend->config.domain_length,
            backend->config.password,
            backend->config.password_length,
            backend->config.desktop_width,
            backend->config.desktop_height);
    }

    if (backend->delay_before_certificate_ms != 0u) {
        deadline = mr_mock_deadline_after_milliseconds(
            backend->delay_before_certificate_ms);
        (void)pthread_mutex_lock(&backend->mutex);
        while (!backend->stop_requested && wait_status == 0) {
            wait_status = pthread_cond_timedwait(
                &backend->condition, &backend->mutex, &deadline);
        }
        if (backend->stop_requested) {
            (void)pthread_mutex_unlock(&backend->mutex);
            return MR_RDP_ERROR_STOPPED;
        }
        (void)pthread_mutex_unlock(&backend->mutex);
        if (wait_status != 0 && wait_status != ETIMEDOUT) {
            return MR_RDP_ERROR_BACKEND;
        }
    }

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        (void)pthread_mutex_unlock(&backend->mutex);
        return MR_RDP_ERROR_STOPPED;
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    /* A gateway's certificate comes first: the tunnel is up before the
     * computer is reached through it. */
    if (backend->gateway_certificate_chain_count != 0u) {
        status = backend->host.present_certificate(
            backend->host.context,
            MR_RDP_CERTIFICATE_ROLE_GATEWAY,
            backend->gateway_certificate_chain,
            backend->gateway_certificate_chain_count);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }
    if (backend->certificate_chain_count != 0u) {
        status = backend->host.present_certificate(
            backend->host.context,
            MR_RDP_CERTIFICATE_ROLE_SERVER,
            backend->certificate_chain,
            backend->certificate_chain_count);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }

    /* The mock speaks NLA, as the policy's default would have it. */
    status = backend->host.connected(backend->host.context, MR_RDP_TRANSPORT_NLA);
    if (status != MR_RDP_STATUS_OK) {
        return status;
    }

    {
        size_t index;
        for (index = 0u; index < backend->channel_transition_count; ++index) {
            const mr_rdp_mock_channel_transition *transition =
                &backend->channel_transitions[index];
            status = backend->host.channel_event(
                backend->host.context,
                transition->channel,
                transition->transition);
            if (status != MR_RDP_STATUS_OK) {
                return status;
            }
        }
    }

    if (backend->has_desktop_frame) {
        status = backend->host.present_frame(
            backend->host.context, &backend->desktop_frame);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }
    if (backend->cursor_event != NULL) {
        status = backend->host.cursor_event(
            backend->host.context, backend->cursor_event);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }
    if (backend->audio_packet != NULL) {
        int focused;
        (void)pthread_mutex_lock(&backend->mutex);
        focused = backend->audio_focused;
        (void)pthread_mutex_unlock(&backend->mutex);
        /* Models the bridge's focus gate: unfocused PCM never surfaces. */
        if (focused) {
            status = backend->host.audio_packet(
                backend->host.context, backend->audio_packet);
            if (status != MR_RDP_STATUS_OK) {
                return status;
            }
        }
    }
    if (backend->remote_clipboard_utf16le != NULL || backend->remote_image_png != NULL ||
        backend->remote_file_count != 0u) {
        status = backend->host.clipboard_remote_formats(
            backend->host.context,
            backend->remote_clipboard_utf16le != NULL,
            backend->remote_image_png != NULL,
            backend->remote_file_count != 0u);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }
    if ((backend->config.channel_flags & MR_RDP_CHANNEL_FLAG_MACRDPX) != 0u) {
        uint32_t negotiated = 0u;
        size_t index;
        for (index = 0u; index < backend->macrdpx_message_count; ++index) {
            const mrx_message *message = &backend->macrdpx_messages[index];
            if (message->type == MRX_MSG_HELLO) {
                negotiated = mrx_negotiate(backend->config.macrdpx_caps, message->u.hello.caps);
            }
            status = backend->host.macrdpx_message(backend->host.context, message, negotiated);
            if (status != MR_RDP_STATUS_OK) {
                return status;
            }
        }
    }
    if (backend->audio_capture_rate != 0u &&
        (backend->config.channel_flags & MR_RDP_CHANNEL_FLAG_MICROPHONE) != 0u) {
        status = backend->host.audio_capture(
            backend->host.context, 1, backend->audio_capture_rate, 1u, 16u);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }

    for (;;) {
        mr_rdp_mock_command command;
        memset(&command, 0, sizeof(command));
        status = mr_mock_wait_for_command(backend, &command);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
        status = mr_mock_process_command(backend, &command);
        if (status != MR_RDP_STATUS_OK) {
            return status;
        }
    }
}

static void mr_mock_request_stop(mr_rdp_backend *base)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_stop_observer observer;
    void *observer_context;
    (void)pthread_mutex_lock(&backend->mutex);
    backend->stop_requested = 1;
    observer = backend->on_request_stop;
    observer_context = backend->observer_context;
    (void)pthread_cond_broadcast(&backend->condition);
    (void)pthread_mutex_unlock(&backend->mutex);
    if (observer != NULL) {
        observer(observer_context);
    }
}

static mr_rdp_status mr_mock_send_key(
    mr_rdp_backend *base,
    const mr_rdp_key_event *event)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_key_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_key;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, event);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_send_pointer(
    mr_rdp_backend *base,
    const mr_rdp_pointer_event *event)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_pointer_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_pointer;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, event);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_start_clipboard_probe(
    mr_rdp_backend *base,
    const mr_rdp_backend_clipboard_probe *probe)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_command command;
    uint8_t *bytes;
    size_t tail;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (probe == NULL || probe->probe_id == 0u || probe->utf16le_bytes == NULL ||
        probe->utf16le_byte_count < 4u ||
        probe->utf16le_byte_count > MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    bytes = (uint8_t *)malloc(probe->utf16le_byte_count);
    if (bytes == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(bytes, probe->utf16le_bytes, probe->utf16le_byte_count);
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_CLIPBOARD_PROBE;
    command.value.clipboard_probe = *probe;
    command.value.clipboard_probe.utf16le_bytes = bytes;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->command_count >= MR_RDP_MOCK_COMMAND_CAPACITY) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else {
        tail = (backend->command_head + backend->command_count) %
            MR_RDP_MOCK_COMMAND_CAPACITY;
        backend->commands[tail] = command;
        ++backend->command_count;
        (void)pthread_cond_broadcast(&backend->condition);
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (status != MR_RDP_STATUS_OK) {
        mr_mock_command_destroy(&command);
    }
    return status;
}

static mr_rdp_status mr_mock_request_display_resize(
    mr_rdp_backend *base,
    const mr_rdp_display_resize_request *request)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_command command;
    size_t tail;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (request == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_DISPLAY_RESIZE;
    command.value.display_resize = *request;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->command_count >= MR_RDP_MOCK_COMMAND_CAPACITY) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else {
        tail = (backend->command_head + backend->command_count) %
            MR_RDP_MOCK_COMMAND_CAPACITY;
        backend->commands[tail] = command;
        ++backend->command_count;
        (void)pthread_cond_broadcast(&backend->condition);
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return status;
}

static mr_rdp_status mr_mock_enqueue(
    mr_rdp_mock_backend *backend,
    const mr_rdp_mock_command *command)
{
    size_t tail;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->command_count >= MR_RDP_MOCK_COMMAND_CAPACITY) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else {
        tail = (backend->command_head + backend->command_count) %
            MR_RDP_MOCK_COMMAND_CAPACITY;
        backend->commands[tail] = *command;
        ++backend->command_count;
        (void)pthread_cond_broadcast(&backend->condition);
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return status;
}

static mr_rdp_status mr_mock_send_unicode(
    mr_rdp_backend *base,
    const mr_rdp_unicode_event *event)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_unicode_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_unicode;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, event);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_send_touch(
    mr_rdp_backend *base,
    const mr_rdp_touch_event *event)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_touch_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_touch;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, event);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_send_pen(
    mr_rdp_backend *base,
    const mr_rdp_pen_event *event)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_pen_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_pen;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, event);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_send_macrdpx(
    mr_rdp_backend *base,
    const mrx_message *message)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_macrdpx_observer observer;
    void *observer_context;
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    observer = backend->on_send_macrdpx;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (stopped) {
        return MR_RDP_ERROR_STOPPED;
    }
    if (observer != NULL) {
        observer(observer_context, message);
    }
    return MR_RDP_STATUS_OK;
}

static void mr_mock_set_audio_focused(mr_rdp_backend *base, int focused)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_audio_focus_observer observer;
    void *observer_context;
    (void)pthread_mutex_lock(&backend->mutex);
    backend->audio_focused = focused != 0;
    observer = backend->on_set_audio_focused;
    observer_context = backend->observer_context;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (observer != NULL) {
        observer(observer_context, focused != 0);
    }
}

static mr_rdp_status mr_mock_offer_clipboard_text(
    mr_rdp_backend *base,
    const mr_rdp_backend_clipboard_offer *offer)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    mr_rdp_mock_command command;
    uint8_t *bytes;
    mr_rdp_status status;
    if (offer == NULL || offer->utf16le_bytes == NULL ||
        offer->utf16le_byte_count == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    bytes = (uint8_t *)malloc(offer->utf16le_byte_count);
    if (bytes == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(bytes, offer->utf16le_bytes, offer->utf16le_byte_count);
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_CLIPBOARD_OFFER;
    command.value.clipboard_offer = *offer;
    command.value.clipboard_offer.utf16le_bytes = bytes;
    status = mr_mock_enqueue(backend, &command);
    if (status != MR_RDP_STATUS_OK) {
        mr_mock_command_destroy(&command);
    }
    return status;
}

static mr_rdp_status mr_mock_request_clipboard_text(
    mr_rdp_backend *base,
    uint64_t request_id)
{
    mr_rdp_mock_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_CLIPBOARD_REQUEST;
    command.value.clipboard_request_id = request_id;
    return mr_mock_enqueue((mr_rdp_mock_backend *)base, &command);
}

static mr_rdp_status mr_mock_request_clipboard_image(
    mr_rdp_backend *base,
    uint64_t request_id)
{
    mr_rdp_mock_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_IMAGE_REQUEST;
    command.value.clipboard_request_id = request_id;
    return mr_mock_enqueue((mr_rdp_mock_backend *)base, &command);
}

static mr_rdp_status mr_mock_request_clipboard_files(
    mr_rdp_backend *base,
    uint64_t request_id)
{
    mr_rdp_mock_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_RDP_MOCK_COMMAND_FILES_REQUEST;
    command.value.clipboard_request_id = request_id;
    return mr_mock_enqueue((mr_rdp_mock_backend *)base, &command);
}

/* Offers are observed synchronously: the bridge has validated them and the
 * views are valid for this call, which is all an observer needs. */
static mr_rdp_status mr_mock_offer_clipboard_image(
    mr_rdp_backend *base,
    const mr_rdp_clipboard_image_offer *offer)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    if (backend->on_offer_clipboard_image != NULL) {
        backend->on_offer_clipboard_image(backend->observer_context, offer);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_offer_clipboard_files(
    mr_rdp_backend *base,
    const mr_rdp_clipboard_files_offer *offer)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    if (backend->on_offer_clipboard_files != NULL) {
        backend->on_offer_clipboard_files(backend->observer_context, offer);
    }
    return MR_RDP_STATUS_OK;
}

static mr_rdp_status mr_mock_send_audio_capture(
    mr_rdp_backend *base,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    if (backend->on_send_audio_capture != NULL) {
        backend->on_send_audio_capture(backend->observer_context, bytes, byte_count);
    }
    return MR_RDP_STATUS_OK;
}

static void mr_mock_destroy(mr_rdp_backend *base)
{
    mr_rdp_mock_backend *backend = (mr_rdp_mock_backend *)base;
    (void)pthread_mutex_lock(&backend->mutex);
    mr_mock_discard_commands_locked(backend);
    (void)pthread_mutex_unlock(&backend->mutex);
    free(backend->certificate_chain);
    free(backend->gateway_certificate_chain);
    free(backend->channel_transitions);
    mr_mock_owned_config_destroy(&backend->config);
    (void)pthread_cond_destroy(&backend->condition);
    (void)pthread_mutex_destroy(&backend->mutex);
    memset(backend, 0, sizeof(*backend));
    free(backend);
}

static const mr_rdp_backend_vtable mr_mock_vtable = {
    .run = mr_mock_run,
    .request_stop = mr_mock_request_stop,
    .send_key = mr_mock_send_key,
    .send_pointer = mr_mock_send_pointer,
    .start_clipboard_probe = mr_mock_start_clipboard_probe,
    .request_display_resize = mr_mock_request_display_resize,
    .send_unicode = mr_mock_send_unicode,
    .set_audio_focused = mr_mock_set_audio_focused,
    .offer_clipboard_text = mr_mock_offer_clipboard_text,
    .request_clipboard_text = mr_mock_request_clipboard_text,
    .offer_clipboard_image = mr_mock_offer_clipboard_image,
    .offer_clipboard_files = mr_mock_offer_clipboard_files,
    .request_clipboard_image = mr_mock_request_clipboard_image,
    .request_clipboard_files = mr_mock_request_clipboard_files,
    .send_audio_capture = mr_mock_send_audio_capture,
    .send_touch = mr_mock_send_touch,
    .send_pen = mr_mock_send_pen,
    .send_macrdpx = mr_mock_send_macrdpx,
    .destroy = mr_mock_destroy
};

static mr_rdp_status mr_mock_backend_create(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend)
{
    const mr_rdp_mock_script *script = (const mr_rdp_mock_script *)factory_context;
    mr_rdp_mock_backend *backend;
    int mutex_initialized = 0;

    if (config == NULL || host == NULL || host->present_certificate == NULL ||
        host->connected == NULL || host->present_frame == NULL ||
        host->channel_event == NULL || host->clipboard_probe_event == NULL ||
        host->display_resize_event == NULL || host->cursor_event == NULL ||
        host->audio_packet == NULL || host->clipboard_remote_formats == NULL ||
        host->clipboard_offer_event == NULL || host->clipboard_text == NULL ||
        host->clipboard_image == NULL || host->clipboard_file == NULL ||
        host->audio_capture == NULL || host->macrdpx_message == NULL ||
        script == NULL || out_backend == NULL ||
        script->struct_size < sizeof(*script) ||
        script->certificate_chain_count > MR_RDP_MAX_CERTIFICATE_CHAIN + 1u ||
        script->gateway_certificate_chain_count > MR_RDP_MAX_CERTIFICATE_CHAIN + 1u ||
        ((script->gateway_certificate_chain == NULL) !=
         (script->gateway_certificate_chain_count == 0u)) ||
        script->channel_transition_count > MR_RDP_MOCK_MAX_CHANNEL_TRANSITIONS ||
        ((script->channel_transitions == NULL) !=
         (script->channel_transition_count == 0u))) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    {
        size_t index;
        for (index = 0u; index < script->channel_transition_count; ++index) {
            const mr_rdp_mock_channel_transition *transition =
                &script->channel_transitions[index];
            if (transition->channel < MR_RDP_CHANNEL_CLIPRDR ||
                transition->channel > MR_RDP_CHANNEL_RAIL ||
                transition->transition > MR_RDP_CHANNEL_CONNECTED ||
                transition->reserved[0] != 0u || transition->reserved[1] != 0u ||
                transition->reserved[2] != 0u || transition->reserved[3] != 0u ||
                transition->reserved[4] != 0u || transition->reserved[5] != 0u) {
                return MR_RDP_ERROR_INVALID_ARGUMENT;
            }
        }
    }
    *out_backend = NULL;
    backend = (mr_rdp_mock_backend *)calloc(1u, sizeof(*backend));
    if (backend == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    if (pthread_mutex_init(&backend->mutex, NULL) != 0) {
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    mutex_initialized = 1;
    if (pthread_cond_init(&backend->condition, NULL) != 0) {
        if (mutex_initialized) {
            (void)pthread_mutex_destroy(&backend->mutex);
        }
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    {
        const mr_rdp_status copy_status = mr_mock_owned_config_copy(
            config, &backend->config);
        if (copy_status != MR_RDP_STATUS_OK) {
            (void)pthread_cond_destroy(&backend->condition);
            (void)pthread_mutex_destroy(&backend->mutex);
            free(backend);
            return copy_status;
        }
    }
    if (script->certificate_chain != NULL &&
        script->certificate_chain_count != 0u) {
        backend->certificate_chain = (mr_rdp_der_blob *)calloc(
            script->certificate_chain_count, sizeof(*backend->certificate_chain));
        if (backend->certificate_chain == NULL) {
            mr_mock_owned_config_destroy(&backend->config);
            (void)pthread_cond_destroy(&backend->condition);
            (void)pthread_mutex_destroy(&backend->mutex);
            free(backend);
            return MR_RDP_ERROR_OUT_OF_MEMORY;
        }
        memcpy(backend->certificate_chain, script->certificate_chain,
               script->certificate_chain_count * sizeof(*backend->certificate_chain));
    }
    if (script->channel_transition_count != 0u) {
        backend->channel_transitions = (mr_rdp_mock_channel_transition *)calloc(
            script->channel_transition_count, sizeof(*backend->channel_transitions));
        if (backend->channel_transitions == NULL) {
            free(backend->certificate_chain);
            mr_mock_owned_config_destroy(&backend->config);
            (void)pthread_cond_destroy(&backend->condition);
            (void)pthread_mutex_destroy(&backend->mutex);
            free(backend);
            return MR_RDP_ERROR_OUT_OF_MEMORY;
        }
        memcpy(backend->channel_transitions, script->channel_transitions,
               script->channel_transition_count * sizeof(*backend->channel_transitions));
    }
    if (script->gateway_certificate_chain_count != 0u) {
        backend->gateway_certificate_chain = (mr_rdp_der_blob *)calloc(
            script->gateway_certificate_chain_count, sizeof(*backend->gateway_certificate_chain));
        if (backend->gateway_certificate_chain == NULL) {
            free(backend->channel_transitions);
            free(backend->certificate_chain);
            mr_mock_owned_config_destroy(&backend->config);
            (void)pthread_cond_destroy(&backend->condition);
            (void)pthread_mutex_destroy(&backend->mutex);
            free(backend);
            return MR_RDP_ERROR_OUT_OF_MEMORY;
        }
        memcpy(backend->gateway_certificate_chain, script->gateway_certificate_chain,
               script->gateway_certificate_chain_count *
                   sizeof(*backend->gateway_certificate_chain));
        backend->gateway_certificate_chain_count = script->gateway_certificate_chain_count;
    }
    backend->base.vtable = &mr_mock_vtable;
    backend->host = *host;
    backend->certificate_chain_count = script->certificate_chain_count;
    backend->delay_before_certificate_ms = script->delay_before_certificate_ms;
    backend->observer_context = script->observer_context;
    backend->on_request_stop = script->on_request_stop;
    backend->on_send_key = script->on_send_key;
    backend->on_send_pointer = script->on_send_pointer;
    backend->on_config = script->on_config;
    backend->on_start_clipboard_probe = script->on_start_clipboard_probe;
    backend->on_request_display_resize = script->on_request_display_resize;
    backend->on_send_unicode = script->on_send_unicode;
    backend->on_set_audio_focused = script->on_set_audio_focused;
    backend->on_session_config = script->on_session_config;
    backend->on_offer_clipboard_text = script->on_offer_clipboard_text;
    backend->on_scale_config = script->on_scale_config;
    backend->on_security_policy = script->on_security_policy;
    backend->on_send_touch = script->on_send_touch;
    backend->on_send_pen = script->on_send_pen;
    backend->macrdpx_messages = script->macrdpx_messages;
    backend->macrdpx_message_count = script->macrdpx_message_count;
    backend->on_send_macrdpx = script->on_send_macrdpx;
    backend->on_connection_config = script->on_connection_config;
    backend->remote_image_png = script->remote_image_png;
    backend->remote_image_png_byte_count = script->remote_image_png_byte_count;
    backend->remote_files = script->remote_files;
    backend->remote_file_count = script->remote_file_count;
    backend->audio_capture_rate = script->audio_capture_rate;
    backend->on_offer_clipboard_image = script->on_offer_clipboard_image;
    backend->on_offer_clipboard_files = script->on_offer_clipboard_files;
    backend->on_send_audio_capture = script->on_send_audio_capture;
    backend->cursor_event = script->cursor_event;
    backend->audio_packet = script->audio_packet;
    backend->remote_clipboard_utf16le = script->remote_clipboard_utf16le;
    backend->remote_clipboard_utf16le_byte_count =
        script->remote_clipboard_utf16le_byte_count;
    backend->channel_transition_count = script->channel_transition_count;
    if (script->desktop_frame != NULL) {
        backend->desktop_frame = *script->desktop_frame;
        backend->has_desktop_frame = 1;
    }
    *out_backend = &backend->base;
    return MR_RDP_STATUS_OK;
}

void mr_rdp_mock_script_init(mr_rdp_mock_script *script)
{
    if (script == NULL) {
        return;
    }
    memset(script, 0, sizeof(*script));
    script->struct_size = (uint32_t)sizeof(*script);
}

mr_rdp_status mr_rdp_session_create_mock(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    const mr_rdp_mock_script *script,
    mr_rdp_session **out_session)
{
    mr_rdp_mock_script default_script;
    if (script == NULL) {
        mr_rdp_mock_script_init(&default_script);
        script = &default_script;
    }
    return mr_rdp_session_create_internal(
        config, callbacks, context, mr_mock_backend_create, script, out_session);
}
