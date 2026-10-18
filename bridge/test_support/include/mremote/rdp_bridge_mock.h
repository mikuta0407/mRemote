#ifndef MREMOTE_RDP_BRIDGE_MOCK_H
#define MREMOTE_RDP_BRIDGE_MOCK_H

#include "mremote/rdp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mr_rdp_mock_stop_observer)(void *context);
typedef void (*mr_rdp_mock_key_observer)(
    void *context,
    const mr_rdp_key_event *event);
typedef void (*mr_rdp_mock_pointer_observer)(
    void *context,
    const mr_rdp_pointer_event *event);
typedef void (*mr_rdp_mock_clipboard_probe_observer)(
    void *context,
    uint64_t probe_id,
    const uint8_t *utf16le_bytes,
    size_t utf16le_byte_count,
    const uint8_t payload_sha256[MR_RDP_SHA256_BYTES]);
typedef void (*mr_rdp_mock_display_resize_observer)(
    void *context,
    const mr_rdp_display_resize_request *request);
typedef void (*mr_rdp_mock_config_observer)(
    void *context,
    const char *username,
    size_t username_length,
    const char *domain,
    size_t domain_length,
    const char *password,
    size_t password_length,
    uint32_t desktop_width,
    uint32_t desktop_height);

typedef void (*mr_rdp_mock_unicode_observer)(
    void *context,
    const mr_rdp_unicode_event *event);
typedef void (*mr_rdp_mock_audio_focus_observer)(void *context, int focused);
typedef void (*mr_rdp_mock_session_config_observer)(
    void *context,
    mr_rdp_keyboard_profile keyboard_profile,
    mr_rdp_channel_flags channel_flags);
typedef void (*mr_rdp_mock_scale_observer)(
    void *context,
    uint32_t desktop_scale_factor,
    uint32_t device_scale_factor);
typedef void (*mr_rdp_mock_security_observer)(
    void *context,
    mr_rdp_security_policy policy);
typedef void (*mr_rdp_mock_clipboard_offer_observer)(
    void *context,
    uint64_t offer_id,
    const uint8_t *utf16le_bytes,
    size_t utf16le_byte_count);

/* ABI 4. */
typedef void (*mr_rdp_mock_touch_observer)(
    void *context,
    const mr_rdp_touch_event *event);
typedef void (*mr_rdp_mock_pen_observer)(
    void *context,
    const mr_rdp_pen_event *event);
/* The backend's copy of what it was created with, at run: gateway and
 * drive. Passwords are already cleared from the session's own copy. */
typedef struct mr_rdp_mock_connection_config {
    const char *gateway_hostname;
    uint16_t gateway_port;
    mr_rdp_gateway_flags gateway_flags;
    const char *gateway_username;
    const char *gateway_domain;
    const char *gateway_password;
    const char *drive_path;
    const char *drive_name;
    /* ABI 7. NULL for no proxy. */
    const char *proxy_hostname;
    uint16_t proxy_port;
} mr_rdp_mock_connection_config;
typedef void (*mr_rdp_mock_connection_observer)(
    void *context,
    const mr_rdp_mock_connection_config *config);

/* ABI 5. */
typedef void (*mr_rdp_mock_image_offer_observer)(
    void *context,
    const mr_rdp_clipboard_image_offer *offer);
typedef void (*mr_rdp_mock_files_offer_observer)(
    void *context,
    const mr_rdp_clipboard_files_offer *offer);
typedef void (*mr_rdp_mock_capture_observer)(
    void *context,
    const uint8_t *bytes,
    size_t byte_count);

/* ABI 6. */
typedef void (*mr_rdp_mock_macrdpx_observer)(
    void *context,
    const mrx_message *message);

typedef struct mr_rdp_mock_channel_transition {
    mr_rdp_channel_kind channel;
    mr_rdp_channel_transition transition;
    uint8_t reserved[6];
} mr_rdp_mock_channel_transition;

typedef struct mr_rdp_mock_script {
    uint32_t struct_size;
    uint32_t delay_before_certificate_ms;
    const mr_rdp_der_blob *certificate_chain;
    size_t certificate_chain_count;
    void *observer_context;
    mr_rdp_mock_stop_observer on_request_stop;
    mr_rdp_mock_key_observer on_send_key;
    mr_rdp_mock_pointer_observer on_send_pointer;
    mr_rdp_mock_config_observer on_config;
    const mr_rdp_desktop_frame *desktop_frame;
    const mr_rdp_mock_channel_transition *channel_transitions;
    size_t channel_transition_count;
    mr_rdp_mock_clipboard_probe_observer on_start_clipboard_probe;
    mr_rdp_mock_display_resize_observer on_request_display_resize;
    /* ABI 2. The cursor and audio views are borrowed through run returning
     * and emitted once each after the desktop frame. A non-NULL remote
     * clipboard announces text after connect and answers every request with
     * it (count 0 with a non-NULL pointer answers with empty text). */
    mr_rdp_mock_unicode_observer on_send_unicode;
    mr_rdp_mock_audio_focus_observer on_set_audio_focused;
    mr_rdp_mock_session_config_observer on_session_config;
    mr_rdp_mock_clipboard_offer_observer on_offer_clipboard_text;
    const mr_rdp_cursor_event *cursor_event;
    const mr_rdp_audio_packet *audio_packet;
    const uint8_t *remote_clipboard_utf16le;
    size_t remote_clipboard_utf16le_byte_count;
    /* ABI 3. Called at run with the scale factors the session was created
     * with. */
    mr_rdp_mock_scale_observer on_scale_config;
    /* ABI 3. Called at run with the session's security policy. */
    mr_rdp_mock_security_observer on_security_policy;
    /* ABI 4. */
    mr_rdp_mock_touch_observer on_send_touch;
    mr_rdp_mock_pen_observer on_send_pen;
    mr_rdp_mock_connection_observer on_connection_config;
    /* Presented with the gateway role before the server's chain. */
    const mr_rdp_der_blob *gateway_certificate_chain;
    size_t gateway_certificate_chain_count;
    /* ABI 5. The remote clipboard's image (always offered as PNG) and files,
     * borrowed through run returning; the microphone opens at this rate
     * after connecting when the session asked for it (zero: never). */
    const uint8_t *remote_image_png;
    size_t remote_image_png_byte_count;
    const mr_rdp_clipboard_file *remote_files;
    size_t remote_file_count;
    uint32_t audio_capture_rate;
    mr_rdp_mock_image_offer_observer on_offer_clipboard_image;
    mr_rdp_mock_files_offer_observer on_offer_clipboard_files;
    mr_rdp_mock_capture_observer on_send_audio_capture;
    /* ABI 6. With MACRDPX in the session's flags: the server messages
     * emitted after connect, in order (a server HELLO first, normally), with
     * the caps negotiated from the session's offer and the HELLO's. Borrowed
     * through run returning. */
    const mrx_message *macrdpx_messages;
    size_t macrdpx_message_count;
    mr_rdp_mock_macrdpx_observer on_send_macrdpx;
} mr_rdp_mock_script;

void mr_rdp_mock_script_init(mr_rdp_mock_script *script);

/*
 * Test-only backend injection. Blob and desktop-frame descriptors are copied
 * at create, while their byte buffers and dirty rectangles are borrowed
 * through run returning. This deliberately models callback-scoped
 * FreeRDP/OpenSSL/GDI memory: the bridge deep-copies DER, while frame consumers
 * must copy the validated framebuffer view during their callback.
 */
mr_rdp_status mr_rdp_session_create_mock(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    const mr_rdp_mock_script *script,
    mr_rdp_session **out_session);

#ifdef __cplusplus
}
#endif

#endif
