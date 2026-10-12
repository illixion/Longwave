// The producer side of an external frame source (lw_frame_source.h): what an
// in-game component or a compositor links to hand frames to the host.
//
// The producer never creates GPU objects of its own. It asks the host for a
// ring of a given format, then opens the textures and fence the host shares
// with it on its own device, draws into a slot, signals the fence and says so
// in the section.
#include "frame_source_win.hpp"

#include <algorithm>
#include <array>

namespace {

using lw::fs::Handle;

struct ProducerSlot {
    std::array<winrt::com_ptr<ID3D11Texture2D>, LW_FS_MAX_TEXTURES> textures;
};

} // namespace

struct lw_frame_producer {
    lw::fs::Section section;
    Handle host_event;     // we set it: request, frame, detach
    Handle producer_event; // the host sets it: answers, freed slots
    Handle host_process;   // SYNCHRONIZE, duplicated to us by the host
    winrt::com_ptr<ID3D11DeviceContext4> context;
    winrt::com_ptr<ID3D11Fence> fence;
    uint64_t fence_value = 0;
    uint64_t generation = 0;
    uint32_t slot_count = 0;
    std::array<ProducerSlot, LW_FS_MAX_SLOTS> slots;

    lw_fs_shared *shared() const { return section.shared; }

    // Whether the attach is still live: the host process exists and the
    // section still names our generation.
    bool live() const {
        if (host_process && WaitForSingleObject(host_process.value, 0) == WAIT_OBJECT_0) return false;
        return lw_fs_is_attached(shared(), generation) != 0;
    }

    ~lw_frame_producer() {
        if (shared() && generation && lw_fs_detach(shared(), generation) && host_event) SetEvent(host_event.value);
    }
};

namespace {

// Closes every handle the host duplicated into this process for the current
// attach: after opening them (or failing to) they are not needed, and a
// leaked NT handle keeps its GPU object alive.
void close_shared_handles(const lw_fs_shared *shared) {
    auto close = [](uint64_t value) {
        if (value) CloseHandle(reinterpret_cast<HANDLE>(static_cast<uintptr_t>(value)));
    };
    close(shared->fence_handle);
    for (const auto &slot : shared->texture_handles)
        for (uint64_t handle : slot) close(handle);
}

HANDLE as_handle(uint64_t value) { return reinterpret_cast<HANDLE>(static_cast<uintptr_t>(value)); }

lw_status wait_for_answer(lw_frame_producer &p, DWORD timeout_ms) {
    lw_fs_shared *s = p.shared();
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    bool extended = false;
    for (;;) {
        const uint32_t state = lw_fs_attach_state(s);
        if (state == LW_FS_ATTACH_ATTACHED || state == LW_FS_ATTACH_REFUSED) return LW_OK;
        if (state == LW_FS_ATTACH_FREE)
            // A host (re)opened the channel and dropped our request with the old one's state.
            return lw::fail(LW_E_UNAVAILABLE, "frame source: the host restarted during the attach; try again");
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) {
            if (lw_fs_producer_cancel_request(s))
                return lw::fail(LW_E_UNAVAILABLE, "frame source: the host didn't answer within %lu ms",
                                static_cast<unsigned long>(timeout_ms));
            // The host is building our ring: give it one more period.
            if (state == LW_FS_ATTACH_BUILDING && !extended) {
                extended = true;
                deadline = now + timeout_ms;
                continue;
            }
            return lw::fail(LW_E_UNAVAILABLE, "frame source: the host stopped answering mid-attach");
        }
        WaitForSingleObject(p.producer_event.value, static_cast<DWORD>(std::min<ULONGLONG>(deadline - now, 50)));
    }
}

} // namespace

extern "C" lw_status lw_frame_producer_attach(const lw_frame_producer_params *params, lw_frame_producer **out,
                                              uint32_t *refusal) {
    if (!params || !params->device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_attach: NULL argument");
    *out = nullptr;
    if (refusal) *refusal = LW_FS_REFUSE_NONE;
    return lw::guarded("lw_frame_producer_attach", [&]() -> lw_status {
        lw::fs::Names names;
        if (!lw::fs::names_for(params->channel, names)) return LW_E_INVALID_ARG;
        lw_fs_format format = params->format;
        if (format.slot_count == 0) format.slot_count = LW_FS_DEFAULT_SLOTS;
        if (lw_fs_validate_format(&format) != LW_FS_REFUSE_NONE)
            return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_attach: format not accepted (layout %u, %ux%u, format %u)",
                            format.layout, format.image_width, format.image_height, format.image_format);

        auto *device = static_cast<ID3D11Device *>(params->device);
        winrt::com_ptr<ID3D11Device5> device5;
        if (FAILED(device->QueryInterface(IID_PPV_ARGS(device5.put()))))
            return lw::fail(LW_E_UNSUPPORTED, "frame source: the device has no ID3D11Device5 (needs Windows 10 1703+)");
        uint64_t luid = 0;
        if (!lw::fs::device_luid(device, luid)) return lw::fail(LW_E_OS, "frame source: can't read the device's adapter");

        auto p = std::make_unique<lw_frame_producer>();
        winrt::com_ptr<ID3D11DeviceContext> immediate;
        device->GetImmediateContext(immediate.put());
        p->context = immediate.as<ID3D11DeviceContext4>();

        p->section.mapping.reset(OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, names.section.c_str()));
        if (!p->section.mapping) {
            const DWORD error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND) return lw::fail(LW_E_UNAVAILABLE, "frame source: no host on channel '%s'", params->channel);
            return lw::fail_hr(HRESULT_FROM_WIN32(error), "frame source: opening the section");
        }
        p->section.shared = static_cast<lw_fs_shared *>(
            MapViewOfFile(p->section.mapping.value, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(lw_fs_shared)));
        if (!p->section.shared) return lw::fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: mapping the section");
        lw_fs_shared *s = p->shared();
        if (lw_fs_check_identity(s) != LW_FS_REFUSE_NONE)
            return lw::fail(LW_E_UNSUPPORTED, "frame source: the host speaks version %u, this producer %u", s->version, LW_FS_VERSION);
        if (!lw_fs_host_listening(s)) return lw::fail(LW_E_UNAVAILABLE, "frame source: no host is listening on '%s'", params->channel);

        p->host_event.reset(OpenEventW(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, names.host_event.c_str()));
        p->producer_event.reset(OpenEventW(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, names.producer_event.c_str()));
        if (!p->host_event || !p->producer_event)
            return lw::fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: opening the channel's events");

        if (!lw_fs_producer_begin_request(s))
            return lw::fail(LW_E_BUSY, "frame source: another producer is attached to '%s'", params->channel);
        s->producer_pid = GetCurrentProcessId();
        s->producer_version = LW_FS_VERSION;
        s->producer_start_time = lw::fs::process_start_time(GetCurrentProcess());
        s->producer_luid = luid;
        s->format = format;
        lw_fs_producer_commit_request(s);
        SetEvent(p->host_event.value);

        lw_status status = wait_for_answer(*p, params->timeout_ms ? params->timeout_ms : 2000);
        if (status != LW_OK) return status;
        if (lw_fs_attach_state(s) == LW_FS_ATTACH_REFUSED) {
            const uint32_t reason = s->refuse_reason;
            lw_fs_producer_acknowledge_refusal(s);
            if (refusal) *refusal = reason;
            static const char *const reasons[] = {"none", "version", "different GPU (adapter LUID)", "format",
                                                  "can't reach this process", "resources"};
            return lw::fail(LW_E_REFUSED, "frame source: the host refused the attach (%s)",
                            reason < 6 ? reasons[reason] : "unknown");
        }

        // ATTACHED: the handles in the section are ours (the acquire load in
        // lw_fs_attach_state made them visible). From here on `generation`
        // is set, so a failure detaches in the destructor.
        p->generation = s->generation;
        p->slot_count = format.slot_count;
        p->host_process.reset(as_handle(s->host_process_handle));
        struct CloseOnExit {
            const lw_fs_shared *s;
            ~CloseOnExit() { close_shared_handles(s); }
        } close_handles{s};

        HRESULT hr = device5->OpenSharedFence(as_handle(s->fence_handle), IID_PPV_ARGS(p->fence.put()));
        if (FAILED(hr)) return lw::fail_hr(hr, "frame source: opening the shared fence");
        p->fence_value = 0;
        winrt::com_ptr<ID3D11Device1> device1;
        winrt::check_hresult(device->QueryInterface(IID_PPV_ARGS(device1.put())));
        for (uint32_t i = 0; i < p->slot_count; ++i) {
            for (uint32_t t = 0; t < LW_FS_MAX_TEXTURES; ++t) {
                const uint64_t handle = s->texture_handles[i][t];
                if (!handle) continue;
                hr = device1->OpenSharedResource1(as_handle(handle), IID_PPV_ARGS(p->slots[i].textures[t].put()));
                if (FAILED(hr)) return lw::fail_hr(hr, "frame source: opening a shared texture");
            }
        }
        *out = p.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_frame_producer_acquire(lw_frame_producer *producer, lw_frame_producer_slot *out) {
    if (!producer || !out) return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_acquire: NULL argument");
    if (!producer->live()) return lw::fail(LW_E_ACCESS_LOST, "frame source: the host ended the attach");
    uint32_t slot = 0;
    switch (lw_fs_producer_acquire(producer->shared(), producer->generation, producer->slot_count, &slot)) {
    case LW_FS_ACQUIRED:
        out->superseded = 0;
        break;
    case LW_FS_ACQUIRED_SUPERSEDED:
        out->superseded = 1;
        break;
    case LW_FS_NO_SLOT:
        return lw::fail(LW_E_BUSY, "frame source: the host holds every slot");
    default:
        return lw::fail(LW_E_ACCESS_LOST, "frame source: the host ended the attach");
    }
    out->index = slot;
    for (uint32_t t = 0; t < LW_FS_MAX_TEXTURES; ++t) out->textures[t] = producer->slots[slot].textures[t].get();
    return LW_OK;
}

extern "C" lw_status lw_frame_producer_submit(lw_frame_producer *producer, uint32_t slot, uint64_t frame_number,
                                              const void *side_data, uint32_t side_data_size) {
    if (!producer || slot >= producer->slot_count || side_data_size > LW_FS_MAX_SIDE_DATA || (side_data_size && !side_data))
        return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_submit: bad argument");
    // Signal behind the drawing on the same queue, then flush: until the
    // context is flushed the GPU hasn't seen the signal, and the host would
    // wait for our next flush (in a game, the next Present).
    const uint64_t value = ++producer->fence_value;
    HRESULT hr = producer->context->Signal(producer->fence.get(), value);
    if (FAILED(hr)) return lw::fail_hr(hr, "frame source: ID3D11DeviceContext4::Signal");
    producer->context->Flush();
    if (!lw_fs_producer_publish(producer->shared(), producer->generation, producer->slot_count, slot, value, frame_number, lw::qpc_now(),
                                side_data, side_data_size))
        return lw::fail(LW_E_ACCESS_LOST, "frame source: the slot is no longer ours (the host ended the attach)");
    SetEvent(producer->host_event.value);
    return LW_OK;
}

extern "C" lw_status lw_frame_producer_discard(lw_frame_producer *producer, uint32_t slot) {
    if (!producer) return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_discard: NULL argument");
    if (!lw_fs_producer_discard(producer->shared(), producer->generation, producer->slot_count, slot))
        return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_discard: slot %u isn't acquired", slot);
    return LW_OK;
}

extern "C" lw_status lw_frame_producer_read_host_state(lw_frame_producer *producer, lw_fs_host_state *out) {
    if (!producer || !out) return lw::fail(LW_E_INVALID_ARG, "lw_frame_producer_read_host_state: NULL argument");
    if (!lw_fs_read_host_state(producer->shared(), out, 64))
        return lw::fail(LW_E_BUSY, "frame source: the host state was being written on every attempt");
    return LW_OK;
}

extern "C" void lw_frame_producer_get_stats(const lw_frame_producer *producer, lw_frame_producer_stats *out) {
    if (!producer || !out) return;
    const lw_fs_shared *s = producer->shared();
    out->generation = producer->generation;
    out->submitted = lw::fs::counter(s->submitted);
    out->superseded = lw::fs::counter(s->superseded);
    out->starved = lw::fs::counter(s->starved);
}

extern "C" void lw_frame_producer_detach(lw_frame_producer *producer) { delete producer; }
