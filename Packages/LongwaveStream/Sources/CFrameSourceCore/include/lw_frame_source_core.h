/*
 * lw_frame_source_core.h - the portable protocol over lw_fs_shared.
 *
 * Every state change of an external frame source (NATIVE_V3_PROTOCOL.md 7.2)
 * is one of these functions: the attach handshake, the slot ring and the
 * seqlocked host state. They only touch the shared memory, never an OS or GPU
 * object, so the same code runs in the Windows producer and host and in the
 * unit tests on any platform. The Windows layer (CStreamWin) adds the named
 * section, the events, the textures and the fence around them.
 *
 * Functions named lw_fs_producer_* are called by the producer, lw_fs_host_*
 * by the host. Each side calls its functions from one thread at a time, except
 * lw_fs_host_release, which may race the host's other calls. Return values of
 * type int are 1 for "done" and 0 for "the state wasn't what was expected";
 * nothing here blocks.
 */
#ifndef LW_FRAME_SOURCE_CORE_H
#define LW_FRAME_SOURCE_CORE_H

#include "lw_frame_source_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Section lifetime (host) ---------------------------------------------- */

/* Zeroes `shared` and writes its identity. For a section the host just created. */
void lw_fs_init(lw_fs_shared *shared);

/* LW_FS_REFUSE_NONE if `shared` has this build's magic, version and size,
 * else LW_FS_REFUSE_VERSION. */
uint32_t lw_fs_check_identity(const lw_fs_shared *shared);

/* A host takes over the channel: bumps host_epoch, records its pid, ends any
 * attach left by an earlier host (a producer still holding it sees that and
 * attaches again), keeps a complete request waiting for it, and starts
 * listening. Returns the new epoch. */
uint64_t lw_fs_host_open(lw_fs_shared *shared, uint32_t host_pid);

/* The host stops listening and ends any attach. */
void lw_fs_host_close(lw_fs_shared *shared);

/* Whether a host is listening on the channel. */
int lw_fs_host_listening(const lw_fs_shared *shared);
uint32_t lw_fs_attach_state(const lw_fs_shared *shared);

/* ---- Attach handshake -------------------------------------------------------
 * producer: begin_request (FREE -> WRITING), fill in the request fields,
 *           commit_request (-> REQUESTED), wait for ATTACHED or REFUSED.
 * host:     begin_attach (REQUESTED -> BUILDING), validate and build,
 *           finish_attach (-> ATTACHED) or refuse (-> REFUSED).
 * producer: acknowledge_refusal (REFUSED -> FREE), or, giving up on a host
 *           that never answered, cancel_request (REQUESTED -> FREE). */

int lw_fs_producer_begin_request(lw_fs_shared *shared);
void lw_fs_producer_commit_request(lw_fs_shared *shared);
int lw_fs_producer_cancel_request(lw_fs_shared *shared);
int lw_fs_producer_acknowledge_refusal(lw_fs_shared *shared);

int lw_fs_host_begin_attach(lw_fs_shared *shared);

/* LW_FS_REFUSE_NONE if the format is acceptable, else LW_FS_REFUSE_FORMAT.
 * slot_count must already be resolved (no 0 = default here). */
uint32_t lw_fs_validate_format(const lw_fs_format *format);

/* Resets every slot to FREE in `generation`, zeroes the per-generation
 * counters, and publishes ATTACHED. The handles and host_luid must already be
 * written: the release store here is what makes them visible. */
void lw_fs_host_finish_attach(lw_fs_shared *shared, uint64_t generation);
void lw_fs_host_refuse(lw_fs_shared *shared, uint32_t reason);

/* Either side ends the attach of `generation` (ATTACHED -> FREE). 0 if that
 * attach had already ended. */
int lw_fs_detach(lw_fs_shared *shared, uint64_t generation);

/* Whether `generation` is still the live attach (and the host still listens). */
int lw_fs_is_attached(const lw_fs_shared *shared, uint64_t generation);

/* ---- Slot ring --------------------------------------------------------------- */

#define LW_FS_ACQUIRED 0            /* a free slot */
#define LW_FS_ACQUIRED_SUPERSEDED 1 /* no free slot: reclaimed the oldest ready frame */
#define LW_FS_NO_SLOT 2             /* the host holds every other slot */
#define LW_FS_STALE 3               /* `generation` is no longer attached */

/* Takes a slot to draw into: a free one, else the oldest ready frame the host
 * hasn't taken (latest wins: a frame nobody encoded yet is worth less than
 * the next one). */
int lw_fs_producer_acquire(lw_fs_shared *shared, uint64_t generation, uint32_t *out_slot);

/* PRODUCING -> READY with the frame's metadata. The caller has already queued
 * the fence signal to `fence_value` on its GPU queue. side_data_size must be
 * <= LW_FS_MAX_SIDE_DATA. 0 if the slot isn't this producer's (stale). */
int lw_fs_producer_publish(lw_fs_shared *shared, uint64_t generation, uint32_t slot,
                           uint64_t fence_value, uint64_t frame_number, int64_t present_qpc,
                           const void *side_data, uint32_t side_data_size);

/* PRODUCING -> FREE without submitting. */
int lw_fs_producer_discard(lw_fs_shared *shared, uint64_t generation, uint32_t slot);

/* Takes the newest ready frame (READY -> CONSUMING) and frees every older
 * ready one, counting them as dropped. 1 and the slot if there was one. The
 * slot's metadata is stable until lw_fs_host_release. Frames are taken in
 * submit order: a ready frame no newer than the last one taken is dropped,
 * never delivered. */
int lw_fs_host_take_newest(lw_fs_shared *shared, uint64_t generation, uint32_t *out_slot);

/* CONSUMING -> FREE. Call only once the host's GPU work reading the slot is
 * finished. 0 if `generation` has ended (nothing to give back). */
int lw_fs_host_release(lw_fs_shared *shared, uint64_t generation, uint32_t slot);

/* ---- Host state seqlock -------------------------------------------------------
 * One writer (the host), any number of readers. A reader never blocks the
 * writer; it retries while a write is in progress. */
void lw_fs_host_write_state(lw_fs_shared *shared, const lw_fs_host_state *state);

/* 1 and a consistent copy, or 0 after `max_attempts` reads that each raced a
 * write (only possible if the writer is writing continuously). */
int lw_fs_read_host_state(const lw_fs_shared *shared, lw_fs_host_state *out, uint32_t max_attempts);

#ifdef __cplusplus
}
#endif

#endif /* LW_FRAME_SOURCE_CORE_H */
