#ifndef MREMOTE_RDP_BRIDGE_H
#define MREMOTE_RDP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

/* ABI 6. The MACRDPX message types (external/macrdpx), shared with
 * macos-rdp-server. */
#include <macrdpx/macrdpx.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MR_RDP_BRIDGE_ABI_VERSION 7u
#define MR_RDP_DEFAULT_PORT 3389u
#define MR_RDP_DEFAULT_CERTIFICATE_TIMEOUT_MS 30000u
#define MR_RDP_MAX_CERTIFICATE_CHAIN 16u
#define MR_RDP_MAX_CERTIFICATE_DER_BYTES (1024u * 1024u)
#define MR_RDP_MAX_CERTIFICATE_CHAIN_BYTES (4u * 1024u * 1024u)
#define MR_RDP_MAX_USERNAME_BYTES 1024u
#define MR_RDP_MAX_DOMAIN_BYTES 1024u
#define MR_RDP_MAX_PASSWORD_BYTES 4096u
#define MR_RDP_DEFAULT_DESKTOP_WIDTH 1280u
#define MR_RDP_DEFAULT_DESKTOP_HEIGHT 720u
#define MR_RDP_MIN_DESKTOP_DIMENSION 200u
#define MR_RDP_MAX_DESKTOP_DIMENSION 8192u
/* MS-RDPBCGR 2.2.1.3.2: the desktop scale factor is a percentage in
 * [100, 500] and the device scale factor one of 100, 140 or 180. */
#define MR_RDP_DEFAULT_SCALE_FACTOR 100u
#define MR_RDP_MIN_DESKTOP_SCALE_FACTOR 100u
#define MR_RDP_MAX_DESKTOP_SCALE_FACTOR 500u
#define MR_RDP_MAX_DESKTOP_FRAME_BYTES (512u * 1024u * 1024u)
#define MR_RDP_MAX_DESKTOP_DIRTY_RECTS 512u
#define MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES (64u * 1024u)
#define MR_RDP_MAX_WHEEL_DELTA 32767
#define MR_RDP_SHA256_BYTES 32u
#define MR_RDP_MAX_CURSOR_DIMENSION 384u
#define MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES (4u * 1024u * 1024u)
#define MR_RDP_CLIPBOARD_REQUEST_TIMEOUT_MS 10000u
/* ABI 4. */
#define MR_RDP_DEFAULT_GATEWAY_PORT 443u
#define MR_RDP_MAX_DRIVE_PATH_BYTES 4096u
#define MR_RDP_MAX_DRIVE_NAME_BYTES 64u
/* Both monitors side by side, as one desktop. */
#define MR_RDP_MAX_VIRTUAL_DESKTOP_WIDTH 16384u
#define MR_RDP_MAX_TOUCH_CONTACT_ID 255u
#define MR_RDP_MAX_PEN_PRESSURE 1024u
/* ABI 5. */
#define MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES (64u * 1024u * 1024u)
#define MR_RDP_MAX_CLIPBOARD_FILES 256u
#define MR_RDP_MAX_CLIPBOARD_FILES_BYTES (256u * 1024u * 1024u)
#define MR_RDP_MAX_CLIPBOARD_FILE_NAME_BYTES 1024u
#define MR_RDP_MAX_REMOTE_PROGRAM_BYTES 1024u
#define MR_RDP_MAX_AUDIO_CAPTURE_PACKET_BYTES (64u * 1024u)
/* ABI 7. */
#define MR_RDP_DEFAULT_PROXY_PORT 1080u

typedef struct mr_rdp_session mr_rdp_session;
typedef int32_t mr_rdp_status;

enum {
    MR_RDP_STATUS_OK = 0,
    MR_RDP_ERROR_INVALID_ARGUMENT = -1,
    MR_RDP_ERROR_OUT_OF_MEMORY = -2,
    MR_RDP_ERROR_INVALID_STATE = -3,
    MR_RDP_ERROR_STOPPED = -4,
    MR_RDP_ERROR_TIMEOUT = -5,
    MR_RDP_ERROR_STALE_CHALLENGE = -6,
    MR_RDP_ERROR_BACKEND_UNAVAILABLE = -7,
    MR_RDP_ERROR_BACKEND = -8,
    MR_RDP_ERROR_INVALID_DATA = -9,
    MR_RDP_ERROR_LIMIT_EXCEEDED = -10,
    MR_RDP_ERROR_CERTIFICATE_REJECTED = -11,
    MR_RDP_ERROR_UNSUPPORTED = -12
};

typedef uint32_t mr_rdp_session_state;
enum {
    MR_RDP_SESSION_CREATED = 0,
    MR_RDP_SESSION_CONNECTING = 1,
    MR_RDP_SESSION_AWAITING_CERTIFICATE = 2,
    MR_RDP_SESSION_CONNECTED = 3,
    MR_RDP_SESSION_STOPPING = 4,
    MR_RDP_SESSION_STOPPED = 5,
    MR_RDP_SESSION_FAILED = 6
};

/* ABI 3. Which transport security the client may agree to. */
typedef uint32_t mr_rdp_security_policy;
enum {
    /* NLA (CredSSP over TLS), or TLS with the server's own logon screen. */
    MR_RDP_SECURITY_SECURE_AUTOMATIC = 1,
    MR_RDP_SECURITY_NLA_REQUIRED = 2,
    MR_RDP_SECURITY_TLS_REQUIRED = 3,
    /* Also the legacy RDP Security Layer: weak encryption and no server
     * certificate to verify. Only ever by explicit per-profile consent. */
    MR_RDP_SECURITY_LEGACY_ALLOWED = 4
};

typedef uint32_t mr_rdp_keyboard_profile;
enum {
    /* Windows Japanese layout 0x411, keyboard type 7 (106/109). The only
     * profile under which Eisu/Kana -> NonConvert/Convert is promised. */
    MR_RDP_KEYBOARD_JAPANESE = 1,
    /* Windows US layout 0x409, keyboard type 4 (101/102). */
    MR_RDP_KEYBOARD_US = 2,
    /* Layout 0: the server keeps the user's own default. */
    MR_RDP_KEYBOARD_AUTOMATIC = 3
};

typedef uint32_t mr_rdp_channel_flags;
enum {
    MR_RDP_CHANNEL_FLAG_AUDIO = 1u << 0,
    MR_RDP_CHANNEL_FLAG_CLIPBOARD = 1u << 1,
    /* ABI 4. One local folder shared as a drive (drive_path/drive_name). */
    MR_RDP_CHANNEL_FLAG_DRIVE = 1u << 2,
    /* ABI 4. Touch and pen input (RDPEI). */
    MR_RDP_CHANNEL_FLAG_TOUCH = 1u << 3,
    /* ABI 5. The microphone (audin): the app is told when the server opens
     * it and feeds PCM with mr_rdp_session_send_audio_capture. */
    MR_RDP_CHANNEL_FLAG_MICROPHONE = 1u << 4,
    /* ABI 5. H.264 (AVC420) graphics, decoded with VideoToolbox. */
    MR_RDP_CHANNEL_FLAG_H264 = 1u << 5,
    /* ABI 6. Join the MACRDPX static channel (Mac RDP eXtensions) and offer
     * config.macrdpx_caps to a server that opens it. Servers that don't know
     * the channel ignore it. */
    MR_RDP_CHANNEL_FLAG_MACRDPX = 1u << 6
};

/* ABI 4. */
typedef uint16_t mr_rdp_gateway_flags;
enum {
    /* The gateway takes the computer's credentials; gateway_username,
     * gateway_domain and gateway_password must then be absent. */
    MR_RDP_GATEWAY_FLAG_SAME_CREDENTIALS = 1u << 0,
    /* Hosts on the local network are reached without the gateway. */
    MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL = 1u << 1
};

/* ABI 7. */
typedef uint16_t mr_rdp_proxy_type;
enum {
    MR_RDP_PROXY_NONE = 0,
    /* RFC 1928, CONNECT, without a sign-in. */
    MR_RDP_PROXY_SOCKS5 = 1
};

typedef struct mr_rdp_config {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t generation;
    const char *hostname;
    uint16_t port;
    uint16_t reserved;
    uint32_t certificate_timeout_ms;
    uint32_t desktop_width;
    uint32_t desktop_height;
    const char *username;
    size_t username_length;
    const char *domain;
    size_t domain_length;
    const char *password;
    size_t password_length;
    mr_rdp_keyboard_profile keyboard_profile;
    mr_rdp_channel_flags channel_flags;
    /* ABI 3. */
    uint32_t desktop_scale_factor;
    uint32_t device_scale_factor;
    mr_rdp_security_policy security_policy;
    uint32_t reserved_abi3;
    /* ABI 4. */
    const char *gateway_hostname;
    uint16_t gateway_port;
    mr_rdp_gateway_flags gateway_flags;
    uint32_t reserved_abi4;
    const char *gateway_username;
    size_t gateway_username_length;
    const char *gateway_domain;
    size_t gateway_domain_length;
    const char *gateway_password;
    size_t gateway_password_length;
    const char *drive_path;
    size_t drive_path_length;
    const char *drive_name;
    size_t drive_name_length;
    /* ABI 5. RemoteApp: the program (an alias such as "||notepad" or a
     * path) and its arguments, or NULL for a whole desktop. */
    const char *remote_program;
    size_t remote_program_length;
    const char *remote_arguments;
    size_t remote_arguments_length;
    /* ABI 6. The MACRDPX features (MRX_CAP_*) offered in the client HELLO;
     * non-zero exactly when channel_flags has MR_RDP_CHANNEL_FLAG_MACRDPX. */
    uint32_t macrdpx_caps;
    uint32_t reserved_abi6;
    /* ABI 7. A proxy every connection of the session goes through. */
    mr_rdp_proxy_type proxy_type;
    uint16_t proxy_port;
    uint32_t reserved_abi7;
    const char *proxy_hostname;
    /* Reserved for a sign-in at the proxy (RFC 1929): NULL/0. */
    const char *proxy_username;
    size_t proxy_username_length;
    const char *proxy_password;
    size_t proxy_password_length;
} mr_rdp_config;

/* ABI 7: with MR_RDP_PROXY_SOCKS5, proxy_hostname is a NUL-terminated name or
 * IP literal of at most 253 bytes, reached on proxy_port (zero selects 1080).
 * The computer, and a gateway when there is one, are then reached through the
 * proxy, which resolves their names: the device does not. With
 * MR_RDP_PROXY_NONE, proxy_hostname is NULL and proxy_port zero. Other types,
 * a sign-in, and a non-zero reserved_abi7 are rejected. A proxy that cannot
 * be reached, or will not connect, fails the connect as FreeRDP reports it
 * (MR_RDP_ERROR_BACKEND with its connect error). */

/* ABI 5: remote_program is a span of 1...MR_RDP_MAX_REMOTE_PROGRAM_BYTES with
 * no embedded NUL, or NULL/0; remote_arguments likewise, and only with a
 * program. A RemoteApp session draws without the graphics pipeline: the
 * server paints the program's windows on an otherwise black desktop. */

/* ABI 4: gateway_hostname is NULL for a direct connection; otherwise a
 * NUL-terminated name of at most 253 bytes, reached on gateway_port (zero
 * selects 443) over HTTPS or RPC. Unless SAME_CREDENTIALS is set, the
 * gateway username and password are non-empty spans with the same rules as
 * the computer's, and the domain is absent only as NULL/0; with it they must
 * all be NULL/0. gateway_flags without a hostname, and unknown flags, are
 * rejected. reserved_abi4 must be zero.
 *
 * drive_path and drive_name are present exactly when channel_flags has
 * MR_RDP_CHANNEL_FLAG_DRIVE: an absolute path of at most
 * MR_RDP_MAX_DRIVE_PATH_BYTES, and a name of 1...MR_RDP_MAX_DRIVE_NAME_BYTES
 * printable ASCII bytes other than '\\', '/', ':', '*', '?', '"', '<', '>',
 * '|' and ';', which is what the server shows the drive as. */

/* desktop_scale_factor and device_scale_factor are ABI 3: how large the
 * server should draw, sent with the core data at connect and with every
 * monitor layout. config_init selects 100 for both, the size servers assume
 * without them. security_policy is ABI 3 too; config_init selects
 * MR_RDP_SECURITY_SECURE_AUTOMATIC, and reserved_abi3 must be zero. */

/* keyboard_profile and channel_flags are ABI 2. config_init selects the
 * Japanese profile and enables audio and clipboard; a cleared flag keeps that
 * channel from being loaded at all rather than loaded and ignored. */

/* username/domain/password are borrowed byte spans used only during create;
 * their lengths exclude any trailing NUL. Username and password must be
 * non-empty, domain is absent only as NULL/0, and embedded NUL bytes are
 * rejected. A trailing NUL is optional because the bridge appends its own.
 * generation zero is reserved and rejected. */

typedef struct mr_rdp_der_blob {
    const uint8_t *bytes;
    size_t length;
} mr_rdp_der_blob;

/* ABI 4. Whose certificate a challenge is about. */
typedef uint32_t mr_rdp_certificate_role;
enum {
    MR_RDP_CERTIFICATE_ROLE_SERVER = 0,
    MR_RDP_CERTIFICATE_ROLE_GATEWAY = 1
};

typedef struct mr_rdp_certificate_challenge {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    uint64_t challenge_id;
    const char *hostname;
    size_t hostname_length;
    uint16_t port;
    uint16_t reserved2;
    /* ABI 4; reserved3 before it. For the gateway, hostname and port are
     * the gateway's. */
    mr_rdp_certificate_role role;
    const mr_rdp_der_blob *chain;
    size_t chain_count;
} mr_rdp_certificate_challenge;

/* chain[0] is the leaf; remaining blobs are issuer certificates in backend
 * order. Every blob is one complete DER-encoded X.509 certificate. */

typedef uint8_t mr_rdp_certificate_decision;
enum {
    MR_RDP_CERTIFICATE_REJECT = 0,
    MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST = 1,
    MR_RDP_CERTIFICATE_ACCEPT_USER_ONCE = 2,
    MR_RDP_CERTIFICATE_ACCEPT_PIN = 3
};

/* ABI 3. What protects the connection, as the server selected it. */
typedef uint32_t mr_rdp_transport_security;
enum {
    MR_RDP_TRANSPORT_UNKNOWN = 0,
    MR_RDP_TRANSPORT_NLA = 1,
    MR_RDP_TRANSPORT_TLS = 2,
    /* The legacy RDP Security Layer: only ever under
     * MR_RDP_SECURITY_LEGACY_ALLOWED. */
    MR_RDP_TRANSPORT_LEGACY_RDP = 3
};

typedef struct mr_rdp_state_event {
    uint32_t struct_size;
    mr_rdp_session_state state;
    uint64_t generation;
    /* ABI 3. Set with MR_RDP_SESSION_CONNECTED, UNKNOWN otherwise. */
    mr_rdp_transport_security transport_security;
    uint32_t reserved;
} mr_rdp_state_event;

typedef struct mr_rdp_error_event {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    mr_rdp_status status;
    int32_t native_code;
} mr_rdp_error_event;

typedef struct mr_rdp_rect {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
} mr_rdp_rect;

typedef struct mr_rdp_desktop_frame {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    uint64_t surface_generation;
    uint64_t frame_id;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t reserved2;
    const uint8_t *bytes;
    size_t length;
    const mr_rdp_rect *dirty_rects;
    size_t dirty_rect_count;
} mr_rdp_desktop_frame;

typedef uint8_t mr_rdp_channel_kind;
enum {
    MR_RDP_CHANNEL_CLIPRDR = 1,
    MR_RDP_CHANNEL_RDPSND = 2,
    MR_RDP_CHANNEL_DRDYNVC = 3,
    MR_RDP_CHANNEL_DISP = 4,
    MR_RDP_CHANNEL_RDPGFX = 5,
    /* ABI 4. */
    MR_RDP_CHANNEL_RDPEI = 6,
    MR_RDP_CHANNEL_RDPDR = 7,
    /* ABI 5. */
    MR_RDP_CHANNEL_AUDIN = 8,
    MR_RDP_CHANNEL_RAIL = 9,
    /* ABI 6. */
    MR_RDP_CHANNEL_MACRDPX = 10
};

typedef uint8_t mr_rdp_channel_transition;
enum {
    MR_RDP_CHANNEL_DISCONNECTED = 0,
    MR_RDP_CHANNEL_CONNECTED = 1
};

typedef struct mr_rdp_channel_event {
    uint32_t struct_size;
    mr_rdp_channel_kind channel;
    mr_rdp_channel_transition transition;
    uint16_t reserved;
    uint64_t generation;
    uint64_t sequence;
} mr_rdp_channel_event;

typedef struct mr_rdp_clipboard_probe {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t probe_id;
    const uint8_t *utf16le_bytes;
    size_t utf16le_byte_count;
} mr_rdp_clipboard_probe;

/* utf16le_bytes contains at least one non-NUL code unit and includes exactly
 * one trailing U+0000 code unit. Embedded NUL,
 * unpaired UTF-16 surrogates, odd lengths, and over-limit payloads are
 * rejected before they reach a backend. The span is borrowed only until
 * mr_rdp_session_start_clipboard_probe returns. */

typedef uint8_t mr_rdp_clipboard_probe_stage;
enum {
    MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT = 1,
    MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE = 2,
    MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST = 3,
    MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT = 4
};

typedef struct mr_rdp_clipboard_probe_event {
    uint32_t struct_size;
    mr_rdp_clipboard_probe_stage stage;
    uint8_t reserved[3];
    mr_rdp_status status;
    uint32_t reserved2;
    uint64_t generation;
    uint64_t sequence;
    uint64_t probe_id;
    size_t payload_byte_count;
    uint8_t payload_sha256[MR_RDP_SHA256_BYTES];
} mr_rdp_clipboard_probe_event;

typedef struct mr_rdp_display_resize_request {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t request_id;
    uint32_t width;
    uint32_t height;
    /* ABI 3. Zero keeps the factor the session connected with; otherwise
     * the same ranges as mr_rdp_config. */
    uint32_t desktop_scale_factor;
    uint32_t device_scale_factor;
    /* ABI 4. A second monitor to the right of the primary, top-aligned;
     * zero for none. The same limits as width/height, and the two widths
     * together at most MR_RDP_MAX_VIRTUAL_DESKTOP_WIDTH. */
    uint32_t secondary_width;
    uint32_t secondary_height;
} mr_rdp_display_resize_request;

typedef struct mr_rdp_display_resize_event {
    uint32_t struct_size;
    mr_rdp_status status;
    uint64_t generation;
    uint64_t sequence;
    uint64_t request_id;
    uint32_t width;
    uint32_t height;
    /* ABI 4. */
    uint32_t secondary_width;
    uint32_t secondary_height;
} mr_rdp_display_resize_event;

typedef uint8_t mr_rdp_cursor_kind;
enum {
    /* A server-supplied shape: bytes/width/height/hotspot are valid. */
    MR_RDP_CURSOR_SHAPE = 1,
    /* The server hid the pointer. */
    MR_RDP_CURSOR_HIDDEN = 2,
    /* The server asked for the system default arrow. */
    MR_RDP_CURSOR_DEFAULT = 3
};

typedef struct mr_rdp_cursor_event {
    uint32_t struct_size;
    mr_rdp_cursor_kind kind;
    uint8_t reserved[3];
    uint64_t generation;
    uint32_t width;
    uint32_t height;
    uint32_t hotspot_x;
    uint32_t hotspot_y;
    uint32_t stride;
    uint32_t reserved2;
    const uint8_t *bytes;
    size_t length;
} mr_rdp_cursor_event;

/* SHAPE bytes are straight-alpha BGRA, top row first, stride >= width * 4,
 * and each dimension is 1...MR_RDP_MAX_CURSOR_DIMENSION. The hotspot lies
 * inside the image. Other kinds carry no bytes. The view is borrowed for the
 * duration of the callback. */

typedef struct mr_rdp_audio_packet {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t generation;
    uint32_t samples_per_second;
    uint16_t channels;
    uint16_t bits_per_sample;
    const uint8_t *bytes;
    size_t length;
} mr_rdp_audio_packet;

/* Interleaved signed 16-bit little-endian PCM, 1 or 2 channels, a whole
 * number of frames. Delivered only while the session's audio is focused;
 * the bytes are borrowed for the duration of the callback, which must copy
 * them into a bounded buffer and return promptly. The protocol's own wave
 * confirmations are sent by FreeRDP whether or not the app plays anything. */

typedef struct mr_rdp_clipboard_remote_formats_event {
    uint32_t struct_size;
    uint8_t has_text;
    /* ABI 5; reserved before. */
    uint8_t has_image;
    uint8_t has_files;
    uint8_t reserved;
    uint64_t generation;
    uint64_t sequence;
} mr_rdp_clipboard_remote_formats_event;

typedef uint8_t mr_rdp_clipboard_offer_stage;
enum {
    /* The server acknowledged the client format list: a paste on the remote
     * side will now ask this client for the text. */
    MR_RDP_CLIPBOARD_OFFER_ACCEPTED = 1,
    /* The server read the offered text. */
    MR_RDP_CLIPBOARD_OFFER_DELIVERED = 2,
    /* The offer failed or was replaced by a remote copy. */
    MR_RDP_CLIPBOARD_OFFER_FAILED = 3
};

typedef struct mr_rdp_clipboard_offer_event {
    uint32_t struct_size;
    mr_rdp_clipboard_offer_stage stage;
    uint8_t reserved[3];
    uint64_t generation;
    uint64_t offer_id;
    mr_rdp_status status;
    uint32_t reserved2;
} mr_rdp_clipboard_offer_event;

typedef struct mr_rdp_clipboard_text_event {
    uint32_t struct_size;
    mr_rdp_status status;
    uint64_t generation;
    uint64_t request_id;
    const uint8_t *utf16le_bytes;
    size_t utf16le_byte_count;
} mr_rdp_clipboard_text_event;

/* On OK, utf16le_bytes is the remote CF_UNICODETEXT with any trailing NUL
 * code units removed; it may be empty. The view is borrowed for the duration
 * of the callback. On failure the span is NULL/0. */

/* ABI 5. An image the server copied: PNG when it offered one, otherwise a
 * device-independent bitmap (CF_DIB: a BITMAPINFO header and the pixels,
 * without a file header). Borrowed for the callback. */
typedef uint8_t mr_rdp_clipboard_image_format;
enum {
    MR_RDP_CLIPBOARD_IMAGE_PNG = 1,
    MR_RDP_CLIPBOARD_IMAGE_DIB = 2
};

typedef struct mr_rdp_clipboard_image_event {
    uint32_t struct_size;
    mr_rdp_status status;
    uint64_t generation;
    uint64_t request_id;
    mr_rdp_clipboard_image_format format;
    uint8_t reserved[7];
    const uint8_t *bytes;
    size_t byte_count;
} mr_rdp_clipboard_image_event;

/* ABI 5. One file the server copied, in order; the last one, or a failure,
 * has is_last set. name is UTF-8, without directories. A request for files
 * when none were copied ends at once with is_last and UNSUPPORTED. Borrowed
 * for the callback. */
typedef struct mr_rdp_clipboard_file_event {
    uint32_t struct_size;
    mr_rdp_status status;
    uint64_t generation;
    uint64_t request_id;
    uint32_t index;
    uint32_t count;
    uint8_t is_last;
    uint8_t reserved[7];
    const char *name;
    size_t name_length;
    const uint8_t *bytes;
    size_t byte_count;
} mr_rdp_clipboard_file_event;

/* ABI 5. The server opened (is_open 1) or closed the microphone. While it is
 * open the app sends interleaved signed 16-bit little-endian PCM at this
 * rate and channel count. */
typedef struct mr_rdp_audio_capture_event {
    uint32_t struct_size;
    uint8_t is_open;
    uint8_t reserved[3];
    uint64_t generation;
    uint32_t samples_per_second;
    uint16_t channels;
    uint16_t bits_per_sample;
} mr_rdp_audio_capture_event;

/* ABI 6. One MACRDPX message from the server. The bridge answers nothing
 * itself beyond sending the client HELLO when the channel connects; the
 * server's HELLO arrives here with negotiated_caps = mrx_negotiate(offered,
 * server). Every later message carries the same negotiated_caps. message and
 * any string in it are valid only during the callback. */
typedef struct mr_rdp_macrdpx_event {
    uint32_t struct_size;
    uint32_t negotiated_caps;
    uint64_t generation;
    const mrx_message *message;
} mr_rdp_macrdpx_event;

typedef void (*mr_rdp_state_callback)(
    void *context,
    const mr_rdp_state_event *event);
typedef void (*mr_rdp_certificate_callback)(
    void *context,
    const mr_rdp_certificate_challenge *challenge);
typedef void (*mr_rdp_error_callback)(
    void *context,
    const mr_rdp_error_event *event);
typedef void (*mr_rdp_desktop_frame_callback)(
    void *context,
    const mr_rdp_desktop_frame *frame);
typedef void (*mr_rdp_channel_callback)(
    void *context,
    const mr_rdp_channel_event *event);
typedef void (*mr_rdp_clipboard_probe_callback)(
    void *context,
    const mr_rdp_clipboard_probe_event *event);
typedef void (*mr_rdp_display_resize_callback)(
    void *context,
    const mr_rdp_display_resize_event *event);

typedef void (*mr_rdp_cursor_callback)(
    void *context,
    const mr_rdp_cursor_event *event);
typedef void (*mr_rdp_audio_callback)(
    void *context,
    const mr_rdp_audio_packet *packet);
typedef void (*mr_rdp_clipboard_remote_formats_callback)(
    void *context,
    const mr_rdp_clipboard_remote_formats_event *event);
typedef void (*mr_rdp_clipboard_offer_callback)(
    void *context,
    const mr_rdp_clipboard_offer_event *event);
typedef void (*mr_rdp_clipboard_text_callback)(
    void *context,
    const mr_rdp_clipboard_text_event *event);

typedef void (*mr_rdp_clipboard_image_callback)(
    void *context,
    const mr_rdp_clipboard_image_event *event);
typedef void (*mr_rdp_clipboard_file_callback)(
    void *context,
    const mr_rdp_clipboard_file_event *event);
typedef void (*mr_rdp_audio_capture_callback)(
    void *context,
    const mr_rdp_audio_capture_event *event);
typedef void (*mr_rdp_macrdpx_callback)(
    void *context,
    const mr_rdp_macrdpx_event *event);

typedef struct mr_rdp_callbacks {
    uint32_t struct_size;
    uint32_t abi_version;
    mr_rdp_state_callback on_state_changed;
    mr_rdp_certificate_callback on_certificate_challenge;
    mr_rdp_error_callback on_error;
    mr_rdp_desktop_frame_callback on_desktop_frame;
    mr_rdp_channel_callback on_channel_event;
    mr_rdp_clipboard_probe_callback on_clipboard_probe_event;
    mr_rdp_display_resize_callback on_display_resize_event;
    /* ABI 2. */
    mr_rdp_cursor_callback on_cursor;
    mr_rdp_audio_callback on_audio;
    mr_rdp_clipboard_remote_formats_callback on_clipboard_remote_formats;
    mr_rdp_clipboard_offer_callback on_clipboard_offer;
    mr_rdp_clipboard_text_callback on_clipboard_text;
    /* ABI 5. */
    mr_rdp_clipboard_image_callback on_clipboard_image;
    mr_rdp_clipboard_file_callback on_clipboard_file;
    mr_rdp_audio_capture_callback on_audio_capture;
    /* ABI 6. */
    mr_rdp_macrdpx_callback on_macrdpx;
} mr_rdp_callbacks;

typedef uint8_t mr_rdp_key_action;
enum {
    MR_RDP_KEY_DOWN = 0,
    MR_RDP_KEY_UP = 1
};

/* Raw keyboard Set 1 code plus explicit RDP EXTENDED/EXTENDED1 selectors.
 * The platform-independent caller does not pass a FreeRDP RDP_SCANCODE.
 * All reserved bytes must be zero. */
typedef struct mr_rdp_key_event {
    uint32_t struct_size;
    uint16_t code;
    uint8_t extended;
    uint8_t extended1;
    mr_rdp_key_action action;
    uint8_t reserved[3];
} mr_rdp_key_event;

typedef uint8_t mr_rdp_pointer_kind;
enum {
    MR_RDP_POINTER_MOVE = 0,
    MR_RDP_POINTER_BUTTON = 1,
    MR_RDP_POINTER_WHEEL = 2
};

typedef uint8_t mr_rdp_pointer_button;
enum {
    MR_RDP_POINTER_BUTTON_NONE = 0,
    MR_RDP_POINTER_BUTTON_LEFT = 1,
    MR_RDP_POINTER_BUTTON_RIGHT = 2,
    MR_RDP_POINTER_BUTTON_MIDDLE = 3
};

typedef struct mr_rdp_pointer_event {
    uint32_t struct_size;
    uint32_t x;
    uint32_t y;
    int32_t wheel_x;
    int32_t wheel_y;
    mr_rdp_pointer_kind kind;
    mr_rdp_pointer_button button;
    mr_rdp_key_action action;
    uint8_t reserved;
} mr_rdp_pointer_event;

/* One Unicode code unit typed as a down/up pair (KBDUNICODE). A
 * supplementary-plane character is two calls, high surrogate first. The pair
 * is atomic, so a Unicode tap never leaves anything pressed on the server. */
typedef struct mr_rdp_unicode_event {
    uint32_t struct_size;
    uint16_t code_unit;
    uint16_t reserved;
} mr_rdp_unicode_event;

/* ABI 4. One finger on the remote touch screen (RDPEI). A DOWN obliges an
 * UP or CANCEL for the same contact; MOVE is coalesced per contact. x/y are
 * remote desktop pixels, contact_id 0...MR_RDP_MAX_TOUCH_CONTACT_ID. Before
 * RDPEI connects - at a logon screen, for instance - FreeRDP turns touches
 * into the left mouse button. */
typedef uint8_t mr_rdp_touch_action;
enum {
    MR_RDP_TOUCH_DOWN = 0,
    MR_RDP_TOUCH_MOVE = 1,
    MR_RDP_TOUCH_UP = 2,
    MR_RDP_TOUCH_CANCEL = 3
};

typedef struct mr_rdp_touch_event {
    uint32_t struct_size;
    uint32_t contact_id;
    uint32_t x;
    uint32_t y;
    mr_rdp_touch_action action;
    uint8_t reserved[3];
} mr_rdp_touch_event;

/* ABI 4. The one pen (RDPEI). DOWN obliges an UP; HOVER and MOVE are
 * coalesced. pressure is 0...MR_RDP_MAX_PEN_PRESSURE, tilt -90...90 degrees,
 * rotation 0...359 degrees. */
typedef uint8_t mr_rdp_pen_action;
enum {
    MR_RDP_PEN_HOVER = 0,
    MR_RDP_PEN_DOWN = 1,
    MR_RDP_PEN_MOVE = 2,
    MR_RDP_PEN_UP = 3
};

typedef uint8_t mr_rdp_pen_flags;
enum {
    MR_RDP_PEN_FLAG_BARREL = 1u << 0,
    MR_RDP_PEN_FLAG_ERASER = 1u << 1
};

typedef struct mr_rdp_pen_event {
    uint32_t struct_size;
    uint32_t x;
    uint32_t y;
    uint32_t pressure;
    int16_t tilt_x;
    int16_t tilt_y;
    uint16_t rotation;
    mr_rdp_pen_action action;
    mr_rdp_pen_flags flags;
} mr_rdp_pen_event;

typedef struct mr_rdp_clipboard_offer {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t offer_id;
    const uint8_t *utf16le_bytes;
    size_t utf16le_byte_count;
} mr_rdp_clipboard_offer;

/* utf16le_bytes follows the probe rules (one trailing NUL, no embedded NUL,
 * well-formed surrogates, even length) with the larger
 * MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES limit. It is copied before
 * mr_rdp_session_offer_clipboard_text returns and served to every server data
 * request until a newer offer or a remote copy replaces it. */

/* Each wheel axis is bounded to +/- MR_RDP_MAX_WHEEL_DELTA. The backend may
 * split one accepted delta across multiple RDP pointer PDUs. */

/* Pointer x/y are already-clamped remote desktop pixel coordinates. Wheel
 * values are signed accumulated deltas; the backend adapter splits them to
 * the protocol's per-event magnitude where required. reserved must be zero;
 * action is DOWN (zero) for MOVE/WHEEL and is meaningful only for BUTTON. */

/*
 * Initializes ABI-versioned value types. Callers may then replace fields.
 */
void mr_rdp_config_init(mr_rdp_config *config);
void mr_rdp_callbacks_init(mr_rdp_callbacks *callbacks);
void mr_rdp_key_event_init(mr_rdp_key_event *event);
void mr_rdp_pointer_event_init(mr_rdp_pointer_event *event);
void mr_rdp_clipboard_probe_init(mr_rdp_clipboard_probe *probe);
void mr_rdp_display_resize_request_init(mr_rdp_display_resize_request *request);
void mr_rdp_unicode_event_init(mr_rdp_unicode_event *event);
void mr_rdp_clipboard_offer_init(mr_rdp_clipboard_offer *offer);
void mr_rdp_touch_event_init(mr_rdp_touch_event *event);
void mr_rdp_pen_event_init(mr_rdp_pen_event *event);

/*
 * Copies config, hostname, credentials, and the callback table before
 * returning. The context is borrowed and must remain valid until destroy
 * returns. The copied password is securely cleared on every cleanup path.
 *
 * The default CMake build uses an intentionally unavailable backend; the
 * generated iOS bridge XCFramework selects the pinned FreeRDP adapter. Tests
 * use the mock factory in rdp_bridge_mock.h.
 */
mr_rdp_status mr_rdp_session_create(
    const mr_rdp_config *config,
    const mr_rdp_callbacks *callbacks,
    void *context,
    mr_rdp_session **out_session);

/*
 * Runs one session synchronously. All callbacks are serialized on this
 * calling thread. A session can be run at most once.
 */
mr_rdp_status mr_rdp_session_run(mr_rdp_session *session);

/*
 * Thread-safe and idempotent. It wakes backend I/O and any certificate wait.
 * It does not wait for callbacks to drain; run returning is the stop barrier.
 */
mr_rdp_status mr_rdp_session_request_stop(mr_rdp_session *session);

/*
 * Answers exactly one active challenge. Both generation and challenge_id
 * must match. Duplicate, late, or cross-generation answers are rejected.
 * ACCEPT_SYSTEM_TRUST means the copied chain and hostname were accepted by
 * the platform SSL trust policy; the bridge never performs silent acceptance.
 */
mr_rdp_status mr_rdp_session_respond_certificate(
    mr_rdp_session *session,
    uint64_t generation,
    uint64_t challenge_id,
    mr_rdp_certificate_decision decision);

/* Rejects/cancels the matching challenge and wakes its worker wait. */
mr_rdp_status mr_rdp_session_cancel_challenge(
    mr_rdp_session *session,
    uint64_t generation,
    uint64_t challenge_id);

mr_rdp_status mr_rdp_session_send_key(
    mr_rdp_session *session,
    const mr_rdp_key_event *event);
mr_rdp_status mr_rdp_session_send_pointer(
    mr_rdp_session *session,
    const mr_rdp_pointer_event *event);

/* Starts a user-initiated, local-to-remote CF_UNICODETEXT exercise. Only the
 * probe id, stage counters, byte count, and SHA-256 are exposed to callbacks;
 * clipboard contents never appear in telemetry. The backend must copy the
 * validated payload before this call returns. The pinned FreeRDP backend
 * reports MR_RDP_ERROR_TIMEOUT for the awaited stage and releases its copy
 * when a format-list response or data request takes longer than 10 seconds.
 * Because CLIPRDR responses have no probe id, retry after timeout requires a
 * fresh channel/session so a late PDU cannot be attributed to a new probe. */
mr_rdp_status mr_rdp_session_start_clipboard_probe(
    mr_rdp_session *session,
    const mr_rdp_clipboard_probe *probe);

/* Queues one DISP monitor-layout request: a primary monitor and, from ABI
 * 4, optionally a second to its right. Widths must be even so FreeRDP
 * 3.31.1 cannot silently round the recorded dimension. */
mr_rdp_status mr_rdp_session_request_display_resize(
    mr_rdp_session *session,
    const mr_rdp_display_resize_request *request);

/* Types one UTF-16 code unit through the same bounded, ordered queue as
 * keys. code_unit zero is rejected. */
mr_rdp_status mr_rdp_session_send_unicode(
    mr_rdp_session *session,
    const mr_rdp_unicode_event *event);

/* ABI 4. Through the same bounded, ordered queue as keys. Refused with
 * MR_RDP_ERROR_UNSUPPORTED when the session was created without
 * MR_RDP_CHANNEL_FLAG_TOUCH. */
mr_rdp_status mr_rdp_session_send_touch(
    mr_rdp_session *session,
    const mr_rdp_touch_event *event);
mr_rdp_status mr_rdp_session_send_pen(
    mr_rdp_session *session,
    const mr_rdp_pen_event *event);

/* Whether this session's PCM reaches on_audio. Thread-safe, callable in any
 * state, and remembered across the channel connecting later. Unfocused audio
 * is dropped in the bridge; the server is still confirmed. */
mr_rdp_status mr_rdp_session_set_audio_focused(
    mr_rdp_session *session,
    uint8_t focused);

/* Announces CF_UNICODETEXT to the server on behalf of a user-initiated copy.
 * Progress arrives on on_clipboard_offer. Fails with INVALID_STATE when the
 * clipboard channel is not ready or was disabled in the config. */
mr_rdp_status mr_rdp_session_offer_clipboard_text(
    mr_rdp_session *session,
    const mr_rdp_clipboard_offer *offer);

/* ABI 5. An image for the server to paste, as PNG and as CF_DIB (a
 * BITMAPINFOHEADER and bottom-up pixels, no file header); either may be
 * absent but not both, each at most MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES. Copied
 * before returning. Progress arrives on on_clipboard_offer. */
typedef struct mr_rdp_clipboard_image_offer {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t offer_id;
    const uint8_t *png_bytes;
    size_t png_byte_count;
    const uint8_t *dib_bytes;
    size_t dib_byte_count;
} mr_rdp_clipboard_image_offer;

void mr_rdp_clipboard_image_offer_init(mr_rdp_clipboard_image_offer *offer);
mr_rdp_status mr_rdp_session_offer_clipboard_image(
    mr_rdp_session *session,
    const mr_rdp_clipboard_image_offer *offer);

/* ABI 5. Files for the server to paste - into Explorer, for instance: 1 to
 * MR_RDP_MAX_CLIPBOARD_FILES, names of 1...MR_RDP_MAX_CLIPBOARD_FILE_NAME_BYTES
 * UTF-8 bytes without '/', '\\' or NUL, together at most
 * MR_RDP_MAX_CLIPBOARD_FILES_BYTES. Copied before returning. */
typedef struct mr_rdp_clipboard_file {
    const char *name;
    size_t name_length;
    const uint8_t *bytes;
    size_t byte_count;
} mr_rdp_clipboard_file;

typedef struct mr_rdp_clipboard_files_offer {
    uint32_t struct_size;
    uint32_t reserved;
    uint64_t offer_id;
    const mr_rdp_clipboard_file *files;
    size_t file_count;
} mr_rdp_clipboard_files_offer;

void mr_rdp_clipboard_files_offer_init(mr_rdp_clipboard_files_offer *offer);
mr_rdp_status mr_rdp_session_offer_clipboard_files(
    mr_rdp_session *session,
    const mr_rdp_clipboard_files_offer *offer);

/* ABI 5. Ask for the server's image (one on_clipboard_image answers) or its
 * files (on_clipboard_file, once per file, the last flagged). They share the
 * text request's single outstanding slot, and its timeout applies to each
 * message of the exchange. */
mr_rdp_status mr_rdp_session_request_clipboard_image(
    mr_rdp_session *session,
    uint64_t request_id);
mr_rdp_status mr_rdp_session_request_clipboard_files(
    mr_rdp_session *session,
    uint64_t request_id);

/* ABI 5. Microphone PCM in the format on_audio_capture announced: a whole
 * number of frames, at most MR_RDP_MAX_AUDIO_CAPTURE_PACKET_BYTES. Dropped
 * while the server has the microphone closed, or when the session was
 * created without MR_RDP_CHANNEL_FLAG_MICROPHONE (UNSUPPORTED). Copied
 * before returning; the bridge keeps about a second and drops the oldest
 * beyond it. */
mr_rdp_status mr_rdp_session_send_audio_capture(
    mr_rdp_session *session,
    const uint8_t *bytes,
    size_t byte_count);

/* ABI 6. Sends one MACRDPX message through the same bounded, ordered queue
 * as keys and the pointer, so a Mac key and a click can never overtake each
 * other. Only client-to-server types are accepted: KEYBOARD_INFO, KEY,
 * MODIFIERS, POINTER, SCROLL and STREAM_CONFIG, valid per mrx_encode. A KEY
 * or POINTER down obliges its up, as for scan-code keys. UNSUPPORTED when the
 * session was created without MR_RDP_CHANNEL_FLAG_MACRDPX. Messages sent
 * before the server's HELLO, or to a server that never opens the channel,
 * are dropped: wait for on_macrdpx before switching input over. */
mr_rdp_status mr_rdp_session_send_macrdpx(
    mr_rdp_session *session,
    const mrx_message *message);

/* Asks the server for its CF_UNICODETEXT. Exactly one on_clipboard_text
 * answers each accepted request, unless the session stops first. Only one
 * request may be outstanding; a request older than
 * MR_RDP_CLIPBOARD_REQUEST_TIMEOUT_MS is answered with TIMEOUT when the next
 * one is made. request_id zero is rejected. */
mr_rdp_status mr_rdp_session_request_clipboard_text(
    mr_rdp_session *session,
    uint64_t request_id);

/*
 * Request stop, wait for the registered run/callback and in-flight calls, then
 * free. Raw-pointer lifetime still belongs to the caller: an external gate
 * must prevent new invocations before destroy starts and must not leave a call
 * racing between invocation and its internal in-flight registration. Calling
 * through a stale handle is never safe. A run known to be active and calls
 * already registered in flight are drained. Calling this from the
 * run/callback thread returns MR_RDP_ERROR_INVALID_STATE.
 */
mr_rdp_status mr_rdp_session_destroy(mr_rdp_session *session);

const char *mr_rdp_status_name(mr_rdp_status status);

/*
 * Callback views are immutable and valid only until that callback returns.
 * Certificate data is a bridge-owned snapshot; desktop bytes and dirty rects
 * are validated backend-owned views. Copy all views before dispatching
 * asynchronous Swift/MainActor work. In particular, never retain a
 * FreeRDP/OpenSSL certificate or GDI framebuffer pointer. Channel, clipboard,
 * and display telemetry contain no borrowed payload pointers. Callbacks must
 * return promptly; certificate timeout measurement begins after its callback
 * returns.
 */

#ifdef __cplusplus
}
#endif

#endif
