// SPIKE ONLY: a world-locked test scene for the PCVR path (lw_spike_scene_*),
// drawn by `frame-source-spike scene` in place of the session broker: each
// eye ray-cast from the pose the headset sent, so nothing between the headset
// and the host's frame source (game, OpenXR runtime, shim, broker) is involved.
//
// The scene, in the headset's world space (metres, y up, -z ahead of where
// its world tracking started):
//   - a floor checker of 0.5 m tiles and a grid-lined room 12 m across;
//   - four panels of dot-matrix "text" facing the origin, at 1.2 m ahead
//     (-z), 2 m to the right (+x), 3 m behind (+z) and 0.7 m to the left
//     (-x), each 1.0 x 0.6 m with its centre 1.4 m up, a black border and
//     red corner crosses (lw_spike_scene_marker gives their positions);
//   - a spoked wheel 0.3 m across beside the front panel turning at half a
//     turn per second of the frame clock: animation smoothness at a glance.
// Four samples per pixel, so the text doesn't alias into a shimmer that would
// read as shaking.
//
// Stamp: in each eye, a row of 18 blocks near the top and another near the
// bottom of the eye's render image (render UV v 0.020-0.035 and 0.965-0.980,
// block i at u 0.30 + 0.022 i, 0.020 wide): block 0 white, block 17 black,
// blocks 1-16 the low 16 bits of the pose sequence the frame was rendered
// from, most significant first, white for 1. Both rows of both eyes carry the
// same value, so a receiver can tell a frame torn top to bottom, eyes from
// different frames, and a picture paired with another frame's render pose.
//
// The depth output (R32_FLOAT, metres along each eye's view axis, 0 where
// there is only sky) is the host's "depth from the game" path: exact.
#include "common.hpp"

#include <d3dcompiler.h>

#include <cmath>
#include <cstring>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace {

const char kShader[] = R"hlsl(
cbuffer SceneConstants : register(b0) {
    float4 orientation; // eye, world from eye, quaternion xyzw
    float4 positionTime; // eye position (world), w = display time, seconds
    float4 tangents;    // left, right, up, down
    float4 viewport;    // x, y, width, height of this eye in the target, pixels
    uint4 info;         // stamp value, draw the stamp, 0, 0
};

float3 rotate(float4 q, float3 v) {
    float3 u = q.xyz;
    float3 c = cross(u, v);
    return v + 2.0 * (q.w * c + cross(u, c));
}

float hash(float2 p) {
    p = frac(p * float2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return frac((p.x + p.y) * p.x);
}

struct Hit { float t; float3 colour; };

// One panel: centre c, normal n (toward the viewer), right r; half sizes 0.5 x 0.3.
void panel(float3 o, float3 d, float3 c, float3 n, float3 r, float seed, inout Hit hit) {
    float denom = dot(d, n);
    if (denom >= -1e-5) return;
    float t = dot(c - o, n) / denom;
    if (t <= 0 || t >= hit.t) return;
    float3 p = o + t * d - c;
    float u = dot(p, r), v = p.y;
    if (abs(u) > 0.5 || abs(v) > 0.3) return;
    float3 colour = float3(0.95, 0.95, 0.92);
    // Border 2 cm, corner crosses 6 cm.
    float eu = 0.5 - abs(u), ev = 0.3 - abs(v);
    if (eu < 0.02 || ev < 0.02) colour = float3(0.05, 0.05, 0.05);
    if (eu < 0.06 && ev < 0.06 && (abs(eu - 0.03) < 0.004 || abs(ev - 0.03) < 0.004)) colour = float3(0.9, 0.1, 0.1);
    // Text: lines 16 mm apart, characters 9 mm, 5 x 7 cells of 1.5 mm.
    float x = u + 0.44, y = 0.24 - v;
    if (x > 0 && x < 0.88 && y > 0 && y < 0.48) {
        float textRow = floor(y / 0.016), column = floor(x / 0.009);
        float cx = floor(fmod(x, 0.009) / 0.0015), cy = floor(fmod(y, 0.016) / 0.0015);
        bool space = hash(float2(column * 0.37 + seed, textRow)) < 0.16;
        if (!space && cx < 5 && cy < 7 && hash(float2(column + seed * 7.0, textRow * 13.0 + cx * 5.0 + cy)) > 0.52)
            colour = float3(0.04, 0.04, 0.06);
    }
    hit.t = t;
    hit.colour = colour;
}

Hit trace(float3 o, float3 d, float time) {
    Hit hit;
    hit.t = 1e9;
    float sky = saturate(d.y * 0.5 + 0.5);
    hit.colour = lerp(float3(0.75, 0.82, 0.9), float3(0.3, 0.5, 0.85), sky);
    // Floor.
    if (d.y < -1e-5) {
        float t = -o.y / d.y;
        if (t > 0 && t < hit.t) {
            float2 p = (o + t * d).xz;
            float checker = fmod(floor(p.x / 0.5) + floor(p.y / 0.5) + 1000.0, 2.0);
            hit.t = t;
            hit.colour = lerp(float3(0.35, 0.35, 0.33), float3(0.55, 0.55, 0.52), checker);
        }
    }
    // Room walls at 6 m, grid lines every 0.25 m, heavier every metre.
    for (int axis = 0; axis < 2; ++axis) {
        float dc = axis == 0 ? d.x : d.z, oc = axis == 0 ? o.x : o.z;
        if (abs(dc) < 1e-5) continue;
        float t = ((dc > 0 ? 6.0 : -6.0) - oc) / dc;
        if (t > 0 && t < hit.t) {
            float3 p = o + t * d;
            float a = axis == 0 ? p.z : p.x, b = p.y;
            if (b > 0 && b < 4) {
                float fine = min(abs(frac(a / 0.25 + 0.5) - 0.5), abs(frac(b / 0.25 + 0.5) - 0.5));
                float heavy = min(abs(frac(a + 0.5) - 0.5), abs(frac(b + 0.5) - 0.5));
                float3 colour = axis == 0 ? float3(0.7, 0.62, 0.5) : float3(0.55, 0.65, 0.7);
                if (fine < 0.03) colour *= 0.6;
                if (heavy < 0.015) colour *= 0.3;
                hit.t = t;
                hit.colour = colour;
            }
        }
    }
    panel(o, d, float3(0, 1.4, -1.2), float3(0, 0, 1), float3(1, 0, 0), 1.0, hit);
    panel(o, d, float3(2.0, 1.4, 0), float3(-1, 0, 0), float3(0, 0, 1), 2.0, hit);
    panel(o, d, float3(0, 1.4, 3.0), float3(0, 0, -1), float3(-1, 0, 0), 3.0, hit);
    panel(o, d, float3(-0.7, 1.4, 0), float3(1, 0, 0), float3(0, 0, -1), 4.0, hit);
    // The wheel, right of the front panel and a little nearer.
    {
        float3 c = float3(0.75, 1.4, -1.1), n = float3(0, 0, 1);
        float denom = dot(d, n);
        if (denom < -1e-5) {
            float t = dot(c - o, n) / denom;
            float3 p = o + t * d - c;
            float radius = length(p.xy);
            if (t > 0 && t < hit.t && radius < 0.15) {
                float angle = atan2(p.y, p.x) - time * 3.14159265;
                float spoke = abs(frac(angle / (3.14159265 / 4.0)) - 0.5);
                hit.t = t;
                hit.colour = radius > 0.135 || spoke < 0.08 ? float3(0.1, 0.1, 0.1) : float3(0.95, 0.75, 0.2);
            }
        }
    }
    return hit;
}

float3 rayFor(float2 uv) {
    float tx = lerp(tangents.x, tangents.y, uv.x), ty = lerp(tangents.z, tangents.w, uv.y);
    return float3(tx, ty, -1);
}

// Fullscreen triangle; the viewport places it on one eye.
float4 vs_main(uint id : SV_VertexID) : SV_Position {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
}

float3 stamp(float2 uv, float3 colour) {
    bool top = uv.y >= 0.020 && uv.y <= 0.035, bottom = uv.y >= 0.965 && uv.y <= 0.980;
    if (!(top || bottom) || uv.x < 0.30 || uv.x > 0.30 + 0.022 * 18) return colour;
    float slot = (uv.x - 0.30) / 0.022;
    uint i = (uint)floor(slot);
    if (frac(slot) > 0.020 / 0.022) return float3(0.5, 0.5, 0.5);
    bool white = i == 0 ? true : i == 17 ? false : ((info.x >> (16 - i)) & 1) != 0;
    return white ? float3(1, 1, 1) : float3(0, 0, 0);
}

float4 ps_colour(float4 position : SV_Position) : SV_Target {
    float3 o = positionTime.xyz;
    float3 colour = 0;
    // Four rotated-grid samples per pixel.
    static const float2 offsets[4] = { float2(-0.125, -0.375), float2(0.375, -0.125), float2(0.125, 0.375), float2(-0.375, 0.125) };
    [unroll] for (int s = 0; s < 4; ++s) {
        float2 uv = (position.xy + offsets[s] - viewport.xy) / viewport.zw;
        float3 d = normalize(rotate(orientation, normalize(rayFor(uv))));
        colour += trace(o, d, positionTime.w).colour;
    }
    colour *= 0.25;
    float2 uv = (position.xy - viewport.xy) / viewport.zw;
    if (info.y != 0) colour = stamp(uv, colour);
    // The ring is UNORM and carries display-referred values: this is sRGB already.
    return float4(colour, 1);
}

float ps_depth(float4 position : SV_Position) : SV_Target {
    float2 uv = (position.xy - viewport.xy) / viewport.zw;
    float3 e = rayFor(uv);
    float3 d = normalize(rotate(orientation, normalize(e)));
    Hit hit = trace(positionTime.xyz, d, positionTime.w);
    if (hit.t >= 1e8) return 0;
    // Distance along the view axis: the ray's length over its eye-space length per unit z.
    return hit.t / length(e);
}
)hlsl";

struct Constants {
    float orientation[4];
    float position_time[4];
    float tangents[4];
    float viewport[4];
    uint32_t info[4];
};
static_assert(sizeof(Constants) % 16 == 0, "constant buffers are 16-byte multiples");

winrt::com_ptr<ID3DBlob> compile(const char *entry, const char *target) {
    winrt::com_ptr<ID3DBlob> code, errors;
    HRESULT hr = D3DCompile(kShader, sizeof(kShader) - 1, "spike_test_scene.hlsl", nullptr, nullptr, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, code.put(), errors.put());
    if (FAILED(hr)) {
        const char *message = errors ? static_cast<const char *>(errors->GetBufferPointer()) : "no message";
        throw std::runtime_error(std::string("D3DCompile ") + entry + ": " + message);
    }
    return code;
}

} // namespace

struct lw_spike_scene {
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    winrt::com_ptr<ID3D11VertexShader> vs;
    winrt::com_ptr<ID3D11PixelShader> colour, depth;
    winrt::com_ptr<ID3D11Buffer> constants;
    std::unordered_map<ID3D11Resource *, winrt::com_ptr<ID3D11RenderTargetView>> views;

    ID3D11RenderTargetView *view(ID3D11Resource *resource) {
        auto found = views.find(resource);
        if (found != views.end()) return found->second.get();
        if (views.size() > 64) views.clear(); // a re-attach brings new textures
        winrt::com_ptr<ID3D11RenderTargetView> rtv;
        winrt::check_hresult(device->CreateRenderTargetView(resource, nullptr, rtv.put()));
        views[resource] = rtv;
        return rtv.get();
    }

    void draw(ID3D11Resource *target, ID3D11PixelShader *shader, const lw_spike_scene_eye eyes[2], uint32_t stamp,
              bool drawStamp) {
        D3D11_TEXTURE2D_DESC desc{};
        static_cast<ID3D11Texture2D *>(target)->GetDesc(&desc);
        ID3D11RenderTargetView *rtv = view(target);
        context->OMSetRenderTargets(1, &rtv, nullptr);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->IASetInputLayout(nullptr);
        context->VSSetShader(vs.get(), nullptr, 0);
        context->PSSetShader(shader, nullptr, 0);
        ID3D11Buffer *buffer = constants.get();
        context->PSSetConstantBuffers(0, 1, &buffer);
        const float eyeWidth = static_cast<float>(desc.Width / 2), height = static_cast<float>(desc.Height);
        for (int e = 0; e < 2; ++e) {
            Constants c{};
            std::memcpy(c.orientation, eyes[e].orientation, sizeof c.orientation);
            std::memcpy(c.position_time, eyes[e].position, 3 * sizeof(float));
            c.position_time[3] = eyes[e].time;
            for (int i = 0; i < 4; ++i) c.tangents[i] = std::tan(eyes[e].angles[i]);
            c.viewport[0] = eyeWidth * e;
            c.viewport[1] = 0;
            c.viewport[2] = eyeWidth;
            c.viewport[3] = height;
            c.info[0] = stamp & 0xFFFFu;
            c.info[1] = drawStamp ? 1 : 0;
            context->UpdateSubresource(constants.get(), 0, nullptr, &c, 0, 0);
            D3D11_VIEWPORT viewport{eyeWidth * e, 0, eyeWidth, height, 0, 1};
            context->RSSetViewports(1, &viewport);
            context->Draw(3, 0);
        }
        ID3D11RenderTargetView *none = nullptr;
        context->OMSetRenderTargets(1, &none, nullptr);
    }
};

extern "C" lw_status lw_spike_scene_create(void *d3d11_device, lw_spike_scene **out) {
    if (!d3d11_device || !out) return lw::fail(LW_E_INVALID_ARG, "lw_spike_scene_create: bad argument");
    *out = nullptr;
    return lw::guarded("lw_spike_scene_create", [&]() -> lw_status {
        auto scene = std::make_unique<lw_spike_scene>();
        scene->device.copy_from(static_cast<ID3D11Device *>(d3d11_device));
        scene->device->GetImmediateContext(scene->context.put());
        auto vs = compile("vs_main", "vs_5_0");
        winrt::check_hresult(scene->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr,
                                                               scene->vs.put()));
        auto colour = compile("ps_colour", "ps_5_0");
        winrt::check_hresult(scene->device->CreatePixelShader(colour->GetBufferPointer(), colour->GetBufferSize(),
                                                              nullptr, scene->colour.put()));
        auto depth = compile("ps_depth", "ps_5_0");
        winrt::check_hresult(scene->device->CreatePixelShader(depth->GetBufferPointer(), depth->GetBufferSize(),
                                                              nullptr, scene->depth.put()));
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = sizeof(Constants);
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        winrt::check_hresult(scene->device->CreateBuffer(&desc, nullptr, scene->constants.put()));
        *out = scene.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_spike_scene_draw(lw_spike_scene *scene, void *image, void *depth,
                                         const lw_spike_scene_eye eyes[2], uint32_t stamp, int32_t draw_stamp) {
    if (!scene || !image || !eyes) return lw::fail(LW_E_INVALID_ARG, "lw_spike_scene_draw: bad argument");
    return lw::guarded("lw_spike_scene_draw", [&]() -> lw_status {
        scene->draw(static_cast<ID3D11Resource *>(image), scene->colour.get(), eyes, stamp, draw_stamp != 0);
        if (depth) scene->draw(static_cast<ID3D11Resource *>(depth), scene->depth.get(), eyes, stamp, false);
        return LW_OK;
    });
}

extern "C" void lw_spike_scene_marker(int32_t panel, int32_t corner, float out[3]) {
    // Panel centres, and their right axes (the direction of +u).
    static const float centres[4][3] = {{0, 1.4f, -1.2f}, {2.0f, 1.4f, 0}, {0, 1.4f, 3.0f}, {-0.7f, 1.4f, 0}};
    static const float rights[4][3] = {{1, 0, 0}, {0, 0, 1}, {-1, 0, 0}, {0, 0, -1}};
    const int p = panel < 0 ? 0 : panel > 3 ? 3 : panel;
    // Corner crosses sit 3 cm in from each edge.
    const float u = (corner & 1) ? 0.47f : -0.47f, v = (corner & 2) ? -0.27f : 0.27f;
    for (int i = 0; i < 3; ++i) out[i] = centres[p][i] + u * rights[p][i];
    out[1] += v;
}

extern "C" void lw_spike_scene_release(lw_spike_scene *scene) { delete scene; }
