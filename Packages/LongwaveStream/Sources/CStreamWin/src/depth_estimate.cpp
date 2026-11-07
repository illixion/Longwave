// lw_depth_*: a PCVR frame's depth for the depthVideo stream (NATIVE_V3_PROTOCOL.md
// section 4.8; the headset displaces its eye meshes by it, so near content
// keeps its parallax when the head moves away from the render pose).
//
// Two sources, one output: grey BGRA8, both eyes side by side at depth size,
// each in its own render frustum, holding v = near / z.
//
// Stereo, for games that submit no depth (most Unity titles):
//   1. cs_luma: both eyes resampled to luminance on one tangent grid that
//      spans both frusta at the depth eye's spacing. On that grid a point's
//      two images differ by a horizontal shift alone (the eyes look the same
//      way; only their frusta differ), its disparity, baseline / z in tangent.
//   2. cs_match: per eye, a 5x5 sum of absolute differences against the
//      other eye at every candidate shift, the minimum refined by a parabola.
//      Texels without texture, or without a clear minimum, are left unknown.
//   3. ps_resolve: per output texel, its grid disparity if it passes the
//      left-right check, else the farther of the nearest good ones along its
//      row (an occlusion hides background), encoded as inverse depth.
// Linear, for games that submit depth (the broker's composite of it, metres):
//   ps_linear: the nearest depth under each output texel.
//
// Shaders are compiled from source once per instance with D3DCompile, like the
// foveation warp's.
#include "common.hpp"

#include <d3dcompiler.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace {

const char kShader[] = R"hlsl(
cbuffer DepthConstants : register(b0) {
    float4 tangents[2]; // per eye: left, right, up, down
    float4 grid;        // x0 (left edge, tangent), dx (tangent per texel), y0 (top edge), dy
    float4 sizes;       // per pass, see each entry point
    float4 extra;       // per pass
    int4 info;          // cs_match: grid width, grid height, max disparity, eye
};
SamplerState linearClamp : register(s0);

// ---- 1. luminance on the shared tangent grid; sizes: source eye w, h, grid w, h; extra: 1/source w, 1/source h
Texture2D<float4> colour : register(t0);
RWTexture2D<float> lumaOut : register(u0);

[numthreads(8, 8, 1)]
void cs_luma(uint3 id : SV_DispatchThreadID) {
    uint gw = (uint)sizes.z, gh = (uint)sizes.w;
    if (id.x >= 2 * gw || id.y >= gh) return;
    uint eye = id.x >= gw ? 1 : 0;
    float tx = grid.x + (id.x - eye * gw + 0.5) * grid.y;
    float ty = grid.z - (id.y + 0.5) * grid.w;
    float4 t = tangents[eye];
    float2 uv = float2((tx - t.x) / (t.y - t.x), (t.z - ty) / (t.z - t.w));
    if (any(uv < 0) || any(uv > 1)) { lumaOut[id.xy] = -1; return; } // outside this eye's frustum
    float2 eyeSize = sizes.xy;
    float2 footprint = float2(grid.y / (t.y - t.x), grid.w / (t.z - t.w)) * eyeSize;
    float2 centre = float2(eye * eyeSize.x, 0) + uv * eyeSize;
    float2 lo = float2(eye * eyeSize.x + 0.5, 0.5), hi = float2((eye + 1) * eyeSize.x - 0.5, eyeSize.y - 0.5);
    float sum = 0;
    [unroll] for (int j = 0; j < 4; j++) {
        [unroll] for (int i = 0; i < 4; i++) {
            float2 p = clamp(centre + (float2(i, j) - 1.5) * 0.25 * footprint, lo, hi);
            sum += dot(colour.SampleLevel(linearClamp, p * extra.xy, 0).rgb, float3(0.299, 0.587, 0.114));
        }
    }
    lumaOut[id.xy] = sum / 16;
}

// ---- 2. block matching, one eye per dispatch; info: grid w, h, max disparity, eye
#define TILE 64
#define RADIUS 2
#define WINDOW (2 * RADIUS + 1)
#define MAX_DISPARITY 128
Texture2D<float> lumaIn : register(t0);
RWTexture2D<float> disparityOut : register(u0);
groupshared float own[WINDOW][TILE + 2 * RADIUS];
groupshared float other[WINDOW][TILE + 2 * RADIUS + MAX_DISPARITY - 1];

float fetch(int base, int x, int y, int gw) {
    return (x < 0 || x >= gw) ? -1 : lumaIn.Load(int3(base + x, y, 0));
}

[numthreads(TILE, 1, 1)]
void cs_match(uint3 group : SV_GroupID, uint3 thread : SV_GroupThreadID) {
    int gw = info.x, gh = info.y, maxD = info.z, eye = info.w;
    int x0 = group.x * TILE, y = group.y, t = thread.x;
    int ownBase = eye * gw, otherBase = (1 - eye) * gw;
    // The left eye's match sits left of it on the grid (x - d), the right eye's right (x + d).
    int otherStart = eye == 0 ? x0 - RADIUS - (maxD - 1) : x0 - RADIUS;
    int otherWidth = TILE + 2 * RADIUS + maxD - 1;
    [unroll] for (int row = 0; row < WINDOW; row++) {
        int yy = clamp(y - RADIUS + row, 0, gh - 1);
        for (int i = t; i < TILE + 2 * RADIUS; i += TILE) own[row][i] = fetch(ownBase, x0 - RADIUS + i, yy, gw);
        for (int k = t; k < otherWidth; k += TILE) other[row][k] = fetch(otherBase, otherStart + k, yy, gw);
    }
    GroupMemoryBarrierWithGroupSync();
    int x = x0 + t;
    if (x >= gw) return;
    int2 target = int2(ownBase + x, y);

    float lo = 2, hi = -2;
    bool inside = true;
    [unroll] for (int r = 0; r < WINDOW; r++) {
        [unroll] for (int c = 0; c < WINDOW; c++) {
            float a = own[r][t + c];
            inside = inside && a >= 0;
            lo = min(lo, a);
            hi = max(hi, a);
        }
    }
    // At the frustum's edge, or flat: nothing to match on.
    if (!inside || hi - lo < 0.02) { disparityOut[target] = -1; return; }

    float best = 1e30, before = 1e30, after = 1e30, previous = 1e30, total = 0;
    int bestD = -1;
    bool captureAfter = false;
    for (int d = 0; d < maxD; d++) {
        int shift = eye == 0 ? (maxD - 1) - d : d;
        float cost = 0;
        [unroll] for (int r2 = 0; r2 < WINDOW; r2++) {
            [unroll] for (int c2 = 0; c2 < WINDOW; c2++) {
                float b = other[r2][t + c2 + shift];
                cost += b < 0 ? 1 : abs(own[r2][t + c2] - b);
            }
        }
        if (captureAfter) { after = cost; captureAfter = false; }
        if (cost < best) { best = cost; bestD = d; before = previous; captureAfter = true; }
        total += cost;
        previous = cost;
    }
    // No clear winner (repeating or faint texture): unknown rather than a guess.
    if (bestD < 0 || best > 0.8 * total / maxD) { disparityOut[target] = -1; return; }
    float sub = 0;
    if (bestD > 0 && bestD < maxD - 1) {
        float curvature = before - 2 * best + after;
        if (curvature > 1e-6) sub = clamp(0.5 * (before - after) / curvature, -0.5, 0.5);
    }
    disparityOut[target] = bestD + sub;
}

// ---- full-screen triangle for the output passes
float4 vs_main(uint id : SV_VertexID) : SV_Position {
    float2 uv = float2((id << 1) & 2, id & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

// ---- 3. resolve; sizes: depth eye w, h, grid w, h; extra: v per grid texel of disparity, tolerance, fill radius
Texture2D<float> disparityIn : register(t0);

float disparityAt(int eye, int gx, int gy, int gw) {
    return (gx < 0 || gx >= gw) ? -1 : disparityIn.Load(int3(eye * gw + gx, gy, 0));
}

// The other eye, at the texel this disparity points to, agrees.
float agreed(int eye, int gx, int gy, int gw) {
    float d = disparityAt(eye, gx, gy, gw);
    if (d < 0) return -1;
    int partner = eye == 0 ? gx - (int)round(d) : gx + (int)round(d);
    float e = disparityAt(1 - eye, partner, gy, gw);
    return (e >= 0 && abs(e - d) <= extra.y) ? d : -1;
}

float4 ps_resolve(float4 position : SV_Position) : SV_Target {
    int eye = position.x >= sizes.x ? 1 : 0;
    float2 uv = float2(position.x - eye * sizes.x, position.y) / sizes.xy;
    float4 t = tangents[eye];
    float tx = t.x + uv.x * (t.y - t.x), ty = t.z - uv.y * (t.z - t.w);
    int gw = (int)sizes.z, gh = (int)sizes.w;
    int gx = clamp((int)floor((tx - grid.x) / grid.y), 0, gw - 1);
    int gy = clamp((int)floor((grid.z - ty) / grid.w), 0, gh - 1);
    float d = agreed(eye, gx, gy, gw);
    if (d < 0) {
        float left = -1, right = -1;
        int radius = (int)extra.z;
        for (int k = 1; k <= radius && (left < 0 || right < 0); k++) {
            if (left < 0) left = agreed(eye, gx - k, gy, gw);
            if (right < 0) right = agreed(eye, gx + k, gy, gw);
        }
        d = (left >= 0 && right >= 0) ? min(left, right) : max(max(left, right), 0);
    }
    float v = saturate(d * extra.x);
    return float4(v, v, v, 1);
}

// ---- linear; sizes: depth eye w, h, source eye w, h; extra: near
Texture2D<float> metres : register(t0);

float4 ps_linear(float4 position : SV_Position) : SV_Target {
    int eye = position.x >= sizes.x ? 1 : 0;
    float2 cell = float2(position.x - 0.5 - eye * sizes.x, position.y - 0.5);
    float2 scale = sizes.zw / sizes.xy;
    int2 a = int2(floor(cell * scale));
    int2 b = max(a, int2(ceil((cell + 1) * scale)) - 1);
    b = min(b, a + 7); // at most 8x8 source texels per output texel
    int2 limit = int2(sizes.zw) - 1;
    float nearest = 1e30;
    for (int y = a.y; y <= b.y; y++) {
        for (int x = a.x; x <= b.x; x++) {
            int2 p = clamp(int2(x, y), 0, limit);
            float z = metres.Load(int3(eye * (int)sizes.z + p.x, p.y, 0));
            if (z > 0) nearest = min(nearest, z);
        }
    }
    float v = nearest < 1e30 ? saturate(extra.x / nearest) : 0;
    return float4(v, v, v, 1);
}
)hlsl";

struct Constants {
    float tangents[2][4];
    float grid[4];
    float sizes[4];
    float extra[4];
    int32_t info[4];
};
static_assert(sizeof(Constants) % 16 == 0, "constant buffers are 16-byte multiples");

constexpr int kTile = 64;
constexpr int kMaxDisparity = 128;

winrt::com_ptr<ID3DBlob> compile(const char *entry, const char *target) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "depth_estimate.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

bool valid_frustum(const float t[4]) {
    return std::isfinite(t[0]) && std::isfinite(t[1]) && std::isfinite(t[2]) && std::isfinite(t[3]) && t[0] < t[1] &&
           t[3] < t[2];
}

} // namespace

struct lw_depth {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11Multithread> multithread;
    winrt::com_ptr<ID3D11ComputeShader> luma, match;
    winrt::com_ptr<ID3D11VertexShader> vertex;
    winrt::com_ptr<ID3D11PixelShader> resolve, linear;
    winrt::com_ptr<ID3D11Buffer> constants;
    winrt::com_ptr<ID3D11SamplerState> sampler;
    winrt::com_ptr<ID3D11RasterizerState> rasterizer;
    // The grid's intermediates, remade when the grid's size changes.
    int grid_width = 0, grid_height = 0;
    winrt::com_ptr<ID3D11Texture2D> luma_texture, disparity_texture;
    winrt::com_ptr<ID3D11ShaderResourceView> luma_srv, disparity_srv;
    winrt::com_ptr<ID3D11UnorderedAccessView> luma_uav, disparity_uav;
    // GPU time per apply: a few frames of timestamp queries in flight, read
    // back without waiting once the GPU has passed them.
    struct Timing {
        winrt::com_ptr<ID3D11Query> disjoint, begin, end, luma_done, match_done;
        bool pending = false;
        bool stereo = false;
    };
    float pass_milliseconds[3] = {-1, -1, -1}; // luminance, matching, output
    Timing timings[4];
    int next_timing = 0;
    float gpu_milliseconds = -1;

    void collect(ID3D11DeviceContext *ctx) {
        for (auto &t : timings) {
            if (!t.pending) continue;
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint{};
            UINT64 begin = 0, end = 0;
            if (ctx->GetData(t.disjoint.get(), &disjoint, sizeof disjoint, D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK ||
                ctx->GetData(t.begin.get(), &begin, sizeof begin, D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK ||
                ctx->GetData(t.end.get(), &end, sizeof end, D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK)
                continue;
            UINT64 luma = begin, match = begin;
            if (t.stereo && (ctx->GetData(t.luma_done.get(), &luma, sizeof luma, D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK ||
                             ctx->GetData(t.match_done.get(), &match, sizeof match, D3D11_ASYNC_GETDATA_DONOTFLUSH) != S_OK))
                continue;
            t.pending = false;
            if (!disjoint.Disjoint && disjoint.Frequency > 0 && end >= begin) {
                auto ms = [&](UINT64 a, UINT64 b) {
                    return static_cast<float>(static_cast<double>(b - a) * 1000.0 / static_cast<double>(disjoint.Frequency));
                };
                gpu_milliseconds = ms(begin, end);
                pass_milliseconds[0] = t.stereo ? ms(begin, luma) : 0;
                pass_milliseconds[1] = t.stereo ? ms(luma, match) : 0;
                pass_milliseconds[2] = t.stereo ? ms(match, end) : ms(begin, end);
            }
        }
    }

    Timing *start_timing(ID3D11DeviceContext *ctx) {
        Timing &t = timings[next_timing];
        if (t.pending) return nullptr; // still in flight four frames later: skip one
        if (!t.disjoint) {
            D3D11_QUERY_DESC desc{D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
            if (FAILED(device->CreateQuery(&desc, t.disjoint.put()))) return nullptr;
            desc.Query = D3D11_QUERY_TIMESTAMP;
            if (FAILED(device->CreateQuery(&desc, t.begin.put())) || FAILED(device->CreateQuery(&desc, t.end.put())) ||
                FAILED(device->CreateQuery(&desc, t.luma_done.put())) || FAILED(device->CreateQuery(&desc, t.match_done.put())))
                return nullptr;
        }
        next_timing = (next_timing + 1) % 4;
        ctx->Begin(t.disjoint.get());
        ctx->End(t.begin.get());
        return &t;
    }

    static void finish_timing(ID3D11DeviceContext *ctx, Timing *t) {
        if (!t) return;
        ctx->End(t->end.get());
        ctx->End(t->disjoint.get());
        t->pending = true;
    }

    void make_grid(int width, int height) {
        if (width == grid_width && height == grid_height) return;
        auto make = [&](winrt::com_ptr<ID3D11Texture2D> &texture, winrt::com_ptr<ID3D11ShaderResourceView> &srv,
                        winrt::com_ptr<ID3D11UnorderedAccessView> &uav) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = static_cast<UINT>(2 * width);
            desc.Height = static_cast<UINT>(height);
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_R32_FLOAT;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
            texture = nullptr;
            srv = nullptr;
            uav = nullptr;
            winrt::check_hresult(device->CreateTexture2D(&desc, nullptr, texture.put()));
            winrt::check_hresult(device->CreateShaderResourceView(texture.get(), nullptr, srv.put()));
            winrt::check_hresult(device->CreateUnorderedAccessView(texture.get(), nullptr, uav.put()));
        };
        make(luma_texture, luma_srv, luma_uav);
        make(disparity_texture, disparity_srv, disparity_uav);
        grid_width = width;
        grid_height = height;
    }

    void upload(ID3D11DeviceContext *ctx, const Constants &c) {
        D3D11_MAPPED_SUBRESOURCE mapped{};
        winrt::check_hresult(ctx->Map(constants.get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped));
        std::memcpy(mapped.pData, &c, sizeof c);
        ctx->Unmap(constants.get(), 0);
    }
};

extern "C" lw_status lw_depth_create(lw_device *device, lw_depth **out) {
    if (!device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_depth_create: NULL argument");
    *out = nullptr;
    return lw::guarded("lw_depth_create", [&]() -> lw_status {
        auto depth = std::make_unique<lw_depth>();
        depth->device = device->device;
        depth->context = device->context;
        depth->multithread = device->device.as<ID3D11Multithread>();
        auto luma = compile("cs_luma", "cs_5_0");
        auto match = compile("cs_match", "cs_5_0");
        auto vs = compile("vs_main", "vs_5_0");
        auto resolve = compile("ps_resolve", "ps_5_0");
        auto linear = compile("ps_linear", "ps_5_0");
        auto &d = depth->device;
        winrt::check_hresult(d->CreateComputeShader(luma->GetBufferPointer(), luma->GetBufferSize(), nullptr,
                                                    depth->luma.put()));
        winrt::check_hresult(d->CreateComputeShader(match->GetBufferPointer(), match->GetBufferSize(), nullptr,
                                                    depth->match.put()));
        winrt::check_hresult(d->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr,
                                                   depth->vertex.put()));
        winrt::check_hresult(d->CreatePixelShader(resolve->GetBufferPointer(), resolve->GetBufferSize(), nullptr,
                                                  depth->resolve.put()));
        winrt::check_hresult(d->CreatePixelShader(linear->GetBufferPointer(), linear->GetBufferSize(), nullptr,
                                                  depth->linear.put()));
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = sizeof(Constants);
        buffer.Usage = D3D11_USAGE_DYNAMIC;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        buffer.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        winrt::check_hresult(d->CreateBuffer(&buffer, nullptr, depth->constants.put()));
        D3D11_SAMPLER_DESC sampler{};
        sampler.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler.MaxLOD = D3D11_FLOAT32_MAX;
        winrt::check_hresult(d->CreateSamplerState(&sampler, depth->sampler.put()));
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        winrt::check_hresult(d->CreateRasterizerState(&raster, depth->rasterizer.put()));
        *out = depth.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_depth_apply(lw_depth *depth, void *source, void *destination, const lw_depth_params *params) {
    if (!depth || !source || !destination || !params) return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: NULL argument");
    const lw_depth_params &p = *params;
    if (p.source_kind != LW_DEPTH_STEREO && p.source_kind != LW_DEPTH_LINEAR)
        return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: unknown source kind %u", p.source_kind);
    if (p.source_eye_width <= 0 || p.source_eye_height <= 0 || p.depth_eye_width <= 0 || p.depth_eye_height <= 0)
        return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: empty eye size");
    if (!valid_frustum(p.tangents[0]) || !valid_frustum(p.tangents[1]))
        return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: bad frustum");
    if (!(p.near_depth > 0) || !std::isfinite(p.near_depth)) return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: bad near depth");
    if (p.source_kind == LW_DEPTH_STEREO &&
        (!(p.baseline > 0) || !std::isfinite(p.baseline) || p.max_disparity < 1 || p.max_disparity > kMaxDisparity))
        return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: bad baseline or disparity range");
    return lw::guarded("lw_depth_apply", [&]() -> lw_status {
        auto *src = static_cast<ID3D11Texture2D *>(source);
        auto *dst = static_cast<ID3D11Texture2D *>(destination);
        D3D11_TEXTURE2D_DESC sd{}, dd{};
        src->GetDesc(&sd);
        dst->GetDesc(&dd);
        if (sd.Width < static_cast<UINT>(2 * p.source_eye_width) || sd.Height < static_cast<UINT>(p.source_eye_height))
            return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: source %ux%u is smaller than two %dx%d eyes", sd.Width,
                            sd.Height, p.source_eye_width, p.source_eye_height);
        if (dd.Width < static_cast<UINT>(2 * p.depth_eye_width) || dd.Height < static_cast<UINT>(p.depth_eye_height))
            return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: destination %ux%u is smaller than two %dx%d eyes",
                            dd.Width, dd.Height, p.depth_eye_width, p.depth_eye_height);
        if (p.source_kind == LW_DEPTH_LINEAR && sd.Format != DXGI_FORMAT_R32_FLOAT && sd.Format != DXGI_FORMAT_R16_FLOAT)
            return lw::fail(LW_E_INVALID_ARG, "lw_depth_apply: linear depth must be R32F or R16F (format %d)",
                            static_cast<int>(sd.Format));

        winrt::com_ptr<ID3D11ShaderResourceView> srv;
        winrt::check_hresult(depth->device->CreateShaderResourceView(src, nullptr, srv.put()));
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(depth->device->CreateRenderTargetView(dst, nullptr, rtv.put()));

        Constants c{};
        std::memcpy(c.tangents, p.tangents, sizeof c.tangents);
        const float *tl = p.tangents[0], *tr = p.tangents[1];
        // The grid: the left depth eye's spacing, wide and tall enough for both frusta.
        const float dx = (tl[1] - tl[0]) / static_cast<float>(p.depth_eye_width);
        const float dy = (tl[2] - tl[3]) / static_cast<float>(p.depth_eye_height);
        const float x0 = std::min(tl[0], tr[0]), x1 = std::max(tl[1], tr[1]);
        const float y0 = std::max(tl[2], tr[2]), y1 = std::min(tl[3], tr[3]);
        const int grid_width = std::clamp(static_cast<int>(std::ceil((x1 - x0) / dx)), 1, 4096);
        const int grid_height = std::clamp(static_cast<int>(std::ceil((y0 - y1) / dy)), 1, 4096);
        c.grid[0] = x0;
        c.grid[1] = dx;
        c.grid[2] = y0;
        c.grid[3] = dy;

        depth->multithread->Enter();
        struct Leave {
            ID3D11Multithread *m;
            ~Leave() { m->Leave(); }
        } leave{depth->multithread.get()};
        ID3D11DeviceContext *ctx = depth->context.get();
        ID3D11Buffer *buffers[] = {depth->constants.get()};
        ID3D11SamplerState *samplers[] = {depth->sampler.get()};
        ID3D11ShaderResourceView *null_srv[] = {nullptr};
        ID3D11UnorderedAccessView *null_uav[] = {nullptr};
        ctx->ClearState();
        depth->collect(ctx);
        lw_depth::Timing *timing = depth->start_timing(ctx);

        ID3D11PixelShader *output = depth->linear.get();
        ID3D11ShaderResourceView *output_input = srv.get();
        if (p.source_kind == LW_DEPTH_STEREO) {
            depth->make_grid(grid_width, grid_height);
            // 1. luminance on the grid
            c.sizes[0] = static_cast<float>(p.source_eye_width);
            c.sizes[1] = static_cast<float>(p.source_eye_height);
            c.sizes[2] = static_cast<float>(grid_width);
            c.sizes[3] = static_cast<float>(grid_height);
            c.extra[0] = 1.0f / static_cast<float>(sd.Width);
            c.extra[1] = 1.0f / static_cast<float>(sd.Height);
            depth->upload(ctx, c);
            ID3D11ShaderResourceView *colour[] = {srv.get()};
            ID3D11UnorderedAccessView *luma[] = {depth->luma_uav.get()};
            ctx->CSSetShader(depth->luma.get(), nullptr, 0);
            ctx->CSSetConstantBuffers(0, 1, buffers);
            ctx->CSSetSamplers(0, 1, samplers);
            ctx->CSSetShaderResources(0, 1, colour);
            ctx->CSSetUnorderedAccessViews(0, 1, luma, nullptr);
            ctx->Dispatch(static_cast<UINT>((2 * grid_width + 7) / 8), static_cast<UINT>((grid_height + 7) / 8), 1);
            ctx->CSSetShaderResources(0, 1, null_srv);
            ctx->CSSetUnorderedAccessViews(0, 1, null_uav, nullptr);
            if (timing) ctx->End(timing->luma_done.get());

            // 2. matching, each eye against the other
            ID3D11ShaderResourceView *lumaIn[] = {depth->luma_srv.get()};
            ID3D11UnorderedAccessView *disparity[] = {depth->disparity_uav.get()};
            ctx->CSSetShader(depth->match.get(), nullptr, 0);
            ctx->CSSetShaderResources(0, 1, lumaIn);
            ctx->CSSetUnorderedAccessViews(0, 1, disparity, nullptr);
            for (int eye = 0; eye < 2; eye++) {
                c.info[0] = grid_width;
                c.info[1] = grid_height;
                c.info[2] = p.max_disparity;
                c.info[3] = eye;
                depth->upload(ctx, c);
                ctx->Dispatch(static_cast<UINT>((grid_width + kTile - 1) / kTile), static_cast<UINT>(grid_height), 1);
            }
            ctx->CSSetShaderResources(0, 1, null_srv);
            ctx->CSSetUnorderedAccessViews(0, 1, null_uav, nullptr);
            ctx->CSSetShader(nullptr, nullptr, 0);
            if (timing) {
                ctx->End(timing->match_done.get());
                timing->stereo = true;
            }

            // 3. resolve: disparity in grid texels -> tangent -> 1/z -> near/z
            c.sizes[0] = static_cast<float>(p.depth_eye_width);
            c.sizes[1] = static_cast<float>(p.depth_eye_height);
            c.extra[0] = dx * p.near_depth / p.baseline;
            c.extra[1] = 1.5f; // left-right agreement, grid texels
            c.extra[2] = 32;   // how far along a row a hole is filled from
            c.extra[3] = 0;
            output = depth->resolve.get();
            output_input = depth->disparity_srv.get();
        } else {
            if (timing) timing->stereo = false;
            c.sizes[0] = static_cast<float>(p.depth_eye_width);
            c.sizes[1] = static_cast<float>(p.depth_eye_height);
            c.sizes[2] = static_cast<float>(p.source_eye_width);
            c.sizes[3] = static_cast<float>(p.source_eye_height);
            c.extra[0] = p.near_depth;
        }
        depth->upload(ctx, c);
        D3D11_VIEWPORT viewport{0, 0, static_cast<float>(2 * p.depth_eye_width), static_cast<float>(p.depth_eye_height),
                                0, 1};
        ID3D11RenderTargetView *targets[] = {rtv.get()};
        ID3D11ShaderResourceView *views[] = {output_input};
        ctx->OMSetRenderTargets(1, targets, nullptr);
        ctx->RSSetViewports(1, &viewport);
        ctx->RSSetState(depth->rasterizer.get());
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(depth->vertex.get(), nullptr, 0);
        ctx->PSSetShader(output, nullptr, 0);
        ctx->PSSetConstantBuffers(0, 1, buffers);
        ctx->PSSetShaderResources(0, 1, views);
        ctx->Draw(3, 0);
        lw_depth::finish_timing(ctx, timing);
        ctx->ClearState(); // unbinds the destination, so NVENC may use it
        ctx->Flush();
        return LW_OK;
    });
}

extern "C" float lw_depth_gpu_milliseconds(lw_depth *depth) {
    if (!depth) return -1;
    depth->multithread->Enter();
    depth->collect(depth->context.get());
    depth->multithread->Leave();
    return depth->gpu_milliseconds;
}

extern "C" void lw_depth_pass_milliseconds(lw_depth *depth, float out[3]) {
    if (!depth || !out) return;
    depth->multithread->Enter();
    depth->collect(depth->context.get());
    depth->multithread->Leave();
    std::memcpy(out, depth->pass_milliseconds, sizeof depth->pass_milliseconds);
}

extern "C" void lw_depth_release(lw_depth *depth) { delete depth; }
