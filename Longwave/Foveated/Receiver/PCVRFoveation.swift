#if FOVEATED_ENABLED
import Foundation
import Metal
import StreamWire

/// How a frame's eyes were packed for the wire (NATIVE_V3_PROTOCOL.md §4.7):
/// the host's centre/edge warp around each eye's centre, and the size each eye
/// had before it. Frames of an unwarped stream carry none.
///
/// The decoded texture holds two wire-size eyes; every shader that samples it
/// by render UV first maps that UV through `CentreEdgeAxisMapping.wireCoordinate
/// (forRender:)` (`PCVRFoveationShader`), with the same four constants per axis
/// the host's warp inverted, so the pair stays matched by construction.
nonisolated struct PCVRFoveation: Equatable, Sendable {
    let mapping: StereoCentreEdgeMapping
    /// One eye as rendered, before the warp.
    let renderEye: PixelSize

    /// Nil when the frame's centres don't belong to these parameters (another
    /// epoch, or no warp at all): such a frame can't be unwarped correctly.
    init?(parameters: FoveationParameters, frame: FoveationSideData, renderEye: PixelSize) {
        guard let mapping = StereoCentreEdgeMapping(parameters: parameters, frame: frame),
              renderEye.width > 0, renderEye.height > 0 else { return nil }
        self.mapping = mapping
        self.renderEye = renderEye
    }

    /// One eye's shader constants, per axis `(a, b, r, L)`.
    func constants(eye: Int) -> (x: SIMD4<Float>, y: SIMD4<Float>) {
        let map = eye == 0 ? mapping.left : mapping.right
        return (map.x.constants, map.y.constants)
    }

    /// The constants that map every UV to itself: an unwarped frame's.
    static let identity = SIMD4<Float>(0, 1, 1, 1)
}

extension PCVRDecodedFrame {
    /// One eye's shader constants: the frame's warp, or the identity.
    func wireConstants(eye: Int) -> (x: SIMD4<Float>, y: SIMD4<Float>) {
        foveation?.constants(eye: eye) ?? (PCVRFoveation.identity, PCVRFoveation.identity)
    }

    /// Both eyes side by side as rendered: the texture's size unless warped.
    var renderSize: (width: Int, height: Int) {
        guard let eye = foveation?.renderEye else { return (texture.width, texture.height) }
        return (2 * Int(eye.width), Int(eye.height))
    }
}

/// Metal shared by every shader that reads a decoded frame by render UV.
nonisolated enum PCVRFoveationShader {
    static let source = """
    // StreamWire's CentreEdgeAxisMapping.wireCoordinate(forRender:): where a
    // render coordinate reads the wire texture. m = (a, b, r, L): the
    // full-density interval a..b, the edge ratio and the packed length.
    // (0, 1, 1, 1) is the identity.
    static float pcvrWireCoordinate(float x, float4 m) {
        float packed;
        if (x < m.x) { packed = x / m.z; }
        else if (x <= m.y) { packed = m.x / m.z + x - m.x; }
        else { packed = m.x / m.z + (m.y - m.x) + (x - m.y) / m.z; }
        return saturate(packed / m.w);
    }

    static float2 pcvrWireUV(float2 renderUV, float4 mx, float4 my) {
        return float2(pcvrWireCoordinate(renderUV.x, mx), pcvrWireCoordinate(renderUV.y, my));
    }

    // The inverse, CentreEdgeAxisMapping.renderCoordinate(forWire:): the
    // render coordinate a wire texel came from.
    static float pcvrRenderCoordinate(float wire, float4 m) {
        float packed = wire * m.w;
        float left = m.x / m.z, end = left + m.y - m.x;
        float x;
        if (packed < left) { x = packed * m.z; }
        else if (packed <= end) { x = m.x + packed - left; }
        else { x = m.y + (packed - end) * m.z; }
        return saturate(x);
    }

    static float2 pcvrRenderUV(float2 wireUV, float4 mx, float4 my) {
        return float2(pcvrRenderCoordinate(wireUV.x, mx), pcvrRenderCoordinate(wireUV.y, my));
    }

    // One eye's texel of a side-by-side texture at eye-local UV `uv`: `rect`
    // places the eye (u origin, v origin, u scale, v scale), `bounds` keeps the
    // tap half a texel inside it so filtering never reaches the other eye.
    static float2 pcvrEyeTexel(float2 uv, float4 rect, float4 bounds) {
        return clamp(rect.xy + uv * rect.zw, bounds.xy, bounds.zw);
    }

    // A Catmull-Rom (bicubic) read of `t` at normalized `uv`, from nine bilinear
    // taps, each kept inside `bounds` like `pcvrEyeTexel`. A bilinear read at a
    // fractional texel position averages two texels: a reprojection lands
    // nearly every pixel between texels, by an amount that changes every frame,
    // so a 1:1 resample comes out softened by up to half a pixel and shimmers as
    // the head moves. Catmull-Rom passes a texel through unchanged at a texel
    // centre and keeps an edge's contrast in between.
    static float4 pcvrSampleCatmullRom(texture2d<float, access::sample> t, sampler s, float2 uv, float4 bounds,
                                       bool deRing) {
        float2 size = float2(t.get_width(), t.get_height());
        float2 pos = uv * size;
        float2 tc = floor(pos - 0.5) + 0.5;
        float2 f = pos - tc;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 a = clamp((tc - 1.0) / size, bounds.xy, bounds.zw);
        float2 b = clamp((tc + w2 / w12) / size, bounds.xy, bounds.zw);
        float2 c = clamp((tc + 2.0) / size, bounds.xy, bounds.zw);
        float4 r = t.sample(s, float2(a.x, a.y)) * (w0.x * w0.y)
                 + t.sample(s, float2(b.x, a.y)) * (w12.x * w0.y)
                 + t.sample(s, float2(c.x, a.y)) * (w3.x * w0.y)
                 + t.sample(s, float2(a.x, b.y)) * (w0.x * w12.y)
                 + t.sample(s, float2(b.x, b.y)) * (w12.x * w12.y)
                 + t.sample(s, float2(c.x, b.y)) * (w3.x * w12.y)
                 + t.sample(s, float2(a.x, c.y)) * (w0.x * w3.y)
                 + t.sample(s, float2(b.x, c.y)) * (w12.x * w3.y)
                 + t.sample(s, float2(c.x, c.y)) * (w3.x * w3.y);
        if (!deRing) return max(r, 0.0);
        // Never outside the four texels around the point: Catmull-Rom's
        // negative lobes overshoot beside a hard edge, a halo that moves with
        // the sub-pixel phase from frame to frame.
        float2 n0 = clamp(tc / size, bounds.xy, bounds.zw), n1 = clamp((tc + 1.0) / size, bounds.xy, bounds.zw);
        float4 p0 = t.sample(s, n0), p1 = t.sample(s, float2(n1.x, n0.y));
        float4 p2 = t.sample(s, float2(n0.x, n1.y)), p3 = t.sample(s, n1);
        return clamp(r, min(min(p0, p1), min(p2, p3)), max(max(p0, p1), max(p2, p3)));
    }
    """
}

/// Undoes the warp into a render-size side-by-side texture, for a presenter
/// that can't sample through the map itself (a RealityKit material).
/// `PCVRReceiver` doesn't need it: it maps each UV while it reprojects.
///
/// Thread-safety: one thread at a time (the presenter's frame loop).
nonisolated final class PCVRUnwarp: @unchecked Sendable {
    let device: any MTLDevice
    private let library: any MTLLibrary
    private let sampler: any MTLSamplerState
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    /// Mirrors `PCVRUnwarpUniforms`.
    private struct Uniforms {
        var wireX: SIMD4<Float>
        var wireY: SIMD4<Float>
        var sourceRect: SIMD4<Float>
        var sourceBounds: SIMD4<Float>
    }

    init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("unwarp sampler")
        }
        self.sampler = sampler
    }

    /// Draws both eyes of `frame`, unwarped, into `target` (at least
    /// `frame.renderSize`, a render target).
    func encode(frame: PCVRDecodedFrame, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PCVRReceiverError.resourceCreationFailed("unwarp encoder")
        }
        encoder.label = "PCVR unwarp"
        encoder.setRenderPipelineState(try pipeline(for: target.pixelFormat))
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let size = frame.renderSize
        let eyeWidth = Double(size.width / 2)
        for eye in 0..<2 {
            let wire = frame.wireConstants(eye: eye)
            var uniforms = Uniforms(wireX: wire.x, wireY: wire.y,
                                    sourceRect: PCVRReceiver.eyeRect(eye: eye, texture: frame.texture),
                                    sourceBounds: PCVRReceiver.eyeBounds(eye: eye, texture: frame.texture))
            encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0, width: eyeWidth,
                                            height: Double(size.height), znear: 0, zfar: 1))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    private func pipeline(for format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        if let cached = pipelines[format] { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "PCVR unwarp"
        descriptor.vertexFunction = library.makeFunction(name: "pcvrUnwarpVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "pcvrUnwarpFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[format] = state
        return state
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    \(PCVRFoveationShader.source)

    struct PCVRUnwarpUniforms {
        float4 wireX;
        float4 wireY;
        float4 sourceRect;
        float4 sourceBounds;
    };

    struct UnwarpOut {
        float4 position [[position]];
        float2 ndc;
    };

    vertex UnwarpOut pcvrUnwarpVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        UnwarpOut out;
        out.position = float4(p, 0.0, 1.0);
        out.ndc = p;
        return out;
    }

    fragment float4 pcvrUnwarpFragment(UnwarpOut in [[stage_in]],
                                       constant PCVRUnwarpUniforms &u [[buffer(0)]],
                                       texture2d<float> frame [[texture(0)]],
                                       sampler s [[sampler(0)]]) {
        // This eye's render UV at the pixel centre, top-left origin.
        float2 uv = saturate(float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5));
        float2 wire = pcvrWireUV(uv, u.wireX, u.wireY);
        return frame.sample(s, pcvrEyeTexel(wire, u.sourceRect, u.sourceBounds));
    }
    """
}
#endif
