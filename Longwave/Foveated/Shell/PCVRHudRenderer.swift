#if FOVEATED_ENABLED && os(visionOS)
import Foundation
import Metal
import os
import simd

/// The newest independent HUD picture. A stopped producer or a disconnected
/// session must not leave the previous game's HUD floating over the new scene.
nonisolated final class PCVRHudFeed: Sendable {
    private let picture = OSAllocatedUnfairLock<PCVRDecodedFrame?>(initialState: nil)

    func deliver(_ frame: PCVRDecodedFrame) {
        let replaced = picture.withLock { previous -> PCVRDecodedFrame? in
            if let previous {
                let newer = PCVRSerialNumber.isNewer(frame.streamEpoch, than: previous.streamEpoch)
                let next = frame.streamEpoch == previous.streamEpoch &&
                    PCVRSerialNumber.isNewer(frame.frameNumber, than: previous.frameNumber)
                guard newer || next else { return nil }
            }
            defer { previous = frame }
            return previous
        }
        withExtendedLifetime(replaced) {}
    }

    func latest(now: TimeInterval) -> PCVRDecodedFrame? {
        picture.withLock { frame in frame.flatMap { now - $0.arrivalTime <= 0.300 ? $0 : nil } }
    }

    func clear() {
        let old = picture.withLock { frame in
            defer { frame = nil }
            return frame
        }
        withExtendedLifetime(old) {}
    }
}

/// Blend the head-relative picture after the world pass. Only the two eye
/// frusta are needed. Both position and rotation follow the current drawable
/// automatically because the HUD never goes through the world's reprojection.
nonisolated final class PCVRHudRenderer {
    private struct Uniforms {
        var source: SIMD4<Float>
        var destination: SIMD4<Float>
        var eye: Float
    }

    private let device: any MTLDevice
    private let vertex: any MTLFunction
    private let fragment: any MTLFunction
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState] = [:]

    init(device: any MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let vertex = library.makeFunction(name: "hudVertex"),
              let fragment = library.makeFunction(name: "hudFragment") else {
            throw PCVRReceiverError.resourceCreationFailed("PCVR HUD shaders")
        }
        self.device = device
        self.vertex = vertex
        self.fragment = fragment
    }

    private func pipeline(format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let pipeline = pipelines[format] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let colour = descriptor.colorAttachments[0]!
        colour.pixelFormat = format
        colour.isBlendingEnabled = true
        colour.sourceRGBBlendFactor = .one
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        pipelines[format] = pipeline
        return pipeline
    }

    func encode(_ frame: PCVRDecodedFrame, targets: [PCVRReceiverTarget], commandBuffer: any MTLCommandBuffer) {
        for target in targets {
            let source = frame.renderPose.eyes[target.eye].fieldOfView.tangents
            guard source.y > source.x, source.z > source.w,
                  let pipeline = pipeline(format: target.colorTexture.pixelFormat) else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target.colorTexture
            pass.colorAttachments[0].slice = target.colorSlice
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            pass.rasterizationRateMap = target.rasterizationRateMap
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "PCVR head-locked HUD"
            encoder.setRenderPipelineState(pipeline)
            encoder.setViewport(target.viewport)
            var uniforms = Uniforms(source: source, destination: target.display.fieldOfView.tangents, eye: Float(target.eye))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Raster {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float4 source, destination;
        float eye;
    };

    vertex Raster hudVertex(uint id [[vertex_id]]) {
        float2 uv(float((id << 1) & 2), float(id & 2));
        return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
    }

    fragment float4 hudFragment(Raster in [[stage_in]], constant Uniforms& views [[buffer(0)]],
                                texture2d<float> image [[texture(0)]]) {
        const float4 src = views.source, dst = views.destination;
        const float2 direction = mix(dst.xz, dst.yw, in.uv);
        const float2 uv = (direction - src.xz) / (src.yw - src.xz);
        if (any(uv < 0) || any(uv > 1)) discard_fragment();

        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        const float2 texel = 1.0 / float2(image.get_width(), image.get_height());
        const float2 colourUV = clamp(uv * 0.5, texel * 0.5, 0.5 - texel * 0.5)
                              + float2(views.eye * 0.5, 0);
        const float alpha = image.sample(linearSampler, colourUV + float2(0, 0.5)).g;
        // A few quantization levels around transparent black are codec noise.
        if (alpha <= 3.0 / 255.0) discard_fragment();
        const float3 c = max(image.sample(linearSampler, colourUV).rgb, 0.0);
        const float3 linear = select(c / 12.92, powr((c + 0.055) / 1.055, float3(2.4)), c > 0.04045);
        return float4(min(linear, float3(alpha)), alpha);
    }
    """
}
#endif
