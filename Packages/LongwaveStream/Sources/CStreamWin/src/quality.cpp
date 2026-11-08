// lw_quality_*: picture quality for the codec bench (pcvr-codec-bench).
//
// Three compute passes over textures already on the GPU, each writing small
// per-tile sums that are read back:
//  - wire: the encoder's input (BGRA8) against its reconstruction (NV12), the
//    codec's loss alone, everywhere;
//  - gaze: a box of render pixels round the gaze point, the rendered truth
//    against what the headset would show there: the wire picture read at each
//    render pixel's warped position, bilinear, as the headset's unwarp reads
//    it, from the reconstruction and (for the warp's share) from the
//    unencoded wire picture;
//  - crop: the same box as pixels, for looking at.
// Luma throughout is BT.709 limited range, what NVENC encodes BGRA as (the
// VUI says so; encoder_nvenc.cpp). The shader is compiled at create time, as
// the warp's is.
#include "common.hpp"

#include <d3dcompiler.h>

#include <cstring>
#include <stdexcept>
#include <vector>

namespace {

const char kShader[] = R"hlsl(
cbuffer Params : register(b0) {
    int4 box;      // eye, x, y, size (gaze and crop)
    float4 axisX;  // the eye's warp constants: lower, upper, ratio, length
    float4 axisY;
    int4 eyes;     // render eye width, height; wire eye width, height
    int4 extent;   // reference width, height; tiles across; first output tile
};
Texture2D<float4> reference : register(t0); // wire pass: the encoder input; gaze, crop: the truth
Texture2D<float> reconY : register(t1);
Texture2D<float2> reconUV : register(t2);
Texture2D<float4> wire : register(t3);
SamplerState linearClamp : register(s0);
RWStructuredBuffer<uint> output : register(u0); // floats as their bits, or BGRA pixels

float luma(float3 rgb) { return 16.0 + 219.0 * dot(saturate(rgb), float3(0.2126, 0.7152, 0.0722)); }

groupshared float gA[16][16];
groupshared float gB[16][16];
groupshared float gC[16][16];
groupshared uint gValid[16][16];

// SSIM of one 8x8 window, A against B (which = 0) or C (which = 1), in code values.
float ssim8(int ox, int oy, int which) {
    float ma = 0, mb = 0, n = 0;
    [loop] for (int j = 0; j < 8; j++) {
        [loop] for (int i = 0; i < 8; i++) {
            if (gValid[oy + j][ox + i] == 0) continue;
            ma += gA[oy + j][ox + i];
            mb += which == 0 ? gB[oy + j][ox + i] : gC[oy + j][ox + i];
            n += 1;
        }
    }
    if (n < 4) return 1;
    ma /= n;
    mb /= n;
    float va = 0, vb = 0, cab = 0;
    [loop] for (int j2 = 0; j2 < 8; j2++) {
        [loop] for (int i2 = 0; i2 < 8; i2++) {
            if (gValid[oy + j2][ox + i2] == 0) continue;
            float a = gA[oy + j2][ox + i2] - ma;
            float b = (which == 0 ? gB[oy + j2][ox + i2] : gC[oy + j2][ox + i2]) - mb;
            va += a * a;
            vb += b * b;
            cab += a * b;
        }
    }
    va /= n;
    vb /= n;
    cab /= n;
    const float c1 = 6.5025, c2 = 58.5225; // (0.01 * 255)^2, (0.03 * 255)^2
    return ((2 * ma * mb + c1) * (2 * cab + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2));
}

float ssim16(int which) {
    return 0.25 * (ssim8(0, 0, which) + ssim8(8, 0, which) + ssim8(0, 8, which) + ssim8(8, 8, which));
}

[numthreads(16, 16, 1)]
void cs_wire(uint3 g : SV_GroupID, uint3 t : SV_GroupThreadID) {
    int2 p = int2(g.xy) * 16 + int2(t.xy);
    bool inside = p.x < extent.x && p.y < extent.y;
    gValid[t.y][t.x] = inside ? 1 : 0;
    gA[t.y][t.x] = inside ? luma(reference.Load(int3(p, 0)).rgb) : 0;
    gB[t.y][t.x] = inside ? reconY.Load(int3(p, 0)) * 255.0 : 0;
    GroupMemoryBarrierWithGroupSync();
    if (t.x != 0 || t.y != 0) return;
    float sse = 0, sum = 0, sum2 = 0, n = 0;
    [loop] for (int j = 0; j < 16; j++) {
        [loop] for (int i = 0; i < 16; i++) {
            if (gValid[j][i] == 0) continue;
            float d = gA[j][i] - gB[j][i];
            sse += d * d;
            sum += gA[j][i];
            sum2 += gA[j][i] * gA[j][i];
            n += 1;
        }
    }
    // Steps across the 8-pixel grid line inside the tile that the reference
    // doesn't have, beyond the same excess at lines between grid lines.
    float edge = 0, inner = 0, ne = 0, ni = 0;
    [loop] for (int k = 0; k < 16; k++) {
        if (gValid[k][8] != 0) {
            edge += abs(gB[k][8] - gB[k][7]) - abs(gA[k][8] - gA[k][7]);
            inner += abs(gB[k][4] - gB[k][3]) - abs(gA[k][4] - gA[k][3]);
            ne += 1;
            ni += 1;
            if (gValid[k][12] != 0) {
                inner += abs(gB[k][12] - gB[k][11]) - abs(gA[k][12] - gA[k][11]);
                ni += 1;
            }
        }
        if (gValid[8][k] != 0) {
            edge += abs(gB[8][k] - gB[7][k]) - abs(gA[8][k] - gA[7][k]);
            inner += abs(gB[4][k] - gB[3][k]) - abs(gA[4][k] - gA[3][k]);
            ne += 1;
            ni += 1;
            if (gValid[12][k] != 0) {
                inner += abs(gB[12][k] - gB[11][k]) - abs(gA[12][k] - gA[11][k]);
                ni += 1;
            }
        }
    }
    float blocky = (ne > 0 && ni > 0) ? max(0, edge / ne - inner / ni) : 0;
    float variance = n > 0 ? max(0, sum2 / n - (sum / n) * (sum / n)) : 0;
    uint tile = g.y * extent.z + g.x;
    output[tile * 4 + 0] = asuint(sse);
    output[tile * 4 + 1] = asuint(ssim16(0));
    output[tile * 4 + 2] = asuint(blocky);
    output[tile * 4 + 3] = asuint(variance);
}

// CentreEdgeAxisMapping.wireCoordinate(forRender:): where the headset reads a render UV.
float wire_coordinate(float x, float4 m) {
    float packed;
    if (x < m.x) packed = x / m.z;
    else if (x <= m.y) packed = m.x / m.z + x - m.x;
    else packed = m.x / m.z + m.y - m.x + (x - m.y) / m.z;
    return saturate(packed / m.w);
}

// A render pixel of the box's eye, as a UV in the side-by-side wire texture.
float2 wire_uv(int2 render) {
    float2 uv = (float2(render) + 0.5) / float2(eyes.xy);
    float2 pos = float2(wire_coordinate(uv.x, axisX), wire_coordinate(uv.y, axisY)) * float2(eyes.zw);
    pos = clamp(pos, 0.5, float2(eyes.zw) - 0.5); // stay inside this eye, as the unwarp does
    pos.x += box.x * eyes.z;
    float w, h;
    reconY.GetDimensions(w, h);
    return pos / float2(w, h);
}

float truth_luma(int2 render, out bool inside) {
    inside = all(render >= 0) && render.x < eyes.x && render.y < eyes.y;
    return inside ? luma(reference.Load(int3(render.x + box.x * eyes.x, render.y, 0)).rgb) : 0;
}

[numthreads(16, 16, 1)]
void cs_gaze(uint3 g : SV_GroupID, uint3 t : SV_GroupThreadID) {
    int2 render = box.yz + int2(g.xy) * 16 + int2(t.xy);
    bool inside;
    float truth = truth_luma(render, inside);
    float2 uv = wire_uv(render);
    gValid[t.y][t.x] = inside ? 1 : 0;
    gA[t.y][t.x] = truth;
    gB[t.y][t.x] = reconY.SampleLevel(linearClamp, uv, 0) * 255.0;
    gC[t.y][t.x] = luma(wire.SampleLevel(linearClamp, uv, 0).rgb);
    GroupMemoryBarrierWithGroupSync();
    if (t.x != 0 || t.y != 0) return;
    float sseShown = 0, sseWire = 0;
    [loop] for (int j = 0; j < 16; j++) {
        [loop] for (int i = 0; i < 16; i++) {
            if (gValid[j][i] == 0) continue;
            float d = gA[j][i] - gB[j][i], e = gA[j][i] - gC[j][i];
            sseShown += d * d;
            sseWire += e * e;
        }
    }
    float lapTruth = 0, lapShown = 0;
    [loop] for (int y = 1; y < 15; y++) {
        [loop] for (int x = 1; x < 15; x++) {
            if (gValid[y][x] == 0 || gValid[y - 1][x] == 0 || gValid[y + 1][x] == 0 || gValid[y][x - 1] == 0 || gValid[y][x + 1] == 0) continue;
            lapTruth += abs(4 * gA[y][x] - gA[y - 1][x] - gA[y + 1][x] - gA[y][x - 1] - gA[y][x + 1]);
            lapShown += abs(4 * gB[y][x] - gB[y - 1][x] - gB[y + 1][x] - gB[y][x - 1] - gB[y][x + 1]);
        }
    }
    uint tile = extent.w + g.y * (box.w / 16) + g.x;
    output[tile * 8 + 0] = asuint(sseShown);
    output[tile * 8 + 1] = asuint(sseWire);
    output[tile * 8 + 2] = asuint(ssim16(0));
    output[tile * 8 + 3] = asuint(ssim16(1));
    output[tile * 8 + 4] = asuint(lapTruth);
    output[tile * 8 + 5] = asuint(lapShown);
    output[tile * 8 + 6] = asuint(0);
    output[tile * 8 + 7] = asuint(0);
}

uint pack(float3 rgb) {
    uint3 c = uint3(saturate(rgb) * 255.0 + 0.5);
    return c.b | (c.g << 8) | (c.r << 16) | (255u << 24); // BGRA in memory
}

[numthreads(16, 16, 1)]
void cs_crop(uint3 id : SV_DispatchThreadID) {
    int2 local = int2(id.xy);
    if (local.x >= box.w || local.y >= box.w) return;
    int2 render = box.yz + local;
    bool inside = all(render >= 0) && render.x < eyes.x && render.y < eyes.y;
    float3 truth = inside ? reference.Load(int3(render.x + box.x * eyes.x, render.y, 0)).rgb : float3(1, 0, 1);
    float2 uv = wire_uv(render);
    float y = (reconY.SampleLevel(linearClamp, uv, 0) * 255.0 - 16.0) / 219.0;
    float2 c = (reconUV.SampleLevel(linearClamp, uv, 0) * 255.0 - 128.0) / 224.0;
    float3 shown = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
    uint i = local.y * box.w + local.x;
    output[i] = pack(truth);
    output[box.w * box.w + i] = pack(shown);
}
)hlsl";

struct Constants {
    int32_t box[4];
    float axis_x[4];
    float axis_y[4];
    int32_t eyes[4];
    int32_t extent[4];
};
static_assert(sizeof(Constants) % 16 == 0, "constant buffers are 16-byte multiples");

winrt::com_ptr<ID3DBlob> compile(const char *entry) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "quality.hlsl", nullptr, nullptr, entry, "cs_5_0",
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

} // namespace

struct lw_quality {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11Multithread> multithread;
    winrt::com_ptr<ID3D11ComputeShader> wire_cs, gaze_cs, crop_cs;
    winrt::com_ptr<ID3D11Buffer> constants;
    winrt::com_ptr<ID3D11SamplerState> sampler;
    // Grown as needed: one structured buffer of 4-byte elements, its UAV, and a staging copy.
    winrt::com_ptr<ID3D11Buffer> output, staging;
    winrt::com_ptr<ID3D11UnorderedAccessView> output_uav;
    uint32_t output_elements = 0;

    void ensure_output(uint32_t elements) {
        if (elements <= output_elements) return;
        output_uav = nullptr;
        output = nullptr;
        staging = nullptr;
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = elements * 4;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_UNORDERED_ACCESS;
        desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
        desc.StructureByteStride = 4;
        winrt::check_hresult(device->CreateBuffer(&desc, nullptr, output.put()));
        D3D11_UNORDERED_ACCESS_VIEW_DESC uav{};
        uav.Format = DXGI_FORMAT_UNKNOWN;
        uav.ViewDimension = D3D11_UAV_DIMENSION_BUFFER;
        uav.Buffer.NumElements = elements;
        winrt::check_hresult(device->CreateUnorderedAccessView(output.get(), &uav, output_uav.put()));
        D3D11_BUFFER_DESC read{};
        read.ByteWidth = elements * 4;
        read.Usage = D3D11_USAGE_STAGING;
        read.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        read.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
        read.StructureByteStride = 4;
        winrt::check_hresult(device->CreateBuffer(&read, nullptr, staging.put()));
        output_elements = elements;
    }

    winrt::com_ptr<ID3D11ShaderResourceView> view(void *texture, DXGI_FORMAT format) {
        winrt::com_ptr<ID3D11ShaderResourceView> srv;
        if (!texture) return srv;
        D3D11_SHADER_RESOURCE_VIEW_DESC desc{};
        desc.Format = format;
        desc.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
        desc.Texture2D.MipLevels = 1;
        winrt::check_hresult(device->CreateShaderResourceView(static_cast<ID3D11Texture2D *>(texture),
                                                              format == DXGI_FORMAT_UNKNOWN ? nullptr : &desc, srv.put()));
        return srv;
    }

    // Binds, dispatches each (constants, groups) in turn, and reads `elements` back into `out`.
    void run(ID3D11ComputeShader *shader, void *reference, void *recon, void *wire,
             const std::vector<std::pair<Constants, std::pair<UINT, UINT>>> &dispatches, uint32_t elements, void *out) {
        ensure_output(elements);
        auto ref_srv = view(reference, DXGI_FORMAT_UNKNOWN);
        auto y_srv = view(recon, DXGI_FORMAT_R8_UNORM);
        auto uv_srv = view(recon, DXGI_FORMAT_R8G8_UNORM);
        auto wire_srv = view(wire ? wire : reference, DXGI_FORMAT_UNKNOWN);
        multithread->Enter();
        struct Leave {
            ID3D11Multithread *m;
            ~Leave() { m->Leave(); }
        } leave{multithread.get()};
        ID3D11DeviceContext *ctx = context.get();
        ctx->ClearState();
        ID3D11ShaderResourceView *views[] = {ref_srv.get(), y_srv.get(), uv_srv.get(), wire_srv.get()};
        ID3D11UnorderedAccessView *uavs[] = {output_uav.get()};
        ID3D11SamplerState *samplers[] = {sampler.get()};
        ID3D11Buffer *buffers[] = {constants.get()};
        ctx->CSSetShader(shader, nullptr, 0);
        ctx->CSSetShaderResources(0, 4, views);
        ctx->CSSetUnorderedAccessViews(0, 1, uavs, nullptr);
        ctx->CSSetSamplers(0, 1, samplers);
        ctx->CSSetConstantBuffers(0, 1, buffers);
        for (const auto &[c, groups] : dispatches) {
            D3D11_MAPPED_SUBRESOURCE mapped{};
            winrt::check_hresult(ctx->Map(constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
            std::memcpy(mapped.pData, &c, sizeof c);
            ctx->Unmap(constants.get(), 0);
            ctx->Dispatch(groups.first, groups.second, 1);
        }
        ctx->ClearState();
        D3D11_BOX range{0, 0, 0, elements * 4, 1, 1};
        ctx->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, output.get(), 0, &range);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
        std::memcpy(out, mapped.pData, static_cast<size_t>(elements) * 4);
        ctx->Unmap(staging.get(), 0);
    }
};

namespace {

bool valid_box(const lw_quality_box &b, const lw_quality_eyes &e) {
    return (b.eye == 0 || b.eye == 1) && b.size > 0 && b.size % 16 == 0 && b.size <= 4096 && e.render_eye_width > 0 &&
           e.render_eye_height > 0 && e.wire_eye_width > 0 && e.wire_eye_height > 0 && b.axis_x[2] >= 1 &&
           b.axis_y[2] >= 1 && b.axis_x[3] > 0 && b.axis_y[3] > 0;
}

Constants box_constants(const lw_quality_box &b, const lw_quality_eyes &e, uint32_t first_tile) {
    Constants c{};
    c.box[0] = b.eye;
    c.box[1] = b.x;
    c.box[2] = b.y;
    c.box[3] = b.size;
    std::memcpy(c.axis_x, b.axis_x, sizeof c.axis_x);
    std::memcpy(c.axis_y, b.axis_y, sizeof c.axis_y);
    c.eyes[0] = e.render_eye_width;
    c.eyes[1] = e.render_eye_height;
    c.eyes[2] = e.wire_eye_width;
    c.eyes[3] = e.wire_eye_height;
    c.extent[3] = static_cast<int32_t>(first_tile);
    return c;
}

} // namespace

extern "C" lw_status lw_quality_create(lw_device *device, lw_quality **out) {
    if (!device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_quality_create: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_quality_create", [&]() -> lw_status {
        auto q = std::make_unique<lw_quality>();
        q->device = device->device;
        q->context = device->context;
        q->multithread = device->device.as<ID3D11Multithread>();
        for (auto [entry, shader] : {std::pair{"cs_wire", &q->wire_cs}, std::pair{"cs_gaze", &q->gaze_cs},
                                     std::pair{"cs_crop", &q->crop_cs}}) {
            auto code = compile(entry);
            winrt::check_hresult(q->device->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr,
                                                                shader->put()));
        }
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Constants);
        buffer.Usage = D3D11_USAGE_DYNAMIC;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        winrt::check_hresult(q->device->CreateBuffer(&buffer, nullptr, q->constants.put()));
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        winrt::check_hresult(q->device->CreateSamplerState(&sampler, q->sampler.put()));
        *out = q.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_quality_wire(lw_quality *quality, void *reference, void *recon, float *out, uint32_t capacity) {
    if (!quality || !reference || !recon || !out) return lw::fail(LW_E_INVALID_ARG, "lw_quality_wire: NULL argument");
    return lw::guarded("lw_quality_wire", [&]() -> lw_status {
        D3D11_TEXTURE2D_DESC a{}, b{};
        static_cast<ID3D11Texture2D *>(reference)->GetDesc(&a);
        static_cast<ID3D11Texture2D *>(recon)->GetDesc(&b);
        if (a.Width != b.Width || a.Height != b.Height || b.Format != DXGI_FORMAT_NV12 || a.Format != DXGI_FORMAT_B8G8R8A8_UNORM)
            return lw::fail(LW_E_INVALID_ARG, "lw_quality_wire: want a BGRA8 reference and an NV12 recon of one size");
        const UINT across = (a.Width + 15) / 16, down = (a.Height + 15) / 16;
        const uint32_t floats = across * down * 4;
        if (capacity < floats) return lw::fail(LW_E_INVALID_ARG, "lw_quality_wire: needs %u floats", floats);
        Constants c{};
        c.extent[0] = static_cast<int32_t>(a.Width);
        c.extent[1] = static_cast<int32_t>(a.Height);
        c.extent[2] = static_cast<int32_t>(across);
        quality->run(quality->wire_cs.get(), reference, recon, nullptr, {{c, {across, down}}}, floats, out);
        return LW_OK;
    });
}

extern "C" lw_status lw_quality_gaze(lw_quality *quality, void *truth, void *wire, void *recon, const lw_quality_eyes *eyes,
                                     const lw_quality_box *boxes, uint32_t count, float *out, uint32_t capacity) {
    if (!quality || !truth || !wire || !recon || !eyes || (count && !boxes) || !out)
        return lw::fail(LW_E_INVALID_ARG, "lw_quality_gaze: NULL argument");
    return lw::guarded("lw_quality_gaze", [&]() -> lw_status {
        std::vector<std::pair<Constants, std::pair<UINT, UINT>>> dispatches;
        uint32_t tiles = 0;
        for (uint32_t i = 0; i < count; i++) {
            if (!valid_box(boxes[i], *eyes)) return lw::fail(LW_E_INVALID_ARG, "lw_quality_gaze: box %u is invalid", i);
            const UINT side = static_cast<UINT>(boxes[i].size / 16);
            dispatches.push_back({box_constants(boxes[i], *eyes, tiles), {side, side}});
            tiles += side * side;
        }
        if (capacity < tiles * 8) return lw::fail(LW_E_INVALID_ARG, "lw_quality_gaze: needs %u floats", tiles * 8);
        if (tiles == 0) return LW_OK;
        quality->run(quality->gaze_cs.get(), truth, recon, wire, dispatches, tiles * 8, out);
        return LW_OK;
    });
}

extern "C" lw_status lw_quality_crop(lw_quality *quality, void *truth, void *recon, const lw_quality_eyes *eyes,
                                     const lw_quality_box *box, uint8_t *truth_out, uint8_t *shown_out) {
    if (!quality || !truth || !recon || !eyes || !box || !truth_out || !shown_out)
        return lw::fail(LW_E_INVALID_ARG, "lw_quality_crop: NULL argument");
    if (!valid_box(*box, *eyes)) return lw::fail(LW_E_INVALID_ARG, "lw_quality_crop: invalid box");
    return lw::guarded("lw_quality_crop", [&]() -> lw_status {
        const UINT side = static_cast<UINT>(box->size / 16);
        const uint32_t pixels = static_cast<uint32_t>(box->size * box->size);
        std::vector<uint32_t> both(pixels * 2);
        quality->run(quality->crop_cs.get(), truth, recon, nullptr, {{box_constants(*box, *eyes, 0), {side, side}}},
                     pixels * 2, both.data());
        std::memcpy(truth_out, both.data(), static_cast<size_t>(pixels) * 4);
        std::memcpy(shown_out, both.data() + pixels, static_cast<size_t>(pixels) * 4);
        return LW_OK;
    });
}

extern "C" void lw_quality_release(lw_quality *quality) { delete quality; }
