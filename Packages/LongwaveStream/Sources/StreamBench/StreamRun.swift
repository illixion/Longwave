// The closed loop the PCVR host runs, on virtual time: frames at the
// display's rate, encoded at whatever the viewer's rate controller allows,
// sharded with FEC, paced onto a modelled link, reassembled (with NACKs and
// recovery) on the headset, and shown at the headset's display ticks. The
// encoder is pluggable: the PC bench passes NVENC, the tests a model of one.
import StreamFEC
import StreamHost
import StreamPlayout
import StreamSim
import StreamTransport
import StreamWire

/// What the loop asks the encoder for.
public struct FrameRequest: Sendable, Equatable {
    /// Captures since the start, 0 first.
    public var index: Int
    /// Run time the frame is rendered for, seconds.
    public var time: Double
    /// The stream's frame rate now.
    public var hz: Double
    /// The colour encoder's target, bits per second.
    public var bitrate: Int
    public var forceKey: Bool

    public init(index: Int, time: Double, hz: Double, bitrate: Int, forceKey: Bool) {
        self.index = index
        self.time = time
        self.hz = hz
        self.bitrate = bitrate
        self.forceKey = forceKey
    }
}

/// What the encoder hands back.
public struct EncodedFrame: Sendable, Equatable {
    public var size: Int
    public var isKey: Bool
    /// How long the encode took; the frame can be sent that long after capture.
    public var encodeSeconds: Double
    public var qp: Int

    public init(size: Int, isKey: Bool, encodeSeconds: Double, qp: Int) {
        self.size = size
        self.isKey = isKey
        self.encodeSeconds = encodeSeconds
        self.qp = qp
    }
}

public protocol BenchEncoder: AnyObject {
    /// Called in capture order, once per frame the sender has room for.
    func encode(_ request: FrameRequest) throws -> EncodedFrame
}

/// One captured frame's life.
public struct FrameRecord: Sendable, Equatable {
    public var index: Int
    public var time: Double
    public var hz: Double
    public var bitrate: Int
    public var size: Int
    public var isKey: Bool
    public var qp: Int
    public var encodeSeconds: Double
    /// The colour stream's frame number, when the sender took it.
    public var frameNumber: UInt32?
    /// Run seconds the headset had the whole frame, and could decode it.
    public var completed: Double?
    public var decodable = false
    public var recoveredShards = 0
    /// Display ticks that showed it.
    public var shownTicks = 0

    public init(index: Int, time: Double, hz: Double, bitrate: Int, size: Int, isKey: Bool, qp: Int, encodeSeconds: Double) {
        self.index = index
        self.time = time
        self.hz = hz
        self.bitrate = bitrate
        self.size = size
        self.isKey = isKey
        self.qp = qp
        self.encodeSeconds = encodeSeconds
    }
}

/// One display refresh on the headset.
public struct TickRecord: Sendable, Equatable {
    public var time: Double
    public var hz: Double
    /// The frame up then (`FrameRecord.index`), nil before the first.
    public var frame: Int?
    /// Seconds from that frame's capture to this tick.
    public var age: Double?

    public init(time: Double, hz: Double, frame: Int?, age: Double?) {
        self.time = time
        self.hz = hz
        self.frame = frame
        self.age = age
    }
}

public struct StreamRunConfiguration: Sendable {
    public var scenario: LinkScenario
    public var refresh: RefreshSchedule
    public var seconds: Double
    /// The colour encoder's ceiling and the rate estimate's start (`--max-mbps`, `--start-mbps`).
    public var maxMbps: Int = 120
    public var startMbps: Int = 100
    /// A floor under the colour bitrate while the link shows no loss (`--min-mbps`,
    /// the host's option of the same name); 0 follows the rate estimate alone.
    public var minMbps: Int = 0
    /// The depth stream: the host reserves `depthReserveMbps` of the budget
    /// for it (`--depth-mbps`); the bench sends `depthLoadMbps` of real traffic.
    public var depthReserveMbps: Int = 40
    public var depthLoadMbps: Double = 4
    /// What the headset needs after the last shard before a frame can go up:
    /// decode, then the presenter's own step.
    public var decodeSeconds: Double = 0.006
    /// The host's `--refresh auto`: the stream runs at half the display's rate
    /// while the encoder's p95 doesn't fit a display period (`StreamRate`).
    public var halvesForEncoder = true
    public var seed: UInt64 = 1

    public init(scenario: LinkScenario, refresh: RefreshSchedule, seconds: Double) {
        self.scenario = scenario
        self.refresh = refresh
        self.seconds = seconds
    }
}

public struct StreamRunResult: Sendable {
    public var frames: [FrameRecord]
    public var ticks: [TickRecord]
    public var held = 0
    public var keyRequests = 0
    public var recoveryRequests = 0
    public var nacks = 0
    public var shardsSent = 0
    public var shardsResent = 0
    public var datagramsLost = 0
    public var datagramsStalled = 0
    public var longestHold: Double = 0
    /// (run seconds, the rate controller's colour target in bits/s), at each capture.
    public var bitrates: [(time: Double, bitsPerSecond: Int)] = []

    public init(frames: [FrameRecord], ticks: [TickRecord]) {
        self.frames = frames
        self.ticks = ticks
    }
}

public final class StreamRun {
    public let configuration: StreamRunConfiguration
    private let encoder: BenchEncoder
    private let session: BenchSession
    private var sender: VideoStreamSender
    private var depthSender: VideoStreamSender
    private var receiver = VideoStreamReceiver(streamID: PCVRProfile.streamID)
    private var depthReceiver = VideoStreamReceiver(streamID: PCVRProfile.depthStreamID)
    private var result = StreamRunResult(frames: [], ticks: [])
    private var start: UInt64 = 0
    private var nextCapture: UInt64 = 0
    private var nextTick: UInt64 = 0
    private var wantsKey = true
    private var lastKeyRequest: UInt64?
    /// Encoded frames waiting for their encode to finish: (submit time, record index).
    private var encoding: [(at: UInt64, index: Int)] = []
    private var byNumber: [UInt32: Int] = [:]
    /// Decoded frames by when they can go up: (ready time, record index).
    private var ready: [(at: UInt64, index: Int)] = []
    private var shown: Int?
    private var streamHz: Double?
    private var encodeMilliseconds: [Double] = []
    private static let keyFrameInterval: UInt64 = 250_000_000

    public init(configuration: StreamRunConfiguration, encoder: BenchEncoder) {
        self.configuration = configuration
        self.encoder = encoder
        session = BenchSession(scenario: configuration.scenario, seed: configuration.seed)
        var colour = VideoStreamSender.Configuration(streamID: PCVRProfile.streamID)
        colour.rateControl.start = UInt64(configuration.startMbps) * 125_000
        colour.rateControl.frameRate = configuration.refresh.hz(at: 0)
        sender = VideoStreamSender(configuration: colour)
        var depth = VideoStreamSender.Configuration(streamID: PCVRProfile.depthStreamID)
        depth.rateControl.start = UInt64(configuration.depthReserveMbps) * 2 * 125_000
        depth.rateControl.frameRate = configuration.refresh.hz(at: 0)
        depthSender = VideoStreamSender(configuration: depth)
    }

    private func seconds(_ time: UInt64) -> Double { Double(Int64(bitPattern: time &- start)) / 1e9 }

    public func run() throws -> StreamRunResult {
        guard session.connect() else { throw BenchError("the bench session never came up: \(String(describing: session.clientFailure))") }
        guard let index = session.hostIndex else { throw BenchError("no host session") }
        _ = session.host.withSession(index) { $0.setPathCeiling(DatagramLayout.maxProbedUDPPayload, now: session.now) }
        start = session.now
        nextCapture = start
        nextTick = start
        let end = start + UInt64(configuration.seconds * 1e9)
        var ceilingSet = false
        while session.now < end {
            session.step()
            let udpPayload = session.host.sessions[index]?.session.udpPayload ?? 1200
            if !ceilingSet {
                sender.setEncoderCeiling(configuration.maxMbps * 1_000_000, udpPayload: udpPayload)
                depthSender.setEncoderCeiling(configuration.depthReserveMbps * 2 * 1_000_000, udpPayload: udpPayload)
                ceilingSet = true
            }
            try hostTick(index: index, udpPayload: udpPayload)
            clientTick()
            displayTick()
            var wakes = [end, nextCapture, nextTick]
            if let next = session.nextWake() { wakes.append(next) }
            if let next = encoding.first?.at { wakes.append(next) }
            if let next = sender.nextWakeTime(now: session.now) { wakes.append(next) }
            if let next = depthSender.nextWakeTime(now: session.now) { wakes.append(next) }
            if let next = receiver.nextWakeTime(now: session.now) { wakes.append(next) }
            if let next = depthReceiver.nextWakeTime(now: session.now) { wakes.append(next) }
            session.advance(to: max(wakes.min()!, session.now + 20_000))
        }
        if let link = session.downlink {
            result.datagramsLost = link.lost + link.queueDrops + link.oversizeDrops
            result.datagramsStalled = link.stalled
            result.longestHold = Double(link.longestHold) / 1e9
        }
        result.shardsSent = sender.statistics.shardsSent
        result.shardsResent = sender.statistics.shardsResent
        return result
    }

    private func requestKey(now: UInt64) {
        if let last = lastKeyRequest, now - last < Self.keyFrameInterval { return }
        lastKeyRequest = now
        wantsKey = true
        result.keyRequests += 1
    }

    private func hostTick(index: UInt32, udpPayload: Int) throws {
        let now = session.now
        let rtt = session.host.sessions[index]?.session.rtt.smoothed ?? 2_000_000
        for event in session.hostEvents {
            switch event {
            case .feedback(_, let results):
                sender.onFeedback(results, now: now, rtt: rtt)
                depthSender.onFeedback(results, now: now, rtt: rtt)
            case .nack(let nack):
                sender.handle(nack)
                depthSender.handle(nack)
            case .message(.control, let message) where message.type == .recoveryRequest:
                guard let request = try? RecoveryRequest(decoding: message.body) else { continue }
                if request.streamID == PCVRProfile.depthStreamID {
                    depthSender.recoveryRequested()
                } else {
                    sender.recoveryRequested()
                    requestKey(now: now)
                }
            default:
                break
            }
        }
        session.hostEvents.removeAll()

        // Capture: one frame per stream interval, gated like the host's capture.
        while now >= nextCapture {
            let time = seconds(nextCapture)
            let display = configuration.refresh.hz(at: time)
            var hz = display
            if configuration.halvesForEncoder {
                let p95 = encodeMilliseconds.count >= 10 ? Stats.percentile(encodeMilliseconds, 0.95) : nil
                hz = StreamRate.choose(display: display, encodeMilliseconds: p95, current: streamHz)
            }
            streamHz = hz
            let captured = nextCapture
            nextCapture += UInt64(1e9 / hz)
            guard sender.canAcceptFrame, encoding.isEmpty else {
                result.held += 1
                continue
            }
            let depthShare = configuration.depthReserveMbps * 1_000_000
            var colour = max(sender.encoderBitrate(udpPayload: udpPayload) - depthShare, 1_000_000)
            if configuration.minMbps > 0, sender.controller.smoothedLoss < 0.02 {
                colour = max(colour, configuration.minMbps * 1_000_000)
            }
            let target = min(colour, configuration.maxMbps * 1_000_000)
            result.bitrates.append((time, target))
            let forceKey = wantsKey || sender.awaitingKeyFrame
            if forceKey { wantsKey = false }
            let request = FrameRequest(index: result.frames.count, time: time, hz: hz, bitrate: target, forceKey: forceKey)
            let encoded = try encoder.encode(request)
            encodeMilliseconds.append(encoded.encodeSeconds * 1000)
            if encodeMilliseconds.count > 120 { encodeMilliseconds.removeFirst(encodeMilliseconds.count - 120) }
            result.frames.append(FrameRecord(index: request.index, time: time, hz: hz, bitrate: target, size: encoded.size,
                                             isKey: encoded.isKey, qp: encoded.qp, encodeSeconds: encoded.encodeSeconds))
            encoding.append((captured + UInt64(max(encoded.encodeSeconds, 0) * 1e9), request.index))
        }

        // Encodes that have finished go to the senders.
        while let first = encoding.first, first.at <= now {
            encoding.removeFirst()
            let record = result.frames[first.index]
            let unit = [UInt8](repeating: 0x5A, count: max(record.size, 16))
            let captureTime = start + UInt64(record.time * 1e9)
            switch try sender.submit(accessUnit: unit, isKeyFrame: record.isKey, captureTime: captureTime,
                                     udpPayload: udpPayload, now: now) {
            case .queued(let number):
                result.frames[first.index].frameNumber = number
                byNumber[number] = first.index
                let depthBytes = Int(configuration.depthLoadMbps * 125_000 / record.hz)
                if depthBytes > 0 {
                    let depthUnit = [UInt8](repeating: 0x33, count: max(depthBytes, 16))
                    _ = try depthSender.submit(accessUnit: depthUnit, isKeyFrame: depthSender.awaitingKeyFrame,
                                               captureTime: captureTime, frameNumber: number, udpPayload: udpPayload, now: now)
                }
            case .awaitingKeyFrame, .queueFull:
                requestKey(now: now)
            }
        }

        func drain(_ sender: inout VideoStreamSender) {
            while let output = sender.next(now: now) {
                let datagram: [UInt8]? = session.host.withSession(index) { session in
                    switch output {
                    case .shard(let header, let data): try? session.sealVideo(header, data: data, now: now)
                    case .padding(let size, let cluster): try? session.sealPadding(size: size, probeCluster: cluster, now: now)
                    }
                } ?? nil
                if let datagram { session.network.send(datagram, from: .host, to: .client, now: now) }
            }
        }
        drain(&depthSender)
        drain(&sender)
    }

    private func clientTick() {
        guard session.client != nil else { return }
        let now = session.now
        var outputs: [VideoStreamReceiver.Output] = []
        var depthOutputs: [VideoStreamReceiver.Output] = []
        for event in session.clientEvents {
            guard case .video(let header, let data) = event else { continue }
            if header.streamID == PCVRProfile.depthStreamID {
                depthOutputs += depthReceiver.receive(header, data: data, now: now)
            } else {
                outputs += receiver.receive(header, data: data, now: now)
            }
        }
        session.clientEvents.removeAll()
        let rtt = session.client!.rtt.smoothed
        outputs += receiver.poll(now: now, rtt: rtt)
        depthOutputs += depthReceiver.poll(now: now, rtt: rtt)
        for output in outputs + depthOutputs {
            switch output {
            case .frame(let frame):
                guard frame.streamID == PCVRProfile.streamID, let index = byNumber[frame.frameNumber] else { continue }
                result.frames[index].completed = seconds(frame.completedAt)
                result.frames[index].decodable = frame.referenceChainIntact || frame.flags.contains(.key)
                result.frames[index].recoveredShards = frame.recoveredShards
                if result.frames[index].decodable {
                    ready.append((frame.completedAt + UInt64(configuration.decodeSeconds * 1e9), index))
                }
            case .nack(let nack):
                result.nacks += 1
                session.client!.send(nack)
            case .recovery(let request):
                result.recoveryRequests += 1
                try? session.client!.send(.recoveryRequest, body: request.encoded(), on: .control)
            }
        }
    }

    private func displayTick() {
        let now = session.now
        while now >= nextTick {
            let time = seconds(nextTick)
            let hz = configuration.refresh.hz(at: time)
            // The newest frame decoded by this refresh goes up.
            var newest = shown
            ready.removeAll { entry in
                guard entry.at <= nextTick else { return false }
                if newest == nil || result.frames[entry.index].time > result.frames[newest!].time { newest = entry.index }
                return true
            }
            shown = newest
            if let shown {
                result.frames[shown].shownTicks += 1
                result.ticks.append(TickRecord(time: time, hz: hz, frame: shown, age: time - result.frames[shown].time))
            } else {
                result.ticks.append(TickRecord(time: time, hz: hz, frame: nil, age: nil))
            }
            nextTick += UInt64(1e9 / hz)
        }
    }
}

public struct BenchError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
