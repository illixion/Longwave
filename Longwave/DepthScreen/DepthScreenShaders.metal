// 3D for flat games (NATIVE_V3_PROTOCOL.md §4.8): the relief mesh kernel, and
// the synthetic corridor the developer lab feeds it with.
//
// visionOS only; excluded from the iOS and macOS targets in the project's
// membership exception sets.

#include <metal_stdlib>
using namespace metal;

// MARK: - Relief mesh

// Mirrors DepthScreenMeshUniforms in DepthScreenRenderer.swift: fourteen
// 4-byte fields, no vectors, so the two layouts can't disagree on padding.
struct DepthScreenMeshUniforms {
    uint columns;              // grid vertices across
    uint rows;                 // grid vertices down
    float width;               // metres
    float height;
    float reliefScale;         // metres per unit relief: strength · width · blend
    float popOutLimit;
    float inverseScale;        // depthRange: 1/z = v · inverseScale + inverseBias
    float inverseBias;
    float convergence;         // distance on the window plane
    float valueScale;          // sample → v
    float valueBias;
    float maxSlope;            // cell widths of rise that make a cell an edge
    uint edgeMode;             // 0 stretch, 1 fill, 2 cut
    float borderFeather;       // fraction of each side over which relief fades out
};

// The LowLevelMesh vertex: position then uv0, 20 bytes.
struct DepthScreenVertex {
    packed_float3 position;
    packed_float2 uv;
};

// Mirrors DepthScreenGeometry.feather.
static inline float depthScreenFeather(float u, float feather) {
    return smoothstep(0.0, feather, u) * (1.0 - smoothstep(1.0 - feather, 1.0, u));
}

// Mirrors DepthScreenGeometry.relief, scaled to metres and feathered.
static inline float depthScreenRelief(
    float2 uv, texture2d<float, access::read> depth, constant DepthScreenMeshUniforms &u
) {
    // Nearest texel, never a blend: a linear sample across an outline invents
    // a depth halfway between subject and background, and with it a sloped
    // cell that no longer reads as an edge.
    const uint2 size = uint2(depth.get_width(), depth.get_height());
    const uint2 texel = uint2(round(uv * float2(size - 1)));
    const float v = saturate(depth.read(texel).r * u.valueScale + u.valueBias);
    const float r = (v * u.inverseScale + u.inverseBias) * u.convergence - 1.0;
    const float shaped = r > 0.0
        ? (u.popOutLimit > 0.0 ? u.popOutLimit * precise::tanh(r / u.popOutLimit) : 0.0)
        : max(r, -1.0);
    return shaped * u.reliefScale
        * depthScreenFeather(uv.x, u.borderFeather) * depthScreenFeather(uv.y, u.borderFeather);
}

// One thread per cell. Each cell owns its four corners (TL, TR, BL, BR) so an
// edge cell can be re-textured or collapsed without disturbing its neighbours;
// shared corners are computed identically in each cell, so the surface stays
// watertight. Indices are static (DepthMeshGrid.indices).
kernel void depthScreenMesh(
    texture2d<float, access::read> depth [[texture(0)]],
    constant DepthScreenMeshUniforms &u [[buffer(0)]],
    device DepthScreenVertex *vertices [[buffer(1)]],
    uint2 cell [[thread_position_in_grid]]
) {
    const uint cellsAcross = u.columns - 1;
    const uint cellsDown = u.rows - 1;
    if (cell.x >= cellsAcross || cell.y >= cellsDown) { return; }

    const float2 step = 1.0 / float2(cellsAcross, cellsDown);
    float2 uv[4];
    float z[4];
    for (uint corner = 0; corner < 4; corner++) {
        uv[corner] = (float2(cell) + float2(corner & 1, corner >> 1)) * step;
        z[corner] = depthScreenRelief(uv[corner], depth, u);
    }

    const float low = min(min(z[0], z[1]), min(z[2], z[3]));
    const float high = max(max(z[0], z[1]), max(z[2], z[3]));
    const float cellWidth = u.width * step.x;
    const bool isEdge = (high - low) > u.maxSlope * cellWidth;

    float2 texCoord[4] = { uv[0], uv[1], uv[2], uv[3] };
    if (isEdge && u.edgeMode == 1) {
        // Mirrors DepthScreenGeometry.fillSources: a near corner takes the
        // background beside it, mirrored across the far corner, so the strip
        // the outline uncovers repeats the background instead of smearing the
        // outline's own pixels across it.
        uint farthest = 0;
        for (uint corner = 1; corner < 4; corner++) {
            if (z[corner] < z[farthest]) { farthest = corner; }
        }
        const float nearThreshold = u.maxSlope * cellWidth * 0.5;
        for (uint corner = 0; corner < 4; corner++) {
            if (z[corner] - low <= nearThreshold) { continue; }
            const uint horizontal = corner ^ 1;
            const uint vertical = corner ^ 2;
            uint source = farthest;
            if (z[horizontal] - low <= nearThreshold) {
                source = horizontal;
            } else if (z[vertical] - low <= nearThreshold) {
                source = vertical;
            }
            texCoord[corner] = saturate(2.0 * uv[source] - uv[corner]);
        }
    }

    const uint base = (cell.y * cellsAcross + cell.x) * 4;
    for (uint corner = 0; corner < 4; corner++) {
        float3 position = float3((uv[corner].x - 0.5) * u.width, (0.5 - uv[corner].y) * u.height, z[corner]);
        if (isEdge && u.edgeMode == 2) {
            // Collapsed onto one point: a degenerate cell draws nothing.
            position = float3((uv[0].x - 0.5) * u.width, (0.5 - uv[0].y) * u.height, z[0]);
        }
        vertices[base + corner].position = packed_float3(position);
        vertices[base + corner].uv = packed_float2(float2(texCoord[corner].x, 1.0 - texCoord[corner].y));
    }
}

// MARK: - Synthetic corridor

// Mirrors DepthSyntheticUniforms in DepthSyntheticSource.swift.
struct DepthSyntheticUniforms {
    float time;
    float aspect;     // width / height
    float tanHalfFov; // vertical
    float near;
    float far;
    uint fullRange;   // depth luma: 1 full range, 0 video range
};

struct SyntheticCamera {
    float3 origin;
    float3 forward;
    float3 right;
    float3 up;
};

static SyntheticCamera syntheticCamera(float t) {
    SyntheticCamera camera;
    camera.origin = float3(0.45 * sin(t * 0.31), 0.05 * sin(t * 1.7), -1.1 * t);
    const float yaw = 0.18 * sin(t * 0.23);
    camera.forward = normalize(float3(sin(yaw), -0.03, -cos(yaw)));
    camera.right = normalize(cross(camera.forward, float3(0, 1, 0)));
    camera.up = cross(camera.right, camera.forward);
    return camera;
}

static float sdBox(float3 p, float3 halfSize) {
    const float3 q = abs(p) - halfSize;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// Distance to the scene and a material id: 0 walls, 1 floor, 2 ceiling,
// 3 pillars, 4 floating spheres, 5 the near sphere.
static float2 syntheticScene(float3 p, float t, SyntheticCamera camera) {
    // The corridor: 4 m wide, floor at −1.2, ceiling at 1.8.
    float2 hit = float2(2.0 - abs(p.x), 0.0);
    if (p.y + 1.2 < hit.x) { hit = float2(p.y + 1.2, 1.0); }
    if (1.8 - p.y < hit.x) { hit = float2(1.8 - p.y, 2.0); }

    // Pillars against both walls every 6 m.
    float3 q = p;
    q.z = q.z - 6.0 * round(q.z / 6.0);
    q.x = abs(q.x) - 1.65;
    const float pillar = sdBox(q, float3(0.22, 3.0, 0.22));
    if (pillar < hit.x) { hit = float2(pillar, 3.0); }

    // A floating sphere every 9 m, wandering across the corridor.
    const float index = round(p.z / 9.0);
    const float3 centre = float3(0.9 * sin(index * 1.7 + t * 0.6), 0.1 + 0.35 * sin(t + index), index * 9.0);
    const float sphere = length(p - centre) - 0.45;
    if (sphere < hit.x) { hit = float2(sphere, 4.0); }

    // One sphere that stays 1.5–2.5 m ahead, sweeping sideways: a strong,
    // always-visible outline against the far corridor.
    const float3 near = camera.origin + camera.forward * (2.0 + 0.5 * sin(t * 0.7))
                      + camera.right * (0.8 * sin(t * 0.9)) - camera.up * 0.25;
    const float hero = length(p - near) - 0.3;
    if (hero < hit.x) { hit = float2(hero, 5.0); }
    return hit;
}

static float3 syntheticNormal(float3 p, float t, SyntheticCamera camera) {
    const float2 e = float2(0.002, 0.0);
    return normalize(float3(
        syntheticScene(p + e.xyy, t, camera).x - syntheticScene(p - e.xyy, t, camera).x,
        syntheticScene(p + e.yxy, t, camera).x - syntheticScene(p - e.yxy, t, camera).x,
        syntheticScene(p + e.yyx, t, camera).x - syntheticScene(p - e.yyx, t, camera).x));
}

// March one ray; returns (distance along the ray, material), material −1 for
// nothing within `far`.
static float2 syntheticMarch(float3 origin, float3 direction, float t, SyntheticCamera camera, float far) {
    float travelled = 0.0;
    for (int i = 0; i < 160; i++) {
        const float2 hit = syntheticScene(origin + direction * travelled, t, camera);
        if (hit.x < 0.0005 * travelled + 0.0005) { return float2(travelled, hit.y); }
        travelled += hit.x * 0.9;
        if (travelled > far) { break; }
    }
    return float2(far, -1.0);
}

static float3 syntheticRay(float2 uv, constant DepthSyntheticUniforms &u, SyntheticCamera camera) {
    const float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    return normalize(camera.forward
                     + camera.right * ndc.x * u.tanHalfFov * u.aspect
                     + camera.up * ndc.y * u.tanHalfFov);
}

static float3 syntheticShade(float3 p, float3 direction, float material, float distance, float t, SyntheticCamera camera) {
    if (material < 0.0) { return float3(0.9, 0.75, 0.5); }   // a lit opening at the far end
    float3 albedo;
    if (material < 0.5) {
        const float stripe = step(0.5, fract(p.z * 0.5));
        albedo = mix(float3(0.55, 0.32, 0.25), float3(0.7, 0.45, 0.35), stripe);
        albedo *= 0.8 + 0.2 * step(0.92, fract(p.y * 2.0));
    } else if (material < 1.5) {
        const float checker = fmod(floor(p.x) + floor(p.z), 2.0) == 0.0 ? 1.0 : 0.0;
        albedo = mix(float3(0.18, 0.2, 0.24), float3(0.75, 0.76, 0.8), abs(checker));
    } else if (material < 2.5) {
        const float lamp = step(abs(p.z - 6.0 * round(p.z / 6.0)), 0.4) * step(abs(p.x), 0.5);
        if (lamp > 0.5) { return float3(1.0, 0.97, 0.9); }
        albedo = float3(0.35);
    } else if (material < 3.5) {
        albedo = float3(0.2, 0.45, 0.75);
    } else if (material < 4.5) {
        albedo = 0.5 + 0.5 * cos(float3(0.0, 2.0, 4.0) + round(p.z / 9.0));
    } else {
        albedo = float3(0.95, 0.35, 0.15);
    }
    const float3 normal = syntheticNormal(p, t, camera);
    const float3 toLight = normalize(camera.origin + float3(0.0, 0.8, 0.0) - p);
    const float diffuse = saturate(dot(normal, toLight));
    const float fog = exp(-distance * 0.035);
    return mix(float3(0.9, 0.75, 0.5) * 0.6, albedo * (0.25 + 0.85 * diffuse), fog);
}

// The picture, full resolution, sRGB-encoded into a BGRA surface.
kernel void depthSyntheticColour(
    texture2d<float, access::write> colour [[texture(0)]],
    constant DepthSyntheticUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= colour.get_width() || gid.y >= colour.get_height()) { return; }
    const float2 uv = (float2(gid) + 0.5) / float2(colour.get_width(), colour.get_height());
    const SyntheticCamera camera = syntheticCamera(u.time);
    const float3 direction = syntheticRay(uv, u, camera);
    const float2 hit = syntheticMarch(camera.origin, direction, u.time, camera, u.far);
    const float3 linear = syntheticShade(camera.origin + direction * hit.x, direction, hit.y, hit.x, u.time, camera);
    colour.write(float4(pow(saturate(linear), 1.0 / 2.2), 1.0), gid);
}

// The depth auxiliary as the host would send it: z-depth (along the camera's
// axis, as a depth buffer holds it), to normalised inverse depth, quantised to
// a 10-bit luma code in the high bits of a 16-bit word — the x420/xf20 layout
// VideoToolbox decodes HEVC Main10 into. One ray per depth texel, which is a
// point downsample of a full-resolution depth buffer.
kernel void depthSyntheticDepth(
    texture2d<float, access::write> depth [[texture(0)]],
    constant DepthSyntheticUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= depth.get_width() || gid.y >= depth.get_height()) { return; }
    const float2 uv = (float2(gid) + 0.5) / float2(depth.get_width(), depth.get_height());
    const SyntheticCamera camera = syntheticCamera(u.time);
    const float3 direction = syntheticRay(uv, u, camera);
    const float2 hit = syntheticMarch(camera.origin, direction, u.time, camera, u.far);
    const float z = max(hit.x * dot(direction, camera.forward), u.near);
    const float v = hit.y < 0.0 ? 0.0 : saturate((1.0 / z - 1.0 / u.far) / (1.0 / u.near - 1.0 / u.far));
    const float code = u.fullRange != 0 ? round(v * 1023.0) : 64.0 + round(v * 876.0);
    depth.write(float4(code * 64.0 / 65535.0), gid);
}
