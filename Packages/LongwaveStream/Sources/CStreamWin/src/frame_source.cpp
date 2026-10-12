// The host side of an external frame source (lw_frame_source.h): a capture
// source next to WGC and duplication whose frames another process renders.
//
// One thread per source owns the channel. It answers attach requests (building
// a ring of shared textures and a shared fence on the host's device and
// duplicating their handles into the producer), notices a producer that
// detaches or dies, and delivers the newest submitted frame once the fence
// says the producer's GPU work on it is done. Frames are lw_frames whose
// texture is the shared slot texture itself, so they go to the encoder with
// no copy.
#include "frame_source_win.hpp"

#include <array>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace {

using lw::fs::Handle;

// The named objects, shared by the source and every frame it delivered (a
// frame may outlive lw_frame_source_stop and still give its slot back).
struct Channel {
    lw::fs::Section section;
    Handle host_event;
    Handle producer_event;
    lw_fs_shared *shared() const { return section.shared; }
};

// One attach's GPU objects.
struct Ring {
    std::shared_ptr<Channel> channel;
    uint64_t generation = 0;
    lw_fs_format format{};
    std::array<std::array<winrt::com_ptr<ID3D11Texture2D>, LW_FS_MAX_TEXTURES>, LW_FS_MAX_SLOTS> textures;
};

struct SourceFrame final : lw_frame {
    std::shared_ptr<Ring> ring;
    lw_frame_source_info source{};

    ~SourceFrame() override {
        // Fails harmlessly if the attach has ended and a new ring reuses the slot.
        if (lw_fs_host_release(ring->channel->shared(), ring->generation, source.slot))
            SetEvent(ring->channel->producer_event.value);
    }
    const lw_frame_source_info *source_info() const override { return &source; }
};

// A handle in the producer's table: closed there if the attach is abandoned.
struct RemoteHandles {
    HANDLE process = nullptr;
    std::vector<HANDLE> values;
    bool keep = false;
    ~RemoteHandles() {
        if (keep) return;
        for (HANDLE h : values) DuplicateHandle(process, h, nullptr, nullptr, 0, FALSE, DUPLICATE_CLOSE_SOURCE);
    }
};

constexpr DWORD kFenceTimeoutMs = 1000; // far beyond any frame; only a hung producer GPU reaches it
constexpr ULONGLONG kStuckHandshakeMs = 3000;

} // namespace

struct lw_frame_source {
    std::shared_ptr<Channel> channel;
    lw::fs::Security security;
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11Device5> device5;
    uint64_t luid = 0;
    lw_frame_callback callback = nullptr;
    void *callback_context = nullptr;

    Handle stop_event;
    Handle fence_event;
    std::thread thread;
    std::mutex publish_mutex;

    // Owned by the thread.
    std::shared_ptr<Ring> ring;
    winrt::com_ptr<ID3D11Fence> fence;
    Handle producer_process;
    uint32_t stuck_state = LW_FS_ATTACH_FREE;
    ULONGLONG stuck_since = 0;

    mutable std::mutex stats_mutex;
    lw_frame_source_stats stats{};

    lw_fs_shared *shared() const { return channel->shared(); }

    template <typename F>
    void update_stats(F &&change) {
        std::lock_guard<std::mutex> lock(stats_mutex);
        change(stats);
    }

    void run();
    void service_handshake();
    void answer_request();
    uint32_t build_ring(std::shared_ptr<Ring> &out_ring, Handle &out_process);
    void deliver();
    bool wait_for_fence(uint64_t value);
    enum class DropReason { detached, producer_exited, stopping };
    void drop_ring(DropReason reason);
};

// ---- The source thread ---------------------------------------------------------

void lw_frame_source::run() {
    HANDLE mmcss = lw::join_mmcss(L"Capture");
    for (;;) {
        HANDLE waits[3] = {stop_event.value, channel->host_event.value, producer_process.value};
        const DWORD count = producer_process ? 3 : 2;
        // The timeout only drives the stuck-handshake check; everything else is an event.
        const DWORD result = WaitForMultipleObjects(count, waits, FALSE, 250);
        if (result == WAIT_OBJECT_0) break;
        if (result == WAIT_OBJECT_0 + 2) drop_ring(DropReason::producer_exited);
        service_handshake();
        deliver();
    }
    lw::leave_mmcss(mmcss);
}

void lw_frame_source::service_handshake() {
    lw_fs_shared *s = shared();
    if (ring && !lw_fs_is_attached(s, ring->generation)) drop_ring(DropReason::detached);
    const uint32_t state = lw_fs_attach_state(s);
    if (state == LW_FS_ATTACH_REQUESTED) {
        answer_request();
        stuck_state = LW_FS_ATTACH_FREE;
        return;
    }
    // A producer that dies between winning the channel and committing its
    // request, or before reading a refusal, would leave the channel closed
    // to every later producer. Neither state lasts more than milliseconds
    // when its producer is alive.
    if (state == LW_FS_ATTACH_WRITING || state == LW_FS_ATTACH_REFUSED) {
        const ULONGLONG now = GetTickCount64();
        if (stuck_state != state) {
            stuck_state = state;
            stuck_since = now;
        } else if (now - stuck_since > kStuckHandshakeMs) {
            lw_fs_host_reclaim(s, state);
            stuck_state = LW_FS_ATTACH_FREE;
        }
    } else {
        stuck_state = LW_FS_ATTACH_FREE;
    }
}

void lw_frame_source::answer_request() {
    lw_fs_shared *s = shared();
    if (!lw_fs_host_begin_attach(s)) return; // the producer gave up first
    if (ring) drop_ring(DropReason::detached);
    std::shared_ptr<Ring> built;
    Handle process;
    const uint32_t reason = build_ring(built, process);
    if (reason != LW_FS_REFUSE_NONE) {
        lw_fs_host_refuse(s, reason);
        update_stats([&](lw_frame_source_stats &st) {
            ++st.refusals;
            st.last_refusal = reason;
        });
    } else {
        ring = std::move(built);
        producer_process = std::move(process);
        lw_fs_host_finish_attach(s, ring->generation);
        update_stats([&](lw_frame_source_stats &st) {
            ++st.attaches;
            st.attached = 1;
            st.generation = ring->generation;
            st.format = ring->format;
            st.producer_pid = s->producer_pid;
        });
    }
    SetEvent(channel->producer_event.value);
}

uint32_t lw_frame_source::build_ring(std::shared_ptr<Ring> &out_ring, Handle &out_process) {
    lw_fs_shared *s = shared(); // BUILDING: the request fields are stable and ours to answer
    s->host_luid = luid;
    if (s->producer_version != LW_FS_VERSION) return LW_FS_REFUSE_VERSION;
    const lw_fs_format format = s->format;
    if (lw_fs_validate_format(&format) != LW_FS_REFUSE_NONE) return LW_FS_REFUSE_FORMAT;
    if (s->producer_luid != luid) return LW_FS_REFUSE_ADAPTER;

    // The pid alone could name a different process by now: pin it to the
    // creation time the producer recorded.
    Handle process(OpenProcess(PROCESS_DUP_HANDLE | SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               s->producer_pid));
    if (!process || lw::fs::process_start_time(process.value) != s->producer_start_time) return LW_FS_REFUSE_PROCESS;

    RemoteHandles remote{process.value};
    auto give = [&](HANDLE local, DWORD access, DWORD options, uint64_t &field) -> bool {
        HANDLE target = nullptr;
        if (!DuplicateHandle(GetCurrentProcess(), local, process.value, &target, access, FALSE, options)) return false;
        remote.values.push_back(target);
        field = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(target));
        return true;
    };

    std::memset(s->texture_handles, 0, sizeof s->texture_handles);
    s->fence_handle = s->host_process_handle = 0;

    auto built = std::make_shared<Ring>();
    built->channel = channel;
    built->generation = s->generation + 1; // the section outlives hosts, so generations never repeat in it
    built->format = format;

    winrt::com_ptr<ID3D11Fence> new_fence;
    if (FAILED(device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_PPV_ARGS(new_fence.put()))))
        return LW_FS_REFUSE_RESOURCES;
    {
        HANDLE shared_handle = nullptr;
        if (FAILED(new_fence->CreateSharedHandle(nullptr, GENERIC_ALL, nullptr, &shared_handle)))
            return LW_FS_REFUSE_RESOURCES;
        Handle local(shared_handle);
        if (!give(local.value, 0, DUPLICATE_SAME_ACCESS, s->fence_handle)) return LW_FS_REFUSE_PROCESS;
    }

    struct Plan {
        uint32_t index, format, width, height;
    };
    std::vector<Plan> plan{{LW_FS_TEXTURE_IMAGE, format.image_format, format.image_width, format.image_height}};
    if (format.layout == LW_FS_LAYOUT_STEREO_SEPARATE)
        plan.push_back({LW_FS_TEXTURE_IMAGE_RIGHT, format.image_format, format.image_width, format.image_height});
    if (format.aux_role != LW_FS_AUX_NONE)
        plan.push_back({LW_FS_TEXTURE_AUX, format.aux_format, format.aux_width, format.aux_height});

    for (uint32_t slot = 0; slot < format.slot_count; ++slot) {
        for (const Plan &p : plan) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = p.width;
            desc.Height = p.height;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = static_cast<DXGI_FORMAT>(p.format);
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            // Render target: the producer draws or copies into it. Shader
            // resource: the host may sample it (warp, depth conversion).
            desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
            winrt::com_ptr<ID3D11Texture2D> texture;
            if (FAILED(device->CreateTexture2D(&desc, nullptr, texture.put()))) return LW_FS_REFUSE_RESOURCES;
            HANDLE shared_handle = nullptr;
            if (FAILED(texture.as<IDXGIResource1>()->CreateSharedHandle(
                    nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, nullptr, &shared_handle)))
                return LW_FS_REFUSE_RESOURCES;
            Handle local(shared_handle);
            if (!give(local.value, 0, DUPLICATE_SAME_ACCESS, s->texture_handles[slot][p.index])) return LW_FS_REFUSE_PROCESS;
            built->textures[slot][p.index] = texture;
        }
    }
    // Last: the producer's way to notice this host dying.
    if (!give(GetCurrentProcess(), SYNCHRONIZE, 0, s->host_process_handle)) return LW_FS_REFUSE_PROCESS;

    remote.keep = true;
    fence = new_fence;
    out_ring = std::move(built);
    out_process = std::move(process);
    return LW_FS_REFUSE_NONE;
}

bool lw_frame_source::wait_for_fence(uint64_t value) {
    const ULONGLONG deadline = GetTickCount64() + kFenceTimeoutMs;
    for (;;) {
        const uint64_t completed = fence->GetCompletedValue();
        if (completed == UINT64_MAX) return false; // device removed
        if (completed >= value) return true;
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) return false;
        // The event is auto-reset and shared by every wait, so a stale
        // signal from an earlier wait can wake this one early: recheck.
        if (FAILED(fence->SetEventOnCompletion(value, fence_event.value))) return false;
        WaitForSingleObject(fence_event.value, static_cast<DWORD>(deadline - now));
    }
}

void lw_frame_source::deliver() {
    if (!ring) return;
    lw_fs_shared *s = shared();
    uint32_t slot = 0;
    while (lw_fs_host_take_newest(s, ring->generation, &slot)) {
        const int64_t taken = lw::qpc_now();
        const lw_fs_slot &meta = s->slots[slot]; // stable while CONSUMING
        if (!wait_for_fence(meta.fence_value)) {
            lw_fs_host_release(s, ring->generation, slot);
            update_stats([](lw_frame_source_stats &st) { ++st.fence_timeouts; });
            return; // the producer's process handle or next request decides what happens next
        }
        auto *frame = new SourceFrame();
        frame->ring = ring;
        auto &info = frame->source;
        info.generation = ring->generation;
        info.frame_number = meta.frame_number;
        info.slot = slot;
        info.side_data_size = meta.side_data_size;
        info.side_data = meta.side_data;
        info.format = ring->format;
        for (uint32_t t = 0; t < LW_FS_MAX_TEXTURES; ++t) info.textures[t] = ring->textures[slot][t].get();
        info.present_qpc = meta.present_qpc;
        info.taken_qpc = taken;
        info.ready_qpc = lw::qpc_now();
        frame->info.texture = info.textures[LW_FS_TEXTURE_IMAGE];
        frame->info.width = static_cast<int32_t>(ring->format.image_width);
        frame->info.height = static_cast<int32_t>(ring->format.image_height);
        frame->info.sequence = info.frame_number;
        frame->info.present_qpc = info.present_qpc;
        frame->info.arrival_qpc = info.taken_qpc;
        frame->info.ready_qpc = info.ready_qpc;
        update_stats([](lw_frame_source_stats &st) { ++st.delivered; });
        callback(callback_context, frame);
    }
}

void lw_frame_source::drop_ring(DropReason reason) {
    if (!ring) return;
    // A no-op when the producer detached itself; otherwise this is what tells
    // a still-running producer that its attach is over.
    lw_fs_detach(shared(), ring->generation);
    ring.reset(); // frames still held keep their textures alive
    fence = nullptr;
    producer_process.reset();
    update_stats([&](lw_frame_source_stats &st) {
        st.attached = 0;
        st.producer_pid = 0;
        if (reason == DropReason::detached) ++st.detaches;
        if (reason == DropReason::producer_exited) ++st.producer_exits;
    });
    SetEvent(channel->producer_event.value);
}

// ---- C ABI ------------------------------------------------------------------------

extern "C" lw_status lw_frame_source_start(lw_device *device, const lw_frame_source_params *params,
                                           lw_frame_callback callback, void *context, lw_frame_source **out) {
    if (!device || !params || !callback || !out) return lw::fail(LW_E_INVALID_ARG, "lw_frame_source_start: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_frame_source_start", [&]() -> lw_status {
        lw::fs::Names names;
        if (!lw::fs::names_for(params->channel, names)) return LW_E_INVALID_ARG;
        auto source = std::make_unique<lw_frame_source>();
        lw_status status = lw::fs::make_security(params->producer_sid, source->security);
        if (status != LW_OK) return status;
        source->device = device->device;
        if (FAILED(device->device->QueryInterface(IID_PPV_ARGS(source->device5.put()))))
            return lw::fail(LW_E_UNSUPPORTED, "frame source: the device has no ID3D11Device5 (needs Windows 10 1703+)");
        DXGI_ADAPTER_DESC1 adapter{};
        device->adapter->GetDesc1(&adapter);
        source->luid = lw::fs::luid_value(adapter.AdapterLuid);
        source->callback = callback;
        source->callback_context = context;

        auto channel = std::make_shared<Channel>();
        SECURITY_ATTRIBUTES *sa = &source->security.attributes;
        channel->section.mapping.reset(CreateFileMappingW(INVALID_HANDLE_VALUE, sa, PAGE_READWRITE, 0,
                                                          sizeof(lw_fs_shared), names.section.c_str()));
        const DWORD created = GetLastError();
        if (!channel->section.mapping) return lw::fail_hr(HRESULT_FROM_WIN32(created), "frame source: creating the section");
        const bool existed = created == ERROR_ALREADY_EXISTS;
        // An existing section is one a producer kept open across a host
        // restart - or one someone else made to intercept frames.
        if (existed && !lw::fs::owned_by(channel->section.mapping.value, source->security.user_sid))
            return lw::fail(LW_E_BUSY, "frame source: channel '%s' is held by another account", params->channel);
        channel->section.shared = static_cast<lw_fs_shared *>(MapViewOfFile(
            channel->section.mapping.value, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, sizeof(lw_fs_shared)));
        if (!channel->section.shared) return lw::fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: mapping the section");
        lw_fs_shared *s = channel->shared();
        if (existed) {
            if (lw_fs_check_identity(s) != LW_FS_REFUSE_NONE)
                return lw::fail(LW_E_BUSY, "frame source: channel '%s' is held by a build speaking version %u",
                                params->channel, s->version);
            // Listening and alive (this process included: a stopped source
            // leaves the channel not listening) means another host owns it.
            if (lw_fs_host_listening(s)) {
                bool alive = s->host_pid == GetCurrentProcessId();
                if (!alive) {
                    Handle other(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, s->host_pid));
                    alive = other && WaitForSingleObject(other.value, 0) == WAIT_TIMEOUT &&
                            lw::fs::process_start_time(other.value) == s->host_start_time;
                }
                if (alive)
                    return lw::fail(LW_E_BUSY, "frame source: another host (pid %u) is listening on '%s'", s->host_pid,
                                    params->channel);
            }
        } else {
            lw_fs_init(s);
        }
        channel->host_event.reset(CreateEventW(sa, FALSE, FALSE, names.host_event.c_str()));
        channel->producer_event.reset(CreateEventW(sa, FALSE, FALSE, names.producer_event.c_str()));
        source->stop_event.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        source->fence_event.reset(CreateEventW(nullptr, FALSE, FALSE, nullptr));
        if (!channel->host_event || !channel->producer_event || !source->stop_event || !source->fence_event)
            return lw::fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: creating events");

        s->host_start_time = lw::fs::process_start_time(GetCurrentProcess());
        lw_fs_host_open(s, GetCurrentProcessId());
        source->channel = channel;
        auto *raw = source.get();
        source->thread = std::thread([raw] { raw->run(); });
        *out = source.release();
        return LW_OK;
    });
}

extern "C" void lw_frame_source_publish(lw_frame_source *source, const lw_fs_host_state *state) {
    if (!source || !state) return;
    std::lock_guard<std::mutex> lock(source->publish_mutex);
    lw_fs_host_write_state(source->shared(), state);
    // A producer pacing itself on next_frame_start_qpc reads on its own
    // schedule; no event is needed.
}

extern "C" void lw_frame_source_get_stats(const lw_frame_source *source, lw_frame_source_stats *out) {
    if (!source || !out) return;
    {
        std::lock_guard<std::mutex> lock(source->stats_mutex);
        *out = source->stats;
    }
    const lw_fs_shared *s = source->shared();
    out->submitted = lw::fs::counter(s->submitted);
    out->superseded = lw::fs::counter(s->superseded);
    out->starved = lw::fs::counter(s->starved);
    out->consumed = lw::fs::counter(s->consumed);
    out->dropped = lw::fs::counter(s->dropped);
}

extern "C" void lw_frame_source_stop(lw_frame_source *source) {
    if (!source) return;
    SetEvent(source->stop_event.value);
    if (source->thread.joinable()) source->thread.join();
    source->drop_ring(lw_frame_source::DropReason::stopping);
    lw_fs_host_close(source->shared());
    SetEvent(source->channel->producer_event.value);
    delete source;
}

extern "C" const lw_frame_source_info *lw_frame_get_source_info(const lw_frame *frame) {
    return frame ? frame->source_info() : nullptr;
}
