// Desktop/window capture into a ring of shim-owned D3D11 textures.
//
// Two backends feed one delivery path:
//  - Windows.Graphics.Capture (WGC): monitors or single windows, cursor
//    composited by the OS. Frames arrive on a thread-pool thread
//    (free-threaded frame pool).
//  - DXGI Desktop Duplication (DDA): monitors only, no cursor composition, on a
//    dedicated MMCSS "Capture" thread.
// The OS's texture belongs to the OS and must be returned quickly, so every
// frame is GPU-copied into a ring slot that the consumer owns until
// lw_frame_release. No pixels touch the CPU.
#include "common.hpp"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

namespace wgc = winrt::Windows::Graphics::Capture;
namespace wgd = winrt::Windows::Graphics::DirectX;
namespace wgd3d = winrt::Windows::Graphics::DirectX::Direct3D11;

namespace {

struct Slot {
    winrt::com_ptr<ID3D11Texture2D> texture;
    int32_t width = 0, height = 0;
    std::atomic<bool> busy{false};
};

// State shared by the backend and every outstanding frame.
struct CaptureCore {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    lw_frame_callback callback = nullptr;
    void *callback_context = nullptr;

    std::vector<std::shared_ptr<Slot>> slots;

    std::mutex delivery_mutex; // held for a whole delivery; stop() takes it to fence callbacks
    bool stopped = false;
    uint64_t sequence = 0;

    std::atomic<uint64_t> os_frames{0}, delivered{0}, dropped{0}, errors{0};
    std::atomic<lw_status> last_error{LW_OK};

    void deliver(ID3D11Texture2D *source, int32_t width, int32_t height, int64_t present_qpc,
                 int64_t arrival_qpc);
    void stop() {
        std::lock_guard<std::mutex> lock(delivery_mutex);
        stopped = true;
    }
};

} // namespace

struct lw_frame {
    std::shared_ptr<Slot> slot;
    lw_frame_info info{};
};

void CaptureCore::deliver(ID3D11Texture2D *source, int32_t width, int32_t height,
                          int64_t present_qpc, int64_t arrival_qpc) {
    std::lock_guard<std::mutex> lock(delivery_mutex);
    if (stopped) return;

    std::shared_ptr<Slot> slot;
    for (auto &candidate : slots) {
        bool expected = false;
        if (candidate->busy.compare_exchange_strong(expected, true)) {
            slot = candidate;
            break;
        }
    }
    if (!slot) {
        dropped.fetch_add(1, std::memory_order_relaxed);
        return;
    }

    // Slots match the content size exactly, so the encoder sees a texture of
    // the size it was configured for. Resizes reallocate lazily, one free slot
    // at a time; textures still held by older frames stay alive through them.
    if (!slot->texture || slot->width != width || slot->height != height) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = static_cast<UINT>(width);
        desc.Height = static_cast<UINT>(height);
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        winrt::com_ptr<ID3D11Texture2D> texture;
        HRESULT hr = device->CreateTexture2D(&desc, nullptr, texture.put());
        if (FAILED(hr)) {
            slot->busy.store(false);
            errors.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        slot->texture = texture;
        slot->width = width;
        slot->height = height;
    }

    D3D11_BOX box{0, 0, 0, static_cast<UINT>(width), static_cast<UINT>(height), 1};
    context->CopySubresourceRegion(slot->texture.get(), 0, 0, 0, 0, source, 0, &box);

    auto *frame = new lw_frame();
    frame->slot = slot;
    frame->info.texture = slot->texture.get();
    frame->info.width = width;
    frame->info.height = height;
    frame->info.sequence = ++sequence;
    frame->info.present_qpc = present_qpc;
    frame->info.arrival_qpc = arrival_qpc;
    frame->info.ready_qpc = lw::qpc_now();
    delivered.fetch_add(1, std::memory_order_relaxed);
    callback(callback_context, frame);
}

// ---- Backends -------------------------------------------------------------------

namespace {

struct Backend {
    virtual ~Backend() = default;
    virtual void stop() = 0;
};

// What a WGC FrameArrived handler touches. Handlers hold it by shared_ptr:
// revoking the handler does not wait for one already running, so the backend
// object itself may be gone by the time a late handler finishes.
struct WgcState {
    std::shared_ptr<CaptureCore> core;
    wgd3d::IDirect3DDevice rt_device{nullptr};
    winrt::Windows::Graphics::SizeInt32 pool_size{};

    void on_frame(const wgc::Direct3D11CaptureFramePool &sender) {
        const int64_t arrival = lw::qpc_now();
        try {
            auto frame = sender.TryGetNextFrame();
            if (!frame) return;
            core->os_frames.fetch_add(1, std::memory_order_relaxed);
            auto size = frame.ContentSize();
            auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            winrt::com_ptr<ID3D11Texture2D> texture;
            winrt::check_hresult(access->GetInterface(IID_PPV_ARGS(texture.put())));
            D3D11_TEXTURE2D_DESC desc{};
            texture->GetDesc(&desc);
            const int32_t width = std::min<int32_t>(size.Width, static_cast<int32_t>(desc.Width)) & ~1;
            const int32_t height = std::min<int32_t>(size.Height, static_cast<int32_t>(desc.Height)) & ~1;
            // SystemRelativeTime is QPC time in 100 ns units.
            const int64_t present = lw::qpc_from_hundred_ns(frame.SystemRelativeTime().count());
            if (width > 0 && height > 0) core->deliver(texture.get(), width, height, present, arrival);
            frame.Close();

            // A resized source (window, or display mode change) needs a pool of the new size.
            if (size.Width != pool_size.Width || size.Height != pool_size.Height) {
                pool_size = size;
                sender.Recreate(rt_device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
            }
        } catch (const winrt::hresult_error &e) {
            core->errors.fetch_add(1, std::memory_order_relaxed);
            if (e.code() == DXGI_ERROR_DEVICE_REMOVED) core->last_error.store(LW_E_ACCESS_LOST);
        }
    }
};

struct WgcBackend final : Backend {
    std::shared_ptr<WgcState> state = std::make_shared<WgcState>();
    wgc::GraphicsCaptureItem item{nullptr};
    wgc::Direct3D11CaptureFramePool pool{nullptr};
    wgc::GraphicsCaptureSession session{nullptr};
    winrt::event_token frame_token{};

    void start(HMONITOR monitor, HWND window, bool cursor) {
        auto dxgi_device = state->core->device.as<IDXGIDevice>();
        winrt::com_ptr<::IInspectable> inspectable;
        winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put()));
        state->rt_device = inspectable.as<wgd3d::IDirect3DDevice>();

        auto interop = winrt::get_activation_factory<wgc::GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        if (monitor) {
            winrt::check_hresult(interop->CreateForMonitor(
                monitor, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(item)));
        } else {
            winrt::check_hresult(interop->CreateForWindow(
                window, winrt::guid_of<wgc::GraphicsCaptureItem>(), winrt::put_abi(item)));
        }

        state->pool_size = item.Size();
        // Two buffers: the OS composes into one while we copy out of the other.
        pool = wgc::Direct3D11CaptureFramePool::CreateFreeThreaded(
            state->rt_device, wgd::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, state->pool_size);
        frame_token = pool.FrameArrived(
            [state = state](const wgc::Direct3D11CaptureFramePool &sender,
                            const winrt::Windows::Foundation::IInspectable &) { state->on_frame(sender); });
        session = pool.CreateCaptureSession(item);
        session.IsCursorCaptureEnabled(cursor);
        try {
            // Windows 11 only; Windows 10 always draws the yellow border.
            session.IsBorderRequired(false);
        } catch (...) {
        }
        session.StartCapture();
    }

    void stop() override {
        if (pool) pool.FrameArrived(frame_token);
        if (session) session.Close();
        if (pool) pool.Close();
        session = nullptr;
        pool = nullptr;
        item = nullptr;
    }
};

struct DdaBackend final : Backend {
    std::shared_ptr<CaptureCore> core;
    winrt::com_ptr<IDXGIOutput1> output;
    std::thread thread;
    std::atomic<bool> quit{false};

    void start(HMONITOR monitor) {
        winrt::com_ptr<IDXGIAdapter1> adapter;
        winrt::com_ptr<IDXGIOutput> plain;
        if (!lw::find_monitor_output(monitor, adapter, plain))
            throw winrt::hresult_error(E_INVALIDARG, L"no DXGI output drives that monitor");
        output = plain.as<IDXGIOutput1>();
        // Fail fast if duplication is refused outright (e.g. no desktop in
        // this session); the thread handles later losses.
        winrt::com_ptr<IDXGIOutputDuplication> probe;
        winrt::check_hresult(output->DuplicateOutput(core->device.get(), probe.put()));
        thread = std::thread([this, first = probe] () mutable { run(std::move(first)); });
    }

    void run(winrt::com_ptr<IDXGIOutputDuplication> duplication) {
        HANDLE mmcss = lw::join_mmcss(L"Capture");
        while (!quit.load(std::memory_order_relaxed)) {
            if (!duplication) {
                // Lost to a mode change, the secure desktop (UAC, lock screen)
                // or a full-screen exclusive app. Re-acquire.
                HRESULT hr = output->DuplicateOutput(core->device.get(), duplication.put());
                if (FAILED(hr)) {
                    core->errors.fetch_add(1, std::memory_order_relaxed);
                    Sleep(100);
                    continue;
                }
            }
            DXGI_OUTDUPL_FRAME_INFO info{};
            winrt::com_ptr<IDXGIResource> resource;
            // Poll with a zero timeout. A blocking AcquireNextFrame holds the
            // device's lock while it waits, which stalls the encoder (same
            // device) until the next desktop update: measured 2026-10-04 as
            // 18.8 fps and 25-50 ms encodes with a 100 ms timeout.
            HRESULT hr = duplication->AcquireNextFrame(0, &info, resource.put());
            if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
                lw::precise_sleep(500);
                continue;
            }
            if (FAILED(hr)) {
                core->errors.fetch_add(1, std::memory_order_relaxed);
                if (hr == DXGI_ERROR_ACCESS_LOST) core->last_error.store(LW_E_ACCESS_LOST);
                duplication = nullptr;
                continue;
            }
            const int64_t arrival = lw::qpc_now();
            // LastPresentTime == 0: only the pointer moved; nothing to encode.
            if (info.LastPresentTime.QuadPart != 0) {
                core->os_frames.fetch_add(1, std::memory_order_relaxed);
                auto texture = resource.as<ID3D11Texture2D>();
                D3D11_TEXTURE2D_DESC desc{};
                texture->GetDesc(&desc);
                core->deliver(texture.get(), static_cast<int32_t>(desc.Width) & ~1,
                              static_cast<int32_t>(desc.Height) & ~1, info.LastPresentTime.QuadPart, arrival);
            }
            duplication->ReleaseFrame();
        }
        lw::leave_mmcss(mmcss);
    }

    void stop() override {
        quit.store(true);
        if (thread.joinable()) thread.join();
    }
};

// SPIKE ONLY: see lw_capture_start_synthetic.
struct SyntheticBackend final : Backend {
    std::shared_ptr<CaptureCore> core;
    winrt::com_ptr<ID3D11Texture2D> noise;
    int32_t width = 0, height = 0;
    uint32_t fps = 60, motion = 0;
    std::thread thread;
    std::atomic<bool> quit{false};

    void start() {
        // Double-size noise, so any width x height window of it is fresh content.
        const UINT nw = static_cast<UINT>(width) * 2, nh = static_cast<UINT>(height) * 2;
        std::vector<uint32_t> pixels(static_cast<size_t>(nw) * nh);
        uint64_t state = 0x9E3779B97F4A7C15ull;
        for (auto &p : pixels) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17;
            p = static_cast<uint32_t>(state) | 0xFF000000u;
        }
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = nw;
        desc.Height = nh;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_IMMUTABLE;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA data{pixels.data(), nw * 4, 0};
        winrt::check_hresult(core->device->CreateTexture2D(&desc, &data, noise.put()));
        thread = std::thread([this] { run(); });
    }

    void run() {
        HANDLE mmcss = lw::join_mmcss(L"Capture");
        const int64_t frequency = lw::qpc_frequency();
        const int64_t interval = frequency / fps;
        int64_t next = lw::qpc_now();
        uint64_t state = 0x2545F4914F6CDD1Dull;
        int64_t frame = 0;
        while (!quit.load(std::memory_order_relaxed)) {
            next += interval;
            const int64_t now = lw::qpc_now();
            if (next > now) lw::precise_sleep((next - now) * 1'000'000 / frequency);
            UINT x, y;
            if (motion == 0) {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17;
                x = static_cast<UINT>(state % static_cast<uint64_t>(width));
                y = static_cast<UINT>((state >> 32) % static_cast<uint64_t>(height));
            } else {
                x = static_cast<UINT>((frame * 8) % width);
                y = static_cast<UINT>((frame * 4) % height);
            }
            ++frame;
            core->os_frames.fetch_add(1, std::memory_order_relaxed);
            const int64_t t = lw::qpc_now();
            deliver_window(x, y, t);
        }
        lw::leave_mmcss(mmcss);
    }

    void deliver_window(UINT x, UINT y, int64_t t) {
        std::lock_guard<std::mutex> lock(core->delivery_mutex);
        if (core->stopped) return;
        std::shared_ptr<Slot> slot;
        for (auto &candidate : core->slots) {
            bool expected = false;
            if (candidate->busy.compare_exchange_strong(expected, true)) {
                slot = candidate;
                break;
            }
        }
        if (!slot) {
            core->dropped.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        if (!slot->texture) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = static_cast<UINT>(width);
            desc.Height = static_cast<UINT>(height);
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            if (FAILED(core->device->CreateTexture2D(&desc, nullptr, slot->texture.put()))) {
                slot->busy.store(false);
                core->errors.fetch_add(1);
                return;
            }
            slot->width = width;
            slot->height = height;
        }
        D3D11_BOX box{x, y, 0, x + static_cast<UINT>(width), y + static_cast<UINT>(height), 1};
        core->context->CopySubresourceRegion(slot->texture.get(), 0, 0, 0, 0, noise.get(), 0, &box);
        auto *frame = new lw_frame();
        frame->slot = slot;
        frame->info.texture = slot->texture.get();
        frame->info.width = width;
        frame->info.height = height;
        frame->info.sequence = ++core->sequence;
        frame->info.present_qpc = t;
        frame->info.arrival_qpc = t;
        frame->info.ready_qpc = lw::qpc_now();
        core->delivered.fetch_add(1, std::memory_order_relaxed);
        core->callback(core->callback_context, frame);
    }

    void stop() override {
        quit.store(true);
        if (thread.joinable()) thread.join();
    }
};

} // namespace

struct lw_capture {
    std::shared_ptr<CaptureCore> core;
    std::unique_ptr<Backend> backend;
};

extern "C" lw_status lw_capture_start(lw_device *device, const lw_capture_params *params,
                                      lw_frame_callback callback, void *context, lw_capture **out) {
    if (!device || !params || !callback || !out)
        return lw::fail(LW_E_INVALID_ARG, "lw_capture_start: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_capture_start", [&]() -> lw_status {
        auto core = std::make_shared<CaptureCore>();
        core->device = device->device;
        core->context = device->context;
        core->callback = callback;
        core->callback_context = context;
        const int ring = params->ring_size > 0 ? params->ring_size : 4;
        for (int i = 0; i < ring; ++i) core->slots.push_back(std::make_shared<Slot>());

        auto capture = std::make_unique<lw_capture>();
        capture->core = core;
        switch (params->backend) {
        case LW_CAPTURE_WGC: {
            if (!wgc::GraphicsCaptureSession::IsSupported())
                return lw::fail(LW_E_UNSUPPORTED, "Windows.Graphics.Capture is not supported here");
            if (!params->monitor && !params->window)
                return lw::fail(LW_E_INVALID_ARG, "WGC needs a monitor or a window");
            auto backend = std::make_unique<WgcBackend>();
            backend->state->core = core;
            backend->start(static_cast<HMONITOR>(params->monitor), static_cast<HWND>(params->window),
                           params->cursor != 0);
            capture->backend = std::move(backend);
            break;
        }
        case LW_CAPTURE_DDA: {
            if (!params->monitor) return lw::fail(LW_E_INVALID_ARG, "DXGI duplication needs a monitor");
            auto backend = std::make_unique<DdaBackend>();
            backend->core = core;
            backend->start(static_cast<HMONITOR>(params->monitor));
            capture->backend = std::move(backend);
            break;
        }
        default:
            return lw::fail(LW_E_INVALID_ARG, "unknown capture backend %u", params->backend);
        }
        *out = capture.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_capture_start_synthetic(lw_device *device, int32_t width, int32_t height, uint32_t fps,
                                                uint32_t motion, lw_frame_callback callback, void *context,
                                                lw_capture **out) {
    if (!device || !callback || !out || width <= 0 || height <= 0 || fps == 0)
        return lw::fail(LW_E_INVALID_ARG, "lw_capture_start_synthetic: bad argument");
    *out = nullptr;
    return lw::guarded("lw_capture_start_synthetic", [&]() -> lw_status {
        auto core = std::make_shared<CaptureCore>();
        core->device = device->device;
        core->context = device->context;
        core->callback = callback;
        core->callback_context = context;
        for (int i = 0; i < 4; ++i) core->slots.push_back(std::make_shared<Slot>());
        auto backend = std::make_unique<SyntheticBackend>();
        backend->core = core;
        backend->width = width & ~1;
        backend->height = height & ~1;
        backend->fps = fps;
        backend->motion = motion;
        backend->start();
        auto capture = std::make_unique<lw_capture>();
        capture->core = core;
        capture->backend = std::move(backend);
        *out = capture.release();
        return LW_OK;
    });
}

extern "C" void lw_capture_get_stats(const lw_capture *capture, lw_capture_stats *out) {
    if (!capture || !out) return;
    const auto &core = *capture->core;
    out->os_frames = core.os_frames.load();
    out->delivered = core.delivered.load();
    out->dropped_ring_full = core.dropped.load();
    out->errors = core.errors.load();
    out->last_error = core.last_error.load();
}

extern "C" void lw_capture_stop(lw_capture *capture) {
    if (!capture) return;
    try {
        capture->backend->stop();
    } catch (...) {
    }
    capture->core->stop(); // waits out a delivery in progress
    delete capture;
}

extern "C" const lw_frame_info *lw_frame_get_info(const lw_frame *frame) {
    return frame ? &frame->info : nullptr;
}

extern "C" void lw_frame_release(lw_frame *frame) {
    if (!frame) return;
    frame->slot->busy.store(false, std::memory_order_release);
    delete frame;
}
