/*
 * lw_frame_source_layout.h - the shared memory of an external frame source.
 *
 * NATIVE_V3_PROTOCOL.md section 7.2. A producer in another process (an
 * in-game depth component, a VR compositor) hands the Longwave host finished
 * frames as a ring of shared D3D11 textures plus one shared fence. Everything
 * the two processes say to each other besides the GPU objects lives in one
 * named section laid out exactly as below. This header is that contract.
 *
 * It is plain C with fixed-width fields and no Windows types, so it compiles
 * (and its layout is checked) on every platform; lw_frame_source_core.h has
 * the portable protocol logic over it, and CStreamWin's lw_frame_source.h the
 * Windows producer and consumer APIs.
 *
 * Rules every field follows
 *  - Little-endian, natural alignment, no implicit padding: each struct's
 *    size and the offsets that matter are asserted below. A layout change
 *    bumps LW_FS_VERSION; both sides refuse a version they weren't built for.
 *  - Fields marked "atomic" are only ever accessed atomically (std::atomic_ref
 *    in the implementation). Every other field is written by one side only, at
 *    a point the protocol orders with an atomic store (release) and the other
 *    side's matching load (acquire).
 *  - Times are QueryPerformanceCounter ticks. QPC is one clock for the whole
 *    machine, so the two processes need no clock exchange.
 *  - Handles are values in the *producer's* handle table, put there by the
 *    host with DuplicateHandle, stored as uint64_t.
 */
#ifndef LW_FRAME_SOURCE_LAYOUT_H
#define LW_FRAME_SOURCE_LAYOUT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define LW_FS_STATIC_ASSERT(condition, message) static_assert(condition, message)
extern "C" {
#else
#define LW_FS_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif

#define LW_FS_MAGIC 0x5346574Cu /* "LWFS" in memory */
#define LW_FS_VERSION 1u

#define LW_FS_MIN_SLOTS 2
#define LW_FS_MAX_SLOTS 8
#define LW_FS_DEFAULT_SLOTS 3 /* one being encoded, one ready, one being drawn */
#define LW_FS_MAX_SIDE_DATA 1024
#define LW_FS_MAX_DIMENSION 16384

/* ---- Layout of a slot's textures -------------------------------------------
 * Declared once, at attach. A slot holds up to three textures, always at these
 * indices; the ones the layout doesn't use are absent. */
#define LW_FS_TEXTURE_IMAGE 0       /* the picture; the left eye with STEREO_SEPARATE */
#define LW_FS_TEXTURE_IMAGE_RIGHT 1 /* the right eye, STEREO_SEPARATE only */
#define LW_FS_TEXTURE_AUX 2         /* the auxiliary image (depth), if any */
#define LW_FS_MAX_TEXTURES 3

#define LW_FS_LAYOUT_MONO 1                /* one image */
#define LW_FS_LAYOUT_STEREO_SIDE_BY_SIDE 2 /* one image, left eye in the left half */
#define LW_FS_LAYOUT_STEREO_SEPARATE 3     /* one image per eye, same size and format */

#define LW_FS_AUX_NONE 0
#define LW_FS_AUX_DEPTH 1 /* the image's depth, one frame number with it (section 4.8) */

/* Formats are DXGI_FORMAT values. Only these are accepted at attach. */
#define LW_FS_FORMAT_R16G16B16A16_FLOAT 10
#define LW_FS_FORMAT_R10G10B10A2_UNORM 24
#define LW_FS_FORMAT_R8G8B8A8_UNORM 28
#define LW_FS_FORMAT_B8G8R8A8_UNORM 87
/* auxiliary (depth) formats: a depth buffer itself can't be shared, so the
 * producer copies or converts it into one of these colour formats */
#define LW_FS_FORMAT_R32_FLOAT 41
#define LW_FS_FORMAT_R16_FLOAT 54
#define LW_FS_FORMAT_R16_UNORM 56

/* What the producer asks for at attach. Sizes are of each texture: with
 * STEREO_SIDE_BY_SIDE image_width covers both eyes. */
typedef struct lw_fs_format {
    uint32_t layout;       /* LW_FS_LAYOUT_* */
    uint32_t slot_count;   /* LW_FS_MIN_SLOTS..LW_FS_MAX_SLOTS */
    uint32_t image_format; /* LW_FS_FORMAT_*, one of the first four */
    uint32_t image_width;  /* even */
    uint32_t image_height; /* even */
    uint32_t aux_role;     /* LW_FS_AUX_* */
    uint32_t aux_format;   /* an auxiliary LW_FS_FORMAT_*; 0 without aux */
    uint32_t aux_width;    /* 0 without aux */
    uint32_t aux_height;
    uint32_t reserved[3];  /* zero */
} lw_fs_format;

/* ---- Host state (host -> producer, seqlocked) --------------------------------
 * What a VR compositor needs to render the next frame: the latest predicted
 * head pose, the eye geometry, gaze and display pacing. A flat-game producer
 * ignores it. Poses are in the client's immersive space, metres, right-handed
 * (the space the v3 STATE message uses, section 4.7). */
typedef struct lw_fs_pose {
    float position[3];
    float orientation[4]; /* unit quaternion x, y, z, w */
} lw_fs_pose;

typedef struct lw_fs_fov {
    float left, right, up, down; /* tangents of the half-angles; left and down negative */
} lw_fs_fov;

typedef struct lw_fs_host_state {
    uint64_t pose_sequence;     /* the client's pose sequence number; echo it in side data */
    int64_t pose_display_qpc;   /* the display time the pose was predicted for */
    uint32_t pose_valid;        /* head, eye_offset and eye_fov hold data */
    uint32_t space_epoch;       /* bumped on recentre: poses of different epochs don't compare */
    lw_fs_pose head;
    lw_fs_pose eye_offset[2];   /* each eye relative to the head (IPD), left then right */
    lw_fs_fov eye_fov[2];
    uint32_t gaze_valid;        /* stays 0 unless the client sends gaze */
    float gaze_direction[3];    /* unit vector, head space */
    float gaze_distance;        /* metres; 0 = unknown */
    int64_t gaze_qpc;           /* when the gaze sample was taken */
    uint32_t refresh_millihz;   /* the client's display refresh, e.g. 90000; 0 = unknown */
    uint32_t reserved0;
    int64_t next_frame_start_qpc; /* when the producer should start its next frame; 0 = unpaced */
    int64_t written_qpc;        /* when the host published this state */
    uint32_t reserved[16];
} lw_fs_host_state;

/* ---- Slots -------------------------------------------------------------------
 * A slot's state word packs (generation, tag, state) so that every transition
 * is one compare-and-swap on the exact word last seen: a stale frame from an
 * earlier attach (other generation) or a slot that was republished in between
 * (other tag) can never be moved by mistake. */
#define LW_FS_SLOT_FREE 0      /* the producer may take it */
#define LW_FS_SLOT_PRODUCING 1 /* the producer is drawing into it */
#define LW_FS_SLOT_READY 2     /* submitted; the host may take it, or the producer reclaim it */
#define LW_FS_SLOT_CONSUMING 3 /* the host holds it until its GPU work on it is done */

#define LW_FS_SLOT_WORD(generation, tag, state)                                             \
    (((uint64_t)(uint32_t)(generation) << 32) | (((uint64_t)(tag) & 0xFFFFFFu) << 8) |     \
     ((uint64_t)(state) & 0xFFu))
#define LW_FS_SLOT_STATE(word) ((uint32_t)((word) & 0xFFu))
#define LW_FS_SLOT_TAG(word) ((uint32_t)(((word) >> 8) & 0xFFFFFFu))
#define LW_FS_SLOT_GENERATION(word) ((uint32_t)((word) >> 32))

typedef struct lw_fs_slot {
    uint64_t state;           /* atomic, LW_FS_SLOT_WORD */
    uint64_t fence_value;     /* the fence reaches this when the slot's GPU work is done */
    uint64_t frame_number;    /* the producer's, carried to the stream (section 4.2) */
    uint64_t submit_sequence; /* the producer's submit count: the newest ready slot wins */
    int64_t present_qpc;      /* when the producer submitted */
    uint32_t side_data_size;
    uint32_t reserved;
    uint8_t side_data[LW_FS_MAX_SIDE_DATA]; /* opaque: v3 side-data TLV bytes, sent as given */
} lw_fs_slot;

/* ---- The section ------------------------------------------------------------ */
#define LW_FS_HOST_GONE 0
#define LW_FS_HOST_LISTENING 1

/* The attach handshake. One producer per channel. */
#define LW_FS_ATTACH_FREE 0      /* no producer */
#define LW_FS_ATTACH_WRITING 1   /* a producer won the channel and is filling in its request */
#define LW_FS_ATTACH_REQUESTED 2 /* the request is complete; the host's turn */
#define LW_FS_ATTACH_BUILDING 3  /* the host is building the ring */
#define LW_FS_ATTACH_ATTACHED 4  /* handles and generation are valid */
#define LW_FS_ATTACH_REFUSED 5   /* refuse_reason says why; the producer resets it to FREE */

/* The attach word carries the generation while ATTACHED (0 in every other
 * state), so ending an attach is a compare-and-swap that can't end a later one. */
#define LW_FS_ATTACH_WORD(generation, state) \
    (((uint64_t)(uint32_t)(generation) << 32) | ((uint64_t)(state) & 0xFFFFFFFFu))
#define LW_FS_ATTACH_STATE(word) ((uint32_t)((word) & 0xFFFFFFFFu))
#define LW_FS_ATTACH_GENERATION(word) ((uint32_t)((word) >> 32))

#define LW_FS_REFUSE_NONE 0
#define LW_FS_REFUSE_VERSION 1   /* the producer was built for another LW_FS_VERSION */
#define LW_FS_REFUSE_ADAPTER 2   /* producer and host are on different GPUs (LUID) */
#define LW_FS_REFUSE_FORMAT 3    /* layout, format, size or slot count not accepted */
#define LW_FS_REFUSE_PROCESS 4   /* the host can't reach the producer's process */
#define LW_FS_REFUSE_RESOURCES 5 /* creating or sharing the textures or fence failed */

typedef struct lw_fs_shared {
    /* Identity, written by the host that creates the section. */
    uint32_t magic;
    uint32_t version;
    uint32_t size;                 /* sizeof(lw_fs_shared) */
    uint32_t host_state;           /* atomic, LW_FS_HOST_* */
    uint64_t host_epoch;           /* atomic, bumped whenever a host opens the channel */
    uint32_t host_pid;
    uint32_t refuse_reason;        /* LW_FS_REFUSE_* with LW_FS_ATTACH_REFUSED */

    /* Handshake: the producer writes the request, the host the answer. */
    uint64_t attach;               /* atomic, LW_FS_ATTACH_WORD */
    uint64_t generation;           /* host: this attach's ring; never reused within a section */
    uint32_t producer_pid;
    uint32_t producer_version;     /* LW_FS_VERSION the producer was built with */
    uint64_t producer_start_time;  /* its process creation time (FILETIME): pins the pid */
    uint64_t producer_luid;        /* adapter LUID: LowPart | HighPart << 32 */
    uint64_t host_luid;
    lw_fs_format format;
    uint64_t fence_handle;         /* ID3D11Fence, starts at 0 for every generation */
    uint64_t host_process_handle;  /* SYNCHRONIZE only: the producer's way to see the host die */
    uint64_t texture_handles[LW_FS_MAX_SLOTS][LW_FS_MAX_TEXTURES]; /* 0 where absent */

    /* Counters, each written by one side (atomic increments). */
    uint64_t submitted;            /* producer: frames submitted this generation */
    uint64_t superseded;           /* producer: ready frames it reclaimed before the host took them */
    uint64_t starved;              /* producer: acquires that found no slot */
    uint64_t consumed;             /* host: frames taken */
    uint64_t dropped;              /* host: ready frames it skipped for a newer one */
    uint64_t submit_sequence;      /* producer: the last submit_sequence handed out */

    /* Host state, seqlocked: odd while the host is writing. */
    uint64_t host_state_sequence;  /* atomic */
    lw_fs_host_state host_state_data;
    uint64_t taken_sequence;       /* host: submit_sequence of the last frame it took */
    uint64_t host_start_time;      /* the host's process creation time: pins host_pid */
    uint64_t reserved1[5];

    lw_fs_slot slots[LW_FS_MAX_SLOTS];
} lw_fs_shared;

LW_FS_STATIC_ASSERT(sizeof(lw_fs_format) == 48, "lw_fs_format layout");
LW_FS_STATIC_ASSERT(sizeof(lw_fs_pose) == 28, "lw_fs_pose layout");
LW_FS_STATIC_ASSERT(sizeof(lw_fs_fov) == 16, "lw_fs_fov layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_host_state, head) == 24, "lw_fs_host_state layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_host_state, gaze_valid) == 140, "lw_fs_host_state layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_host_state, gaze_qpc) == 160, "lw_fs_host_state layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_host_state, next_frame_start_qpc) == 176, "lw_fs_host_state layout");
LW_FS_STATIC_ASSERT(sizeof(lw_fs_host_state) == 256, "lw_fs_host_state layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_slot, side_data) == 48, "lw_fs_slot layout");
LW_FS_STATIC_ASSERT(sizeof(lw_fs_slot) == 48 + LW_FS_MAX_SIDE_DATA, "lw_fs_slot layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, attach) == 32, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, format) == 80, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, fence_handle) == 128, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, texture_handles) == 144, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, submitted) == 336, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, host_state_sequence) == 384, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, host_state_data) == 392, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, slots) == 704, "lw_fs_shared layout");
LW_FS_STATIC_ASSERT(offsetof(lw_fs_shared, slots) % 64 == 0, "slots start on a cache line");
LW_FS_STATIC_ASSERT(sizeof(lw_fs_shared) == 704 + LW_FS_MAX_SLOTS * (48 + LW_FS_MAX_SIDE_DATA),
                    "lw_fs_shared layout");

#ifdef __cplusplus
}
#endif

#endif /* LW_FRAME_SOURCE_LAYOUT_H */
