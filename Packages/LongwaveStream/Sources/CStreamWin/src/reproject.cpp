// lw_reproject_*: an eye pair turned from one pose to another by a homography
// per eye, for the motion search (docs/PCVR_MOTION_EXTRAPOLATION.md): the
// previous picture is turned to the current frame's render orientation before
// NVENC compares the two, so a still world matches itself at zero motion. The
// search alone can't be trusted with the head's share: on flat or repeating
// texture "no motion" matches as well as the true one, and subtracting the
// turn from such a block turned it into motion of the turn's size (the wobble
// on the headset, 2026-11-17). Oculus ASW turned its previous frame the same
// way.
//
// One full-screen triangle over the destination's eye pair, as lw_warp. Each
// destination pixel maps through its eye's 3x3 matrix (destination pixel,
// homogeneous, to source pixel within that eye) and reads the source there,
// bilinear, clamped half a texel inside the eye.
#include "common.hpp"

#include <d3dcompiler.h>

#include <cmath>
#include <cstring>
#include <stdexcept>

namespace {

const char kShader[] = R"hlsl(
cbuffer Reproject : register(b0) {
    float4 rows[6];   // left eye's matrix rows, then the right's (xyz)
    float4 sizes;     // eye width, height (pixels); 1 / texture width, 1 / texture height
};
Texture2D<float4> source : register(t0);
SamplerState linearClamp : register(s0);

float4 vs_main(uint id : SV_VertexID) : SV_Position {
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

float4 ps_main(float4 position : SV_Position) : SV_Target {
    float2 eye = sizes.xy;
    uint e = position.x >= eye.x ? 1 : 0;
    float3 p = float3(position.x - e * eye.x, position.y, 1);
    float3 q = float3(dot(rows[e * 3].xyz, p), dot(rows[e * 3 + 1].xyz, p), dot(rows[e * 3 + 2].xyz, p));
    float2 at = q.z > 1e-6 ? q.xy / q.z : p.xy;
    float2 lo = float2(0.5, 0.5), hi = eye - 0.5;
    float2 texel = clamp(at, lo, hi) + float2(e * eye.x, 0);
    return source.SampleLevel(linearClamp, texel * sizes.zw, 0);
}
)hlsl";

struct Constants {
    float rows[6][4];
    float sizes[4];
};
static_assert(sizeof(Constants) % 16 == 0, "constant buffers are 16-byte multiples");

winrt::com_ptr<ID3DBlob> compile(const char *entry, const char *target) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "reproject.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

} // namespace

struct lw_reproject {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11Multithread> multithread;
    winrt::com_ptr<ID3D11VertexShader> vertex;
    winrt::com_ptr<ID3D11PixelShader> pixel;
    winrt::com_ptr<ID3D11Buffer> constants;
    winrt::com_ptr<ID3D11SamplerState> sampler;
    winrt::com_ptr<ID3D11RasterizerState> rasterizer;
};

extern "C" lw_status lw_reproject_create(lw_device *device, lw_reproject **out) {
    if (!device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_reproject_create: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_reproject_create", [&]() -> lw_status {
        auto r = std::make_unique<lw_reproject>();
        r->device = device->device;
        r->context = device->context;
        r->multithread = device->device.as<ID3D11Multithread>();
        auto vs = compile("vs_main", "vs_5_0");
        auto ps = compile("ps_main", "ps_5_0");
        winrt::check_hresult(r->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, r->vertex.put()));
        winrt::check_hresult(r->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, r->pixel.put()));
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Constants);
        buffer.Usage = D3D11_USAGE_DYNAMIC;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        winrt::check_hresult(r->device->CreateBuffer(&buffer, nullptr, r->constants.put()));
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        winrt::check_hresult(r->device->CreateSamplerState(&sampler, r->sampler.put()));
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        winrt::check_hresult(r->device->CreateRasterizerState(&raster, r->rasterizer.put()));
        *out = r.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_reproject_apply(lw_reproject *r, void *source, void *destination, const lw_reproject_params *params) {
    if (!r || !source || !destination || !params || source == destination)
        return lw::fail(LW_E_INVALID_ARG, "lw_reproject_apply: bad argument");
    const lw_reproject_params &p = *params;
    if (p.eye_width <= 0 || p.eye_height <= 0) return lw::fail(LW_E_INVALID_ARG, "lw_reproject_apply: empty eye size");
    for (float v : p.matrices) {
        if (!std::isfinite(v)) return lw::fail(LW_E_INVALID_ARG, "lw_reproject_apply: matrix not finite");
    }
    return lw::guarded("lw_reproject_apply", [&]() -> lw_status {
        auto *src = static_cast<ID3D11Texture2D *>(source);
        auto *dst = static_cast<ID3D11Texture2D *>(destination);
        D3D11_TEXTURE2D_DESC sd{}, dd{};
        src->GetDesc(&sd);
        dst->GetDesc(&dd);
        const UINT width = static_cast<UINT>(2 * p.eye_width), height = static_cast<UINT>(p.eye_height);
        if (sd.Width < width || sd.Height < height || dd.Width < width || dd.Height < height)
            return lw::fail(LW_E_INVALID_ARG, "lw_reproject_apply: a texture is smaller than two %dx%d eyes", p.eye_width,
                            p.eye_height);
        winrt::com_ptr<ID3D11ShaderResourceView> srv;
        winrt::check_hresult(r->device->CreateShaderResourceView(src, nullptr, srv.put()));
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(r->device->CreateRenderTargetView(dst, nullptr, rtv.put()));

        Constants c{};
        for (int row = 0; row < 6; row++) {
            for (int k = 0; k < 3; k++) c.rows[row][k] = p.matrices[row * 3 + k];
        }
        c.sizes[0] = static_cast<float>(p.eye_width);
        c.sizes[1] = static_cast<float>(p.eye_height);
        c.sizes[2] = 1.0f / static_cast<float>(sd.Width);
        c.sizes[3] = 1.0f / static_cast<float>(sd.Height);

        r->multithread->Enter();
        struct Leave {
            ID3D11Multithread *m;
            ~Leave() { m->Leave(); }
        } leave{r->multithread.get()};
        ID3D11DeviceContext *ctx = r->context.get();
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(r->constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
        std::memcpy(mapped.pData, &c, sizeof c);
        ctx->Unmap(r->constants.get(), 0);
        D3D11_VIEWPORT viewport{0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1};
        ID3D11RenderTargetView *targets[] = {rtv.get()};
        ID3D11ShaderResourceView *views[] = {srv.get()};
        ID3D11SamplerState *samplers[] = {r->sampler.get()};
        ID3D11Buffer *buffers[] = {r->constants.get()};
        ctx->ClearState();
        ctx->OMSetRenderTargets(1, targets, nullptr);
        ctx->RSSetViewports(1, &viewport);
        ctx->RSSetState(r->rasterizer.get());
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(r->vertex.get(), nullptr, 0);
        ctx->PSSetShader(r->pixel.get(), nullptr, 0);
        ctx->PSSetConstantBuffers(0, 1, buffers);
        ctx->PSSetShaderResources(0, 1, views);
        ctx->PSSetSamplers(0, 1, samplers);
        ctx->Draw(3, 0);
        ctx->ClearState();
        ctx->Flush();
        return LW_OK;
    });
}

extern "C" void lw_reproject_release(lw_reproject *r) { delete r; }
