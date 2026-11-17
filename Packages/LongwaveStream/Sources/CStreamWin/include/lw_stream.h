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
#define LW_E_UNAVAILABLE (-7) /* nobody on the other end yet (no host listening) */
#define LW_E_REFUSED (-8)     /* the other end refused (lw_frame_source.h) */

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
/* The ID3D11Device* itself, for code that renders on the shim's device. */
void *lw_device_get_d3d11(const lw_device *device);
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

/* SPIKE ONLY: a test pattern for the external frame source measurements
 * (frame-source-spike). On any D3D11 device. Drawing is GPU work only, on the
 * device's immediate context: a panning noise background (so the encoder has
 * real work), a moving bar, and the frame number as 32 black/white 16-pixel
 * blocks along the top edge; `aux`, if given (R32_FLOAT), is cleared to the
 * frame number. Both textures must be render targets at least 512 pixels wide. */
typedef struct lw_spike_pattern lw_spike_pattern;
lw_status lw_spike_pattern_create(void *d3d11_device, int32_t width, int32_t height, lw_spike_pattern **out);
lw_status lw_spike_pattern_draw(lw_spike_pattern *pattern, void *texture, void *aux, uint64_t frame_number);
/* Reads back what draw painted (blocks on the GPU; verification only). aux may be NULL. */
lw_status lw_spike_pattern_read(lw_spike_pattern *pattern, void *texture, void *aux, uint32_t *out_frame_number,
                                float *out_aux);
void lw_spike_pattern_release(lw_spike_pattern *pattern);

/* SPIKE ONLY: a world-locked test scene for the PCVR path, ray-cast per eye from
 * the headset's pose (spike_test_scene.cpp has the scene and the stamp layout).
 * `image` is the side-by-side BGRA8 target, `depth` (R32_FLOAT, side by side,
 * any size) receives metres along each eye's view axis and may be NULL. */
typedef struct lw_spike_scene lw_spike_scene;
typedef struct lw_spike_scene_eye {
    float orientation[4]; /* world from eye, xyzw */
    float position[3];    /* world, metres */
    float angles[4];      /* left, right, up, down, radians */
    float time;           /* display time, seconds: drives the animation */
} lw_spike_scene_eye;
lw_status lw_spike_scene_create(void *d3d11_device, lw_spike_scene **out);
lw_status lw_spike_scene_draw(lw_spike_scene *scene, void *image, void *depth, const lw_spike_scene_eye eyes[2],
                              uint32_t stamp, int32_t draw_stamp);
/* A panel's corner cross in world space: panel 0 ahead, 1 right, 2 behind, 3 left;
 * corner bit 0 = right, bit 1 = bottom. */
void lw_spike_scene_marker(int32_t panel, int32_t corner, float out[3]);
void lw_spike_scene_release(lw_spike_scene *scene);

/* SPIKE ONLY: the frame-source-spike command line (produce, consume,
 * inprocess, gpu-load); see spike_frame_source_tool.cpp. Returns the exit code. */
int lw_spike_frame_source_tool(int argc, char **argv);

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
    uint32_t const_qp;        /* 1..51: constant QP instead of CBR at bitrate_bps (a
                                 depth picture, whose bits are cheap and whose
                                 ringing is not); 0 = CBR */
    uint32_t multi_pass;      /* CBR only: 0 single pass, 1 a quarter-resolution first
                                 pass, 2 a full-resolution one (the first pass measures
                                 this frame before its QP is chosen) */
    uint32_t spatial_aq;      /* CBR only: 0 off, 1..15 spatial adaptive quantisation strength */
    uint32_t max_qp;          /* CBR only: 1..51 caps the QP (frames may then overrun
                                 the VBV); 0 = no cap */
    uint32_t bit_depth;       /* HEVC only: 10 encodes Main10 from the same 8-bit input
                                 (NVENC converts; less banding in dark gradients);
                                 0 or 8 = Main */
    uint32_t tuning;          /* 0 = ultra-low latency, 1 = low latency (NVENC's tuning info) */
    uint32_t temporal_aq;     /* CBR only: 1 = temporal adaptive quantisation */
    uint32_t key_frame_scale; /* CBR only: the I to P bit ratio NVENC aims for in a
                                 short VBV (lowDelayKeyFrameScale); 0 = its default */
    uint32_t min_qp;          /* CBR only: 1..51, the lowest QP; 0 = none */
    uint32_t recon;           /* 1 = write each picture's reconstruction (what any
                                 decoder outputs) to the texture lw_encoder_encode_ex names */
    uint32_t qp_map;          /* 1 = take a QP delta map with each picture (lw_encoder_encode_ex) */
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
/* A new bitrate and frame rate in place: no new session, no key frame (the
 * rate control's per-frame budget follows the new rate). */
lw_status lw_encoder_reconfigure(lw_encoder *encoder, uint32_t bitrate_bps, uint32_t fps);
/* What lw_encoder_encode does, plus: */
typedef struct lw_encode_extras {
    /* With params.qp_map: a QP offset per 32x32 CTB, raster order, added to
     * what rate control picks (negative = sharper); NULL for none this picture. */
    const int8_t *qp_delta_map;
    uint32_t qp_delta_map_size; /* ceil(width / 32) * ceil(height / 32) */
    /* With params.recon: an encoder-sized NV12 texture (lw_texture_create,
     * LW_TEXTURE_NV12) that receives the reconstructed picture. */
    void *recon;
} lw_encode_extras;
lw_status lw_encoder_encode_ex(lw_encoder *encoder, void *texture, uint64_t timestamp, uint32_t flags,
                               const lw_encode_extras *extras, lw_packet *out);
void lw_encoder_release(lw_encoder *encoder);

/* ---- Foveation warp (NATIVE_V3_PROTOCOL.md section 4.7) -------------------
 * Packs each eye of a side-by-side render texture into a smaller wire texture
 * with v3's centre/edge warp: the centre interval at full density, the edges
 * compressed. Per eye and axis it takes StreamWire's CentreEdgeAxisMapping
 * constants (centre interval a..b in render UV, edge ratio r, packed length L)
 * and evaluates that type's renderCoordinate(forWire:) at every wire pixel
 * centre; StreamHostWindowsTests compares the two. Compressed pixels average
 * four bilinear taps spread over their footprint; full-density pixels take one.
 * Every tap stays half a texel inside its own eye, so nothing crosses the seam.
 * GPU work only, on the device's immediate context (under its multithread
 * lock), queued before a later lw_encoder_encode of the destination. */
typedef struct lw_warp_axis {
    float lower, upper; /* the full-density interval, render UV, 0 <= lower < upper <= 1 */
    float ratio;        /* edge compression, >= 1 */
    float length;       /* wire/render length, (0, 1] */
} lw_warp_axis;
typedef struct lw_warp_eye {
    lw_warp_axis x, y;
} lw_warp_eye;
typedef struct lw_warp_params {
    int32_t render_eye_width, render_eye_height; /* per eye, at the source's top left, left eye first */
    int32_t wire_eye_width, wire_eye_height;     /* per eye, at the destination's top left */
    lw_warp_eye eyes[2];                         /* left, right */
} lw_warp_params;

typedef struct lw_warp lw_warp;
lw_status lw_warp_create(lw_device *device, lw_warp **out);
/* source: an ID3D11Texture2D a float SRV can read (a frame's BGRA8 texture);
 * destination: one from lw_texture_create, at least two wire eyes wide. */
lw_status lw_warp_apply(lw_warp *warp, void *source, void *destination, const lw_warp_params *params);
void lw_warp_release(lw_warp *warp);

/* ---- Depth (NATIVE_V3_PROTOCOL.md section 4.8, PCVR reprojection) ---------
 * Writes a frame's depth for the depthVideo stream: both eyes side by side at
 * depth size, each in its own render frustum, as grey BGRA8 (B = G = R) holding
 * inverse depth v = near / z, so v = 1 at `near_depth` and 0 at infinity.
 *  - LW_DEPTH_STEREO: estimated from the two eyes of a side-by-side colour
 *    frame. Both are resampled to luminance on one tangent grid (the depth
 *    eye's spacing, spanning both frusta), where a point's eyes differ only by a
 *    horizontal shift, its disparity, baseline / z in tangent. Each eye is block
 *    matched against the other (5x5 sum of absolute differences, up to
 *    `max_disparity` grid texels, sub-texel by parabola). Matches that fail the
 *    left-right check, or lack texture or a clear minimum, are filled from the
 *    farther of the nearest good ones on their row (what an occlusion hides is
 *    the background). near_depth = baseline / (max_disparity x spacing).
 *  - LW_DEPTH_LINEAR: from planar depth in metres (R32F or R16F, side by side,
 *    any size, 0 or less = nothing there): the nearest under each output texel.
 * GPU work only, on the device's immediate context under its multithread
 * lock, queued before a later lw_encoder_encode of the destination. */
#define LW_DEPTH_STEREO 1
#define LW_DEPTH_LINEAR 2
typedef struct lw_depth_params {
    uint32_t source_kind;                         /* LW_DEPTH_* */
    int32_t source_eye_width, source_eye_height;  /* per eye, at the source's top left, left eye first */
    int32_t depth_eye_width, depth_eye_height;    /* per eye, at the destination's top left */
    float tangents[2][4];                         /* per eye: left, right, up, down (left and down negative) */
    float baseline;                               /* LW_DEPTH_STEREO: metres between the eyes, along x */
    int32_t max_disparity;                        /* LW_DEPTH_STEREO: 1...128 grid texels */
    float near_depth;                             /* metres encoded as 255 */
} lw_depth_params;

typedef struct lw_depth lw_depth;
lw_status lw_depth_create(lw_device *device, lw_depth **out);
/* source: an ID3D11Texture2D a float SRV can read; destination: a BGRA8 one
 * from lw_texture_create, at least two depth eyes wide. */
lw_status lw_depth_apply(lw_depth *depth, void *source, void *destination, const lw_depth_params *params);
/* GPU time of the latest apply the GPU has finished, ms; -1 before the first. */
float lw_depth_gpu_milliseconds(lw_depth *depth);
/* The same apply's passes: luminance, matching (0 for linear), output. */
void lw_depth_pass_milliseconds(lw_depth *depth, float out[3]);
/* Diagnostics: the last stereo estimate's luminance grid (which 0), raw grid
 * disparity (1) or cleaned disparity (2; -1 = unknown), both eyes side by
 * side, waiting for the GPU.
 * With out NULL or capacity too small, only the size is written. */
lw_status lw_depth_debug_read(lw_depth *depth, int32_t which, float *out, int32_t capacity, int32_t *width,
                              int32_t *height);
void lw_depth_release(lw_depth *depth);

/* ---- Textures --------------------------------------------------------------
 * Render-target textures on the shim's device (bindable as shader resources
 * too): the warp's destination, which lw_encoder_encode accepts when BGRA8,
 * and fixtures for tests. */
#define LW_TEXTURE_BGRA8 1   /* DXGI_FORMAT_B8G8R8A8_UNORM */
#define LW_TEXTURE_RGBA32F 2 /* DXGI_FORMAT_R32G32B32A32_FLOAT */
#define LW_TEXTURE_R32F 3    /* DXGI_FORMAT_R32_FLOAT */
#define LW_TEXTURE_NV12 4    /* DXGI_FORMAT_NV12: an encoder's reconstruction (not readable by lw_texture_read) */
/* data: initial pixels with rows `row_pitch` bytes apart, or NULL. */
lw_status lw_texture_create(lw_device *device, int32_t width, int32_t height, uint32_t format, const void *data,
                            uint32_t row_pitch, void **out);
/* Copies the pixels to `out` (rows `row_pitch` bytes apart), waiting for the
 * GPU: tests and diagnostics only. */
lw_status lw_texture_read(lw_device *device, void *texture, void *out, uint32_t row_pitch);
/* GPU-only crop into an equally formatted destination texture; no readback.
 * The destination extent selects the crop size. Both textures use this device. */
lw_status lw_texture_copy_region(lw_device *device, void *source, uint32_t source_x,
                                 uint32_t source_y, void *destination);
void lw_texture_release(void *texture);

/* ---- Motion (NVENC motion-estimation-only mode) ----------------------------
 * The motion from a reference picture to the current one, searched by the
 * video encoder's engine rather than the 3D engine (motion_nvenc.cpp,
 * docs/PCVR_MOTION_EXTRAPOLATION.md). Both pictures are BGRA8 textures of the
 * size given at creation. Synchronous: waits for the encoder engine. */
typedef struct lw_motion lw_motion;
typedef struct lw_motion_params {
    int32_t width, height;
    uint32_t preset; /* 1 (fastest) to 7; 0 = 4 */
    uint32_t block;  /* the output grid's block side in pixels: 8, 16 or 32; 0 = 16 */
} lw_motion_params;
typedef struct lw_motion_stats {
    double submit_ms, wait_ms, parse_ms; /* CPU wall time of each step */
    uint32_t records, records_used, malformed_ctbs;
    uint32_t ctb_size, ctb_markers, largest_cu; /* the CTB size the records were read with */
    uint32_t known_blocks;               /* blocks with a P vector */
    double mean_pixels;                  /* mean vector length over them */
} lw_motion_stats;
typedef struct lw_motion_field {
    int32_t grid_width, grid_height, block; /* blocks of `block` x `block` pixels, raster order */
    /* Per block x then y, quarter pixels: current(p) matches reference(p + v).
     * Owned by the lw_motion, valid until its next estimate. */
    const int16_t *vectors;
    const uint8_t *known; /* 0: no inter vector (intra, or outside) */
    lw_motion_stats stats;
} lw_motion_field;
/* An eye pair turned by a homography per eye (lw_reproject_*), for the motion
 * search: the previous picture turned to the current render orientation, so a
 * still world matches itself at zero motion. `matrices`: left then right, each
 * 3x3 row-major, destination eye pixel (x, y, 1) to source eye pixel
 * (homogeneous). GPU work only, on the immediate context, queued before a later
 * lw_motion_estimate of the destination. */
typedef struct lw_reproject_params {
    int32_t eye_width, eye_height;
    float matrices[18];
} lw_reproject_params;
typedef struct lw_reproject lw_reproject;
lw_status lw_reproject_create(lw_device *device, lw_reproject **out);
lw_status lw_reproject_apply(lw_reproject *reproject, void *source, void *destination, const lw_reproject_params *params);
void lw_reproject_release(lw_reproject *reproject);
lw_status lw_motion_create(lw_device *device, const lw_motion_params *params, lw_motion **out);
lw_status lw_motion_estimate(lw_motion *motion, void *current, void *reference, lw_motion_field *out);
void lw_motion_release(lw_motion *motion);

/* ---- Picture quality (the codec bench) -------------------------------------
 * Compares pictures on the GPU, in luma (BT.709, limited range: what NVENC
 * encodes from BGRA), and reads back small per-tile sums. Waits for the GPU:
 * benches only. */
typedef struct lw_quality lw_quality;
lw_status lw_quality_create(lw_device *device, lw_quality **out);
/* The codec alone: `reference` (BGRA8) against `recon` (NV12, the same size),
 * per 16x16 tile in raster order (ceil(w/16) x ceil(h/16) tiles), 4 floats each:
 * squared error summed, the mean SSIM of the tile's four 8x8 windows, block-edge
 * excess (how much more the recon steps across the 8-pixel grid inside the tile
 * than the reference does, beyond its steps elsewhere; code values), and the
 * reference's variance. `capacity` is in floats. */
lw_status lw_quality_wire(lw_quality *quality, void *reference, void *recon, float *out, uint32_t capacity);
/* What the headset shows at a point. A box of render pixels in one eye of
 * `truth` (two render eyes side by side, BGRA8) against the same pixels read
 * from a wire picture (two wire eyes side by side) at their warped positions,
 * bilinear, as the headset's unwarp reads them: from `recon` (NV12) and from
 * `wire` (BGRA8, unencoded). */
typedef struct lw_quality_box {
    int32_t eye;                  /* 0 left, 1 right */
    int32_t x, y;                 /* the box's top-left render pixel, in that eye */
    int32_t size;                 /* square, a multiple of 16 */
    float axis_x[4], axis_y[4];   /* the eye's warp constants (lower, upper, ratio, length) */
} lw_quality_box;
typedef struct lw_quality_eyes {
    int32_t render_eye_width, render_eye_height;
    int32_t wire_eye_width, wire_eye_height;
} lw_quality_eyes;
/* Per 16x16 tile of each box in turn, 8 floats: squared error shown (recon)
 * and unencoded (wire), SSIM shown and unencoded (mean of four 8x8 windows),
 * Laplacian energy of the truth and of the shown pixels (the tile's inner
 * 14x14), and two zeros. */
lw_status lw_quality_gaze(lw_quality *quality, void *truth, void *wire, void *recon, const lw_quality_eyes *eyes,
                          const lw_quality_box *boxes, uint32_t count, float *out, uint32_t capacity);
/* Pixels to look at: the box from the truth and as shown, BGRA8, size x size each. */
lw_status lw_quality_crop(lw_quality *quality, void *truth, void *recon, const lw_quality_eyes *eyes,
                          const lw_quality_box *box, uint8_t *truth_out, uint8_t *shown_out);
void lw_quality_release(lw_quality *quality);

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

/* ---- Audio out (WASAPI render): a stream we generate --------------------- */
/* Fill `out` with `frames` mono float32 samples at the stream's rate; called on
 * the shim's MMCSS audio thread every few milliseconds. Must not block. */
typedef void (*lw_audio_render_callback)(void *context, float *out, uint32_t frames);

typedef struct lw_audio_render lw_audio_render;
/* Plays a mono float32 stream at `sample_rate` into a render endpoint (from
 * lw_audio_endpoint_list, or NULL for the default). Windows converts it to the
 * endpoint's own mix format and rate. About 20 ms is kept queued in the engine. */
lw_status lw_audio_render_start(const char *endpoint_id, uint32_t sample_rate, lw_audio_render_callback callback,
                                void *context, lw_audio_render **out);
void lw_audio_render_stop(lw_audio_render *render);

/* SPIKE ONLY: plays a distinct sine per channel (channel n at 250 * (n + 1) Hz)
 * on an endpoint for `milliseconds`, blocking, so loopback has known content. */
lw_status lw_audio_play_test_tones(const char *endpoint_id, uint32_t milliseconds, float amplitude);

#ifdef __cplusplus
}
#endif

#endif /* LW_STREAM_H */
