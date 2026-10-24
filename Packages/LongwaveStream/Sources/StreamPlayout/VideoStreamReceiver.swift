import StreamWire

/// The client's side of one video stream (sections 4.2 and 6.3), without
/// I/O: shards in; decodable frames, NACKs and recovery requests out.
///
/// - **Decodable only:** a frame goes to the decoder only if it is a key frame
///   or its reference chain is intact. After a loss, frames are held back until
///   the next key frame, so the picture freezes instead of smearing.
/// - **Recovery:** a loss, or a predicted frame whose chain broke, asks the host
///   for recovery, at most once per `recoveryInterval` while it lasts.
/// - **NACK:** what the assembler lists as missing is asked for again, each
///   frame or block at most once per `nackInterval` (or the RTT, if longer),
///   when the session negotiated `nack`.
public struct VideoStreamReceiver: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var assembler = VideoFrameAssembler.Configuration()
        public var nacks = true
        public var nackInterval: UInt64 = 8_000_000
        public var recoveryInterval: UInt64 = 250_000_000

        public init() {}
    }

    public enum Output: Sendable {
        case frame(AssembledVideoFrame)
        case nack(ShardNack)
        case recovery(RecoveryRequest)
    }

    public struct Statistics: Sendable, Equatable {
        public var framesDelivered = 0
        /// Delivered by the assembler but not decodable (a broken chain).
        public var framesHeldBack = 0
        public var framesLost = 0
        public var nacksSent = 0
        public var recoveryRequests = 0
    }

    public let streamID: UInt32
    public let configuration: Configuration
    public private(set) var assembler: VideoFrameAssembler
    public private(set) var statistics = Statistics()
    /// Nothing decodable until a key frame arrives.
    public private(set) var awaitingKeyFrame = true

    private var lastNack: [NackKey: UInt64] = [:]
    private var lastRecoveryRequest: UInt64?
    /// The first frame the decoder can't have.
    private var firstUndecodable: UInt32?

    private struct NackKey: Hashable {
        var frame: UInt32
        var block: Int
    }

    public init(streamID: UInt32, configuration: Configuration = Configuration()) {
        self.streamID = streamID
        self.configuration = configuration
        assembler = VideoFrameAssembler(streamID: streamID, configuration: configuration.assembler)
    }

    public mutating func receive(_ header: VideoShardHeader, data: ArraySlice<UInt8>, now: UInt64) -> [Output] {
        var outputs: [Output] = []
        handle(assembler.receive(header, data: data, now: now), now: now, into: &outputs)
        return outputs
    }

    /// Timeouts, NACKs and repeated recovery requests: call every few ms while
    /// frames are pending (`nextWakeTime`), and after receiving.
    public mutating func poll(now: UInt64, rtt: UInt64) -> [Output] {
        var outputs: [Output] = []
        handle(assembler.poll(now: now), now: now, into: &outputs)
        requestRecoveryIfDue(now: now, into: &outputs)
        if configuration.nacks {
            let interval = max(configuration.nackInterval, rtt)
            for missing in assembler.missingShards(now: now) {
                let scope: ShardNack.Scope
                let key: NackKey
                switch missing.scope {
                case .wholeFrame:
                    scope = .wholeFrame
                    key = NackKey(frame: missing.frameNumber, block: -1)
                case .wholeBlock(let block):
                    scope = .wholeBlock(block)
                    key = NackKey(frame: missing.frameNumber, block: Int(block))
                case .shards(let block, let needed, let indices):
                    scope = .shards(block: block, needed: UInt8(min(needed, 255)), dataIndices: indices)
                    key = NackKey(frame: missing.frameNumber, block: Int(block))
                }
                if let last = lastNack[key], now - last < interval { continue }
                lastNack[key] = now
                statistics.nacksSent += 1
                outputs.append(.nack(ShardNack(streamID: streamID, frameNumber: missing.frameNumber, scope: scope)))
            }
            if lastNack.count > 256, let next = assembler.nextFrame {
                lastNack = lastNack.filter { !SerialNumber.isNewer(next, than: $0.key.frame) }
            }
        }
        return outputs
    }

    /// When `poll` next has work: pending frames are checked every 2 ms, and a
    /// recovery request repeats while no key frame comes.
    public func nextWakeTime(now: UInt64) -> UInt64? {
        var times: [UInt64] = []
        if assembler.pendingFrameCount > 0 { times.append(now + 2_000_000) }
        if awaitingKeyFrame, firstUndecodable != nil, let last = lastRecoveryRequest {
            times.append(last + configuration.recoveryInterval)
        }
        return times.min()
    }

    /// The decoder lost its state (a decoder session ended, a bad frame): hold
    /// everything back until a key frame, and ask for one.
    public mutating func requestKeyFrame(now: UInt64) -> [Output] {
        awaitingKeyFrame = true
        if firstUndecodable == nil { firstUndecodable = assembler.nextFrame ?? 0 }
        var outputs: [Output] = []
        requestRecoveryIfDue(now: now, into: &outputs)
        return outputs
    }

    /// A new format: the stream starts again at its key frame.
    public mutating func reset() {
        assembler.reset()
        awaitingKeyFrame = true
        firstUndecodable = nil
        lastNack.removeAll()
    }

    private mutating func handle(_ events: [VideoAssemblyEvent], now: UInt64, into outputs: inout [Output]) {
        for event in events {
            switch event {
            case .frame(let frame):
                if frame.flags.contains(.key) {
                    awaitingKeyFrame = false
                    firstUndecodable = nil
                } else if awaitingKeyFrame || !frame.referenceChainIntact {
                    awaitingKeyFrame = true
                    statistics.framesHeldBack += 1
                    if firstUndecodable == nil { firstUndecodable = frame.frameNumber }
                    continue
                }
                statistics.framesDelivered += 1
                outputs.append(.frame(frame))
            case .lost(let first, let count, _):
                statistics.framesLost += Int(count)
                awaitingKeyFrame = true
                if firstUndecodable == nil { firstUndecodable = first }
            }
        }
        requestRecoveryIfDue(now: now, into: &outputs)
    }

    private mutating func requestRecoveryIfDue(now: UInt64, into outputs: inout [Output]) {
        guard awaitingKeyFrame, let first = firstUndecodable else { return }
        if let last = lastRecoveryRequest, now - last < configuration.recoveryInterval { return }
        lastRecoveryRequest = now
        statistics.recoveryRequests += 1
        outputs.append(.recovery(RecoveryRequest(streamID: streamID, firstLostFrame: first)))
    }
}
