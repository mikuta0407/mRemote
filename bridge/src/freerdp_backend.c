#include "bridge_internal.h"
#include "certificate_chain.h"
#include "control_deadline.h"
#include "h264_decoder.h"
#include "input_command_queue.h"
#include "mremote/rdpsnd.h"

#include <freerdp/addin.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/rdpsnd.h>
#include <freerdp/client/audin.h>
#include <freerdp/channels/audin.h>
#include <freerdp/graphics.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rail.h>
#include <freerdp/client/rdpei.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/svc.h>
#include <freerdp/codec/region.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/gdi/region.h>
#include <freerdp/rail.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/drdynvc.h>
#include <freerdp/channels/rdpdr.h>
#include <freerdp/channels/rdpei.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/channels/rdpsnd.h>
#include <freerdp/codec/color.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/locale/keyboard.h>
#include <freerdp/settings.h>
#include <freerdp/utils/cliprdr_utils.h>

#include <winpr/crt.h>
#include <winpr/shell.h>
#include <winpr/string.h>
#include <winpr/user.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/wlog.h>

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ABI 4 needs touch/pen and the drive service compiled into FreeRDP. */
#if !defined(CHANNEL_RDPEI_CLIENT) || !defined(CHANNEL_DRIVE_CLIENT)
#error "FreeRDP must be built with CHANNEL_RDPEI and CHANNEL_DRIVE"
#endif

#define MR_FREERDP_LOG_TAG "com.mremote.bridge"

#define MR_FREERDP_PROTOCOL_RDP 0x00000000u
#define MR_FREERDP_PROTOCOL_SSL 0x00000001u
#define MR_FREERDP_PROTOCOL_HYBRID 0x00000002u

static BOOL mr_freerdp_protocol_allowed(mr_rdp_security_policy policy, uint32_t selected);
static mr_rdp_transport_security mr_freerdp_transport_security(uint32_t selected);
#define MR_FREERDP_CLIPBOARD_PROBE_TIMEOUT_MS 10000u
#define MR_FREERDP_COMMAND_BATCH_LIMIT 64u
#define MR_FREERDP_RDPSND_SUBSYSTEM "mremote"
#define MR_FREERDP_RDPSND_LATENCY_MS "400"
#define MR_FREERDP_MAX_AUDIO_SINKS 2u
/* The one pen this adapter registers with RDPEI. */
#define MR_FREERDP_PEN_DEVICE_ID 1

typedef struct mr_freerdp_backend mr_freerdp_backend;

/* RemoteApp: Windows 11 draws each window on a graphics surface of its
 * own, mapped to the window; this adapter lays them out on the desktop
 * framebuffer where the server says the windows are. */
#define MR_FREERDP_RAIL_WINDOWS 64u

typedef struct mr_freerdp_rail_window {
    UINT32 id;
    INT32 x;
    INT32 y;
    BOOL shown;
} mr_freerdp_rail_window;

/* ABI 5: one H.264 decoder per graphics surface; Windows uses a handful. */
#define MR_FREERDP_MAX_H264_SURFACES 16u

typedef struct mr_freerdp_h264_surface {
    UINT16 surface_id;
    const void *surface;
    mr_h264_decoder *decoder;
} mr_freerdp_h264_surface;

/* ABI 5: about a second of 48 kHz stereo 16-bit microphone audio. */
#define MR_FREERDP_CAPTURE_CAPACITY (48000u * 2u * 2u)

/* The microphone as FreeRDP's audin sees it: the app feeds it. */
typedef struct mr_freerdp_audin_device {
    IAudinDevice iface;
    mr_freerdp_backend *backend;
    AudinReceive receive;
    void *user_data;
    AUDIO_FORMAT format;
    UINT32 frames_per_packet;
} mr_freerdp_audin_device;

typedef struct mr_freerdp_clipboard_probe {
    mr_rdp_backend_clipboard_probe descriptor;
    uint8_t *bytes;
} mr_freerdp_clipboard_probe;

/* ABI 5: what a clipboard offer or request is about. */
enum {
    MR_FREERDP_CLIP_TEXT = 1,
    MR_FREERDP_CLIP_IMAGE = 2,
    MR_FREERDP_CLIP_FILES = 3
};

/* Registered formats this client announces under its own ids. */
#define MR_FREERDP_FORMAT_PNG 0xC0A0u
#define MR_FREERDP_FORMAT_FILES 0xC0B0u
#define MR_FREERDP_FORMAT_PNG_NAME "PNG"
#define MR_FREERDP_FORMAT_FILES_NAME "FileGroupDescriptorW"
/* How much of a remote file each contents request asks for. */
#define MR_FREERDP_FILE_CHUNK (1024u * 1024u)

typedef struct mr_freerdp_clipboard_file {
    WCHAR name[260];
    uint8_t *bytes;
    size_t byte_count;
} mr_freerdp_clipboard_file;

typedef struct mr_freerdp_clipboard_offer {
    uint64_t offer_id;
    int kind;
    /* Text: UTF-16LE with its NUL. */
    uint8_t *bytes;
    size_t byte_count;
    /* Image: either or both. */
    uint8_t *png;
    size_t png_count;
    uint8_t *dib;
    size_t dib_count;
    mr_freerdp_clipboard_file *files;
    size_t file_count;
} mr_freerdp_clipboard_offer;

/* ABI 6: the MACRDPX static channel's client half. FreeRDP owns its life
 * (VirtualChannelEntryEx ... CHANNEL_EVENT_TERMINATED); the backend only
 * points at it while it exists. Everything runs on the session worker. */
typedef struct mr_freerdp_macrdpx {
    CHANNEL_ENTRY_POINTS_FREERDP_EX entry_points;
    CHANNEL_DEF def;
    void *init_handle;
    DWORD open_handle;
    rdpContext *rdpcontext;
    uint8_t *data_in;
    size_t data_in_length;
    size_t data_in_capacity;
} mr_freerdp_macrdpx;

typedef struct mr_freerdp_context {
    rdpClientContext common;
    mr_freerdp_backend *backend;
} mr_freerdp_context;

struct mr_freerdp_backend {
    mr_rdp_backend base;
    pthread_mutex_t mutex;
    int mutex_initialized;
    mr_rdp_backend_host host;
    rdpContext *context;
    freerdp *instance;
    HANDLE command_event;
    char *expected_hostname;
    uint16_t expected_port;
    /* ABI 4. NULL without a gateway. */
    char *expected_gateway_hostname;
    uint16_t expected_gateway_port;
    int pen_registered;
    uint64_t generation;

    mr_input_command_queue command_queue;
    CliprdrClientContext *cliprdr;
    int cliprdr_ready;
    DispClientContext *disp;
    /* RemoteApp: the windows the server reported, and their stacking,
     * topmost first. Read and written on the connection's thread. */
    mr_freerdp_rail_window rail_windows[MR_FREERDP_RAIL_WINDOWS];
    size_t rail_window_count;
    UINT32 rail_zorder[MR_FREERDP_RAIL_WINDOWS];
    size_t rail_zorder_count;
    RdpgfxClientContext *gfx;
    RailClientContext *rail;
    int rail_started;
    mr_freerdp_clipboard_probe *pending_clipboard_probe;
    mr_freerdp_clipboard_probe *active_clipboard_probe;
    mr_control_deadline clipboard_probe_deadline;
    int clipboard_probe_timed_out;
    mr_rdp_display_resize_request pending_display_resize;
    int display_resize_pending;
    int stop_requested;
    int accepting_input;
    int gdi_initialized;
    int channels_subscribed;
    mr_rdp_status callback_status;
    mr_rdp_status input_failure_status;
    uint64_t surface_generation;
    uint64_t frame_id;

    /* ABI 2 */
    mr_rdp_keyboard_profile keyboard_profile;
    mr_rdp_channel_flags channel_flags;
    mr_rdp_security_policy security_policy;
    int audio_focused;
    mr_rdpsnd_device *audio_sinks[MR_FREERDP_MAX_AUDIO_SINKS];
    /* Announced on the next drain; then owned as current_offer. */
    mr_freerdp_clipboard_offer *offer_to_announce;
    mr_freerdp_clipboard_offer *current_offer;
    int offer_awaiting_response;
    uint64_t pending_text_request_id;
    uint64_t expired_text_request_id;
    uint64_t outstanding_text_request_id;
    UINT64 outstanding_text_request_since;
    /* ABI 5: the kind of the pending, outstanding and expired requests, and
     * what the server last offered beyond text. */
    int pending_request_kind;
    int outstanding_request_kind;
    int expired_request_kind;
    UINT32 remote_png_id;
    int remote_has_dib;
    UINT32 remote_files_id;
    /* Remote files being fetched, one at a time, a chunk per message. */
    FILEDESCRIPTORW *incoming_files;
    UINT32 incoming_count;
    UINT32 incoming_index;
    uint8_t *incoming_buffer;
    uint64_t incoming_size;
    uint64_t incoming_received;
    uint64_t incoming_total;
    UINT32 incoming_stream_id;
    /* The image request asked for PNG rather than CF_DIB. */
    int outstanding_image_png;
    /* ABI 5 microphone: the open device, and what the app has sent that has
     * not reached it yet. Both under the mutex. */
    mr_freerdp_audin_device *audin;
    int audin_open;
    uint8_t capture[MR_FREERDP_CAPTURE_CAPACITY];
    size_t capture_count;
    /* ABI 5 H.264: gdi's own surface command, wrapped; only the worker
     * touches these. */
    pcRdpgfxSurfaceCommand gdi_surface_command;
    mr_freerdp_h264_surface h264[MR_FREERDP_MAX_H264_SURFACES];
    /* ABI 6 MACRDPX: offered features, the open channel, and what the
     * server's HELLO agreed to (zero until it arrives). Worker only. */
    uint32_t macrdpx_caps;
    mr_freerdp_macrdpx *macrdpx;
    uint32_t macrdpx_negotiated;
    int macrdpx_ready;
};

/* ABI 5 handlers wired up when their channel connects, defined further down. */
static UINT mr_freerdp_surface_command(RdpgfxClientContext *context, const RDPGFX_SURFACE_COMMAND *cmd);
static UINT mr_freerdp_update_window_from_surface(RdpgfxClientContext *gfx, gdiGfxSurface *surface);
static UINT mr_freerdp_rail_execute_result(RailClientContext *rail, const RAIL_EXEC_RESULT_ORDER *result);
static BOOL mr_freerdp_begin_paint(rdpContext *context);
static BOOL mr_freerdp_end_paint(rdpContext *context);
static UINT VCAPITYPE mr_freerdp_audin_entry(PFREERDP_AUDIN_DEVICE_ENTRY_POINTS entry);

static mr_freerdp_backend *mr_freerdp_backend_from_instance(freerdp *instance)
{
    mr_freerdp_context *context;
    if (instance == NULL || instance->context == NULL) {
        return NULL;
    }
    context = (mr_freerdp_context *)instance->context;
    return context->backend;
}

static int mr_freerdp_is_stopped(mr_freerdp_backend *backend)
{
    int stopped;
    (void)pthread_mutex_lock(&backend->mutex);
    stopped = backend->stop_requested;
    (void)pthread_mutex_unlock(&backend->mutex);
    return stopped;
}

static void mr_freerdp_record_status(
    mr_freerdp_backend *backend,
    mr_rdp_status status)
{
    if (status == MR_RDP_STATUS_OK) {
        return;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->callback_status == MR_RDP_STATUS_OK) {
        backend->callback_status = status;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
}

static mr_rdp_status mr_freerdp_current_status(mr_freerdp_backend *backend)
{
    mr_rdp_status status;
    (void)pthread_mutex_lock(&backend->mutex);
    status = backend->input_failure_status != MR_RDP_STATUS_OK
        ? backend->input_failure_status
        : backend->callback_status;
    (void)pthread_mutex_unlock(&backend->mutex);
    return status;
}

static void mr_freerdp_clipboard_probe_destroy(
    mr_freerdp_clipboard_probe *probe)
{
    if (probe == NULL) {
        return;
    }
    if (probe->bytes != NULL) {
        SecureZeroMemory(probe->bytes, probe->descriptor.utf16le_byte_count);
        free(probe->bytes);
    }
    SecureZeroMemory(probe, sizeof(*probe));
    free(probe);
}

static mr_rdp_status mr_freerdp_emit_clipboard_probe_event(
    mr_freerdp_backend *backend,
    const mr_freerdp_clipboard_probe *probe,
    mr_rdp_clipboard_probe_stage stage,
    mr_rdp_status operation_status)
{
    mr_rdp_backend_clipboard_probe metadata;
    mr_rdp_status status;
    if (backend == NULL || probe == NULL ||
        backend->host.clipboard_probe_event == NULL) {
        return MR_RDP_ERROR_BACKEND;
    }
    metadata = probe->descriptor;
    /* Telemetry carries only identity, byte count, and digest. The copied
     * clipboard contents never cross back through the host callback. */
    metadata.utf16le_bytes = NULL;
    status = backend->host.clipboard_probe_event(
        backend->host.context, &metadata, stage, operation_status);
    SecureZeroMemory(&metadata, sizeof(metadata));
    if (status != MR_RDP_STATUS_OK) {
        mr_freerdp_record_status(backend, status);
    }
    return status;
}

static void mr_freerdp_arm_clipboard_probe_deadline_locked(
    mr_freerdp_backend *backend,
    mr_rdp_clipboard_probe_stage awaited_stage)
{
    mr_control_deadline_arm(
        &backend->clipboard_probe_deadline,
        GetTickCount64(),
        MR_FREERDP_CLIPBOARD_PROBE_TIMEOUT_MS,
        awaited_stage);
}

static DWORD mr_freerdp_clipboard_probe_wait_timeout(
    mr_freerdp_backend *backend)
{
    uint32_t timeout_ms;
    (void)pthread_mutex_lock(&backend->mutex);
    timeout_ms = mr_control_deadline_remaining_ms(
        &backend->clipboard_probe_deadline, GetTickCount64());
    (void)pthread_mutex_unlock(&backend->mutex);
    return (DWORD)timeout_ms;
}

static mr_rdp_status mr_freerdp_expire_clipboard_probe(
    mr_freerdp_backend *backend)
{
    mr_freerdp_clipboard_probe *probe = NULL;
    uint8_t awaited_stage = 0u;
    mr_rdp_status host_status;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->active_clipboard_probe == NULL) {
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else if (mr_control_deadline_take_expired(
                   &backend->clipboard_probe_deadline,
                   GetTickCount64(),
                   &awaited_stage)) {
        probe = backend->active_clipboard_probe;
        backend->active_clipboard_probe = NULL;
        /* CLIPRDR responses do not carry our probe id. A late response from
         * this timed-out offer could otherwise be misattributed to a later
         * probe, so retries require a fresh channel/session. */
        backend->clipboard_probe_timed_out = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    if (probe == NULL) {
        return MR_RDP_STATUS_OK;
    }
    host_status = mr_freerdp_emit_clipboard_probe_event(
        backend,
        probe,
        (mr_rdp_clipboard_probe_stage)awaited_stage,
        MR_RDP_ERROR_TIMEOUT);
    mr_freerdp_clipboard_probe_destroy(probe);
    return host_status;
}

static void mr_freerdp_clipboard_offer_destroy(mr_freerdp_clipboard_offer *offer)
{
    if (offer == NULL) {
        return;
    }
    if (offer->bytes != NULL) {
        SecureZeroMemory(offer->bytes, offer->byte_count);
        free(offer->bytes);
    }
    free(offer->png);
    free(offer->dib);
    if (offer->files != NULL) {
        size_t index;
        for (index = 0u; index < offer->file_count; ++index) {
            free(offer->files[index].bytes);
        }
        free(offer->files);
    }
    SecureZeroMemory(offer, sizeof(*offer));
    free(offer);
}

static void mr_freerdp_emit_offer(
    mr_freerdp_backend *backend,
    uint64_t offer_id,
    mr_rdp_clipboard_offer_stage stage,
    mr_rdp_status status)
{
    mr_rdp_status host_status;
    if (offer_id == 0u) {
        return;
    }
    host_status = backend->host.clipboard_offer_event(
        backend->host.context, offer_id, stage, status);
    if (host_status != MR_RDP_STATUS_OK && host_status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, host_status);
    }
}

static void mr_freerdp_emit_text(
    mr_freerdp_backend *backend,
    uint64_t request_id,
    mr_rdp_status status,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_status host_status;
    if (request_id == 0u) {
        return;
    }
    host_status = backend->host.clipboard_text(
        backend->host.context, request_id, status, bytes, byte_count);
    if (host_status != MR_RDP_STATUS_OK && host_status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, host_status);
    }
}

/* Forgets a remote file transfer in progress. */
static void mr_freerdp_reset_incoming_locked(mr_freerdp_backend *backend)
{
    free(backend->incoming_files);
    free(backend->incoming_buffer);
    backend->incoming_files = NULL;
    backend->incoming_buffer = NULL;
    backend->incoming_count = 0u;
    backend->incoming_index = 0u;
    backend->incoming_size = 0u;
    backend->incoming_received = 0u;
    backend->incoming_total = 0u;
}

static void mr_freerdp_emit_image(
    mr_freerdp_backend *backend,
    uint64_t request_id,
    mr_rdp_status status,
    mr_rdp_clipboard_image_format format,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_status host_status;
    if (request_id == 0u) {
        return;
    }
    host_status = backend->host.clipboard_image(
        backend->host.context, request_id, status, format, bytes, byte_count);
    if (host_status != MR_RDP_STATUS_OK && host_status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, host_status);
    }
}

static void mr_freerdp_emit_file(
    mr_freerdp_backend *backend,
    uint64_t request_id,
    mr_rdp_status status,
    uint32_t index,
    uint32_t count,
    const WCHAR *name,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_rdp_status host_status;
    char *utf8 = NULL;
    size_t utf8_length = 0u;
    if (request_id == 0u) {
        return;
    }
    if (status == MR_RDP_STATUS_OK) {
        utf8 = ConvertWCharNToUtf8Alloc(name, 260u, &utf8_length);
        if (utf8 == NULL || utf8_length == 0u) {
            free(utf8);
            status = MR_RDP_ERROR_INVALID_DATA;
        }
    }
    host_status = status == MR_RDP_STATUS_OK
        ? backend->host.clipboard_file(
              backend->host.context, request_id, status, index, count, index + 1u == count,
              utf8, utf8_length, byte_count == 0u ? NULL : bytes, byte_count)
        : backend->host.clipboard_file(
              backend->host.context, request_id, status, 0u, 0u, 1, NULL, 0u, NULL, 0u);
    free(utf8);
    if (host_status != MR_RDP_STATUS_OK && host_status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, host_status);
    }
}

/* A request that ends without data, whatever its kind. */
static void mr_freerdp_fail_request(
    mr_freerdp_backend *backend,
    uint64_t request_id,
    int kind,
    mr_rdp_status status)
{
    if (kind == MR_FREERDP_CLIP_IMAGE) {
        mr_freerdp_emit_image(backend, request_id, status, 0u, NULL, 0u);
    } else if (kind == MR_FREERDP_CLIP_FILES) {
        mr_freerdp_emit_file(backend, request_id, status, 0u, 0u, NULL, NULL, 0u);
    } else {
        mr_freerdp_emit_text(backend, request_id, status, NULL, 0u);
    }
}

/* Drops every clipboard obligation. Called with the mutex held when the
 * channel or the connection goes away; the caller frees what is returned. */
static void mr_freerdp_take_clipboard_state_locked(
    mr_freerdp_backend *backend,
    mr_freerdp_clipboard_offer **out_announce,
    mr_freerdp_clipboard_offer **out_current)
{
    *out_announce = backend->offer_to_announce;
    *out_current = backend->current_offer;
    backend->offer_to_announce = NULL;
    backend->current_offer = NULL;
    backend->offer_awaiting_response = 0;
    backend->pending_text_request_id = 0u;
    backend->expired_text_request_id = 0u;
    backend->outstanding_text_request_id = 0u;
    backend->outstanding_text_request_since = 0u;
    backend->pending_request_kind = 0;
    backend->outstanding_request_kind = 0;
    backend->expired_request_kind = 0;
    backend->remote_png_id = 0u;
    backend->remote_has_dib = 0;
    backend->remote_files_id = 0u;
    mr_freerdp_reset_incoming_locked(backend);
}

static UINT mr_freerdp_cliprdr_monitor_ready(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_MONITOR_READY *monitor_ready)
{
    CLIPRDR_CAPABILITIES capabilities;
    CLIPRDR_GENERAL_CAPABILITY_SET general;
    if (cliprdr == NULL || monitor_ready == NULL ||
        cliprdr->custom == NULL || cliprdr->ClientCapabilities == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    memset(&capabilities, 0, sizeof(capabilities));
    memset(&general, 0, sizeof(general));
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1u;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    /* ABI 5: files are streamed on request, by index, never by path. */
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
        CB_FILECLIP_NO_FILE_PATHS;
    {
        UINT status = cliprdr->ClientCapabilities(cliprdr, &capabilities);
        mr_freerdp_backend *backend =
            (mr_freerdp_backend *)cliprdr->custom;
        if (status == CHANNEL_RC_OK && cliprdr->ClientFormatList != NULL) {
            /* MS-RDPECLIP 1.3.2.1: the client follows its capabilities with
             * a format list. It is empty because nothing has been copied
             * here yet; an offer announces CF_UNICODETEXT later. */
            CLIPRDR_FORMAT_LIST empty;
            memset(&empty, 0, sizeof(empty));
            empty.common.msgType = CB_FORMAT_LIST;
            status = cliprdr->ClientFormatList(cliprdr, &empty);
        }
        if (status == CHANNEL_RC_OK) {
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->cliprdr == cliprdr) {
                backend->cliprdr_ready = 1;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
        }
        return status;
    }
}

static UINT mr_freerdp_cliprdr_server_capabilities(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_CAPABILITIES *capabilities)
{
    if (cliprdr == NULL || capabilities == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    return CHANNEL_RC_OK;
}

static UINT mr_freerdp_cliprdr_server_format_list(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST *format_list)
{
    CLIPRDR_FORMAT_LIST_RESPONSE response;
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_offer *replaced;
    uint64_t failed_offer_id = 0u;
    mr_rdp_status host_status;
    int has_text = 0;
    int has_dib = 0;
    UINT32 png_id = 0u;
    UINT32 files_id = 0u;
    UINT32 index;
    UINT status;
    if (cliprdr == NULL || format_list == NULL || cliprdr->custom == NULL ||
        cliprdr->ClientFormatListResponse == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    for (index = 0u; index < format_list->numFormats && format_list->formats != NULL;
         ++index) {
        const CLIPRDR_FORMAT *format = &format_list->formats[index];
        if (format->formatId == CF_UNICODETEXT) {
            has_text = 1;
        } else if (format->formatId == CF_DIB || format->formatId == CF_DIBV5) {
            has_dib = 1;
        } else if (format->formatName != NULL &&
                   strcmp(format->formatName, MR_FREERDP_FORMAT_PNG_NAME) == 0) {
            png_id = format->formatId;
        } else if (format->formatName != NULL &&
                   strcmp(format->formatName, MR_FREERDP_FORMAT_FILES_NAME) == 0) {
            files_id = format->formatId;
        }
    }
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    status = cliprdr->ClientFormatListResponse(cliprdr, &response);

    /* A remote copy takes clipboard ownership: whatever this client offered
     * is no longer what a remote paste would read. */
    (void)pthread_mutex_lock(&backend->mutex);
    replaced = backend->current_offer;
    backend->current_offer = NULL;
    if (replaced != NULL && backend->offer_awaiting_response) {
        failed_offer_id = replaced->offer_id;
    }
    backend->offer_awaiting_response = 0;
    backend->remote_png_id = png_id;
    backend->remote_has_dib = has_dib;
    backend->remote_files_id = files_id;
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_emit_offer(
        backend, failed_offer_id, MR_RDP_CLIPBOARD_OFFER_FAILED, MR_RDP_ERROR_INVALID_STATE);
    mr_freerdp_clipboard_offer_destroy(replaced);

    host_status = backend->host.clipboard_remote_formats(
        backend->host.context, has_text, has_dib || png_id != 0u, files_id != 0u);
    if (host_status != MR_RDP_STATUS_OK && host_status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, host_status);
    }
    return status;
}

static UINT mr_freerdp_cliprdr_server_format_list_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *probe;
    mr_rdp_status operation_status;
    mr_rdp_status host_status;
    if (cliprdr == NULL || response == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    probe = mr_control_deadline_is_armed_for(
                &backend->clipboard_probe_deadline,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE)
        ? backend->active_clipboard_probe
        : NULL;
    (void)pthread_mutex_unlock(&backend->mutex);
    if (probe == NULL) {
        uint64_t offer_id = 0u;
        (void)pthread_mutex_lock(&backend->mutex);
        if (backend->offer_awaiting_response && backend->current_offer != NULL) {
            offer_id = backend->current_offer->offer_id;
            backend->offer_awaiting_response = 0;
        }
        (void)pthread_mutex_unlock(&backend->mutex);
        if ((response->common.msgFlags & CB_RESPONSE_OK) != 0u) {
            mr_freerdp_emit_offer(
                backend, offer_id, MR_RDP_CLIPBOARD_OFFER_ACCEPTED, MR_RDP_STATUS_OK);
        } else {
            mr_freerdp_emit_offer(
                backend, offer_id, MR_RDP_CLIPBOARD_OFFER_FAILED, MR_RDP_ERROR_BACKEND);
        }
        return CHANNEL_RC_OK;
    }
    operation_status = (response->common.msgFlags & CB_RESPONSE_OK) != 0u
        ? MR_RDP_STATUS_OK
        : MR_RDP_ERROR_BACKEND;
    host_status = mr_freerdp_emit_clipboard_probe_event(
        backend,
        probe,
        MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE,
        operation_status);
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->active_clipboard_probe != probe ||
        !mr_control_deadline_is_armed_for(
            &backend->clipboard_probe_deadline,
            MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE)) {
        probe = NULL;
    } else if (operation_status != MR_RDP_STATUS_OK ||
               host_status != MR_RDP_STATUS_OK) {
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else {
        mr_freerdp_arm_clipboard_probe_deadline_locked(
            backend, MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST);
        probe = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(probe);
    return host_status == MR_RDP_STATUS_OK
        ? CHANNEL_RC_OK
        : CHANNEL_RC_INITIALIZATION_ERROR;
}

static UINT mr_freerdp_cliprdr_server_format_data_request(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *probe;
    CLIPRDR_FORMAT_DATA_RESPONSE response;
    mr_rdp_status request_status;
    mr_rdp_status response_status;
    mr_rdp_status host_status = MR_RDP_STATUS_OK;
    UINT channel_status;
    if (cliprdr == NULL || request == NULL || cliprdr->custom == NULL ||
        cliprdr->ClientFormatDataResponse == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    probe = backend->active_clipboard_probe;
    if (probe != NULL && request->requestedFormatId == CF_UNICODETEXT &&
        mr_control_deadline_is_armed_for(
            &backend->clipboard_probe_deadline,
            MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST)) {
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    } else {
        probe = NULL;
    }
    if (probe == NULL) {
        /* The offer's bytes are owned under the mutex; the response is sent
         * from a private copy so a concurrent replacement cannot free them
         * while the channel is still reading. */
        uint8_t *served = NULL;
        size_t served_count = 0u;
        uint64_t offer_id = 0u;
        const mr_freerdp_clipboard_offer *offer = backend->current_offer;
        const uint8_t *source = NULL;
        size_t source_count = 0u;
        if (offer != NULL) {
            if (offer->kind == MR_FREERDP_CLIP_TEXT &&
                request->requestedFormatId == CF_UNICODETEXT) {
                source = offer->bytes;
                source_count = offer->byte_count;
            } else if (offer->kind == MR_FREERDP_CLIP_IMAGE &&
                       request->requestedFormatId == CF_DIB) {
                source = offer->dib;
                source_count = offer->dib_count;
            } else if (offer->kind == MR_FREERDP_CLIP_IMAGE &&
                       request->requestedFormatId == MR_FREERDP_FORMAT_PNG) {
                source = offer->png;
                source_count = offer->png_count;
            } else if (offer->kind == MR_FREERDP_CLIP_FILES &&
                       request->requestedFormatId == MR_FREERDP_FORMAT_FILES) {
                /* The file list, built from the names and sizes. */
                FILEDESCRIPTORW *descriptors = (FILEDESCRIPTORW *)calloc(
                    offer->file_count, sizeof(FILEDESCRIPTORW));
                BYTE *list = NULL;
                UINT32 list_length = 0u;
                size_t file;
                if (descriptors != NULL) {
                    for (file = 0u; file < offer->file_count; ++file) {
                        const uint64_t size = offer->files[file].byte_count;
                        descriptors[file].dwFlags = FD_ATTRIBUTES | FD_FILESIZE | FD_SHOWPROGRESSUI;
                        descriptors[file].dwFileAttributes = FILE_ATTRIBUTE_NORMAL;
                        descriptors[file].nFileSizeHigh = (DWORD)(size >> 32);
                        descriptors[file].nFileSizeLow = (DWORD)(size & 0xFFFFFFFFu);
                        memcpy(descriptors[file].cFileName, offer->files[file].name,
                               sizeof(descriptors[file].cFileName));
                    }
                    if (cliprdr_serialize_file_list(
                            descriptors, (UINT32)offer->file_count, &list, &list_length) ==
                            CHANNEL_RC_OK) {
                        served = list;
                        served_count = list_length;
                        offer_id = offer->offer_id;
                    }
                    free(descriptors);
                }
            }
        }
        if (source != NULL && source_count != 0u) {
            served = (uint8_t *)malloc(source_count);
            if (served != NULL) {
                memcpy(served, source, source_count);
                served_count = source_count;
                offer_id = offer->offer_id;
            }
        }
        (void)pthread_mutex_unlock(&backend->mutex);
        memset(&response, 0, sizeof(response));
        response.common.msgType = CB_FORMAT_DATA_RESPONSE;
        if (served != NULL) {
            response.common.msgFlags = CB_RESPONSE_OK;
            response.common.dataLen = (UINT32)served_count;
            response.requestedFormatData = served;
        } else {
            response.common.msgFlags = CB_RESPONSE_FAIL;
        }
        channel_status = cliprdr->ClientFormatDataResponse(cliprdr, &response);
        if (served != NULL) {
            SecureZeroMemory(served, served_count);
            free(served);
            mr_freerdp_emit_offer(
                backend, offer_id,
                channel_status == CHANNEL_RC_OK
                    ? MR_RDP_CLIPBOARD_OFFER_DELIVERED
                    : MR_RDP_CLIPBOARD_OFFER_FAILED,
                channel_status == CHANNEL_RC_OK
                    ? MR_RDP_STATUS_OK
                    : MR_RDP_ERROR_BACKEND);
        }
        return channel_status;
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (probe != NULL) {
        request_status = MR_RDP_STATUS_OK;
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)probe->descriptor.utf16le_byte_count;
        response.requestedFormatData = probe->bytes;
    } else {
        request_status = MR_RDP_ERROR_UNSUPPORTED;
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    if (probe != NULL) {
        host_status = mr_freerdp_emit_clipboard_probe_event(
            backend,
            probe,
            MR_RDP_CLIPBOARD_PROBE_DATA_REQUEST,
            request_status);
    }
    channel_status = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    response_status = channel_status == CHANNEL_RC_OK
        ? MR_RDP_STATUS_OK
        : MR_RDP_ERROR_BACKEND;
    if (probe != NULL) {
        const mr_rdp_status final_host_status =
            mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_DATA_RESPONSE_SENT,
                response_status);
        if (host_status == MR_RDP_STATUS_OK) {
            host_status = final_host_status;
        }
    }
    mr_freerdp_clipboard_probe_destroy(probe);
    if (host_status != MR_RDP_STATUS_OK) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    return channel_status;
}

/* Asks for the next chunk of the current remote file, or hands over the
 * file and moves to the next. Called on the worker with no lock held. */
static UINT mr_freerdp_continue_files(
    mr_freerdp_backend *backend,
    CliprdrClientContext *cliprdr,
    uint64_t request_id)
{
    for (;;) {
        CLIPRDR_FILE_CONTENTS_REQUEST request;
        FILEDESCRIPTORW *descriptor;
        uint64_t remaining;
        (void)pthread_mutex_lock(&backend->mutex);
        if (backend->outstanding_text_request_id != request_id ||
            backend->incoming_index >= backend->incoming_count) {
            (void)pthread_mutex_unlock(&backend->mutex);
            return CHANNEL_RC_OK;
        }
        descriptor = &backend->incoming_files[backend->incoming_index];
        remaining = backend->incoming_size - backend->incoming_received;
        if (remaining == 0u) {
            /* This file is complete: hand it over, then the next. */
            const uint32_t index = backend->incoming_index;
            const uint32_t count = backend->incoming_count;
            WCHAR name[260];
            uint8_t *bytes = backend->incoming_buffer;
            const size_t size = (size_t)backend->incoming_size;
            memcpy(name, descriptor->cFileName, sizeof(name));
            name[259] = 0;
            backend->incoming_buffer = NULL;
            backend->incoming_index += 1u;
            if (backend->incoming_index < backend->incoming_count) {
                const FILEDESCRIPTORW *next = &backend->incoming_files[backend->incoming_index];
                backend->incoming_size = ((uint64_t)next->nFileSizeHigh << 32) | next->nFileSizeLow;
                backend->incoming_received = 0u;
                backend->incoming_buffer = backend->incoming_size == 0u
                    ? NULL : (uint8_t *)malloc((size_t)backend->incoming_size);
                if (backend->incoming_size != 0u && backend->incoming_buffer == NULL) {
                    backend->incoming_count = backend->incoming_index;
                }
            } else {
                backend->outstanding_text_request_id = 0u;
                backend->outstanding_text_request_since = 0u;
                backend->outstanding_request_kind = 0;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_emit_file(backend, request_id, MR_RDP_STATUS_OK, index, count, name, bytes, size);
            free(bytes);
            if (index + 1u == count) {
                (void)pthread_mutex_lock(&backend->mutex);
                mr_freerdp_reset_incoming_locked(backend);
                (void)pthread_mutex_unlock(&backend->mutex);
                return CHANNEL_RC_OK;
            }
            continue;
        }
        memset(&request, 0, sizeof(request));
        request.common.msgType = CB_FILECONTENTS_REQUEST;
        request.streamId = ++backend->incoming_stream_id;
        request.listIndex = backend->incoming_index;
        request.dwFlags = FILECONTENTS_RANGE;
        request.nPositionLow = (UINT32)(backend->incoming_received & 0xFFFFFFFFu);
        request.nPositionHigh = (UINT32)(backend->incoming_received >> 32);
        request.cbRequested = remaining > MR_FREERDP_FILE_CHUNK
            ? MR_FREERDP_FILE_CHUNK : (UINT32)remaining;
        backend->outstanding_text_request_since = GetTickCount64();
        (void)pthread_mutex_unlock(&backend->mutex);
        if (cliprdr->ClientFileContentsRequest == NULL ||
            cliprdr->ClientFileContentsRequest(cliprdr, &request) != CHANNEL_RC_OK) {
            (void)pthread_mutex_lock(&backend->mutex);
            backend->outstanding_text_request_id = 0u;
            backend->outstanding_request_kind = 0;
            mr_freerdp_reset_incoming_locked(backend);
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_emit_file(backend, request_id, MR_RDP_ERROR_BACKEND, 0u, 0u, NULL, NULL, 0u);
        }
        return CHANNEL_RC_OK;
    }
}

/* The server's file list: what will be fetched, within the limits. */
static UINT mr_freerdp_receive_file_list(
    mr_freerdp_backend *backend,
    CliprdrClientContext *cliprdr,
    uint64_t request_id,
    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    FILEDESCRIPTORW *descriptors = NULL;
    UINT32 count = 0u;
    uint64_t total = 0u;
    UINT32 index;
    mr_rdp_status failure = MR_RDP_STATUS_OK;
    if ((response->common.msgFlags & CB_RESPONSE_OK) == 0u ||
        response->requestedFormatData == NULL ||
        cliprdr_parse_file_list(response->requestedFormatData, response->common.dataLen,
                                &descriptors, &count) != CHANNEL_RC_OK) {
        failure = MR_RDP_ERROR_BACKEND;
    } else if (count == 0u) {
        failure = MR_RDP_ERROR_UNSUPPORTED;
    } else if (count > MR_RDP_MAX_CLIPBOARD_FILES) {
        failure = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else {
        for (index = 0u; index < count; ++index) {
            /* Folders are not fetched: their files come in the list too. */
            if ((descriptors[index].dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0u ||
                (descriptors[index].dwFlags & FD_FILESIZE) == 0u) {
                failure = MR_RDP_ERROR_UNSUPPORTED;
                break;
            }
            total += ((uint64_t)descriptors[index].nFileSizeHigh << 32) |
                descriptors[index].nFileSizeLow;
        }
        if (failure == MR_RDP_STATUS_OK && total > MR_RDP_MAX_CLIPBOARD_FILES_BYTES) {
            failure = MR_RDP_ERROR_LIMIT_EXCEEDED;
        }
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (failure != MR_RDP_STATUS_OK || backend->outstanding_text_request_id != request_id) {
        if (backend->outstanding_text_request_id == request_id) {
            backend->outstanding_text_request_id = 0u;
            backend->outstanding_text_request_since = 0u;
            backend->outstanding_request_kind = 0;
        }
        (void)pthread_mutex_unlock(&backend->mutex);
        free(descriptors);
        mr_freerdp_emit_file(backend, request_id,
                             failure != MR_RDP_STATUS_OK ? failure : MR_RDP_ERROR_INVALID_STATE,
                             0u, 0u, NULL, NULL, 0u);
        return CHANNEL_RC_OK;
    }
    mr_freerdp_reset_incoming_locked(backend);
    backend->incoming_files = descriptors;
    backend->incoming_count = count;
    backend->incoming_index = 0u;
    backend->incoming_total = total;
    backend->incoming_size = ((uint64_t)descriptors[0].nFileSizeHigh << 32) | descriptors[0].nFileSizeLow;
    backend->incoming_received = 0u;
    backend->incoming_buffer = backend->incoming_size == 0u
        ? NULL : (uint8_t *)malloc((size_t)backend->incoming_size);
    if (backend->incoming_size != 0u && backend->incoming_buffer == NULL) {
        backend->outstanding_text_request_id = 0u;
        backend->outstanding_request_kind = 0;
        mr_freerdp_reset_incoming_locked(backend);
        (void)pthread_mutex_unlock(&backend->mutex);
        mr_freerdp_emit_file(backend, request_id, MR_RDP_ERROR_OUT_OF_MEMORY, 0u, 0u, NULL, NULL, 0u);
        return CHANNEL_RC_OK;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return mr_freerdp_continue_files(backend, cliprdr, request_id);
}

/* A chunk of the current remote file. */
static UINT mr_freerdp_cliprdr_server_file_contents_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
    mr_freerdp_backend *backend;
    uint64_t request_id;
    int accepted = 0;
    if (cliprdr == NULL || response == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    request_id = backend->outstanding_text_request_id;
    if (backend->outstanding_request_kind == MR_FREERDP_CLIP_FILES && request_id != 0u &&
        response->streamId == backend->incoming_stream_id &&
        (response->common.msgFlags & CB_RESPONSE_OK) != 0u &&
        response->requestedData != NULL && response->cbRequested != 0u &&
        response->cbRequested <= backend->incoming_size - backend->incoming_received) {
        memcpy(backend->incoming_buffer + backend->incoming_received,
               response->requestedData, response->cbRequested);
        backend->incoming_received += response->cbRequested;
        accepted = 1;
    } else if (backend->outstanding_request_kind == MR_FREERDP_CLIP_FILES && request_id != 0u) {
        backend->outstanding_text_request_id = 0u;
        backend->outstanding_request_kind = 0;
        mr_freerdp_reset_incoming_locked(backend);
    } else {
        request_id = 0u;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (request_id == 0u) {
        return CHANNEL_RC_OK;
    }
    if (!accepted) {
        mr_freerdp_emit_file(backend, request_id, MR_RDP_ERROR_BACKEND, 0u, 0u, NULL, NULL, 0u);
        return CHANNEL_RC_OK;
    }
    return mr_freerdp_continue_files(backend, cliprdr, request_id);
}

/* The server reading a file this client offered. */
static UINT mr_freerdp_cliprdr_server_file_contents_request(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FILE_CONTENTS_REQUEST *request)
{
    mr_freerdp_backend *backend;
    CLIPRDR_FILE_CONTENTS_RESPONSE response;
    uint8_t *served = NULL;
    uint8_t size_bytes[8];
    UINT32 served_count = 0u;
    int answered = 0;
    UINT status;
    if (cliprdr == NULL || request == NULL || cliprdr->custom == NULL ||
        cliprdr->ClientFileContentsResponse == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->current_offer != NULL && backend->current_offer->kind == MR_FREERDP_CLIP_FILES &&
        request->listIndex < backend->current_offer->file_count) {
        const mr_freerdp_clipboard_file *file = &backend->current_offer->files[request->listIndex];
        const uint64_t position = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
        if ((request->dwFlags & FILECONTENTS_SIZE) != 0u) {
            uint64_t size = file->byte_count;
            size_t index;
            for (index = 0u; index < 8u; ++index) {
                size_bytes[index] = (uint8_t)(size >> (8u * index));
            }
            served = size_bytes;
            served_count = 8u;
            answered = 1;
        } else if (position <= file->byte_count) {
            answered = 1;
            uint64_t available = file->byte_count - position;
            served_count = (UINT32)(available < request->cbRequested ? available : request->cbRequested);
            if (served_count != 0u) {
                served = (uint8_t *)malloc(served_count);
                if (served != NULL) {
                    memcpy(served, file->bytes + position, served_count);
                } else {
                    served_count = 0u;
                }
            }
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.streamId = request->streamId;
    if (answered && (served != NULL || served_count == 0u)) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.cbRequested = served_count;
        response.requestedData = served;
    } else {
        response.common.msgFlags = CB_RESPONSE_FAIL;
    }
    status = cliprdr->ClientFileContentsResponse(cliprdr, &response);
    if (served != NULL && served != size_bytes) {
        free(served);
    }
    return status;
}

static UINT mr_freerdp_cliprdr_server_format_data_response(
    CliprdrClientContext *cliprdr,
    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    mr_freerdp_backend *backend;
    uint64_t request_id;
    int kind;
    if (cliprdr == NULL || response == NULL || cliprdr->custom == NULL) {
        return CHANNEL_RC_INITIALIZATION_ERROR;
    }
    backend = (mr_freerdp_backend *)cliprdr->custom;
    (void)pthread_mutex_lock(&backend->mutex);
    request_id = backend->outstanding_text_request_id;
    kind = backend->outstanding_request_kind;
    if (kind != MR_FREERDP_CLIP_FILES) {
        backend->outstanding_text_request_id = 0u;
        backend->outstanding_text_request_since = 0u;
        backend->outstanding_request_kind = 0;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (request_id == 0u) {
        /* Nobody is waiting: a response to a request that already timed out. */
        return CHANNEL_RC_OK;
    }
    if (kind == MR_FREERDP_CLIP_IMAGE) {
        const int is_png = backend->outstanding_image_png;
        if ((response->common.msgFlags & CB_RESPONSE_OK) == 0u ||
            response->requestedFormatData == NULL || response->common.dataLen == 0u) {
            mr_freerdp_emit_image(backend, request_id, MR_RDP_ERROR_BACKEND, 0u, NULL, 0u);
        } else if (response->common.dataLen > MR_RDP_MAX_CLIPBOARD_IMAGE_BYTES) {
            mr_freerdp_emit_image(backend, request_id, MR_RDP_ERROR_LIMIT_EXCEEDED, 0u, NULL, 0u);
        } else {
            mr_freerdp_emit_image(
                backend, request_id, MR_RDP_STATUS_OK,
                is_png ? MR_RDP_CLIPBOARD_IMAGE_PNG : MR_RDP_CLIPBOARD_IMAGE_DIB,
                response->requestedFormatData, response->common.dataLen);
        }
        return CHANNEL_RC_OK;
    }
    if (kind == MR_FREERDP_CLIP_FILES) {
        return mr_freerdp_receive_file_list(backend, cliprdr, request_id, response);
    }
    if ((response->common.msgFlags & CB_RESPONSE_OK) == 0u) {
        mr_freerdp_emit_text(backend, request_id, MR_RDP_ERROR_BACKEND, NULL, 0u);
        return CHANNEL_RC_OK;
    }
    {
        size_t length = response->common.dataLen;
        const BYTE *data = response->requestedFormatData;
        if (length > 0u && data == NULL) {
            mr_freerdp_emit_text(backend, request_id, MR_RDP_ERROR_INVALID_DATA, NULL, 0u);
            return CHANNEL_RC_OK;
        }
        if ((length & 1u) != 0u) {
            /* A stray byte cannot be half a code unit of anything useful. */
            length -= 1u;
        }
        while (length >= 2u && data[length - 2u] == 0u && data[length - 1u] == 0u) {
            length -= 2u;
        }
        if (length > MR_RDP_MAX_CLIPBOARD_TEXT_UTF16LE_BYTES) {
            mr_freerdp_emit_text(backend, request_id, MR_RDP_ERROR_LIMIT_EXCEEDED, NULL, 0u);
            return CHANNEL_RC_OK;
        }
        mr_freerdp_emit_text(
            backend, request_id, MR_RDP_STATUS_OK, length == 0u ? NULL : data, length);
    }
    return CHANNEL_RC_OK;
}

static int mr_freerdp_channel_kind_from_name(
    const char *name,
    mr_rdp_channel_kind *out_kind)
{
    if (name == NULL || out_kind == NULL) {
        return 0;
    }
    if (strcmp(name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_CLIPRDR;
    } else if (strcmp(name, RDPSND_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPSND_DVC_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPSND_LOSSY_DVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPSND;
    } else if (strcmp(name, DRDYNVC_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_DRDYNVC;
    } else if (strcmp(name, DISP_DVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_DISP;
    } else if (strcmp(name, RDPGFX_DVC_CHANNEL_NAME) == 0 ||
               strcmp(name, RDPGFX_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPGFX;
    } else if (strcmp(name, RDPEI_DVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPEI;
    } else if (strcmp(name, RDPDR_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RDPDR;
    } else if (strcmp(name, AUDIN_DVC_CHANNEL_NAME) == 0 ||
               strcmp(name, AUDIN_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_AUDIN;
    } else if (strcmp(name, RAIL_SVC_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_RAIL;
    } else if (strcmp(name, MRX_CHANNEL_NAME) == 0) {
        *out_kind = MR_RDP_CHANNEL_MACRDPX;
    } else {
        return 0;
    }
    return 1;
}

static void mr_freerdp_on_channel_connected(
    void *context,
    const ChannelConnectedEventArgs *event)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    mr_rdp_channel_kind kind;
    mr_rdp_status status;
    if (client_context == NULL || event == NULL || event->name == NULL ||
        client_context->backend == NULL) {
        return;
    }
    backend = client_context->backend;
    freerdp_client_OnChannelConnectedEventHandler(context, event);
    /* The common handler has just set gdi up on the graphics pipeline;
     * AVC420 is taken from it here. */
    if ((backend->channel_flags & MR_RDP_CHANNEL_FLAG_H264) != 0u &&
        (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0 ||
         strcmp(event->name, RDPGFX_CHANNEL_NAME) == 0) && event->pInterface != NULL) {
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)event->pInterface;
        if (gfx->SurfaceCommand != mr_freerdp_surface_command) {
            backend->gdi_surface_command = gfx->SurfaceCommand;
            gfx->SurfaceCommand = mr_freerdp_surface_command;
        }
    }
    if ((strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0 ||
         strcmp(event->name, RDPGFX_CHANNEL_NAME) == 0) && event->pInterface != NULL &&
        freerdp_settings_get_bool(((rdpContext *)context)->settings,
                                  FreeRDP_RemoteApplicationMode)) {
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)event->pInterface;
        backend->gfx = gfx;
        gfx->UpdateWindowFromSurface = mr_freerdp_update_window_from_surface;
    }
    if (strcmp(event->name, RAIL_SVC_CHANNEL_NAME) == 0 && event->pInterface != NULL) {
        /* FreeRDP answers the server's handshake itself (only with custom
         * set); the program is started once the server has sent its
         * windows (see the desktop order). */
        backend->rail = (RailClientContext *)event->pInterface;
        backend->rail->custom = backend;
        backend->rail->ServerExecuteResult = mr_freerdp_rail_execute_result;
        backend->rail_started = 0;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        backend->cliprdr = (CliprdrClientContext *)event->pInterface;
        backend->cliprdr_ready = 0;
        backend->clipboard_probe_timed_out = 0;
        if (backend->cliprdr != NULL) {
            backend->cliprdr->custom = backend;
            backend->cliprdr->MonitorReady = mr_freerdp_cliprdr_monitor_ready;
            backend->cliprdr->ServerCapabilities =
                mr_freerdp_cliprdr_server_capabilities;
            backend->cliprdr->ServerFormatList =
                mr_freerdp_cliprdr_server_format_list;
            backend->cliprdr->ServerFormatListResponse =
                mr_freerdp_cliprdr_server_format_list_response;
            backend->cliprdr->ServerFormatDataRequest =
                mr_freerdp_cliprdr_server_format_data_request;
            backend->cliprdr->ServerFormatDataResponse =
                mr_freerdp_cliprdr_server_format_data_response;
            backend->cliprdr->ServerFileContentsRequest =
                mr_freerdp_cliprdr_server_file_contents_request;
            backend->cliprdr->ServerFileContentsResponse =
                mr_freerdp_cliprdr_server_file_contents_response;
        }
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        backend->disp = (DispClientContext *)event->pInterface;
    } else if (strcmp(event->name, RDPEI_DVC_CHANNEL_NAME) == 0) {
        backend->pen_registered = 0;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (mr_freerdp_channel_kind_from_name(event->name, &kind)) {
        status = backend->host.channel_event(
            backend->host.context, kind, MR_RDP_CHANNEL_CONNECTED);
        mr_freerdp_record_status(backend, status);
        if (status != MR_RDP_STATUS_OK && backend->context != NULL) {
            (void)freerdp_abort_connect_context(backend->context);
        }
    }
}

static void mr_freerdp_on_channel_disconnected(
    void *context,
    const ChannelDisconnectedEventArgs *event)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    mr_freerdp_clipboard_probe *pending_probe = NULL;
    mr_freerdp_clipboard_probe *active_probe = NULL;
    mr_freerdp_clipboard_offer *announce = NULL;
    mr_freerdp_clipboard_offer *current = NULL;
    mr_rdp_channel_kind kind;
    mr_rdp_status status;
    if (client_context == NULL || event == NULL || event->name == NULL ||
        client_context->backend == NULL) {
        return;
    }
    backend = client_context->backend;
    (void)pthread_mutex_lock(&backend->mutex);
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (backend->cliprdr == (CliprdrClientContext *)event->pInterface &&
            backend->cliprdr != NULL) {
            backend->cliprdr->custom = NULL;
            backend->cliprdr = NULL;
        }
        backend->cliprdr_ready = 0;
        pending_probe = backend->pending_clipboard_probe;
        active_probe = backend->active_clipboard_probe;
        backend->pending_clipboard_probe = NULL;
        backend->active_clipboard_probe = NULL;
        mr_control_deadline_reset(&backend->clipboard_probe_deadline);
        backend->clipboard_probe_timed_out = 0;
        mr_freerdp_take_clipboard_state_locked(backend, &announce, &current);
    } else if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        if (backend->disp == (DispClientContext *)event->pInterface) {
            backend->disp = NULL;
        }
        backend->display_resize_pending = 0;
        memset(&backend->pending_display_resize, 0,
               sizeof(backend->pending_display_resize));
    } else if (backend->gfx != NULL &&
               backend->gfx == (RdpgfxClientContext *)event->pInterface) {
        backend->gfx = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(pending_probe);
    mr_freerdp_clipboard_probe_destroy(active_probe);
    mr_freerdp_clipboard_offer_destroy(announce);
    mr_freerdp_clipboard_offer_destroy(current);
    freerdp_client_OnChannelDisconnectedEventHandler(context, event);
    if (mr_freerdp_channel_kind_from_name(event->name, &kind)) {
        status = backend->host.channel_event(
            backend->host.context, kind, MR_RDP_CHANNEL_DISCONNECTED);
        mr_freerdp_record_status(backend, status);
        if (status != MR_RDP_STATUS_OK && backend->context != NULL) {
            (void)freerdp_abort_connect_context(backend->context);
        }
    }
}

static void mr_freerdp_clear_password(rdpSettings *settings)
{
    if (settings != NULL) {
        /* Pinned FreeRDP 3.31.1's generated setter clears the previous
         * allocation with memset(strlen) before freeing it. The bridge rejects
         * embedded NUL bytes, so this covers the complete credential span. */
        (void)freerdp_settings_set_string(settings, FreeRDP_Password, NULL);
        (void)freerdp_settings_set_string(settings, FreeRDP_GatewayPassword, NULL);
    }
}

static int mr_freerdp_verify_x509_certificate(
    freerdp *instance,
    const BYTE *pem,
    size_t pem_length,
    const char *hostname,
    UINT16 port,
    DWORD flags)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    mr_rdp_der_blob chain[MR_RDP_MAX_CERTIFICATE_CHAIN];
    size_t chain_count = 0u;
    mr_rdp_status status;
    mr_rdp_certificate_role role;
    if (backend == NULL) {
        return -1;
    }
    /* Only the two endpoints this session was configured with: the gateway
     * under its own name and port, and the computer. A redirect to anything
     * else is not followed. */
    if ((flags & VERIFY_CERT_FLAG_REDIRECT) != 0u || hostname == NULL) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
        return -1;
    }
    if ((flags & VERIFY_CERT_FLAG_GATEWAY) != 0u) {
        if (backend->expected_gateway_hostname == NULL ||
            strcmp(hostname, backend->expected_gateway_hostname) != 0 ||
            port != backend->expected_gateway_port) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
            return -1;
        }
        role = MR_RDP_CERTIFICATE_ROLE_GATEWAY;
    } else if (strcmp(hostname, backend->expected_hostname) != 0 ||
               port != backend->expected_port) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
        return -1;
    } else {
        role = MR_RDP_CERTIFICATE_ROLE_SERVER;
    }
    status = mr_rdp_certificate_chain_from_pem(
        pem, pem_length, chain, &chain_count);
    if (status == MR_RDP_STATUS_OK) {
        status = backend->host.present_certificate(
            backend->host.context, role, chain, chain_count);
    }
    mr_rdp_certificate_chain_free(chain, chain_count);
    if (status == MR_RDP_STATUS_OK) {
        /* Platform trust/pin persistence is owned by the app. Never ask
         * FreeRDP to store a parallel known-hosts decision. */
        return 2;
    }
    mr_freerdp_record_status(backend, status);
    if (status == MR_RDP_ERROR_CERTIFICATE_REJECTED ||
        status == MR_RDP_ERROR_TIMEOUT) {
        return 0;
    }
    return -1;
}

static int mr_freerdp_clip_region(
    const GDI_RGN *source,
    uint32_t frame_width,
    uint32_t frame_height,
    mr_rdp_rect *out_rect)
{
    int64_t left;
    int64_t top;
    int64_t right;
    int64_t bottom;

    if (source == NULL || out_rect == NULL || source->null ||
        source->w <= 0 || source->h <= 0) {
        return 0;
    }
    left = source->x;
    top = source->y;
    right = left + (int64_t)source->w;
    bottom = top + (int64_t)source->h;
    if (left < 0) {
        left = 0;
    }
    if (top < 0) {
        top = 0;
    }
    if (right > (int64_t)frame_width) {
        right = (int64_t)frame_width;
    }
    if (bottom > (int64_t)frame_height) {
        bottom = (int64_t)frame_height;
    }
    if (right <= left || bottom <= top || left >= (int64_t)frame_width ||
        top >= (int64_t)frame_height) {
        return 0;
    }
    out_rect->x = (uint32_t)left;
    out_rect->y = (uint32_t)top;
    out_rect->width = (uint32_t)(right - left);
    out_rect->height = (uint32_t)(bottom - top);
    return 1;
}

static BOOL mr_freerdp_present_gdi_frame(
    mr_freerdp_backend *backend,
    const mr_rdp_rect *dirty_rects,
    size_t dirty_rect_count)
{
    rdpGdi *gdi;
    mr_rdp_desktop_frame frame;
    size_t length;
    mr_rdp_status status;

    if (backend == NULL || backend->context == NULL ||
        dirty_rects == NULL || dirty_rect_count == 0u) {
        return FALSE;
    }
    gdi = backend->context->gdi;
    if (gdi == NULL || gdi->primary_buffer == NULL ||
        gdi->dstFormat != PIXEL_FORMAT_BGRA32 || gdi->width <= 0 ||
        gdi->height <= 0 || (uint32_t)gdi->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        (uint32_t)gdi->height > MR_RDP_MAX_DESKTOP_DIMENSION ||
        gdi->stride < (uint32_t)gdi->width * 4u ||
        (size_t)gdi->stride > SIZE_MAX / (size_t)gdi->height) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_INVALID_DATA);
        return FALSE;
    }
    length = (size_t)gdi->stride * (size_t)gdi->height;
    if (length > MR_RDP_MAX_DESKTOP_FRAME_BYTES) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    ++backend->frame_id;
    if (backend->frame_id == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    memset(&frame, 0, sizeof(frame));
    frame.struct_size = (uint32_t)sizeof(frame);
    frame.generation = backend->generation;
    frame.surface_generation = backend->surface_generation;
    frame.frame_id = backend->frame_id;
    frame.width = (uint32_t)gdi->width;
    frame.height = (uint32_t)gdi->height;
    frame.stride = gdi->stride;
    frame.bytes = gdi->primary_buffer;
    frame.length = length;
    frame.dirty_rects = dirty_rects;
    frame.dirty_rect_count = dirty_rect_count;
    status = backend->host.present_frame(backend->host.context, &frame);
    if (status != MR_RDP_STATUS_OK) {
        mr_freerdp_record_status(backend, status);
        return FALSE;
    }
    return TRUE;
}

static BOOL mr_freerdp_begin_paint(rdpContext *context)
{
    HGDI_WND window;
    if (context == NULL || context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL) {
        return FALSE;
    }
    window = context->gdi->primary->hdc->hwnd;
    if (window != NULL) {
        if (window->invalid != NULL) {
            window->invalid->null = TRUE;
        }
        window->ninvalid = 0;
    }
    return TRUE;
}

static BOOL mr_freerdp_end_paint(rdpContext *context)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    rdpGdi *gdi;
    HGDI_WND window;
    mr_rdp_rect dirty_rects[MR_RDP_MAX_DESKTOP_DIRTY_RECTS];
    size_t dirty_count = 0u;
    int index;

    if (client_context == NULL || client_context->backend == NULL ||
        context->gdi == NULL || context->gdi->primary == NULL ||
        context->gdi->primary->hdc == NULL) {
        return FALSE;
    }
    backend = client_context->backend;
    gdi = context->gdi;
    window = gdi->primary->hdc->hwnd;
    if (window == NULL || window->invalid == NULL || window->invalid->null) {
        return TRUE;
    }

    if (window->ninvalid > 0 && window->cinvalid != NULL &&
        (size_t)window->ninvalid <= MR_RDP_MAX_DESKTOP_DIRTY_RECTS) {
        for (index = 0; index < window->ninvalid; ++index) {
            if (mr_freerdp_clip_region(
                    &window->cinvalid[index],
                    (uint32_t)gdi->width,
                    (uint32_t)gdi->height,
                    &dirty_rects[dirty_count])) {
                ++dirty_count;
            }
        }
    } else if (mr_freerdp_clip_region(
                   window->invalid,
                   (uint32_t)gdi->width,
                   (uint32_t)gdi->height,
                   &dirty_rects[0])) {
        dirty_count = 1u;
    }
    if (dirty_count == 0u) {
        return TRUE;
    }
    return mr_freerdp_present_gdi_frame(backend, dirty_rects, dirty_count);
}

static BOOL mr_freerdp_desktop_resize(rdpContext *context)
{
    mr_freerdp_context *client_context = (mr_freerdp_context *)context;
    mr_freerdp_backend *backend;
    uint32_t width;
    uint32_t height;
    mr_rdp_rect full;

    if (client_context == NULL || client_context->backend == NULL ||
        context->settings == NULL || context->gdi == NULL) {
        return FALSE;
    }
    backend = client_context->backend;
    width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    if (!gdi_resize(context->gdi, width, height)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }
    ++backend->surface_generation;
    if (backend->surface_generation == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    full = (mr_rdp_rect){ 0u, 0u, width, height };
    return mr_freerdp_present_gdi_frame(backend, &full, 1u);
}

/* ---- Remote cursor --------------------------------------------------- */

typedef struct mr_freerdp_pointer {
    rdpPointer pointer;
    uint8_t *bgra;
    uint32_t stride;
} mr_freerdp_pointer;

static mr_freerdp_backend *mr_freerdp_backend_from_context(rdpContext *context)
{
    if (context == NULL) {
        return NULL;
    }
    return ((mr_freerdp_context *)context)->backend;
}

static BOOL mr_freerdp_emit_cursor_kind(rdpContext *context, mr_rdp_cursor_kind kind)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_context(context);
    mr_rdp_cursor_event event;
    mr_rdp_status status;
    if (backend == NULL) {
        return FALSE;
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.kind = kind;
    event.generation = backend->generation;
    status = backend->host.cursor_event(backend->host.context, &event);
    /* A cursor the app could not take is cosmetic; only a stop matters. */
    return status == MR_RDP_STATUS_OK || status == MR_RDP_ERROR_INVALID_DATA;
}

static BOOL mr_freerdp_pointer_new(rdpContext *context, rdpPointer *pointer)
{
    mr_freerdp_pointer *shape = (mr_freerdp_pointer *)pointer;
    if (context == NULL || shape == NULL) {
        return FALSE;
    }
    shape->bgra = NULL;
    shape->stride = 0u;
    if (pointer->width == 0u || pointer->height == 0u ||
        pointer->width > MR_RDP_MAX_CURSOR_DIMENSION ||
        pointer->height > MR_RDP_MAX_CURSOR_DIMENSION) {
        /* Kept as a shape without pixels; Set shows the default arrow. */
        return TRUE;
    }
    shape->stride = pointer->width * 4u;
    shape->bgra = (uint8_t *)calloc((size_t)pointer->height, shape->stride);
    if (shape->bgra == NULL) {
        return FALSE;
    }
    if (!freerdp_image_copy_from_pointer_data(
            shape->bgra, PIXEL_FORMAT_BGRA32, shape->stride, 0u, 0u,
            pointer->width, pointer->height,
            pointer->xorMaskData, pointer->lengthXorMask,
            pointer->andMaskData, pointer->lengthAndMask,
            pointer->xorBpp,
            context->gdi != NULL ? &context->gdi->palette : NULL)) {
        free(shape->bgra);
        shape->bgra = NULL;
        shape->stride = 0u;
    }
    return TRUE;
}

static void mr_freerdp_pointer_free(rdpContext *context, rdpPointer *pointer)
{
    mr_freerdp_pointer *shape = (mr_freerdp_pointer *)pointer;
    (void)context;
    if (shape != NULL) {
        free(shape->bgra);
        shape->bgra = NULL;
    }
}

static BOOL mr_freerdp_pointer_set(rdpContext *context, rdpPointer *pointer)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_context(context);
    mr_freerdp_pointer *shape = (mr_freerdp_pointer *)pointer;
    mr_rdp_cursor_event event;
    mr_rdp_status status;
    if (backend == NULL || shape == NULL) {
        return FALSE;
    }
    if (shape->bgra == NULL) {
        return mr_freerdp_emit_cursor_kind(context, MR_RDP_CURSOR_DEFAULT);
    }
    memset(&event, 0, sizeof(event));
    event.struct_size = (uint32_t)sizeof(event);
    event.kind = MR_RDP_CURSOR_SHAPE;
    event.generation = backend->generation;
    event.width = pointer->width;
    event.height = pointer->height;
    /* Servers occasionally send a hotspot on the far edge; clamp rather than
     * drop the whole shape. */
    event.hotspot_x = pointer->xPos < pointer->width ? pointer->xPos : pointer->width - 1u;
    event.hotspot_y = pointer->yPos < pointer->height ? pointer->yPos : pointer->height - 1u;
    event.stride = shape->stride;
    event.bytes = shape->bgra;
    event.length = (size_t)shape->stride * pointer->height;
    status = backend->host.cursor_event(backend->host.context, &event);
    return status == MR_RDP_STATUS_OK || status == MR_RDP_ERROR_INVALID_DATA;
}

static BOOL mr_freerdp_pointer_set_null(rdpContext *context)
{
    return mr_freerdp_emit_cursor_kind(context, MR_RDP_CURSOR_HIDDEN);
}

static BOOL mr_freerdp_pointer_set_default(rdpContext *context)
{
    return mr_freerdp_emit_cursor_kind(context, MR_RDP_CURSOR_DEFAULT);
}

static BOOL mr_freerdp_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y)
{
    /* iPadOS gives an app no way to move the system pointer, so a server
     * warp is ignored rather than drawn somewhere the user is not. */
    (void)context;
    (void)x;
    (void)y;
    return TRUE;
}

/* ---- rdpsnd device ---------------------------------------------------- */

/* FreeRDP 3.31.1's core sends both Wave Confirm PDUs around Play (see
 * rdpsnd_treat_wave), so this device never confirms anything itself. It only
 * hands PCM to mr_rdpsnd, whose focus gate decides whether the app hears it. */
typedef struct mr_freerdp_rdpsnd_device {
    rdpsndDevicePlugin device;
    mr_freerdp_backend *backend;
    mr_rdpsnd_device *sink;
} mr_freerdp_rdpsnd_device;

static int mr_freerdp_audio_format_supported(const AUDIO_FORMAT *format)
{
    return format != NULL && format->wFormatTag == WAVE_FORMAT_PCM &&
        format->wBitsPerSample == 16u &&
        format->nChannels >= 1u && format->nChannels <= 2u &&
        format->nSamplesPerSec >= 8000u && format->nSamplesPerSec <= 192000u &&
        format->nBlockAlign == format->nChannels * 2u;
}

static void mr_freerdp_rdpsnd_format(const AUDIO_FORMAT *source, mr_rdpsnd_format *out)
{
    mr_rdpsnd_format_init(out);
    out->format_tag = MR_RDPSND_WAVE_FORMAT_PCM;
    out->channels = source->nChannels;
    out->samples_per_second = source->nSamplesPerSec;
    out->block_align = (uint16_t)(source->nChannels * 2u);
    out->average_bytes_per_second = source->nSamplesPerSec * out->block_align;
    out->bits_per_sample = 16u;
}

static mr_rdpsnd_pcm_result mr_freerdp_rdpsnd_on_pcm(
    void *context,
    const mr_rdpsnd_pcm_packet *packet)
{
    mr_freerdp_rdpsnd_device *device = (mr_freerdp_rdpsnd_device *)context;
    mr_rdp_audio_packet audio;
    memset(&audio, 0, sizeof(audio));
    audio.struct_size = (uint32_t)sizeof(audio);
    audio.generation = device->backend->generation;
    audio.samples_per_second = packet->format.samples_per_second;
    audio.channels = packet->format.channels;
    audio.bits_per_sample = packet->format.bits_per_sample;
    audio.bytes = packet->bytes;
    audio.length = packet->length;
    return device->backend->host.audio_packet(device->backend->host.context, &audio) ==
            MR_RDP_STATUS_OK
        ? MR_RDPSND_PCM_ACCEPTED
        : MR_RDPSND_PCM_DROP_BACKPRESSURE;
}

static void mr_freerdp_rdpsnd_on_confirm(
    void *context,
    const mr_rdpsnd_wave_confirmation *confirmation)
{
    (void)context;
    (void)confirmation;
}

static BOOL mr_freerdp_rdpsnd_format_supported(
    rdpsndDevicePlugin *device,
    const AUDIO_FORMAT *format)
{
    (void)device;
    return mr_freerdp_audio_format_supported(format) ? TRUE : FALSE;
}

static BOOL mr_freerdp_rdpsnd_open(
    rdpsndDevicePlugin *plugin,
    const AUDIO_FORMAT *format,
    UINT32 latency)
{
    mr_freerdp_rdpsnd_device *device = (mr_freerdp_rdpsnd_device *)plugin;
    mr_rdpsnd_format native;
    (void)latency;
    if (device == NULL || !mr_freerdp_audio_format_supported(format)) {
        return FALSE;
    }
    mr_freerdp_rdpsnd_format(format, &native);
    return mr_rdpsnd_device_open(device->sink, &native) == MR_RDP_STATUS_OK;
}

static UINT32 mr_freerdp_rdpsnd_get_volume(rdpsndDevicePlugin *device)
{
    (void)device;
    return 0xFFFFFFFFu;
}

static BOOL mr_freerdp_rdpsnd_set_volume(rdpsndDevicePlugin *device, UINT32 value)
{
    /* Volume is the app's mixer's business, per session. */
    (void)device;
    (void)value;
    return TRUE;
}

static UINT mr_freerdp_rdpsnd_play(
    rdpsndDevicePlugin *plugin,
    const BYTE *data,
    size_t size)
{
    mr_freerdp_rdpsnd_device *device = (mr_freerdp_rdpsnd_device *)plugin;
    if (device != NULL) {
        /* Block number and timestamp are not exposed by this FreeRDP
         * version; mr_rdpsnd carries them for telemetry only. */
        (void)mr_rdpsnd_device_play(device->sink, 0u, 0u, data, size);
    }
    return 0u;
}

static void mr_freerdp_rdpsnd_close(rdpsndDevicePlugin *plugin)
{
    mr_freerdp_rdpsnd_device *device = (mr_freerdp_rdpsnd_device *)plugin;
    if (device != NULL) {
        (void)mr_rdpsnd_device_close(device->sink);
    }
}

static void mr_freerdp_rdpsnd_free(rdpsndDevicePlugin *plugin)
{
    mr_freerdp_rdpsnd_device *device = (mr_freerdp_rdpsnd_device *)plugin;
    size_t index;
    if (device == NULL) {
        return;
    }
    (void)pthread_mutex_lock(&device->backend->mutex);
    for (index = 0u; index < MR_FREERDP_MAX_AUDIO_SINKS; ++index) {
        if (device->backend->audio_sinks[index] == device->sink) {
            device->backend->audio_sinks[index] = NULL;
        }
    }
    (void)pthread_mutex_unlock(&device->backend->mutex);
    (void)mr_rdpsnd_device_free(&device->sink);
    free(device);
}

static UINT VCAPITYPE mr_freerdp_rdpsnd_entry(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS entry)
{
    mr_freerdp_rdpsnd_device *device;
    mr_freerdp_backend *backend;
    mr_rdpsnd_config config;
    mr_rdpsnd_callbacks callbacks;
    size_t index;
    int registered = 0;
    if (entry == NULL || entry->rdpsnd == NULL || entry->pRegisterRdpsndDevice == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    backend = mr_freerdp_backend_from_context(freerdp_rdpsnd_get_context(entry->rdpsnd));
    if (backend == NULL) {
        return ERROR_INTERNAL_ERROR;
    }
    device = (mr_freerdp_rdpsnd_device *)calloc(1u, sizeof(*device));
    if (device == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }
    device->backend = backend;
    mr_rdpsnd_config_init(&config);
    config.generation = backend->generation;
    config.max_wave_bytes = MR_RDPSND_DEFAULT_MAX_WAVE_BYTES;
    (void)pthread_mutex_lock(&backend->mutex);
    config.initially_focused = backend->audio_focused ? 1u : 0u;
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_rdpsnd_callbacks_init(&callbacks);
    callbacks.on_pcm = mr_freerdp_rdpsnd_on_pcm;
    callbacks.on_wave_confirm = mr_freerdp_rdpsnd_on_confirm;
    if (mr_rdpsnd_device_create(&config, &callbacks, device, &device->sink) !=
        MR_RDP_STATUS_OK) {
        free(device);
        return ERROR_INTERNAL_ERROR;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    for (index = 0u; index < MR_FREERDP_MAX_AUDIO_SINKS; ++index) {
        if (backend->audio_sinks[index] == NULL) {
            backend->audio_sinks[index] = device->sink;
            registered = 1;
            break;
        }
    }
    /* Re-read under the same lock that set_audio_focused holds, so a focus
     * change racing this entry cannot be lost. */
    (void)mr_rdpsnd_device_set_focused(device->sink, backend->audio_focused ? 1u : 0u);
    (void)pthread_mutex_unlock(&backend->mutex);
    if (!registered) {
        (void)mr_rdpsnd_device_free(&device->sink);
        free(device);
        return ERROR_INTERNAL_ERROR;
    }
    device->device.FormatSupported = mr_freerdp_rdpsnd_format_supported;
    device->device.Open = mr_freerdp_rdpsnd_open;
    device->device.GetVolume = mr_freerdp_rdpsnd_get_volume;
    device->device.SetVolume = mr_freerdp_rdpsnd_set_volume;
    device->device.Play = mr_freerdp_rdpsnd_play;
    device->device.Close = mr_freerdp_rdpsnd_close;
    device->device.Free = mr_freerdp_rdpsnd_free;
    entry->pRegisterRdpsndDevice(entry->rdpsnd, &device->device);
    return CHANNEL_RC_OK;
}

/* ---- ABI 6: MACRDPX ---------------------------------------------------- */

static BOOL mr_freerdp_macrdpx_write(mr_freerdp_macrdpx *plugin, const mrx_message *message)
{
    uint8_t buffer[MRX_HEADER_BYTES + 2u * MRX_MAX_NAME_BYTES];
    size_t length = 0u;
    uint8_t *copy;
    UINT rc;
    if (plugin == NULL || plugin->open_handle == 0u ||
        mrx_encode(message, buffer, sizeof(buffer), &length) != MRX_OK) {
        return FALSE;
    }
    /* FreeRDP holds the buffer until WRITE_COMPLETE/CANCELLED frees it. */
    copy = (uint8_t *)malloc(length);
    if (copy == NULL) {
        return FALSE;
    }
    memcpy(copy, buffer, length);
    rc = plugin->entry_points.pVirtualChannelWriteEx(
        plugin->init_handle, plugin->open_handle, copy, (ULONG)length, copy);
    if (rc != CHANNEL_RC_OK) {
        free(copy);
        return FALSE;
    }
    return TRUE;
}

static void mr_freerdp_macrdpx_dispatch(mr_freerdp_macrdpx *plugin)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_context(plugin->rdpcontext);
    size_t offset = 0u;
    if (backend == NULL) {
        return;
    }
    while (offset < plugin->data_in_length) {
        mrx_message message;
        size_t used = 0u;
        mr_rdp_status status;
        const mrx_status decoded = mrx_decode(
            plugin->data_in + offset, plugin->data_in_length - offset, &message, &used);
        if (decoded == MRX_ERROR_UNKNOWN_TYPE) {
            offset += used;
            continue;
        }
        if (decoded != MRX_OK) {
            /* One write is one message batch; anything else is a broken
             * server. Stop listening rather than guess at framing. */
            WLog_WARN(MR_FREERDP_LOG_TAG, "MACRDPX: %s from the server; channel ignored",
                      mrx_status_name(decoded));
            backend->macrdpx_ready = 0;
            backend->macrdpx_negotiated = 0u;
            return;
        }
        offset += used;
        if (message.type == MRX_MSG_HELLO) {
            if (message.u.hello.role != MRX_ROLE_SERVER) {
                continue;
            }
            backend->macrdpx_negotiated = mrx_negotiate(backend->macrdpx_caps,
                                                        message.u.hello.caps);
            backend->macrdpx_ready = 1;
        } else if (!backend->macrdpx_ready ||
                   (message.type != MRX_MSG_STREAM_STATUS &&
                    message.type != MRX_MSG_INPUT_SOURCE)) {
            continue;
        }
        status = backend->host.macrdpx_message(
            backend->host.context, &message, backend->macrdpx_negotiated);
        if (status == MR_RDP_ERROR_STOPPED) {
            mr_freerdp_record_status(backend, status);
            return;
        }
    }
}

static void mr_freerdp_macrdpx_received(
    mr_freerdp_macrdpx *plugin,
    const void *data,
    UINT32 length,
    UINT32 total_length,
    UINT32 flags)
{
    if ((flags & (CHANNEL_FLAG_SUSPEND | CHANNEL_FLAG_RESUME)) != 0u) {
        return;
    }
    if ((flags & CHANNEL_FLAG_FIRST) != 0u) {
        if (total_length > MRX_HEADER_BYTES + MRX_MAX_PAYLOAD_BYTES * 4u) {
            plugin->data_in_length = 0u;
            plugin->data_in_capacity = 0u;
            return;
        }
        if (plugin->data_in_capacity < total_length) {
            uint8_t *grown = (uint8_t *)realloc(plugin->data_in, total_length);
            if (grown == NULL) {
                plugin->data_in_capacity = 0u;
                return;
            }
            plugin->data_in = grown;
        }
        plugin->data_in_capacity = total_length;
        plugin->data_in_length = 0u;
    }
    if (plugin->data_in == NULL ||
        plugin->data_in_length + length > plugin->data_in_capacity) {
        return;
    }
    memcpy(plugin->data_in + plugin->data_in_length, data, length);
    plugin->data_in_length += length;
    if ((flags & CHANNEL_FLAG_LAST) != 0u &&
        plugin->data_in_length == plugin->data_in_capacity) {
        mr_freerdp_macrdpx_dispatch(plugin);
        plugin->data_in_length = 0u;
    }
}

static VOID VCAPITYPE mr_freerdp_macrdpx_open_event(
    LPVOID user, DWORD open_handle, UINT event, LPVOID data,
    UINT32 length, UINT32 total_length, UINT32 flags)
{
    mr_freerdp_macrdpx *plugin = (mr_freerdp_macrdpx *)user;
    switch (event) {
        case CHANNEL_EVENT_DATA_RECEIVED:
            if (plugin != NULL && plugin->open_handle == open_handle) {
                mr_freerdp_macrdpx_received(plugin, data, length, total_length, flags);
            }
            break;
        case CHANNEL_EVENT_WRITE_COMPLETE:
        case CHANNEL_EVENT_WRITE_CANCELLED:
            free(data);
            break;
        default:
            break;
    }
}

static void mr_freerdp_macrdpx_connected(mr_freerdp_macrdpx *plugin)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_context(plugin->rdpcontext);
    static const char name[] = "mRemote; Apple";
    mrx_message hello;
    if (backend == NULL ||
        plugin->entry_points.pVirtualChannelOpenEx(
            plugin->init_handle, &plugin->open_handle, plugin->def.name,
            mr_freerdp_macrdpx_open_event) != CHANNEL_RC_OK) {
        return;
    }
    backend->macrdpx = plugin;
    backend->macrdpx_ready = 0;
    backend->macrdpx_negotiated = 0u;
    memset(&hello, 0, sizeof(hello));
    hello.type = MRX_MSG_HELLO;
    hello.u.hello.version = MRX_PROTOCOL_VERSION;
    hello.u.hello.role = MRX_ROLE_CLIENT;
    hello.u.hello.caps = backend->macrdpx_caps;
    hello.u.hello.name = name;
    hello.u.hello.name_length = (uint8_t)(sizeof(name) - 1u);
    if (!mr_freerdp_macrdpx_write(plugin, &hello)) {
        WLog_WARN(MR_FREERDP_LOG_TAG, "MACRDPX: could not send HELLO");
    }
}

static void mr_freerdp_macrdpx_disconnected(mr_freerdp_macrdpx *plugin)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_context(plugin->rdpcontext);
    if (backend != NULL && backend->macrdpx == plugin) {
        backend->macrdpx = NULL;
        backend->macrdpx_ready = 0;
        backend->macrdpx_negotiated = 0u;
    }
    if (plugin->open_handle != 0u) {
        (void)plugin->entry_points.pVirtualChannelCloseEx(plugin->init_handle, plugin->open_handle);
        plugin->open_handle = 0u;
    }
    plugin->data_in_length = 0u;
}

static VOID VCAPITYPE mr_freerdp_macrdpx_init_event(
    LPVOID user, LPVOID init_handle, UINT event, LPVOID data, UINT length)
{
    mr_freerdp_macrdpx *plugin = (mr_freerdp_macrdpx *)user;
    (void)data;
    (void)length;
    if (plugin == NULL || plugin->init_handle != init_handle) {
        return;
    }
    switch (event) {
        case CHANNEL_EVENT_CONNECTED:
            mr_freerdp_macrdpx_connected(plugin);
            break;
        case CHANNEL_EVENT_DISCONNECTED:
            mr_freerdp_macrdpx_disconnected(plugin);
            break;
        case CHANNEL_EVENT_TERMINATED:
            mr_freerdp_macrdpx_disconnected(plugin);
            free(plugin->data_in);
            free(plugin);
            break;
        default:
            break;
    }
}

static BOOL VCAPITYPE mr_freerdp_macrdpx_entry(PCHANNEL_ENTRY_POINTS_EX entry_points, PVOID init_handle)
{
    CHANNEL_ENTRY_POINTS_FREERDP_EX *freerdp_points = (CHANNEL_ENTRY_POINTS_FREERDP_EX *)entry_points;
    mr_freerdp_macrdpx *plugin;
    if (freerdp_points == NULL ||
        freerdp_points->cbSize < sizeof(CHANNEL_ENTRY_POINTS_FREERDP_EX) ||
        freerdp_points->MagicNumber != FREERDP_CHANNEL_MAGIC_NUMBER) {
        return FALSE;
    }
    plugin = (mr_freerdp_macrdpx *)calloc(1u, sizeof(*plugin));
    if (plugin == NULL) {
        return FALSE;
    }
    plugin->def.options = CHANNEL_OPTION_INITIALIZED | CHANNEL_OPTION_ENCRYPT_RDP;
    (void)sprintf_s(plugin->def.name, ARRAYSIZE(plugin->def.name), MRX_CHANNEL_NAME);
    memcpy(&plugin->entry_points, freerdp_points, sizeof(plugin->entry_points));
    plugin->init_handle = init_handle;
    plugin->rdpcontext = freerdp_points->context;
    if (plugin->entry_points.pVirtualChannelInitEx(
            plugin, NULL, init_handle, &plugin->def, 1, VIRTUAL_CHANNEL_VERSION_WIN2000,
            mr_freerdp_macrdpx_init_event) != CHANNEL_RC_OK) {
        free(plugin);
        return FALSE;
    }
    return TRUE;
}

/* Worker: one queued client message onto the channel. Until the server has
 * answered HELLO - or when it never opens the channel - it is dropped, as
 * the header promises. */
static BOOL mr_freerdp_send_macrdpx_command(
    mr_freerdp_backend *backend,
    const mrx_message *message)
{
    if (backend->macrdpx == NULL || !backend->macrdpx_ready) {
        return TRUE;
    }
    if (!mr_freerdp_macrdpx_write(backend->macrdpx, message)) {
        WLog_WARN(MR_FREERDP_LOG_TAG, "MACRDPX: %s not sent", mrx_message_type_name(message->type));
    }
    return TRUE;
}

/* freerdp_client_context_new replaces the process-wide addin provider with
 * the static channel table every time it runs, so the mRemote provider is
 * re-registered right after it, under one lock, and delegates everything but
 * its own rdpsnd subsystem back to that table. */
static pthread_mutex_t mr_freerdp_addin_lock = PTHREAD_MUTEX_INITIALIZER;

static PVIRTUALCHANNELENTRY mr_freerdp_addin_provider(
    LPCSTR name,
    LPCSTR subsystem,
    LPCSTR type,
    DWORD flags)
{
    if (name != NULL && subsystem != NULL &&
        strcmp(name, RDPSND_CHANNEL_NAME) == 0 &&
        strcmp(subsystem, MR_FREERDP_RDPSND_SUBSYSTEM) == 0) {
        PFREERDP_RDPSND_DEVICE_ENTRY entry = mr_freerdp_rdpsnd_entry;
        return WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRY);
    }
    if (name != NULL && subsystem != NULL &&
        strcmp(name, AUDIN_CHANNEL_NAME) == 0 &&
        strcmp(subsystem, MR_FREERDP_RDPSND_SUBSYSTEM) == 0) {
        PFREERDP_AUDIN_DEVICE_ENTRY entry = mr_freerdp_audin_entry;
        return WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRY);
    }
    if (name != NULL && subsystem == NULL && strcmp(name, MRX_CHANNEL_NAME) == 0 &&
        (flags & FREERDP_ADDIN_CHANNEL_STATIC) != 0u &&
        (flags & FREERDP_ADDIN_CHANNEL_ENTRYEX) != 0u) {
        PVIRTUALCHANNELENTRYEX entry = mr_freerdp_macrdpx_entry;
        return WINPR_FUNC_PTR_CAST(entry, PVIRTUALCHANNELENTRY);
    }
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

static mr_freerdp_backend *mr_freerdp_backend_from_gfx(RdpgfxClientContext *gfx)
{
    rdpGdi *gdi = gfx != NULL ? (rdpGdi *)gfx->custom : NULL;
    if (gdi == NULL || gdi->context == NULL) {
        return NULL;
    }
    return ((mr_freerdp_context *)gdi->context)->backend;
}

/* The decoder for a surface: kept while the surface is the same, renewed
 * when the id comes back for a new one. */
static mr_h264_decoder *mr_freerdp_h264_for(mr_freerdp_backend *backend, const gdiGfxSurface *surface)
{
    size_t index;
    mr_freerdp_h264_surface *free_slot = NULL;
    for (index = 0u; index < MR_FREERDP_MAX_H264_SURFACES; ++index) {
        mr_freerdp_h264_surface *slot = &backend->h264[index];
        if (slot->decoder != NULL && slot->surface_id == surface->surfaceId) {
            if (slot->surface != surface) {
                mr_h264_decoder_free(slot->decoder);
                slot->decoder = mr_h264_decoder_new();
                slot->surface = surface;
            }
            return slot->decoder;
        }
        if (slot->decoder == NULL && free_slot == NULL) {
            free_slot = slot;
        }
    }
    if (free_slot == NULL) {
        /* Full: start over; the next key frame rebuilds what is in use. */
        for (index = 0u; index < MR_FREERDP_MAX_H264_SURFACES; ++index) {
            mr_h264_decoder_free(backend->h264[index].decoder);
            backend->h264[index].decoder = NULL;
        }
        free_slot = &backend->h264[0];
    }
    free_slot->decoder = mr_h264_decoder_new();
    free_slot->surface_id = surface->surfaceId;
    free_slot->surface = surface;
    return free_slot->decoder;
}

static void mr_freerdp_h264_release_all(mr_freerdp_backend *backend)
{
    size_t index;
    for (index = 0u; index < MR_FREERDP_MAX_H264_SURFACES; ++index) {
        mr_h264_decoder_free(backend->h264[index].decoder);
        backend->h264[index].decoder = NULL;
        backend->h264[index].surface = NULL;
    }
}

/* AVC420 goes to VideoToolbox; every other codec to gdi as before. The
 * update that follows mirrors gdi's own: the region is invalidated, and
 * drawn now when it arrived outside a frame. */
static UINT mr_freerdp_surface_command(RdpgfxClientContext *context, const RDPGFX_SURFACE_COMMAND *cmd)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_gfx(context);
    const RDPGFX_AVC420_BITMAP_STREAM *stream;
    gdiGfxSurface *surface;
    mr_h264_decoder *decoder;
    rdpGdi *gdi;
    UINT32 index;
    UINT status = CHANNEL_RC_OK;
    if (backend == NULL || backend->gdi_surface_command == NULL) {
        return ERROR_INTERNAL_ERROR;
    }
    if (cmd == NULL || (cmd->codecId != RDPGFX_CODECID_AVC420 &&
                        cmd->codecId != RDPGFX_CODECID_AVC444 &&
                        cmd->codecId != RDPGFX_CODECID_AVC444v2)) {
        return backend->gdi_surface_command(context, cmd);
    }
    if (cmd->codecId == RDPGFX_CODECID_AVC420) {
        stream = (const RDPGFX_AVC420_BITMAP_STREAM *)cmd->extra;
    } else {
        /* AVC444: the first stream is an ordinary 4:2:0 picture and is
         * drawn; the second only sharpens colour and is left out. An
         * update that carries only the second (LC 2) changes nothing here. */
        const RDPGFX_AVC444_BITMAP_STREAM *avc444 = (const RDPGFX_AVC444_BITMAP_STREAM *)cmd->extra;
        if (avc444 == NULL) {
            return ERROR_INTERNAL_ERROR;
        }
        if (avc444->LC == 2u) {
            return CHANNEL_RC_OK;
        }
        stream = &avc444->bitstream[0];
    }
    surface = context->GetSurfaceData != NULL
        ? (gdiGfxSurface *)context->GetSurfaceData(context, (UINT16)cmd->surfaceId)
        : NULL;
    if (stream == NULL || surface == NULL || surface->data == NULL) {
        return ERROR_NOT_FOUND;
    }
    decoder = mr_freerdp_h264_for(backend, surface);
    if (decoder == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }
    {
        const int decoded = mr_h264_decoder_decode(
            decoder, stream->data, stream->length, surface->data, surface->scanline,
            surface->width, surface->height,
            (const mr_h264_rect *)stream->meta.regionRects, stream->meta.numRegionRects);
        if (decoded != MR_H264_OK) {
            /* As gdi does: a picture that cannot be decoded is skipped, not
             * fatal; the server's next key frame repairs it. */
            WLog_WARN(MR_FREERDP_LOG_TAG, "H.264 picture skipped (%d), codec %" PRIu16 ", %" PRIu32 " bytes",
                      decoded, cmd->codecId, stream->length);
            return CHANNEL_RC_OK;
        }
        WLog_DBG(MR_FREERDP_LOG_TAG, "H.264 codec %" PRIu16 ": %" PRIu32 " rects into surface %" PRIu16 " %" PRIu32 "x%" PRIu32,
                 cmd->codecId, stream->meta.numRegionRects, surface->surfaceId, surface->width, surface->height);
    }
    for (index = 0u; index < stream->meta.numRegionRects; ++index) {
        if (!region16_union_rect(&surface->invalidRegion, &surface->invalidRegion,
                                 &stream->meta.regionRects[index])) {
            return ERROR_INTERNAL_ERROR;
        }
    }
    if (context->UpdateSurfaceArea != NULL) {
        status = context->UpdateSurfaceArea(
            context, surface->surfaceId, stream->meta.numRegionRects, stream->meta.regionRects);
    }
    gdi = (rdpGdi *)context->custom;
    if (status == CHANNEL_RC_OK && gdi != NULL && !gdi->inGfxFrame && context->UpdateSurfaces != NULL) {
        status = context->UpdateSurfaces(context);
    }
    return status;
}

static UINT mr_freerdp_rail_execute_result(RailClientContext *rail, const RAIL_EXEC_RESULT_ORDER *result)
{
    (void)rail;
    if (result != NULL) {
        WLog_INFO(MR_FREERDP_LOG_TAG, "RemoteApp start: result %" PRIu16 ", raw 0x%08" PRIx32,
                  result->execResult, result->rawResult);
    }
    return CHANNEL_RC_OK;
}

static mr_freerdp_rail_window *mr_freerdp_rail_find(mr_freerdp_backend *backend, UINT32 id)
{
    size_t index;
    for (index = 0u; index < backend->rail_window_count; index++) {
        if (backend->rail_windows[index].id == id) {
            return &backend->rail_windows[index];
        }
    }
    return NULL;
}

/* 0 is the bottom: windows missing from the stacking list first, then the
 * list from its end, since it is given topmost first. */
static size_t mr_freerdp_rail_rank(const mr_freerdp_backend *backend, UINT32 id)
{
    size_t index;
    for (index = 0u; index < backend->rail_zorder_count; index++) {
        if (backend->rail_zorder[index] == id) {
            return 1u + backend->rail_zorder_count - index;
        }
    }
    return 0u;
}

/* Repaints one desktop rectangle from the window surfaces under it,
 * bottom to top; nothing under a window is black. The caller holds the
 * graphics lock and is inside a paint. */
static void mr_freerdp_rail_compose(mr_freerdp_backend *backend, rdpGdi *gdi,
                                    INT32 left, INT32 top, INT32 right, INT32 bottom)
{
    RdpgfxClientContext *gfx = backend->gfx;
    UINT16 *ids = NULL;
    UINT16 count = 0u;
    gdiGfxSurface *order[MR_FREERDP_RAIL_WINDOWS];
    size_t ranks[MR_FREERDP_RAIL_WINDOWS];
    size_t drawn = 0u;
    size_t index;

    left = left < 0 ? 0 : left;
    top = top < 0 ? 0 : top;
    right = right > (INT32)gdi->width ? (INT32)gdi->width : right;
    bottom = bottom > (INT32)gdi->height ? (INT32)gdi->height : bottom;
    if (left >= right || top >= bottom || gdi->primary_buffer == NULL) {
        return;
    }
    (void)freerdp_image_fill(gdi->primary_buffer, gdi->dstFormat, gdi->stride,
                             (UINT32)left, (UINT32)top, (UINT32)(right - left),
                             (UINT32)(bottom - top), 0u);
    if (gfx != NULL && gfx->GetSurfaceIds != NULL && gfx->GetSurfaceData != NULL &&
        gfx->GetSurfaceIds(gfx, &ids, &count) == CHANNEL_RC_OK) {
        for (index = 0u; index < count && drawn < MR_FREERDP_RAIL_WINDOWS; index++) {
            gdiGfxSurface *surface = (gdiGfxSurface *)gfx->GetSurfaceData(gfx, ids[index]);
            const mr_freerdp_rail_window *window;
            size_t rank;
            size_t slot;
            if (surface == NULL || !surface->windowMapped || surface->data == NULL) {
                continue;
            }
            window = mr_freerdp_rail_find(backend, (UINT32)surface->windowId);
            if (window == NULL || !window->shown) {
                continue;
            }
            rank = mr_freerdp_rail_rank(backend, window->id);
            slot = drawn;
            while (slot > 0u && ranks[slot - 1u] > rank) {
                order[slot] = order[slot - 1u];
                ranks[slot] = ranks[slot - 1u];
                slot--;
            }
            order[slot] = surface;
            ranks[slot] = rank;
            drawn++;
        }
        free(ids);
    }
    for (index = 0u; index < drawn; index++) {
        const gdiGfxSurface *surface = order[index];
        const mr_freerdp_rail_window *window =
            mr_freerdp_rail_find(backend, (UINT32)surface->windowId);
        const UINT32 width = surface->mappedWidth < surface->width ? surface->mappedWidth : surface->width;
        const UINT32 height = surface->mappedHeight < surface->height ? surface->mappedHeight : surface->height;
        INT32 x0 = window->x;
        INT32 y0 = window->y;
        INT32 x1 = window->x + (INT32)width;
        INT32 y1 = window->y + (INT32)height;
        x0 = x0 < left ? left : x0;
        y0 = y0 < top ? top : y0;
        x1 = x1 > right ? right : x1;
        y1 = y1 > bottom ? bottom : y1;
        if (x0 >= x1 || y0 >= y1) {
            continue;
        }
        (void)freerdp_image_copy_no_overlap(
            gdi->primary_buffer, gdi->dstFormat, gdi->stride, (UINT32)x0, (UINT32)y0,
            (UINT32)(x1 - x0), (UINT32)(y1 - y0), surface->data, surface->format,
            surface->scanline, (UINT32)(x0 - window->x), (UINT32)(y0 - window->y),
            NULL, FREERDP_FLIP_NONE);
    }
    (void)gdi_InvalidateRegion(gdi->primary->hdc, left, top, right - left, bottom - top);
}

static void mr_freerdp_rail_compose_all(rdpContext *context)
{
    mr_freerdp_backend *backend = ((mr_freerdp_context *)context)->backend;
    rdpGdi *gdi = context->gdi;
    if (backend == NULL || gdi == NULL || gdi->primary == NULL) {
        return;
    }
    if (backend->gfx != NULL) {
        EnterCriticalSection(&backend->gfx->mux);
    }
    mr_freerdp_rail_compose(backend, gdi, 0, 0, (INT32)gdi->width, (INT32)gdi->height);
    if (backend->gfx != NULL) {
        LeaveCriticalSection(&backend->gfx->mux);
    }
}

/* Window orders arrive inside the paint of the update that carries them. */
static BOOL mr_freerdp_window_state(rdpContext *context, const WINDOW_ORDER_INFO *info,
                                    const WINDOW_STATE_ORDER *state)
{
    mr_freerdp_backend *backend = ((mr_freerdp_context *)context)->backend;
    mr_freerdp_rail_window *window;
    if (backend == NULL || info == NULL || state == NULL) {
        return TRUE;
    }
    window = mr_freerdp_rail_find(backend, info->windowId);
    if (window == NULL) {
        if (backend->rail_window_count >= MR_FREERDP_RAIL_WINDOWS) {
            return TRUE;
        }
        window = &backend->rail_windows[backend->rail_window_count++];
        memset(window, 0, sizeof(*window));
        window->id = info->windowId;
        window->shown = TRUE;
    }
    if ((info->fieldFlags & WINDOW_ORDER_FIELD_WND_OFFSET) != 0u) {
        window->x = state->windowOffsetX;
        window->y = state->windowOffsetY;
    }
    if ((info->fieldFlags & WINDOW_ORDER_FIELD_SHOW) != 0u) {
        /* SW_HIDE and SW_MINIMIZE. */
        window->shown = state->showState != 0u && state->showState != 2u;
    }
    if ((info->fieldFlags & (WINDOW_ORDER_FIELD_WND_OFFSET | WINDOW_ORDER_FIELD_SHOW |
                             WINDOW_ORDER_FIELD_WND_SIZE)) != 0u) {
        mr_freerdp_rail_compose_all(context);
    }
    return TRUE;
}

static BOOL mr_freerdp_window_delete(rdpContext *context, const WINDOW_ORDER_INFO *info)
{
    mr_freerdp_backend *backend = ((mr_freerdp_context *)context)->backend;
    mr_freerdp_rail_window *window;
    if (backend == NULL || info == NULL) {
        return TRUE;
    }
    window = mr_freerdp_rail_find(backend, info->windowId);
    if (window != NULL) {
        *window = backend->rail_windows[--backend->rail_window_count];
        mr_freerdp_rail_compose_all(context);
    }
    return TRUE;
}

static BOOL mr_freerdp_monitored_desktop(rdpContext *context, const WINDOW_ORDER_INFO *info,
                                         const MONITORED_DESKTOP_ORDER *desktop)
{
    mr_freerdp_backend *backend = ((mr_freerdp_context *)context)->backend;
    size_t index;
    if (backend == NULL || info == NULL) {
        return TRUE;
    }
    /* The server has sent the windows it already has: say who we are and
     * what to run, as FreeRDP's own clients do. */
    if ((info->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ARC_COMPLETED) != 0u &&
        backend->rail != NULL && !backend->rail_started) {
        backend->rail_started = 1;
        if (client_rail_server_start_cmd(backend->rail) != CHANNEL_RC_OK) {
            return FALSE;
        }
    }
    if (desktop == NULL || (info->fieldFlags & WINDOW_ORDER_FIELD_DESKTOP_ZORDER) == 0u) {
        return TRUE;
    }
    backend->rail_zorder_count = 0u;
    for (index = 0u; index < desktop->numWindowIds && index < MR_FREERDP_RAIL_WINDOWS; index++) {
        backend->rail_zorder[backend->rail_zorder_count++] = desktop->windowIds[index];
    }
    mr_freerdp_rail_compose_all(context);
    return TRUE;
}

/* A window surface changed: repaint what it covers. Called by the
 * graphics pipeline with its lock held, outside a paint. */
static UINT mr_freerdp_update_window_from_surface(RdpgfxClientContext *gfx, gdiGfxSurface *surface)
{
    rdpGdi *gdi = (rdpGdi *)gfx->custom;
    mr_freerdp_backend *backend;
    const mr_freerdp_rail_window *window;
    const RECTANGLE_16 *rects;
    UINT32 count = 0u;
    UINT32 index;
    if (gdi == NULL || gdi->context == NULL) {
        return CHANNEL_RC_OK;
    }
    backend = ((mr_freerdp_context *)gdi->context)->backend;
    window = backend != NULL ? mr_freerdp_rail_find(backend, (UINT32)surface->windowId) : NULL;
    if (window != NULL && window->shown && !gdi->suppressOutput) {
        rects = region16_rects(&surface->invalidRegion, &count);
        /* Graphics run on the connection's thread (synchronous channels), so
         * this paints between updates, as gdi's own output update does. */
        if (rects != NULL && count > 0u && mr_freerdp_begin_paint(gdi->context)) {
            for (index = 0u; index < count; index++) {
                mr_freerdp_rail_compose(backend, gdi, window->x + rects[index].left,
                                        window->y + rects[index].top,
                                        window->x + rects[index].right,
                                        window->y + rects[index].bottom);
            }
            (void)mr_freerdp_end_paint(gdi->context);
        }
    }
    region16_clear(&surface->invalidRegion);
    return CHANNEL_RC_OK;
}


static BOOL mr_freerdp_audin_format_supported(IAudinDevice *device, const AUDIO_FORMAT *format)
{
    (void)device;
    return format != NULL && format->wFormatTag == WAVE_FORMAT_PCM &&
        format->wBitsPerSample == 16u && format->nChannels >= 1u && format->nChannels <= 2u &&
        format->nSamplesPerSec >= 8000u && format->nSamplesPerSec <= 48000u;
}

static UINT mr_freerdp_audin_set_format(IAudinDevice *device, const AUDIO_FORMAT *format, UINT32 frames)
{
    mr_freerdp_audin_device *audin = (mr_freerdp_audin_device *)device;
    if (audin == NULL || format == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    audin->format = *format;
    audin->format.data = NULL;
    audin->format.cbSize = 0u;
    audin->frames_per_packet = frames;
    return CHANNEL_RC_OK;
}

static UINT mr_freerdp_audin_open(IAudinDevice *device, AudinReceive receive, void *user_data)
{
    mr_freerdp_audin_device *audin = (mr_freerdp_audin_device *)device;
    mr_freerdp_backend *backend;
    mr_rdp_status status;
    if (audin == NULL || receive == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    backend = audin->backend;
    audin->receive = receive;
    audin->user_data = user_data;
    (void)pthread_mutex_lock(&backend->mutex);
    backend->audin = audin;
    backend->audin_open = 1;
    backend->capture_count = 0u;
    (void)pthread_mutex_unlock(&backend->mutex);
    status = backend->host.audio_capture(
        backend->host.context, 1, audin->format.nSamplesPerSec,
        audin->format.nChannels, audin->format.wBitsPerSample);
    if (status != MR_RDP_STATUS_OK && status != MR_RDP_ERROR_STOPPED) {
        mr_freerdp_record_status(backend, status);
    }
    return CHANNEL_RC_OK;
}

static UINT mr_freerdp_audin_close(IAudinDevice *device)
{
    mr_freerdp_audin_device *audin = (mr_freerdp_audin_device *)device;
    mr_freerdp_backend *backend;
    int was_open;
    if (audin == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    backend = audin->backend;
    (void)pthread_mutex_lock(&backend->mutex);
    was_open = backend->audin_open && backend->audin == audin;
    if (backend->audin == audin) {
        backend->audin_open = 0;
        backend->capture_count = 0u;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (was_open) {
        (void)backend->host.audio_capture(backend->host.context, 0, 0u, 0u, 0u);
    }
    return CHANNEL_RC_OK;
}

static UINT mr_freerdp_audin_free(IAudinDevice *device)
{
    mr_freerdp_audin_device *audin = (mr_freerdp_audin_device *)device;
    if (audin == NULL) {
        return CHANNEL_RC_OK;
    }
    (void)pthread_mutex_lock(&audin->backend->mutex);
    if (audin->backend->audin == audin) {
        audin->backend->audin = NULL;
        audin->backend->audin_open = 0;
    }
    (void)pthread_mutex_unlock(&audin->backend->mutex);
    free(audin);
    return CHANNEL_RC_OK;
}

static UINT VCAPITYPE mr_freerdp_audin_entry(PFREERDP_AUDIN_DEVICE_ENTRY_POINTS entry)
{
    mr_freerdp_audin_device *audin;
    mr_freerdp_backend *backend;
    if (entry == NULL || entry->rdpcontext == NULL || entry->pRegisterAudinDevice == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    backend = ((mr_freerdp_context *)entry->rdpcontext)->backend;
    if (backend == NULL) {
        return ERROR_INVALID_PARAMETER;
    }
    audin = (mr_freerdp_audin_device *)calloc(1u, sizeof(*audin));
    if (audin == NULL) {
        return CHANNEL_RC_NO_MEMORY;
    }
    audin->backend = backend;
    audin->iface.Open = mr_freerdp_audin_open;
    audin->iface.FormatSupported = mr_freerdp_audin_format_supported;
    audin->iface.SetFormat = mr_freerdp_audin_set_format;
    audin->iface.Close = mr_freerdp_audin_close;
    audin->iface.Free = mr_freerdp_audin_free;
    if (entry->pRegisterAudinDevice(entry->plugin, &audin->iface) != CHANNEL_RC_OK) {
        free(audin);
        return ERROR_INTERNAL_ERROR;
    }
    return CHANNEL_RC_OK;
}

/* Hands what the app captured to audin, a packet at a time. On the worker. */
static void mr_freerdp_feed_audio_capture(mr_freerdp_backend *backend)
{
    uint8_t packet[MR_RDP_MAX_AUDIO_CAPTURE_PACKET_BYTES];
    for (;;) {
        mr_freerdp_audin_device *audin;
        size_t take;
        (void)pthread_mutex_lock(&backend->mutex);
        audin = backend->audin_open ? backend->audin : NULL;
        take = backend->capture_count < sizeof(packet) ? backend->capture_count : sizeof(packet);
        if (audin != NULL && audin->format.nBlockAlign != 0u) {
            take -= take % audin->format.nBlockAlign;
        }
        if (audin == NULL || take == 0u) {
            (void)pthread_mutex_unlock(&backend->mutex);
            return;
        }
        memcpy(packet, backend->capture, take);
        memmove(backend->capture, backend->capture + take, backend->capture_count - take);
        backend->capture_count -= take;
        (void)pthread_mutex_unlock(&backend->mutex);
        (void)audin->receive(&audin->format, packet, take, audin->user_data);
    }
}

static mr_rdp_status mr_freerdp_send_audio_capture(
    mr_rdp_backend *base,
    const uint8_t *bytes,
    size_t byte_count)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    (void)pthread_mutex_lock(&backend->mutex);
    if (!backend->audin_open) {
        (void)pthread_mutex_unlock(&backend->mutex);
        return MR_RDP_STATUS_OK;
    }
    if (byte_count >= MR_FREERDP_CAPTURE_CAPACITY) {
        bytes += byte_count - MR_FREERDP_CAPTURE_CAPACITY;
        byte_count = MR_FREERDP_CAPTURE_CAPACITY;
        backend->capture_count = 0u;
    } else if (backend->capture_count + byte_count > MR_FREERDP_CAPTURE_CAPACITY) {
        /* Behind: the oldest goes, so the voice stays close to real time. */
        const size_t drop = backend->capture_count + byte_count - MR_FREERDP_CAPTURE_CAPACITY;
        memmove(backend->capture, backend->capture + drop, backend->capture_count - drop);
        backend->capture_count -= drop;
    }
    memcpy(backend->capture + backend->capture_count, bytes, byte_count);
    backend->capture_count += byte_count;
    (void)SetEvent(backend->command_event);
    (void)pthread_mutex_unlock(&backend->mutex);
    return MR_RDP_STATUS_OK;
}

static BOOL mr_freerdp_pre_connect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    rdpSettings *settings;
    /* latency: how far ahead of its own play clock rdpsnd lets audio run
     * before it drops a wave (rdpsnd_detect_overrun). At the default 0 that
     * is one wave: a few waves arriving together after a Wi-Fi stall - a
     * server streaming live audio sends them as they are made - lost one,
     * a click every few seconds. The app's ring absorbs this much. */
    const char *rdpsnd[] = { "rdpsnd", "sys:" MR_FREERDP_RDPSND_SUBSYSTEM,
                             "latency:" MR_FREERDP_RDPSND_LATENCY_MS };
    const BOOL audio = (backend != NULL &&
        (backend->channel_flags & MR_RDP_CHANNEL_FLAG_AUDIO) != 0u) ? TRUE : FALSE;
    const BOOL clipboard = (backend != NULL &&
        (backend->channel_flags & MR_RDP_CHANNEL_FLAG_CLIPBOARD) != 0u) ? TRUE : FALSE;
    /* ABI 4. MultiTouchInput makes the loader add rdpei. */
    const BOOL touch = (backend != NULL &&
        (backend->channel_flags & MR_RDP_CHANNEL_FLAG_TOUCH) != 0u) ? TRUE : FALSE;
    /* ABI 5. audin with this adapter's own subsystem: the app's PCM. */
    const BOOL microphone = (backend != NULL &&
        (backend->channel_flags & MR_RDP_CHANNEL_FLAG_MICROPHONE) != 0u) ? TRUE : FALSE;
    const char *audin[] = { "audin", "sys:" MR_FREERDP_RDPSND_SUBSYSTEM };
    /* ABI 6. The add-in provider answers this name with the MACRDPX entry. */
    const char *macrdpx[] = { MRX_CHANNEL_NAME };
    const BOOL mac_extensions = (backend != NULL &&
        (backend->channel_flags & MR_RDP_CHANNEL_FLAG_MACRDPX) != 0u) ? TRUE : FALSE;

    if (backend == NULL || instance->context == NULL ||
        instance->context->settings == NULL || mr_freerdp_is_stopped(backend)) {
        if (backend != NULL) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        }
        return FALSE;
    }
    settings = instance->context->settings;
    /* Schedule rdpsnd with explicit iOS arguments before the common add-in
     * loader runs. In FreeRDP 3.31.1 client/common/cmdline.c, both
     * freerdp_client_add_*_channel functions return at the duplicate-name
     * lookup before allocating a replacement ADDIN_ARGV. The loader's later
     * one-argument registrations therefore preserve this sys:ios selection.
     * Register both forms because the server may negotiate the SVC or DVC.
     * The loader also enables RDPDR for rdpsnd and loads cliprdr/drdynvc plus
     * the requested DVCs. AudioPlayback must be true for that path. The
     * subsystem is this adapter's own device (mr_freerdp_rdpsnd_entry), so the
     * PCM reaches the app's per-session focus policy instead of FreeRDP's
     * process-wide iOS AudioQueue. */
    if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, audio) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, microphone) ||
        (microphone &&
         !freerdp_client_add_dynamic_channel(settings, sizeof(audin) / sizeof(audin[0]), audin)) ||
        (mac_extensions &&
         !freerdp_client_add_static_channel(settings, 1, macrdpx)) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, clipboard) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_MultiTouchInput, touch) ||
        (audio &&
         (!freerdp_client_add_static_channel(
              settings, sizeof(rdpsnd) / sizeof(rdpsnd[0]), rdpsnd) ||
          !freerdp_client_add_dynamic_channel(
              settings, sizeof(rdpsnd) / sizeof(rdpsnd[0]), rdpsnd)))) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }

    if (!backend->channels_subscribed) {
        if (PubSub_SubscribeChannelConnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_connected) < 0) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
            return FALSE;
        }
        if (PubSub_SubscribeChannelDisconnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_disconnected) < 0) {
            PubSub_UnsubscribeChannelConnected(
                instance->context->pubSub,
                mr_freerdp_on_channel_connected);
            mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
            return FALSE;
        }
        backend->channels_subscribed = 1;
    }
    if (mr_freerdp_is_stopped(backend)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        return FALSE;
    }
    return TRUE;
}

static BOOL mr_freerdp_post_connect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    rdpContext *context;
    uint32_t width;
    uint32_t height;
    mr_rdp_status status;

    if (backend == NULL || instance->context == NULL ||
        instance->context->settings == NULL || instance->context->update == NULL ||
        mr_freerdp_is_stopped(backend)) {
        if (backend != NULL) {
            mr_freerdp_record_status(backend, MR_RDP_ERROR_STOPPED);
        }
        return FALSE;
    }
    context = instance->context;
    /* PostConnect is reached only after authentication. This adapter does not
     * support automatic reconnect, so retaining FreeRDP's credential copy for
     * the rest of the desktop session serves no purpose. */
    mr_freerdp_clear_password(context->settings);
    /* The protocol constants are adapter-local: they are internal in pinned
     * FreeRDP 3.31.1. Whatever the server selected has to be one the
     * session's policy allows - the negotiation offered only those, so this
     * is the check that it held - and HYBRID_EX, RDSTLS and AAD never reach
     * GDI/input activation under any policy. */
    if (!mr_freerdp_protocol_allowed(
            backend->security_policy,
            freerdp_settings_get_uint32(context->settings, FreeRDP_SelectedProtocol))) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_UNSUPPORTED);
        return FALSE;
    }
    width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_BACKEND);
        return FALSE;
    }
    backend->gdi_initialized = 1;
    ++backend->surface_generation;
    if (backend->surface_generation == 0u) {
        mr_freerdp_record_status(backend, MR_RDP_ERROR_LIMIT_EXCEEDED);
        return FALSE;
    }
    {
        mr_freerdp_pointer prototype;
        memset(&prototype, 0, sizeof(prototype));
        prototype.pointer.size = sizeof(mr_freerdp_pointer);
        prototype.pointer.New = mr_freerdp_pointer_new;
        prototype.pointer.Free = mr_freerdp_pointer_free;
        prototype.pointer.Set = mr_freerdp_pointer_set;
        prototype.pointer.SetNull = mr_freerdp_pointer_set_null;
        prototype.pointer.SetDefault = mr_freerdp_pointer_set_default;
        prototype.pointer.SetPosition = mr_freerdp_pointer_set_position;
        graphics_register_pointer(context->graphics, &prototype.pointer);
    }
    context->update->BeginPaint = mr_freerdp_begin_paint;
    context->update->EndPaint = mr_freerdp_end_paint;
    context->update->DesktopResize = mr_freerdp_desktop_resize;
    if (freerdp_settings_get_bool(context->settings, FreeRDP_RemoteApplicationMode) &&
        context->update->window != NULL) {
        context->update->window->WindowCreate = mr_freerdp_window_state;
        context->update->window->WindowUpdate = mr_freerdp_window_state;
        context->update->window->WindowDelete = mr_freerdp_window_delete;
        context->update->window->MonitoredDesktop = mr_freerdp_monitored_desktop;
    }

    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = !backend->stop_requested;
    (void)pthread_mutex_unlock(&backend->mutex);
    status = backend->host.connected(
        backend->host.context,
        mr_freerdp_transport_security(
            freerdp_settings_get_uint32(context->settings, FreeRDP_SelectedProtocol)));
    if (status != MR_RDP_STATUS_OK) {
        (void)pthread_mutex_lock(&backend->mutex);
        backend->accepting_input = 0;
        (void)pthread_mutex_unlock(&backend->mutex);
        mr_freerdp_record_status(backend, status);
        return FALSE;
    }
    return TRUE;
}

static void mr_freerdp_post_disconnect(freerdp *instance)
{
    mr_freerdp_backend *backend = mr_freerdp_backend_from_instance(instance);
    mr_freerdp_clipboard_probe *pending_probe;
    mr_freerdp_clipboard_probe *active_probe;
    mr_freerdp_clipboard_offer *announce;
    mr_freerdp_clipboard_offer *current;
    if (backend == NULL || instance->context == NULL) {
        return;
    }
    /* The decoders belong to surfaces that are gone with the connection. */
    mr_freerdp_h264_release_all(backend);
    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = 0;
    backend->audin_open = 0;
    backend->capture_count = 0u;
    mr_input_command_queue_reset(&backend->command_queue);
    if (backend->cliprdr != NULL) {
        backend->cliprdr->custom = NULL;
    }
    backend->cliprdr = NULL;
    backend->cliprdr_ready = 0;
    backend->disp = NULL;
    backend->gfx = NULL;
    backend->rail = NULL;
    backend->rail_window_count = 0u;
    backend->rail_zorder_count = 0u;
    pending_probe = backend->pending_clipboard_probe;
    active_probe = backend->active_clipboard_probe;
    backend->pending_clipboard_probe = NULL;
    backend->active_clipboard_probe = NULL;
    mr_control_deadline_reset(&backend->clipboard_probe_deadline);
    backend->clipboard_probe_timed_out = 0;
    backend->display_resize_pending = 0;
    memset(&backend->pending_display_resize, 0,
           sizeof(backend->pending_display_resize));
    mr_freerdp_take_clipboard_state_locked(backend, &announce, &current);
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_probe_destroy(pending_probe);
    mr_freerdp_clipboard_probe_destroy(active_probe);
    mr_freerdp_clipboard_offer_destroy(announce);
    mr_freerdp_clipboard_offer_destroy(current);
    if (backend->channels_subscribed) {
        PubSub_UnsubscribeChannelConnected(
            instance->context->pubSub,
            mr_freerdp_on_channel_connected);
        PubSub_UnsubscribeChannelDisconnected(
            instance->context->pubSub,
            mr_freerdp_on_channel_disconnected);
        backend->channels_subscribed = 0;
    }
    if (backend->gdi_initialized) {
        gdi_free(instance);
        backend->gdi_initialized = 0;
    }
}

static BOOL mr_freerdp_send_key_command(
    mr_freerdp_backend *backend,
    const mr_rdp_key_event *event)
{
    UINT16 flags = 0u;
    rdpInput *input;
    if (backend->context == NULL || backend->context->input == NULL) {
        return FALSE;
    }
    input = backend->context->input;
    if (event->action == MR_RDP_KEY_UP) {
        flags |= KBD_FLAGS_RELEASE;
    }
    if (event->extended != 0u) {
        flags |= KBD_FLAGS_EXTENDED;
    }
    if (event->extended1 != 0u) {
        flags |= KBD_FLAGS_EXTENDED1;
    }
    /* Do not use freerdp_input_send_keyboard_event_ex: the 3.31.1 helper
     * derives EXTENDED but cannot preserve an explicit EXTENDED1 selector. */
    return freerdp_input_send_keyboard_event(input, flags, (UINT8)event->code);
}

static BOOL mr_freerdp_send_wheel_axis(
    rdpInput *input,
    UINT16 axis_flag,
    int32_t value,
    UINT16 x,
    UINT16 y)
{
    uint64_t remaining;
    int negative;
    if (value == 0) {
        return TRUE;
    }
    negative = value < 0;
    remaining = negative
        ? (uint64_t)(-(int64_t)value)
        : (uint64_t)value;
    while (remaining > 0u) {
        const UINT16 magnitude = remaining > 0xffu
            ? 0xffu
            : (UINT16)remaining;
        UINT16 encoded = magnitude;
        UINT16 flags = axis_flag;
        if (negative) {
            flags |= PTR_FLAGS_WHEEL_NEGATIVE;
            encoded = (UINT16)(0x100u - magnitude);
        }
        if (!freerdp_input_send_mouse_event(input, (UINT16)(flags | encoded), x, y)) {
            return FALSE;
        }
        remaining -= magnitude;
    }
    return TRUE;
}

static BOOL mr_freerdp_send_pointer_command(
    mr_freerdp_backend *backend,
    const mr_rdp_pointer_event *event)
{
    rdpInput *input;
    UINT16 flags;
    UINT16 x;
    UINT16 y;
    if (backend->context == NULL || backend->context->input == NULL ||
        event->x > UINT16_MAX || event->y > UINT16_MAX) {
        return FALSE;
    }
    input = backend->context->input;
    x = (UINT16)event->x;
    y = (UINT16)event->y;
    if (event->kind == MR_RDP_POINTER_MOVE) {
        return freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
    }
    if (event->kind == MR_RDP_POINTER_BUTTON) {
        switch (event->button) {
            case MR_RDP_POINTER_BUTTON_LEFT:
                flags = PTR_FLAGS_BUTTON1;
                break;
            case MR_RDP_POINTER_BUTTON_RIGHT:
                flags = PTR_FLAGS_BUTTON2;
                break;
            case MR_RDP_POINTER_BUTTON_MIDDLE:
                flags = PTR_FLAGS_BUTTON3;
                break;
            default:
                return FALSE;
        }
        if (event->action == MR_RDP_KEY_DOWN) {
            flags |= PTR_FLAGS_DOWN;
        }
        return freerdp_input_send_mouse_event(input, flags, x, y);
    }
    if (!mr_freerdp_send_wheel_axis(
            input, PTR_FLAGS_WHEEL, event->wheel_y, x, y)) {
        return FALSE;
    }
    return mr_freerdp_send_wheel_axis(
        input, PTR_FLAGS_HWHEEL, event->wheel_x, x, y);
}

/* FreeRDP cancels a touch as UPDATE|CANCELED, which its RDPEI client never
 * retires: the finger goes on being sent as held in every later frame, and
 * Windows ignores the mouse buttons meanwhile (a two-finger tap taking over
 * from a touch did not right-click). RDPEI's own TouchCancel sends
 * UP|CANCELED. FreeRDP's contact table, too, frees a slot only on UP, so ten
 * cancels would leave no room for another finger: the slot is freed here. */
static BOOL mr_freerdp_cancel_touch(
    rdpClientContext *client,
    const mr_rdp_touch_event *event)
{
    BOOL ok;
    if (client->rdpei != NULL && client->rdpei->TouchCancel != NULL) {
        INT32 rdpei_contact = 0;
        ok = freerdp_get_state(&client->context) != CONNECTION_STATE_ACTIVE ||
            client->rdpei->TouchCancel(
                client->rdpei, (INT32)event->contact_id, (INT32)event->x,
                (INT32)event->y, &rdpei_contact) == CHANNEL_RC_OK;
    } else {
        ok = freerdp_client_handle_touch(
            client, FREERDP_TOUCH_CANCEL, (INT32)event->contact_id, 0u,
            (INT32)event->x, (INT32)event->y);
    }
    for (size_t i = 0; i < ARRAYSIZE(client->contacts); i++) {
        if (client->contacts[i].id == (INT32)event->contact_id) {
            const FreeRDP_TouchContact empty = { 0 };
            client->contacts[i] = empty;
            break;
        }
    }
    return ok;
}

/* Before RDPEI connects - a logon screen - FreeRDP turns a touch into the
 * left button itself, so this never needs to know. */
static BOOL mr_freerdp_send_touch_command(
    mr_freerdp_backend *backend,
    const mr_rdp_touch_event *event)
{
    UINT32 flags;
    if (backend->context == NULL) {
        return FALSE;
    }
    switch (event->action) {
        case MR_RDP_TOUCH_DOWN:
            flags = FREERDP_TOUCH_DOWN;
            break;
        case MR_RDP_TOUCH_MOVE:
            flags = FREERDP_TOUCH_MOTION;
            break;
        case MR_RDP_TOUCH_UP:
            flags = FREERDP_TOUCH_UP;
            break;
        case MR_RDP_TOUCH_CANCEL:
            return mr_freerdp_cancel_touch((rdpClientContext *)backend->context, event);
        default:
            return FALSE;
    }
    return freerdp_client_handle_touch(
        (rdpClientContext *)backend->context, flags, (INT32)event->contact_id, 0u,
        (INT32)event->x, (INT32)event->y);
}

static BOOL mr_freerdp_send_pen_command(
    mr_freerdp_backend *backend,
    const mr_rdp_pen_event *event)
{
    rdpClientContext *client = (rdpClientContext *)backend->context;
    UINT32 flags = FREERDP_PEN_HAS_PRESSURE | FREERDP_PEN_HAS_ROTATION |
        FREERDP_PEN_HAS_TILTX | FREERDP_PEN_HAS_TILTY;
    if (client == NULL) {
        return FALSE;
    }
    /* A pen only works through RDPEI; without it the event is dropped
     * rather than failing the session. */
    if (client->rdpei == NULL) {
        return TRUE;
    }
    if (!backend->pen_registered) {
        if (!freerdp_client_handle_pen(
                client, FREERDP_PEN_REGISTER | FREERDP_PEN_HAS_PRESSURE,
                MR_FREERDP_PEN_DEVICE_ID, (double)MR_RDP_MAX_PEN_PRESSURE)) {
            return FALSE;
        }
        backend->pen_registered = 1;
    }
    switch (event->action) {
        case MR_RDP_PEN_DOWN:
            flags |= FREERDP_PEN_PRESS;
            break;
        case MR_RDP_PEN_UP:
            flags |= FREERDP_PEN_RELEASE;
            break;
        default:
            flags |= FREERDP_PEN_MOTION;
            break;
    }
    if ((event->flags & MR_RDP_PEN_FLAG_BARREL) != 0u) {
        flags |= FREERDP_PEN_BARREL_PRESSED;
    }
    if ((event->flags & MR_RDP_PEN_FLAG_ERASER) != 0u) {
        flags |= FREERDP_PEN_ERASER_PRESSED;
    }
    return freerdp_client_handle_pen(
        client, flags, MR_FREERDP_PEN_DEVICE_ID,
        (INT32)event->x, (INT32)event->y,
        /* Hovering has no pressure. */
        event->action == MR_RDP_PEN_HOVER ? 0.0 : (double)event->pressure,
        (unsigned)event->rotation, (int)event->tilt_x, (int)event->tilt_y);
}

static mr_rdp_status mr_freerdp_process_control_command(
    mr_freerdp_backend *backend,
    int *out_processed)
{
    mr_freerdp_clipboard_probe *probe = NULL;
    mr_rdp_display_resize_request resize_request;
    CliprdrClientContext *cliprdr = NULL;
    DispClientContext *disp = NULL;
    int process_resize = 0;
    mr_rdp_status gate_status = MR_RDP_STATUS_OK;
    mr_rdp_status operation_status;
    mr_rdp_status host_status;
    UINT channel_status;

    *out_processed = 0;
    memset(&resize_request, 0, sizeof(resize_request));
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        gate_status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        gate_status = backend->input_failure_status;
    } else if (backend->pending_clipboard_probe != NULL) {
        probe = backend->pending_clipboard_probe;
        backend->pending_clipboard_probe = NULL;
        cliprdr = backend->cliprdr_ready ? backend->cliprdr : NULL;
        if (cliprdr != NULL && backend->active_clipboard_probe == NULL) {
            backend->active_clipboard_probe = probe;
            mr_freerdp_arm_clipboard_probe_deadline_locked(
                backend, MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_RESPONSE);
        } else {
            cliprdr = NULL;
        }
        *out_processed = 1;
    } else if (backend->display_resize_pending) {
        resize_request = backend->pending_display_resize;
        memset(&backend->pending_display_resize, 0,
               sizeof(backend->pending_display_resize));
        backend->display_resize_pending = 0;
        disp = backend->disp;
        process_resize = 1;
        *out_processed = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (gate_status != MR_RDP_STATUS_OK) {
        return gate_status;
    }

    if (probe != NULL) {
        CLIPRDR_FORMAT format;
        CLIPRDR_FORMAT_LIST format_list;
        if (cliprdr == NULL) {
            operation_status = MR_RDP_ERROR_INVALID_STATE;
            host_status = mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT,
                operation_status);
        } else {
            memset(&format, 0, sizeof(format));
            memset(&format_list, 0, sizeof(format_list));
            format.formatId = CF_UNICODETEXT;
            format_list.common.msgType = CB_FORMAT_LIST;
            format_list.numFormats = 1u;
            format_list.formats = &format;
            channel_status = cliprdr->ClientFormatList == NULL
                ? CHANNEL_RC_INITIALIZATION_ERROR
                : cliprdr->ClientFormatList(cliprdr, &format_list);
            operation_status = channel_status == CHANNEL_RC_OK
                ? MR_RDP_STATUS_OK
                : MR_RDP_ERROR_BACKEND;
            host_status = mr_freerdp_emit_clipboard_probe_event(
                backend,
                probe,
                MR_RDP_CLIPBOARD_PROBE_FORMAT_LIST_SENT,
                operation_status);
        }
        if (operation_status != MR_RDP_STATUS_OK ||
            host_status != MR_RDP_STATUS_OK) {
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->active_clipboard_probe == probe) {
                backend->active_clipboard_probe = NULL;
                mr_control_deadline_reset(&backend->clipboard_probe_deadline);
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_clipboard_probe_destroy(probe);
        }
        return host_status;
    }

    if (process_resize) {
        DISPLAY_CONTROL_MONITOR_LAYOUT layouts[2];
        DISPLAY_CONTROL_MONITOR_LAYOUT *layout = &layouts[0];
        const UINT32 monitor_count = resize_request.secondary_width != 0u ? 2u : 1u;
        memset(layouts, 0, sizeof(layouts));
        layout->Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        layout->Width = resize_request.width;
        layout->Height = resize_request.height;
        if (backend->context != NULL && backend->context->settings != NULL) {
            rdpSettings *settings = backend->context->settings;
            /* ABI 3: a request's own factors replace the session's, here and
             * for every later layout, so a resize that only changes the size
             * does not quietly drop a scale chosen earlier. This runs on the
             * run thread, which owns the settings. */
            if (resize_request.desktop_scale_factor != 0u) {
                (void)freerdp_settings_set_uint32(
                    settings, FreeRDP_DesktopScaleFactor,
                    resize_request.desktop_scale_factor);
            }
            if (resize_request.device_scale_factor != 0u) {
                (void)freerdp_settings_set_uint32(
                    settings, FreeRDP_DeviceScaleFactor,
                    resize_request.device_scale_factor);
            }
            layout->Orientation = freerdp_settings_get_uint16(
                settings, FreeRDP_DesktopOrientation);
            layout->DesktopScaleFactor = freerdp_settings_get_uint32(
                settings, FreeRDP_DesktopScaleFactor);
            layout->DeviceScaleFactor = freerdp_settings_get_uint32(
                settings, FreeRDP_DeviceScaleFactor);
        }
        if (monitor_count == 2u) {
            /* ABI 4: the second monitor to the right, top-aligned, drawn at
             * 100%: a monitor is not a phone held close. */
            layouts[1].Left = (INT32)resize_request.width;
            layouts[1].Top = 0;
            layouts[1].Width = resize_request.secondary_width;
            layouts[1].Height = resize_request.secondary_height;
            layouts[1].Orientation = ORIENTATION_LANDSCAPE;
            layouts[1].DesktopScaleFactor = 100u;
            layouts[1].DeviceScaleFactor = 100u;
        }
        channel_status = disp == NULL || disp->SendMonitorLayout == NULL
            ? CHANNEL_RC_NOT_CONNECTED
            : disp->SendMonitorLayout(disp, monitor_count, layouts);
        operation_status = channel_status == CHANNEL_RC_OK
            ? MR_RDP_STATUS_OK
            : MR_RDP_ERROR_BACKEND;
        host_status = backend->host.display_resize_event(
            backend->host.context, &resize_request, operation_status);
        if (host_status != MR_RDP_STATUS_OK) {
            mr_freerdp_record_status(backend, host_status);
        }
        return host_status;
    }
    return MR_RDP_STATUS_OK;
}

/* Announces a pending offer or sends a pending text request. One piece of
 * work per call, like the control commands, so the batch limit still bounds
 * how long the run loop stays away from FreeRDP's own handles. */
static mr_rdp_status mr_freerdp_process_clipboard_command(
    mr_freerdp_backend *backend,
    int *out_processed)
{
    mr_freerdp_clipboard_offer *announce = NULL;
    mr_freerdp_clipboard_offer *replaced = NULL;
    uint64_t expired_request = 0u;
    int expired_kind = 0;
    uint64_t request = 0u;
    int request_kind = 0;
    UINT32 request_format = CF_UNICODETEXT;
    uint64_t replaced_failed_id = 0u;
    CliprdrClientContext *cliprdr = NULL;
    UINT channel_status;

    *out_processed = 0;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested || backend->input_failure_status != MR_RDP_STATUS_OK) {
        (void)pthread_mutex_unlock(&backend->mutex);
        return MR_RDP_STATUS_OK;
    }
    cliprdr = backend->cliprdr_ready ? backend->cliprdr : NULL;
    if (backend->expired_text_request_id != 0u) {
        expired_request = backend->expired_text_request_id;
        expired_kind = backend->expired_request_kind;
        backend->expired_text_request_id = 0u;
        backend->expired_request_kind = 0;
    } else if (backend->offer_to_announce != NULL) {
        announce = backend->offer_to_announce;
        backend->offer_to_announce = NULL;
        replaced = backend->current_offer;
        if (replaced != NULL && backend->offer_awaiting_response) {
            replaced_failed_id = replaced->offer_id;
        }
        backend->current_offer = cliprdr != NULL ? announce : NULL;
        backend->offer_awaiting_response = cliprdr != NULL;
    } else if (backend->pending_text_request_id != 0u) {
        request = backend->pending_text_request_id;
        request_kind = backend->pending_request_kind;
        backend->pending_text_request_id = 0u;
        backend->pending_request_kind = 0;
        /* PNG when the server offered it, CF_DIB otherwise; the file list
         * under the server's own id for it. Zero: nothing to ask for. */
        if (request_kind == MR_FREERDP_CLIP_IMAGE) {
            request_format = backend->remote_png_id != 0u ? backend->remote_png_id
                : backend->remote_has_dib ? CF_DIB : 0u;
            backend->outstanding_image_png = backend->remote_png_id != 0u;
        } else if (request_kind == MR_FREERDP_CLIP_FILES) {
            request_format = backend->remote_files_id;
        }
        if (cliprdr != NULL && request_format != 0u) {
            backend->outstanding_text_request_id = request;
            backend->outstanding_request_kind = request_kind;
            backend->outstanding_text_request_since = GetTickCount64();
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);

    if (expired_request != 0u) {
        *out_processed = 1;
        mr_freerdp_fail_request(backend, expired_request, expired_kind, MR_RDP_ERROR_TIMEOUT);
        return MR_RDP_STATUS_OK;
    }
    if (announce != NULL) {
        *out_processed = 1;
        mr_freerdp_emit_offer(
            backend, replaced_failed_id, MR_RDP_CLIPBOARD_OFFER_FAILED,
            MR_RDP_ERROR_INVALID_STATE);
        mr_freerdp_clipboard_offer_destroy(replaced);
        if (cliprdr == NULL || cliprdr->ClientFormatList == NULL) {
            mr_freerdp_emit_offer(
                backend, announce->offer_id, MR_RDP_CLIPBOARD_OFFER_FAILED,
                MR_RDP_ERROR_INVALID_STATE);
            if (cliprdr == NULL) {
                mr_freerdp_clipboard_offer_destroy(announce);
            }
            return MR_RDP_STATUS_OK;
        }
        {
            /* What the offer is, in the formats a Windows program pastes. */
            CLIPRDR_FORMAT formats[2];
            CLIPRDR_FORMAT_LIST format_list;
            char png_name[] = MR_FREERDP_FORMAT_PNG_NAME;
            char files_name[] = MR_FREERDP_FORMAT_FILES_NAME;
            memset(formats, 0, sizeof(formats));
            memset(&format_list, 0, sizeof(format_list));
            format_list.common.msgType = CB_FORMAT_LIST;
            if (announce->kind == MR_FREERDP_CLIP_IMAGE) {
                if (announce->dib != NULL) {
                    formats[format_list.numFormats++].formatId = CF_DIB;
                }
                if (announce->png != NULL) {
                    formats[format_list.numFormats].formatId = MR_FREERDP_FORMAT_PNG;
                    formats[format_list.numFormats++].formatName = png_name;
                }
            } else if (announce->kind == MR_FREERDP_CLIP_FILES) {
                formats[0].formatId = MR_FREERDP_FORMAT_FILES;
                formats[0].formatName = files_name;
                format_list.numFormats = 1u;
            } else {
                formats[0].formatId = CF_UNICODETEXT;
                format_list.numFormats = 1u;
            }
            format_list.formats = formats;
            channel_status = cliprdr->ClientFormatList(cliprdr, &format_list);
        }
        if (channel_status != CHANNEL_RC_OK) {
            uint64_t failed = 0u;
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->current_offer == announce) {
                backend->current_offer = NULL;
                backend->offer_awaiting_response = 0;
                failed = announce->offer_id;
            } else {
                announce = NULL;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_emit_offer(
                backend, failed, MR_RDP_CLIPBOARD_OFFER_FAILED, MR_RDP_ERROR_BACKEND);
            mr_freerdp_clipboard_offer_destroy(announce);
        }
        return MR_RDP_STATUS_OK;
    }
    if (request != 0u) {
        CLIPRDR_FORMAT_DATA_REQUEST data_request;
        *out_processed = 1;
        if (cliprdr == NULL || cliprdr->ClientFormatDataRequest == NULL || request_format == 0u) {
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->outstanding_text_request_id == request) {
                backend->outstanding_text_request_id = 0u;
                backend->outstanding_request_kind = 0;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            mr_freerdp_fail_request(
                backend, request, request_kind,
                request_format == 0u ? MR_RDP_ERROR_UNSUPPORTED : MR_RDP_ERROR_INVALID_STATE);
            return MR_RDP_STATUS_OK;
        }
        memset(&data_request, 0, sizeof(data_request));
        data_request.common.msgType = CB_FORMAT_DATA_REQUEST;
        data_request.requestedFormatId = request_format;
        channel_status = cliprdr->ClientFormatDataRequest(cliprdr, &data_request);
        if (channel_status != CHANNEL_RC_OK) {
            int owned = 0;
            (void)pthread_mutex_lock(&backend->mutex);
            if (backend->outstanding_text_request_id == request) {
                backend->outstanding_text_request_id = 0u;
                owned = 1;
            }
            (void)pthread_mutex_unlock(&backend->mutex);
            if (owned) {
                mr_freerdp_fail_request(backend, request, request_kind, MR_RDP_ERROR_BACKEND);
            }
        }
    }
    return MR_RDP_STATUS_OK;
}

static int mr_freerdp_has_pending_work_locked(const mr_freerdp_backend *backend)
{
    return backend->pending_clipboard_probe != NULL ||
        backend->display_resize_pending ||
        backend->offer_to_announce != NULL ||
        backend->pending_text_request_id != 0u ||
        backend->expired_text_request_id != 0u ||
        (backend->audin_open && backend->capture_count != 0u);
}

static mr_rdp_status mr_freerdp_enqueue_command(
    mr_freerdp_backend *backend,
    const mr_input_command *command)
{
    mr_input_enqueue_result result;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (!backend->accepting_input) {
        status = backend->input_failure_status != MR_RDP_STATUS_OK
            ? backend->input_failure_status
            : MR_RDP_ERROR_INVALID_STATE;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        result = mr_input_command_queue_enqueue(
            &backend->command_queue, command);
        if (result == MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW ||
            result == MR_INPUT_ENQUEUE_INVALID) {
            status = result == MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW
                ? MR_RDP_ERROR_LIMIT_EXCEEDED
                : MR_RDP_ERROR_BACKEND;
            backend->input_failure_status = status;
            backend->accepting_input = 0;
            mr_input_command_queue_reset(&backend->command_queue);
            context_to_abort = backend->context;
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    return status;
}

static int mr_freerdp_dequeue_command(
    mr_freerdp_backend *backend,
    mr_input_command *out_command,
    mr_rdp_status *out_status)
{
    int has_command = 0;
    (void)pthread_mutex_lock(&backend->mutex);
    *out_status = MR_RDP_STATUS_OK;
    if (backend->stop_requested) {
        *out_status = MR_RDP_ERROR_STOPPED;
        mr_input_command_queue_reset(&backend->command_queue);
        (void)ResetEvent(backend->command_event);
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        *out_status = backend->input_failure_status;
        mr_input_command_queue_reset(&backend->command_queue);
        (void)ResetEvent(backend->command_event);
    } else if (mr_input_command_queue_dequeue(
                   &backend->command_queue, out_command)) {
        has_command = 1;
        if (mr_input_command_queue_count(&backend->command_queue) == 0u &&
            !mr_freerdp_has_pending_work_locked(backend)) {
            (void)ResetEvent(backend->command_event);
        }
    } else {
        if (!mr_freerdp_has_pending_work_locked(backend)) {
            (void)ResetEvent(backend->command_event);
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return has_command;
}

static mr_rdp_status mr_freerdp_drain_commands(mr_freerdp_backend *backend)
{
    size_t commands_processed = 0u;
    for (;;) {
        mr_input_command command;
        mr_rdp_status dequeue_status;
        mr_rdp_status control_status;
        int processed_control;
        BOOL sent;
        control_status = mr_freerdp_process_control_command(
            backend, &processed_control);
        if (control_status != MR_RDP_STATUS_OK) {
            return control_status;
        }
        if (processed_control) {
            continue;
        }
        mr_freerdp_feed_audio_capture(backend);
        control_status = mr_freerdp_process_clipboard_command(
            backend, &processed_control);
        if (control_status != MR_RDP_STATUS_OK) {
            return control_status;
        }
        if (processed_control) {
            continue;
        }
        if (!mr_freerdp_dequeue_command(
                backend, &command, &dequeue_status)) {
            return dequeue_status;
        }
        if (command.kind == MR_INPUT_COMMAND_KEY) {
            sent = mr_freerdp_send_key_command(backend, &command.value.key);
        } else if (command.kind == MR_INPUT_COMMAND_POINTER) {
            sent = mr_freerdp_send_pointer_command(backend, &command.value.pointer);
        } else if (command.kind == MR_INPUT_COMMAND_TOUCH) {
            sent = mr_freerdp_send_touch_command(backend, &command.value.touch);
        } else if (command.kind == MR_INPUT_COMMAND_PEN) {
            sent = mr_freerdp_send_pen_command(backend, &command.value.pen);
        } else if (command.kind == MR_INPUT_COMMAND_MACRDPX) {
            sent = mr_freerdp_send_macrdpx_command(backend, &command.value.macrdpx);
        } else if (command.kind == MR_INPUT_COMMAND_UNICODE) {
            sent = backend->context != NULL && backend->context->input != NULL &&
                freerdp_input_send_unicode_keyboard_event(
                    backend->context->input, 0u, command.value.unicode.code_unit) &&
                freerdp_input_send_unicode_keyboard_event(
                    backend->context->input, KBD_FLAGS_RELEASE,
                    command.value.unicode.code_unit);
        } else {
            sent = FALSE;
        }
        if (!sent) {
            return MR_RDP_ERROR_BACKEND;
        }
        ++commands_processed;
        if (commands_processed >= MR_FREERDP_COMMAND_BATCH_LIMIT) {
            /* Leave command_event signaled while work remains. Returning to
             * the outer loop gives FreeRDP handles and control deadlines a
             * bounded chance to run under sustained input. */
            return MR_RDP_STATUS_OK;
        }
    }
}

static mr_rdp_status mr_freerdp_run(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    BOOL connected;

    base->last_native_error = 0;
    if (mr_freerdp_is_stopped(backend)) {
        return MR_RDP_ERROR_STOPPED;
    }
    connected = freerdp_connect(backend->instance);
    if (!connected) {
        status = mr_freerdp_current_status(backend);
        /* Without this the app only sees MR_RDP_ERROR_BACKEND and cannot tell
         * a refused socket from a logon failure. FreeRDP's own connect error
         * survives freerdp_connect returning FALSE. */
        base->last_native_error = (int32_t)freerdp_get_last_error(backend->context);
        if (mr_freerdp_is_stopped(backend)) {
            status = MR_RDP_ERROR_STOPPED;
        } else if (status == MR_RDP_STATUS_OK) {
            status = MR_RDP_ERROR_BACKEND;
        }
        goto cleanup;
    }

    while (!freerdp_shall_disconnect_context(backend->context)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS];
        DWORD handle_count;
        DWORD wait_status;
        DWORD wait_timeout;

        if (mr_freerdp_is_stopped(backend)) {
            status = MR_RDP_ERROR_STOPPED;
            break;
        }
        status = mr_freerdp_expire_clipboard_probe(backend);
        if (status != MR_RDP_STATUS_OK) {
            break;
        }
        memset(handles, 0, sizeof(handles));
        handle_count = freerdp_get_event_handles(
            backend->context, handles, MAXIMUM_WAIT_OBJECTS - 1u);
        if (handle_count == 0u || handle_count >= MAXIMUM_WAIT_OBJECTS) {
            status = MR_RDP_ERROR_BACKEND;
            break;
        }
        handles[handle_count++] = backend->command_event;
        wait_timeout = mr_freerdp_clipboard_probe_wait_timeout(backend);
        wait_status = WaitForMultipleObjects(
            handle_count, handles, FALSE, wait_timeout);
        if (wait_status == WAIT_FAILED) {
            status = MR_RDP_ERROR_BACKEND;
            break;
        }
        if (wait_status == WAIT_TIMEOUT) {
            status = mr_freerdp_expire_clipboard_probe(backend);
            if (status != MR_RDP_STATUS_OK) {
                break;
            }
            continue;
        }

        status = mr_freerdp_drain_commands(backend);
        if (status != MR_RDP_STATUS_OK) {
            break;
        }
        if (!freerdp_check_event_handles(backend->context)) {
            status = mr_freerdp_current_status(backend);
            if (status == MR_RDP_STATUS_OK) {
                status = MR_RDP_ERROR_BACKEND;
            }
            break;
        }
    }

    if (status == MR_RDP_STATUS_OK) {
        status = mr_freerdp_current_status(backend);
    }
    /* Read whenever this side did not ask for the stop, not only after an
     * adapter error. A server that ends the session - another connection
     * taking it over, a sign-out, an idle timeout - sends Set Error Info,
     * which FreeRDP keeps as its last error (ERRINFO class) while the loop
     * itself ends cleanly. Reading it only on a failed status reported all
     * of those as a failure with no cause, which the app then retried. */
    if (!mr_freerdp_is_stopped(backend)) {
        base->last_native_error = (int32_t)freerdp_get_last_error(backend->context);
    }
    if (mr_freerdp_is_stopped(backend)) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (status == MR_RDP_STATUS_OK) {
        status = MR_RDP_ERROR_BACKEND;
    }

cleanup:
    (void)pthread_mutex_lock(&backend->mutex);
    backend->accepting_input = 0;
    (void)pthread_mutex_unlock(&backend->mutex);
    /* FreeRDP 3.31.1 already disconnects internally when connect fails. */
    if (connected) {
        (void)freerdp_disconnect(backend->instance);
    }
    mr_freerdp_clear_password(backend->context->settings);
    return status;
}

static void mr_freerdp_request_stop(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    rdpContext *context;
    (void)pthread_mutex_lock(&backend->mutex);
    backend->stop_requested = 1;
    backend->accepting_input = 0;
    context = backend->context;
    if (backend->command_event != NULL) {
        (void)SetEvent(backend->command_event);
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context != NULL) {
        (void)freerdp_abort_connect_context(context);
    }
}

static mr_rdp_status mr_freerdp_send_key(
    mr_rdp_backend *base,
    const mr_rdp_key_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_KEY;
    command.value.key = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_send_pointer(
    mr_rdp_backend *base,
    const mr_rdp_pointer_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    if (event->x > UINT16_MAX || event->y > UINT16_MAX) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_POINTER;
    command.value.pointer = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_send_touch(
    mr_rdp_backend *base,
    const mr_rdp_touch_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_TOUCH;
    command.value.touch = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_send_pen(
    mr_rdp_backend *base,
    const mr_rdp_pen_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_PEN;
    command.value.pen = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_send_macrdpx(
    mr_rdp_backend *base,
    const mrx_message *message)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_MACRDPX;
    command.value.macrdpx = *message;
    return mr_freerdp_enqueue_command(backend, &command);
}

static mr_rdp_status mr_freerdp_start_clipboard_probe(
    mr_rdp_backend *base,
    const mr_rdp_backend_clipboard_probe *probe)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_freerdp_clipboard_probe *copy;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (backend == NULL || probe == NULL || probe->probe_id == 0u ||
        probe->utf16le_bytes == NULL || probe->utf16le_byte_count == 0u ||
        probe->utf16le_byte_count > MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    copy = (mr_freerdp_clipboard_probe *)calloc(1u, sizeof(*copy));
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->bytes = (uint8_t *)malloc(probe->utf16le_byte_count);
    if (copy->bytes == NULL) {
        mr_freerdp_clipboard_probe_destroy(copy);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(copy->bytes, probe->utf16le_bytes, probe->utf16le_byte_count);
    copy->descriptor = *probe;
    copy->descriptor.utf16le_bytes = copy->bytes;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->cliprdr == NULL ||
               !backend->cliprdr_ready) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->clipboard_probe_timed_out) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->pending_clipboard_probe != NULL ||
               backend->active_clipboard_probe != NULL) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        backend->pending_clipboard_probe = copy;
        copy = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    mr_freerdp_clipboard_probe_destroy(copy);
    return status;
}

static mr_rdp_status mr_freerdp_request_display_resize(
    mr_rdp_backend *base,
    const mr_rdp_display_resize_request *request)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    rdpContext *context_to_abort = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    if (backend == NULL || request == NULL || request->request_id == 0u ||
        request->width < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->width > MR_RDP_MAX_DESKTOP_DIMENSION ||
        request->height < MR_RDP_MIN_DESKTOP_DIMENSION ||
        request->height > MR_RDP_MAX_DESKTOP_DIMENSION) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->disp == NULL) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->display_resize_pending) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
        backend->input_failure_status = status;
        backend->accepting_input = 0;
        mr_input_command_queue_reset(&backend->command_queue);
        context_to_abort = backend->context;
    } else {
        backend->pending_display_resize = *request;
        backend->display_resize_pending = 1;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    if (context_to_abort != NULL) {
        (void)freerdp_abort_connect_context(context_to_abort);
    }
    return status;
}

static mr_rdp_status mr_freerdp_send_unicode(
    mr_rdp_backend *base,
    const mr_rdp_unicode_event *event)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_UNICODE;
    command.value.unicode = *event;
    return mr_freerdp_enqueue_command(backend, &command);
}

static void mr_freerdp_set_audio_focused(mr_rdp_backend *base, int focused)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    size_t index;
    /* Held across the sink calls: rdpsnd's Free unregisters under the same
     * lock, so a sink cannot be freed between being read and being told. */
    (void)pthread_mutex_lock(&backend->mutex);
    backend->audio_focused = focused != 0;
    for (index = 0u; index < MR_FREERDP_MAX_AUDIO_SINKS; ++index) {
        if (backend->audio_sinks[index] != NULL) {
            (void)mr_rdpsnd_device_set_focused(
                backend->audio_sinks[index], focused ? 1u : 0u);
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
}

static mr_rdp_status mr_freerdp_queue_offer(
    mr_freerdp_backend *backend,
    mr_freerdp_clipboard_offer *copy);

static mr_rdp_status mr_freerdp_offer_clipboard_text(
    mr_rdp_backend *base,
    const mr_rdp_backend_clipboard_offer *offer)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_freerdp_clipboard_offer *copy;
    if (offer == NULL || offer->offer_id == 0u || offer->utf16le_bytes == NULL ||
        offer->utf16le_byte_count == 0u) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    copy = (mr_freerdp_clipboard_offer *)calloc(1u, sizeof(*copy));
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->bytes = (uint8_t *)malloc(offer->utf16le_byte_count);
    if (copy->bytes == NULL) {
        free(copy);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    memcpy(copy->bytes, offer->utf16le_bytes, offer->utf16le_byte_count);
    copy->byte_count = offer->utf16le_byte_count;
    copy->offer_id = offer->offer_id;
    copy->kind = MR_FREERDP_CLIP_TEXT;
    return mr_freerdp_queue_offer(backend, copy);
}

/* Takes ownership of `copy`: the newest offer is announced on the worker. */
static mr_rdp_status mr_freerdp_queue_offer(
    mr_freerdp_backend *backend,
    mr_freerdp_clipboard_offer *copy)
{
    mr_freerdp_clipboard_offer *superseded = NULL;
    mr_rdp_status status = MR_RDP_STATUS_OK;

    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->cliprdr == NULL ||
               !backend->cliprdr_ready) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->pending_clipboard_probe != NULL ||
               backend->active_clipboard_probe != NULL) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else if (!SetEvent(backend->command_event)) {
        status = MR_RDP_ERROR_BACKEND;
    } else {
        /* The newest copy wins; an older one not yet announced never was. */
        superseded = backend->offer_to_announce;
        backend->offer_to_announce = copy;
        copy = NULL;
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    mr_freerdp_clipboard_offer_destroy(superseded);
    mr_freerdp_clipboard_offer_destroy(copy);
    return status;
}

static uint8_t *mr_freerdp_copy_bytes(const uint8_t *bytes, size_t count)
{
    uint8_t *copy;
    if (bytes == NULL || count == 0u) {
        return NULL;
    }
    copy = (uint8_t *)malloc(count);
    if (copy != NULL) {
        memcpy(copy, bytes, count);
    }
    return copy;
}

static mr_rdp_status mr_freerdp_offer_clipboard_image(
    mr_rdp_backend *base,
    const mr_rdp_clipboard_image_offer *offer)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_freerdp_clipboard_offer *copy =
        (mr_freerdp_clipboard_offer *)calloc(1u, sizeof(mr_freerdp_clipboard_offer));
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->offer_id = offer->offer_id;
    copy->kind = MR_FREERDP_CLIP_IMAGE;
    copy->png = mr_freerdp_copy_bytes(offer->png_bytes, offer->png_byte_count);
    copy->png_count = copy->png != NULL ? offer->png_byte_count : 0u;
    copy->dib = mr_freerdp_copy_bytes(offer->dib_bytes, offer->dib_byte_count);
    copy->dib_count = copy->dib != NULL ? offer->dib_byte_count : 0u;
    if ((offer->png_bytes != NULL && copy->png == NULL) ||
        (offer->dib_bytes != NULL && copy->dib == NULL)) {
        mr_freerdp_clipboard_offer_destroy(copy);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    return mr_freerdp_queue_offer(backend, copy);
}

static mr_rdp_status mr_freerdp_offer_clipboard_files(
    mr_rdp_backend *base,
    const mr_rdp_clipboard_files_offer *offer)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_freerdp_clipboard_offer *copy =
        (mr_freerdp_clipboard_offer *)calloc(1u, sizeof(mr_freerdp_clipboard_offer));
    size_t index;
    if (copy == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->offer_id = offer->offer_id;
    copy->kind = MR_FREERDP_CLIP_FILES;
    copy->files = (mr_freerdp_clipboard_file *)calloc(offer->file_count, sizeof(mr_freerdp_clipboard_file));
    if (copy->files == NULL) {
        mr_freerdp_clipboard_offer_destroy(copy);
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    copy->file_count = offer->file_count;
    for (index = 0u; index < offer->file_count; ++index) {
        const mr_rdp_clipboard_file *file = &offer->files[index];
        /* A Windows file name is at most 259 UTF-16 units plus its NUL. */
        const SSIZE_T converted = ConvertUtf8NToWChar(
            file->name, file->name_length, copy->files[index].name, 259u);
        if (converted <= 0) {
            mr_freerdp_clipboard_offer_destroy(copy);
            return MR_RDP_ERROR_INVALID_ARGUMENT;
        }
        copy->files[index].name[259] = 0;
        copy->files[index].bytes = mr_freerdp_copy_bytes(file->bytes, file->byte_count);
        if (file->byte_count != 0u && copy->files[index].bytes == NULL) {
            mr_freerdp_clipboard_offer_destroy(copy);
            return MR_RDP_ERROR_OUT_OF_MEMORY;
        }
        copy->files[index].byte_count = file->byte_count;
    }
    return mr_freerdp_queue_offer(backend, copy);
}

static mr_rdp_status mr_freerdp_request_clipboard(
    mr_rdp_backend *base,
    uint64_t request_id,
    int kind)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    mr_rdp_status status = MR_RDP_STATUS_OK;
    (void)pthread_mutex_lock(&backend->mutex);
    if (backend->stop_requested) {
        status = MR_RDP_ERROR_STOPPED;
    } else if (backend->input_failure_status != MR_RDP_STATUS_OK) {
        status = backend->input_failure_status;
    } else if (!backend->accepting_input || backend->cliprdr == NULL ||
               !backend->cliprdr_ready) {
        status = MR_RDP_ERROR_INVALID_STATE;
    } else if (backend->pending_text_request_id != 0u) {
        status = MR_RDP_ERROR_LIMIT_EXCEEDED;
    } else {
        if (backend->outstanding_text_request_id != 0u) {
            if (GetTickCount64() - backend->outstanding_text_request_since <
                MR_RDP_CLIPBOARD_REQUEST_TIMEOUT_MS) {
                status = MR_RDP_ERROR_LIMIT_EXCEEDED;
            } else {
                /* CLIPRDR responses carry no id: a late answer to the expired
                 * request would be read as this one's, which is acceptable
                 * only because both ask for the same remote clipboard. */
                backend->expired_text_request_id = backend->outstanding_text_request_id;
                backend->expired_request_kind = backend->outstanding_request_kind;
                backend->outstanding_text_request_id = 0u;
                backend->outstanding_text_request_since = 0u;
                backend->outstanding_request_kind = 0;
                mr_freerdp_reset_incoming_locked(backend);
            }
        }
        if (status == MR_RDP_STATUS_OK) {
            if (!SetEvent(backend->command_event)) {
                status = MR_RDP_ERROR_BACKEND;
            } else {
                backend->pending_text_request_id = request_id;
                backend->pending_request_kind = kind;
            }
        }
    }
    (void)pthread_mutex_unlock(&backend->mutex);
    return status;
}

static mr_rdp_status mr_freerdp_request_clipboard_text(mr_rdp_backend *base, uint64_t request_id)
{
    return mr_freerdp_request_clipboard(base, request_id, MR_FREERDP_CLIP_TEXT);
}

static mr_rdp_status mr_freerdp_request_clipboard_image(mr_rdp_backend *base, uint64_t request_id)
{
    return mr_freerdp_request_clipboard(base, request_id, MR_FREERDP_CLIP_IMAGE);
}

static mr_rdp_status mr_freerdp_request_clipboard_files(mr_rdp_backend *base, uint64_t request_id)
{
    return mr_freerdp_request_clipboard(base, request_id, MR_FREERDP_CLIP_FILES);
}

static void mr_freerdp_destroy(mr_rdp_backend *base)
{
    mr_freerdp_backend *backend = (mr_freerdp_backend *)base;
    if (backend == NULL) {
        return;
    }
    if (backend->context != NULL) {
        mr_freerdp_clear_password(backend->context->settings);
    }
    if (backend->instance != NULL) {
        mr_freerdp_post_disconnect(backend->instance);
    }
    if (backend->context != NULL) {
        mr_freerdp_context *context = (mr_freerdp_context *)backend->context;
        context->backend = NULL;
        freerdp_client_context_free(backend->context);
        backend->context = NULL;
        backend->instance = NULL;
    }
    if (backend->command_event != NULL) {
        (void)CloseHandle(backend->command_event);
        backend->command_event = NULL;
    }
    if (backend->mutex_initialized) {
        (void)pthread_mutex_destroy(&backend->mutex);
    }
    free(backend->expected_hostname);
    free(backend->expected_gateway_hostname);
    SecureZeroMemory(backend, sizeof(*backend));
    free(backend);
}

static const mr_rdp_backend_vtable mr_freerdp_vtable = {
    .run = mr_freerdp_run,
    .request_stop = mr_freerdp_request_stop,
    .send_key = mr_freerdp_send_key,
    .send_pointer = mr_freerdp_send_pointer,
    .start_clipboard_probe = mr_freerdp_start_clipboard_probe,
    .request_display_resize = mr_freerdp_request_display_resize,
    .send_unicode = mr_freerdp_send_unicode,
    .set_audio_focused = mr_freerdp_set_audio_focused,
    .offer_clipboard_text = mr_freerdp_offer_clipboard_text,
    .request_clipboard_text = mr_freerdp_request_clipboard_text,
    .offer_clipboard_image = mr_freerdp_offer_clipboard_image,
    .offer_clipboard_files = mr_freerdp_offer_clipboard_files,
    .request_clipboard_image = mr_freerdp_request_clipboard_image,
    .request_clipboard_files = mr_freerdp_request_clipboard_files,
    .send_audio_capture = mr_freerdp_send_audio_capture,
    .send_touch = mr_freerdp_send_touch,
    .send_pen = mr_freerdp_send_pen,
    .send_macrdpx = mr_freerdp_send_macrdpx,
    .destroy = mr_freerdp_destroy
};

/* The layout/type pair the server is told at connect. Japanese is the only
 * profile under which Eisu/Kana reaching Windows as NonConvert/Convert is
 * promised; automatic leaves FreeRDP's own defaults untouched. */
/* Only ever called for a protocol mr_freerdp_protocol_allowed accepted. */
static mr_rdp_transport_security mr_freerdp_transport_security(uint32_t selected)
{
    switch (selected) {
    case MR_FREERDP_PROTOCOL_HYBRID: return MR_RDP_TRANSPORT_NLA;
    case MR_FREERDP_PROTOCOL_SSL: return MR_RDP_TRANSPORT_TLS;
    case MR_FREERDP_PROTOCOL_RDP: return MR_RDP_TRANSPORT_LEGACY_RDP;
    default: return MR_RDP_TRANSPORT_UNKNOWN;
    }
}

static BOOL mr_freerdp_protocol_allowed(mr_rdp_security_policy policy, uint32_t selected)
{
    switch (selected) {
    case MR_FREERDP_PROTOCOL_HYBRID:
        return policy != MR_RDP_SECURITY_TLS_REQUIRED;
    case MR_FREERDP_PROTOCOL_SSL:
        return policy != MR_RDP_SECURITY_NLA_REQUIRED;
    case MR_FREERDP_PROTOCOL_RDP:
        return policy == MR_RDP_SECURITY_LEGACY_ALLOWED;
    default:
        return FALSE;
    }
}

/* What the client offers in the X.224 negotiation. NLA is always tried
 * first where it is allowed; the legacy RDP Security Layer is offered only
 * under MR_RDP_SECURITY_LEGACY_ALLOWED, which the app sets only after the
 * user has explicitly consented for that one profile. */
static BOOL mr_freerdp_configure_security(
    rdpSettings *settings,
    mr_rdp_security_policy policy)
{
    BOOL nla = policy != MR_RDP_SECURITY_TLS_REQUIRED;
    BOOL tls = policy != MR_RDP_SECURITY_NLA_REQUIRED;
    BOOL rdp = policy == MR_RDP_SECURITY_LEGACY_ALLOWED;
    return freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, nla) &&
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, tls) &&
        freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, rdp);
}

static BOOL mr_freerdp_configure_keyboard(
    rdpSettings *settings,
    mr_rdp_keyboard_profile profile)
{
    switch (profile) {
        case MR_RDP_KEYBOARD_JAPANESE:
            return freerdp_settings_set_uint32(
                       settings, FreeRDP_KeyboardLayout, (uint32_t)KBD_JAPANESE) &&
                freerdp_settings_set_uint32(
                    settings, FreeRDP_KeyboardType, (uint32_t)WINPR_KBD_TYPE_JAPANESE) &&
                freerdp_settings_set_uint32(settings, FreeRDP_KeyboardSubType, 2u) &&
                freerdp_settings_set_uint32(settings, FreeRDP_KeyboardFunctionKey, 12u);
        case MR_RDP_KEYBOARD_US:
            return freerdp_settings_set_uint32(
                       settings, FreeRDP_KeyboardLayout, (uint32_t)KBD_US) &&
                freerdp_settings_set_uint32(
                    settings, FreeRDP_KeyboardType,
                    (uint32_t)WINPR_KBD_TYPE_IBM_ENHANCED) &&
                freerdp_settings_set_uint32(settings, FreeRDP_KeyboardSubType, 0u) &&
                freerdp_settings_set_uint32(settings, FreeRDP_KeyboardFunctionKey, 12u);
        case MR_RDP_KEYBOARD_AUTOMATIC:
            return TRUE;
        default:
            return FALSE;
    }
}

/* ABI 4: HTTPS first with RPC as the fallback, as Microsoft's clients do.
 * Credentials are either the computer's or the gateway's own. */
static BOOL mr_freerdp_configure_gateway(
    rdpSettings *settings,
    const mr_rdp_owned_config *config)
{
    const BOOL same = (config->gateway_flags & MR_RDP_GATEWAY_FLAG_SAME_CREDENTIALS) != 0u;
    if (!freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE) ||
        !freerdp_set_gateway_usage_method(settings, TSC_PROXY_MODE_DIRECT) ||
        !freerdp_settings_set_string_len(
            settings, FreeRDP_GatewayHostname,
            config->gateway_hostname, config->gateway_hostname_length) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort, config->gateway_port) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayUdpTransport, FALSE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_GatewayBypassLocal,
            (config->gateway_flags & MR_RDP_GATEWAY_FLAG_BYPASS_LOCAL) != 0u) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, same)) {
        return FALSE;
    }
    if (same) {
        return TRUE;
    }
    return freerdp_settings_set_string_len(
               settings, FreeRDP_GatewayUsername,
               config->gateway_username, config->gateway_username_length) &&
        freerdp_settings_set_string_len(
            settings, FreeRDP_GatewayPassword,
            config->gateway_password, config->gateway_password_length) &&
        (config->gateway_domain == NULL ||
         freerdp_settings_set_string_len(
             settings, FreeRDP_GatewayDomain,
             config->gateway_domain, config->gateway_domain_length));
}

static mr_rdp_status mr_freerdp_configure_settings(
    mr_freerdp_backend *backend,
    const mr_rdp_owned_config *config)
{
    rdpSettings *settings = backend->context->settings;
    const BOOL h264 = (config->channel_flags & MR_RDP_CHANNEL_FLAG_H264) != 0u &&
        config->remote_program == NULL;
    if (!freerdp_settings_set_string_len(
            settings, FreeRDP_ServerHostname,
            config->hostname, config->hostname_length) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config->port) ||
        !freerdp_settings_set_string_len(
            settings, FreeRDP_Username,
            config->username, config->username_length) ||
        !freerdp_settings_set_string_len(
            settings, FreeRDP_Password,
            config->password, config->password_length) ||
        (config->domain != NULL &&
         !freerdp_settings_set_string_len(
             settings, FreeRDP_Domain,
             config->domain, config->domain_length)) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DesktopWidth, config->desktop_width) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DesktopHeight, config->desktop_height) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DesktopScaleFactor, config->desktop_scale_factor) ||
        !freerdp_settings_set_uint32(
            settings, FreeRDP_DeviceScaleFactor, config->device_scale_factor) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32u) ||
        !mr_freerdp_configure_keyboard(settings, config->keyboard_profile) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_ExternalCertificateManagement, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_CertificateCallbackPreferPEM, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AutoDenyCertificate, FALSE) ||
        !mr_freerdp_configure_security(settings, config->security_policy) ||
        !freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RdstlsSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_AadSecurity, FALSE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_UseRdpSecurityLayer, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE) ||
        /* These are the three settings FreeRDP 3.31.1 actually consumes for
         * update, rdpsnd SVC, and rdpsnd/drdynvc DVC dispatch respectively.
         * FreeRDP_AsyncChannels is only a deprecated stored property in that
         * release, so it is intentionally not relied upon here. */
        !freerdp_settings_set_bool(settings, FreeRDP_AsyncUpdate, FALSE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_SynchronousStaticChannels, TRUE) ||
        !freerdp_settings_set_bool(
            settings, FreeRDP_SynchronousDynamicChannels, TRUE) ||
        /* RemoteApp windows arrive on surfaces of their own too (see the
         * window compositor). */
        !freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) ||
        /* ABI 5: H.264, decoded by this adapter with VideoToolbox. Not for
         * RemoteApp: Windows 11 drops a RemoteApp connection a few seconds
         * after its windows start coming as AVC. */
        !freerdp_settings_set_bool(settings, FreeRDP_GfxH264, h264) ||
        /* Windows only uses AVC with the 10.x capabilities, which imply
         * AVC444; its first stream is drawn as 4:2:0 (see the surface
         * command). */
        !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, h264) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, h264) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GfxCodecAV1, FALSE)) {
        return MR_RDP_ERROR_BACKEND;
    }
    if (config->gateway_hostname != NULL &&
        !mr_freerdp_configure_gateway(settings, config)) {
        return MR_RDP_ERROR_BACKEND;
    }
    /* ABI 7. FreeRDP sends the name to the proxy unresolved (SOCKS5 domain
     * address), for the gateway's connection as for the computer's. */
    if (config->proxy_hostname != NULL &&
        (!freerdp_settings_set_uint32(settings, FreeRDP_ProxyType, PROXY_TYPE_SOCKS) ||
         !freerdp_settings_set_string_len(
             settings, FreeRDP_ProxyHostname,
             config->proxy_hostname, config->proxy_hostname_length) ||
         !freerdp_settings_set_uint16(settings, FreeRDP_ProxyPort, config->proxy_port))) {
        return MR_RDP_ERROR_BACKEND;
    }
    if (config->remote_program != NULL &&
        (!freerdp_settings_set_bool(settings, FreeRDP_RemoteApplicationMode, TRUE) ||
         !freerdp_settings_set_string_len(
             settings, FreeRDP_RemoteApplicationProgram,
             config->remote_program, config->remote_program_length) ||
         (config->remote_arguments != NULL &&
          !freerdp_settings_set_string_len(
              settings, FreeRDP_RemoteApplicationCmdLine,
              config->remote_arguments, config->remote_arguments_length)) ||
         !freerdp_settings_set_bool(settings, FreeRDP_RemoteAppLanguageBarSupported, TRUE))) {
        return MR_RDP_ERROR_BACKEND;
    }
    /* ABI 4: one folder, as a drive under the name given. rdpdr loads the
     * drive service from the static table. */
    if (config->drive_path != NULL) {
        const char *drive[] = { "drive", config->drive_name, config->drive_path };
        if (!freerdp_client_add_device_channel(settings, 3u, drive)) {
            return MR_RDP_ERROR_BACKEND;
        }
    }
    return MR_RDP_STATUS_OK;
}

mr_rdp_status mr_rdp_backend_create_default(
    const mr_rdp_owned_config *config,
    const mr_rdp_backend_host *host,
    const void *factory_context,
    mr_rdp_backend **out_backend)
{
    mr_freerdp_backend *backend;
    RDP_CLIENT_ENTRY_POINTS entry_points;
    mr_rdp_status status = MR_RDP_ERROR_BACKEND;
    (void)factory_context;

    if (config == NULL || host == NULL || host->present_certificate == NULL ||
        host->connected == NULL || host->present_frame == NULL ||
        host->channel_event == NULL || host->clipboard_probe_event == NULL ||
        host->display_resize_event == NULL || host->cursor_event == NULL ||
        host->audio_packet == NULL || host->clipboard_remote_formats == NULL ||
        host->clipboard_offer_event == NULL || host->clipboard_text == NULL ||
        out_backend == NULL) {
        return MR_RDP_ERROR_INVALID_ARGUMENT;
    }
    *out_backend = NULL;
    backend = (mr_freerdp_backend *)calloc(1u, sizeof(*backend));
    if (backend == NULL) {
        return MR_RDP_ERROR_OUT_OF_MEMORY;
    }
    backend->base.vtable = &mr_freerdp_vtable;
    backend->host = *host;
    backend->generation = config->generation;
    backend->expected_port = config->port;
    backend->callback_status = MR_RDP_STATUS_OK;
    backend->input_failure_status = MR_RDP_STATUS_OK;
    backend->keyboard_profile = config->keyboard_profile;
    backend->security_policy = config->security_policy;
    backend->channel_flags = config->channel_flags;
    backend->macrdpx_caps = config->macrdpx_caps;
    if (!mr_input_command_queue_init(
            &backend->command_queue, MR_INPUT_COMMAND_QUEUE_CAPACITY)) {
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    if (pthread_mutex_init(&backend->mutex, NULL) != 0) {
        free(backend);
        return MR_RDP_ERROR_BACKEND;
    }
    backend->mutex_initialized = 1;
    backend->command_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (backend->command_event == NULL) {
        goto fail;
    }
    backend->expected_hostname = strdup(config->hostname);
    if (backend->expected_hostname == NULL) {
        status = MR_RDP_ERROR_OUT_OF_MEMORY;
        goto fail;
    }
    if (config->gateway_hostname != NULL) {
        backend->expected_gateway_hostname = strdup(config->gateway_hostname);
        if (backend->expected_gateway_hostname == NULL) {
            status = MR_RDP_ERROR_OUT_OF_MEMORY;
            goto fail;
        }
        backend->expected_gateway_port = config->gateway_port;
    }

    memset(&entry_points, 0, sizeof(entry_points));
    entry_points.Size = sizeof(entry_points);
    entry_points.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry_points.ContextSize = sizeof(mr_freerdp_context);
    (void)pthread_mutex_lock(&mr_freerdp_addin_lock);
    backend->context = freerdp_client_context_new(&entry_points);
    if (backend->context != NULL &&
        freerdp_register_addin_provider(mr_freerdp_addin_provider, 0u) != CHANNEL_RC_OK) {
        (void)pthread_mutex_unlock(&mr_freerdp_addin_lock);
        goto fail;
    }
    (void)pthread_mutex_unlock(&mr_freerdp_addin_lock);
    if (backend->context == NULL) {
        goto fail;
    }
    backend->instance = backend->context->instance;
    ((mr_freerdp_context *)backend->context)->backend = backend;
    backend->instance->PreConnect = mr_freerdp_pre_connect;
    backend->instance->PostConnect = mr_freerdp_post_connect;
    backend->instance->PostDisconnect = mr_freerdp_post_disconnect;
    backend->instance->VerifyX509Certificate = mr_freerdp_verify_x509_certificate;
    /* Credentials are supplied up front and Phase 0 has no interactive
     * gateway/smart-card/AAD flow. Do not inherit common CLI callbacks that
     * could try to read stdin from the session worker. */
    backend->instance->AuthenticateEx = NULL;
    backend->instance->ChooseSmartcard = NULL;
    backend->instance->PresentGatewayMessage = NULL;
    backend->instance->GetAccessToken = NULL;
    backend->instance->RetryDialog = NULL;

    status = mr_freerdp_configure_settings(backend, config);
    if (status != MR_RDP_STATUS_OK) {
        goto fail;
    }

    /* FreeRDP 3.31.1's public rdpsnd device vtable does not expose block
     * number/server timestamp and its core sends WaveConfirm around Play.
     * The mremote subsystem therefore wires mr_rdpsnd for its focus gate
     * only and never emits a confirmation of its own. */
    *out_backend = &backend->base;
    return MR_RDP_STATUS_OK;

fail:
    mr_freerdp_destroy(&backend->base);
    return status;
}
