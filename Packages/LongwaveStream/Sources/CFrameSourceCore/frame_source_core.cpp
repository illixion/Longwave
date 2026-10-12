// The portable external-frame-source protocol (lw_frame_source_core.h).
//
// The section is shared memory between two processes, so every field that
// both sides touch concurrently goes through std::atomic_ref (lock-free 32-
// and 64-bit atomics are address-free, which is what makes them valid across
// processes). Plain fields are only written while the protocol gives one side
// sole ownership, and handed over with a release store / acquire load.
#include "lw_frame_source_core.h"

#include <atomic>
#include <cstring>
#include <initializer_list>

namespace {

static_assert(std::atomic_ref<uint64_t>::is_always_lock_free, "64-bit atomics must be lock-free");
static_assert(std::atomic_ref<uint32_t>::is_always_lock_free, "32-bit atomics must be lock-free");

// std::atomic_ref<const T> only arrives in C++26; loads from a const section
// cast the const away, which is sound because a load never writes.
template <typename T>
std::atomic_ref<T> atomic(const T &field) {
    return std::atomic_ref<T>(const_cast<T &>(field));
}

uint64_t load(const uint64_t &field, std::memory_order order = std::memory_order_acquire) {
    return atomic(field).load(order);
}

uint32_t load32(const uint32_t &field, std::memory_order order = std::memory_order_acquire) {
    return atomic(field).load(order);
}

bool exchange(uint64_t &field, uint64_t expected, uint64_t desired) {
    return std::atomic_ref<uint64_t>(field).compare_exchange_strong(expected, desired, std::memory_order_acq_rel,
                                                                    std::memory_order_acquire);
}

void increment(uint64_t &counter) { std::atomic_ref<uint64_t>(counter).fetch_add(1, std::memory_order_relaxed); }

uint32_t slot_count(const lw_fs_shared *shared) {
    const uint32_t count = shared->format.slot_count;
    return count > LW_FS_MAX_SLOTS ? LW_FS_MAX_SLOTS : count;
}

bool transition(lw_fs_shared *shared, uint32_t from, uint32_t to) {
    return exchange(shared->attach, LW_FS_ATTACH_WORD(0, from), LW_FS_ATTACH_WORD(0, to));
}

constexpr uint32_t kRetries = 8; // CAS races per call before giving up; each needs the other side to act

} // namespace

extern "C" {

// ---- Section lifetime ----------------------------------------------------------

void lw_fs_init(lw_fs_shared *shared) {
    std::memset(shared, 0, sizeof *shared);
    shared->magic = LW_FS_MAGIC;
    shared->version = LW_FS_VERSION;
    shared->size = sizeof(lw_fs_shared);
}

uint32_t lw_fs_check_identity(const lw_fs_shared *shared) {
    return shared->magic == LW_FS_MAGIC && shared->version == LW_FS_VERSION && shared->size == sizeof(lw_fs_shared)
               ? LW_FS_REFUSE_NONE
               : LW_FS_REFUSE_VERSION;
}

uint64_t lw_fs_host_open(lw_fs_shared *shared, uint32_t host_pid) {
    const uint64_t epoch = std::atomic_ref<uint64_t>(shared->host_epoch).fetch_add(1, std::memory_order_acq_rel) + 1;
    shared->host_pid = host_pid;
    // An attach, a half-built ring or an unread refusal belonged to the
    // previous host. A complete request (or one being written) is kept: its
    // producer is waiting, and this host can answer it.
    for (uint32_t i = 0; i < kRetries; ++i) {
        const uint64_t word = load(shared->attach);
        const uint32_t state = LW_FS_ATTACH_STATE(word);
        if (state == LW_FS_ATTACH_FREE || state == LW_FS_ATTACH_WRITING || state == LW_FS_ATTACH_REQUESTED) break;
        if (exchange(shared->attach, word, LW_FS_ATTACH_WORD(0, LW_FS_ATTACH_FREE))) break;
    }
    std::atomic_ref<uint32_t>(shared->host_state).store(LW_FS_HOST_LISTENING, std::memory_order_release);
    return epoch;
}

void lw_fs_host_close(lw_fs_shared *shared) {
    std::atomic_ref<uint32_t>(shared->host_state).store(LW_FS_HOST_GONE, std::memory_order_release);
    for (uint32_t i = 0; i < kRetries; ++i) {
        const uint64_t word = load(shared->attach);
        const uint32_t state = LW_FS_ATTACH_STATE(word);
        if (state != LW_FS_ATTACH_ATTACHED && state != LW_FS_ATTACH_BUILDING) break;
        if (exchange(shared->attach, word, LW_FS_ATTACH_WORD(0, LW_FS_ATTACH_FREE))) break;
    }
}

int lw_fs_host_listening(const lw_fs_shared *shared) { return load32(shared->host_state) == LW_FS_HOST_LISTENING; }

uint32_t lw_fs_attach_state(const lw_fs_shared *shared) { return LW_FS_ATTACH_STATE(load(shared->attach)); }

// ---- Attach handshake -------------------------------------------------------------

int lw_fs_producer_begin_request(lw_fs_shared *shared) {
    return transition(shared, LW_FS_ATTACH_FREE, LW_FS_ATTACH_WRITING);
}

void lw_fs_producer_commit_request(lw_fs_shared *shared) {
    // A plain store, not a CAS: WRITING belongs to this producer alone, and a
    // host that (re)opened meanwhile leaves WRITING untouched.
    std::atomic_ref<uint64_t>(shared->attach).store(LW_FS_ATTACH_WORD(0, LW_FS_ATTACH_REQUESTED),
                                                    std::memory_order_release);
}

int lw_fs_producer_cancel_request(lw_fs_shared *shared) {
    return transition(shared, LW_FS_ATTACH_REQUESTED, LW_FS_ATTACH_FREE);
}

int lw_fs_producer_acknowledge_refusal(lw_fs_shared *shared) {
    return transition(shared, LW_FS_ATTACH_REFUSED, LW_FS_ATTACH_FREE);
}

int lw_fs_host_begin_attach(lw_fs_shared *shared) {
    return transition(shared, LW_FS_ATTACH_REQUESTED, LW_FS_ATTACH_BUILDING);
}

int lw_fs_host_reclaim(lw_fs_shared *shared, uint32_t state) {
    if (state != LW_FS_ATTACH_WRITING && state != LW_FS_ATTACH_REFUSED) return 0;
    return transition(shared, state, LW_FS_ATTACH_FREE);
}

uint32_t lw_fs_validate_format(const lw_fs_format *format) {
    auto image_format_ok = [](uint32_t f) {
        return f == LW_FS_FORMAT_B8G8R8A8_UNORM || f == LW_FS_FORMAT_R8G8B8A8_UNORM ||
               f == LW_FS_FORMAT_R10G10B10A2_UNORM || f == LW_FS_FORMAT_R16G16B16A16_FLOAT;
    };
    auto aux_format_ok = [](uint32_t f) {
        return f == LW_FS_FORMAT_R32_FLOAT || f == LW_FS_FORMAT_R16_FLOAT || f == LW_FS_FORMAT_R16_UNORM;
    };
    auto size_ok = [](uint32_t w, uint32_t h) {
        return w > 0 && h > 0 && w <= LW_FS_MAX_DIMENSION && h <= LW_FS_MAX_DIMENSION;
    };
    if (format->layout < LW_FS_LAYOUT_MONO || format->layout > LW_FS_LAYOUT_STEREO_SEPARATE) return LW_FS_REFUSE_FORMAT;
    if (format->slot_count < LW_FS_MIN_SLOTS || format->slot_count > LW_FS_MAX_SLOTS) return LW_FS_REFUSE_FORMAT;
    if (!image_format_ok(format->image_format)) return LW_FS_REFUSE_FORMAT;
    // Even sizes: the encoder works in 4:2:0.
    if (!size_ok(format->image_width, format->image_height) || (format->image_width & 1) || (format->image_height & 1))
        return LW_FS_REFUSE_FORMAT;
    if (format->layout == LW_FS_LAYOUT_STEREO_SIDE_BY_SIDE && (format->image_width & 3))
        return LW_FS_REFUSE_FORMAT; // each eye even too
    switch (format->aux_role) {
    case LW_FS_AUX_NONE:
        if (format->aux_format || format->aux_width || format->aux_height) return LW_FS_REFUSE_FORMAT;
        break;
    case LW_FS_AUX_DEPTH:
        if (!aux_format_ok(format->aux_format) || !size_ok(format->aux_width, format->aux_height))
            return LW_FS_REFUSE_FORMAT;
        break;
    default:
        return LW_FS_REFUSE_FORMAT;
    }
    for (uint32_t r : format->reserved)
        if (r) return LW_FS_REFUSE_FORMAT;
    return LW_FS_REFUSE_NONE;
}

void lw_fs_host_finish_attach(lw_fs_shared *shared, uint64_t generation) {
    // BUILDING belongs to the host: no producer touches slots or counters now.
    shared->generation = generation;
    shared->refuse_reason = LW_FS_REFUSE_NONE;
    for (auto &slot : shared->slots) {
        std::atomic_ref<uint64_t>(slot.state).store(LW_FS_SLOT_WORD(generation, 0, LW_FS_SLOT_FREE),
                                                    std::memory_order_relaxed);
        slot.fence_value = slot.frame_number = 0;
        std::atomic_ref<uint64_t>(slot.submit_sequence).store(0, std::memory_order_relaxed);
        slot.present_qpc = 0;
        slot.side_data_size = 0;
    }
    shared->taken_sequence = 0;
    for (uint64_t *counter : {&shared->submitted, &shared->superseded, &shared->starved, &shared->consumed,
                              &shared->dropped, &shared->submit_sequence})
        std::atomic_ref<uint64_t>(*counter).store(0, std::memory_order_relaxed);
    std::atomic_ref<uint64_t>(shared->attach).store(LW_FS_ATTACH_WORD(generation, LW_FS_ATTACH_ATTACHED),
                                                    std::memory_order_release);
}

void lw_fs_host_refuse(lw_fs_shared *shared, uint32_t reason) {
    shared->refuse_reason = reason;
    std::atomic_ref<uint64_t>(shared->attach).store(LW_FS_ATTACH_WORD(0, LW_FS_ATTACH_REFUSED),
                                                    std::memory_order_release);
}

int lw_fs_detach(lw_fs_shared *shared, uint64_t generation) {
    return exchange(shared->attach, LW_FS_ATTACH_WORD(generation, LW_FS_ATTACH_ATTACHED),
                    LW_FS_ATTACH_WORD(0, LW_FS_ATTACH_FREE));
}

int lw_fs_is_attached(const lw_fs_shared *shared, uint64_t generation) {
    return load(shared->attach) == LW_FS_ATTACH_WORD(generation, LW_FS_ATTACH_ATTACHED) &&
           load32(shared->host_state) == LW_FS_HOST_LISTENING;
}

// ---- Slot ring ----------------------------------------------------------------------

int lw_fs_producer_acquire(lw_fs_shared *shared, uint64_t generation, uint32_t *out_slot) {
    if (!lw_fs_is_attached(shared, generation)) return LW_FS_STALE;
    const uint32_t gen = static_cast<uint32_t>(generation);
    const uint32_t count = slot_count(shared);
    for (uint32_t attempt = 0; attempt < kRetries; ++attempt) {
        for (uint32_t i = 0; i < count; ++i) {
            const uint64_t word = load(shared->slots[i].state);
            if (LW_FS_SLOT_GENERATION(word) != gen || LW_FS_SLOT_STATE(word) != LW_FS_SLOT_FREE) continue;
            if (exchange(shared->slots[i].state, word, LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_PRODUCING))) {
                *out_slot = i;
                return LW_FS_ACQUIRED;
            }
        }
        // No free slot: reclaim the oldest frame the host hasn't taken.
        uint32_t oldest = count;
        uint64_t oldest_word = 0, oldest_sequence = UINT64_MAX;
        for (uint32_t i = 0; i < count; ++i) {
            const uint64_t word = load(shared->slots[i].state);
            if (LW_FS_SLOT_GENERATION(word) != gen || LW_FS_SLOT_STATE(word) != LW_FS_SLOT_READY) continue;
            const uint64_t sequence = load(shared->slots[i].submit_sequence, std::memory_order_relaxed);
            if (sequence < oldest_sequence) {
                oldest = i;
                oldest_word = word;
                oldest_sequence = sequence;
            }
        }
        if (oldest == count) break; // the host holds everything else
        if (exchange(shared->slots[oldest].state, oldest_word, LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_PRODUCING))) {
            increment(shared->superseded);
            *out_slot = oldest;
            return LW_FS_ACQUIRED_SUPERSEDED;
        }
        // The host took it first; look again.
    }
    increment(shared->starved);
    return LW_FS_NO_SLOT;
}

int lw_fs_producer_publish(lw_fs_shared *shared, uint64_t generation, uint32_t slot, uint64_t fence_value,
                           uint64_t frame_number, int64_t present_qpc, const void *side_data,
                           uint32_t side_data_size) {
    if (slot >= slot_count(shared) || side_data_size > LW_FS_MAX_SIDE_DATA || (side_data_size && !side_data))
        return 0;
    const uint32_t gen = static_cast<uint32_t>(generation);
    lw_fs_slot &s = shared->slots[slot];
    const uint64_t word = load(s.state);
    if (word != LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_PRODUCING)) return 0;
    s.fence_value = fence_value;
    s.frame_number = frame_number;
    s.present_qpc = present_qpc;
    s.side_data_size = side_data_size;
    if (side_data_size) std::memcpy(s.side_data, side_data, side_data_size);
    const uint64_t sequence =
        std::atomic_ref<uint64_t>(shared->submit_sequence).fetch_add(1, std::memory_order_relaxed) + 1;
    std::atomic_ref<uint64_t>(s.submit_sequence).store(sequence, std::memory_order_relaxed);
    // The tag makes this publication's word unique, so a host CAS based on an
    // earlier look at the slot can't move this frame.
    if (!exchange(s.state, word, LW_FS_SLOT_WORD(gen, sequence, LW_FS_SLOT_READY))) return 0;
    increment(shared->submitted);
    return 1;
}

int lw_fs_producer_discard(lw_fs_shared *shared, uint64_t generation, uint32_t slot) {
    if (slot >= slot_count(shared)) return 0;
    const uint32_t gen = static_cast<uint32_t>(generation);
    return exchange(shared->slots[slot].state, LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_PRODUCING),
                    LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_FREE));
}

int lw_fs_host_take_newest(lw_fs_shared *shared, uint64_t generation, uint32_t *out_slot) {
    if (load(shared->attach) != LW_FS_ATTACH_WORD(generation, LW_FS_ATTACH_ATTACHED)) return 0;
    const uint32_t gen = static_cast<uint32_t>(generation);
    const uint32_t count = slot_count(shared);
    for (uint32_t attempt = 0; attempt < kRetries; ++attempt) {
        // The scan is not a snapshot: a slot read early as PRODUCING can be
        // published, just ahead of a newer one read later. So "newest" is
        // judged against the last frame taken too, and anything not newer
        // than it is never delivered (frames reach the host in order).
        uint64_t words[LW_FS_MAX_SLOTS] = {};
        uint64_t sequences[LW_FS_MAX_SLOTS] = {};
        uint32_t newest = count;
        for (uint32_t i = 0; i < count; ++i) {
            words[i] = load(shared->slots[i].state);
            if (LW_FS_SLOT_GENERATION(words[i]) != gen || LW_FS_SLOT_STATE(words[i]) != LW_FS_SLOT_READY) continue;
            sequences[i] = load(shared->slots[i].submit_sequence, std::memory_order_relaxed);
            if (sequences[i] > shared->taken_sequence && (newest == count || sequences[i] > sequences[newest]))
                newest = i;
        }
        const uint64_t floor = newest == count ? shared->taken_sequence : sequences[newest];
        // Ready frames older than the one taken (or than the last one taken)
        // will never be shown: give them back now rather than leaving the
        // producer to reclaim them. The CAS on the exact word seen above skips
        // any slot republished since (its tag changed).
        for (uint32_t i = 0; i < count; ++i) {
            if (i == newest || LW_FS_SLOT_STATE(words[i]) != LW_FS_SLOT_READY ||
                LW_FS_SLOT_GENERATION(words[i]) != gen || sequences[i] >= floor)
                continue;
            if (exchange(shared->slots[i].state, words[i], LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_FREE)))
                increment(shared->dropped);
        }
        if (newest == count) return 0;
        const uint64_t taken = LW_FS_SLOT_WORD(gen, LW_FS_SLOT_TAG(words[newest]), LW_FS_SLOT_CONSUMING);
        if (!exchange(shared->slots[newest].state, words[newest], taken)) continue; // reclaimed meanwhile
        shared->taken_sequence = sequences[newest];
        increment(shared->consumed);
        *out_slot = newest;
        return 1;
    }
    return 0;
}

int lw_fs_host_release(lw_fs_shared *shared, uint64_t generation, uint32_t slot) {
    if (slot >= LW_FS_MAX_SLOTS) return 0;
    const uint32_t gen = static_cast<uint32_t>(generation);
    for (uint32_t attempt = 0; attempt < kRetries; ++attempt) {
        const uint64_t word = load(shared->slots[slot].state);
        if (LW_FS_SLOT_GENERATION(word) != gen || LW_FS_SLOT_STATE(word) != LW_FS_SLOT_CONSUMING) return 0;
        if (exchange(shared->slots[slot].state, word, LW_FS_SLOT_WORD(gen, 0, LW_FS_SLOT_FREE))) return 1;
    }
    return 0;
}

// ---- Host state seqlock ----------------------------------------------------------------
// The payload is copied as 32-bit words through relaxed atomics, so a reader
// racing the writer reads torn data (which the sequence check then discards)
// rather than invoking a data race. Fences order the payload against the
// sequence number (the classic seqlock; Boehm, MSPC 2012).

namespace {
constexpr size_t kStateWords = sizeof(lw_fs_host_state) / sizeof(uint32_t);
static_assert(sizeof(lw_fs_host_state) % sizeof(uint32_t) == 0, "host state copies as words");
} // namespace

void lw_fs_host_write_state(lw_fs_shared *shared, const lw_fs_host_state *state) {
    uint32_t words[kStateWords];
    std::memcpy(words, state, sizeof words);
    auto *target = reinterpret_cast<uint32_t *>(&shared->host_state_data);
    std::atomic_ref<uint64_t> sequence(shared->host_state_sequence);
    const uint64_t start = sequence.load(std::memory_order_relaxed);
    sequence.store(start + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    for (size_t i = 0; i < kStateWords; ++i) std::atomic_ref<uint32_t>(target[i]).store(words[i], std::memory_order_relaxed);
    sequence.store(start + 2, std::memory_order_release);
}

int lw_fs_read_host_state(const lw_fs_shared *shared, lw_fs_host_state *out, uint32_t max_attempts) {
    const auto *source = reinterpret_cast<const uint32_t *>(&shared->host_state_data);
    uint32_t words[kStateWords];
    for (uint32_t attempt = 0; attempt < max_attempts; ++attempt) {
        const uint64_t before = load(shared->host_state_sequence);
        if (before & 1) continue; // a write is in progress
        for (size_t i = 0; i < kStateWords; ++i) words[i] = load32(source[i], std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (load(shared->host_state_sequence, std::memory_order_relaxed) == before) {
            std::memcpy(out, words, sizeof words);
            return 1;
        }
    }
    return 0;
}

} // extern "C"
