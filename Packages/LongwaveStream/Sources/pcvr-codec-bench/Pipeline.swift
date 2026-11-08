// The bench's picture path: the PCVR test scene ray-cast at a recorded head
// pose, the host's foveation warp centred where the bench's eyes look, NVENC
// with the host's settings (or a variant's), and the reconstruction scored on
// the GPU against the truth. It is the host's encode path with the frame
// source, the session and the clock taken out.
import CStreamWin
import Foundation
import StreamBench
import StreamHost
import StreamHostWindows
import StreamWire

/// How one run encodes: the host's flags (defaults as the host's), and the bench's own.
struct EncoderSettings {
    var preset = 1
    var vbvFrames = 4
    var multiPass = 0
    var spatialAQ = 0
    var temporalAQ = false
    var maxQP = 0
    var minQP = 0
    var keyFrameScale = 0
    var lowLatencyTuning = false
    /// What a change of stream rate does: `reconfigure` (the host's default)
    /// changes the rate in place; `rebuild` makes a new encoder and a key frame.
    var reconfigureOnRateChange = true
    /// A foveal QP map (`FovealQPMap`, the host's defaults): `foveaQP` at the warp
    /// centre out to `foveaRadius` degrees, ramping to `edgeQP` at `edgeRadius`. 0/0 is off.
    var foveaQP = -10
    var edgeQP = 10
    var foveaRadius = 8.0
    var edgeRadius = 30.0
    /// Warp parameters (`--warp centre,ratio`): the host's default 0.3 at 3.5.
    var warp = PCVRProfile.defaultWarp
    /// Snap the warp centre to the pixel grid (`CentreEdgeWarp.pixelAlignedCentre`), as the host does.
    var alignCentre = true

    var usesQPMap: Bool { foveaQP != 0 || edgeQP != 0 }
}

/// What the bench's viewer is.
struct ViewerSettings {
    var trajectory: HeadTrajectory
    /// Seconds into the trajectory the run starts.
    var start = 0.0
    var gaze = GazeModel.reading
    /// The warp's centre: the gaze as the host gets it (`gazeLag` old) or straight ahead.
    var followGaze = true
    var gazeLag = 0.03
    /// Render pixels per eye, and the eyes' field of view (tangents).
    var renderEye = PixelSize(width: 5184, height: 4160)
    var leftTangents: [Float] = [-1.7666, 1.02, 1.02, -1.2158]
    var ipd: Float = 0.064
    /// The side of the measured box round the gaze, render pixels.
    var box = 384

    var rightTangents: [Float] { [-leftTangents[1], -leftTangents[0], leftTangents[2], leftTangents[3]] }
}

final class Pipeline: BenchEncoder {
    let device: GraphicsDevice
    let settings: EncoderSettings
    let viewer: ViewerSettings
    private let scene: OpaquePointer
    private let warp: FoveationWarpPass
    private let quality: OpaquePointer
    private let render: GraphicsTexture
    private var wireTexture: GraphicsTexture?
    private var reconTexture: GraphicsTexture?
    private var encoder: VideoEncoder?
    private var gazeTracker: GazeTracker
    /// Gaze directions by time, for the host's lagged view of them.
    private var gazeHistory: [(time: Double, direction: [Double])] = []
    private(set) var qualities: [Int: FrameQuality] = [:]
    private(set) var rebuilds = 0
    private(set) var renderSeconds: [Double] = []
    var cropTimes: [Double] = []
    var cropDirectory: URL?
    var label = "run"
    private var wireTiles: [Float] = []
    private var gazeTiles: [Float] = []

    init(device: GraphicsDevice, settings: EncoderSettings, viewer: ViewerSettings) throws {
        self.device = device
        self.settings = settings
        self.viewer = viewer
        gazeTracker = GazeTracker(model: viewer.gaze)
        var s: OpaquePointer?
        try Self.check(lw_spike_scene_create(lw_device_get_d3d11(device.raw), &s), "lw_spike_scene_create")
        scene = s!
        warp = try FoveationWarpPass(device: device)
        var q: OpaquePointer?
        try Self.check(lw_quality_create(device.raw, &q), "lw_quality_create")
        quality = q!
        render = try GraphicsTexture(device: device, width: Int(viewer.renderEye.width) * 2, height: Int(viewer.renderEye.height),
                                     format: .bgra8)
    }

    deinit {
        lw_spike_scene_release(scene)
        lw_quality_release(quality)
    }

    static func check(_ status: lw_status, _ what: String) throws {
        guard status == LW_OK else {
            throw BenchError("\(what) failed (\(status)): \(String(cString: lw_last_error()))")
        }
    }

    var wireEye: PixelSize { settings.warp.wireSize(forRender: viewer.renderEye, alignment: PCVRProfile.wireAlignment)! }

    private func fieldOfView(_ tangents: [Float]) -> FieldOfView {
        FieldOfView(angleLeft: atan(tangents[0]), angleRight: atan(tangents[1]), angleUp: atan(tangents[2]),
                    angleDown: atan(tangents[3]))
    }

    private func eyePose(_ eye: Int) -> Pose {
        Pose(orientation: .identity, position: Vector3(eye == 0 ? -viewer.ipd / 2 : viewer.ipd / 2, 0, 0))
    }

    private func vector(_ d: [Double]) -> Vector3 { Vector3(Float(d[0]), Float(d[1]), Float(d[2])) }

    /// Gaze at `time` in the run, and the direction the host would have then.
    private func gaze(at time: Double, head: HeadSample) -> (actual: [Double], host: [Double]) {
        let actual = gazeTracker.direction(at: time, head: head)
        gazeHistory.append((time, actual))
        while let first = gazeHistory.first, first.time < time - 1 { gazeHistory.removeFirst() }
        let lagged = gazeHistory.last { $0.time <= time - viewer.gazeLag }?.direction ?? gazeHistory[0].direction
        return (actual, viewer.followGaze ? lagged : [0, 0, -1])
    }

    // MARK: BenchEncoder

    func encode(_ request: FrameRequest) throws -> EncodedFrame {
        let time = viewer.start + request.time
        let head = viewer.trajectory.sample(at: time)
        let (actualGaze, hostGaze) = gaze(at: time, head: head)

        // The scene at this pose: each eye ray-cast from the head plus its offset.
        let started = Date()
        var eyes = [lw_spike_scene_eye(), lw_spike_scene_eye()]
        for e in 0..<2 {
            let offset = head.orientation.rotate([Double(eyePose(e).position.x), 0, 0])
            let o = head.orientation
            eyes[e].orientation = (Float(o.x), Float(o.y), Float(o.z), Float(o.w))
            eyes[e].position = (Float(head.position[0] + offset[0]), Float(head.position[1] + offset[1]),
                                Float(head.position[2] + offset[2]))
            let fov = fieldOfView(e == 0 ? viewer.leftTangents : viewer.rightTangents)
            eyes[e].angles = (fov.angleLeft, fov.angleRight, fov.angleUp, fov.angleDown)
            eyes[e].time = Float(time)
        }
        try eyes.withUnsafeBufferPointer { buffer in
            try Self.check(lw_spike_scene_draw(scene, render.raw, nil, buffer.baseAddress, 0, 0), "lw_spike_scene_draw")
        }

        // The warp, centred where the host thinks the eyes are.
        let fovs = [fieldOfView(viewer.leftTangents), fieldOfView(viewer.rightTangents)]
        let centres = (0..<2).map { e in
            let centre = GazeProjection.centre(direction: vector(hostGaze), distance: 0, deviceFromEye: eyePose(e),
                                               fieldOfView: fovs[e]) ?? .centre
            return settings.alignCentre ? settings.warp.pixelAlignedCentre(centre, renderEye: viewer.renderEye, wireEye: wireEye) : centre
        }
        let parameters = FoveationParameters(epoch: 1, warp: .centreEdge(settings.warp))
        guard let maps = StereoCentreEdgeMapping(parameters: parameters,
                                                 frame: FoveationSideData(parameterEpoch: 1, leftCentre: centres[0],
                                                                          rightCentre: centres[1])) else {
            throw BenchError("no warp maps for centres \(centres)")
        }
        let wire = wireEye
        let pictureWidth = Int(wire.width) * 2, pictureHeight = Int(wire.height)
        if wireTexture == nil {
            wireTexture = try GraphicsTexture(device: device, width: pictureWidth, height: pictureHeight, format: .bgra8)
            reconTexture = try GraphicsTexture(device: device, width: pictureWidth, height: pictureHeight, format: .nv12)
        }
        try warp.apply(source: render, renderEye: (Int(viewer.renderEye.width), Int(viewer.renderEye.height)),
                       destination: wireTexture!, wireEye: (Int(wire.width), Int(wire.height)),
                       left: FoveationWarpPass.Eye(x: maps.left.x.constants, y: maps.left.y.constants),
                       right: FoveationWarpPass.Eye(x: maps.right.x.constants, y: maps.right.y.constants))

        // The encoder: created, rebuilt or reconfigured the way the host would.
        let fps = Int(request.hz.rounded())
        var forceKey = request.forceKey
        if let current = encoder, current.parameters.fps != fps {
            rebuilds += 1
            if settings.reconfigureOnRateChange {
                try current.reconfigure(bitrate: request.bitrate, fps: fps)
            } else {
                encoder = nil
            }
        }
        if encoder == nil {
            var p = VideoEncoder.Parameters(width: pictureWidth, height: pictureHeight, fps: fps, bitrate: request.bitrate)
            p.codec = .hevc
            p.asyncMode = true
            p.preset = settings.preset
            p.vbvFrames = settings.vbvFrames
            p.multiPass = settings.multiPass
            p.spatialAQ = settings.spatialAQ
            p.temporalAQ = settings.temporalAQ
            p.maxQP = settings.maxQP
            p.minQP = settings.minQP
            p.keyFrameScale = settings.keyFrameScale
            p.lowLatencyTuning = settings.lowLatencyTuning
            p.reconstruction = true
            p.qpMap = settings.usesQPMap
            encoder = try VideoEncoder(device: device, parameters: p)
            forceKey = true
        } else if let encoder, abs(request.bitrate - encoder.parameters.bitrate) * 100 > encoder.parameters.bitrate * 3 {
            try encoder.setBitrate(request.bitrate)
        }
        let map = settings.usesQPMap ? qpMap(maps: maps, centres: centres, fovs: fovs) : nil
        let picture = try encoder!.encode(wireTexture!, timestamp: UInt64(request.index), forceIDR: forceKey,
                                          qpDeltaMap: map, recon: reconTexture) {
            (size: $0.bytes.count, isIDR: $0.isIDR, qp: $0.averageQP, seconds: HostClock.milliseconds($0.doneTicks - $0.submitTicks) / 1000)
        }

        // Scoring: the codec in the wire picture, and what the eye sees at the gaze.
        let fovea = try measure(maps: maps, actualGaze: actualGaze, fovs: fovs, wire: wire)
        qualities[request.index] = FrameQuality(
            gazePSNR: fovea.gazePSNR, gazeSSIM: fovea.gazeSSIM, gazeWarpPSNR: fovea.warpPSNR, gazeDetail: fovea.detail,
            centrePSNR: fovea.centrePSNR, centreSSIM: fovea.centreSSIM, edgePSNR: fovea.edgePSNR, blockiness: fovea.blockiness,
            turnRate: viewer.trajectory.turnRate(at: time) * 180 / .pi)
        let gazeUV = GazeProjection.centre(direction: vector(actualGaze), distance: 0, deviceFromEye: eyePose(0),
                                           fieldOfView: fovs[0]) ?? .centre
        qualities[request.index]!.gazeUV = [Double(gazeUV.x), Double(gazeUV.y)]
        qualities[request.index]!.centreUV = [Double(maps.left.x.effectiveCentre), Double(maps.left.y.effectiveCentre)]
        if let first = cropTimes.first, request.time >= first {
            cropTimes.removeFirst()
            try crop(maps: maps, actualGaze: actualGaze, fovs: fovs, wire: wire, time: request.time, qp: picture.qp,
                     quality: qualities[request.index]!)
        }
        renderSeconds.append(Date().timeIntervalSince(started))
        return EncodedFrame(size: picture.size, isKey: picture.isIDR, encodeSeconds: picture.seconds, qp: picture.qp)
    }

    // MARK: The foveal QP map

    private func qpMap(maps: StereoCentreEdgeMapping, centres: [NormalizedPoint], fovs: [FieldOfView]) -> [Int8] {
        FovealQPMap(foveaQP: settings.foveaQP, edgeQP: settings.edgeQP, foveaRadius: settings.foveaRadius,
                    edgeRadius: settings.edgeRadius).offsets(maps: maps, fieldsOfView: (fovs[0], fovs[1]), wireEye: wireEye)
    }

    // MARK: Measuring

    private struct Fovea {
        var gazePSNR, gazeSSIM, warpPSNR, detail, centrePSNR, centreSSIM, edgePSNR, blockiness: Double
    }

    private func eyes(_ wire: PixelSize) -> lw_quality_eyes {
        lw_quality_eyes(render_eye_width: Int32(viewer.renderEye.width), render_eye_height: Int32(viewer.renderEye.height),
                        wire_eye_width: Int32(wire.width), wire_eye_height: Int32(wire.height))
    }

    private func boxes(maps: StereoCentreEdgeMapping, actualGaze: [Double], fovs: [FieldOfView]) -> [lw_quality_box] {
        (0..<2).map { e in
            let uv = GazeProjection.centre(direction: vector(actualGaze), distance: 0, deviceFromEye: eyePose(e),
                                           fieldOfView: fovs[e]) ?? .centre
            let side = viewer.box
            let x = min(max(Int(uv.x * Float(viewer.renderEye.width)) - side / 2, 0), Int(viewer.renderEye.width) - side)
            let y = min(max(Int(uv.y * Float(viewer.renderEye.height)) - side / 2, 0), Int(viewer.renderEye.height) - side)
            let m = e == 0 ? maps.left : maps.right
            return lw_quality_box(eye: Int32(e), x: Int32(x), y: Int32(y), size: Int32(side),
                                  axis_x: (m.x.constants.x, m.x.constants.y, m.x.constants.z, m.x.constants.w),
                                  axis_y: (m.y.constants.x, m.y.constants.y, m.y.constants.z, m.y.constants.w))
        }
    }

    private static func psnr(_ sse: Double, _ count: Double) -> Double {
        guard count > 0 else { return .nan }
        let mse = sse / count
        return mse <= 1e-6 ? 99 : 10 * log10(255 * 255 / mse)
    }

    private func measure(maps: StereoCentreEdgeMapping, actualGaze: [Double], fovs: [FieldOfView], wire: PixelSize) throws -> Fovea {
        guard let wireTexture, let reconTexture else { throw BenchError("no wire picture") }
        let across = (wireTexture.width + 15) / 16, down = (wireTexture.height + 15) / 16
        if wireTiles.count != across * down * 4 { wireTiles = [Float](repeating: 0, count: across * down * 4) }
        try wireTiles.withUnsafeMutableBufferPointer { out in
            try Self.check(lw_quality_wire(quality, wireTexture.raw, reconTexture.raw, out.baseAddress, UInt32(out.count)),
                           "lw_quality_wire")
        }
        // Tiles wholly inside an eye's full-density box are "centre"; the rest "edge".
        func centreRange(_ m: CentreEdgeAxisMapping, _ length: Int) -> ClosedRange<Int> {
            let c = m.constants
            let start = Double(c.x / c.z) / Double(c.w), end = Double(c.x / c.z + c.y - c.x) / Double(c.w)
            return Int((start * Double(length)).rounded(.up))...Int((end * Double(length)).rounded(.down))
        }
        let ranges = [maps.left, maps.right].map { (x: centreRange($0.x, Int(wire.width)), y: centreRange($0.y, Int(wire.height))) }
        var centreSSE = 0.0, centreCount = 0.0, centreSSIM = 0.0, centreTiles = 0.0, blocky = 0.0
        var edgeSSE = 0.0, edgeCount = 0.0
        for ty in 0..<down {
            for tx in 0..<across {
                let i = (ty * across + tx) * 4
                let x0 = tx * 16, y0 = ty * 16
                let pixels = Double(min(16, wireTexture.width - x0) * min(16, wireTexture.height - y0))
                let eye = x0 >= Int(wire.width) ? 1 : 0
                let lx = x0 - eye * Int(wire.width)
                let inside = ranges[eye].x.contains(lx) && ranges[eye].x.contains(lx + 15)
                    && ranges[eye].y.contains(y0) && ranges[eye].y.contains(y0 + 15)
                if inside {
                    centreSSE += Double(wireTiles[i])
                    centreCount += pixels
                    centreSSIM += Double(wireTiles[i + 1])
                    blocky += Double(wireTiles[i + 2])
                    centreTiles += 1
                } else {
                    edgeSSE += Double(wireTiles[i])
                    edgeCount += pixels
                }
            }
        }

        var boxList = boxes(maps: maps, actualGaze: actualGaze, fovs: fovs)
        let tilesPerBox = (viewer.box / 16) * (viewer.box / 16)
        if gazeTiles.count != tilesPerBox * 2 * 8 { gazeTiles = [Float](repeating: 0, count: tilesPerBox * 2 * 8) }
        var e = eyes(wire)
        try gazeTiles.withUnsafeMutableBufferPointer { out in
            try boxList.withUnsafeMutableBufferPointer { b in
                try Self.check(lw_quality_gaze(quality, render.raw, wireTexture.raw, reconTexture.raw, &e, b.baseAddress, 2,
                                               out.baseAddress, UInt32(out.count)), "lw_quality_gaze")
            }
        }
        var shownSSE = 0.0, wireSSE = 0.0, ssim = 0.0, lapTruth = 0.0, lapShown = 0.0
        for t in 0..<(tilesPerBox * 2) {
            shownSSE += Double(gazeTiles[t * 8])
            wireSSE += Double(gazeTiles[t * 8 + 1])
            ssim += Double(gazeTiles[t * 8 + 2])
            lapTruth += Double(gazeTiles[t * 8 + 4])
            lapShown += Double(gazeTiles[t * 8 + 5])
        }
        let gazePixels = Double(viewer.box * viewer.box * 2)
        return Fovea(gazePSNR: Self.psnr(shownSSE, gazePixels), gazeSSIM: ssim / Double(tilesPerBox * 2),
                     warpPSNR: Self.psnr(wireSSE, gazePixels), detail: lapTruth > 0 ? lapShown / lapTruth : .nan,
                     centrePSNR: Self.psnr(centreSSE, centreCount), centreSSIM: centreTiles > 0 ? centreSSIM / centreTiles : .nan,
                     edgePSNR: Self.psnr(edgeSSE, edgeCount), blockiness: centreTiles > 0 ? blocky / centreTiles : .nan)
    }

    private func crop(maps: StereoCentreEdgeMapping, actualGaze: [Double], fovs: [FieldOfView], wire: PixelSize, time: Double,
                      qp: Int, quality q: FrameQuality) throws {
        guard let directory = cropDirectory, let reconTexture else { return }
        var box = boxes(maps: maps, actualGaze: actualGaze, fovs: fovs)[0]
        var e = eyes(wire)
        let side = Int(box.size)
        var truth = [UInt8](repeating: 0, count: side * side * 4), shown = truth
        try truth.withUnsafeMutableBufferPointer { t in
            try shown.withUnsafeMutableBufferPointer { s in
                try Self.check(lw_quality_crop(quality, render.raw, reconTexture.raw, &e, &box, t.baseAddress, s.baseAddress),
                               "lw_quality_crop")
            }
        }
        // Truth on the left, shown on the right.
        var pair = [UInt8](repeating: 0, count: side * side * 8)
        for y in 0..<side {
            pair.replaceSubrange((y * side * 8)..<(y * side * 8 + side * 4), with: truth[(y * side * 4)..<((y + 1) * side * 4)])
            pair.replaceSubrange((y * side * 8 + side * 4)..<((y + 1) * side * 8), with: shown[(y * side * 4)..<((y + 1) * side * 4)])
        }
        let name = String(format: "%@-t%06.2f-qp%02d-%.1fdB-%.0fdps.bmp", label, time, qp, q.gazePSNR, q.turnRate)
        try BMP.write(pair, width: side * 2, height: side, to: directory.appendingPathComponent(name))
    }
}

enum BMP {
    /// 32-bit BGRA, top-down rows.
    static func write(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let size = UInt32(width * height * 4)
        data.append(contentsOf: [0x42, 0x4D])
        u32(54 + size); u32(0); u32(54)
        u32(40); u32(UInt32(width)); u32(UInt32(bitPattern: Int32(-height))); u16(1); u16(32); u32(0); u32(size)
        u32(2835); u32(2835); u32(0); u32(0)
        data.append(contentsOf: pixels)
        try data.write(to: url)
    }
}
