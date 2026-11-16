import Metal
import StreamWire
import UIKit
import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
/// A bench for the overlay's depth warp, off the headset: a ray-cast room like
/// the PC's test scene (grid walls, a checker floor, a near text board, a
/// spoked wheel, a thin pole) rendered at any eye pose, its depth reduced the
/// way the host sends it (the nearest depth under each output texel, 8-bit
/// inverse depth from 0.25 m), warped by `PCVRDepthWarper` to a target pose,
/// and compared with the room rendered at that pose: the truth.
///
/// Opt-in, since it writes images: `TEST_RUNNER_PCVR_BENCH=<directory>`
/// on the `xcodebuild test` line. Each case prints its error and writes the
/// warped picture, the truth and their difference (amplified) there.
///
/// Scale: an eye of 2592x2080 over the display's frustum, so a depth divisor
/// of 4 here is the stream's 8 (`--depth-scale 8`, 0.19 degrees a texel)
/// and 1 here its 2.
final class PCVRWarpBenchTests: XCTestCase {
    static let width = 2592, height = 2080
    static let left = PCVRFieldOfView(tangentLeft: -1.7666, tangentRight: 1.02, tangentUp: 1.02, tangentDown: -1.2158)
    static let right = PCVRFieldOfView(tangentLeft: -1.02, tangentRight: 1.7666, tangentUp: 1.02, tangentDown: -1.2158)
    static let ipd: Float = 0.064
    /// The head: 1.4 m up, half a metre in front of the room's centre, looking down -z.
    static let head = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.1, 1.45, 0.4])

    var device: (any MTLDevice)!
    var queue: (any MTLCommandQueue)!
    private var pipeline: (any MTLComputePipelineState)!
    var directory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["PCVR_BENCH"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PCVR_BENCH=<output directory> to run the warp bench")
        }
        directory = URL(fileURLWithPath: path)
        // `PCVR_BENCH_BOUND_PASSES=0`: the march from the stream's near depth, for comparison.
        if let passes = ProcessInfo.processInfo.environment["PCVR_BENCH_BOUND_PASSES"].flatMap(Int.init) {
            PCVRDepthWarper.boundPasses = passes
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try device.makeLibrary(source: Self.sceneSource, options: nil)
        pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "benchRender")))
        depthPipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "benchDepth")))
        scorePipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "benchScore")))
    }

    private var depthPipeline: (any MTLComputePipelineState)!
    /// The last `scoreGPU`'s pixels outside the source eye's frame: error sum and count.
    private var lastOutside: (Double, Int) = (0, 0)
    var lastScoreMap: (any MTLTexture)?
    private var scorePipeline: (any MTLComputePipelineState)!

    // MARK: The room

    struct Rendered {
        var colour: any MTLTexture   // both eyes side by side, rgba16Float
        var depth: [Float]           // eye-space distance along -z per pixel, 0 for the sky
        var depthTexture: (any MTLTexture)? = nil   // the same, r32Float
    }

    private struct EyeUniforms {
        var worldFromEye: simd_float4x4
        var tangents: SIMD4<Float>
        var origin: UInt32
        var samples: UInt32
        var size: SIMD2<UInt32>
    }

    /// The eyes at `head`, each `margin` metres outward of the real eye (the overlay's render margin).
    static func eyes(head: PCVRPose, margin: Float = 0, overscan: Float = 1) -> PCVRStereo<PCVREyeView> {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let grow = max(overscan, 1) - 1
        return PCVRStereo(
            left: PCVREyeView(pose: head * PCVRPose(rotation: identity, position: [-ipd / 2 - margin, 0, 0]),
                              fieldOfView: left.expanded(by: grow)),
            right: PCVREyeView(pose: head * PCVRPose(rotation: identity, position: [ipd / 2 + margin, 0, 0]),
                               fieldOfView: right.expanded(by: grow)))
    }

    func render(_ eyes: PCVRStereo<PCVREyeView>, readDepth: Bool = true) throws -> Rendered {
        let w = Self.width, h = Self.height
        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2 * w, height: h,
                                                                        mipmapped: false)
        colourDescriptor.usage = [.shaderRead, .shaderWrite]
        colourDescriptor.storageMode = .shared
        let colour = try XCTUnwrap(device.makeTexture(descriptor: colourDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 2 * w, height: h,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.shaderRead, .shaderWrite]
        depthDescriptor.storageMode = .shared
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        var uniforms = (0..<2).map { eye in
            let view = eyes[eye]
            return EyeUniforms(worldFromEye: Self.matrix(view.pose), tangents: view.fieldOfView.tangents,
                               origin: UInt32(eye * w), samples: 3, size: SIMD2(UInt32(w), UInt32(h)))
        }
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(colour, index: 0)
        encoder.setTexture(depth, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<EyeUniforms>.stride * 2, index: 0)
        encoder.dispatchThreads(MTLSize(width: 2 * w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        guard readDepth else { return Rendered(colour: colour, depth: [], depthTexture: depth) }
        var values = [Float](repeating: 0, count: 2 * w * h)
        values.withUnsafeMutableBytes {
            depth.getBytes($0.baseAddress!, bytesPerRow: 2 * w * 4, from: MTLRegionMake2D(0, 0, 2 * w, h), mipmapLevel: 0)
        }
        return Rendered(colour: colour, depth: values, depthTexture: depth)
    }

    /// `hostDepth` on the GPU: the nearest depth under each output texel, 8-bit inverse depth from 0.25 m.
    func hostDepthGPU(_ rendered: Rendered, divisor: Int, bits: Int = 8, noise: Int = 0) throws -> PCVRDepthMap {
        let w = Self.width, h = Self.height, dw = w / divisor, dh = h / divisor
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bits == 8 ? .r8Unorm : .r32Float, width: 2 * dw, height: dh, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let out = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var uniforms = SIMD4<UInt32>(UInt32(divisor), UInt32(w), UInt32(dw), UInt32(bits) | (UInt32(noise) << 8))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(depthPipeline)
        encoder.setTexture(try XCTUnwrap(rendered.depthTexture), index: 0)
        encoder.setTexture(out, index: 1)
        encoder.setBytes(&uniforms, length: 16, index: 0)
        encoder.dispatchThreads(MTLSize(width: 2 * dw, height: dh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return PCVRDepthMap(texture: out, near: 0.25, far: .infinity)
    }

    private struct ScoreUniforms {
        var sourceFromTruth: simd_float4x4
        var truthTangents: SIMD4<Float>
        var sourceTangents: SIMD4<Float>
        /// Only pixels inside this frustum count: what the display shows of the picture.
        var displayTangents: SIMD4<Float>
        var size: SIMD2<UInt32>
        var border: UInt32
        var pad: UInt32 = 0
    }

    /// The left eye's score on the GPU: per pixel the error and whether the source eye saw its point.
    /// Returns (sum of error over seen pixels, seen count, sum over unseen, unseen count).
    func scoreGPU(warped: any MTLTexture, truth: Rendered, truthEye: PCVREyeView, source: Rendered,
                          sourceEye: PCVREyeView, display: PCVRFieldOfView? = nil, readSummary: Bool = true) throws -> (seen: Double, seenCount: Int, hidden: Double, hiddenCount: Int) {
        let w = Self.width, h = Self.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let out = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var uniforms = ScoreUniforms(sourceFromTruth: Self.matrix(sourceEye.pose).inverse * Self.matrix(truthEye.pose),
                                     truthTangents: truthEye.fieldOfView.tangents, sourceTangents: sourceEye.fieldOfView.tangents,
                                     displayTangents: (display ?? truthEye.fieldOfView).tangents,
                                     size: SIMD2(UInt32(w), UInt32(h)), border: display == nil ? UInt32(w / 25) : 0)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(scorePipeline)
        encoder.setTexture(warped, index: 0)
        encoder.setTexture(truth.colour, index: 1)
        encoder.setTexture(try XCTUnwrap(truth.depthTexture), index: 2)
        encoder.setTexture(try XCTUnwrap(source.depthTexture), index: 3)
        encoder.setTexture(out, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<ScoreUniforms>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastScoreMap = out
        if !readSummary { return (0, 0, 0, 0) }
        var values = [Float](repeating: 0, count: w * h * 2)
        values.withUnsafeMutableBytes {
            out.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var seen = 0.0, hidden = 0.0, outside = 0.0, seenCount = 0, hiddenCount = 0, outsideCount = 0
        values.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                let e = p[i]
                if e >= 0 {
                    if p[i + 1] > 1.5 { outside += Double(e); outsideCount += 1 }
                    else if p[i + 1] > 0.5 { hidden += Double(e); hiddenCount += 1 }
                    else { seen += Double(e); seenCount += 1 }
                }
                i += 2
            }
        }
        lastOutside = (outside, outsideCount)
        return (seen, seenCount, hidden, hiddenCount)
    }

    // MARK: A recorded head motion

    /// Measured head poses (`t`, position, quaternion), from the overlay's pose recorder.
    struct Trajectory {
        var times: [Double]
        var poses: [PCVRPose]

        init(contentsOf url: URL) throws {
            struct File: Decodable { var rows: [[Double]] }
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.rows.count >= 2, file.rows.allSatisfy({ $0.count >= 8 && $0.allSatisfy(\.isFinite) }),
                  zip(file.rows, file.rows.dropFirst()).allSatisfy({ $0[0] < $1[0] }) else {
                throw NSError(domain: "PCVRWarpBench", code: 1, userInfo: [NSLocalizedDescriptionKey: "motion requires two or more finite, ordered pose rows"])
            }
            times = file.rows.map { $0[0] }
            poses = file.rows.map { r in
                PCVRPose(rotation: simd_quatf(ix: Float(r[4]), iy: Float(r[5]), iz: Float(r[6]), r: Float(r[7])).normalized,
                         position: SIMD3(Float(r[1]), Float(r[2]), Float(r[3])))
            }
        }

        func pose(at t: Double) -> PCVRPose {
            guard let j = times.firstIndex(where: { $0 >= t }), j > 0 else { return t <= times[0] ? poses[0] : poses[poses.count - 1] }
            let a = Float((t - times[j - 1]) / max(times[j] - times[j - 1], 1e-6))
            return PCVRPose(rotation: simd_slerp(poses[j - 1].rotation, poses[j].rotation, a),
                            position: simd_mix(poses[j - 1].position, poses[j].position, SIMD3(repeating: a)))
        }

        /// The fastest the head turned in `range`, rad/s, sample to sample.
        func peakRate(over range: ClosedRange<Double>) -> Float {
            var peak: Float = 0
            for i in 1..<times.count where range.contains(times[i]) {
                let dt = Float(times[i] - times[i - 1])
                guard dt > 1e-4 else { continue }
                var dq = poses[i].rotation * poses[i - 1].rotation.inverse
                if dq.real < 0 { dq = simd_quatf(ix: -dq.imag.x, iy: -dq.imag.y, iz: -dq.imag.z, r: -dq.real) }
                peak = max(peak, dq.angle / dt)
            }
            return peak
        }

        /// The overlay's predictor (`V3HeadPredictor`, linear at `gain`): from the pose at `t`,
        /// with the velocity over the 30 ms before it, `ahead` seconds on.
        func predicted(at t: Double, ahead: Double, gain: Float) -> PCVRPose {
            let now = pose(at: t), before = pose(at: t - 0.03)
            let velocity = (now.position - before.position) / 0.03
            var dq = now.rotation * before.rotation.inverse
            if dq.real < 0 { dq = simd_quatf(ix: -dq.imag.x, iy: -dq.imag.y, iz: -dq.imag.z, r: -dq.real) }
            let rate = dq.angle / 0.03
            let rotation = rate > 1e-4 ? simd_quatf(angle: gain * rate * Float(ahead), axis: dq.axis) * now.rotation : now.rotation
            return PCVRPose(rotation: rotation.normalized, position: now.position + gain * velocity * Float(ahead))
        }
    }

    /// The recorded motion replayed against the room: each 60 fps frame rendered for the pose
    /// predicted `span` ahead (the display lead plus the pose horizon), warped to where the head
    /// really was then, with the overlay's history of earlier frames as fills or without it; scored
    /// over the pixels no frame's eye saw. `TEST_RUNNER_PCVR_BENCH_TRAJECTORY=<file>` (rows of
    /// t, x, y, z, qx, qy, qz, qw); `_SPANS_MS` (85: 120 Hz, 125: 60 Hz once warm), `_START`, `_SECONDS`.
    func testRecordedMotion() throws {
        guard let path = ProcessInfo.processInfo.environment["PCVR_BENCH_TRAJECTORY"], !path.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_PCVR_BENCH_TRAJECTORY to a recorded head motion")
        }
        let trajectory = try Trajectory(contentsOf: URL(fileURLWithPath: path))
        let offset = Double(ProcessInfo.processInfo.environment["PCVR_BENCH_START"] ?? "") ?? 10
        let start = trajectory.times[0] + offset
        let seconds = Double(ProcessInfo.processInfo.environment["PCVR_BENCH_SECONDS"] ?? "1.5") ?? 1.5
        let reference = trajectory.pose(at: start)
        /// The recorded head, moved so that it starts at the bench's head pose.
        func head(_ recorded: PCVRPose) -> PCVRPose { Self.head * (reference.inverse * recorded) }
        let divisor = Int(ProcessInfo.processInfo.environment["PCVR_BENCH_DIVISOR"] ?? "1") ?? 1
        let adaptive = Float(ProcessInfo.processInfo.environment["PCVR_BENCH_ADAPTIVE"] ?? "") ?? 0
        let adaptiveCap = Float(ProcessInfo.processInfo.environment["PCVR_BENCH_ADAPTIVE_CAP"] ?? "") ?? 1.3
        var report = ["span ms | history | frames | unseen pixels (share of the eye, mean error)"]
        for jitterMm in Self.list("PCVR_BENCH_JITTER_MM", [0]) {
        for overscan in Self.list("PCVR_BENCH_OVERSCANS", [1.02]) {
        for spanMs in Self.list("PCVR_BENCH_SPANS_MS", [85, 125]) {
            for useHistory in [false, true] {
                var history: [PCVRDepthWarper.FillSource] = []
                var seen = 0.0, seenCount = 0, hidden = 0.0, hiddenCount = 0, frames = 0
                var outside = 0.0, outsideCount = 0
                var overscanSum = 0.0
                var worst: (share: Double, frame: Int) = (0, -1)
                let span = Double(spanMs) / 1000
                var k = 0
                while Double(k) / 60 < seconds {
                  // Each frame's textures (about 260 MB) freed before the next: without a
                  // pool they piled up until the GPU stalled in a render (2026-11-08).
                  try autoreleasepool {
                    let sampled = start + Double(k) / 60
                    let lead = spanMs > 100 ? 0.042 : 0.025
                    var rendered = head(trajectory.predicted(at: sampled + lead, ahead: span - lead, gain: 0.5))
                    // Viewpoint jitter: each frame rendered a little off the prediction, in turn
                    // right, left, up, down, so recent frames have seen round near edges every way.
                    let pattern: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]]
                    rendered.position += rendered.rotation.act(pattern[k % 4] * jitterMm / 1000)
                    let actual = head(trajectory.pose(at: sampled + span))
                    // The truth in the frame's own frustum: the warp writes the picture there (the
                    // overlay's mesh covers that frustum, and the display shows part of it).
                    // Adaptive (`PCVR_BENCH_ADAPTIVE` = gain): wider while the head has turned fast lately,
                    // from the peak rate over the last half second, at least `overscan`.
                    var frameOverscan = overscan
                    if adaptive > 0 {
                        let peak = trajectory.peakRate(over: (sampled + lead - 0.5)...(sampled + lead))
                        frameOverscan = min(max(overscan, 1 + adaptive * peak * Float(span)), adaptiveCap)
                    }
                    overscanSum += Double(frameOverscan)
                    let renderEyes = Self.eyes(head: rendered, overscan: frameOverscan), truthEyes = Self.eyes(head: actual, overscan: frameOverscan)
                    let source = try render(renderEyes, readDepth: false)
                    let truth = try render(truthEyes, readDepth: false)
                    let depth = try hostDepthGPU(source, divisor: divisor)
                    let frame = PCVRDecodedFrame(streamEpoch: 0, frameNumber: UInt32(k + 1), texture: source.colour,
                                                 renderPose: PCVRRenderPose(poseSequence: UInt32(k + 1), spaceEpoch: 0,
                                                                            displayTime: sampled + span, eyes: renderEyes),
                                                 arrivalTime: 0)
                    let targets = PCVRStereo(left: truthEyes.left.pose, right: truthEyes.right.pose)
                    let warped = try warp(frame, depth: depth, to: targets, fills: useHistory ? history : [])
                    let s = try scoreGPU(warped: warped, truth: truth, truthEye: truthEyes.left, source: source, sourceEye: renderEyes.left,
                                         display: Self.left)
                    seen += s.seen; seenCount += s.seenCount; hidden += s.hidden; hiddenCount += s.hiddenCount
                    outside += lastOutside.0; outsideCount += lastOutside.1
                    let share = Double(s.hiddenCount) / Double(max(s.seenCount + s.hiddenCount + lastOutside.1, 1))
                    if share > worst.share { worst = (share, k) }
                    frames += 1
                    // The presenter's history (`remember`): newest last, at most `fillFrames`, none
                    // over 0.35 s older than the newest, no two within 5 mm.
                    let position = renderEyes.left.pose.position
                    history.removeAll { old in
                        frame.renderPose.displayTime - old.frame.renderPose.displayTime > 0.35
                            || simd_distance(old.frame.renderPose.eyes.left.pose.position, position) < 0.005
                    }
                    history.append(PCVRDepthWarper.FillSource(frame: frame, depth: depth))
                    if history.count > PCVRDepthWarper.fillFrames { history.removeFirst(history.count - PCVRDepthWarper.fillFrames) }
                  }
                  k += 1
                }
                let total = Double(max(seenCount + hiddenCount + outsideCount, 1))
                report.append(String(format: "jitter %.0f mm | overscan %.2f (mean %.3f) | %.0f | %@ | %d | behind objects %.3f %% err %.4f | past the frame edge %.3f %% err %.4f | visible err %.4f (worst frame %d: %.2f %% behind objects)",
                                     jitterMm, overscan, overscanSum / Double(max(frames, 1)), spanMs, useHistory ? "on" : "off", frames,
                                     Double(hiddenCount) / total * 100, hidden / Double(max(hiddenCount, 1)),
                                     Double(outsideCount) / total * 100, outside / Double(max(outsideCount, 1)),
                                     seen / Double(max(seenCount, 1)), worst.frame, worst.share * 100))
            }
        }
        }
        }
        let text = report.joined(separator: "\n")
        print(text)
        try text.write(to: directory.appendingPathComponent("motion-report.txt"), atomically: true, encoding: .utf8)
    }

    static func matrix(_ pose: PCVRPose) -> simd_float4x4 {
        var m = simd_float4x4(pose.rotation)
        m.columns.3 = SIMD4(pose.position, 1)
        return m
    }

    /// The host's depth picture: per output texel the nearest depth under it
    /// (`depth_estimate.cpp`, ps_linear), as 8-bit inverse depth from 0.25 m.
    private func hostDepth(_ rendered: Rendered, divisor: Int) throws -> PCVRDepthMap {
        let w = Self.width, h = Self.height
        let dw = w / divisor, dh = h / divisor
        let noise = Int(ProcessInfo.processInfo.environment["PCVR_BENCH_DEPTH_NOISE"] ?? "") ?? 0
        var bytes = [UInt8](repeating: 0, count: 2 * dw * dh)
        for eye in 0..<2 {
            for y in 0..<dh {
                for x in 0..<dw {
                    var nearest = Float.infinity
                    for sy in 0..<divisor {
                        let row = (y * divisor + sy) * 2 * w + eye * w + x * divisor
                        for sx in 0..<divisor {
                            let z = rendered.depth[row + sx]
                            if z > 0 { nearest = min(nearest, z) }
                        }
                    }
                    let v = nearest.isFinite ? min(max(0.25 / nearest, 0), 1) : 0
                    // Codec noise, `PCVR_BENCH_DEPTH_NOISE` codes at most (the stream's
                    // depth is HEVC at QP 12): a fixed pattern, so cases compare.
                    var code = (v * 255).rounded()
                    if noise > 0 {
                        var h = UInt32(truncatingIfNeeded: (eye * 7919 + y) &* 73_856_093 ^ x &* 19_349_663)
                        h = (h ^ (h >> 13)) &* 1_274_126_177
                        code += Float(Int(h % UInt32(2 * noise + 1)) - noise)
                    }
                    bytes[y * 2 * dw + eye * dw + x] = UInt8(min(max(code, 0), 255))
                }
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 2 * dw, height: dh, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 2 * dw, dh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2 * dw)
        }
        return PCVRDepthMap(texture: texture, near: 0.25, far: .infinity)
    }

    // MARK: Warp and compare

    struct Score: CustomStringConvertible {
        var meanError: Float
        /// Share of pixels off by more than 0.1 (of 1) in any channel's mean: what reads as wrong.
        var wrongPercent: Float
        /// Of those, the share inside 12 pixels of a silhouette in the truth.
        var wrongAtEdgesPercent: Float
        /// Pixels whose true point the source eye could not see (hidden, or outside its frame): the strips a
        /// fill has to make up, as a share of all; their mean error; and the visible pixels' mean error.
        var uncoveredPercent: Float = 0
        var uncoveredError: Float = 0
        var visibleError: Float = 0
        var description: String {
            String(format: "visible err %.4f | uncovered %.2f %% of px, err %.3f | wrong %.2f %% (%.2f %% at silhouettes)",
                   visibleError, uncoveredPercent, uncoveredError, wrongPercent, wrongAtEdgesPercent)
        }
    }

    /// Which left-eye pixels of the truth (rendered from `truthEye`) show a point the source's left eye
    /// (`sourceEye`, depth `source`) could not see: behind something nearer, or outside its frame.
    private func uncoveredMask(truth: Rendered, truthEye: PCVREyeView, source: Rendered, sourceEye: PCVREyeView) -> [Bool] {
        let w = Self.width, h = Self.height, rowStride = 2 * w
        let t = truthEye.fieldOfView.tangents, s = sourceEye.fieldOfView.tangents
        let worldFromTruth = Self.matrix(truthEye.pose), sourceFromWorld = Self.matrix(sourceEye.pose).inverse
        let sourceFromTruth = sourceFromWorld * worldFromTruth
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let z = truth.depth[y * rowStride + x]
                guard z > 0 else { continue } // the sky is everywhere
                let u = (Float(x) + 0.5) / Float(w), v = (Float(y) + 0.5) / Float(h)
                let p = SIMD4((t.x + u * (t.y - t.x)) * z, (t.z - v * (t.z - t.w)) * z, -z, 1)
                let q = sourceFromTruth * p
                let zs = -q.z
                guard zs > 0.01 else { mask[y * w + x] = true; continue }
                let su = (q.x / zs - s.x) / (s.y - s.x), sv = (s.z - q.y / zs) / (s.z - s.w)
                guard su >= 0, su < 1, sv >= 0, sv < 1 else { mask[y * w + x] = true; continue }
                let sx = min(Int(su * Float(w)), w - 1), sy = min(Int(sv * Float(h)), h - 1)
                var seen = false
                // Seen if any source pixel round it sees a point at that depth (a pixel of slack at edges).
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = min(max(sx + dx, 0), w - 1), yy = min(max(sy + dy, 0), h - 1)
                        let d = source.depth[yy * rowStride + xx]
                        if d > 0, abs(d - zs) < 0.03 * zs { seen = true }
                    }
                }
                mask[y * w + x] = !seen
            }
        }
        return mask
    }

    private func warp(_ source: Rendered, depth: PCVRDepthMap?, from renderEyes: PCVRStereo<PCVREyeView>,
                      to targets: PCVRStereo<PCVRPose>, configure: (PCVRDepthWarper) -> Void = { _ in }) throws -> any MTLTexture {
        let frame = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1, texture: source.colour,
                                     renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0, eyes: renderEyes),
                                     arrivalTime: 0)
        return try warp(frame, depth: depth, to: targets, configure: configure)
    }

    private func warp(_ frame: PCVRDecodedFrame, depth: PCVRDepthMap?, to targets: PCVRStereo<PCVRPose>,
                      fills: [PCVRDepthWarper.FillSource] = [],
                      configure: (PCVRDepthWarper) -> Void = { _ in }) throws -> any MTLTexture {
        let warper = try PCVRDepthWarper(device: device)
        configure(warper)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2 * Self.width,
                                                                  height: Self.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let out = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, targets: targets, planeDistance: 50, into: out, fills: fills,
                          commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        withExtendedLifetime(frame) {}
        return out
    }

    private static func pixels(_ texture: any MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return values
    }

    /// Left eye only, a 4 % border left out (where the target sees past the source's frame).
    private func score(_ warped: [Float16], truth: Rendered, truthPixels: [Float16], uncovered: [Bool]) -> (Score, [UInt8]) {
        let w = Self.width, h = Self.height, rowStride = 2 * w
        let border = w / 25
        var diff = [UInt8](repeating: 0, count: w * h)
        var sum: Double = 0, count = 0, wrong = 0, wrongAtEdges = 0
        var hiddenSum: Double = 0, hiddenCount = 0, seenSum: Double = 0, seenCount = 0
        // Silhouettes in the truth: a depth jump of a fifth or more between neighbours, dilated 12 px.
        var edge = [Bool](repeating: false, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let z = truth.depth[y * rowStride + x]
                for (dx, dy) in [(1, 0), (0, 1)] {
                    let n = truth.depth[(y + dy) * rowStride + x + dx]
                    let a = z > 0 ? 1 / z : 0, b = n > 0 ? 1 / n : 0
                    if abs(a - b) > 0.2 * max(a, b) { edge[y * w + x] = true }
                }
            }
        }
        // Dilated separably: the last edge seen along each row, then each column.
        let reach = 12
        var rows = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            var last = -1_000
            for x in 0..<w { if edge[y * w + x] { last = x }; if x - last <= reach { rows[y * w + x] = true } }
            last = 1_000_000
            for x in stride(from: w - 1, through: 0, by: -1) { if edge[y * w + x] { last = x }; if last - x <= reach { rows[y * w + x] = true } }
        }
        var near = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            var last = -1_000
            for y in 0..<h { if rows[y * w + x] { last = y }; if y - last <= reach { near[y * w + x] = true } }
            last = 1_000_000
            for y in stride(from: h - 1, through: 0, by: -1) { if rows[y * w + x] { last = y }; if last - y <= reach { near[y * w + x] = true } }
        }
        for y in border..<(h - border) {
            for x in border..<(w - border) {
                let i = (y * rowStride + x) * 4
                var e: Float = 0
                for c in 0..<3 { e += abs(Float(warped[i + c]) - Float(truthPixels[i + c])) }
                e /= 3
                sum += Double(e)
                count += 1
                if uncovered[y * w + x] { hiddenSum += Double(e); hiddenCount += 1 } else { seenSum += Double(e); seenCount += 1 }
                if e > 0.1 {
                    wrong += 1
                    if near[y * w + x] { wrongAtEdges += 1 }
                }
                diff[y * w + x] = UInt8(min(e * 4, 1) * 255)
            }
        }
        let score = Score(meanError: Float(sum / Double(max(count, 1))), wrongPercent: Float(wrong) / Float(max(count, 1)) * 100,
                          wrongAtEdgesPercent: Float(wrongAtEdges) / Float(max(count, 1)) * 100,
                          uncoveredPercent: Float(hiddenCount) / Float(max(count, 1)) * 100,
                          uncoveredError: Float(hiddenSum / Double(max(hiddenCount, 1))),
                          visibleError: Float(seenSum / Double(max(seenCount, 1))))
        return (score, diff)
    }

    // MARK: Images

    /// Left eye, rows `y0..<y0+height` and columns `x0..<x0+width` of each picture side by side:
    /// truth | warped | difference.
    private func writeStrip(_ name: String, truth: [Float16], warped: [Float16], diff: [UInt8], x0: Int, y0: Int,
                            width: Int, height: Int) {
        let rowStride = 2 * Self.width, gap = 6
        let total = 3 * width + 2 * gap
        var rgba = [UInt8](repeating: 255, count: total * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = ((y0 + y) * rowStride + x0 + x) * 4
                for (column, picture) in [truth, warped].enumerated() {
                    let o = (y * total + column * (width + gap) + x) * 4
                    for c in 0..<3 { rgba[o + c] = UInt8(min(max(Float(picture[i + c]), 0), 1) * 255) }
                }
                let d = diff[(y0 + y) * Self.width + x0 + x]
                let o = (y * total + 2 * (width + gap) + x) * 4
                rgba[o] = d; rgba[o + 1] = d / 3; rgba[o + 2] = d / 3
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: total, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: total * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = UIImage(cgImage: image).pngData() else { return }
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    // MARK: Cases

    struct Case {
        var name: String
        /// The target eye's offset from the render eye, head space, metres; and a yaw, degrees.
        var move: SIMD3<Float>
        var yaw: Float = 0
    }

    static let cases: [Case] = [
        Case(name: "still", move: .zero),
        Case(name: "left10", move: [-0.010, 0, 0]),
        Case(name: "right20", move: [0.020, 0, 0]),
        Case(name: "left40", move: [-0.040, 0, 0]),
        Case(name: "right40", move: [0.040, 0, 0]),
        Case(name: "down15", move: [0, -0.015, 0]),
        Case(name: "fwd20", move: [0, 0, -0.020]),
        Case(name: "yaw3", move: .zero, yaw: 3),
    ]

    /// Depth divisors and render margins to compare (`PCVR_BENCH_DIVISORS`, `PCVR_BENCH_MARGINS_MM`, comma-separated).
    static func list(_ key: String, _ fallback: [Float]) -> [Float] {
        guard let text = ProcessInfo.processInfo.environment[key], !text.isEmpty else { return fallback }
        return text.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    }

    func testWarpAgainstTheTruth() throws {
        var report = ["case | depth divisor | margin mm | score"]
        var truths: [String: (Rendered, [Float16])] = [:]
        var masks: [String: [Bool]] = [:]
        for marginMm in Self.list("PCVR_BENCH_MARGINS_MM", [0]) {
          let renderEyes = Self.eyes(head: Self.head, margin: marginMm / 1000)
          let source = try render(renderEyes)
          for divisor in Self.list("PCVR_BENCH_DIVISORS", [1, 4]).map(Int.init) {
            let depth = try hostDepth(source, divisor: divisor)
            for c in Self.cases {
                var head = Self.head
                head.position += Self.head.rotation.act(c.move)
                head.rotation = simd_quatf(angle: c.yaw * .pi / 180, axis: [0, 1, 0]) * head.rotation
                let truthEyes = Self.eyes(head: head)
                if truths[c.name] == nil {
                    let truth = try render(truthEyes)
                    truths[c.name] = (truth, Self.pixels(truth.colour))
                }
                let (truth, truthPixels) = truths[c.name]!
                let warped = try warp(source, depth: depth, from: renderEyes, to: truthEyes.map(\.pose))
                let warpedPixels = Self.pixels(warped)
                let key = "\(c.name)-\(marginMm)"
                if masks[key] == nil {
                    masks[key] = uncoveredMask(truth: truth, truthEye: truthEyes.left, source: source, sourceEye: renderEyes.left)
                }
                let (score, diff) = self.score(warpedPixels, truth: truth, truthPixels: truthPixels, uncovered: masks[key]!)
                report.append("\(c.name) | \(divisor) | \(Int(marginMm)) | \(score)")
                let divisor = "\(divisor)m\(Int(marginMm))"
                if true {
                    // The wheel (round 1931, 907 in the left eye), the board's
                    // lower left corner (1166, 1153) and the pole (x 2395).
                    writeStrip("\(c.name)-d\(divisor)-wheel", truth: truthPixels, warped: warpedPixels, diff: diff,
                               x0: 1680, y0: 700, width: 520, height: 420)
                    writeStrip("\(c.name)-d\(divisor)-board", truth: truthPixels, warped: warpedPixels, diff: diff,
                               x0: 1000, y0: 950, width: 520, height: 420)
                    writeStrip("\(c.name)-d\(divisor)-pole", truth: truthPixels, warped: warpedPixels, diff: diff,
                               x0: 2060, y0: 1250, width: 440, height: 360)
                }
            }
          }
        }
        let text = report.joined(separator: "\n")
        print(text)
        try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Quality tiers, through the display path

    /// Warps `frame` straight into two display views of the bench's eye size
    /// (`PCVRDepthWarper.encode(frame:depth:views:)`, what Shell A's render
    /// loop calls), at the frame's own frusta so the room rendered at the
    /// target is still the truth. Returns the picture laid out like the
    /// compute path's (both eyes side by side) and the time of one encode,
    /// milliseconds: the least over `timedRuns` command buffers of
    /// `encodesPerRun` encodes each, from commit to completion on the wall
    /// clock (the simulator reports no GPU start and end times worth the
    /// name: 0.06-0.1 ms for all of this). It is the Mac's GPU, so only the
    /// ratio between two runs means anything.
    private func warpDisplay(_ frame: PCVRDecodedFrame, depth: PCVRDepthMap?, to targets: PCVRStereo<PCVREyeView>,
                             march: PCVRWarpMarch, timedRuns: Int = 12,
                             encodesPerRun: Int = 16) throws -> (pixels: [Float16], gpuMs: Double) {
        let w = Self.width, h = Self.height
        let near: Float = 0.1
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        var views: [PCVRReceiverTarget] = []
        for eye in 0..<2 {
            let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                                            mipmapped: false)
            colourDescriptor.usage = [.renderTarget, .shaderRead]
            colourDescriptor.storageMode = .shared
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h,
                                                                           mipmapped: false)
            depthDescriptor.usage = .renderTarget
            depthDescriptor.storageMode = .private
            views.append(PCVRReceiverTarget(
                eye: eye, colorTexture: try XCTUnwrap(device.makeTexture(descriptor: colourDescriptor)),
                depthTexture: try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor)), depthClearValue: 0,
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1),
                display: targets[eye], displayProjection: projection))
        }
        let warper = try PCVRDepthWarper(device: device)
        warper.maxSteps = march.maxSteps
        warper.stepTexels = march.stepTexels
        warper.fillsFromOtherEye = march.fillsFromOtherEye
        // `PCVR_BENCH_TINT=1`: the filled pixels tinted, to see in the strips which pixels were made up.
        warper.tintsFills = ProcessInfo.processInfo.environment["PCVR_BENCH_TINT"] == "1"
        var times: [Double] = []
        // The first run compiles the pipelines and makes the map; it draws the picture and is not timed.
        for _ in 0...timedRuns {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            for _ in 0..<encodesPerRun {
                try warper.encode(frame: frame, depth: depth, views: views, planeDistance: 50, commandBuffer: commandBuffer)
            }
            let start = CACurrentMediaTime()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            times.append((CACurrentMediaTime() - start) * 1000 / Double(encodesPerRun))
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        }
        times.removeFirst()
        var pixels = [Float16](repeating: 0, count: 2 * w * h * 4)
        pixels.withUnsafeMutableBytes { bytes in
            for eye in 0..<2 {
                views[eye].colorTexture.getBytes(bytes.baseAddress! + eye * w * 8, bytesPerRow: 2 * w * 8,
                                                 from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            }
        }
        return (pixels, times.min() ?? 0)
    }

    /// Each `PCVRWarpTier` over the bench's moves, through the display path,
    /// at the headset's depth size (a divisor of 8 here: 324x260 an eye):
    /// the score against the truth and the encode's GPU time, per case and
    /// averaged per tier, beside the same encode without a depth map (one
    /// plane, no march: the part of the time no tier can touch).
    /// `PCVR_BENCH_TIER_STRIPS=1` writes the strips too, `PCVR_BENCH_CASES`
    /// (comma-separated names) picks the moves.
    func testWarpTiers() throws {
        let renderEyes = Self.eyes(head: Self.head)
        let source = try render(renderEyes)
        let frame = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1, texture: source.colour,
                                     renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0, eyes: renderEyes),
                                     arrivalTime: 0)
        let strips = ProcessInfo.processInfo.environment["PCVR_BENCH_TIER_STRIPS"] == "1"
        // Shell A's defaults (`PCVRShellDepthWarp`).
        let defaults = PCVRWarpMarch(maxSteps: 32, stepTexels: 2, fillsFromOtherEye: true)
        var report = ["case | depth divisor | tier | gpu ms | score"]
        for divisor in Self.list("PCVR_BENCH_DIVISORS", [8]).map(Int.init) {
            let depth = try hostDepth(source, divisor: divisor)
            var totals: [PCVRWarpTier: (gpu: Double, visible: Double, uncovered: Double, wrong: Double, count: Double)] = [:]
            var plane = 0.0, planeCount = 0.0
            let names = ProcessInfo.processInfo.environment["PCVR_BENCH_CASES"].map { $0.split(separator: ",").map(String.init) }
            for c in Self.cases where names?.contains(c.name) ?? true {
                var head = Self.head
                head.position += Self.head.rotation.act(c.move)
                head.rotation = simd_quatf(angle: c.yaw * .pi / 180, axis: [0, 1, 0]) * head.rotation
                let truthEyes = Self.eyes(head: head)
                let truth = try render(truthEyes)
                let truthPixels = Self.pixels(truth.colour)
                let mask = uncoveredMask(truth: truth, truthEye: truthEyes.left, source: source, sourceEye: renderEyes.left)
                try autoreleasepool {
                    plane += try warpDisplay(frame, depth: nil, to: truthEyes, march: defaults).gpuMs
                    planeCount += 1
                }
                // A pool per warp: its textures and pixel arrays are a few hundred megabytes, and the
                // simulator killed the run without one.
                for tier in PCVRWarpTier.allCases { try autoreleasepool {
                    let (pixels, gpu) = try warpDisplay(frame, depth: depth, to: truthEyes, march: tier.limiting(defaults))
                    let (score, diff) = self.score(pixels, truth: truth, truthPixels: truthPixels, uncovered: mask)
                    report.append(String(format: "%@ | %d | %@ | %.2f | %@", c.name, divisor, tier.name, gpu, score.description))
                    var total = totals[tier] ?? (0, 0, 0, 0, 0)
                    total.gpu += gpu
                    total.visible += Double(score.visibleError)
                    total.uncovered += Double(score.uncoveredError)
                    total.wrong += Double(score.wrongPercent)
                    total.count += 1
                    totals[tier] = total
                    if strips {
                        writeStrip("tier-\(tier.name)-\(c.name)-d\(divisor)-board", truth: truthPixels, warped: pixels, diff: diff,
                                   x0: 1000, y0: 950, width: 520, height: 420)
                        writeStrip("tier-\(tier.name)-\(c.name)-d\(divisor)-wheel", truth: truthPixels, warped: pixels, diff: diff,
                                   x0: 1680, y0: 700, width: 520, height: 420)
                    }
                } }
            }
            report.append(String(format: "mean | %d | no depth (plane) | %.2f |", divisor, plane / max(planeCount, 1)))
            for tier in PCVRWarpTier.allCases {
                guard let t = totals[tier], t.count > 0 else { continue }
                report.append(String(format: "mean | %d | %@ | %.2f | visible err %.4f | uncovered err %.3f | wrong %.2f %%",
                                     divisor, tier.name, t.gpu / t.count, t.visible / t.count, t.uncovered / t.count,
                                     t.wrong / t.count))
            }
        }
        let text = report.joined(separator: "\n")
        print(text)
        try text.write(to: directory.appendingPathComponent("tiers.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Scene shader

    static let sceneSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EyeUniforms {
        float4x4 worldFromEye;
        float4 tangents;
        uint origin;
        uint samples;
        uint2 size;
    };

    struct Hit { float t; float3 colour; };

    static float3 grid(float2 p, float3 base, float3 line, float spacing, float width) {
        float2 f = fract(p / spacing);
        bool on = f.x < width / spacing || f.y < width / spacing;
        float2 g = fract(p / 1.0);
        bool major = g.x < 0.02 || g.y < 0.02;
        return (on || major) ? line : base;
    }

    static float hash(float n) { return fract(sin(n) * 43758.5453); }

    static Hit scene(float3 o, float3 d) {
        Hit best = {1e30, float3(0.42, 0.58, 0.9)};
        // Floor, y = 0: 0.5 m checks.
        if (d.y < 0) {
            float t = -o.y / d.y; float3 p = o + t * d;
            if (t < best.t && p.x > -3 && p.x < 2 && p.z > -3 && p.z < 3) {
                bool light = (int(floor(p.x / 0.5)) + int(floor(p.z / 0.5))) % 2 == 0;
                best = {t, light ? float3(0.56) : float3(0.33)};
            }
        }
        // Back wall, z = -3: blue-grey with a 0.2 m grid.
        if (d.z < 0) {
            float t = (-3 - o.z) / d.z; float3 p = o + t * d;
            if (t < best.t && p.y > 0 && p.y < 2.6 && p.x > -3 && p.x < 2)
                best = {t, grid(p.xy, float3(0.55, 0.65, 0.75), float3(0.12, 0.14, 0.16), 0.2, 0.012)};
        }
        // Right wall, x = 2: tan.
        if (d.x > 0) {
            float t = (2 - o.x) / d.x; float3 p = o + t * d;
            if (t < best.t && p.y > 0 && p.y < 2.6 && p.z > -3 && p.z < 3)
                best = {t, grid(p.zy, float3(0.7, 0.6, 0.45), float3(0.2, 0.16, 0.1), 0.2, 0.012)};
        }
        // Left wall, x = -3.
        if (d.x < 0) {
            float t = (-3 - o.x) / d.x; float3 p = o + t * d;
            if (t < best.t && p.y > 0 && p.y < 2.6 && p.z > -3 && p.z < 3)
                best = {t, grid(p.zy, float3(0.7, 0.6, 0.45), float3(0.2, 0.16, 0.1), 0.2, 0.012)};
        }
        // The board, z = -1.2: white, black border, rows of "text".
        if (d.z < 0) {
            float t = (-1.2 - o.z) / d.z; float3 p = o + t * d;
            if (t < best.t && p.x > -0.75 && p.x < 0.25 && p.y > 1.1 && p.y < 1.75) {
                float3 c = float3(0.95);
                if (p.x < -0.72 || p.x > 0.22 || p.y < 1.13 || p.y > 1.72) c = float3(0.03);
                else {
                    float row = floor(p.y / 0.035);
                    float word = floor((p.x + hash(row) * 0.3) / 0.05);
                    if (fract(p.y / 0.035) < 0.55 && hash(row * 17 + word) > 0.3 && fract((p.x + hash(row) * 0.3) / 0.05) < 0.8) c = float3(0.1);
                }
                best = {t, c};
            }
        }
        // The wheel, a disc at z = -1.8 round (0.75, 1.55): yellow, ten black spokes, a black rim.
        if (d.z < 0) {
            float t = (-1.8 - o.z) / d.z; float3 p = o + t * d;
            float2 q = p.xy - float2(0.75, 1.55);
            float r = length(q);
            if (t < best.t && r < 0.28) {
                float a = atan2(q.y, q.x) / (2 * M_PI_F) * 10;
                bool spoke = abs(fract(a) - 0.5) < 0.04 * 0.28 / max(r, 0.02) * 0.6;
                best = {t, (r > 0.255 || spoke) ? float3(0.04) : float3(0.98, 0.74, 0.1)};
            }
        }
        // A thin pole at (1.2, -1.0), 2 cm round, floor to 2 m.
        {
            float2 oc = o.xz - float2(1.2, -1.0);
            float a = dot(d.xz, d.xz), b = dot(oc, d.xz), c = dot(oc, oc) - 0.02 * 0.02;
            float h = b * b - a * c;
            if (a > 1e-8 && h >= 0) {
                float t = (-b - sqrt(h)) / a; float3 p = o + t * d;
                if (t > 0 && t < best.t && p.y > 0 && p.y < 2.0) best = {t, float3(0.85, 0.2, 0.15)};
            }
        }
        return best;
    }

    kernel void benchRender(texture2d<float, access::write> colour [[texture(0)]],
                            texture2d<float, access::write> depth [[texture(1)]],
                            constant EyeUniforms *eyes [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint eye = gid.x >= eyes[1].origin ? 1 : 0;
        constant EyeUniforms &u = eyes[eye];
        uint2 local = uint2(gid.x - u.origin, gid.y);
        if (local.x >= u.size.x || local.y >= u.size.y) return;
        float3 o = u.worldFromEye[3].xyz;
        float3x3 r = float3x3(u.worldFromEye[0].xyz, u.worldFromEye[1].xyz, u.worldFromEye[2].xyz);
        float3 sum = float3(0);
        uint n = u.samples;
        for (uint sy = 0; sy < n; sy++) {
            for (uint sx = 0; sx < n; sx++) {
                float2 uv = (float2(local) + (float2(sx, sy) + 0.5) / float(n)) / float2(u.size);
                float3 e = float3(u.tangents.x + uv.x * (u.tangents.y - u.tangents.x), u.tangents.z - uv.y * (u.tangents.z - u.tangents.w), -1);
                sum += scene(o, normalize(r * e)).colour;
            }
        }
        colour.write(float4(sum / float(n * n), 1), gid);
        // Depth at the pixel centre, as a depth buffer has it: distance along -z.
        float2 uv = (float2(local) + 0.5) / float2(u.size);
        float3 e = float3(u.tangents.x + uv.x * (u.tangents.y - u.tangents.x), u.tangents.z - uv.y * (u.tangents.z - u.tangents.w), -1);
        Hit h = scene(o, normalize(r * e));
        float z = h.t < 1e29 ? h.t / length(e) : 0;
        depth.write(float4(z, 0, 0, 0), gid);
    }

    // The host's depth picture: the nearest depth under each output texel, 8-bit inverse depth from 0.25 m.
    struct DepthUniforms { uint divisor; uint eyeWidth; uint outEyeWidth; uint controls; };
    kernel void benchDepth(texture2d<float, access::read> depth [[texture(0)]],
                           texture2d<float, access::write> out [[texture(1)]],
                           constant DepthUniforms &u [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        uint eye = gid.x >= u.outEyeWidth ? 1 : 0;
        uint x0 = eye * u.eyeWidth + (gid.x - eye * u.outEyeWidth) * u.divisor, y0 = gid.y * u.divisor;
        float nearest = 1e30;
        for (uint y = 0; y < u.divisor; y++) {
            for (uint x = 0; x < u.divisor; x++) {
                float z = depth.read(uint2(x0 + x, y0 + y)).r;
                if (z > 0) nearest = min(nearest, z);
            }
        }
        float v = nearest < 1e29 ? saturate(0.25 / nearest) : 0;
        uint bits = u.controls & 255u;
        float levels = bits == 0 ? 0 : float((1u << bits) - 1u);
        float code = bits == 0 ? v : round(v * levels) / levels;
        uint noise = u.controls >> 8;
        if (noise > 0) {
            // Synthetic codec-like blocks, deliberately NOT a real HEVC model.
            uint h = (gid.x / 8u) * 73856093u ^ (gid.y / 8u) * 19349663u;
            code += (float(h % (2u * noise + 1u)) - float(noise)) / 255.0;
        }
        out.write(float4(saturate(code), 0, 0, 0), gid);
    }

    // Per left-eye pixel: the warp's error against the truth, and whether the source eye saw its point.
    struct ScoreUniforms {
        float4x4 sourceFromTruth;
        float4 truthTangents;
        float4 sourceTangents;
        float4 displayTangents;
        uint2 size;
        uint border;
        uint pad;
    };
    kernel void benchScore(texture2d<float, access::read> warped [[texture(0)]],
                           texture2d<float, access::read> truth [[texture(1)]],
                           texture2d<float, access::read> truthDepth [[texture(2)]],
                           texture2d<float, access::read> sourceDepth [[texture(3)]],
                           texture2d<float, access::write> out [[texture(4)]],
                           constant ScoreUniforms &u [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        if (gid.x < u.border || gid.y < u.border || gid.x >= u.size.x - u.border || gid.y >= u.size.y - u.border) {
            out.write(float4(-1, 0, 0, 0), gid);
            return;
        }
        {
            float2 uv = (float2(gid) + 0.5) / float2(u.size);
            float4 t = u.truthTangents, d = u.displayTangents;
            float tx = t.x + uv.x * (t.y - t.x), ty = t.z - uv.y * (t.z - t.w);
            if (tx < d.x || tx > d.y || ty > d.z || ty < d.w) { out.write(float4(-1, 0, 0, 0), gid); return; }
        }
        float3 a = warped.read(gid).rgb, b = truth.read(gid).rgb;
        float e = (abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)) / 3;
        float z = truthDepth.read(gid).r;
        float hidden = 0;
        if (z > 0) {
            float2 uv = (float2(gid) + 0.5) / float2(u.size);
            float4 t = u.truthTangents, s = u.sourceTangents;
            float4 q = u.sourceFromTruth * float4((t.x + uv.x * (t.y - t.x)) * z, (t.z - uv.y * (t.z - t.w)) * z, -z, 1);
            float zs = -q.z;
            if (zs <= 0.01) hidden = 2;
            else {
                float su = (q.x / zs - s.x) / (s.y - s.x), sv = (s.z - q.y / zs) / (s.z - s.w);
                if (su < 0 || su >= 1 || sv < 0 || sv >= 1) hidden = 2;
                else {
                    int sx = int(su * float(u.size.x)), sy = int(sv * float(u.size.y));
                    bool seen = false;
                    for (int dy = -1; dy <= 1; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            uint2 c = uint2(clamp(sx + dx, 0, int(u.size.x) - 1), clamp(sy + dy, 0, int(u.size.y) - 1));
                            float d = sourceDepth.read(c).r;
                            if (d > 0 && abs(d - zs) < 0.03 * zs) seen = true;
                        }
                    }
                    hidden = seen ? 0 : 1;
                }
            }
        }
        out.write(float4(e, hidden, 0, 0), gid);
    }
    """
}
#endif
