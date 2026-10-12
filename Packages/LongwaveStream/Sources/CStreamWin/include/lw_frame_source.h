/*
 * lw_frame_source.h - external frame sources: frames from another process.
 *
 * NATIVE_V3_PROTOCOL.md section 7.2. Besides WGC and duplication, the host
 * streams frames that another process renders: an in-game depth component
 * (section 4.8: picture plus depth, one frame number) or a VR compositor
 * (section 4.7: eye images plus their render poses, with head poses, gaze and
 * pacing coming back). The producer never links the stream core; it links
 * this producer API, and the two processes share only:
 *
 *  - a ring of D3D11 textures, created by the host on its device, shared as
 *    NT handles, opened by the producer on its own device;
 *  - one shared ID3D11Fence: the producer signals it after drawing a slot,
 *    the host waits for that value before encoding, so the handoff is GPU
 *    only, with no CPU copy or readback;
 *  - the section of lw_frame_source_layout.h, for everything else.
 *
 * Producer and host must use the same GPU: the host checks the adapter LUID
 * at attach and refuses a producer on another one.
 *
 * Named objects, for channel C (letters, digits, '.', '-', '_'; at most
 * LW_FS_MAX_CHANNEL characters), all in the session's Local\ namespace, so
 * producer and host run in the same logon session:
 *   Local\lw_frame_source.C            the section (sizeof(lw_fs_shared) bytes)
 *   Local\lw_frame_source.C.host       auto-reset event the producer sets:
 *                                      request, frame submitted, detach
 *   Local\lw_frame_source.C.producer   auto-reset event the host sets:
 *                                      attach answered, slot freed, host leaving
 * The host creates all three with this security descriptor, owner set
 * explicitly so a restarted host can tell its own section from a squatter's:
 *   O:<host user>D:P(A;;GA;;;SY)(A;;GA;;;<host user>)[(A;;GA;;;<producer_sid>)]S:(ML;;NW;;;LW)
 * The low mandatory label is what lets a producer at any integrity level
 * (a medium-integrity game, or a sandboxed low one) open objects that an
 * elevated host created; the DACL still limits them to the host's own user,
 * SYSTEM and, optionally, one more account (a host running as SYSTEM names
 * the signed-in user there).
 *
 * The GPU objects are not named. D3D11 can open a shared texture by name but
 * not a shared fence, so instead the host duplicates every handle into the
 * producer's process (it needs PROCESS_DUP_HANDLE on the producer: same user
 * at equal or lower integrity, or a host running as SYSTEM) and writes the
 * values into the section. Unnamed objects also leave nothing in the
 * namespace to squat. A producer at a higher integrity level than the host,
 * or a protected process, can't be served and is refused.
 *
 * Lifetimes. A producer that crashes is seen by the host at once (it waits on
 * the producer's process handle) and its ring is torn down; a host that
 * crashes is seen by the producer on its next acquire (it holds a SYNCHRONIZE
 * handle to the host's process) and it attaches again once a host listens.
 * Either side may restart any number of times; generations keep the old and
 * new rings apart.
 *
 * Requirements: Windows 10 1703 or later (ID3D11Device5 / ID3D11Fence) with a
 * WDDM 2.0 driver, on both sides.
 */
#ifndef LW_FRAME_SOURCE_H
#define LW_FRAME_SOURCE_H

#include "lw_frame_source_layout.h"
#include "lw_stream.h"

#ifdef __cplusplus
extern "C" {
#endif

#define LW_FS_MAX_CHANNEL 64

/* ==== Host side (the consumer) ==============================================
 * Listens on a channel and delivers each producer frame as an lw_frame, the
 * same type WGC and duplication deliver, so it feeds lw_encoder_encode
 * directly. Only the newest frame is delivered: frames the host hasn't taken
 * when a newer one is ready are dropped. */

typedef struct lw_frame_source lw_frame_source;

typedef struct lw_frame_source_params {
    const char *channel;
    const char *producer_sid; /* string SID granted access besides the host's user; NULL = none */
} lw_frame_source_params;

/* What an lw_frame from an external source carries besides lw_frame_info.
 * lw_frame_info.texture is textures[LW_FS_TEXTURE_IMAGE], sequence is
 * frame_number, present_qpc the producer's submit time, arrival_qpc when the
 * host took the slot and ready_qpc when the fence reached the slot's value
 * (the producer's GPU work on it is finished). */
typedef struct lw_frame_source_info {
    uint64_t generation;   /* the attach this frame came from */
    uint64_t frame_number;
    uint32_t slot;
    uint32_t side_data_size;
    const uint8_t *side_data; /* valid while the frame is held */
    lw_fs_format format;      /* as declared at attach */
    void *textures[LW_FS_MAX_TEXTURES]; /* ID3D11Texture2D* on the host's device, NULL where absent */
    int64_t present_qpc;
    int64_t taken_qpc;
    int64_t ready_qpc;
} lw_frame_source_info;

/* The external part of a frame, or NULL for a frame from WGC or duplication. */
const lw_frame_source_info *lw_frame_get_source_info(const lw_frame *frame);

/* Creates the channel's named objects and starts listening on a shim thread,
 * which also delivers frames to `callback` (ownership passes, as with
 * lw_capture_start). Release a frame only when the GPU is done with its
 * textures: after lw_encoder_encode returns is safe, since that waits for the
 * encode. Until it is released the producer can't reuse the slot, so a callee
 * that holds frames starves the producer (which then drops frames).
 * LW_E_BUSY if another host is listening on the channel or an incompatible
 * build still holds it. */
lw_status lw_frame_source_start(lw_device *device, const lw_frame_source_params *params,
                                lw_frame_callback callback, void *context, lw_frame_source **out);

/* Publishes the host state the producer reads (head pose, gaze, pacing).
 * Any thread; calls are serialised. */
void lw_frame_source_publish(lw_frame_source *source, const lw_fs_host_state *state);

typedef struct lw_frame_source_stats {
    int32_t attached;
    uint32_t producer_pid;    /* 0 when nobody is attached */
    uint64_t generation;
    lw_fs_format format;
    uint32_t last_refusal;    /* LW_FS_REFUSE_* of the most recent refused attach */
    uint32_t reserved;
    uint64_t attaches, refusals;
    uint64_t detaches;        /* the producer detached */
    uint64_t producer_exits;  /* the producer's process ended while attached */
    uint64_t delivered;
    uint64_t fence_timeouts;  /* a slot's fence value never arrived (producer GPU hang or TDR) */
    uint64_t errors;
    /* this generation, from the section */
    uint64_t submitted, superseded, starved, consumed, dropped;
} lw_frame_source_stats;

void lw_frame_source_get_stats(const lw_frame_source *source, lw_frame_source_stats *out);

/* Ends any attach, stops listening and blocks until no callback is running.
 * Frames still held stay valid until released. */
void lw_frame_source_stop(lw_frame_source *source);

/* ==== Producer side ===========================================================
 * What an in-game component or a compositor calls. A producer builds with
 * this header, lw_frame_source_layout.h, CFrameSourceCore and CStreamWin's
 * frame_producer.cpp, frame_source_win.cpp and runtime.cpp; it needs no
 * Swift runtime. Call these from one thread at a time; acquire, submit and
 * discard use the device's immediate context, so call them where the
 * producer renders. */

typedef struct lw_frame_producer lw_frame_producer;

typedef struct lw_frame_producer_params {
    const char *channel;
    void *device;        /* ID3D11Device* (must support ID3D11Device5) */
    lw_fs_format format; /* slot_count 0 = LW_FS_DEFAULT_SLOTS */
    uint32_t timeout_ms; /* how long to wait for the host's answer; 0 = 2000 */
} lw_frame_producer_params;

/* LW_E_UNAVAILABLE: no host is listening on the channel (try again later).
 * LW_E_BUSY: another producer is attached or attaching.
 * LW_E_REFUSED: the host refused; *refusal (if not NULL) gets the reason.
 * LW_E_UNSUPPORTED: the host speaks another LW_FS_VERSION, or the device
 * lacks D3D11.4 fences. */
lw_status lw_frame_producer_attach(const lw_frame_producer_params *params, lw_frame_producer **out,
                                   uint32_t *refusal);

typedef struct lw_frame_producer_slot {
    uint32_t index;
    int32_t superseded; /* 1 if this reclaimed a frame the host never took */
    void *textures[LW_FS_MAX_TEXTURES]; /* ID3D11Texture2D* on the producer's device, NULL where absent */
} lw_frame_producer_slot;

/* A slot to draw into. LW_E_BUSY: the host holds every slot (it stalled);
 * drop this frame. LW_E_ACCESS_LOST: the host went away or ended the attach;
 * detach, then attach again. */
lw_status lw_frame_producer_acquire(lw_frame_producer *producer, lw_frame_producer_slot *out);

/* Queues the fence signal behind the drawing already queued for `slot`,
 * flushes, and hands the slot to the host with its frame number and side data
 * (at most LW_FS_MAX_SIDE_DATA bytes, sent as given: v3 side-data TLVs). */
lw_status lw_frame_producer_submit(lw_frame_producer *producer, uint32_t slot, uint64_t frame_number,
                                   const void *side_data, uint32_t side_data_size);

/* Gives an acquired slot back without submitting it. */
lw_status lw_frame_producer_discard(lw_frame_producer *producer, uint32_t slot);

/* The latest host state (lock-free; never blocks the host). LW_E_BUSY if the
 * host was writing on every attempt, which practically never happens. */
lw_status lw_frame_producer_read_host_state(lw_frame_producer *producer, lw_fs_host_state *out);

typedef struct lw_frame_producer_stats {
    uint64_t generation;
    uint64_t submitted;
    uint64_t superseded; /* frames reclaimed before the host took them */
    uint64_t starved;    /* acquires that found no slot */
} lw_frame_producer_stats;

void lw_frame_producer_get_stats(const lw_frame_producer *producer, lw_frame_producer_stats *out);

/* Ends the attach (if still live) and releases everything. */
void lw_frame_producer_detach(lw_frame_producer *producer);

#ifdef __cplusplus
}
#endif

#endif /* LW_FRAME_SOURCE_H */
