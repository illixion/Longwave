#if FOVEATED_ENABLED
import Foundation
import Metal
import simd

/// Where one eye's reprojected image goes. A presenter fills this from its own
/// drawable: CompositorServices hands over a texture, slice, viewport, rate map
/// and projection per view; a RealityKit presenter would hand over a
/// `LowLevelTexture`'s texture and no depth.
nonisolated struct PCVRReceiverTarget {
    /// Which of the stream's eyes to show here (0 left, 1 right). A mono target,
    /// such as a capture drawable with one view, shows one eye.
    var eye: Int
    var colorTexture: any MTLTexture
    var colorSlice: Int = 0
    /// Optional. When set, the receiver writes the proxy surface's depth (see
    /// `PCVRReprojection.displayPlane`) through `displayProjection`, so a system
    /// compositor that reprojects again from depth agrees with what was drawn.
    var depthTexture: (any MTLTexture)?
    var depthSlice: Int = 0
    var depthClearValue: Double = 0
    var viewport: MTLViewport
    var rasterizationRateMap: (any MTLRasterizationRateMap)?
    /// The eye the image is shown at: pose at the presentation time, and frustum.
    var display: PCVREyeView
    /// Clip-from-eye for the depth write, in the presenter's depth convention.
    var displayProjection: simd_float4x4 = matrix_identity_float4x4
}

/// Per-encode choices the presenter makes (and a developer can change live).
nonisolated struct PCVRReceiverOptions: Equatable, Sendable {
    var mode: PCVRReprojectionMode = .rotationAndTranslation(planeDistance: 2)
    /// NDC distance over which a ray leaving the rendered frustum fades to black.
    var edgeFade: Float = 0.04
}

/// The presenter-agnostic half of the PCVR receiver: Metal that takes a decoded
/// side-by-side stereo frame and its render pose, and draws each eye
/// reprojected to the display pose (`PCVRReprojection` has the maths and what it
/// does at edges). It touches no CompositorServices, RealityKit or ARKit type,
/// so a second presenter (the foveated-streaming provider extension's scene,
/// NATIVE_V3_PROTOCOL.md open question 16) reuses it unchanged.
///
/// Thread-safety: `encode` may be called from any one thread at a time (the
/// presenter's render loop); the pipeline cache is not shared across threads.
///
/// The shaders are compiled from source at init rather than shipped as a
/// `.metal` file. A `.metal` file would build into every target that shares
/// this folder (the iOS and macOS clients) and could not honour
/// `FOVEATED_ENABLED`; a source string compiles out with the rest of PCVR.
/// It costs a few milliseconds once per session, off the main actor.
nonisolated final class PCVRReceiver: @unchecked Sendable {
    let device: any MTLDevice
    private let library: any MTLLibrary
    private let sampler: any MTLSamplerState
    private var pipelines: [PipelineKey: any MTLRenderPipelineState] = [:]

    private struct PipelineKey: Hashable {
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var sampleCount: Int
    }

    /// Mirrors `PCVRReprojectUniforms` in the shader. Matrices are column-major
    /// with 16-byte columns on both sides, and the scalars ride in one vector so
    /// no trailing-padding rule can make the layouts disagree.
    private struct Uniforms {
        var sourceFromDisplay: simd_float3x3
        var sourceRect: SIMD4<Float>
        var displayTangents: SIMD4<Float>
        var displayPlane: SIMD4<Float>
        var displayProjection: simd_float4x4
        /// x: edge fade, y: 1 when a frame is bound.
        var parameters: SIMD4<Float>
    }

    init(device: any MTLDevice) throws {
        self.device = device
        library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("sampler")
        }
        self.sampler = sampler
    }

    /// Encodes every target. With no frame (none yet, or no head pose to place
    /// one at), clears them to black.
    func encode(frame: PCVRDecodedFrame?, targets: [PCVRReceiverTarget],
                options: PCVRReceiverOptions, commandBuffer: any MTLCommandBuffer) throws {
        for group in Self.passGroups(targets) {
            let first = group[0]
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = first.colorTexture
            pass.colorAttachments[0].slice = first.colorSlice
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            if let depth = first.depthTexture {
                pass.depthAttachment.texture = depth
                pass.depthAttachment.slice = first.depthSlice
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = first.depthClearValue
                pass.depthAttachment.storeAction = .store
            }
            pass.rasterizationRateMap = first.rasterizationRateMap
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw PCVRReceiverError.resourceCreationFailed("render encoder")
            }
            encoder.label = "PCVR reprojection"
            if let frame {
                encoder.setRenderPipelineState(try pipeline(for: first))
                encoder.setFragmentTexture(frame.texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                for target in group {
                    var uniforms = makeUniforms(frame: frame, target: target, options: options)
                    encoder.setViewport(target.viewport)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
            }
            encoder.endEncoding()
        }
    }

    /// Targets drawn in one render pass: consecutive views on the same texture
    /// slice (a shared layout). A pass per view there would clear the view drawn
    /// before it.
    private static func passGroups(_ targets: [PCVRReceiverTarget]) -> [[PCVRReceiverTarget]] {
        var groups: [[PCVRReceiverTarget]] = []
        for target in targets {
            if let last = groups.last?.last, last.colorTexture === target.colorTexture,
               last.colorSlice == target.colorSlice {
                groups[groups.count - 1].append(target)
            } else {
                groups.append([target])
            }
        }
        return groups
    }

    private func makeUniforms(frame: PCVRDecodedFrame, target: PCVRReceiverTarget,
                              options: PCVRReceiverOptions) -> Uniforms {
        let render = frame.renderPose.eyes[target.eye]
        let fov = target.display.fieldOfView
        return Uniforms(
            sourceFromDisplay: PCVRReprojection.sourceFromDisplay(render: render, display: target.display, mode: options.mode),
            sourceRect: Self.eyeRect(eye: target.eye, texture: frame.texture),
            displayTangents: SIMD4(-fov.left, fov.right, fov.up, -fov.down),
            displayPlane: PCVRReprojection.displayPlane(render: render, display: target.display, mode: options.mode),
            displayProjection: target.displayProjection,
            parameters: SIMD4(max(options.edgeFade, 1e-4), 1, 0, 0)
        )
    }

    /// The eye's half of a side-by-side texture as `(u0, v0, du, dv)`, inset by
    /// half a texel so bilinear filtering never reaches into the other eye.
    static func eyeRect(eye: Int, texture: any MTLTexture) -> SIMD4<Float> {
        let halfTexelU = 0.5 / Float(texture.width), halfTexelV = 0.5 / Float(texture.height)
        let u0 = (eye == 0 ? 0 : 0.5) + halfTexelU
        return SIMD4(u0, halfTexelV, 0.5 - 2 * halfTexelU, 1 - 2 * halfTexelV)
    }

    private func pipeline(for target: PCVRReceiverTarget) throws -> any MTLRenderPipelineState {
        let key = PipelineKey(color: target.colorTexture.pixelFormat,
                              depth: target.depthTexture?.pixelFormat ?? .invalid,
                              sampleCount: target.colorTexture.sampleCount)
        if let cached = pipelines[key] { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "PCVR reprojection"
        descriptor.vertexFunction = library.makeFunction(name: "pcvrFullScreenVertex")
        descriptor.fragmentFunction = library.makeFunction(
            name: key.depth == .invalid ? "pcvrReprojectFragment" : "pcvrReprojectDepthFragment")
        descriptor.colorAttachments[0].pixelFormat = key.color
        descriptor.depthAttachmentPixelFormat = key.depth
        descriptor.rasterSampleCount = key.sampleCount
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = state
        return state
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PCVRReprojectUniforms {
        float3x3 sourceFromDisplay;
        float4 sourceRect;
        float4 displayTangents;   // signed: -left, right, up, -down
        float4 displayPlane;      // n.xyz, d with dot(n, p) = d in display-eye space
        float4x4 displayProjection;
        float4 parameters;        // x: edge fade (NDC), y: frame bound
    };

    struct FullScreenOut {
        float4 position [[position]];
        float2 ndc;
    };

    vertex FullScreenOut pcvrFullScreenVertex(uint vid [[vertex_id]]) {
        // One triangle covering the viewport; NDC +Y up.
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        FullScreenOut out;
        out.position = float4(p, 0.0, 1.0);
        out.ndc = p;
        return out;
    }

    static float4 pcvrReproject(float2 ndc, constant PCVRReprojectUniforms &u,
                                texture2d<float> frame, sampler s) {
        float3 h = u.sourceFromDisplay * float3(ndc, 1.0);
        if (h.z <= 1e-6) { return float4(0.0, 0.0, 0.0, 1.0); }
        float2 source = h.xy / h.z;
        // Outside the rendered frustum: fade to black rather than smear the edge.
        float outside = max(max(abs(source.x), abs(source.y)) - 1.0, 0.0);
        float fade = 1.0 - saturate(outside / u.parameters.x);
        float2 uv = saturate(float2(source.x * 0.5 + 0.5, 0.5 - source.y * 0.5));
        float3 rgb = frame.sample(s, u.sourceRect.xy + uv * u.sourceRect.zw).rgb;
        return float4(rgb * fade, 1.0);
    }

    fragment float4 pcvrReprojectFragment(FullScreenOut in [[stage_in]],
                                          constant PCVRReprojectUniforms &u [[buffer(0)]],
                                          texture2d<float> frame [[texture(0)]],
                                          sampler s [[sampler(0)]]) {
        return pcvrReproject(in.ndc, u, frame, s);
    }

    struct ColorDepthOut {
        float4 color [[color(0)]];
        float depth [[depth(any)]];
    };

    fragment ColorDepthOut pcvrReprojectDepthFragment(FullScreenOut in [[stage_in]],
                                                      constant PCVRReprojectUniforms &u [[buffer(0)]],
                                                      texture2d<float> frame [[texture(0)]],
                                                      sampler s [[sampler(0)]]) {
        ColorDepthOut out;
        out.color = pcvrReproject(in.ndc, u, frame, s);
        // The display ray through this pixel, met with the proxy surface.
        float2 t = in.ndc * 0.5 + 0.5;
        float3 ray = float3(mix(u.displayTangents.x, u.displayTangents.y, t.x),
                            mix(u.displayTangents.w, u.displayTangents.z, t.y), -1.0);
        float facing = dot(u.displayPlane.xyz, ray);
        float distance = facing > 1e-6 ? u.displayPlane.w / facing : 0.0;
        if (distance <= 0.0) {
            out.depth = 0.0;
        } else {
            float4 clip = u.displayProjection * float4(ray * distance, 1.0);
            out.depth = saturate(clip.z / clip.w);
        }
        return out;
    }
    """
}

nonisolated enum PCVRReceiverError: Error, CustomStringConvertible {
    case resourceCreationFailed(String)

    var description: String {
        switch self {
        case .resourceCreationFailed(let what): "Could not create the PCVR receiver's \(what)"
        }
    }
}
#endif
