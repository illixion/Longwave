import StreamFEC
import StreamTransport
import StreamWire

/// One viewer's copy of one video stream (sections 4.2, 6.2 to 6.4), without
/// I/O: encoded frames in, shards out through the pacer, at whatever the rate
/// controller allows.
///
/// - **Numbering:** frames are numbered per viewer, from the first key frame
///   it is sent. A frame this viewer never gets has no number, so its frame
///   numbers have no gaps it would read as loss.
/// - **Holding the encoder back:** `canAcceptFrame` is false while two frames
///   are still queued. The owner gates the encoder on it (v2's desktop gate),
///   so a slow link holds frames back rather than dropping them.
/// - **Stale parity:** a new frame drops the unsent parity of older ones; their
///   data still goes, since later frames predict from them (section 6.4).
/// - **Overflow:** a frame that arrives with the queue already full is skipped,
///   and so is everything after it until the next key frame.
/// - **NACK:** a resend goes to the front of the queue, data shards first,
///   then parity if those don't cover what the receiver needs.
/// - **Probing:** the controller's probe bursts go out as padding beside the
///   pacer, uncharged, as in the rate simulations.
///
/// Not thread-safe: one owner, who seals each shard with the viewer's
/// `TransportSession` and sends it.
public struct VideoStreamSender: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var streamID: UInt32
        /// Frames queued before `canAcceptFrame` turns false.
        public var maxQueuedFrames: Int = 2
        /// How long a sent frame is kept to answer NACKs.
        public var history: UInt64 = 300_000_000
        public var minimumParity: Int = 2
        public var rateControl: GCCRateController.Configuration = .init()

        public init(streamID: UInt32) {
            self.streamID = streamID
        }
    }

    public enum Output: Sendable, Equatable {
        /// Seal with `sealVideo` and send.
        case shard(VideoShardHeader, ArraySlice<UInt8>)
        /// Seal with `sealPadding` and send: a rate probe.
        case padding(size: Int, cluster: UInt32)
    }

    public enum Submission: Sendable, Equatable {
        case queued(frameNumber: UInt32)
        /// Not a key frame, and this viewer is waiting for one.
        case awaitingKeyFrame
        /// The queue was full; the viewer now waits for a key frame.
        case queueFull
    }

    public struct Statistics: Sendable, Equatable {
        public var framesQueued = 0
        public var framesSkipped = 0
        public var shardsSent = 0
        public var shardsResent = 0
        public var parityDropped = 0
        public var probes = 0
    }

    private struct QueuedShard: Sendable, Equatable {
        var frameNumber: UInt32
        var index: Int
        var isParity: Bool
        var isResend: Bool
    }

    private struct SentFrame: Sendable {
        var frame: ShardedVideoFrame
        var submittedAt: UInt64
    }

    public let configuration: Configuration
    public private(set) var controller: GCCRateController
    public private(set) var statistics = Statistics()
    /// The viewer can't decode until a key frame: the owner asks the encoder.
    public private(set) var awaitingKeyFrame = true

    private var pacer: Pacer
    private var queue: [QueuedShard] = []
    private var queueStart = 0
    private var frames: [UInt32: SentFrame] = [:]
    private var nextFrameNumber: UInt32 = 0
    /// The frame number of the last frame queued, which the next predicts from.
    private var lastQueued: UInt32?
    private var probe: (cluster: ProbeCluster, next: UInt64, remaining: Int, interval: UInt64)?

    public init(configuration: Configuration) {
        self.configuration = configuration
        controller = GCCRateController(configuration: configuration.rateControl)
        pacer = Pacer(rate: controller.budget.pacingRate)
    }

    // MARK: Encoder side

    /// The most the encoder will ever produce (bits/s; nil for no limit).
    /// The budget stops there, with room for the most parity and the shard
    /// headers, so probes measure no further than the stream could use.
    public mutating func setEncoderCeiling(_ bitsPerSecond: Int?, udpPayload: Int) {
        guard let bitsPerSecond, bitsPerSecond > 0 else {
            controller.setCeiling(nil)
            return
        }
        let shard = Double(DatagramLayout.videoShardDataCapacity(udpPayload: udpPayload))
        let wirePerByte = (1 + configuration.rateControl.maximumFEC) * Double(udpPayload) / shard
        // The pacer follows at the next feedback report, a few ms away.
        controller.setCeiling(UInt64(Double(bitsPerSecond) / 8 * wirePerByte))
    }

    /// The bitrate the encoder should run at for this viewer, bits per second.
    public func encoderBitrate(udpPayload: Int) -> Int {
        Int(clamping: controller.budget.mediaRate(udpPayload: udpPayload) * 8)
    }

    /// Frames waiting in the queue, counting a partly sent one.
    public var queuedFrames: Int {
        var count = 0
        var last: UInt32?
        for shard in queue[queueStart...] where shard.frameNumber != last {
            count += 1
            last = shard.frameNumber
        }
        return count
    }

    public var canAcceptFrame: Bool { queuedFrames < configuration.maxQueuedFrames }

    /// The next frame number this viewer's stream will use, for a format
    /// description sent ahead of a key frame (`FormatDescription.firstFrameNumber`).
    public var upcomingFrameNumber: UInt32 { nextFrameNumber }

    /// Queues one encoded frame (an access unit as the decoder takes it).
    /// `udpPayload` is the session's confirmed datagram size.
    public mutating func submit(accessUnit: some Collection<UInt8>, isKeyFrame: Bool, captureTime: UInt64,
                                udpPayload: Int, now: UInt64) throws -> Submission {
        if awaitingKeyFrame, !isKeyFrame {
            statistics.framesSkipped += 1
            return .awaitingKeyFrame
        }
        if queuedFrames > configuration.maxQueuedFrames, !isKeyFrame {
            // The owner didn't hold the encoder back; a skipped frame breaks
            // the chain, so this viewer waits for a key frame.
            awaitingKeyFrame = true
            statistics.framesSkipped += 1
            return .queueFull
        }
        dropQueuedParity()

        let number = nextFrameNumber
        let info = VideoFrameInfo(
            streamID: configuration.streamID, frameNumber: number, captureTime: captureTime,
            flags: isKeyFrame ? .key : [],
            referenceDistance: isKeyFrame ? 0 : UInt16(truncatingIfNeeded: number &- (lastQueued ?? number &- 1)))
        let payload = try FramePayload.encode(sideData: SideData(), accessUnit: accessUnit)
        let policy = FECPolicy(ratioPermille: Int((controller.budget.fecRatio * 1_000).rounded()),
                               minimumParity: configuration.minimumParity)
        let frame = try ShardedVideoFrame(payload: payload, info: info,
                                          shardSize: DatagramLayout.videoShardDataCapacity(udpPayload: udpPayload),
                                          policy: policy)
        frames[number] = SentFrame(frame: frame, submittedAt: now)
        for index in 0..<frame.count {
            queue.append(QueuedShard(frameNumber: number, index: index,
                                     isParity: frame.shard(index).header.isParity, isResend: false))
        }
        nextFrameNumber &+= 1
        lastQueued = number
        awaitingKeyFrame = false
        statistics.framesQueued += 1
        forgetOldFrames(now: now)
        return .queued(frameNumber: number)
    }

    /// The viewer asked for recovery (it lost a frame or its chain broke): it
    /// waits for a key frame. VideoToolbox can't invalidate a reference, so
    /// this is the IDR path of section 6.3.
    public mutating func recoveryRequested() {
        awaitingKeyFrame = true
    }

    // MARK: Network side

    public mutating func onFeedback(_ results: [SentPacketLog.Result], now: UInt64, rtt: UInt64) {
        controller.onFeedback(results, now: now, rtt: rtt)
        pacer.setRate(controller.budget.pacingRate, now: now)
    }

    /// Requeues what a NACK names, ahead of everything else.
    public mutating func handle(_ nack: ShardNack) {
        guard nack.streamID == configuration.streamID, let sent = frames[nack.frameNumber] else { return }
        let frame = sent.frame
        let all = (0..<frame.count).map { ($0, frame.shard($0).header) }
        var picks: [(Int, VideoShardHeader)]
        switch nack.scope {
        case .wholeFrame:
            picks = all.filter { !$0.1.isParity }
        case .wholeBlock(let block):
            picks = all.filter { $0.1.block == block && !$0.1.isParity }
        case .shards(let block, let needed, let indices):
            let inBlock = all.filter { $0.1.block == block }
            picks = inBlock.filter { indices.contains($0.1.shardIndex) } + inBlock.filter(\.1.isParity)
            picks = Array(picks.prefix(Int(needed)))
        }
        let queued = Set(queue[queueStart...].filter { $0.frameNumber == nack.frameNumber }.map(\.index))
        let resend = picks.filter { !queued.contains($0.0) }.map {
            QueuedShard(frameNumber: nack.frameNumber, index: $0.0, isParity: $0.1.isParity, isResend: true)
        }
        guard !resend.isEmpty else { return }
        compact()
        queue.insert(contentsOf: resend, at: 0)
        statistics.shardsResent += resend.count
    }

    /// The next thing to send, if anything may leave now.
    public mutating func next(now: UInt64) -> Output? {
        if probe == nil, let cluster = controller.nextProbe(now: now) {
            let size = DatagramLayout.defaultUDPPayload
            probe = (cluster, now, max(cluster.bytes / size, 5), UInt64(size) * 1_000_000_000 / max(cluster.rate, 1))
            statistics.probes += 1
        }
        if var current = probe, current.next <= now {
            current.remaining -= 1
            current.next += current.interval
            probe = current.remaining > 0 ? current : nil
            return .padding(size: DatagramLayout.defaultUDPPayload, cluster: current.cluster.id)
        }
        while queueStart < queue.count {
            let item = queue[queueStart]
            guard let sent = frames[item.frameNumber] else {
                queueStart += 1
                continue
            }
            let shard = sent.frame.shard(item.index)
            let size = Self.wireSize(shard.data.count)
            guard pacer.delay(for: size, now: now) == 0 else { return nil }
            pacer.consume(size, now: now)
            queueStart += 1
            if queueStart > 256 { compact() }
            statistics.shardsSent += 1
            return .shard(shard.header, shard.data)
        }
        return nil
    }

    /// The owner couldn't send a probe datagram (the socket refused it).
    public mutating func abandonProbe() {
        probe = nil
        controller.abandonProbe()
    }

    /// When `next` may have something: the pacer's delay for the head of the
    /// queue, or the next probe datagram.
    public mutating func nextWakeTime(now: UInt64) -> UInt64? {
        var times: [UInt64] = []
        if let probe { times.append(probe.next) }
        if queueStart < queue.count, let sent = frames[queue[queueStart].frameNumber] {
            let size = Self.wireSize(sent.frame.shard(queue[queueStart].index).data.count)
            times.append(now + pacer.delay(for: size, now: now))
        }
        return times.min()
    }

    /// A shard's datagram size: its data plus the shard header and the sealed
    /// datagram's own overhead.
    private static func wireSize(_ data: Int) -> Int {
        data + DatagramLayout.defaultUDPPayload - DatagramLayout.videoShardDataCapacity(udpPayload: DatagramLayout.defaultUDPPayload)
    }

    // MARK: Queue housekeeping

    private mutating func compact() {
        queue.removeFirst(queueStart)
        queueStart = 0
    }

    private mutating func dropQueuedParity() {
        let before = queue.count - queueStart
        compact()
        queue.removeAll { $0.isParity && !$0.isResend }
        statistics.parityDropped += before - queue.count
    }

    private mutating func forgetOldFrames(now: UInt64) {
        let queued = Set(queue[queueStart...].map(\.frameNumber))
        for (number, sent) in frames where now >= sent.submittedAt + configuration.history && !queued.contains(number) {
            frames[number] = nil
        }
    }
}
