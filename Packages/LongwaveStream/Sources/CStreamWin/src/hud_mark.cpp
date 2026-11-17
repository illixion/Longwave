// lw_hud_mark_*: the head-locked HUD marked in the depth picture's chroma
// (NATIVE_V3_PROTOCOL.md section 4.8). The broker composites the game's quad
// layers into the eye images; a head-locked one (Cyberpunk's HUD) is drawn at
// the render pose and then reprojected with the world by the headset, so it
// swam by however far the head moved in the frame's 100+ ms of latency. Where
// the producer says so (side data hudMark) the eye images' alpha is 1 minus
// the head-locked HUD's coverage. This pass copies the depth picture and, at
// every depth texel the HUD covers, moves its chroma off grey without moving
// its luma: Cb (B - Y) pushed half the range away from the side nearer to
// clipping, G pulled to compensate, so the depth value NVENC encodes as luma
// stays. The headset's depth decode reads Cb away from 128 as "head-locked:
// show where the head is now". Older headsets read only the luma.
#include "common.hpp"

#include <d3dcompiler.h>

#include <cstring>
#include <stdexcept>

namespace {

const char kShader[] = R"hlsl(
cbuffer Mark : register(b0) {
    float4 sizes;   // depth eye width, height; colour eye width, height (pixels)
    float4 texel;   // 1 / colour texture width, height; 1 / depth texture width, height
};
Texture2D<float4> depth : register(t0);
Texture2D<float4> colour : register(t1);
SamplerState linearClamp : register(s0);

float4 vs_main(uint id : SV_VertexID) : SV_Position {
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 ps_main(float4 position : SV_Position) : SV_Target {
    float4 d = depth.Load(int3(position.xy, 0));
    float2 depthEye = sizes.xy, colourEye = sizes.zw;
    uint e = position.x >= depthEye.x ? 1 : 0;
    float2 local = float2(position.x - e * depthEye.x, position.y) / depthEye;
    // The texel's footprint in the colour eye, four taps: covered if any of them is.
    float2 footprint = colourEye / depthEye;
    float coverage = 0;
    [unroll] for (int j = 0; j < 2; j++) {
        [unroll] for (int i = 0; i < 2; i++) {
            float2 p = local * colourEye + (float2(i, j) - 0.5) * footprint * 0.5;
            p = clamp(p, 0.5, colourEye - 0.5) + float2(e * colourEye.x, 0);
            coverage = max(coverage, 1 - colour.SampleLevel(linearClamp, p * texel.xy, 0).a);
        }
    }
    if (coverage < 0.25) return d;
    float y = d.r;                       // grey depth: r = g = b
    float b = y < 0.5 ? y + 0.5 : y - 0.5;
    float g = saturate(y + 0.0722 * (y - b) / 0.7152);
    return float4(y, g, b, 1);
}
)hlsl";

struct Constants {
    float sizes[4];
    float texel[4];
};

winrt::com_ptr<ID3DBlob> compile(const char *entry, const char *target) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "hud_mark.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

} // namespace

struct lw_hud_mark {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11Multithread> multithread;
    winrt::com_ptr<ID3D11VertexShader> vertex;
    winrt::com_ptr<ID3D11PixelShader> pixel;
    winrt::com_ptr<ID3D11Buffer> constants;
    winrt::com_ptr<ID3D11SamplerState> sampler;
    winrt::com_ptr<ID3D11RasterizerState> rasterizer;
};

extern "C" lw_status lw_hud_mark_create(lw_device *device, lw_hud_mark **out) {
    if (!device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_hud_mark_create: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_hud_mark_create", [&]() -> lw_status {
        auto m = std::make_unique<lw_hud_mark>();
        m->device = device->device;
        m->context = device->context;
        m->multithread = device->device.as<ID3D11Multithread>();
        auto vs = compile("vs_main", "vs_5_0");
        auto ps = compile("ps_main", "ps_5_0");
        winrt::check_hresult(m->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, m->vertex.put()));
        winrt::check_hresult(m->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, m->pixel.put()));
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Constants);
        buffer.Usage = D3D11_USAGE_DYNAMIC;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        winrt::check_hresult(m->device->CreateBuffer(&buffer, nullptr, m->constants.put()));
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        winrt::check_hresult(m->device->CreateSamplerState(&sampler, m->sampler.put()));
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        winrt::check_hresult(m->device->CreateRasterizerState(&raster, m->rasterizer.put()));
        *out = m.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_hud_mark_apply(lw_hud_mark *m, void *depth, void *colour, void *destination,
                                        const lw_hud_mark_params *params) {
    if (!m || !depth || !colour || !destination || !params || depth == destination)
        return lw::fail(LW_E_INVALID_ARG, "lw_hud_mark_apply: bad argument");
    const lw_hud_mark_params &p = *params;
    if (p.depth_eye_width <= 0 || p.depth_eye_height <= 0 || p.colour_eye_width <= 0 || p.colour_eye_height <= 0)
        return lw::fail(LW_E_INVALID_ARG, "lw_hud_mark_apply: empty eye size");
    return lw::guarded("lw_hud_mark_apply", [&]() -> lw_status {
        auto *dsrc = static_cast<ID3D11Texture2D *>(depth);
        auto *csrc = static_cast<ID3D11Texture2D *>(colour);
        auto *dst = static_cast<ID3D11Texture2D *>(destination);
        D3D11_TEXTURE2D_DESC dd{}, cd{}, od{};
        dsrc->GetDesc(&dd);
        csrc->GetDesc(&cd);
        dst->GetDesc(&od);
        const UINT width = static_cast<UINT>(2 * p.depth_eye_width), height = static_cast<UINT>(p.depth_eye_height);
        if (dd.Width < width || dd.Height < height || od.Width < width || od.Height < height ||
            cd.Width < static_cast<UINT>(2 * p.colour_eye_width) || cd.Height < static_cast<UINT>(p.colour_eye_height))
            return lw::fail(LW_E_INVALID_ARG, "lw_hud_mark_apply: a texture is smaller than its eyes");
        winrt::com_ptr<ID3D11ShaderResourceView> dsrv, csrv;
        winrt::check_hresult(m->device->CreateShaderResourceView(dsrc, nullptr, dsrv.put()));
        winrt::check_hresult(m->device->CreateShaderResourceView(csrc, nullptr, csrv.put()));
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(m->device->CreateRenderTargetView(dst, nullptr, rtv.put()));
        Constants c{};
        c.sizes[0] = static_cast<float>(p.depth_eye_width);
        c.sizes[1] = static_cast<float>(p.depth_eye_height);
        c.sizes[2] = static_cast<float>(p.colour_eye_width);
        c.sizes[3] = static_cast<float>(p.colour_eye_height);
        c.texel[0] = 1.0f / static_cast<float>(cd.Width);
        c.texel[1] = 1.0f / static_cast<float>(cd.Height);
        c.texel[2] = 1.0f / static_cast<float>(dd.Width);
        c.texel[3] = 1.0f / static_cast<float>(dd.Height);

        m->multithread->Enter();
        struct Leave {
            ID3D11Multithread *t;
            ~Leave() { t->Leave(); }
        } leave{m->multithread.get()};
        ID3D11DeviceContext *ctx = m->context.get();
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(m->constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
        std::memcpy(mapped.pData, &c, sizeof c);
        ctx->Unmap(m->constants.get(), 0);
        D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
        ID3D11RenderTargetView *targets[] = {rtv.get()};
        ID3D11ShaderResourceView *views[] = {dsrv.get(), csrv.get()};
        ID3D11SamplerState *samplers[] = {m->sampler.get()};
        ID3D11Buffer *buffers[] = {m->constants.get()};
        ctx->ClearState();
        ctx->OMSetRenderTargets(1, targets, nullptr);
        ctx->RSSetViewports(1, &viewport);
        ctx->RSSetState(m->rasterizer.get());
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(m->vertex.get(), nullptr, 0);
        ctx->PSSetShader(m->pixel.get(), nullptr, 0);
        ctx->PSSetConstantBuffers(0, 1, buffers);
        ctx->PSSetShaderResources(0, 2, views);
        ctx->PSSetSamplers(0, 1, samplers);
        ctx->Draw(3, 0);
        ctx->ClearState();
        ctx->Flush();
        return LW_OK;
    });
}

extern "C" void lw_hud_mark_release(lw_hud_mark *m) { delete m; }
