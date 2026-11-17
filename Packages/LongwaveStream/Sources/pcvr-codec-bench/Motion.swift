// `--mode motion`: is NVENC's motion-estimation-only mode a usable motion
// source for extrapolating the frame a half-rate stream repeats
// (docs/PCVR_MOTION_EXTRAPOLATION.md)? The test scene is ray-cast at three
// times along the trajectory: the previous source frame, the current one, and
// the display time half a source period after it (the repeat at 45 on 90).
// Motion is estimated from the previous to the current picture; the current
// one moved half that far is scored against the truth at the half time, next to
// simply showing the current one again. Times the estimate on the encoder
// engine, which is the number that matters with a game on the GPU.
import CStreamWin
import Foundation
import StreamBench
import StreamHost
import StreamHostWindows
import StreamWire

enum MotionProbe {
    struct Sample {
        var time: Double
        var estimateMs: Double
        var knownShare: Double
        var meanPixels: Double
        var repeatPSNR: Double?
        var extrapolatedPSNR: Double?
        /// The other sign (a check on the vectors' convention).
        var negatedPSNR: Double?
        var malformed: UInt32
        var ctb: UInt32 = 0
        var markers: UInt32 = 0
        var largestCU: UInt32 = 0
    }

    static func run(device: GraphicsDevice, viewer: ViewerSettings, eye: PixelSize, seconds: Double, sourceHz: Double,
                    preset: Int, scoreEvery: Int) throws {
        var s: OpaquePointer?
        try Pipeline.check(lw_spike_scene_create(lw_device_get_d3d11(device.raw), &s), "lw_spike_scene_create")
        let scene = s!
        defer { lw_spike_scene_release(scene) }
        let width = Int(eye.width) * 2, height = Int(eye.height)
        let previous = try GraphicsTexture(device: device, width: width, height: height, format: .bgra8)
        let current = try GraphicsTexture(device: device, width: width, height: height, format: .bgra8)
        let half = try GraphicsTexture(device: device, width: width, height: height, format: .bgra8)
        var params = lw_motion_params(width: Int32(width), height: Int32(height), preset: UInt32(preset), block: 0)
        var m: OpaquePointer?
        try Pipeline.check(lw_motion_create(device.raw, &params, &m), "lw_motion_create")
        let motion = m!
        defer { lw_motion_release(motion) }

        let period = 1 / sourceHz
        let count = Int(seconds * sourceHz)
        var samples: [Sample] = []
        var lastStats = lw_motion_stats()
        var currentPixels = [UInt8](repeating: 0, count: width * height * 4)
        var halfPixels = currentPixels
        for k in 1..<count {
            let t1 = viewer.start + Double(k) * period
            try draw(scene, at: t1 - period, viewer: viewer, into: previous)
            try draw(scene, at: t1, viewer: viewer, into: current)
            // Reading the picture back waits for both draws, so the estimate's time is the
            // encoder's alone, not the draws queued behind a game on the 3D engine.
            try read(device, current, into: &currentPixels, width: width)
            var field = lw_motion_field()
            try Pipeline.check(lw_motion_estimate(motion, current.raw, previous.raw, &field), "lw_motion_estimate")
            let blocks = Int(field.grid_width) * Int(field.grid_height)
            var sample = Sample(time: t1 - viewer.start, estimateMs: field.stats.submit_ms + field.stats.wait_ms,
                                knownShare: Double(field.stats.known_blocks) / Double(max(blocks, 1)),
                                meanPixels: field.stats.mean_pixels, malformed: field.stats.malformed_ctbs,
                                ctb: field.stats.ctb_size, markers: field.stats.ctb_markers, largestCU: field.stats.largest_cu)
            if k % scoreEvery == 0 {
                try draw(scene, at: t1 + period / 2, viewer: viewer, into: half)
                try read(device, half, into: &halfPixels, width: width)
                let vectors = UnsafeBufferPointer(start: field.vectors, count: blocks * 2)
                let known = UnsafeBufferPointer(start: field.known, count: blocks)
                let scores = score(current: currentPixels, truth: halfPixels, width: width, height: height, eyeWidth: Int(eye.width),
                                   vectors: vectors, known: known, gridWidth: Int(field.grid_width), block: Int(field.block))
                sample.repeatPSNR = scores.repeat
                sample.extrapolatedPSNR = scores.extrapolated
                sample.negatedPSNR = scores.negated
            }
            samples.append(sample)
            lastStats = field.stats
        }

        let times = samples.map(\.estimateMs).sorted()
        func percentile(_ p: Double) -> Double { times.isEmpty ? 0 : times[min(times.count - 1, Int(p * Double(times.count - 1)))] }
        // Frames where something moved: a still picture repeats perfectly and says nothing.
        let scored = samples.filter { ($0.repeatPSNR ?? 99) < 60 }
        let repeatMean = Stats.mean(scored.compactMap(\.repeatPSNR))
        let extrapolatedMean = Stats.mean(scored.compactMap(\.extrapolatedPSNR))
        let gains = scored.map { $0.extrapolatedPSNR! - $0.repeatPSNR! }
        print(String(format: "motion %dx%d HEVC ME P%d: %d estimates, %.2f ms mean, p50 %.2f, p95 %.2f, max %.2f; known %.0f%% of blocks, "
                     + "mean |v| %.1f px; %u malformed CTBs",
                     width, height, preset, samples.count, Stats.mean(times), percentile(0.5), percentile(0.95), times.last ?? 0,
                     Stats.mean(samples.map(\.knownShare)) * 100, Stats.mean(samples.map(\.meanPixels)),
                     samples.map(\.malformed).reduce(0, +)))
        print(String(format: "  split: submit %.2f ms, wait %.2f ms, parse %.2f ms (last estimate)", lastStats.submit_ms,
                     lastStats.wait_ms, lastStats.parse_ms))
        if let last = samples.last {
            print("  read as \(last.ctb)x\(last.ctb) CTBs (\(last.markers) markers), largest CU \(last.largestCU)")
        }
        print(String(format: "half-period frame, left-eye centre: repeat %.2f dB, extrapolated %.2f dB, gain %.2f dB mean "
                     + "(%d of %d scored frames gained); other sign %.2f dB", repeatMean, extrapolatedMean, Stats.mean(gains),
                     gains.filter { $0 > 0 }.count, gains.count, Stats.mean(scored.compactMap(\.negatedPSNR))))
        for sample in scored.prefix(12) {
            print(String(format: "  t %.2f s: ME %.2f ms, |v| %.1f px, repeat %.2f dB, extrapolated %.2f dB", sample.time,
                         sample.estimateMs, sample.meanPixels, sample.repeatPSNR!, sample.extrapolatedPSNR!))
        }
    }

    private static func draw(_ scene: OpaquePointer, at time: Double, viewer: ViewerSettings, into texture: GraphicsTexture) throws {
        let head = viewer.trajectory.sample(at: time)
        var eyes = [lw_spike_scene_eye(), lw_spike_scene_eye()]
        for e in 0..<2 {
            let offset = head.orientation.rotate([Double(e == 0 ? -viewer.ipd / 2 : viewer.ipd / 2), 0, 0])
            let o = head.orientation
            eyes[e].orientation = (Float(o.x), Float(o.y), Float(o.z), Float(o.w))
            eyes[e].position = (Float(head.position[0] + offset[0]), Float(head.position[1] + offset[1]),
                                Float(head.position[2] + offset[2]))
            let t = e == 0 ? viewer.leftTangents : viewer.rightTangents
            eyes[e].angles = (atan(t[0]), atan(t[1]), atan(t[2]), atan(t[3]))
            eyes[e].time = Float(time)
        }
        try eyes.withUnsafeBufferPointer { buffer in
            try Pipeline.check(lw_spike_scene_draw(scene, texture.raw, nil, buffer.baseAddress, 0, 0), "lw_spike_scene_draw")
        }
    }

    private static func read(_ device: GraphicsDevice, _ texture: GraphicsTexture, into pixels: inout [UInt8], width: Int) throws {
        try pixels.withUnsafeMutableBytes { bytes in
            try Pipeline.check(lw_texture_read(device.raw, texture.raw, bytes.baseAddress, UInt32(width * 4)), "lw_texture_read")
        }
    }

    /// PSNR in luma over the left eye's central 1024x1024: the current picture as
    /// it is, and moved half its motion (each pixel from current(p + v/2), v the
    /// block's vector, bilinear), against the truth at the half time.
    private static func score(current: [UInt8], truth: [UInt8], width: Int, height: Int, eyeWidth: Int,
                              vectors: UnsafeBufferPointer<Int16>, known: UnsafeBufferPointer<UInt8>, gridWidth: Int,
                              block: Int) -> (repeat: Double, extrapolated: Double, negated: Double) {
        func luma(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            return 0.0722 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.2126 * Double(pixels[i + 2])
        }
        func sample(_ pixels: [UInt8], _ x: Double, _ y: Double) -> Double {
            let cx = min(max(x, 0), Double(eyeWidth - 1)), cy = min(max(y, 0), Double(height - 1))
            let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, eyeWidth - 1), y1 = min(y0 + 1, height - 1)
            let fx = cx - Double(x0), fy = cy - Double(y0)
            let top = luma(pixels, x0, y0) * (1 - fx) + luma(pixels, x1, y0) * fx
            let bottom = luma(pixels, x0, y1) * (1 - fx) + luma(pixels, x1, y1) * fx
            return top * (1 - fy) + bottom * fy
        }
        let side = min(1024, eyeWidth, height)
        let x0 = eyeWidth / 2 - side / 2, y0 = height / 2 - side / 2
        var repeatError = 0.0, extrapolatedError = 0.0, negatedError = 0.0
        for y in y0..<(y0 + side) {
            for x in x0..<(x0 + side) {
                let t = luma(truth, x, y)
                let r = luma(current, x, y) - t
                repeatError += r * r
                let b = (y / block) * gridWidth + x / block
                var e = r, g = r
                if known[b] != 0 {
                    let vx = Double(vectors[b * 2]) / 4, vy = Double(vectors[b * 2 + 1]) / 4
                    e = sample(current, Double(x) + vx / 2, Double(y) + vy / 2) - t
                    g = sample(current, Double(x) - vx / 2, Double(y) - vy / 2) - t
                }
                extrapolatedError += e * e
                negatedError += g * g
            }
        }
        let n = Double(side * side)
        func psnr(_ sse: Double) -> Double { sse <= 0 ? 99 : 10 * log10(255 * 255 * n / sse) }
        return (psnr(repeatError), psnr(extrapolatedError), psnr(negatedError))
    }
}
