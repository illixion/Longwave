// Transport frame bodies (sections 4.1, 5 and 6.1): CTRL, ACK, PING, PONG,
// FEEDBACK and NACK. Fixed when StreamTransport was built (2026-10-24).
//
// These are fixed structures, so they decode strictly: reserved values and
// trailing bytes are rejected. New fields arrive as new frame types.

/// The three reliable channels (section 4.1). Separate so a clipboard image
/// can't sit in front of a key-up. Fixed in v3.0; a new one needs a capability.
public enum ReliableChannelID: UInt8, Sendable, CaseIterable, Hashable {
    /// Control messages (0x20-0x3F), host input feedback (0x60-0x6F).
    case control = 0
    /// Input events (0x40-0x5F).
    case input = 1
    /// Large, latency-tolerant payloads: clipboard, artwork.
    case bulk = 2
}

/// CTRL (0x01): a run of one reliable channel's byte stream.
///
/// ```
/// channel u8 | offset u64 | data (the rest of the body, at least one byte)
/// ```
///
/// Each channel is one byte stream from offset 0, carrying messages framed by
/// `MessageFraming`. A resend repeats the same bytes at the same offset.
public struct StreamChunk: WireCodable, Hashable {
    public static let headerSize = 9

    public var channel: ReliableChannelID
    public var offset: UInt64
    public var data: [UInt8]

    public init(channel: ReliableChannelID, offset: UInt64, data: [UInt8]) {
        self.channel = channel
        self.offset = offset
        self.data = data
    }

    /// The offset just past the last byte.
    public var end: UInt64 { offset &+ UInt64(data.count) }

    public func validate() throws(WireError) {
        guard !data.isEmpty else { throw .invalid("streamChunk.data") }
        guard offset <= UInt64.max - UInt64(data.count) else { throw .tooLarge("streamChunk.offset") }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        guard let channel = ReliableChannelID(rawValue: try reader.readUInt8()) else { throw .invalid("streamChunk.channel") }
        self.channel = channel
        offset = try reader.readUInt64()
        data = Array(try reader.readBytes(reader.remaining))
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt8(channel.rawValue)
        writer.writeUInt64(offset)
        writer.writeBytes(data)
    }
}

/// ACK (0x02): what one reliable channel's receiver holds.
///
/// ```
/// channel u8 | ackDelay varint (µs) | cumulative u64 | rangeCount u8 |
///   rangeCount x (gap varint, length varint)
/// ```
///
/// `cumulative` is the next offset the receiver needs: everything below it
/// arrived. Ranges are the bytes held above it, ascending: each starts `gap`
/// bytes after the previous one ends (the first after `cumulative`), and gaps
/// and lengths are at least 1, so ranges never touch and the encoding is
/// unique. `ackDelay` is how long the receiver held the ACK after the newest
/// byte arrived, so the sender can take it out of an RTT sample.
public struct ChannelAck: WireCodable, Hashable {
    public static let maxRanges = 32

    public struct Range: Sendable, Hashable {
        public var start: UInt64
        public var end: UInt64

        public init(start: UInt64, end: UInt64) {
            self.start = start
            self.end = end
        }
    }

    public var channel: ReliableChannelID
    public var ackDelay: Int
    public var cumulative: UInt64
    public var ranges: [Range]

    public init(channel: ReliableChannelID, ackDelay: Int, cumulative: UInt64, ranges: [Range] = []) {
        self.channel = channel
        self.ackDelay = ackDelay
        self.cumulative = cumulative
        self.ranges = ranges
    }

    /// Whether every byte of `start..<end` is acknowledged.
    public func covers(start: UInt64, end: UInt64) -> Bool {
        if end <= cumulative { return true }
        return ranges.contains { $0.start <= max(start, cumulative) && end <= $0.end }
    }

    public func validate() throws(WireError) {
        guard ackDelay >= 0, ackDelay <= Varint.maxValue else { throw .tooLarge("ack.ackDelay") }
        guard ranges.count <= Self.maxRanges else { throw .tooLarge("ack.ranges") }
        var previousEnd = cumulative
        for range in ranges {
            guard range.start > previousEnd, range.end > range.start else { throw .invalid("ack.range") }
            guard range.start - previousEnd <= UInt64(Varint.maxValue),
                  range.end - range.start <= UInt64(Varint.maxValue) else { throw .tooLarge("ack.range") }
            previousEnd = range.end
        }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        guard let channel = ReliableChannelID(rawValue: try reader.readUInt8()) else { throw .invalid("ack.channel") }
        self.channel = channel
        ackDelay = try reader.readVarint()
        cumulative = try reader.readUInt64()
        let count = Int(try reader.readUInt8())
        guard count <= Self.maxRanges else { throw .tooLarge("ack.ranges") }
        var ranges: [Range] = []
        ranges.reserveCapacity(count)
        var previousEnd = cumulative
        for _ in 0..<count {
            let gap = UInt64(try reader.readVarint())
            let length = UInt64(try reader.readVarint())
            guard gap >= 1, length >= 1 else { throw .invalid("ack.range") }
            guard previousEnd <= UInt64.max - gap - length else { throw .tooLarge("ack.range") }
            let start = previousEnd + gap
            ranges.append(Range(start: start, end: start + length))
            previousEnd = start + length
        }
        self.ranges = ranges
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt8(channel.rawValue)
        try writer.writeVarint(ackDelay)
        writer.writeUInt64(cumulative)
        writer.writeUInt8(UInt8(ranges.count))
        var previousEnd = cumulative
        for range in ranges {
            try writer.writeVarint(Int(range.start - previousEnd))
            try writer.writeVarint(Int(range.end - range.start))
            previousEnd = range.end
        }
    }
}

/// PING (0x07): `id u32 | sendTime u64`, the sender's monotonic ns.
///
/// Either side may ping. A PMTU probe is a PING padded with PADDING frames.
public struct Ping: WireCodable, Hashable {
    public static let wireSize = 12

    public var id: UInt32
    public var sendTime: UInt64

    public init(id: UInt32, sendTime: UInt64) {
        self.id = id
        self.sendTime = sendTime
    }

    public init(from reader: inout WireReader) throws(WireError) {
        id = try reader.readUInt32()
        sendTime = try reader.readUInt64()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        writer.writeUInt32(id)
        writer.writeUInt64(sendTime)
    }
}

/// PONG (0x08): the NTP-style answer (section 5).
///
/// ```
/// id u32 | pingSendTime u64 | receiveTime u64 | sendTime u64
/// ```
///
/// `pingSendTime` echoes the PING in the pinger's clock; `receiveTime` and
/// `sendTime` are when this side received the PING and sent the PONG, in its
/// own monotonic ns. With the PONG's arrival time the pinger has all four
/// timestamps.
public struct Pong: WireCodable, Hashable {
    public static let wireSize = 28

    public var id: UInt32
    public var pingSendTime: UInt64
    public var receiveTime: UInt64
    public var sendTime: UInt64

    public init(id: UInt32, pingSendTime: UInt64, receiveTime: UInt64, sendTime: UInt64) {
        self.id = id
        self.pingSendTime = pingSendTime
        self.receiveTime = receiveTime
        self.sendTime = sendTime
    }

    public func validate() throws(WireError) {
        guard sendTime >= receiveTime else { throw .inconsistent("pong.times") }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        id = try reader.readUInt32()
        pingSendTime = try reader.readUInt64()
        receiveTime = try reader.readUInt64()
        sendTime = try reader.readUInt64()
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt32(id)
        writer.writeUInt64(pingSendTime)
        writer.writeUInt64(receiveTime)
        writer.writeUInt64(sendTime)
    }
}

/// The two ECN bits of a received packet (RFC 3168 codepoints).
public enum ECNMark: UInt8, Sendable, CaseIterable, Hashable {
    case notECT = 0
    case ect1 = 1
    case ect0 = 2
    case congestionExperienced = 3
}

/// FEEDBACK (0x06): the receive report for rate control (section 6.1).
///
/// ```
/// reportSequence u16 | basePacketNumber u64 | referenceTime u64 (µs) |
///   runCount varint | runCount x run varint |
///   one arrival delta per received packet, zigzag varint (µs) |
///   streamCount u8 | streamCount x StreamStatus
/// ```
///
/// Runs cover consecutive packet numbers from `basePacketNumber`. Each run is
/// `length << 3 | received << 2 | ecn`; a lost run has ECN 0, and neighbouring
/// runs differ, so the encoding is unique. Arrival times are in the
/// receiver's monotonic µs: each received packet's delta is from the previous
/// received packet in packet-number order (the first from `referenceTime`),
/// signed because Wi-Fi reorders. A delta must fit in ±1,048,575 µs, so a
/// report spanning a longer silence is split.
public struct Feedback: WireCodable, Hashable {
    public static let maxDelta = (Varint.maxValue + 1) / 2 - 1
    /// Packets one report may cover: a 20 ms report at 3 million packets/s.
    /// Lost runs cost no delta bytes, so this bounds what a decoder allocates.
    public static let maxPackets = 1 << 16

    public struct Packet: Sendable, Hashable {
        public var packetNumber: UInt64
        /// Receiver monotonic µs, or nil for a packet not received.
        public var arrival: UInt64?
        public var ecn: ECNMark

        public init(packetNumber: UInt64, arrival: UInt64?, ecn: ECNMark = .notECT) {
            self.packetNumber = packetNumber
            self.arrival = arrival
            self.ecn = ecn
        }
    }

    /// Per-stream frame status (section 6.1): `streamID u32 |
    /// lastDecodableFrame u32 | framesLost u32 | latenessP50, P95, P99 varint`.
    public struct StreamStatus: Sendable, Hashable {
        public var streamID: UInt32
        /// The newest frame number delivered whole.
        public var lastDecodableFrame: UInt32
        /// Frames lost beyond FEC and NACK since the session began, wrapping.
        public var framesLost: UInt32
        /// Playout lateness percentiles (section 5) in µs, at most
        /// `Varint.maxValue` (about 2.1 s); senders saturate.
        public var latenessP50: Int
        public var latenessP95: Int
        public var latenessP99: Int

        public init(streamID: UInt32, lastDecodableFrame: UInt32, framesLost: UInt32,
                    latenessP50: Int, latenessP95: Int, latenessP99: Int) {
            self.streamID = streamID
            self.lastDecodableFrame = lastDecodableFrame
            self.framesLost = framesLost
            self.latenessP50 = latenessP50
            self.latenessP95 = latenessP95
            self.latenessP99 = latenessP99
        }
    }

    public var reportSequence: UInt16
    public var referenceTime: UInt64
    /// Consecutive packet numbers, ascending, at least one.
    public var packets: [Packet]
    public var streams: [StreamStatus]

    public init(reportSequence: UInt16, referenceTime: UInt64, packets: [Packet], streams: [StreamStatus] = []) {
        self.reportSequence = reportSequence
        self.referenceTime = referenceTime
        self.packets = packets
        self.streams = streams
    }

    public func validate() throws(WireError) {
        guard let first = packets.first else { throw .missing("feedback.packets") }
        guard packets.count <= Self.maxPackets else { throw .tooLarge("feedback.packets") }
        guard first.packetNumber <= UInt64.max - UInt64(packets.count - 1) else { throw .tooLarge("feedback.packets") }
        var previousArrival = referenceTime
        for (index, packet) in packets.enumerated() {
            guard packet.packetNumber == first.packetNumber + UInt64(index) else { throw .invalid("feedback.packetNumber") }
            guard let arrival = packet.arrival else {
                guard packet.ecn == .notECT else { throw .invalid("feedback.ecn") }
                continue
            }
            let delta = arrival >= previousArrival ? arrival - previousArrival : previousArrival - arrival
            guard delta <= UInt64(Self.maxDelta) else { throw .tooLarge("feedback.delta") }
            previousArrival = arrival
        }
        guard streams.count <= Int(UInt8.max) else { throw .tooLarge("feedback.streams") }
        for stream in streams {
            for value in [stream.latenessP50, stream.latenessP95, stream.latenessP99] {
                guard value >= 0, value <= Varint.maxValue else { throw .tooLarge("feedback.lateness") }
            }
        }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        reportSequence = try reader.readUInt16()
        let base = try reader.readUInt64()
        referenceTime = try reader.readUInt64()
        let runCount = try reader.readVarint()
        var runs: [(length: Int, received: Bool, ecn: ECNMark)] = []
        var total = 0
        for _ in 0..<runCount {
            let value = try reader.readVarint()
            let length = value >> 3
            let received = value & 0b100 != 0
            let ecn = ECNMark(rawValue: UInt8(value & 0b11))!
            guard length >= 1 else { throw .invalid("feedback.run") }
            guard received || ecn == .notECT else { throw .invalid("feedback.ecn") }
            if let last = runs.last, last.received == received, last.ecn == ecn { throw .invalid("feedback.run") }
            total += length
            guard total <= Self.maxPackets else { throw .tooLarge("feedback.packets") }
            runs.append((length, received, ecn))
        }
        guard total >= 1 else { throw .missing("feedback.packets") }
        guard base <= UInt64.max - UInt64(total - 1) else { throw .tooLarge("feedback.packets") }
        var packets: [Packet] = []
        packets.reserveCapacity(total)
        var arrival = referenceTime
        var number = base
        for run in runs {
            for _ in 0..<run.length {
                if run.received {
                    let zigzag = try reader.readVarint()
                    let magnitude = UInt64(zigzag >> 1)
                    if zigzag & 1 == 0 {
                        guard arrival <= UInt64.max - magnitude else { throw .invalid("feedback.delta") }
                        arrival += magnitude
                    } else {
                        guard arrival >= magnitude + 1 else { throw .invalid("feedback.delta") }
                        arrival -= magnitude + 1
                    }
                    packets.append(Packet(packetNumber: number, arrival: arrival, ecn: run.ecn))
                } else {
                    packets.append(Packet(packetNumber: number, arrival: nil))
                }
                number &+= 1
            }
        }
        self.packets = packets
        let streamCount = Int(try reader.readUInt8())
        var streams: [StreamStatus] = []
        for _ in 0..<streamCount {
            streams.append(StreamStatus(streamID: try reader.readUInt32(), lastDecodableFrame: try reader.readUInt32(),
                                        framesLost: try reader.readUInt32(), latenessP50: try reader.readVarint(),
                                        latenessP95: try reader.readVarint(), latenessP99: try reader.readVarint()))
        }
        self.streams = streams
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt16(reportSequence)
        writer.writeUInt64(packets[0].packetNumber)
        writer.writeUInt64(referenceTime)
        // maxPackets is below the longest run a varint holds, so runs never split.
        var runs: [Int] = []
        var index = 0
        while index < packets.count {
            let received = packets[index].arrival != nil
            let ecn = packets[index].ecn
            var length = 0
            while index < packets.count, (packets[index].arrival != nil) == received, packets[index].ecn == ecn {
                length += 1
                index += 1
            }
            runs.append(length << 3 | (received ? 0b100 : 0) | Int(ecn.rawValue))
        }
        try writer.writeVarint(runs.count)
        for run in runs { try writer.writeVarint(run) }
        var previous = referenceTime
        for packet in packets {
            guard let arrival = packet.arrival else { continue }
            let zigzag = arrival >= previous ? Int(arrival - previous) << 1 : Int(previous - arrival - 1) << 1 | 1
            try writer.writeVarint(zigzag)
            previous = arrival
        }
        writer.writeUInt8(UInt8(streams.count))
        for stream in streams {
            writer.writeUInt32(stream.streamID)
            writer.writeUInt32(stream.lastDecodableFrame)
            writer.writeUInt32(stream.framesLost)
            try writer.writeVarint(stream.latenessP50)
            try writer.writeVarint(stream.latenessP95)
            try writer.writeVarint(stream.latenessP99)
        }
    }
}

/// NACK (0x09): video shards to send again (sections 4.2 and 6.3), one frame
/// or block per frame. Needs the `nack` capability.
///
/// ```
/// streamID u32 | frameNumber u32 | scope u8 |
///   scope 0  whole frame (no shard of it arrived)
///   scope 1  block u8 (no shard of that block arrived)
///   scope 2  block u8 | needed u8 | count u8 | count x data shard index u8, ascending
/// ```
///
/// For scope 2, `needed` more shards of any kind complete the block, and the
/// indices are its missing data shards, the cheapest to resend.
public struct ShardNack: WireCodable, Hashable {
    public enum Scope: Sendable, Hashable {
        case wholeFrame
        case wholeBlock(UInt8)
        case shards(block: UInt8, needed: UInt8, dataIndices: [UInt8])
    }

    public var streamID: UInt32
    public var frameNumber: UInt32
    public var scope: Scope

    public init(streamID: UInt32, frameNumber: UInt32, scope: Scope) {
        self.streamID = streamID
        self.frameNumber = frameNumber
        self.scope = scope
    }

    public func validate() throws(WireError) {
        guard case .shards(_, let needed, let indices) = scope else { return }
        guard needed >= 1 else { throw .invalid("nack.needed") }
        guard indices.count <= VideoShardHeader.maxShardsPerBlock else { throw .tooLarge("nack.indices") }
        guard zip(indices, indices.dropFirst()).allSatisfy({ $0 < $1 }) else { throw .invalid("nack.indices") }
    }

    public init(from reader: inout WireReader) throws(WireError) {
        streamID = try reader.readUInt32()
        frameNumber = try reader.readUInt32()
        switch try reader.readUInt8() {
        case 0:
            scope = .wholeFrame
        case 1:
            scope = .wholeBlock(try reader.readUInt8())
        case 2:
            let block = try reader.readUInt8()
            let needed = try reader.readUInt8()
            let count = Int(try reader.readUInt8())
            scope = .shards(block: block, needed: needed, dataIndices: Array(try reader.readBytes(count)))
        default:
            throw .invalid("nack.scope")
        }
        try validate()
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt32(streamID)
        writer.writeUInt32(frameNumber)
        switch scope {
        case .wholeFrame:
            writer.writeUInt8(0)
        case .wholeBlock(let block):
            writer.writeUInt8(1)
            writer.writeUInt8(block)
        case .shards(let block, let needed, let indices):
            writer.writeUInt8(2)
            writer.writeUInt8(block)
            writer.writeUInt8(needed)
            writer.writeUInt8(UInt8(indices.count))
            writer.writeBytes(indices)
        }
    }
}
