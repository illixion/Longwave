#if FOVEATED_ENABLED
import CoreMedia
import CoreVideo
import DebugTrace
import Foundation
import Metal
import Network
import QuartzCore
import RAVECompanion
import StreamCrypto
import StreamPlayout
import StreamTransport
import StreamWire
import VideoToolbox
import os
import simd

/// Where Shell A's v3 source connects: the gaming PC's v3 port, with the
/// credential this headset got when it paired with the PC's Companion.
nonisolated struct PCVRV3Target: Sendable, Equatable {
    var host: String
    var port: UInt16 = PCVRProfile.port
    var credential: CompanionCredential
    var deviceName: String
}

/// What the dev window shows about the v3 source, refreshed by the remote.
nonisolated struct PCVRV3Status: Equatable, Sendable {
    var state = "Idle"
    var framesDecoded = 0
    var framesLost = 0
    var decodeErrors = 0
    var rttMilliseconds: Double?
    var megabitsPerSecond: Double = 0
    var decodeMilliseconds: Double?
    var posesPerSecond: Double = 0
    /// Whether the host accepted `gaze`, and how many poses a second carried a sample.
    var gazeNegotiated = false
    var gazePerSecond: Double = 0
    var picture = "—"
    /// Whether the host packs the eyes with the centre/edge warp, and where the
    /// last frame's full-density centres were (left x, y, right x, y; top-left UVs).
    var foveated = false
    var foveationCentres: [Float]?
    /// Frames dropped because their foveation side data didn't match the format.
    var framesWithoutFoveation = 0
    /// Whether the host sends the depth stream, and how much of it arrived.
    var depthNegotiated = false
    var depthFramesDecoded = 0
    var depthFramesLost = 0
    var depthPicture = "—"
}

/// The depth stream's decoded pictures (NATIVE_V3_PROTOCOL.md §4.8, PCVR), kept
/// a few frames so a presenter can pair each eye frame with the depth that has
/// its number. Depth decodes in a fraction of the eye frame's time, so it is
/// usually there first.
nonisolated final class PCVRDepthStore: @unchecked Sendable {
    /// One decoded depth picture; keeps its decoder buffer alive.
    final class Entry: @unchecked Sendable {
        let frameNumber: UInt32
        let map: PCVRDepthMap
        private let release: (@Sendable () -> Void)?

        init(frameNumber: UInt32, map: PCVRDepthMap, release: (@Sendable () -> Void)?) {
            self.frameNumber = frameNumber
            self.map = map
            self.release = release
        }

        deinit { release?() }
    }

    private static let kept = 6
    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    func deliver(_ entry: Entry) {
        let dropped = entries.withLock { list -> [Entry] in
            list.append(entry)
            guard list.count > Self.kept else { return [] }
            let extra = Array(list.prefix(list.count - Self.kept))
            list.removeFirst(list.count - Self.kept)
            return extra
        }
        withExtendedLifetime(dropped) {}
    }

    /// The depth with this frame number, else the newest older one within
    /// `tolerance` frames (a lost depth frame: close, not exact), else nil.
    func depth(for frameNumber: UInt32, tolerance: UInt32 = 2) -> Entry? {
        entries.withLock { list in
            if let exact = list.last(where: { $0.frameNumber == frameNumber }) { return exact }
            return list.last { !PCVRSerialNumber.isNewer($0.frameNumber, than: frameNumber) && frameNumber &- $0.frameNumber <= tolerance }
        }
    }

    func clear() {
        let all = entries.withLock { list -> [Entry] in
            defer { list = [] }
            return list
        }
        withExtendedLifetime(all) {}
    }
}

/// Shell A's real frame source: the client half of Native v3's PCVR profile
/// (NATIVE_V3_PROTOCOL.md §4.7) against the Windows host. A drop-in for
/// `PCVRFakeRemote`: it feeds the same `PCVRFrameMailbox` and takes the same
/// head-pose snapshots.
///
/// - Network: a UDP socket and a timer driving the package's sans-I/O
///   `ClientConnector`, `TransportSession` and `VideoStreamReceiver`, as
///   `MacNativeV3Link` does for the desktop. Everything there runs on `queue`.
/// - Video: the host's NVENC output is Annex-B HEVC, both eyes side by side;
///   VideoToolbox decodes it to BGRA (colour conversion in the decoder's own
///   hardware path), and the frame's `renderPose` side data goes with it.
/// - Uplink: every head-pose snapshot goes up as a STATE `headPose`, its
///   times moved onto the host's clock with the transport's clock estimate.
///   Until that estimate exists (about two seconds of PINGs) poses are held
///   back: a pose with a wrong display time would make the host predict for
///   the wrong moment.
///
/// A session that fails or times out is retried every two seconds while the
/// remote runs, so the space can be opened before the PC's host is up.
nonisolated final class PCVRV3Remote: @unchecked Sendable {
    let status = OSAllocatedUnfairLock(initialState: PCVRV3Status())

    private let target: PCVRV3Target
    private let psk: StreamPSK
    private let mailbox: PCVRFrameMailbox
    private let decoder: PCVRHEVCDecoder
    /// The depth stream, when this receiver asked for it (`wantsDepth`).
    let depthStore: PCVRDepthStore?
    private let depthDecoder: PCVRHEVCDecoder?
    private let queue = DispatchQueue(label: "pro.longwave.pcvr.v3", qos: .userInteractive)
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRV3Remote")

    // Everything below is touched only on `queue`.
    private let hello: ClientHello
    private var connector: ClientConnector?
    private var connection: NWConnection?
    private var timer: NativeV3Timer?
    private var session: TransportSession?
    private var gazeNegotiated = false
    private var needsTimedKeyFrame = true
    private var receiver = VideoStreamReceiver(streamID: PCVRProfile.streamID)
    private var receiverDue: UInt64 = 0
    private var pendingFormats: [FormatDescription] = []
    private var activeFormat: FormatDescription?
    private var depthNegotiated = false
    private var depthReceiver = VideoStreamReceiver(streamID: PCVRProfile.depthStreamID)
    private var depthDue: UInt64 = 0
    private var pendingDepthFormats: [FormatDescription] = []
    private var activeDepthFormat: FormatDescription?
    private var depthNeedsKeyFrame = true
    /// Bumped per format applied: the frame numbering's run (`PCVRDecodedFrame.streamEpoch`).
    private var streamEpoch: UInt32 = 0
    private var running = false
    private var retryAt: UInt64?
    private var attempts = 0
    private var counters = Counters()
    private var lastStats: UInt64 = 0
    private var lastCentres: [Float]?

    private struct Counters {
        var framesAssembled = 0
        var framesWithoutPose = 0
        var framesWithoutFoveation = 0
        var payloadBytes = 0
        var posesSent = 0
        var gazeSent = 0
        var posesUnsynced = 0
        var depthAssembled = 0
    }

    private static let retryInterval: UInt64 = 2_000_000_000
    private static let statsInterval: UInt64 = 5_000_000_000

    /// - Parameter offersGaze: Offer `gaze` in the hello. Pass true only when
    ///   the pose producer has a gaze source with local capture times; the
    ///   uplink then carries fresh samples and stays empty otherwise.
    /// - Parameter wantsDepth: Offer `depthVideo`, for a presenter that
    ///   reprojects by depth: the host's depth pictures land in `depthStore`.
    init?(device: any MTLDevice, mailbox: PCVRFrameMailbox, target: PCVRV3Target,
          offersGaze: Bool = false, wantsDepth: Bool = false) throws {
        guard let psk = NativeV3.psk(for: target.credential) else { return nil }
        self.target = target
        self.psk = psk
        self.mailbox = mailbox
        decoder = try PCVRHEVCDecoder(device: device, output: .colour(mailbox))
        if wantsDepth {
            let store = PCVRDepthStore()
            depthStore = store
            depthDecoder = try PCVRHEVCDecoder(device: device, output: .depth(store))
        } else {
            depthStore = nil
            depthDecoder = nil
        }
        hello = ClientHello(capabilities: PCVRProfile.clientCapabilities(gaze: offersGaze, depth: wantsDepth),
                            platform: .visionOS,
                            maxUDPPayload: DatagramLayout.maxProbedUDPPayload, intent: [.screen],
                            deviceName: NativeV3.helloName(target.deviceName), software: NativeV3.softwareVersion)
        decoder.onDecodeError = { [weak self] in
            self?.queue.async { self?.requestKeyFrame() }
        }
        depthDecoder?.onDecodeError = { [weak self] in
            self?.queue.async { self?.requestDepthKeyFrame() }
        }
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            timer = NativeV3Timer(queue: queue) { [weak self] in
                self?.timer?.fired()
                self?.drive()
            }
            connect()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            if session != nil, let body = try? TextBody.encode("") {
                try? session?.send(.bye, body: body, on: .control)
                flush(now: NativeV3.now())
            }
            tearDownConnection()
            timer?.cancel()
            timer = nil
            decoder.invalidate()
            depthDecoder?.invalidate()
            depthStore?.clear()
            setState("Stopped")
            log.notice("v3 PCVR source stopped")
        }
    }

    /// The uplink: called on the render thread with every snapshot.
    func receive(_ snapshot: PCVRHeadPoseSnapshot) {
        queue.async { [self] in send(snapshot) }
    }

    // MARK: Connecting (on `queue`)

    private func connect() {
        guard running, let port = NWEndpoint.Port(rawValue: target.port), let helloBytes = try? hello.encoded() else { return }
        attempts += 1
        connector = ClientConnector(psk: psk, hello: helloBytes)
        receiver = VideoStreamReceiver(streamID: PCVRProfile.streamID)
        pendingFormats = []
        activeFormat = nil
        needsTimedKeyFrame = true
        depthReceiver = VideoStreamReceiver(streamID: PCVRProfile.depthStreamID)
        pendingDepthFormats = []
        activeDepthFormat = nil
        depthNeedsKeyFrame = true
        depthStore?.clear()
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: NativeV3.parameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.drive()
            case .failed(let error): self?.lost("socket failed: \(error.localizedDescription)")
            default: break
            }
        }
        receive(on: connection)
        connection.start(queue: queue)
        setState(attempts == 1 ? "Connecting…" : "Connecting… (attempt \(attempts))")
        log.notice("v3 PCVR source connecting to the PC, attempt \(self.attempts, privacy: .public)")
    }

    private func tearDownConnection() {
        connection?.cancel()
        connection = nil
        connector = nil
        session = nil
        gazeNegotiated = false
        depthNegotiated = false
    }

    /// The session ended or never started: try again shortly while running.
    private func lost(_ reason: String) {
        guard running else { return }
        log.notice("v3 PCVR source: \(reason, privacy: .public); retrying")
        tearDownConnection()
        setState("Waiting for the PC (\(reason))")
        retryAt = NativeV3.now() + Self.retryInterval
        timer?.arm(at: retryAt)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty { handle(datagram: [UInt8](data)) }
            if error == nil { receive(on: connection) }
        }
    }

    private func handle(datagram: [UInt8]) {
        let now = NativeV3.now()
        guard session != nil else {
            guard let (opened, ackBytes) = connector?.receive(datagram, now: now) else { return }
            connected(opened, ackBytes: ackBytes, now: now)
            return
        }
        let events: [SessionEvent]
        do {
            events = try session!.receive(datagram, now: now)
        } catch {
            lost("session closed (\(error))")
            return
        }
        for event in events { handle(event, now: now) }
        drive()
    }

    private func connected(_ opened: TransportSession, ackBytes: [UInt8], now: UInt64) {
        guard let ack = try? HostHelloAck(decoding: ackBytes) else {
            lost("unreadable hello-ack")
            return
        }
        guard !ack.refused else {
            // Not worth retrying until the grant changes, but cheap: keep trying.
            lost("the PC refused this headset (no screen grant)")
            return
        }
        let capabilities = hello.sessionCapabilities(from: ack)
        guard capabilities.contains(.pcvr) else {
            lost("the PC's host doesn't offer PCVR")
            return
        }
        gazeNegotiated = capabilities.contains(.gaze)
        if hello.capabilities.contains(.gaze) {
            log.notice("v3 PCVR gaze \(self.gazeNegotiated ? "negotiated" : "not offered by the PC", privacy: .public)")
        }
        depthNegotiated = capabilities.contains(.depthVideo) && depthDecoder != nil
        if hello.capabilities.contains(.depthVideo) {
            log.notice("v3 PCVR depth \(self.depthNegotiated ? "negotiated" : "not offered by the PC", privacy: .public)")
        }
        let depthNegotiated = depthNegotiated
        status.withLock { $0.depthNegotiated = depthNegotiated }
        var session = opened
        session.setPathCeiling(ack.maxUDPPayload, now: now)
        self.session = session
        connector = nil
        var configuration = VideoStreamReceiver.Configuration()
        configuration.nacks = capabilities.contains(.nack)
        receiver = VideoStreamReceiver(streamID: PCVRProfile.streamID, configuration: configuration)
        depthReceiver = VideoStreamReceiver(streamID: PCVRProfile.depthStreamID, configuration: configuration)
        attempts = 0
        setState("Connected, waiting for the picture")
        log.notice("v3 PCVR session up (\(ack.platform.description, privacy: .public), datagrams up to \(ack.maxUDPPayload, privacy: .public) bytes)")
        drive()
    }

    // MARK: Session events (on `queue`)

    private func handle(_ event: SessionEvent, now: UInt64) {
        switch event {
        case .message(.control, let message):
            handleControl(message)
        case .video(let header, let data):
            counters.payloadBytes += data.count
            if header.streamID == PCVRProfile.depthStreamID {
                guard depthNegotiated else { break }
                handleDepth(depthReceiver.receive(header, data: data, now: now))
                depthDue = min(depthDue, now + 2_000_000)
            } else {
                handle(receiver.receive(header, data: data, now: now))
                receiverDue = min(receiverDue, now + 2_000_000)
            }
        case .message, .audio, .state, .nack, .feedback:
            break
        }
    }

    private func handleControl(_ message: Message) {
        switch message.type {
        case .formatDescription:
            guard let format = try? FormatDescription(decoding: message.body) else { return }
            if format.streamID == PCVRProfile.streamID {
                pendingFormats.append(format)
            } else if format.streamID == PCVRProfile.depthStreamID, depthNegotiated,
                      format.auxiliary == AuxiliaryStream(role: .depth, primaryStreamID: PCVRProfile.streamID),
                      format.depthEncoding?.kind == .inverseLinear {
                pendingDepthFormats.append(format)
            }
        case .bye:
            let reason = (try? TextBody.decode(message.body)) ?? ""
            lost(reason.isEmpty ? "the PC ended the session" : "the PC ended the session: \(reason)")
        default:
            break
        }
    }

    private func handle(_ outputs: [VideoStreamReceiver.Output]) {
        for output in outputs {
            switch output {
            case .frame(let frame):
                deliver(frame)
            case .nack(let nack):
                session?.send(nack)
            case .recovery(let request):
                if let body = try? request.encoded() { try? session?.send(.recoveryRequest, body: body, on: .control) }
            }
        }
    }

    /// The decoder lost its state: freeze until a key frame, and ask for one.
    private func requestKeyFrame() {
        guard session != nil else { return }
        let now = NativeV3.now()
        handle(receiver.requestKeyFrame(now: now))
        receiverDue = min(receiverDue, receiver.nextWakeTime(now: now) ?? .max)
        drive()
    }

    private func handleDepth(_ outputs: [VideoStreamReceiver.Output]) {
        for output in outputs {
            switch output {
            case .frame(let frame):
                deliverDepth(frame)
            case .nack(let nack):
                session?.send(nack)
            case .recovery(let request):
                if let body = try? request.encoded() { try? session?.send(.recoveryRequest, body: body, on: .control) }
            }
        }
    }

    private func requestDepthKeyFrame() {
        guard session != nil, depthNegotiated else { return }
        let now = NativeV3.now()
        handleDepth(depthReceiver.requestKeyFrame(now: now))
        depthDue = min(depthDue, depthReceiver.nextWakeTime(now: now) ?? .max)
        drive()
    }

    private func deliverDepth(_ frame: AssembledVideoFrame) {
        counters.depthAssembled += 1
        while let next = pendingDepthFormats.first, !SerialNumber.isNewer(next.firstFrameNumber, than: frame.frameNumber) {
            pendingDepthFormats.removeFirst()
            applyDepth(next)
        }
        guard let format = activeDepthFormat, let depthDecoder,
              case .planes(let near, let far, _) = frame.payload.sideData.depthRange else { return }
        if depthNeedsKeyFrame {
            guard frame.flags.contains(.key) else { requestDepthKeyFrame(); return }
            depthNeedsKeyFrame = false
        }
        depthDecoder.decodeDepth(accessUnit: frame.payload.accessUnit, isKeyFrame: frame.flags.contains(.key),
                                 frameNumber: frame.frameNumber, near: near, far: far, fullRange: format.colour.fullRange,
                                 valueBits: Int(format.depthEncoding?.valueBits ?? 8))
    }

    private func applyDepth(_ format: FormatDescription) {
        guard format.codec == .hevc, format.formatKind == .annexBParameterSets, let depthDecoder else { return }
        do {
            try depthDecoder.setFormat(format)
        } catch {
            log.error("v3 PCVR depth decoder could not take the format: \(String(describing: error), privacy: .public)")
            activeDepthFormat = nil
            requestDepthKeyFrame()
            return
        }
        activeDepthFormat = format
        let picture = "HEVC \(Int(format.size.width) / 2)×\(format.size.height) per eye"
        status.withLock { $0.depthPicture = picture }
        log.notice("v3 PCVR depth format: \(picture, privacy: .public)")
    }

    private func deliver(_ frame: AssembledVideoFrame) {
        counters.framesAssembled += 1
        while let next = pendingFormats.first, !SerialNumber.isNewer(next.firstFrameNumber, than: frame.frameNumber) {
            pendingFormats.removeFirst()
            apply(next)
        }
        guard activeFormat != nil else { return }
        guard let wirePose = frame.payload.sideData.renderPose else {
            counters.framesWithoutPose += 1
            needsTimedKeyFrame = true
            return
        }
        guard let renderPose = Self.renderMetadata(wirePose, localTime: {
            session?.clock.localTime(atRemote: $0)
        }) else {
            needsTimedKeyFrame = true
            return
        }
        // A warped picture is only drawable with the centres it was warped
        // around, under this format's parameters.
        var foveation: PCVRFoveation?
        if let pcvr = activeFormat?.pcvr, pcvr.foveation.warp != .none {
            guard let side = frame.payload.sideData.foveation,
                  let mapping = PCVRFoveation(parameters: pcvr.foveation, frame: side, renderEye: pcvr.renderSize) else {
                counters.framesWithoutFoveation += 1
                needsTimedKeyFrame = true
                return
            }
            foveation = mapping
        }
        // Skipping an unsynchronised reference frame breaks its dependants.
        // Resume on an IDR after clock sync, rather than decoding a P frame
        // against the missing picture.
        if needsTimedKeyFrame {
            guard frame.flags.contains(.key) else { requestKeyFrame(); return }
            needsTimedKeyFrame = false
        }
        if let foveation {
            let l = foveation.mapping.left, r = foveation.mapping.right
            lastCentres = [l.x.effectiveCentre, l.y.effectiveCentre, r.x.effectiveCentre, r.y.effectiveCentre]
        } else {
            lastCentres = nil
        }
        decoder.decode(accessUnit: frame.payload.accessUnit, isKeyFrame: frame.flags.contains(.key),
                       frameNumber: frame.frameNumber, streamEpoch: streamEpoch, renderPose: renderPose,
                       foveation: foveation)
    }

    /// A frame without a clock mapping cannot supply a truthful render time.
    static func renderMetadata(_ wirePose: RenderPose?, localTime: (UInt64) -> UInt64?) -> PCVRRenderPose? {
        guard let wirePose, let time = localTime(wirePose.displayTime) else { return nil }
        return PCVRRenderPose(
            poseSequence: wirePose.poseSequence,
            spaceEpoch: wirePose.spaceEpoch,
            displayTime: Self.seconds(time),
            eyes: PCVRStereo(left: Self.eyeView(wirePose.left), right: Self.eyeView(wirePose.right)))
    }

    private func apply(_ format: FormatDescription) {
        guard format.codec == .hevc, format.formatKind == .annexBParameterSets else {
            log.error("v3 PCVR format not supported (\(String(describing: format.codec), privacy: .public), kind \(format.formatKind.rawValue, privacy: .public))")
            return
        }
        do {
            try decoder.setFormat(format)
        } catch {
            log.error("v3 PCVR decoder could not take the format: \(String(describing: error), privacy: .public)")
            activeFormat = nil
            requestKeyFrame()
            return
        }
        activeFormat = format
        streamEpoch &+= 1
        var eye = format.pcvr.map { "\($0.wireSize.width)×\($0.wireSize.height) per eye" } ?? "\(format.size.width)×\(format.size.height)"
        var foveated = false
        if let pcvr = format.pcvr, case .centreEdge(let warp) = pcvr.foveation.warp {
            foveated = true
            eye += String(format: ", foveated from %d×%d (centre %.2f×%.2f, edges 1/%.1f×1/%.1f)",
                          Int(pcvr.renderSize.width), Int(pcvr.renderSize.height), warp.centreSizeX, warp.centreSizeY,
                          warp.edgeRatioX, warp.edgeRatioY)
            log.notice("v3 PCVR stream is foveated: \(eye, privacy: .public)")
        }
        status.withLock {
            $0.picture = "HEVC \(eye)"
            $0.foveated = foveated
        }
        setState("Streaming")
        log.notice("v3 PCVR format: HEVC \(format.size.width, privacy: .public)x\(format.size.height, privacy: .public), \(format.bitDepth, privacy: .public)-bit")
    }

    // MARK: Uplink (on `queue`)

    private func send(_ snapshot: PCVRHeadPoseSnapshot) {
        guard let clock = session?.clock else { return }
        let now = NativeV3.now()
        guard let hostNow = clock.remoteTime(atLocal: now),
              let displayTime = clock.remoteTime(atLocal: Self.nanoseconds(snapshot.displayTime)) else {
            counters.posesUnsynced += 1
            return
        }
        var presented: PresentedFrame?
        if let frame = snapshot.lastPresentedFrame, let time = snapshot.lastPresentTime,
           let hostTime = clock.remoteTime(atLocal: Self.nanoseconds(time)) {
            presented = PresentedFrame(frameNumber: frame, presentTime: hostTime)
        }
        let pose = HeadPose(displayTime: displayTime, spaceEpoch: snapshot.spaceEpoch, head: Self.wirePose(snapshot.head),
                            leftEye: Self.wireEye(snapshot.eyes.left), rightEye: Self.wireEye(snapshot.eyes.right),
                            presented: presented,
                            gaze: snapshot.gaze.wireSample(now: Self.seconds(now), negotiated: gazeNegotiated) {
                                clock.remoteTime(atLocal: Self.nanoseconds($0))
                            })
        // Built first: the optional-chained mutating send holds `session`.
        let state = StateSnapshot(sequence: snapshot.sequence, hostTime: hostNow, payload: .headPose(pose))
        session?.send(state)
        counters.posesSent += 1
        if pose.gaze != nil { counters.gazeSent += 1 }
        flush(now: now)
    }

    // MARK: Driving (on `queue`)

    private func drive() {
        guard running else { return }
        let now = NativeV3.now()
        if let retryAt {
            guard now >= retryAt else {
                timer?.arm(at: retryAt)
                return
            }
            self.retryAt = nil
            connect()
        }
        guard session != nil else {
            guard var connector, let connection else { return }
            do {
                if let initiation = try connector.poll(now: now) { NativeV3.send([initiation], on: connection) }
                self.connector = connector
                timer?.arm(at: connector.nextWakeTime)
            } catch .timedOut {
                lost("no answer from the PC on UDP \(target.port)")
            } catch {
                lost("couldn't start a secure session")
            }
            return
        }
        if now >= receiverDue {
            handle(receiver.poll(now: now, rtt: session?.rtt.smoothed ?? 0))
            receiverDue = receiver.nextWakeTime(now: now) ?? .max
        }
        if depthNegotiated, now >= depthDue {
            handleDepth(depthReceiver.poll(now: now, rtt: session?.rtt.smoothed ?? 0))
            depthDue = depthReceiver.nextWakeTime(now: now) ?? .max
        }
        flush(now: now)
        if let closure = session?.closure {
            lost(closure == .timedOut ? "the PC stopped answering" : "session closed (\(closure))")
            return
        }
        if now - lastStats >= Self.statsInterval { reportStats(now: now) }
        let wakes = [session?.nextWakeTime(now: now), receiverDue, depthNegotiated ? depthDue : nil,
                     lastStats + Self.statsInterval].compactMap { $0 }
        timer?.arm(at: max(wakes.min() ?? now + 250_000_000, now + 50_000))
    }

    private func flush(now: UInt64) {
        guard let connection, let datagrams = session?.poll(now: now) else { return }
        NativeV3.send(datagrams, on: connection)
    }

    private func reportStats(now: UInt64) {
        let elapsed = lastStats == 0 ? 0 : Double(now - lastStats) / 1e9
        lastStats = now
        guard elapsed > 0 else {
            counters = Counters()
            return
        }
        let decoded = decoder.takeCounters()
        let depthDecoded = depthDecoder?.takeCounters()
        let depthLost = depthReceiver.statistics.framesLost
        let rtt = session.map { Double($0.rtt.smoothed) / 1e6 }
        let mbps = Double(counters.payloadBytes) * 8 / elapsed / 1e6
        let decodeMs = decoded.frames > 0 ? decoded.decodeSeconds / Double(decoded.frames) * 1000 : nil
        let poseRate = Double(counters.posesSent) / elapsed
        let gazeRate = Double(counters.gazeSent) / elapsed
        let gazeNegotiated = gazeNegotiated
        let lost = receiver.statistics.framesLost
        let withoutFoveation = counters.framesWithoutFoveation
        let centres = lastCentres
        status.withLock {
            $0.framesWithoutFoveation += withoutFoveation
            $0.foveationCentres = centres
            $0.framesDecoded += decoded.frames
            $0.decodeErrors += decoded.errors
            $0.framesLost = lost
            $0.rttMilliseconds = rtt
            $0.megabitsPerSecond = mbps
            $0.decodeMilliseconds = decodeMs
            $0.posesPerSecond = poseRate
            $0.gazeNegotiated = gazeNegotiated
            $0.gazePerSecond = gazeRate
            $0.depthFramesDecoded += depthDecoded?.frames ?? 0
            $0.depthFramesLost = depthLost
        }
        log.notice("v3 PCVR: \(Double(self.counters.framesAssembled) / elapsed, format: .fixed(precision: 1), privacy: .public) fps received, \(Double(decoded.frames) / elapsed, format: .fixed(precision: 1), privacy: .public) decoded, \(decoded.errors, privacy: .public) decode errors, \(lost, privacy: .public) lost in total, \(self.counters.framesWithoutPose, privacy: .public) without a render pose, \(self.counters.framesWithoutFoveation, privacy: .public) without matching foveation; \(mbps, format: .fixed(precision: 1), privacy: .public) Mbps, RTT \(rtt ?? -1, format: .fixed(precision: 1), privacy: .public) ms, decode \(decodeMs ?? -1, format: .fixed(precision: 2), privacy: .public) ms; poses \(poseRate, format: .fixed(precision: 1), privacy: .public)/s sent (gaze in \(gazeRate, format: .fixed(precision: 1), privacy: .public)/s), \(self.counters.posesUnsynced, privacy: .public) held for clock sync")
        if depthNegotiated, let depthDecoded {
            log.notice("v3 PCVR depth: \(Double(self.counters.depthAssembled) / elapsed, format: .fixed(precision: 1), privacy: .public) fps received, \(Double(depthDecoded.frames) / elapsed, format: .fixed(precision: 1), privacy: .public) decoded, \(depthDecoded.errors, privacy: .public) decode errors, \(depthLost, privacy: .public) lost in total, decode \(depthDecoded.frames > 0 ? depthDecoded.decodeSeconds / Double(depthDecoded.frames) * 1000 : -1, format: .fixed(precision: 2), privacy: .public) ms")
        }
        counters = Counters()
    }

    private func setState(_ state: String) {
        status.withLock { $0.state = state }
    }

    // MARK: Conversions

    /// The receiver clock (`CACurrentMediaTime`) and `NativeV3.now()` both count
    /// `mach_absolute_time`, so they differ only in unit.
    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(seconds, 0) * 1e9) }
    private static func seconds(_ nanoseconds: UInt64) -> TimeInterval { Double(nanoseconds) / 1e9 }

    static func wirePose(_ pose: PCVRPose) -> Pose {
        let q = pose.rotation.vector
        return Pose(orientation: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w),
                    position: Vector3(pose.position.x, pose.position.y, pose.position.z))
    }

    static func wireEye(_ eye: PCVREyeGeometry) -> EyeView {
        let fov = eye.fieldOfView
        return EyeView(pose: wirePose(eye.deviceFromEye),
                       fieldOfView: FieldOfView(angleLeft: fov.angleLeft, angleRight: fov.angleRight,
                                                angleUp: fov.angleUp, angleDown: fov.angleDown))
    }

    static func eyeView(_ view: EyeView) -> PCVREyeView {
        let o = view.pose.orientation, p = view.pose.position, f = view.fieldOfView
        return PCVREyeView(pose: PCVRPose(rotation: simd_quatf(ix: o.x, iy: o.y, iz: o.z, r: o.w),
                                          position: SIMD3(p.x, p.y, p.z)),
                           fieldOfView: PCVRFieldOfView(angleLeft: f.angleLeft, angleRight: f.angleRight,
                                                        angleUp: f.angleUp, angleDown: f.angleDown))
    }
}

/// VideoToolbox HEVC decode for the v3 PCVR streams. Decoding is
/// asynchronous; each decoded picture goes straight to its output from
/// VideoToolbox's callback.
/// - `colour`: the eye stream, into BGRA Metal textures the receiver samples as
///   sRGB (the host's eye images are sRGB-encoded BGRA8 before NVENC), to the mailbox.
/// - `depth`: the depth auxiliary, its luma plane alone as an r8 texture (the
///   host's grey depth needs no colour conversion), to the depth store.
nonisolated final class PCVRHEVCDecoder: @unchecked Sendable {
    enum Failure: Error { case parameterSets, formatDescription(OSStatus), session(OSStatus) }

    enum Output {
        case colour(PCVRFrameMailbox)
        case depth(PCVRDepthStore)
    }

    /// A picture failed to decode: the stream needs a key frame.
    var onDecodeError: (@Sendable () -> Void)?

    private let output: Output
    private let textureCache: CVMetalTextureCache
    private let lock = OSAllocatedUnfairLock(initialState: Tally())
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var configuration: [UInt8] = []
    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRV3Remote")

    struct Tally {
        var frames = 0
        var errors = 0
        var decodeSeconds: Double = 0
    }

    init(device: any MTLDevice, output: Output) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw PCVRReceiverError.resourceCreationFailed("texture cache") }
        textureCache = cache
        self.output = output
    }

    private var isDepth: Bool {
        if case .depth = output { return true }
        return false
    }

    deinit { invalidate() }

    func takeCounters() -> Tally {
        // Lets the cache drop textures for buffers VideoToolbox has recycled.
        CVMetalTextureCacheFlush(textureCache, 0)
        return lock.withLock { tally in
            defer { tally = Tally() }
            return tally
        }
    }

    /// A new format: a new session unless it is the one already running.
    /// Called on the remote's queue, as is `decode`.
    func setFormat(_ format: FormatDescription) throws {
        if format.configuration == configuration, session != nil { return }
        guard let sets = PCVRAnnexB.parameterSets(format.configuration) else { throw Failure.parameterSets }
        var description: CMVideoFormatDescription?
        let status = sets.vps.withUnsafeBufferPointer { vps in
            sets.sps.withUnsafeBufferPointer { sps in
                sets.pps.withUnsafeBufferPointer { pps in
                    let pointers = [vps.baseAddress!, sps.baseAddress!, pps.baseAddress!]
                    let sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                        extensions: Self.colourExtensions(format.colour), formatDescriptionOut: &description)
                }
            }
        }
        guard status == noErr, let description else { throw Failure.formatDescription(status) }
        invalidate()
        let pixelFormat = !isDepth ? kCVPixelFormatType_32BGRA
            : format.colour.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        guard sessionStatus == noErr, let created else { throw Failure.session(sessionStatus) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        formatDescription = description
        configuration = format.configuration
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        configuration = []
    }

    func decode(accessUnit: some Collection<UInt8>, isKeyFrame: Bool, frameNumber: UInt32, streamEpoch: UInt32,
                renderPose: PCVRRenderPose, foveation: PCVRFoveation? = nil) {
        guard case .colour(let mailbox) = output, let session, let formatDescription else { return }
        let sample = PCVRAnnexB.lengthPrefixedSample(accessUnit)
        guard !sample.isEmpty, let buffer = Self.sampleBuffer(sample, format: formatDescription) else {
            fail("could not wrap an access unit")
            return
        }
        let submitted = CACurrentMediaTime()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: buffer, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                fail("decode failed (\(status))")
                return
            }
            guard let texture = makeTexture(imageBuffer) else {
                fail("could not wrap a decoded picture as a texture")
                return
            }
            let now = CACurrentMediaTime()
            lock.withLock {
                $0.frames += 1
                $0.decodeSeconds += now - submitted
            }
            let metalTexture = texture.texture
            let frame = PCVRDecodedFrame(streamEpoch: streamEpoch, frameNumber: frameNumber, texture: metalTexture,
                                         renderPose: renderPose, foveation: foveation, arrivalTime: now,
                                         release: { withExtendedLifetime((texture, imageBuffer)) {} })
            mailbox.deliver(frame)
        }
        if status != noErr { fail("decode refused (\(status))") }
    }

    /// One depth picture: inverse depth from `near` to `far` (§4.8 kind 1), in
    /// limited-range luma unless `fullRange`.
    func decodeDepth(accessUnit: some Collection<UInt8>, isKeyFrame: Bool, frameNumber: UInt32, near: Float, far: Float,
                     fullRange: Bool, valueBits: Int) {
        guard case .depth(let store) = output, let session, let formatDescription else { return }
        let sample = PCVRAnnexB.lengthPrefixedSample(accessUnit)
        guard !sample.isEmpty, let buffer = Self.sampleBuffer(sample, format: formatDescription) else {
            fail("could not wrap a depth access unit")
            return
        }
        // Luma read as unorm: full range is the value itself; limited range
        // has 16...235 (of 255) stretched back to 0...1. Fewer value bits than
        // eight leave the top of the range unused.
        let top = Float((1 << max(1, min(valueBits, 8))) - 1) / 255
        let scale: Float = fullRange ? 1 / top : 255 / 219 / top
        let offset: Float = fullRange ? 0 : -16 / 219 / top
        let submitted = CACurrentMediaTime()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: buffer, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer, let texture = makeTexture(imageBuffer) else {
                fail("depth decode failed (\(status))")
                return
            }
            let now = CACurrentMediaTime()
            lock.withLock {
                $0.frames += 1
                $0.decodeSeconds += now - submitted
            }
            var map = PCVRDepthMap(texture: texture.texture, near: near, far: far)
            map.valueScale = scale
            map.valueOffset = offset
            store.deliver(PCVRDepthStore.Entry(frameNumber: frameNumber, map: map,
                                               release: { withExtendedLifetime((texture, imageBuffer)) {} }))
        }
        if status != noErr { fail("depth decode refused (\(status))") }
    }

    private func fail(_ reason: String) {
        lock.withLock { $0.errors += 1 }
        log.error("v3 PCVR decoder: \(reason, privacy: .public)")
        onDecodeError?()
    }

    private struct WrappedTexture: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let texture: any MTLTexture
    }

    private func makeTexture(_ imageBuffer: CVImageBuffer) -> WrappedTexture? {
        let depth = isDepth
        let width = depth ? CVPixelBufferGetWidthOfPlane(imageBuffer, 0) : CVPixelBufferGetWidth(imageBuffer)
        let height = depth ? CVPixelBufferGetHeightOfPlane(imageBuffer, 0) : CVPixelBufferGetHeight(imageBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, imageBuffer, nil, depth ? .r8Unorm : .bgra8Unorm_srgb, width, height, 0,
            &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return WrappedTexture(cvTexture: cvTexture, texture: texture)
    }

    private static func sampleBuffer(_ sample: [UInt8], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: sample.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = sample.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: sample.count)
        }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        var size = sample.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer) == noErr else { return nil }
        return buffer
    }

    /// The stream's colour as CoreMedia extensions, so VideoToolbox converts to
    /// RGB with the matrix and range the host's encoder used.
    static func colourExtensions(_ colour: ColourInfo) -> CFDictionary {
        var extensions: [CFString: Any] = [kCMFormatDescriptionExtension_FullRangeVideo: colour.fullRange]
        switch colour.matrix {
        case 1: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 5, 6: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        case 9: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: break
        }
        switch colour.primaries {
        case 1: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        case 12: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_P3_D65
        default: break
        }
        switch colour.transfer {
        case 1, 6, 14, 15: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 13: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_sRGB
        default: break
        }
        return extensions as CFDictionary
    }
}
#endif
