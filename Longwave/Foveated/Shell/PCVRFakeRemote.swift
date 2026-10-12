#if FOVEATED_ENABLED && DEBUG
import CoreText
import DebugTrace
import Foundation
import Metal
import QuartzCore
import os
import simd

/// How the fake remote behaves, changeable while it runs.
nonisolated struct PCVRFakeRemoteSettings: Equatable, Sendable {
    /// Added between a frame finishing rendering and it reaching the receiver:
    /// the stand-in for encode, network and decode.
    var delay: TimeInterval = 0.03
    var frameRate: Double = 72
    /// How much wider than the display each eye is rendered (fraction of each
    /// tangent), leaving reprojection room before the edges go black.
    var overscan: Float = 0.1
}

/// A stand-in PCVR host for exercising Shell A with no PC: it renders a test
/// room into a side-by-side stereo texture from the latest uplink head-pose
/// snapshot, as a host would, and hands each frame to the receiver after an
/// artificial delay and at its own frame rate. With a delay and a frame rate
/// below the display's, every frame is stale when shown, so what stays still in
/// the headset is what reprojection fixed.
///
/// The room: a 6 × 3 × 6 m box centred on the space's origin with a 25 cm grid
/// (1 m lines heavier), each wall tinted and labelled with its compass
/// direction (north is -Z). Cubes 0.5, 1 and 2 m ahead at eye height, each
/// labelled, show translation error by depth (only the one on the proxy plane
/// stays put with rotation-and-translation). A yellow cube orbits at the
/// remote's own clock, so its cadence shows the source frame rate.
///
/// DEBUG only: a developer fixture, not a product surface.
nonisolated final class PCVRFakeRemote: @unchecked Sendable {
    let settings = OSAllocatedUnfairLock(initialState: PCVRFakeRemoteSettings())
    /// Frames rendered and frames skipped because every texture was still leased.
    var counts: (rendered: Int, stalled: Int) { tally.withLock { $0 } }

    /// Per-eye resolution of the stream texture. Square, near a headset's
    /// per-eye stream size without costing much memory per frame.
    static let eyeSize = 1152

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let atlas: any MTLTexture
    private let labels: [Label]
    private let pool: TexturePool
    private let mailbox: PCVRFrameMailbox
    private let delivery = DispatchQueue(label: "pro.longwave.pcvr.fake-remote.delivery", qos: .userInteractive)
    private let latest = OSAllocatedUnfairLock<PCVRHeadPoseSnapshot?>(initialState: nil)
    private let tally = OSAllocatedUnfairLock(initialState: (rendered: 0, stalled: 0))
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRShell")
    private let startTime = CACurrentMediaTime()
    private var frameNumber: UInt32 = 0

    init(device: any MTLDevice, mailbox: PCVRFrameMailbox) throws {
        guard let queue = device.makeCommandQueue() else {
            throw PCVRReceiverError.resourceCreationFailed("fake remote command queue")
        }
        queue.label = "PCVR fake remote"
        self.device = device
        self.queue = queue
        self.mailbox = mailbox
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "PCVR fake remote scene"
        descriptor.vertexFunction = library.makeFunction(name: "fakeRemoteVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fakeRemoteScene")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        (atlas, labels) = try Self.makeLabels(device: device)
        pool = TexturePool(device: device, width: Self.eyeSize * 2, height: Self.eyeSize, capacity: 12)
    }

    /// The uplink: keeps the newest snapshot. Each one carries the eye offsets
    /// and fields of view, so any single snapshot is enough to render from.
    func receive(_ snapshot: PCVRHeadPoseSnapshot) {
        latest.withLock { latest in
            if let current = latest, !PCVRSerialNumber.isNewer(snapshot.sequence, than: current.sequence) { return }
            latest = snapshot
        }
    }

    func start() {
        guard running.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let thread = Thread { [self] in run() }
        thread.name = "PCVR fake remote"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        running.withLock { $0 = false }
    }

    // MARK: Loop

    private func run() {
        log.notice("Fake remote started")
        var next = CACurrentMediaTime()
        while running.withLock({ $0 }) {
            let settings = self.settings.withLock { $0 }
            let period = 1 / max(settings.frameRate, 1)
            let now = CACurrentMediaTime()
            if next > now { Thread.sleep(forTimeInterval: next - now) }
            // Late by more than a frame (a hitch, or a lowered rate): restart the
            // cadence from now instead of rendering a burst to catch up.
            next = max(next + period, CACurrentMediaTime())
            renderFrame(settings: settings)
        }
        log.notice("Fake remote stopped")
    }

    private func renderFrame(settings: PCVRFakeRemoteSettings) {
        guard let snapshot = latest.withLock({ $0 }) else { return }
        // A lease returns its texture to the pool when its last reference goes,
        // on every path: a failed command buffer below, or the frame's end.
        guard let lease = pool.checkOut() else {
            tally.withLock { $0.stalled += 1 }
            return
        }
        frameNumber &+= 1
        let renderPose = PCVRRenderPose(
            poseSequence: snapshot.sequence,
            spaceEpoch: snapshot.spaceEpoch,
            displayTime: snapshot.displayTime,
            eyes: snapshot.eyes.map { geometry in
                var view = geometry.view(head: snapshot.head)
                view.fieldOfView = view.fieldOfView.expanded(by: settings.overscan)
                return view
            })
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        encodeScene(into: lease.texture, renderPose: renderPose, time: Float(CACurrentMediaTime() - startTime),
                    commandBuffer: commandBuffer)
        let number = frameNumber
        let renderedAt = CACurrentMediaTime()
        // Delivered only once the GPU has finished, like a decoder's output, so
        // the receiver never samples a half-rendered texture from another queue.
        commandBuffer.addCompletedHandler { [delivery, mailbox, tally] _ in
            let due = renderedAt + settings.delay
            delivery.asyncAfter(deadline: .now() + max(due - CACurrentMediaTime(), 0)) {
                let frame = PCVRDecodedFrame(frameNumber: number, texture: lease.texture, renderPose: renderPose,
                                             arrivalTime: CACurrentMediaTime(),
                                             release: { withExtendedLifetime(lease) {} })
                mailbox.deliver(frame)
                tally.withLock { $0.rendered += 1 }
            }
        }
        commandBuffer.commit()
    }

    private func encodeScene(into texture: any MTLTexture, renderPose: PCVRRenderPose, time: Float,
                             commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Fake remote scene"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(atlas, index: 0)
        var labels = self.labels
        encoder.setFragmentBytes(&labels, length: MemoryLayout<Label>.stride * labels.count, index: 1)
        let half = Double(texture.width / 2)
        for eye in 0..<2 {
            let view = renderPose.eyes[eye]
            let fov = view.fieldOfView
            var uniforms = EyeUniforms(worldFromEye: view.pose.matrix,
                                       tangents: fov.tangents,
                                       parameters: SIMD4(time, Float(labels.count), 0, 0))
            encoder.setViewport(MTLViewport(originX: half * Double(eye), originY: 0, width: half,
                                            height: Double(texture.height), znear: 0, zfar: 1))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EyeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    // MARK: Scene data

    private struct EyeUniforms {
        var worldFromEye: simd_float4x4
        var tangents: SIMD4<Float>
        /// x: seconds, y: label count.
        var parameters: SIMD4<Float>
    }

    /// A text panel in the room: centre, half-extent axes and its atlas row.
    private struct Label {
        var center: SIMD4<Float>
        var right: SIMD4<Float>   // xyz unit axis, w half width
        var up: SIMD4<Float>      // xyz unit axis, w half height
        var atlasRect: SIMD4<Float>
    }

    private static func makeLabels(device: any MTLDevice) throws -> (any MTLTexture, [Label]) {
        typealias Placement = (text: String, center: SIMD3<Float>, right: SIMD3<Float>, halfHeight: Float)
        let placements: [Placement] = [
            ("NORTH  -Z", SIMD3(0, 2.2, -2.99), SIMD3(1, 0, 0), 0.18),
            ("EAST  +X", SIMD3(2.99, 2.2, 0), SIMD3(0, 0, 1), 0.18),
            ("SOUTH  +Z", SIMD3(0, 2.2, 2.99), SIMD3(-1, 0, 0), 0.18),
            ("WEST  -X", SIMD3(-2.99, 2.2, 0), SIMD3(0, 0, -1), 0.18),
            ("0.5 m", SIMD3(0.12, 1.5, -0.5), SIMD3(1, 0, 0), 0.012),
            ("1 m", SIMD3(-0.25, 1.6, -1.0), SIMD3(1, 0, 0), 0.025),
            ("2 m", SIMD3(0.5, 1.6, -2.0), SIMD3(1, 0, 0), 0.05),
        ]
        let width = 1024, rowHeight = 128
        let height = rowHeight * placements.count
        var pixels = [UInt8](repeating: 0, count: width * height)
        var aspects: [Float] = []
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            for (row, placement) in placements.enumerated() {
                let attributes = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, placement.text as CFString, attributes))
                let textWidth = min(CGFloat(width - 32), CTLineGetTypographicBounds(line, nil, nil, nil))
                // CoreGraphics' origin is bottom-left; row 0 is the top of the texture.
                let baseline = CGFloat(height - (row + 1) * rowHeight) + 30
                context.textPosition = CGPoint(x: 16, y: baseline)
                CTLineDraw(line, context)
                aspects.append(Float(textWidth + 32) / Float(rowHeight))
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("label atlas")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels,
                        bytesPerRow: width)
        let labels = placements.enumerated().map { row, placement in
            let aspect = aspects.indices.contains(row) ? aspects[row] : 4
            let rowV = Float(row) / Float(placements.count)
            return Label(center: SIMD4(placement.center, 0),
                         right: SIMD4(placement.right, placement.halfHeight * aspect),
                         up: SIMD4(0, 1, 0, placement.halfHeight),
                         atlasRect: SIMD4(0, rowV, aspect * Float(rowHeight) / Float(width), 1 / Float(placements.count)))
        }
        return (texture, labels)
    }

    // MARK: Texture pool

    /// Stream textures, reused once nothing leases them: a lease hands its
    /// texture back when it is deallocated, so no exit path can forget to. Grows on demand to
    /// `capacity`: at zero delay a handful suffice; at 60 ms and 90 fps about
    /// six are queued for delivery while the receiver holds two or three more.
    private final class TexturePool: @unchecked Sendable {
        final class Lease: @unchecked Sendable {
            let texture: any MTLTexture
            private weak var pool: TexturePool?
            init(texture: any MTLTexture, pool: TexturePool) {
                self.texture = texture
                self.pool = pool
            }
            deinit { pool?.recycle(texture) }
        }

        private let device: any MTLDevice
        private let descriptor: MTLTextureDescriptor
        private let capacity: Int
        private let state = OSAllocatedUnfairLock(initialState: (free: [any MTLTexture](), made: 0))

        init(device: any MTLDevice, width: Int, height: Int, capacity: Int) {
            self.device = device
            self.capacity = capacity
            descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width,
                                                                  height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
        }

        func checkOut() -> Lease? {
            let reused: (any MTLTexture)? = state.withLock { state in
                state.free.popLast()
            }
            if let reused { return Lease(texture: reused, pool: self) }
            let mayMake = state.withLock { state in
                guard state.made < capacity else { return false }
                state.made += 1
                return true
            }
            guard mayMake, let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "PCVR fake remote frame"
            return Lease(texture: texture, pool: self)
        }

        fileprivate func recycle(_ texture: any MTLTexture) {
            state.withLock { $0.free.append(texture) }
        }
    }

    // MARK: Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EyeUniforms {
        float4x4 worldFromEye;
        float4 tangents;     // signed tangents (left, right, up, down), left and down negative
        float4 parameters;   // x: seconds, y: label count
    };

    struct Label {
        float4 center;
        float4 right;
        float4 up;
        float4 atlasRect;
    };

    struct FullScreenOut {
        float4 position [[position]];
        float2 ndc;
    };

    vertex FullScreenOut fakeRemoteVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        FullScreenOut out;
        out.position = float4(p, 0.0, 1.0);
        out.ndc = p;
        return out;
    }

    // Grid lines on a face: 25 cm minor, 1 m major, antialiased by screen-space width.
    static float gridLines(float2 coordinate) {
        float2 minorWidth = fwidth(coordinate * 4.0);
        float2 minor = abs(fract(coordinate * 4.0 - 0.5) - 0.5) / max(minorWidth, 1e-4);
        float2 majorWidth = fwidth(coordinate);
        float2 major = abs(fract(coordinate - 0.5) - 0.5) / max(majorWidth, 1e-4);
        float minorLine = 1.0 - saturate(min(minor.x, minor.y));
        float majorLine = 1.0 - saturate(min(major.x, major.y) / 2.0);
        return max(minorLine * 0.35, majorLine);
    }

    // Slab test against an axis-aligned cube; returns the entry distance or -1.
    static float hitCube(float3 origin, float3 direction, float3 center, float halfSize, thread float3 &normal) {
        float3 inverse = 1.0 / direction;
        float3 t0 = (center - halfSize - origin) * inverse;
        float3 t1 = (center + halfSize - origin) * inverse;
        float3 near = min(t0, t1), far = max(t0, t1);
        float entry = max(max(near.x, near.y), near.z);
        float exit = min(min(far.x, far.y), far.z);
        if (entry > exit || exit < 0.0) { return -1.0; }
        normal = (entry == near.x) ? float3(-sign(direction.x), 0, 0)
               : (entry == near.y) ? float3(0, -sign(direction.y), 0)
               : float3(0, 0, -sign(direction.z));
        return entry;
    }

    fragment float4 fakeRemoteScene(FullScreenOut in [[stage_in]],
                                    constant EyeUniforms &u [[buffer(0)]],
                                    constant Label *labels [[buffer(1)]],
                                    texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float2 t = in.ndc * 0.5 + 0.5;
        float3 eyeDirection = normalize(float3(mix(u.tangents.x, u.tangents.y, t.x),
                                               mix(u.tangents.w, u.tangents.z, t.y), -1.0));
        float3 origin = u.worldFromEye[3].xyz;
        float3 direction = normalize((u.worldFromEye * float4(eyeDirection, 0.0)).xyz);

        // The room, seen from inside: the nearest face the ray leaves through.
        float3 roomMin = float3(-3.0, 0.0, -3.0), roomMax = float3(3.0, 3.0, 3.0);
        float3 exits = (select(roomMin, roomMax, direction > 0.0) - origin) / direction;
        float best = min(min(exits.x, exits.y), exits.z);
        float3 hit = origin + direction * best;
        float3 color;
        float2 faceCoordinate;
        if (best == exits.y) {
            bool floor = direction.y < 0.0;
            color = floor ? float3(0.16, 0.16, 0.18) : float3(0.30, 0.30, 0.32);
            faceCoordinate = hit.xz;
        } else if (best == exits.x) {
            color = direction.x > 0.0 ? float3(0.42, 0.16, 0.14) : float3(0.40, 0.36, 0.12);   // east red, west yellow
            faceCoordinate = hit.zy;
        } else {
            color = direction.z < 0.0 ? float3(0.12, 0.20, 0.42) : float3(0.12, 0.34, 0.18);   // north blue, south green
            faceCoordinate = hit.xy;
        }
        color = mix(color, float3(0.92), gridLines(faceCoordinate));

        // Depth markers ahead and one cube orbiting on the remote's clock.
        const float4 markers[3] = { float4(0.12, 1.45, -0.5, 0.025), float4(-0.25, 1.5, -1.0, 0.05),
                                    float4(0.5, 1.4, -2.0, 0.1) };
        const float3 markerColors[3] = { float3(1.0, 0.45, 0.1), float3(0.1, 0.85, 0.95), float3(0.95, 0.2, 0.8) };
        float3 light = normalize(float3(0.4, 1.0, 0.6));
        for (int i = 0; i < 4; i++) {
            float4 marker;
            float3 markerColor;
            if (i < 3) {
                marker = markers[i];
                markerColor = markerColors[i];
            } else {
                float angle = u.parameters.x * (2.0 * M_PI_F / 6.0);
                marker = float4(1.2 * sin(angle), 1.0, -1.2 * cos(angle), 0.06);
                markerColor = float3(1.0, 0.9, 0.1);
            }
            float3 normal;
            float distance = hitCube(origin, direction, marker.xyz, marker.w, normal);
            if (distance > 0.0 && distance < best) {
                best = distance;
                color = markerColor * (0.35 + 0.65 * saturate(dot(normal, light)));
            }
        }

        // Text panels: dark plate, white text from the atlas.
        int labelCount = int(u.parameters.y);
        for (int i = 0; i < labelCount; i++) {
            Label label = labels[i];
            float3 normal = cross(label.right.xyz, label.up.xyz);
            float facing = dot(direction, normal);
            if (abs(facing) < 1e-5) { continue; }
            float distance = dot(label.center.xyz - origin, normal) / facing;
            if (distance <= 0.0 || distance >= best) { continue; }
            float3 local = origin + direction * distance - label.center.xyz;
            float2 panel = float2(dot(local, label.right.xyz) / label.right.w, dot(local, label.up.xyz) / label.up.w);
            if (any(abs(panel) > 1.0)) { continue; }
            float2 uv = label.atlasRect.xy + float2(panel.x * 0.5 + 0.5, 0.5 - panel.y * 0.5) * label.atlasRect.zw;
            float ink = atlas.sample(linearSampler, uv).r;
            best = distance;
            color = mix(float3(0.05, 0.05, 0.07), float3(1.0), ink);
        }
        return float4(color, 1.0);
    }
    """
}
#endif
