// lw_warp_*: v3's centre/edge foveation warp on the GPU (NATIVE_V3_PROTOCOL.md
// section 4.7), and lw_texture_*: plain textures on the shim's device for the
// warp's destination and for tests.
//
// The warp is one full-screen triangle over the destination's eye pair. Each
// wire pixel evaluates StreamWire's CentreEdgeAxisMapping.renderCoordinate
// (forWire:) per axis, from the four constants Swift hands over unchanged, and
// samples the render texture there. The shader is compiled from source once per
// warp with D3DCompile (d3dcompiler_47.dll, part of Windows 10), so there is no
// build step for it and no bytecode blob to keep in sync with this file.
#include "common.hpp"

#include <d3dcompiler.h>

#include <cstring>
#include <stdexcept>

namespace {

const char kShader[] = R"hlsl(
cbuffer Warp : register(b0) {
    float4 axis[4];   // left x, left y, right x, right y: (a, b, r, L)
    float4 sizes;     // render eye width, height; wire eye width, height (pixels)
    float4 texel;     // 1 / source texture width, 1 / source texture height
};
Texture2D<float4> source : register(t0);
SamplerState linearClamp : register(s0);

float4 vs_main(uint id : SV_VertexID) : SV_Position {
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

// CentreEdgeAxisMapping.renderCoordinate(forWire:), plus the slope
// d(render)/d(wire) of the piece the coordinate lands on.
float render_coordinate(float wire, float4 m, out float slope) {
    float packed = wire * m.w;
    float left = m.x / m.z;
    float end = left + m.y - m.x;
    float x;
    if (packed < left) { x = packed * m.z; slope = m.z * m.w; }
    else if (packed <= end) { x = m.x + packed - left; slope = m.w; }
    else { x = m.y + (packed - end) * m.z; slope = m.z * m.w; }
    return saturate(x);
}

float4 ps_main(float4 position : SV_Position) : SV_Target {
    float2 renderEye = sizes.xy, wireEye = sizes.zw;
    uint eye = position.x >= wireEye.x ? 1 : 0;
    float2 wire = float2(position.x - eye * wireEye.x, position.y) / wireEye;
    float4 mx = axis[eye * 2], my = axis[eye * 2 + 1];
    float sx, sy;
    float2 render = float2(render_coordinate(wire.x, mx, sx), render_coordinate(wire.y, my, sy));
    // How many render pixels this wire pixel stands for, per axis: about 1 in
    // the centre, the edge ratio in the edges. Four bilinear taps spread over
    // that footprint average it (a box prefilter); at 1 they coincide, so the
    // centre is a single exact tap.
    float2 spread = max(float2(sx, sy) * renderEye / wireEye - 1, 0) * 0.25;
    float2 centre = float2(eye * renderEye.x, 0) + render * renderEye;
    // Half a texel inside this eye: no tap reaches the other one.
    float2 lo = float2(eye * renderEye.x + 0.5, 0.5);
    float2 hi = float2((eye + 1) * renderEye.x - 0.5, renderEye.y - 0.5);
    float4 sum = 0;
    [unroll] for (int j = 0; j < 2; j++) {
        [unroll] for (int i = 0; i < 2; i++) {
            float2 offset = float2(i == 0 ? -spread.x : spread.x, j == 0 ? -spread.y : spread.y);
            sum += source.SampleLevel(linearClamp, clamp(centre + offset, lo, hi) * texel.xy, 0);
        }
    }
    return sum * 0.25;
}
)hlsl";

struct Constants {
    float axis[4][4];
    float sizes[4];
    float texel[4];
};
static_assert(sizeof(Constants) % 16 == 0, "constant buffers are 16-byte multiples");

winrt::com_ptr<ID3DBlob> compile(const char *entry, const char *target) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "foveation_warp.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

bool valid(const lw_warp_axis &axis) {
    // The same ranges CentreEdgeAxisMapping produces: 0 <= a < b <= 1, r >= 1, 0 < L <= 1.
    return axis.lower >= 0 && axis.lower < axis.upper && axis.upper <= 1 && axis.ratio >= 1 &&
           axis.length > 0 && axis.length <= 1;
}

DXGI_FORMAT dxgi_format(uint32_t format) {
    switch (format) {
    case LW_TEXTURE_BGRA8: return DXGI_FORMAT_B8G8R8A8_UNORM;
    case LW_TEXTURE_RGBA32F: return DXGI_FORMAT_R32G32B32A32_FLOAT;
    default: return DXGI_FORMAT_UNKNOWN;
    }
}

} // namespace

struct lw_warp {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11Multithread> multithread;
    winrt::com_ptr<ID3D11VertexShader> vertex;
    winrt::com_ptr<ID3D11PixelShader> pixel;
    winrt::com_ptr<ID3D11Buffer> constants;
    winrt::com_ptr<ID3D11SamplerState> sampler;
    winrt::com_ptr<ID3D11RasterizerState> rasterizer;
};

extern "C" lw_status lw_warp_create(lw_device *device, lw_warp **out) {
    if (!device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_warp_create: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_warp_create", [&]() -> lw_status {
        auto warp = std::make_unique<lw_warp>();
        warp->device = device->device;
        warp->context = device->context;
        warp->multithread = device->device.as<ID3D11Multithread>();
        auto vs = compile("vs_main", "vs_5_0");
        auto ps = compile("ps_main", "ps_5_0");
        winrt::check_hresult(warp->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr,
                                                              warp->vertex.put()));
        winrt::check_hresult(warp->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr,
                                                             warp->pixel.put()));
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Constants);
        buffer.Usage = D3D11_USAGE_DYNAMIC;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        winrt::check_hresult(warp->device->CreateBuffer(&buffer, nullptr, warp->constants.put()));
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        winrt::check_hresult(warp->device->CreateSamplerState(&sampler, warp->sampler.put()));
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        winrt::check_hresult(warp->device->CreateRasterizerState(&raster, warp->rasterizer.put()));
        *out = warp.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_warp_apply(lw_warp *warp, void *source, void *destination, const lw_warp_params *params) {
    if (!warp || !source || !destination || !params) return lw::fail(LW_E_INVALID_ARG, "lw_warp_apply: NULL argument");
    const lw_warp_params &p = *params;
    if (p.render_eye_width <= 0 || p.render_eye_height <= 0 || p.wire_eye_width <= 0 || p.wire_eye_height <= 0)
        return lw::fail(LW_E_INVALID_ARG, "lw_warp_apply: empty eye size");
    for (const lw_warp_eye &eye : p.eyes) {
        if (!valid(eye.x) || !valid(eye.y)) return lw::fail(LW_E_INVALID_ARG, "lw_warp_apply: axis constants out of range");
    }
    return lw::guarded("lw_warp_apply", [&]() -> lw_status {
        auto *src = static_cast<ID3D11Texture2D *>(source);
        auto *dst = static_cast<ID3D11Texture2D *>(destination);
        D3D11_TEXTURE2D_DESC sd{}, dd{};
        src->GetDesc(&sd);
        dst->GetDesc(&dd);
        if (sd.Width < static_cast<UINT>(2 * p.render_eye_width) || sd.Height < static_cast<UINT>(p.render_eye_height))
            return lw::fail(LW_E_INVALID_ARG, "lw_warp_apply: source %ux%u is smaller than two %dx%d eyes", sd.Width,
                            sd.Height, p.render_eye_width, p.render_eye_height);
        if (dd.Width < static_cast<UINT>(2 * p.wire_eye_width) || dd.Height < static_cast<UINT>(p.wire_eye_height))
            return lw::fail(LW_E_INVALID_ARG, "lw_warp_apply: destination %ux%u is smaller than two %dx%d eyes",
                            dd.Width, dd.Height, p.wire_eye_width, p.wire_eye_height);

        // Views per call: microseconds, and nothing outlives a frame-source re-attach.
        winrt::com_ptr<ID3D11ShaderResourceView> srv;
        winrt::check_hresult(warp->device->CreateShaderResourceView(src, nullptr, srv.put()));
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(warp->device->CreateRenderTargetView(dst, nullptr, rtv.put()));

        Constants c{};
        for (int eye = 0; eye < 2; eye++) {
            const lw_warp_axis *axes[2] = {&p.eyes[eye].x, &p.eyes[eye].y};
            for (int a = 0; a < 2; a++) {
                float *v = c.axis[eye * 2 + a];
                v[0] = axes[a]->lower;
                v[1] = axes[a]->upper;
                v[2] = axes[a]->ratio;
                v[3] = axes[a]->length;
            }
        }
        c.sizes[0] = static_cast<float>(p.render_eye_width);
        c.sizes[1] = static_cast<float>(p.render_eye_height);
        c.sizes[2] = static_cast<float>(p.wire_eye_width);
        c.sizes[3] = static_cast<float>(p.wire_eye_height);
        c.texel[0] = 1.0f / static_cast<float>(sd.Width);
        c.texel[1] = 1.0f / static_cast<float>(sd.Height);

        // The context is shared with the rest of the shim; hold its lock for the
        // whole sequence so no other caller's state lands between our binds.
        warp->multithread->Enter();
        struct Leave {
            ID3D11Multithread *m;
            ~Leave() { m->Leave(); }
        } leave{warp->multithread.get()};
        ID3D11DeviceContext *ctx = warp->context.get();
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(warp->constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
        std::memcpy(mapped.pData, &c, sizeof c);
        ctx->Unmap(warp->constants.get(), 0);

        D3D11_VIEWPORT viewport{0, 0, static_cast<float>(2 * p.wire_eye_width), static_cast<float>(p.wire_eye_height),
                                0, 1};
        ID3D11RenderTargetView *targets[] = {rtv.get()};
        ID3D11ShaderResourceView *views[] = {srv.get()};
        ID3D11SamplerState *samplers[] = {warp->sampler.get()};
        ID3D11Buffer *buffers[] = {warp->constants.get()};
        ctx->ClearState();
        ctx->OMSetRenderTargets(1, targets, nullptr);
        ctx->RSSetViewports(1, &viewport);
        ctx->RSSetState(warp->rasterizer.get());
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(warp->vertex.get(), nullptr, 0);
        ctx->PSSetShader(warp->pixel.get(), nullptr, 0);
        ctx->PSSetConstantBuffers(0, 1, buffers);
        ctx->PSSetShaderResources(0, 1, views);
        ctx->PSSetSamplers(0, 1, samplers);
        ctx->Draw(3, 0);
        ctx->ClearState(); // unbinds the destination, so NVENC and others may use it
        ctx->Flush();
        return LW_OK;
    });
}

extern "C" void lw_warp_release(lw_warp *warp) { delete warp; }

extern "C" lw_status lw_texture_create(lw_device *device, int32_t width, int32_t height, uint32_t format,
                                       const void *data, uint32_t row_pitch, void **out) {
    if (!device || !out || width <= 0 || height <= 0) return lw::fail(LW_E_INVALID_ARG, "lw_texture_create: bad argument");
    *out = nullptr;
    const DXGI_FORMAT dxgi = dxgi_format(format);
    if (dxgi == DXGI_FORMAT_UNKNOWN) return lw::fail(LW_E_INVALID_ARG, "lw_texture_create: unknown format %u", format);
    return lw::guarded("lw_texture_create", [&]() -> lw_status {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = static_cast<UINT>(width);
        desc.Height = static_cast<UINT>(height);
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = dxgi;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA initial{data, row_pitch, 0};
        ID3D11Texture2D *texture = nullptr;
        winrt::check_hresult(device->device->CreateTexture2D(&desc, data ? &initial : nullptr, &texture));
        *out = texture; // the caller's reference, released by lw_texture_release
        return LW_OK;
    });
}

extern "C" lw_status lw_texture_read(lw_device *device, void *texture, void *out, uint32_t row_pitch) {
    if (!device || !texture || !out) return lw::fail(LW_E_INVALID_ARG, "lw_texture_read: NULL argument");
    return lw::guarded("lw_texture_read", [&]() -> lw_status {
        auto *source = static_cast<ID3D11Texture2D *>(texture);
        D3D11_TEXTURE2D_DESC desc{};
        source->GetDesc(&desc);
        UINT bytes_per_pixel = 0;
        switch (desc.Format) {
        case DXGI_FORMAT_B8G8R8A8_UNORM: bytes_per_pixel = 4; break;
        case DXGI_FORMAT_R32G32B32A32_FLOAT: bytes_per_pixel = 16; break;
        default: return lw::fail(LW_E_INVALID_ARG, "lw_texture_read: format %d", static_cast<int>(desc.Format));
        }
        if (row_pitch < desc.Width * bytes_per_pixel) return lw::fail(LW_E_INVALID_ARG, "lw_texture_read: row pitch too small");
        desc.Usage = D3D11_USAGE_STAGING;
        desc.BindFlags = 0;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        desc.MiscFlags = 0;
        winrt::com_ptr<ID3D11Texture2D> staging;
        winrt::check_hresult(device->device->CreateTexture2D(&desc, nullptr, staging.put()));
        auto multithread = device->device.as<ID3D11Multithread>();
        multithread->Enter();
        struct Leave {
            ID3D11Multithread *m;
            ~Leave() { m->Leave(); }
        } leave{multithread.get()};
        device->context->CopyResource(staging.get(), source);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(device->context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
        for (UINT y = 0; y < desc.Height; y++) {
            std::memcpy(static_cast<uint8_t *>(out) + static_cast<size_t>(y) * row_pitch,
                        static_cast<const uint8_t *>(mapped.pData) + static_cast<size_t>(y) * mapped.RowPitch,
                        static_cast<size_t>(desc.Width) * bytes_per_pixel);
        }
        device->context->Unmap(staging.get(), 0);
        return LW_OK;
    });
}

extern "C" void lw_texture_release(void *texture) {
    if (texture) static_cast<ID3D11Texture2D *>(texture)->Release();
}
