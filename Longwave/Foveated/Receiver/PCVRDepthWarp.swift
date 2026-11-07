#if FOVEATED_ENABLED
import Foundation
import Metal
import simd

/// Per-pixel reprojection of a decoded frame by its depth map, from the eye
/// poses it was rendered at to the poses it will be shown at: positional
/// timewarp, done on the headset once per display frame.
///
/// **Why.** A mesh displaced by depth (`PCVREyeMesh`) gets parallax right
/// inside a surface but stretches every cell that spans a depth edge, since
/// one triangle must join the near side to the far: the wider the eye has
/// moved from the render pose, the wider the smear, and the band is as wide
/// as a cell whatever the depth resolution. Warping every pixel instead moves
/// the near side and the far side each by its own parallax, and what the move
/// uncovers is filled from the far side rather than stretched.
///
/// **How.** For each output pixel (per eye, at the frame's wire size, through
/// its foveation map, so the picture is still packed around the gaze) the
/// kernel takes the pixel's ray from the target eye and marches it through
/// the source eye's depth map, from half the stream's near depth to infinity
/// in equal steps of inverse distance (which is nearly equal steps across the
/// depth picture), about one depth texel each, until the ray passes behind the
/// scene surface; the crossing is refined by two secant steps and the frame is
/// read there. Pure rotation needs one step. Depth is interpolated between
/// texels except across an edge (a jump of `edgeCodes` of the 8-bit picture),
/// where the nearer texel's value stands as a step, as in the mesh kernel.
///
/// **Edges.** The march tells a surface from a silhouette by that jump. A ray
/// that passes behind a nearer surface's silhouette (the depth jumps up as the
/// ray goes behind) has not hit it: it carries on in the surface's shadow.
/// Coming out the far side onto a farther surface it is either in front of
/// that surface again, and marches on to hit it, or already behind it: then
/// the point it really hits was hidden from the source eye, and the pixel is
/// filled with the farther surface's colour beside the edge, drawn across the
/// uncovered strip. A ray that never crosses cleanly (the sky, or behind
/// something to the end) takes the far end: rotation only, at infinity.
///
/// **Cost.** The march runs at a quarter of the output's resolution per axis
/// into a warp map (per texel, the hit's displacement in render UV and its
/// inverse depth), and the full-resolution pass interpolates the map where
/// its four texels around a pixel agree in depth, marching itself only where
/// they don't: the few per cent of pixels within a map texel of a depth edge,
/// where interpolation would smear the near side into the far. (Marching every
/// pixel took 5 ms of GPU a tick on the headset, 2026-11-07, half the tick.)
///
/// **Output.** `encode` writes the warped picture for both eyes side by side
/// and, when asked, the warped depth at the depth map's size, encoded like the
/// source (`PCVRDepthMap` with the same near and far): a mesh placed at the
/// target pose can then be displaced by it, so whatever the system's own
/// reprojection still has to bridge (the target pose is a prediction) is
/// bridged with depth, over a shift a few times smaller than the one warped.
///
/// Thread-safety: one thread at a time (the presenter's frame loop).
nonisolated final class PCVRDepthWarper: @unchecked Sendable {
    /// Mirrors `PCVRDepthWarpUniforms`.
    private struct Uniforms {
        var rotation: simd_float3x3
        var translation: SIMD4<Float>
        var sourceTangents: SIMD4<Float>
        var targetTangents: SIMD4<Float>
        var wireX: SIMD4<Float>
        var wireY: SIMD4<Float>
        var sourceRect: SIMD4<Float>
        var sourceBounds: SIMD4<Float>
        var depthRect: SIMD4<Float>
        var depthTexels: SIMD4<Float>
        var depthDecode: SIMD4<Float>
        var depthSize: SIMD2<Float>
        var mapBounds: SIMD4<Float>
        var mapSize: SIMD2<Float>
        var outputSize: SIMD2<Float>
        var outputOrigin: SIMD2<UInt32>
        var nearInverse: Float
        var planeInverse: Float
        var stepTexels: Float
        var edge: Float
        var maxSteps: UInt32
        var flags: UInt32
    }

    /// Codes of an 8-bit depth picture between neighbouring texels that make
    /// an edge rather than a slope (`PCVREyeMeshBuilder` uses the same).
    static let edgeCodes: Float = 4

    let device: any MTLDevice
    private let mapPipeline: any MTLComputePipelineState
    private let colourPipeline: any MTLComputePipelineState
    private let depthPipeline: any MTLComputePipelineState
    private let sampler: any MTLSamplerState
    private let noDepth: any MTLTexture
    /// The warp map, remade when the output size changes.
    private var map: (any MTLTexture)?
    /// Output pixels per warp-map texel, each axis.
    static let mapScale = 4

    /// The most steps a ray is marched: bounds the cost of a large shift. At
    /// one depth texel a step, 32 cover a 12-degree shift of near content.
    var maxSteps = 32
    /// The march's step across the depth picture, in texels.
    var stepTexels: Float = 1

    init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let map = library.makeFunction(name: "pcvrDepthWarpMap"),
              let colour = library.makeFunction(name: "pcvrDepthWarpColour"),
              let depth = library.makeFunction(name: "pcvrDepthWarpDepth") else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp kernels")
        }
        mapPipeline = try device.makeComputePipelineState(function: map)
        colourPipeline = try device.makeComputePipelineState(function: colour)
        depthPipeline = try device.makeComputePipelineState(function: depth)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp sampler")
        }
        self.sampler = sampler
        let empty = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        empty.usage = .shaderRead
        guard let noDepth = device.makeTexture(descriptor: empty) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp placeholder depth")
        }
        self.noDepth = noDepth
    }

    /// Warps `frame` to the eyes at `targets` (world-from-eye, left then
    /// right, with the frame's own frusta), writing both eyes side by side
    /// into `colour` (any size; the frame's wire size keeps its detail) and,
    /// when given, the warped depth into `warpedDepth` (a float texture, both
    /// eyes side by side; the source depth's size is natural). Without `depth`
    /// the whole picture is taken to lie `planeDistance` metres ahead of the
    /// source eye and `warpedDepth` is left alone.
    func encode(frame: PCVRDecodedFrame, depth: PCVRDepthMap?, targets: PCVRStereo<PCVRPose>, planeDistance: Float,
                into colour: any MTLTexture, warpedDepth: (any MTLTexture)? = nil,
                commandBuffer: any MTLCommandBuffer) throws {
        let depthTexture = depth?.texture ?? noDepth
        let map = try warpMap(for: colour)
        var uniforms = (0..<2).map { eye in
            self.uniforms(frame: frame, eye: eye, depth: depth, target: targets[eye], planeDistance: planeDistance,
                          colour: colour, map: map)
        }
        let length = MemoryLayout<Uniforms>.stride * 2
        // A serial encoder: each dispatch sees the one before it complete.
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp encoder")
        }
        encoder.label = "PCVR depth warp"
        encoder.setBytes(&uniforms, length: length, index: 0)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(depthTexture, index: 1)
        encoder.setTexture(colour, index: 2)
        encoder.setTexture(map, index: 3)
        encoder.setSamplerState(sampler, index: 0)
        encoder.setComputePipelineState(mapPipeline)
        encoder.dispatchThreads(MTLSize(width: map.width, height: map.height, depth: 1),
                                threadsPerThreadgroup: Self.threadgroup(mapPipeline))
        encoder.setComputePipelineState(colourPipeline)
        encoder.dispatchThreads(MTLSize(width: colour.width, height: colour.height, depth: 1),
                                threadsPerThreadgroup: Self.threadgroup(colourPipeline))
        if let warpedDepth, depth != nil {
            encoder.setComputePipelineState(depthPipeline)
            encoder.setTexture(warpedDepth, index: 2)
            encoder.dispatchThreads(MTLSize(width: warpedDepth.width, height: warpedDepth.height, depth: 1),
                                    threadsPerThreadgroup: Self.threadgroup(depthPipeline))
        }
        encoder.endEncoding()
    }

    /// The warp map for an output: a quarter of its size per axis, per eye.
    private func warpMap(for colour: any MTLTexture) throws -> any MTLTexture {
        let width = 2 * ((colour.width / 2 + Self.mapScale - 1) / Self.mapScale)
        let height = (colour.height + Self.mapScale - 1) / Self.mapScale
        if let map, map.width == width, map.height == height { return map }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp map")
        }
        made.label = "PCVR depth warp map"
        map = made
        return made
    }

    private static func threadgroup(_ pipeline: any MTLComputePipelineState) -> MTLSize {
        let width = min(pipeline.threadExecutionWidth, 16)
        return MTLSize(width: width, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, 16)), depth: 1)
    }

    private func uniforms(frame: PCVRDecodedFrame, eye: Int, depth: PCVRDepthMap?, target: PCVRPose,
                          planeDistance: Float, colour: any MTLTexture, map: any MTLTexture) -> Uniforms {
        let source = frame.renderPose.eyes[eye]
        let sourceFromTarget = source.pose.inverse * target
        let wire = frame.wireConstants(eye: eye)
        let depthTexture = depth?.texture ?? noDepth
        let decode = depth?.decode ?? .zero
        let plane = max(planeDistance, 0.01)
        let eyeWidth = colour.width / 2
        return Uniforms(
            rotation: simd_float3x3(sourceFromTarget.rotation),
            translation: SIMD4(sourceFromTarget.position, 0),
            sourceTangents: source.fieldOfView.tangents,
            targetTangents: source.fieldOfView.tangents,
            wireX: wire.x, wireY: wire.y,
            sourceRect: PCVRReceiver.eyeRect(eye: eye, texture: frame.texture),
            sourceBounds: PCVRReceiver.eyeBounds(eye: eye, texture: frame.texture),
            depthRect: PCVRReceiver.eyeRect(eye: eye, texture: depthTexture),
            depthTexels: PCVREyeMeshBuilder.eyeTexels(eye: eye, texture: depthTexture),
            depthDecode: decode,
            depthSize: SIMD2(Float(depthTexture.width), Float(depthTexture.height)),
            mapBounds: PCVRReceiver.eyeBounds(eye: eye, texture: map),
            mapSize: SIMD2(Float(map.width / 2), Float(map.height)),
            outputSize: SIMD2(Float(eyeWidth), Float(colour.height)),
            outputOrigin: SIMD2(UInt32(eye * eyeWidth), 0),
            // The march starts at half the nearest depth there can be, so its
            // first sample is in front of everything.
            nearInverse: depth.map { 2 / max($0.near, 0.01) } ?? 2 / plane,
            planeInverse: 1 / plane,
            stepTexels: max(stepTexels, 0.25),
            edge: depth != nil ? Self.edgeCodes / 255 * abs(decode.x * decode.w) : 0,
            maxSteps: UInt32(max(maxSteps, 1)),
            flags: depth != nil ? 1 : 0)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    \(PCVRFoveationShader.source)

    struct PCVRDepthWarpUniforms {
        float3x3 rotation;      // source eye <- target eye
        float4 translation;     // the target eye's origin in source eye space
        float4 sourceTangents;  // left, right, up, down (left and down negative)
        float4 targetTangents;
        float4 wireX;           // the frame's centre/edge map for this eye
        float4 wireY;
        float4 sourceRect;      // this eye's half of the frame texture, and its clamp
        float4 sourceBounds;
        float4 depthRect;       // this eye's half of the depth map, its texel range and decode
        float4 depthTexels;
        float4 depthDecode;
        float2 depthSize;
        float4 mapBounds;       // this eye's half of the warp map (clamp) and its texels
        float2 mapSize;
        float2 outputSize;      // this eye's output pixels and where they start
        uint2 outputOrigin;
        float nearInverse;      // where the march starts, as inverse distance along the ray
        float planeInverse;     // the scene's inverse depth everywhere, without a depth map
        float stepTexels;
        float edge;             // an inverse-depth jump this large between texels is an edge
        uint maxSteps;
        uint flags;             // 1: a depth map
    };

    struct PCVRDepthWarpHit {
        float2 uv;   // source render UV
        float w;     // inverse depth there, in the source eye
    };

    // The scene's inverse depth at a source render UV: the four texels around
    // it interpolated where they agree, else the one nearest the point, so an
    // edge stays a step at the texel boundary (PCVREyeMeshBuilder takes the
    // nearest depth of the four instead, which here would grow every near
    // shape by a texel and drag a rim of background with it).
    static float pcvrDepthWarpScene(float2 renderUV, constant PCVRDepthWarpUniforms &u,
                                    texture2d<float, access::read> depth) {
        if (!(u.flags & 1u)) return u.planeInverse;
        float2 position = (u.depthRect.xy + saturate(renderUV) * u.depthRect.zw) * u.depthSize - 0.5;
        int2 base = int2(floor(position));
        float2 f = position - float2(base);
        int2 low = int2(u.depthTexels.xy), high = int2(u.depthTexels.zw);
        float w[4];
        for (int k = 0; k < 4; k++) {
            uint2 p = uint2(clamp(base + int2(k & 1, k >> 1), low, high));
            float value = saturate(depth.read(p).r * u.depthDecode.x + u.depthDecode.y);
            w[k] = u.depthDecode.z + value * u.depthDecode.w;
        }
        float nearest = max(max(w[0], w[1]), max(w[2], w[3]));
        float farthest = min(min(w[0], w[1]), min(w[2], w[3]));
        if (nearest - farthest <= u.edge) return mix(mix(w[0], w[1], f.x), mix(w[2], w[3], f.x), f.y);
        return w[(f.x >= 0.5 ? 1 : 0) + (f.y >= 0.5 ? 2 : 0)];
    }

    // The target ray at inverse distance `lambda` (1/s along it): where that
    // point is in the source image (render UV) and its inverse depth in the
    // source eye. The point t + s D, scaled by 1/s, is D + t lambda; its
    // source depth over s is -(D + t lambda).z.
    static void pcvrDepthWarpRay(float3 D, float3 t, float lambda, float4 st, thread float2 &uv, thread float &rho) {
        float3 p = D + t * lambda;
        float z = max(-p.z, 1e-6);
        float2 tangent = p.xy / z;
        uv = float2((tangent.x - st.x) / (st.y - st.x), (st.z - tangent.y) / (st.z - st.w));
        rho = lambda / z;
    }

    static PCVRDepthWarpHit pcvrDepthWarpMarch(float2 targetRenderUV, constant PCVRDepthWarpUniforms &u,
                                               texture2d<float, access::read> depth) {
        float4 tt = u.targetTangents;
        float3 d = float3(tt.x + targetRenderUV.x * (tt.y - tt.x), tt.z - targetRenderUV.y * (tt.z - tt.w), -1);
        float3 D = u.rotation * d;
        float3 t = u.translation.xyz;
        float lambdaMax = u.nearInverse;
        float2 uvNear, uvFar;
        float rhoNear, rhoFar;
        pcvrDepthWarpRay(D, t, lambdaMax, u.sourceTangents, uvNear, rhoNear);
        pcvrDepthWarpRay(D, t, 0, u.sourceTangents, uvFar, rhoFar);
        // About a depth texel a step along the ray's track across the picture;
        // one step without a depth map, where the secant is exact.
        uint n = 1;
        if (u.flags & 1u) {
            float2 track = (uvFar - uvNear) * u.depthRect.zw * u.depthSize;
            n = clamp(uint(ceil(length(track) / u.stepTexels)), 1u, u.maxSteps);
        }
        float2 previousUV = uvNear;
        float previousW = pcvrDepthWarpScene(uvNear, u, depth);
        float previousLambda = lambdaMax, previousF = rhoNear - previousW;
        // In a nearer surface's shadow, and the last thing seen before it: the
        // farther surface beside its edge, which fills what it uncovered.
        bool behind = previousF < 0;
        PCVRDepthWarpHit entry = {uvNear, previousW};
        for (uint k = 1; k <= n; k++) {
            float lambda = lambdaMax * (1 - float(k) / float(n));
            float2 uv;
            float rho;
            pcvrDepthWarpRay(D, t, lambda, u.sourceTangents, uv, rho);
            float w = pcvrDepthWarpScene(uv, u, depth);
            float f = rho - w;
            if (!behind) {
                if (f < 0) {
                    if (w - previousW > u.edge) {
                        // A nearer surface has come under the ray. Into its
                        // face, or behind its silhouette? Where the ray reaches
                        // that surface's depth within this step: on the surface
                        // it is a hit, past the edge the ray slipped behind.
                        float rhoPrevious = previousF + previousW;
                        float a = (rhoPrevious - w) / (rhoPrevious - rho);
                        if (a >= 0 && a <= 1) {
                            float lm = mix(previousLambda, lambda, a);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            if (abs(pcvrDepthWarpScene(uvm, u, depth) - w) <= u.edge) return PCVRDepthWarpHit{uvm, rhom};
                        }
                        entry = PCVRDepthWarpHit{previousUV, previousW};
                        behind = true;
                    } else {
                        // Through the surface: the crossing by the secant, twice.
                        for (int pass = 0; pass < 2; pass++) {
                            float a = previousF / (previousF - f);
                            float lm = mix(previousLambda, lambda, a);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            float fm = rhom - pcvrDepthWarpScene(uvm, u, depth);
                            if (pass == 1) return PCVRDepthWarpHit{uvm, rhom};
                            if (fm > 0) { previousLambda = lm; previousF = fm; } else { lambda = lm; f = fm; }
                        }
                    }
                }
            } else if (f >= 0) {
                // Out from behind it, in front of what lies farther (or at
                // the sky, at infinity, which it can only be level with).
                behind = false;
            } else if (previousW - w > u.edge) {
                // Off the silhouette onto a farther surface and already behind
                // it: the point the ray hits was hidden from the source eye.
                return entry;
            }
            previousUV = uv;
            previousW = w;
            previousLambda = lambda;
            previousF = f;
        }
        // Still in a shadow at infinity: the hit was hidden. Else the far end:
        // rotation only, the sky.
        return behind ? entry : PCVRDepthWarpHit{previousUV, previousW};
    }

    // Pass one, the warp map at a quarter of the output per axis: per texel,
    // how far the hit's render UV is from the texel's own (a displacement,
    // smooth across a surface however the foveation map bends under it) and
    // the hit's inverse depth.
    kernel void pcvrDepthWarpMap(texture2d<float, access::read> depth [[texture(1)]],
                                 texture2d<float, access::write> map [[texture(3)]],
                                 constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        uint eyeWidth = map.get_width() / 2;
        uint eye = gid.x >= eyeWidth ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        float2 wire = (float2(gid.x - eye * eyeWidth, gid.y) + 0.5) / u.mapSize;
        float2 render = pcvrRenderUV(wire, u.wireX, u.wireY);
        PCVRDepthWarpHit hit = pcvrDepthWarpMarch(render, u, depth);
        map.write(float4(hit.uv - render, hit.w, 0), gid);
    }

    // Pass two, every output pixel: the map interpolated where its four
    // texels around the pixel agree in depth, the march itself where they
    // don't (a depth edge, where interpolating would smear near into far).
    kernel void pcvrDepthWarpColour(texture2d<float, access::sample> source [[texture(0)]],
                                    texture2d<float, access::read> depth [[texture(1)]],
                                    texture2d<float, access::write> output [[texture(2)]],
                                    texture2d<float, access::sample> map [[texture(3)]],
                                    constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                    sampler linear [[sampler(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        uint eye = gid.x >= eyes[1].outputOrigin.x ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        uint2 local = gid - u.outputOrigin;
        if (local.x >= uint(u.outputSize.x) || local.y >= uint(u.outputSize.y)) return;
        float2 wire = (float2(local) + 0.5) / u.outputSize;
        float2 render = pcvrRenderUV(wire, u.wireX, u.wireY);
        float2 at = pcvrEyeTexel(wire, u.sourceRect, u.mapBounds);
        float4 w4 = map.gather(linear, at, int2(0), component::z);
        float spread = max(max(w4.x, w4.y), max(w4.z, w4.w)) - min(min(w4.x, w4.y), min(w4.z, w4.w));
        PCVRDepthWarpHit hit;
        if (spread > u.edge) {
            hit = pcvrDepthWarpMarch(render, u, depth);
        } else {
            float4 m = map.sample(linear, at);
            hit.uv = render + m.xy;
            hit.w = m.z;
        }
        float2 uv = pcvrEyeTexel(pcvrWireUV(saturate(hit.uv), u.wireX, u.wireY), u.sourceRect, u.sourceBounds);
        output.write(float4(source.sample(linear, uv).rgb, 1), gid);
    }

    // The warped depth, at the output's size, encoded as the source map is.
    kernel void pcvrDepthWarpDepth(texture2d<float, access::read> depth [[texture(1)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint eyeWidth = output.get_width() / 2;
        uint eye = gid.x >= eyeWidth ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        float2 render = (float2(gid.x - eye * eyeWidth, gid.y) + 0.5) / float2(eyeWidth, output.get_height());
        PCVRDepthWarpHit hit = pcvrDepthWarpMarch(render, u, depth);
        float value = u.depthDecode.w > 0 ? (hit.w - u.depthDecode.z) / u.depthDecode.w : 0;
        output.write(float4(saturate(value), 0, 0, 1), gid);
    }
    """
}
#endif
