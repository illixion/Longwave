/*
 * lw_stream.h - flat C ABI over the Windows media APIs used by the Longwave host.
 *
 * NATIVE_V3_PROTOCOL.md section 7.2: the Swift core never talks to COM, WinRT,
 * NVENC or WASAPI directly. Everything Windows-specific sits behind this header,
 * which is plain C so Swift imports it without C++ interop.
 *
 * Conventions
 *  - Functions return lw_status (LW_OK or a negative LW_E_* code). On failure,
 *    lw_last_error() describes it (thread-local, UTF-8, valid until the next
 *    lw_* call on the same thread).
 *  - Objects are opaque pointers created by lw_*_create/start and destroyed by
 *    lw_*_release/stop. Destroying NULL is a no-op.
 *  - Times are raw QueryPerformanceCounter ticks (lw_qpc_frequency() per second)
 *    so capture, audio and network stamps share one host clock.
 *  - Callbacks run on shim-owned threads. They must not call the stop/release
 *    function of the object that is calling them.
 */
#ifndef LW_STREAM_H
#define LW_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LW_ABI_VERSION 1

typedef int32_t lw_status;
#define LW_OK 0
#define LW_E_INVALID_ARG (-1)
#define LW_E_UNSUPPORTED (-2)
#define LW_E_OS (-3)          /* an OS or driver call failed */
#define LW_E_ENCODER (-4)     /* NVENC returned an error */
#define LW_E_ACCESS_LOST (-5) /* the capture source went away; start again */
#define LW_E_BUSY (-6)

const char *lw_last_error(void);

/* ---- Process --------------------------------------------------------------
 * Call once at start-up, on the main thread: per-monitor DPI awareness (so
 * coordinates and capture sizes are physical pixels), WinRT in the
 * multithreaded apartment, 1 ms timer resolution. */
lw_status lw_runtime_init(void);
int64_t lw_qpc_now(void);
int64_t lw_qpc_frequency(void);

/* ---- Displays ------------------------------------------------------------- */
typedef struct lw_monitor_info {
    void *handle; /* HMONITOR */
    int32_t x, y, width, height; /* physical pixels, desktop coordinates */
    uint32_t refresh_hz;
    int32_t is_primary;
    char device_name[32];   /* \\.\DISPLAYn */
    char adapter_name[128]; /* the GPU DXGI says drives it, if found */
} lw_monitor_info;

/* Fills up to `capacity` entries; returns the total number of monitors. */
int32_t lw_monitor_list(lw_monitor_info *out, int32_t capacity);

/* ---- D3D11 device ---------------------------------------------------------
 * One device is shared by capture and encode so frames never leave the GPU. */
typedef struct lw_device lw_device;
typedef struct lw_device_info {
    char adapter_name[128];
    uint32_t vendor_id; /* 0x10DE NVIDIA, 0x1002 AMD, 0x8086 Intel */
    uint64_t dedicated_video_memory;
} lw_device_info;

/* monitor: HMONITOR whose adapter to use (required for DXGI duplication), or
 * NULL for the first hardware adapter. */
lw_status lw_device_create(void *monitor, lw_device **out);
void lw_device_get_info(const lw_device *device, lw_device_info *out);
void lw_device_release(lw_device *device);

/* ---- Capture -------------------------------------------------------------- */
#define LW_CAPTURE_WGC 1 /* Windows.Graphics.Capture: monitors and windows */
#define LW_CAPTURE_DDA 2 /* DXGI Desktop Duplication: monitors only */

typedef struct lw_frame lw_frame;
typedef struct lw_frame_info {
    void *texture; /* ID3D11Texture2D*, DXGI_FORMAT_B8G8R8A8_UNORM, owned by the frame */
    int32_t width, height; /* content size (the texture may be larger) */
    uint64_t sequence;     /* per capture session, increasing */
    int64_t present_qpc;   /* when the OS composed/presented this content */
    int64_t arrival_qpc;   /* when the shim received it */
    int64_t ready_qpc;     /* after the shim queued its GPU copy */
} lw_frame_info;

/* Ownership of `frame` passes to the callee, which must lw_frame_release it
 * (from any thread, at any time - even after lw_capture_stop). */
typedef void (*lw_frame_callback)(void *context, lw_frame *frame);

typedef struct lw_capture_params {
    uint32_t backend; /* LW_CAPTURE_* */
    void *monitor;    /* HMONITOR, or NULL with `window` */
    void *window;     /* HWND (WGC only) */
    int32_t cursor;   /* composite the cursor (WGC only) */
    int32_t ring_size; /* frames the callee may hold at once; 0 = 4. A frame
                          arriving with every slot held is dropped. */
} lw_capture_params;

typedef struct lw_capture_stats {
    uint64_t os_frames;         /* frames the OS delivered */
    uint64_t delivered;         /* passed to the callback */
    uint64_t dropped_ring_full; /* the callee held every slot */
    uint64_t errors;
    lw_status last_error;       /* LW_E_ACCESS_LOST once the source is gone */
} lw_capture_stats;

typedef struct lw_capture lw_capture;
lw_status lw_capture_start(lw_device *device, const lw_capture_params *params,
                           lw_frame_callback callback, void *context, lw_capture **out);
void lw_capture_get_stats(const lw_capture *capture, lw_capture_stats *out);
/* Blocks until no callback is running; none runs afterwards. */
void lw_capture_stop(lw_capture *capture);

/* SPIKE ONLY: a synthetic source on the same delivery path, for measuring the
 * encoder at sizes/rates the attached display doesn't offer. Each frame is a
 * GPU copy out of a double-size noise texture: `motion` 0 = a random offset
 * every frame (nothing predictable: worst case), 1 = a steady pan (camera-like
 * motion the encoder can predict). Paced at `fps` on its own thread. */
lw_status lw_capture_start_synthetic(lw_device *device, int32_t width, int32_t height, uint32_t fps,
                                     uint32_t motion, lw_frame_callback callback, void *context,
                                     lw_capture **out);

/* SPIKE ONLY: keeps the GPU busy from its own D3D11 device, the way a running
 * game would, at roughly `percent` duty cycle (large texture copies in 10 ms
 * periods). For measuring the encoder at game-time clocks and under contention. */
typedef struct lw_gpu_load lw_gpu_load;
lw_status lw_spike_gpu_load_start(int32_t percent, lw_gpu_load **out);
void lw_spike_gpu_load_stop(lw_gpu_load *load);

const lw_frame_info *lw_frame_get_info(const lw_frame *frame);
void lw_frame_release(lw_frame *frame);

/* ---- Video encoder (NVENC) ------------------------------------------------ */
#define LW_CODEC_H264 1
#define LW_CODEC_HEVC 2

typedef struct lw_encoder_params {
    uint32_t codec;
    int32_t width, height;
    uint32_t fps;
    uint32_t bitrate_bps;     /* CBR */
    uint32_t preset;          /* NVENC P1..P7 (1 = fastest); 0 = P1 */
    uint32_t vbv_frames;      /* VBV in frames of average bitrate; 0 = 1 */
    uint32_t intra_refresh_period; /* frames; 0 = off */
    uint32_t slices;          /* 0 or 1 = one slice per picture */
    uint32_t async_mode;      /* 1 = wait on a completion event (NVIDIA's advice on
                                 Windows); 0 = block in nvEncLockBitstream */
} lw_encoder_params;

typedef struct lw_encoder_info {
    char name[64];
    uint32_t header_api_major, header_api_minor; /* the API this shim was built for */
    uint32_t driver_api_major, driver_api_minor; /* the newest the driver accepts */
    int32_t supports_ref_invalidation;
    int32_t supports_intra_refresh;
    int32_t supports_ltr;
    int32_t max_width, max_height;
} lw_encoder_info;

#define LW_ENCODE_FORCE_IDR 0x1

typedef struct lw_packet {
    const uint8_t *data; /* Annex-B; valid until the next encode or release */
    uint32_t size;
    int32_t is_idr;
    uint32_t picture_type; /* NV_ENC_PIC_TYPE */
    uint32_t average_qp;
    uint64_t timestamp;    /* as passed to lw_encoder_encode */
    int64_t submit_qpc;    /* before handing the picture to the encoder */
    int64_t done_qpc;      /* bitstream locked (encode finished) */
} lw_packet;

typedef struct lw_encoder lw_encoder;
lw_status lw_encoder_create(lw_device *device, const lw_encoder_params *params, lw_encoder **out);
void lw_encoder_get_info(const lw_encoder *encoder, lw_encoder_info *out);
/* Synchronous: returns when the picture is encoded. `texture` is an
 * ID3D11Texture2D (BGRA8) on the encoder's device, e.g. lw_frame_info.texture.
 * Call from one thread at a time. */
lw_status lw_encoder_encode(lw_encoder *encoder, void *texture, uint64_t timestamp,
                            uint32_t flags, lw_packet *out);
/* Marks earlier pictures (by timestamp) as unusable references, so the next
 * picture predicts only from what the client still has. */
lw_status lw_encoder_invalidate(lw_encoder *encoder, const uint64_t *timestamps, uint32_t count);
lw_status lw_encoder_set_bitrate(lw_encoder *encoder, uint32_t bitrate_bps);
void lw_encoder_release(lw_encoder *encoder);

/* ---- Audio (WASAPI loopback) ---------------------------------------------- */
typedef struct lw_audio_endpoint_info {
    char id[256];   /* pass to lw_audio_loopback_start */
    char name[128];
    uint32_t channels;
    uint32_t sample_rate;
    uint32_t channel_mask; /* SPEAKER_* bits */
    int32_t is_default;
} lw_audio_endpoint_info;

/* Active render endpoints. Fills up to `capacity`; returns the total. */
int32_t lw_audio_endpoint_list(lw_audio_endpoint_info *out, int32_t capacity);

typedef struct lw_audio_format {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t bits_per_sample;
    uint32_t channel_mask;
    int32_t is_float;
    uint32_t block_align; /* bytes per frame */
} lw_audio_format;

#define LW_AUDIO_SILENT 0x1        /* buffer is silence; `data` may be NULL */
#define LW_AUDIO_DISCONTINUITY 0x2 /* the engine dropped audio before this */

/* `bytes` = frames * block_align; qpc: when the buffer's first frame was captured. */
typedef void (*lw_audio_callback)(void *context, const void *data, uint32_t frames,
                                  uint32_t bytes, int64_t qpc, uint32_t flags);

typedef struct lw_audio_loopback lw_audio_loopback;
/* endpoint_id: from lw_audio_endpoint_list, or NULL for the default render
 * endpoint. Captures the endpoint's mix format, all channels. */
lw_status lw_audio_loopback_start(const char *endpoint_id, lw_audio_callback callback,
                                  void *context, lw_audio_loopback **out,
                                  lw_audio_format *out_format);
void lw_audio_loopback_stop(lw_audio_loopback *loopback);

/* SPIKE ONLY: plays a distinct sine per channel (channel n at 250 * (n + 1) Hz)
 * on an endpoint for `milliseconds`, blocking, so loopback has known content. */
lw_status lw_audio_play_test_tones(const char *endpoint_id, uint32_t milliseconds, float amplitude);

#ifdef __cplusplus
}
#endif

#endif /* LW_STREAM_H */
