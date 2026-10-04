// SPIKE ONLY: a stand-in for a game's GPU load (see lw_spike_gpu_load_start).
#include "common.hpp"

#include <atomic>
#include <thread>

struct lw_gpu_load {
    std::thread thread;
    std::atomic<bool> quit{false};
};

extern "C" lw_status lw_spike_gpu_load_start(int32_t percent, lw_gpu_load **out) {
    if (!out || percent <= 0 || percent > 100) return lw::fail(LW_E_INVALID_ARG, "percent must be 1..100");
    *out = nullptr;
    return lw::guarded("lw_spike_gpu_load_start", [&]() -> lw_status {
        winrt::com_ptr<ID3D11Device> device;
        winrt::com_ptr<ID3D11DeviceContext> context;
        const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
        winrt::check_hresult(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1,
                                               D3D11_SDK_VERSION, device.put(), nullptr, context.put()));
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = 8192;
        desc.Height = 4096;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_R32G32B32A32_FLOAT; // 512 MB per copy pass
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        winrt::com_ptr<ID3D11Texture2D> a, b;
        winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, a.put()));
        winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, b.put()));
        D3D11_QUERY_DESC query_desc{D3D11_QUERY_EVENT, 0};
        winrt::com_ptr<ID3D11Query> query;
        winrt::check_hresult(device->CreateQuery(&query_desc, query.put()));

        auto load = std::make_unique<lw_gpu_load>();
        auto *raw = load.get();
        load->thread = std::thread([=]() {
            const int64_t f = lw::qpc_frequency();
            const int64_t period = f / 100; // 10 ms
            const int64_t busy = period * percent / 100;
            while (!raw->quit.load()) {
                const int64_t start = lw::qpc_now();
                while (lw::qpc_now() - start < busy && !raw->quit.load()) {
                    context->CopyResource(b.get(), a.get());
                    context->End(query.get());
                    context->Flush();
                    while (context->GetData(query.get(), nullptr, 0, 0) == S_FALSE) lw::precise_sleep(200);
                }
                const int64_t left = period - (lw::qpc_now() - start);
                if (left > 0) lw::precise_sleep(left * 1'000'000 / f);
            }
        });
        *out = load.release();
        return LW_OK;
    });
}

extern "C" void lw_spike_gpu_load_stop(lw_gpu_load *load) {
    if (!load) return;
    load->quit.store(true);
    if (load->thread.joinable()) load->thread.join();
    delete load;
}
