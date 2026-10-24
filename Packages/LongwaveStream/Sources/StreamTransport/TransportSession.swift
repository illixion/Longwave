import StreamCrypto
import StreamWire

/// What a session hands up from received datagrams.
public enum SessionEvent: Sendable, Equatable {
    /// One whole message from a reliable channel, in order.
    case message(ReliableChannelID, Message)
    case video(VideoShardHeader, ArraySlice<UInt8>)
    case audio(AudioShardHeader, ArraySlice<UInt8>)
    case state(StateSnapshot)
    case nack(ShardNack)
    /// The peer's receive report, resolved against what this side sent.
    case feedback(Feedback, [SentPacketLog.Result])
}

/// Why a session ended.
public enum SessionClosure: Error, Sendable, Equatable {
    /// Nothing authenticated arrived for `idleTimeout`.
    case timedOut
    /// The peer's records reached their cipher's integrity limit.
    case integrityLimit
    /// A reliable channel's byte stream didn't parse: the peer has a bug.
    case malformedStream(ReliableChannelID, WireError)
    /// The send side ran out of packet numbers.
    case packetNumbersExhausted
}

/// Counters for the stats overlay and tests.
public struct SessionStatistics: Sendable, Equatable {
    public var datagramsSent = 0
    public var datagramsReceived = 0
    public var bytesSent = 0
    /// Failed authentication, replay or a bad connection ID.
    public var datagramsRejected = 0
    /// Authenticated but malformed (section 4.1: dropped whole).
    public var datagramsMalformed = 0
    public var pingsAnswered = 0
}

/// One v3 session after the handshake, without I/O (sections 3 to 6).
///
/// The owner feeds it received datagrams and the time, sends the datagrams
/// `poll` returns, and calls `poll` again by `nextWakeTime`. Media is sealed
/// one shard per datagram by `sealVideo`/`sealAudio`, which the owner sends
/// through its pacer; everything small (reliable chunks, ACKs, PING/PONG,
/// FEEDBACK, NACK, STATE) coalesces into datagrams of its own (open question
/// 20). Not thread-safe: one owner.
public struct TransportSession: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var udpPayload: Int
        public var pingInterval: UInt64
        public var idleTimeout: UInt64
        /// The media receiver sends FEEDBACK; the media sender doesn't need it.
        public var sendsFeedback: Bool

        public init(udpPayload: Int = DatagramLayout.defaultUDPPayload, pingInterval: UInt64 = 250_000_000,
                    idleTimeout: UInt64 = 10_000_000_000, sendsFeedback: Bool) {
            self.udpPayload = udpPayload
            self.pingInterval = pingInterval
            self.idleTimeout = idleTimeout
            self.sendsFeedback = sendsFeedback
        }
    }

    public let configuration: Configuration
    public private(set) var secure: SecureSession
    public private(set) var rtt = RTTEstimator()
    public private(set) var clock = ClockEstimator()
    public private(set) var statistics = SessionStatistics()
    public private(set) var closure: SessionClosure?

    private var senders: [ReliableSender]
    private var receivers: [ReliableReceiver]
    private var reassemblers: [MessageReassembler]
    private var feedback = FeedbackGenerator()
    private var sentLog = SentPacketLog()
    private var pendingPongs: [(ping: Ping, receivedAt: UInt64)] = []
    private var pendingNacks: [ShardNack] = []
    private var pendingState: [StateKey: StateSnapshot] = [:]
    private var stateOrder: [StateKey] = []
    private var pendingReports: [Feedback] = []
    private var pendingPings = 0
    private var nextPingID: UInt32 = 0
    private var lastPingAt: UInt64?
    private var lastReceiveAt: UInt64

    public init(secure: SecureSession, configuration: Configuration, now: UInt64) {
        self.secure = secure
        self.configuration = configuration
        senders = ReliableChannelID.allCases.map { ReliableSender(channel: $0) }
        receivers = ReliableChannelID.allCases.map { ReliableReceiver(channel: $0) }
        reassemblers = ReliableChannelID.allCases.map { _ in MessageReassembler() }
        lastReceiveAt = now
    }

    /// Seeds the RTT with the handshake's round trip.
    public mutating func seedRoundTrip(_ sample: UInt64) {
        if rtt.sampleCount == 0 { rtt.add(sample: sample) }
    }

    private var bodyCapacity: Int { DatagramLayout.sealedBodyCapacity(udpPayload: configuration.udpPayload) }

    // MARK: Sending

    /// Queues a reliable message.
    public mutating func send(_ type: MessageType, body: some Collection<UInt8>, on channel: ReliableChannelID) throws(WireError) {
        try senders[Int(channel.rawValue)].enqueue(type, body: body)
    }

    /// Queues a STATE snapshot; a newer one for the same key replaces it.
    public mutating func send(_ snapshot: StateSnapshot) {
        if pendingState[snapshot.key] == nil { stateOrder.append(snapshot.key) }
        if let current = pendingState[snapshot.key], !snapshot.supersedes(current) { return }
        pendingState[snapshot.key] = snapshot
    }

    public mutating func send(_ nack: ShardNack) {
        pendingNacks.append(nack)
    }

    /// One video shard, sealed alone in a datagram.
    public mutating func sealVideo(_ header: VideoShardHeader, data: some Collection<UInt8>,
                                   now: UInt64) throws -> [UInt8] {
        var writer = WireWriter(reservingCapacity: configuration.udpPayload)
        try writer.appendVideoShard(header, data: data)
        return try seal(writer.bytes, isMedia: true, now: now)
    }

    public mutating func sealAudio(_ header: AudioShardHeader, packet: some Collection<UInt8>,
                                   now: UInt64) throws -> [UInt8] {
        var writer = WireWriter(reservingCapacity: configuration.udpPayload)
        try writer.appendAudioShard(header, packet: packet)
        return try seal(writer.bytes, isMedia: true, now: now)
    }

    private mutating func seal(_ body: [UInt8], isMedia: Bool, now: UInt64) throws(StreamCryptoError) -> [UInt8] {
        guard body.count <= bodyCapacity else { throw .malformed("datagram larger than the UDP payload") }
        do {
            let (number, datagram) = try secure.sender.seal(body, now: now)
            sentLog.record(packetNumber: number, sendTime: now, size: datagram.count, isMedia: isMedia)
            statistics.datagramsSent += 1
            statistics.bytesSent += datagram.count
            return datagram
        } catch {
            if error == .packetNumbersExhausted { closure = .packetNumbersExhausted }
            throw error
        }
    }

    /// Everything small that is due, as sealed datagrams. Pending ACKs ride
    /// along with anything else that goes, even before their deadline.
    public mutating func poll(now: UInt64) -> [[UInt8]] {
        guard closure == nil else { return [] }
        if now >= lastReceiveAt, now - lastReceiveAt >= configuration.idleTimeout {
            closure = .timedOut
            return []
        }
        if lastPingAt.map({ now >= $0 && now - $0 >= configuration.pingInterval }) ?? true {
            lastPingAt = now
            pendingPings += 1
        }
        var datagrams: [[UInt8]] = []
        while let body = nextBody(now: now) {
            guard let datagram = try? seal(body, isMedia: false, now: now) else { break }
            datagrams.append(datagram)
        }
        return datagrams
    }

    /// Whether anything other than piggybacked ACKs is due now.
    private func hasDueContent(now: UInt64) -> Bool {
        if !pendingPongs.isEmpty || !pendingNacks.isEmpty || !pendingState.isEmpty || pendingPings > 0 { return true }
        if configuration.sendsFeedback, let due = feedback.nextReportTime, due <= now { return true }
        if receivers.contains(where: { $0.ackDeadline.map { $0 <= now } ?? false }) { return true }
        return senders.contains { $0.hasSendable(now: now, rtt: rtt) }
    }

    private mutating func nextBody(now: UInt64) -> [UInt8]? {
        guard hasDueContent(now: now) else { return nil }
        let capacity = bodyCapacity
        var writer = WireWriter(reservingCapacity: capacity)
        func room() -> Int { capacity - writer.count }
        func fits(_ bodySize: Int) -> Bool { 1 + Varint.encodedLength(bodySize) + bodySize <= room() }

        while let pong = pendingPongs.first {
            let body = (try? Pong(id: pong.ping.id, pingSendTime: pong.ping.sendTime,
                                  receiveTime: pong.receivedAt, sendTime: max(now, pong.receivedAt)).encoded()) ?? []
            guard fits(body.count) else { break }
            try? writer.appendFrame(.pong, body: body)
            pendingPongs.removeFirst()
        }
        // An ACK frame is at most 2 + 13 + 32 × 6 bytes. Making one clears what
        // it owes, so only make it where it fits.
        for index in receivers.indices where receivers[index].ackDeadline != nil && room() >= 210 {
            if let ack = receivers[index].makeAck(now: now), let body = try? ack.encoded() {
                try? writer.appendFrame(.ack, body: body)
            }
        }
        while let nack = pendingNacks.first, let body = try? nack.encoded(), fits(body.count) {
            try? writer.appendFrame(.nack, body: body)
            pendingNacks.removeFirst()
        }
        if configuration.sendsFeedback, let due = feedback.nextReportTime, due <= now, room() > 200 {
            for report in feedback.makeReports(now: now) {
                // A report that no longer fits waits for the next datagram.
                if let body = try? report.encoded(), fits(body.count) {
                    try? writer.appendFrame(.feedback, body: body)
                } else {
                    pendingReports.append(report)
                }
            }
        }
        while let report = pendingReports.first, let body = try? report.encoded(), fits(body.count) {
            try? writer.appendFrame(.feedback, body: body)
            pendingReports.removeFirst()
        }
        while let key = stateOrder.first, let snapshot = pendingState[key] {
            guard let body = try? snapshot.encoded(), fits(body.count) else { break }
            try? writer.appendFrame(.state, body: body)
            stateOrder.removeFirst()
            pendingState[key] = nil
        }
        if pendingPings > 0 {
            let body = (try? Ping(id: nextPingID, sendTime: now).encoded()) ?? []
            if fits(body.count) {
                try? writer.appendFrame(.ping, body: body)
                nextPingID &+= 1
                pendingPings = 0
            }
        }
        // Reliable data last, control before input before bulk.
        for index in senders.indices {
            while room() > StreamChunk.headerSize + 4 {
                let maxData = room() - StreamChunk.headerSize - 3
                guard let chunk = senders[index].nextChunk(maxData: maxData, now: now, rtt: rtt),
                      let body = try? chunk.encoded() else { break }
                try? writer.appendFrame(.control, body: body)
            }
        }
        return writer.count > 0 ? writer.bytes : nil
    }

    /// When `poll` next has something to do.
    public func nextWakeTime(now: UInt64) -> UInt64? {
        guard closure == nil else { return nil }
        var times: [UInt64] = [lastReceiveAt + configuration.idleTimeout]
        times.append((lastPingAt ?? now) + configuration.pingInterval)
        if !pendingPongs.isEmpty || !pendingNacks.isEmpty || !pendingState.isEmpty || !pendingReports.isEmpty {
            times.append(now)
        }
        if configuration.sendsFeedback, let due = feedback.nextReportTime { times.append(due) }
        times += receivers.compactMap(\.ackDeadline)
        for sender in senders {
            if sender.hasSendable(now: now, rtt: rtt) { times.append(now) }
            if let timeout = sender.nextTimeout(rtt: rtt) { times.append(timeout) }
        }
        return times.min()
    }

    /// Nothing reliable left to deliver in either direction.
    public var reliableChannelsIdle: Bool { senders.allSatisfy(\.isIdle) }

    // MARK: Receiving

    /// Opens one transport datagram. Rejected datagrams are counted and
    /// produce nothing; a closure is thrown.
    public mutating func receive(_ datagram: [UInt8], now: UInt64, ecn: ECNMark = .notECT) throws(SessionClosure) -> [SessionEvent] {
        if let closure { throw closure }
        let opened: (packetNumber: UInt64, body: [UInt8])
        do {
            opened = try secure.receiver.open(datagram)
        } catch {
            if error == .integrityLimitReached {
                closure = .integrityLimit
                throw .integrityLimit
            }
            statistics.datagramsRejected += 1
            return []
        }
        statistics.datagramsReceived += 1
        lastReceiveAt = max(lastReceiveAt, now)
        if configuration.sendsFeedback { feedback.record(packetNumber: opened.packetNumber, arrival: now, ecn: ecn) }

        // Parse the whole datagram before acting on any of it: a malformed one
        // is dropped whole (section 4.1).
        var frames: [Frame] = []
        do {
            var reader = FrameReader(opened.body)
            while let frame = try reader.next() { frames.append(frame) }
        } catch {
            statistics.datagramsMalformed += 1
            return []
        }
        var decoded: [DecodedFrame] = []
        do {
            for frame in frames {
                switch frame.type {
                case .control: decoded.append(.chunk(try StreamChunk(decoding: frame.body)))
                case .ack: decoded.append(.ack(try ChannelAck(decoding: frame.body)))
                case .video:
                    let (header, data) = try VideoShardHeader.split(frame.body)
                    decoded.append(.video(header, data))
                case .audio:
                    let (header, packet) = try AudioShardHeader.split(frame.body)
                    decoded.append(.audio(header, packet))
                case .state:
                    // nil is a kind this build doesn't know: skipped (section 4.1).
                    if let snapshot = try StateSnapshot(frameBody: frame.body) { decoded.append(.state(snapshot)) }
                case .feedback: decoded.append(.feedback(try Feedback(decoding: frame.body)))
                case .ping: decoded.append(.ping(try Ping(decoding: frame.body)))
                case .pong: decoded.append(.pong(try Pong(decoding: frame.body)))
                case .nack: decoded.append(.nack(try ShardNack(decoding: frame.body)))
                case .padding: break
                }
            }
        } catch {
            statistics.datagramsMalformed += 1
            return []
        }

        var events: [SessionEvent] = []
        for frame in decoded {
            switch frame {
            case .chunk(let chunk):
                let index = Int(chunk.channel.rawValue)
                let bytes = receivers[index].receive(chunk, now: now)
                guard !bytes.isEmpty else { continue }
                reassemblers[index].append(bytes)
                do {
                    while let message = try reassemblers[index].next() { events.append(.message(chunk.channel, message)) }
                } catch {
                    closure = .malformedStream(chunk.channel, error)
                    throw closure!
                }
            case .ack(let ack):
                if let sample = senders[Int(ack.channel.rawValue)].handle(ack, now: now, rtt: rtt) {
                    rtt.add(sample: sample, ackDelay: UInt64(ack.ackDelay) * 1_000)
                }
            case .video(let header, let data):
                events.append(.video(header, data))
            case .audio(let header, let packet):
                events.append(.audio(header, packet))
            case .state(let snapshot):
                events.append(.state(snapshot))
            case .feedback(let report):
                events.append(.feedback(report, sentLog.apply(report)))
            case .ping(let ping):
                pendingPongs.append((ping, now))
                statistics.pingsAnswered += 1
            case .pong(let pong):
                let sample = ClockSample(pong: pong, receivedAt: now)
                clock.add(sample)
                if let roundTrip = sample.roundTrip { rtt.add(sample: roundTrip) }
            case .nack(let nack):
                events.append(.nack(nack))
            }
        }
        return events
    }

    private enum DecodedFrame {
        case chunk(StreamChunk)
        case ack(ChannelAck)
        case video(VideoShardHeader, ArraySlice<UInt8>)
        case audio(AudioShardHeader, ArraySlice<UInt8>)
        case state(StateSnapshot)
        case feedback(Feedback)
        case ping(Ping)
        case pong(Pong)
        case nack(ShardNack)
    }
}
