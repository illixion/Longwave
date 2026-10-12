// SPIKE ONLY: the test pattern frame-source-spike draws (lw_spike_pattern_*).
// Shader-free: a copy out of a noise texture plus ClearView rectangles, so it
// runs on any D3D11.1 device without a shader compiler.
#include "common.hpp"

#include <algorithm>
#include <unordered_map>
#include <vector>

namespace {
constexpr UINT kBlock = 16; // frame-number block size, pixels
constexpr UINT kBits = 32;
} // namespace

struct lw_spike_pattern {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext1> context;
    winrt::com_ptr<ID3D11Texture2D> noise;
    winrt::com_ptr<ID3D11Texture2D> strip;   // staging, BGRA, kBits * kBlock x kBlock
    winrt::com_ptr<ID3D11Texture2D> aux_pixel; // staging, R32_FLOAT, 1x1
    std::unordered_map<ID3D11Resource *, winrt::com_ptr<ID3D11RenderTargetView>> views;
    UINT width = 0, height = 0;

    ID3D11RenderTargetView *view(ID3D11Resource *resource) {
        auto found = views.find(resource);
        if (found != views.end()) return found->second.get();
        if (views.size() > 64) views.clear(); // a re-attach brings new textures
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(device->CreateRenderTargetView(resource, nullptr, rtv.put()));
        views[resource] = rtv;
        return rtv.get();
    }
};

extern "C" lw_status lw_spike_pattern_create(void *d3d11_device, int32_t width, int32_t height, lw_spike_pattern **out) {
    if (!d3d11_device || !out || width < static_cast<int32_t>(kBits * kBlock) || height < static_cast<int32_t>(kBlock))
        return lw::fail(LW_E_INVALID_ARG, "lw_spike_pattern_create: bad argument");
    *out = nullptr;
    return lw::guarded("lw_spike_pattern_create", [&]() -> lw_status {
        auto pattern = std::make_unique<lw_spike_pattern>();
        pattern->device.copy_from(static_cast<ID3D11Device *>(d3d11_device));
        winrt::com_ptr<ID3D11DeviceContext> context;
        pattern->device->GetImmediateContext(context.put());
        pattern->context = context.as<ID3D11DeviceContext1>();
        pattern->width = static_cast<UINT>(width);
        pattern->height = static_cast<UINT>(height);

        const UINT nw = pattern->width * 2, nh = pattern->height * 2;
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
        winrt::check_hresult(pattern->device->CreateTexture2D(&desc, &data, pattern->noise.put()));

        desc.Width = kBits * kBlock;
        desc.Height = kBlock;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        winrt::check_hresult(pattern->device->CreateTexture2D(&desc, nullptr, pattern->strip.put()));
        desc.Width = desc.Height = 1;
        desc.Format = DXGI_FORMAT_R32_FLOAT;
        winrt::check_hresult(pattern->device->CreateTexture2D(&desc, nullptr, pattern->aux_pixel.put()));
        *out = pattern.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_spike_pattern_draw(lw_spike_pattern *pattern, void *texture, void *aux, uint64_t frame_number) {
    if (!pattern || !texture) return lw::fail(LW_E_INVALID_ARG, "lw_spike_pattern_draw: NULL argument");
    return lw::guarded("lw_spike_pattern_draw", [&]() -> lw_status {
        auto *target = static_cast<ID3D11Texture2D *>(texture);
        const UINT w = pattern->width, h = pattern->height;
        // A steady pan: camera-like motion the encoder can predict.
        const UINT x = static_cast<UINT>((frame_number * 8) % w), y = static_cast<UINT>((frame_number * 4) % h);
        D3D11_BOX box{x, y, 0, x + w, y + h, 1};
        pattern->context->CopySubresourceRegion(target, 0, 0, 0, 0, pattern->noise.get(), 0, &box);

        ID3D11RenderTargetView *rtv = pattern->view(target);
        const float white[4] = {1, 1, 1, 1}, black[4] = {0, 0, 0, 1};
        const LONG bar = static_cast<LONG>((frame_number * 12) % w);
        const D3D11_RECT bar_rect{bar, static_cast<LONG>(kBlock), std::min<LONG>(bar + 48, static_cast<LONG>(w)), static_cast<LONG>(h)};
        pattern->context->ClearView(rtv, white, &bar_rect, 1);
        D3D11_RECT ones[kBits], zeros[kBits];
        UINT one_count = 0, zero_count = 0;
        for (UINT bit = 0; bit < kBits; ++bit) {
            const D3D11_RECT r{static_cast<LONG>(bit * kBlock), 0, static_cast<LONG>((bit + 1) * kBlock), static_cast<LONG>(kBlock)};
            if ((frame_number >> bit) & 1) ones[one_count++] = r; else zeros[zero_count++] = r;
        }
        if (one_count) pattern->context->ClearView(rtv, white, ones, one_count);
        if (zero_count) pattern->context->ClearView(rtv, black, zeros, zero_count);
        if (aux) {
            const float value[4] = {static_cast<float>(frame_number % (1u << 24)), 0, 0, 0}; // exact in a float
            pattern->context->ClearView(pattern->view(static_cast<ID3D11Texture2D *>(aux)), value, nullptr, 0);
        }
        return LW_OK;
    });
}

extern "C" lw_status lw_spike_pattern_read(lw_spike_pattern *pattern, void *texture, void *aux, uint32_t *out_frame_number,
                                           float *out_aux) {
    if (!pattern || !texture || !out_frame_number) return lw::fail(LW_E_INVALID_ARG, "lw_spike_pattern_read: NULL argument");
    return lw::guarded("lw_spike_pattern_read", [&]() -> lw_status {
        auto &ctx = pattern->context;
        D3D11_BOX box{0, 0, 0, kBits * kBlock, kBlock, 1};
        ctx->CopySubresourceRegion(pattern->strip.get(), 0, 0, 0, 0, static_cast<ID3D11Texture2D *>(texture), 0, &box);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(pattern->strip.get(), 0, D3D11_MAP_READ, 0, &mapped));
        uint32_t value = 0;
        const auto *row = reinterpret_cast<const uint32_t *>(static_cast<const uint8_t *>(mapped.pData) + mapped.RowPitch * (kBlock / 2));
        for (UINT bit = 0; bit < kBits; ++bit) {
            const uint32_t pixel = row[bit * kBlock + kBlock / 2];
            if ((pixel & 0xFF) > 0x80) value |= 1u << bit;
        }
        ctx->Unmap(pattern->strip.get(), 0);
        *out_frame_number = value;
        if (aux && out_aux) {
            D3D11_BOX one{0, 0, 0, 1, 1, 1};
            ctx->CopySubresourceRegion(pattern->aux_pixel.get(), 0, 0, 0, 0, static_cast<ID3D11Texture2D *>(aux), 0, &one);
            winrt::check_hresult(ctx->Map(pattern->aux_pixel.get(), 0, D3D11_MAP_READ, 0, &mapped));
            *out_aux = *static_cast<const float *>(mapped.pData);
            ctx->Unmap(pattern->aux_pixel.get(), 0);
        }
        return LW_OK;
    });
}

extern "C" void lw_spike_pattern_release(lw_spike_pattern *pattern) { delete pattern; }
