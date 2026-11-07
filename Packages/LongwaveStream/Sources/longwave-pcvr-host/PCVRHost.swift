// The v3 PCVR host (NATIVE_V3_PROTOCOL.md section 4.7): frames composited by
// the session broker arrive through an external frame source, are encoded
// with NVENC and sent to each PCVR viewer over a v3 session; the viewers'
// head poses go back to the broker through the frame source's host state.
//
// Three threads share one lock: the network thread (socket, timers, pacing),
// the encoder thread (frame -> NVENC -> each viewer's sender) and the pacing
// thread (host state at the display rate).

import Foundation
import StreamCrypto
import StreamHost
import StreamHostWindows
import StreamTransport
import StreamWire

struct HostOptions {
    var channel = "pcvr"
    var port = PCVRProfile.port
    /// The encoder's ceiling and the rate estimate's cap.
    var maxMbps = 150
    /// The rate estimate's starting point.
    var startMbps = 30
    /// The frame clock's rate, and whether it follows the headset's display:
    /// `--refresh auto` (the default) paces at the rate the headset's poses
    /// arrive, one per display tick, so a producer may render as often as the
    /// headset can show and no more; a number fixes it.
    var refreshHz = 90.0
    var followsHeadset = true
    /// NVENC preset, 1 (fastest) to 7, and the rate control's buffer in frames:
    /// a bigger buffer lets detailed frames take more bits, for a little latency.
    var preset = 1
    var vbvFrames = 1
    var logPath: String?
    var seconds: Double?
    var foveation = FoveationMode.auto
    var warp = PCVRProfile.defaultWarp
    var depth = DepthMode.auto
    /// The depth stream's encoder rate. Its picture is small and smooth, but a
    /// mesh displaced by it turns every codec block edge into a step in the
    /// world: at 6 Mbps walls tore along block boundaries (test scene, 2026-11-07).
    var depthMbps = 16
    /// The depth picture's size: the render eye divided by this, per axis
    /// (`PCVRProfile.depthDivisor` by default). Each silhouette in it is as
    /// coarse as a texel, and the receiver's reprojection moves a texel's
    /// pixels together, so at 16 a rim of background 16 render pixels wide
    /// moves with every near shape (test scene, 2026-11-07).
    var depthScale = PCVRProfile.depthDivisor
    /// The depth encoder's constant QP (0: CBR at `depthMbps`). Under CBR the
    /// rate control spent a megabit or two on the mostly flat picture and let
    /// its edges ring, and the receiver's reprojection turned that ringing
    /// into noise around every near shape on head movement (test scene,
    /// 2026-11-07). At a low constant QP the picture still costs a few Mbps.
    var depthQP = 12
    /// Diagnostics: a directory the estimate's grids and output are written to.
    var depthDump: String?
}

/// Where a viewer that negotiated `depthVideo` gets its depth from (section 4.8).
enum DepthMode: String {
    /// Never sent.
    case off
    /// The game's own depth when the frame source carries it, else estimated from the two eyes.
    case auto
    /// Always estimated from the two eyes, even when the game's depth is there.
    case stereo
}

/// The nearest a stereo estimate looks for: closer than this, a vertex stays
/// at this depth. Sets the disparity search range per frame. Not nearer: a
/// false near match does far more harm than a flat picture (the error grows
/// with 1/z), and little in a game comes closer than a hand's length.
private let stereoNearest: Float = 0.25

/// When the host packs the eye images with the centre/edge warp. Only ever
/// for viewers that negotiated `foveatedVideo` (they can undo it).
enum FoveationMode: String {
    /// Never: every pixel at render density.
    case off
    /// When every viewer also sends gaze, so the full-density centre follows
    /// the eyes. Without gaze, fixed foveation would only blur the edges.
    case auto
    /// Whenever the viewers can undo it; without gaze the centre sits straight ahead.
    case on
}

final class PCVRHost: @unchecked Sendable {
    private final class Viewer {
        let index: UInt32
        let deviceID: String
        let name: String
        let grants: SessionGrants
        let capabilities: CapabilitySet
        var confirmed = false
        var sender: VideoStreamSender
        /// The eye stream's depth auxiliary, for a viewer that negotiated `depthVideo`.
        var depthSender: VideoStreamSender?
        var lastPose: UInt32?
        var posesReceived = 0
        var lastPresented: PresentedFrame?

        init(index: UInt32, deviceID: String, name: String, grants: SessionGrants, capabilities: CapabilitySet,
             configuration: VideoStreamSender.Configuration) {
            self.index = index
            self.deviceID = deviceID
            self.name = name
            self.grants = grants
            self.capabilities = capabilities
            sender = VideoStreamSender(configuration: configuration)
        }
    }

    private static let keyFrameInterval: UInt64 = 250_000_000
    /// Gaze older than this doesn't centre the warp (the headset's own uplink budget).
    private static let gazeMaxAge: UInt64 = 100_000_000
    /// A centre outlives its gaze this long (a blink, a dropped pose) before
    /// the warp falls back to straight ahead.
    private static let centreHold: UInt64 = 500_000_000

    private let options: HostOptions
    private let log: HostLog
    private let lock = NSLock()
    private var running = true

    private let socket: UDPSocket
    private let device: GraphicsDevice
    private var source: ExternalFrameSource?

    // Under `lock`.
    private var endpoint = HostEndpoint<UDPAddress>(devices: [])
    private var pairedDevices: [PairedDevice] = []
    private var viewers: [UInt32: Viewer] = [:]
    private var answered: [String: (hello: ClientHello, grants: SessionGrants, capabilities: CapabilitySet)] = [:]
    private var format: FormatDescription?
    private var depthFormat: FormatDescription?
    private var wantsKeyFrame = true
    private var depthWantsKeyFrame = true
    private var lastKeyFrameRequest: UInt64?
    private var targetBitrate: Int?
    private var headPose: (sequence: UInt32, pose: HeadPose)?
    /// The frame clock's rate now (`options.refreshHz` until the headset's is known).
    private var pacedHz: Double
    /// Poses accepted since the rate was last measured.
    private var posesForRate = 0
    private var lastDeviceReload: UInt64 = 0

    // Frames waiting for the encoder: only the newest is kept.
    private let frameLock = NSLock()
    private var pendingFrame: CapturedFrame?
    private var framesSuperseded = 0
    private let frameReady = DispatchSemaphore(value: 0)

    // Encoder thread only.
    private var encoder: VideoEncoder?
    private var appliedBitrate = 0
    private var parameterSets: [UInt8] = []
    private var layout: Layout?
    /// Bumped with every layout: the `FoveationParameters.epoch` frames name.
    private var foveationEpoch: UInt32 = 0
    /// The layout changed since the last format: send one with the next key frame.
    private var formatStale = true
    private var warp: FoveationWarpPass?
    /// The warp's shader couldn't be made: stream unwarped rather than not at all.
    private var warpUnavailable = false
    private var wireTexture: GraphicsTexture?
    private var lastGazeCentres: (left: NormalizedPoint, right: NormalizedPoint, time: UInt64)?
    private var depthPass: DepthPass?
    /// The depth shaders couldn't be made: no depth stream rather than no stream.
    private var depthUnavailable = false
    /// Written in turn by the depth pass, read by the depth thread's encoder:
    /// enough that the pass never reaches one still queued or being encoded.
    private var depthTextures: [GraphicsTexture] = []
    private var nextDepthTexture = 0
    private static let depthTextureCount = 4
    private static let depthQueue = 2
    private var lastDepthDump: UInt64 = 0
    private var depthDumpBurst = 0
    private var depthDumpIndex = 0

    // The depth thread's.
    private var depthEncoder: VideoEncoder?
    private var depthParameterSets: [UInt8] = []
    private var depthFormatStale = true

    /// A depth picture waiting for the depth thread's encoder.
    private struct DepthJob {
        var texture: GraphicsTexture
        var picture: PixelSize
        var eye: PixelSize
        var near: Float
        var fromGame: Bool
        var sequence: UInt64
        var captureTime: UInt64
        var numbers: [UInt32: UInt32]
        var gpuMilliseconds: Double?
    }
    private let depthLock = NSLock()
    private var depthJobs: [DepthJob] = []
    private let depthReady = DispatchSemaphore(value: 0)

    /// How the eye images go on the wire: their render size per eye, the wire
    /// size per eye, and the warp between the two (none when they are equal).
    private struct Layout: Equatable {
        var renderEye: PixelSize
        var wireEye: PixelSize
        var warp: CentreEdgeWarp?
        var pictureSize: PixelSize { PixelSize(width: wireEye.width * 2, height: wireEye.height) }
    }

    // Statistics, under `lock`.
    private var framesEncoded = 0
    private var qpTotal = 0
    private var qpMax = 0
    private var encodeMilliseconds = 0.0
    private var encodedBytes = 0
    private var framesWithoutViewers = 0
    private var badSideData = 0
    private var lastStats: UInt64 = 0
    private var foveationStats = FoveationStatistics()
    private var depthStats = DepthStatistics()

    private struct DepthStatistics {
        var frames = 0, stereo = 0, game = 0, dropped = 0
        var bytes = 0
        var qpTotal = 0, qpMax = 0
        var encodeMilliseconds = 0.0
        var gpuMilliseconds: Double?
        var size: String?
        var near: Float = 0
    }

    private struct FoveationStatistics {
        var gaze = 0, held = 0, ahead = 0
        var gazeAgeTotal: UInt64 = 0
        var gazeAgeMax: UInt64 = 0
        var lastCentres: (NormalizedPoint, NormalizedPoint)?
        var layout: String?
    }

    init(options: HostOptions, log: HostLog) throws {
        self.options = options
        self.log = log
        pacedHz = options.refreshHz
        try StreamHostRuntime.initialize()
        socket = try UDPSocket(port: options.port)
        device = try GraphicsDevice(for: nil)
        log.line("device: \(device.adapterName); v3 PCVR on UDP \(options.port); frame source channel '\(options.channel)'")
        reloadDevices(now: Self.now())
    }

    /// Host monotonic ns on QPC, the clock frames are stamped with.
    static func now() -> UInt64 { HostClock.nanoseconds(HostClock.now()) }

    static func ticks(fromNanoseconds ns: UInt64) -> Int64 {
        let f = UInt64(HostClock.ticksPerSecond)
        return Int64(ns / 1_000_000_000 * f + ns % 1_000_000_000 * f / 1_000_000_000)
    }

    func run() throws {
        source = try ExternalFrameSource(device: device, channel: options.channel) { [weak self] frame in
            self?.offer(frame)
        }
        let encoderThread = Thread { [self] in encodeLoop() }
        encoderThread.name = "encoder"
        encoderThread.start()
        let pacingThread = Thread { [self] in pacingLoop() }
        pacingThread.name = "pacing"
        pacingThread.start()
        let depthThread = Thread { [self] in depthLoop() }
        depthThread.name = "depth"
        depthThread.start()

        let end = options.seconds.map { Self.now() + UInt64($0 * 1e9) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running {
            let timeout = lock.withLock { pollTimeout(now: Self.now()) }
            let readable = socket.wait(milliseconds: timeout)
            lock.withLock {
                if readable {
                    while let (count, address) = socket.receive(into: &buffer) {
                        guard count > 0 else { continue }
                        handle(Array(buffer[0..<count]), from: address)
                    }
                }
                pump()
            }
            if let end, Self.now() >= end { running = false }
        }
        lock.withLock {
            for viewer in Array(viewers.values) { endSession(viewer, reason: "The PC stopped streaming.") }
        }
        frameReady.signal()
        depthReady.signal()
        source?.stop()
    }

    // MARK: Frames

    private func offer(_ frame: CapturedFrame) {
        frameLock.withLock {
            if pendingFrame != nil { framesSuperseded += 1 }
            pendingFrame = frame // the older one is released here
        }
        frameReady.signal()
    }

    private func encodeLoop() {
        while running {
            _ = frameReady.wait(timeout: .now() + .milliseconds(100))
            guard let frame = frameLock.withLock({ () -> CapturedFrame? in
                defer { pendingFrame = nil }
                return pendingFrame
            }) else { continue }
            do {
                try encode(frame)
            } catch {
                log.line("encode failed: \(error)")
                encoder = nil
            }
        }
    }

    private func encode(_ frame: CapturedFrame) throws {
        let (watched, requestedKey, bitrate, foveate, head, depthWanted) = lock.withLock {
            () -> (Bool, Bool, Int?, Bool, HeadPose?, Bool) in
            let confirmed = viewers.values.filter(\.confirmed)
            let watched = !confirmed.isEmpty
            if !watched { framesWithoutViewers += 1 }
            let force = watched && wantsKeyFrame
            if force { wantsKeyFrame = false }
            let foveate = watched && options.foveation != .off
                && confirmed.allSatisfy { $0.capabilities.contains(.foveatedVideo) }
                && (options.foveation == .on || confirmed.allSatisfy { $0.capabilities.contains(.gaze) })
            return (watched, force, targetBitrate, foveate, headPose?.pose, confirmed.contains { $0.depthSender != nil })
        }
        guard watched else { return }

        var forceKey = requestedKey
        let renderEye = PixelSize(width: UInt16(frame.width / 2), height: UInt16(frame.height))
        if foveate, warp == nil, !warpUnavailable {
            do {
                warp = try FoveationWarpPass(device: device)
            } catch {
                warpUnavailable = true
                log.line("foveation unavailable, streaming unwarped: \(error)")
            }
        }
        let wanted = Self.layout(renderEye: renderEye, warp: foveate && warp != nil ? options.warp : nil)
        if wanted != layout {
            layout = wanted
            foveationEpoch &+= 1
            formatStale = true
            forceKey = true
            lastGazeCentres = nil
            let description = wanted.warp == nil
                ? "off, \(renderEye.width)x\(renderEye.height) per eye"
                : "on, \(wanted.wireEye.width)x\(wanted.wireEye.height) of \(renderEye.width)x\(renderEye.height) per eye"
            lock.withLock { foveationStats.layout = description }
            log.line("foveation \(description) (epoch \(foveationEpoch))")
        }
        let picture = wanted.pictureSize

        if encoder == nil || encoder?.parameters.width != Int(picture.width) || encoder?.parameters.height != Int(picture.height) {
            var parameters = VideoEncoder.Parameters(width: Int(picture.width), height: Int(picture.height),
                                                     fps: Int(lock.withLock { pacedHz }.rounded()),
                                                     bitrate: bitrate ?? options.startMbps * 1_000_000)
            parameters.codec = .hevc
            parameters.asyncMode = true
            parameters.preset = options.preset
            parameters.vbvFrames = options.vbvFrames
            encoder = nil
            encoder = try VideoEncoder(device: device, parameters: parameters)
            appliedBitrate = parameters.bitrate
            parameterSets = []
            log.line("encoder: \(encoder!.info.name) HEVC \(picture.width)x\(picture.height) @ \(parameters.fps) Hz, \(parameters.bitrate / 1_000_000) Mbps, VBV \(parameters.vbvFrames) frame(s)")
        }
        guard let encoder else { return }
        if let bitrate, abs(bitrate - appliedBitrate) * 100 > appliedBitrate * 3 {
            try encoder.setBitrate(bitrate)
            appliedBitrate = bitrate
        }

        var sideData = SideData.none
        if let bytes = frame.external?.sideData, !bytes.isEmpty {
            var reader = WireReader(bytes)
            if let decoded = try? SideData(items: &reader), decoded.renderPose != nil {
                sideData = decoded
            } else {
                lock.withLock { badSideData += 1 }
                return // a PCVR frame without its render pose can't be shown
            }
        } else {
            lock.withLock { badSideData += 1 }
            return
        }

        var depthJob: DepthJob?
        if depthWanted, let renderPose = sideData.renderPose {
            do {
                depthJob = try prepareDepth(frame, renderPose: renderPose, renderEye: renderEye)
            } catch {
                log.line("depth failed: \(error)")
            }
        }

        let encoded: (accessUnit: [UInt8], isIDR: Bool, milliseconds: Double, qp: Int)
        if let shape = wanted.warp, let renderPose = sideData.renderPose {
            let now = Self.now()
            let (left, right, source) = centres(renderPose: renderPose, head: head, now: now)
            let parameters = FoveationParameters(epoch: foveationEpoch, warp: .centreEdge(shape))
            let side = FoveationSideData(parameterEpoch: foveationEpoch, leftCentre: left, rightCentre: right)
            guard let maps = StereoCentreEdgeMapping(parameters: parameters, frame: side) else {
                lock.withLock { badSideData += 1 }
                return
            }
            if wireTexture?.width != Int(picture.width) || wireTexture?.height != Int(picture.height) {
                wireTexture = try GraphicsTexture(device: device, width: Int(picture.width), height: Int(picture.height),
                                                  format: .bgra8)
            }
            guard let warp, let wireTexture else { return }
            try warp.apply(source: frame, renderEye: (Int(renderEye.width), Int(renderEye.height)),
                           destination: wireTexture, wireEye: (Int(wanted.wireEye.width), Int(wanted.wireEye.height)),
                           left: FoveationWarpPass.Eye(x: maps.left.x.constants, y: maps.left.y.constants),
                           right: FoveationWarpPass.Eye(x: maps.right.x.constants, y: maps.right.y.constants))
            sideData.foveation = side
            lock.withLock {
                switch source {
                case .gaze(let age):
                    foveationStats.gaze += 1
                    foveationStats.gazeAgeTotal += age
                    foveationStats.gazeAgeMax = max(foveationStats.gazeAgeMax, age)
                case .held: foveationStats.held += 1
                case .ahead: foveationStats.ahead += 1
                }
                foveationStats.lastCentres = (left, right)
            }
            encoded = try encoder.encode(wireTexture, timestamp: frame.sequence, forceIDR: forceKey) {
                (Array($0.bytes), $0.isIDR, HostClock.milliseconds($0.doneTicks - $0.submitTicks), $0.averageQP)
            }
        } else {
            encoded = try encoder.encode(frame, timestamp: frame.sequence, forceIDR: forceKey) {
                (Array($0.bytes), $0.isIDR, HostClock.milliseconds($0.doneTicks - $0.submitTicks), $0.averageQP)
            }
        }
        let (accessUnit, isIDR, milliseconds, qp) = encoded
        let captureTime = HostClock.nanoseconds(frame.presentTicks)
        // The frame (and its ring slot) is released when `frame` goes out of
        // scope: the encode (and the warp before it) has finished with the texture.

        var colourNumbers: [UInt32: UInt32] = [:]
        var newFormat: FormatDescription?
        if isIDR {
            let sets = Self.parameterSets(in: accessUnit)
            if !sets.isEmpty, sets != parameterSets || formatStale {
                parameterSets = sets
                formatStale = false
                newFormat = Self.format(layout: wanted, epoch: foveationEpoch, parameterSets: sets)
            }
        }

        lock.withLock {
            framesEncoded += 1
            encodeMilliseconds += milliseconds
            encodedBytes += accessUnit.count
            qpTotal += qp
            qpMax = max(qpMax, qp)
            if let newFormat {
                format = newFormat
                for viewer in viewers.values where viewer.confirmed { sendFormat(to: viewer) }
            }
            let now = Self.now()
            var needsKey = false
            for viewer in viewers.values where viewer.confirmed {
                guard let udpPayload = endpoint.sessions[viewer.index]?.session.udpPayload else { continue }
                do {
                    switch try viewer.sender.submit(accessUnit: accessUnit, isKeyFrame: isIDR, captureTime: captureTime,
                                                    sideData: sideData, udpPayload: udpPayload, now: now) {
                    case .queued(let number): if viewer.depthSender != nil { colourNumbers[viewer.index] = number }
                    case .awaitingKeyFrame, .queueFull: needsKey = true
                    }
                } catch {
                    log.line("could not shard a frame: \(error)")
                }
            }
            if needsKey { requestKeyFrame(now: now) }
            pump()
        }

        // The colour frame is on its way; its depth follows under the same
        // numbers, encoded on the depth thread. Depth decodes in a fraction of
        // the colour's time, so it is still ready first on the headset.
        if var job = depthJob, !colourNumbers.isEmpty {
            job.numbers = colourNumbers
            job.captureTime = captureTime
            let dropped = depthLock.withLock { () -> Bool in
                depthJobs.append(job)
                guard depthJobs.count > Self.depthQueue else { return false }
                depthJobs.removeFirst() // its numbers become a gap the headset recovers from
                return true
            }
            if dropped { lock.withLock { depthStats.dropped += 1 } }
            depthReady.signal()
        }
    }

    /// The frame's depth into the next of the depth textures: queued on the GPU
    /// ahead of the colour encode, whose completion then covers it, so the
    /// frame's ring slot is free of it by the time `frame` is released.
    private func prepareDepth(_ frame: CapturedFrame, renderPose: RenderPose, renderEye: PixelSize) throws -> DepthJob? {
        guard !depthUnavailable else { return nil }
        if depthPass == nil {
            do {
                depthPass = try DepthPass(device: device)
            } catch {
                depthUnavailable = true
                log.line("depth unavailable, streaming without it: \(error)")
                return nil
            }
        }
        guard let depthPass else { return nil }
        let eye = PCVRProfile.depthEye(forRender: renderEye, divisor: options.depthScale)
        let picture = PixelSize(width: eye.width * 2, height: eye.height)
        if depthTextures.first?.width != Int(picture.width) || depthTextures.first?.height != Int(picture.height) {
            depthTextures = try (0..<Self.depthTextureCount).map { _ in
                try GraphicsTexture(device: device, width: Int(picture.width), height: Int(picture.height), format: .bgra8)
            }
        }
        let texture = depthTextures[nextDepthTexture]
        nextDepthTexture = (nextDepthTexture + 1) % depthTextures.count

        func tangents(_ fov: FieldOfView) -> SIMD4<Float> {
            SIMD4(Float(tan(Double(fov.angleLeft))), Float(tan(Double(fov.angleRight))),
                  Float(tan(Double(fov.angleUp))), Float(tan(Double(fov.angleDown))))
        }
        let frusta = (left: tangents(renderPose.left.fieldOfView), right: tangents(renderPose.right.fieldOfView))
        let near: Float
        let fromGame: Bool
        var maxDisparity = 0
        if options.depth == .auto, let external = frame.external, let aux = external.auxTexture,
           external.auxFormat == 41 || external.auxFormat == 54 { // R32_FLOAT, R16_FLOAT: metres
            // The stereo estimate's floor too: 8-bit inverse depth from 0.1 m
            // stepped 1.4 m at 6 m, and a mesh displaced by it terraced the
            // walls (test scene, 2026-11-07). From 0.25 m the steps are 2.5x finer;
            // anything nearer is drawn at 0.25 m.
            near = stereoNearest
            fromGame = true
            try depthPass.apply(source: aux, kind: .linear, sourceEye: (external.auxWidth / 2, external.auxHeight),
                                destination: texture, depthEye: (Int(eye.width), Int(eye.height)),
                                tangents: frusta, near: near)
        } else {
            let l = renderPose.left.pose.position, r = renderPose.right.pose.position
            let baseline = Float(sqrt(Double((r.x - l.x) * (r.x - l.x) + (r.y - l.y) * (r.y - l.y) + (r.z - l.z) * (r.z - l.z))))
            guard baseline > 0.02, baseline < 0.2 else { return nil } // not a pair of eyes
            let spacing = (frusta.left.y - frusta.left.x) / Float(eye.width)
            maxDisparity = min(max(Int((baseline / (stereoNearest * spacing)).rounded(.up)), 8), 128)
            near = DepthPass.stereoNear(baseline: baseline, maxDisparity: maxDisparity, leftTangents: frusta.left,
                                        depthEyeWidth: Int(eye.width))
            fromGame = false
            try depthPass.apply(source: frame.texture, kind: .stereo(baseline: baseline, maxDisparity: maxDisparity),
                                sourceEye: (Int(renderEye.width), Int(renderEye.height)), destination: texture,
                                depthEye: (Int(eye.width), Int(eye.height)), tangents: frusta, near: near)
        }
        if let directory = options.depthDump, !fromGame {
            let l = renderPose.left.pose.position, r = renderPose.right.pose.position
            let note = String(format: "left tangents %.4f %.4f %.4f %.4f at %.4f %.4f %.4f\nright tangents %.4f %.4f %.4f %.4f at %.4f %.4f %.4f\nnear %.4f max disparity %d\n",
                              frusta.left.x, frusta.left.y, frusta.left.z, frusta.left.w, l.x, l.y, l.z,
                              frusta.right.x, frusta.right.y, frusta.right.z, frusta.right.w, r.x, r.y, r.z,
                              near, maxDisparity)
            dumpDepth(to: directory, texture: texture, maxDisparity: maxDisparity, note: note)
        }
        return DepthJob(texture: texture, picture: picture, eye: eye, near: near, fromGame: fromGame,
                        sequence: frame.sequence, captureTime: 0, numbers: [:], gpuMilliseconds: depthPass.gpuMilliseconds)
    }

    /// Diagnostics (--depth-dump): every few seconds, three frames in a row of
    /// the estimate's luminance grid, grid disparity and output, as PGM, plus
    /// the luminance as raw floats (a fixture for tuning the estimate).
    private func dumpDepth(to directory: String, texture: GraphicsTexture, maxDisparity: Int, note: String) {
        let now = Self.now()
        if depthDumpBurst == 0 {
            guard now - lastDepthDump > 3_000_000_000 else { return }
            lastDepthDump = now
            depthDumpBurst = 3
            depthDumpIndex += 1
        }
        depthDumpBurst -= 1
        guard let depthPass else { return }
        let tag = String(format: "%@/%03d-%d", directory, depthDumpIndex, 2 - depthDumpBurst)
        func pgm(_ path: String, width: Int, height: Int, _ bytes: [UInt8]) {
            var data = Data("P5\n\(width) \(height)\n255\n".utf8)
            data.append(contentsOf: bytes)
            FileManager.default.createFile(atPath: path, contents: data)
        }
        do {
            let luma = try depthPass.debugGrid(.luma)
            pgm(tag + "-luma.pgm", width: luma.width, height: luma.height,
                luma.values.map { $0 < 0 ? 0 : UInt8(min(max($0 * 255, 0), 255)) })
            if depthDumpBurst == 2 {
                FileManager.default.createFile(atPath: tag + "-pose.txt", contents: Data(note.utf8))
                let raw = luma.values.withUnsafeBufferPointer { Data(buffer: $0) }
                FileManager.default.createFile(atPath: tag + "-luma-\(luma.width)x\(luma.height).f32", contents: raw)
            }
            for (grid, suffix) in [(DepthPass.DebugGrid.disparity, "disparity"), (.cleaned, "cleaned")] {
                let values = try depthPass.debugGrid(grid)
                pgm(tag + "-\(suffix).pgm", width: values.width, height: values.height,
                    values.values.map { $0 < 0 ? 0 : UInt8(min(1 + $0 / Float(max(maxDisparity, 1)) * 254, 255)) })
            }
            let out = try texture.read()
            pgm(tag + "-depth.pgm", width: texture.width, height: texture.height,
                stride(from: 0, to: out.count, by: 4).map { out[$0] })
        } catch {
            log.line("depth dump failed: \(error)")
        }
    }

    private func depthLoop() {
        while running {
            _ = depthReady.wait(timeout: .now() + .milliseconds(100))
            guard let job = depthLock.withLock({ () -> DepthJob? in
                depthJobs.isEmpty ? nil : depthJobs.removeFirst()
            }) else { continue }
            do {
                try encodeDepth(job)
            } catch {
                log.line("depth encode failed: \(error)")
                depthEncoder = nil
            }
        }
    }

    /// Depth thread: one depth picture encoded once and queued for each depth
    /// viewer under the number its colour frame got (`job.numbers`, by viewer index).
    private func encodeDepth(_ job: DepthJob) throws {
        let picture = job.picture
        if depthEncoder == nil || depthEncoder?.parameters.width != Int(picture.width)
            || depthEncoder?.parameters.height != Int(picture.height) {
            var parameters = VideoEncoder.Parameters(width: Int(picture.width), height: Int(picture.height),
                                                     fps: Int(lock.withLock { pacedHz }.rounded()),
                                                     bitrate: options.depthMbps * 1_000_000)
            parameters.codec = .hevc
            parameters.asyncMode = true
            parameters.constantQP = options.depthQP
            depthEncoder = nil
            depthEncoder = try VideoEncoder(device: device, parameters: parameters)
            depthParameterSets = []
            depthFormatStale = true
            log.line("depth encoder: HEVC \(picture.width)x\(picture.height), "
                     + (options.depthQP > 0 ? "QP \(options.depthQP), at most \(options.depthMbps) Mbps" : "\(options.depthMbps) Mbps"))
        }
        guard let depthEncoder else { return }
        let forceKey = lock.withLock { () -> Bool in
            let wanted = depthWantsKeyFrame || depthFormatStale
            depthWantsKeyFrame = false
            return wanted
        }
        let (accessUnit, isIDR, milliseconds, qp) = try depthEncoder.encode(job.texture, timestamp: job.sequence,
                                                                           forceIDR: forceKey) {
            (Array($0.bytes), $0.isIDR, HostClock.milliseconds($0.doneTicks - $0.submitTicks), $0.averageQP)
        }
        var newFormat: FormatDescription?
        if isIDR {
            let sets = Self.parameterSets(in: accessUnit)
            if !sets.isEmpty, sets != depthParameterSets || depthFormatStale {
                depthParameterSets = sets
                depthFormatStale = false
                newFormat = FormatDescription(
                    streamID: PCVRProfile.depthStreamID, firstFrameNumber: 0, codec: .hevc, formatKind: .annexBParameterSets,
                    size: picture, bitDepth: 8, chromaFormat: .yuv420, colour: .bt709, configuration: sets,
                    sideDataTypes: [.depthRange],
                    auxiliary: AuxiliaryStream(role: .depth, primaryStreamID: PCVRProfile.streamID),
                    depthEncoding: PCVRProfile.depthEncoding)
            }
        }
        let sideData = SideData(depthRange: .planes(near: job.near, far: .infinity, convergence: 0))

        lock.withLock {
            depthStats.frames += 1
            if job.fromGame { depthStats.game += 1 } else { depthStats.stereo += 1 }
            depthStats.bytes += accessUnit.count
            depthStats.encodeMilliseconds += milliseconds
            depthStats.qpTotal += qp
            depthStats.qpMax = max(depthStats.qpMax, qp)
            depthStats.gpuMilliseconds = job.gpuMilliseconds
            depthStats.size = "\(job.eye.width)x\(job.eye.height) per eye"
            depthStats.near = job.near
            if let newFormat {
                depthFormat = newFormat
                for viewer in viewers.values where viewer.confirmed && viewer.depthSender != nil { sendDepthFormat(to: viewer) }
            }
            let now = Self.now()
            var needsKey = false
            for viewer in viewers.values where viewer.confirmed {
                guard let number = job.numbers[viewer.index], viewer.depthSender != nil,
                      let udpPayload = endpoint.sessions[viewer.index]?.session.udpPayload else { continue }
                do {
                    switch try viewer.depthSender!.submit(accessUnit: accessUnit, isKeyFrame: isIDR,
                                                          captureTime: job.captureTime, sideData: sideData,
                                                          frameNumber: number, udpPayload: udpPayload, now: now) {
                    case .queued: break
                    case .awaitingKeyFrame, .queueFull: needsKey = true
                    }
                } catch {
                    log.line("could not shard a depth frame: \(error)")
                }
            }
            if needsKey { depthWantsKeyFrame = true }
            pump()
        }
    }

    /// VPS, SPS and PPS of an Annex-B HEVC access unit, each with a 4-byte start code.
    static func parameterSets(in accessUnit: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var starts: [(nal: Int, code: Int)] = []
        var i = 0
        while i + 3 <= accessUnit.count {
            if accessUnit[i] == 0, accessUnit[i + 1] == 0, accessUnit[i + 2] == 1 {
                starts.append((i + 3, i > 0 && accessUnit[i - 1] == 0 ? i - 1 : i))
                i += 3
            } else {
                i += 1
            }
        }
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].code : accessUnit.count
            guard start.nal < end else { continue }
            let type = (accessUnit[start.nal] >> 1) & 0x3F
            if (32...34).contains(type) {
                result += [0, 0, 0, 1] + accessUnit[start.nal..<end]
            }
        }
        return result
    }

    private static func format(layout: Layout, epoch: UInt32, parameterSets: [UInt8]) -> FormatDescription {
        FormatDescription(
            streamID: PCVRProfile.streamID, firstFrameNumber: 0, codec: .hevc, formatKind: .annexBParameterSets,
            size: layout.pictureSize, bitDepth: 8, chromaFormat: .yuv420, colour: .bt709, configuration: parameterSets,
            sideDataTypes: layout.warp == nil ? [.renderPose] : [.renderPose, .foveation],
            pcvr: PCVRLayout(layout: .sideBySide, renderSize: layout.renderEye, wireSize: layout.wireEye,
                             foveation: FoveationParameters(epoch: epoch, warp: layout.warp.map { .centreEdge($0) } ?? .none)))
    }

    /// The layout for eyes rendered at `renderEye`: warped when `warp` is
    /// given and actually makes them smaller, as rendered otherwise.
    private static func layout(renderEye: PixelSize, warp: CentreEdgeWarp?) -> Layout {
        if let warp, let wire = warp.wireSize(forRender: renderEye, alignment: PCVRProfile.wireAlignment), wire != renderEye {
            return Layout(renderEye: renderEye, wireEye: wire, warp: warp)
        }
        return Layout(renderEye: renderEye, wireEye: renderEye, warp: nil)
    }

    /// Each eye's warp centre for a frame: where fresh gaze lands in that eye's
    /// rendered frustum; else the last gaze centres, for a short while; else
    /// straight ahead. Gaze and the eye offsets are head-relative, so the head
    /// pose itself never enters (NATIVE_V3_PROTOCOL.md 4.7, gaze projection).
    private func centres(renderPose: RenderPose, head: HeadPose?, now: UInt64)
        -> (NormalizedPoint, NormalizedPoint, CentreSourceSample) {
        if let head, let gaze = head.gaze, let age = Self.age(of: gaze.sampleTime, now: now),
           let left = GazeProjection.centre(direction: gaze.direction, distance: gaze.distance,
                                            deviceFromEye: head.leftEye.pose, fieldOfView: renderPose.left.fieldOfView),
           let right = GazeProjection.centre(direction: gaze.direction, distance: gaze.distance,
                                             deviceFromEye: head.rightEye.pose, fieldOfView: renderPose.right.fieldOfView) {
            lastGazeCentres = (left, right, now)
            return (left, right, .gaze(age: age))
        }
        if let last = lastGazeCentres, now &- last.time <= Self.centreHold {
            return (last.left, last.right, .held)
        }
        func ahead(_ eye: EyeView?, _ fov: FieldOfView) -> NormalizedPoint {
            GazeProjection.centre(direction: Vector3(0, 0, -1), distance: 0, deviceFromEye: eye?.pose ?? .identity,
                                  fieldOfView: fov) ?? .centre
        }
        return (ahead(head?.leftEye, renderPose.left.fieldOfView), ahead(head?.rightEye, renderPose.right.fieldOfView), .ahead)
    }

    /// Where a frame's warp centre came from.
    private enum CentreSourceSample { case gaze(age: UInt64), held, ahead }

    /// A gaze sample's age, or nil when it is too old to centre the warp. A
    /// few milliseconds in the future (the clock mapping's error) count as 0.
    static func age(of sampleTime: UInt64, now: UInt64) -> UInt64? {
        if sampleTime > now { return sampleTime - now <= 5_000_000 ? 0 : nil }
        let age = now - sampleTime
        return age <= gazeMaxAge ? age : nil
    }

    // MARK: Head poses and pacing

    /// The display rates a headset ticks at; a measured pose rate snaps to the nearest within 4%.
    static let displayRates: [Double] = [60, 72, 90, 96, 100, 120]

    static func displayRate(forPoseRate rate: Double) -> Double? {
        guard let nearest = displayRates.min(by: { abs($0 - rate) < abs($1 - rate) }),
              abs(nearest - rate) <= nearest * 0.04 else { return nil }
        return nearest
    }

    private func pacingLoop() {
        var next = HostClock.now()
        var measuredSince = next
        while running {
            let hz = lock.withLock { pacedHz }
            let interval = Int64(Double(HostClock.ticksPerSecond) / hz)
            next += interval
            if options.followsHeadset, next - measuredSince >= 2 * HostClock.ticksPerSecond {
                let seconds = Double(next - measuredSince) / Double(HostClock.ticksPerSecond)
                measuredSince = next
                let (poses, current) = lock.withLock { () -> (Int, Double) in
                    defer { posesForRate = 0 }
                    return (posesForRate, pacedHz)
                }
                if let rate = Self.displayRate(forPoseRate: Double(poses) / seconds), rate != current {
                    lock.withLock { pacedHz = rate }
                    log.line("frame clock: \(Int(rate)) Hz, following the headset (\(String(format: "%.1f", Double(poses) / seconds)) poses/s)")
                }
            }
            let wait = HostClock.milliseconds(next - HostClock.now())
            if wait > 1.5 { Thread.sleep(forTimeInterval: (wait - 1) / 1000) }
            while HostClock.now() < next {}

            var state = ExternalHostState()
            state.refreshMillihertz = UInt32(hz * 1000)
            state.nextFrameStartTicks = next + interval
            if let (sequence, pose) = lock.withLock({ headPose }) {
                state.poseSequence = sequence
                state.poseDisplayTicks = Self.ticks(fromNanoseconds: pose.displayTime)
                state.spaceEpoch = UInt32(pose.spaceEpoch)
                state.head = Self.hostPose(pose.head)
                state.eyeOffsets = (Self.hostPose(pose.leftEye.pose), Self.hostPose(pose.rightEye.pose))
                state.eyeFieldsOfView = (Self.hostFOV(pose.leftEye.fieldOfView), Self.hostFOV(pose.rightEye.fieldOfView))
                if let gaze = pose.gaze {
                    state.gaze = (SIMD3(gaze.direction.x, gaze.direction.y, gaze.direction.z), gaze.distance,
                                  Self.ticks(fromNanoseconds: gaze.sampleTime))
                }
            }
            source?.publish(state)
        }
    }

    private static func hostPose(_ pose: Pose) -> ExternalHostState.Pose {
        var p = ExternalHostState.Pose()
        p.orientation = SIMD4(pose.orientation.x, pose.orientation.y, pose.orientation.z, pose.orientation.w)
        p.position = SIMD3(pose.position.x, pose.position.y, pose.position.z)
        return p
    }

    private static func hostFOV(_ fov: FieldOfView) -> ExternalHostState.FieldOfView {
        var f = ExternalHostState.FieldOfView()
        f.angleLeft = fov.angleLeft
        f.angleRight = fov.angleRight
        f.angleUp = fov.angleUp
        f.angleDown = fov.angleDown
        return f
    }

    // MARK: Datagrams (under `lock`)

    private func reloadDevices(now: UInt64) {
        lastDeviceReload = now
        do {
            let loaded = try PairedDevices.load()
            guard loaded != pairedDevices else { return }
            pairedDevices = loaded
            let removed = endpoint.setDevices(loaded.map { .init(psk: $0.psk, deviceID: $0.id) })
            for index in removed {
                if let viewer = viewers[index] { removeViewer(viewer, reason: "device removed") }
            }
            log.line("paired devices: \(loaded.count) (\(loaded.filter { $0.sessionGrants.contains(.screen) }.count) with the screen grant)")
        } catch {
            log.line("could not read the paired devices: \(error)")
        }
    }

    private func handle(_ datagram: [UInt8], from address: UDPAddress) {
        let now = Self.now()
        let events = endpoint.receive(datagram, from: address, now: now) { deviceID, hello in
            answer(deviceID: deviceID, hello: hello)
        }
        for event in events { handle(event, now: now) }
    }

    private func answer(deviceID: String, hello bytes: [UInt8]) -> [UInt8]? {
        guard let hello = try? ClientHello(decoding: bytes) else { return nil }
        var grants = pairedDevices.first { $0.id == deviceID }?.sessionGrants ?? []
        // This host streams only PCVR: a client that can't take it is refused.
        if !hello.capabilities.contains(.pcvr) || !grants.contains(.screen) { grants = [] }
        let ack = HostHelloAck(answering: hello, hostCapabilities: PCVRProfile.hostCapabilities, platform: .windows,
                               keyCodeSpace: .hidUsage, grants: grants, maxUDPPayload: DatagramLayout.maxProbedUDPPayload,
                               hostName: String(ProcessInfo.processInfo.hostName.prefix(HelloLimits.maxNameBytes)),
                               software: "Longwave PCVR host")
        answered[deviceID] = (hello, grants, hello.sessionCapabilities(from: ack))
        return try? ack.encoded()
    }

    private func handle(_ event: HostEndpoint<UDPAddress>.Event, now: UInt64) {
        switch event {
        case .send(let bytes, let address):
            socket.send(bytes, to: address)
        case .connected(let index, let deviceID, _):
            guard let (hello, grants, capabilities) = answered.removeValue(forKey: deviceID) else { return }
            guard !grants.isEmpty, capabilities.contains(.pcvr) else {
                log.line("refused a session: \(hello.capabilities.contains(.pcvr) ? "no screen grant" : "not a PCVR client")")
                endpoint.remove(index)
                return
            }
            var configuration = VideoStreamSender.Configuration(streamID: PCVRProfile.streamID)
            configuration.rateControl.start = UInt64(options.startMbps) * 125_000
            configuration.rateControl.frameRate = options.refreshHz
            let viewer = Viewer(index: index, deviceID: deviceID, name: hello.deviceName ?? "headset", grants: grants,
                                capabilities: capabilities, configuration: configuration)
            if options.depth != .off, capabilities.contains(.depthVideo) {
                var depth = VideoStreamSender.Configuration(streamID: PCVRProfile.depthStreamID)
                depth.rateControl.start = UInt64(options.depthMbps) * 2 * 125_000
                depth.rateControl.frameRate = options.refreshHz
                viewer.depthSender = VideoStreamSender(configuration: depth)
            }
            viewers[index] = viewer
            _ = endpoint.withSession(index) { $0.setPathCeiling(DatagramLayout.maxProbedUDPPayload, now: now) }
            if let udpPayload = endpoint.sessions[index]?.session.udpPayload {
                viewer.sender.setEncoderCeiling(options.maxMbps * 1_000_000, udpPayload: udpPayload)
                viewer.depthSender?.setEncoderCeiling(options.depthMbps * 2 * 1_000_000, udpPayload: udpPayload)
            }
        case .confirmed(let index):
            guard let viewer = viewers[index], !viewer.confirmed else { return }
            viewer.confirmed = true
            log.line("viewer '\(viewer.name)' connected from \(endpoint.sessions[index]?.address.description ?? "?")"
                + " (\(viewer.capabilities.contains(.foveatedVideo) ? "can unwarp" : "no unwarp")"
                + ", \(viewer.capabilities.contains(.gaze) ? "gaze" : "no gaze")"
                + ", \(viewer.depthSender != nil ? "depth" : "no depth"))")
            sendFormat(to: viewer)
            if viewer.depthSender != nil {
                sendDepthFormat(to: viewer)
                depthWantsKeyFrame = true
            }
            lastKeyFrameRequest = nil
            requestKeyFrame(now: now)
        case .events(let index, let events):
            if let viewer = viewers[index] { handle(events, from: viewer, now: now) }
        case .superseded(let index, _):
            if let viewer = viewers[index] { removeViewer(viewer, reason: "superseded by a newer session") }
        case .closed(let index, let closure):
            if let viewer = viewers[index] { removeViewer(viewer, reason: "session closed: \(closure)") }
        }
    }

    private func handle(_ events: [SessionEvent], from viewer: Viewer, now: UInt64) {
        for event in events {
            switch event {
            case .state(let snapshot):
                guard case .headPose(let pose) = snapshot.payload else { continue }
                if let last = viewer.lastPose, !SerialNumber.isNewer(snapshot.sequence, than: last) { continue }
                viewer.lastPose = snapshot.sequence
                viewer.posesReceived += 1
                posesForRate += 1
                if let presented = pose.presented { viewer.lastPresented = presented }
                headPose = (snapshot.sequence, pose)
            case .message(.control, let message):
                switch message.type {
                case .recoveryRequest:
                    guard let request = try? RecoveryRequest(decoding: message.body) else { continue }
                    if request.streamID == PCVRProfile.depthStreamID {
                        viewer.depthSender?.recoveryRequested()
                        depthWantsKeyFrame = true
                    } else {
                        viewer.sender.recoveryRequested()
                        requestKeyFrame(now: now)
                    }
                case .bye:
                    endpoint.remove(viewer.index)
                    removeViewer(viewer, reason: "viewer said goodbye")
                default:
                    continue
                }
            case .nack(let nack):
                viewer.sender.handle(nack)
                viewer.depthSender?.handle(nack)
            case .feedback(_, let results):
                let rtt = endpoint.sessions[viewer.index]?.session.rtt.smoothed ?? 2_000_000
                viewer.sender.onFeedback(results, now: now, rtt: rtt)
                viewer.depthSender?.onFeedback(results, now: now, rtt: rtt)
            case .message, .video, .audio:
                continue
            }
        }
    }

    private func sendFormat(to viewer: Viewer) {
        guard var format else { return }
        format.firstFrameNumber = viewer.sender.upcomingFrameNumber
        viewer.sender.recoveryRequested()
        guard let body = try? format.encoded() else { return }
        _ = endpoint.withSession(viewer.index) { try? $0.send(.formatDescription, body: body, on: .control) }
    }

    private func sendDepthFormat(to viewer: Viewer) {
        guard var depthFormat, let depthSender = viewer.depthSender else { return }
        // Depth frames take the colour frames' numbers, which are never behind its own.
        depthFormat.firstFrameNumber = max(depthSender.upcomingFrameNumber, viewer.sender.upcomingFrameNumber)
        viewer.depthSender?.recoveryRequested()
        depthWantsKeyFrame = true
        guard let body = try? depthFormat.encoded() else { return }
        _ = endpoint.withSession(viewer.index) { try? $0.send(.formatDescription, body: body, on: .control) }
    }

    private func requestKeyFrame(now: UInt64) {
        if let last = lastKeyFrameRequest, now - last < Self.keyFrameInterval { return }
        lastKeyFrameRequest = now
        wantsKeyFrame = true
    }

    private func endSession(_ viewer: Viewer, reason: String) {
        if let body = try? TextBody.encode(reason) {
            _ = endpoint.withSession(viewer.index) { try? $0.send(.bye, body: body, on: .control) }
        }
        flush(now: Self.now())
        endpoint.remove(viewer.index)
        removeViewer(viewer, reason: "ended by the host")
    }

    private func removeViewer(_ viewer: Viewer, reason: String) {
        guard viewers.removeValue(forKey: viewer.index) != nil else { return }
        log.line("viewer '\(viewer.name)' left: \(reason)")
        if viewers.isEmpty { headPose = nil }
    }

    /// Sends what's due: each viewer's paced media, then the sessions' own datagrams.
    private func pump() {
        let now = Self.now()
        for viewer in viewers.values where viewer.confirmed {
            guard let address = endpoint.sessions[viewer.index]?.address else { continue }
            func drain(_ next: () -> VideoStreamSender.Output?) {
                while let output = next() {
                    let datagram: [UInt8]?? = endpoint.withSession(viewer.index) { session in
                        switch output {
                        case .shard(let header, let data): try? session.sealVideo(header, data: data, now: now)
                        case .padding(let size, let cluster): try? session.sealPadding(size: size, probeCluster: cluster, now: now)
                        }
                    }
                    if let datagram = datagram ?? nil { socket.send(datagram, to: address) }
                }
            }
            // Depth first: a few shards, and the headset wants it before the colour frame.
            if viewer.depthSender != nil { drain { viewer.depthSender!.next(now: now) } }
            drain { viewer.sender.next(now: now) }
        }
        flush(now: now)
        let bitrates = viewers.values.filter(\.confirmed).compactMap { viewer -> Int? in
            guard let session = endpoint.sessions[viewer.index]?.session else { return nil }
            // The depth stream's share comes out of the colour budget.
            let depth = viewer.depthSender == nil ? 0 : options.depthMbps * 1_000_000
            return max(viewer.sender.encoderBitrate(udpPayload: session.udpPayload) - depth, 1_000_000)
        }
        targetBitrate = bitrates.min().map { min($0, options.maxMbps * 1_000_000) }
        if now - lastDeviceReload > 10_000_000_000 { reloadDevices(now: now) }
        if now - lastStats > 5_000_000_000 { logStatistics(now: now) }
    }

    private func flush(now: UInt64) {
        let (datagrams, closed) = endpoint.poll(now: now)
        for datagram in datagrams { socket.send(datagram.bytes, to: datagram.to) }
        for (index, closure) in closed {
            if let viewer = viewers[index] { removeViewer(viewer, reason: "session closed: \(closure)") }
        }
    }

    private func pollTimeout(now: UInt64) -> Int32 {
        var wake = now + 100_000_000
        if let next = endpoint.nextWakeTime(now: now) { wake = min(wake, next) }
        for viewer in viewers.values where viewer.confirmed {
            if let next = viewer.sender.nextWakeTime(now: now) { wake = min(wake, next) }
            if let next = viewer.depthSender?.nextWakeTime(now: now) { wake = min(wake, next) }
        }
        guard wake > now else { return 0 }
        return Int32(max(1, min(100, (wake - now + 999_999) / 1_000_000)))
    }

    private func logStatistics(now: UInt64) {
        let seconds = lastStats == 0 ? 5.0 : Double(now - lastStats) / 1e9
        lastStats = now
        let source = self.source?.statistics
        let superseded = frameLock.withLock { framesSuperseded }
        var line = String(format: "encoded %.1f fps, %.2f ms avg, %.1f Mbps, QP %.1f avg %d max; ", Double(framesEncoded) / seconds,
                          framesEncoded > 0 ? encodeMilliseconds / Double(framesEncoded) : 0,
                          Double(encodedBytes) * 8 / seconds / 1e6,
                          framesEncoded > 0 ? Double(qpTotal) / Double(framesEncoded) : 0, qpMax)
        if let source {
            line += "source \(source.attached ? "attached pid \(source.producerPID)" : "waiting"), delivered \(source.delivered), "
                + "superseded \(superseded), no viewer \(framesWithoutViewers), no render pose \(badSideData)"
        }
        log.line(line)
        if let layout = foveationStats.layout {
            let f = foveationStats
            var fov = "  foveation \(layout)"
            if f.gaze + f.held + f.ahead > 0 {
                fov += "; centres: \(f.gaze) gaze, \(f.held) held, \(f.ahead) ahead"
                if f.gaze > 0 {
                    fov += String(format: "; gaze age %.1f ms avg, %.1f max", Double(f.gazeAgeTotal) / Double(f.gaze) / 1e6,
                                  Double(f.gazeAgeMax) / 1e6)
                }
                if let (l, r) = f.lastCentres {
                    fov += String(format: "; last L (%.2f, %.2f) R (%.2f, %.2f)", l.x, l.y, r.x, r.y)
                }
            }
            log.line(fov)
            foveationStats = FoveationStatistics(layout: layout)
        }
        if let size = depthStats.size {
            let d = depthStats
            var line = "  depth \(size): \(d.stereo) estimated, \(d.game) from the game"
            if d.frames > 0 {
                line += String(format: ", encode %.2f ms avg, %.1f Mbps, QP %.1f avg %d max",
                               d.encodeMilliseconds / Double(d.frames), Double(d.bytes) * 8 / seconds / 1e6,
                               Double(d.qpTotal) / Double(d.frames), d.qpMax)
            }
            if let gpu = d.gpuMilliseconds { line += String(format: ", GPU %.2f ms", gpu) }
            if d.dropped > 0 { line += ", \(d.dropped) dropped behind the encoder" }
            line += String(format: ", near %.3f m", d.near)
            log.line(line)
            depthStats = DepthStatistics(size: size)
        }
        framesEncoded = 0
        encodeMilliseconds = 0
        encodedBytes = 0
        qpTotal = 0
        qpMax = 0
        for viewer in viewers.values where viewer.confirmed {
            guard let session = endpoint.sessions[viewer.index]?.session else { continue }
            let rate = viewer.sender.controller
            let stats = viewer.sender.statistics
            func mbps(_ bytes: UInt64?) -> String { bytes.map { String(format: "%.1f", Double($0) * 8 / 1e6) } ?? "-" }
            log.line("  '\(viewer.name)': budget \(mbps(rate.budget.total)) Mbps, received \(mbps(rate.receiveRate)), "
                + "loss \(String(format: "%.1f", rate.smoothedLoss * 100))%, FEC \(Int(rate.budget.fecRatio * 100))%, "
                + "queue \(rate.queueingDelay / 1_000_000) ms, RTT \(String(format: "%.1f", Double(session.rtt.smoothed) / 1e6)) ms, "
                + "payload \(session.udpPayload); frames \(stats.framesQueued) queued, \(stats.framesSkipped) skipped; "
                + "shards \(stats.shardsSent) sent, \(stats.shardsResent) resent; "
                + String(format: "poses %.0f/s", Double(viewer.posesReceived) / seconds)
                + (viewer.lastPresented.map { ", last shown frame \($0.frameNumber)" } ?? ""))
            viewer.posesReceived = 0
        }
    }
}

/// Timestamped lines to stdout and, optionally, a file (the host usually runs
/// in the desktop session, where nobody reads its console).
final class HostLog: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle?

    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            file = FileHandle(forWritingAtPath: path)
        } else {
            file = nil
        }
    }

    func line(_ text: String) {
        let stamp = String(format: "%.3f", Double(HostClock.now()) / Double(HostClock.ticksPerSecond))
        let line = "[\(stamp)] \(text)\n"
        lock.withLock {
            print(line, terminator: "")
            fflush(stdout)
            file?.write(Data(line.utf8))
        }
    }
}
