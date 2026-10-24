import StreamWire

/// The sending half of one reliable channel (section 4.1): a byte stream sent
/// as CTRL chunks, retransmitted until a peer ACK covers it.
///
/// There is no congestion window: the channels carry a few KB/s and are
/// counted against the media rate controller's budget instead. In-flight bytes
/// are capped by `window`, which the receiver uses to bound what it buffers
/// out of order.
public struct ReliableSender: Sendable {
    public static let defaultWindow = 256 * 1024
    /// Backoff doubles the timeout per retransmission, up to 2^6.
    static let maxBackoffShift = 6

    struct Segment: Sendable {
        var offset: UInt64
        var data: [UInt8]
        var sentAt: UInt64
        /// Order of this transmission among all of the channel's sends: send
        /// times alone can't order segments that left in the same instant.
        var sequence: UInt64
        var transmissions: Int

        var end: UInt64 { offset + UInt64(data.count) }
    }

    public let channel: ReliableChannelID
    public let window: Int
    /// Everything below this offset is acknowledged.
    public private(set) var acknowledged: UInt64 = 0
    /// The offset of the next byte never sent.
    public private(set) var nextOffset: UInt64 = 0
    /// Bytes retransmitted so far (statistics).
    public private(set) var retransmittedBytes = 0

    /// Unsent bytes; `unsent[unsentStart...]` is live, the prefix awaits compaction.
    private var unsent: [UInt8] = []
    private var unsentStart = 0
    /// Sent and unacknowledged, ascending by offset, never overlapping.
    private var inFlight: [Segment] = []
    /// The newest acknowledged transmission. An unacknowledged one sent before
    /// it is lost once the reordering delay has passed (RFC 9002 6.1.2).
    private var newestAckedSequence: UInt64?
    private var nextSequence: UInt64 = 0

    public init(channel: ReliableChannelID, window: Int = ReliableSender.defaultWindow) {
        self.channel = channel
        self.window = window
    }

    /// Queues raw stream bytes.
    public mutating func enqueue(_ bytes: some Collection<UInt8>) {
        unsent.append(contentsOf: bytes)
    }

    /// Queues one framed message.
    public mutating func enqueue(_ type: MessageType, body: some Collection<UInt8>) throws(WireError) {
        enqueue(try MessageFraming.encode(type, body: body))
    }

    public var unsentBytes: Int { unsent.count - unsentStart }
    public var bytesInFlight: Int { Int(nextOffset - acknowledged) }
    /// Nothing queued and nothing unacknowledged.
    public var isIdle: Bool { unsentBytes == 0 && inFlight.isEmpty }
    /// Whether a chunk could be sent right now (new data within the window, or a
    /// lost segment to repeat).
    public func hasSendable(now: UInt64, rtt: RTTEstimator) -> Bool {
        if inFlight.contains(where: { isDue($0, now: now, rtt: rtt) }) { return true }
        return unsentBytes > 0 && bytesInFlight < window
    }

    /// The next chunk to send, at most `maxData` bytes of data: a lost or
    /// timed-out segment first, then new bytes within the window.
    public mutating func nextChunk(maxData: Int, now: UInt64, rtt: RTTEstimator) -> StreamChunk? {
        guard maxData > 0 else { return nil }
        if let index = inFlight.firstIndex(where: { isDue($0, now: now, rtt: rtt) }) {
            if inFlight[index].data.count > maxData {
                // Send the head now; the tail stays due.
                var tail = inFlight[index]
                tail.offset += UInt64(maxData)
                tail.data = Array(tail.data[maxData...])
                inFlight[index].data = Array(inFlight[index].data[..<maxData])
                inFlight.insert(tail, at: index + 1)
            }
            inFlight[index].sentAt = now
            inFlight[index].sequence = nextSequence
            nextSequence += 1
            inFlight[index].transmissions += 1
            retransmittedBytes += inFlight[index].data.count
            return StreamChunk(channel: channel, offset: inFlight[index].offset, data: inFlight[index].data)
        }
        let room = window - bytesInFlight
        let count = min(maxData, unsentBytes, room)
        guard count > 0 else { return nil }
        let data = Array(unsent[unsentStart..<(unsentStart + count)])
        unsentStart += count
        if unsentStart > 4096, unsentStart * 2 > unsent.count {
            unsent.removeFirst(unsentStart)
            unsentStart = 0
        }
        let segment = Segment(offset: nextOffset, data: data, sentAt: now, sequence: nextSequence, transmissions: 1)
        nextSequence += 1
        inFlight.append(segment)
        nextOffset += UInt64(count)
        return StreamChunk(channel: channel, offset: segment.offset, data: data)
    }

    /// Applies a peer ACK. Returns an RTT sample when the newest newly
    /// acknowledged segment was sent only once (Karn's rule).
    public mutating func handle(_ ack: ChannelAck, now: UInt64, rtt: RTTEstimator) -> UInt64? {
        guard ack.channel == channel, ack.cumulative <= nextOffset else { return nil }
        acknowledged = max(acknowledged, ack.cumulative)
        var newestAcked: (sequence: UInt64, sentAt: UInt64, single: Bool)?
        var remaining: [Segment] = []
        remaining.reserveCapacity(inFlight.count)
        for segment in inFlight {
            let pieces = Self.uncovered(segment, by: ack)
            if pieces.count == 1, pieces[0].offset == segment.offset, pieces[0].data.count == segment.data.count {
                remaining.append(segment)
                continue
            }
            if newestAcked.map({ segment.sequence > $0.sequence }) ?? true {
                newestAcked = (segment.sequence, segment.sentAt, segment.transmissions == 1)
            }
            remaining += pieces
        }
        inFlight = remaining
        if let newestAcked { newestAckedSequence = max(newestAckedSequence ?? 0, newestAcked.sequence) }
        guard let newestAcked, newestAcked.single, now >= newestAcked.sentAt else { return nil }
        return now - newestAcked.sentAt
    }

    /// When the earliest in-flight segment is due again (timed out, or lost
    /// to reordering), if any.
    public func nextTimeout(rtt: RTTEstimator) -> UInt64? {
        inFlight.lazy.map { self.deadline($0, rtt: rtt) }.min()
    }

    private func deadline(_ segment: Segment, rtt: RTTEstimator) -> UInt64 {
        let timeout = segment.sentAt + (rtt.retransmissionTimeout << min(segment.transmissions - 1, Self.maxBackoffShift))
        guard let newestAckedSequence, segment.sequence < newestAckedSequence else { return timeout }
        return min(timeout, segment.sentAt + rtt.reorderingDelay)
    }

    private func isDue(_ segment: Segment, now: UInt64, rtt: RTTEstimator) -> Bool {
        now >= deadline(segment, rtt: rtt)
    }

    /// The parts of `segment` the ACK doesn't cover, as segments.
    static func uncovered(_ segment: Segment, by ack: ChannelAck) -> [Segment] {
        var covered: [(UInt64, UInt64)] = [(0, ack.cumulative)]
        covered += ack.ranges.map { ($0.start, $0.end) }
        var pieces: [Segment] = []
        var cursor = segment.offset
        for (start, end) in covered where end > cursor && start < segment.end {
            if start > cursor {
                var piece = segment
                piece.offset = cursor
                piece.data = Array(segment.data[Int(cursor - segment.offset)..<Int(start - segment.offset)])
                pieces.append(piece)
            }
            cursor = max(cursor, end)
            if cursor >= segment.end { break }
        }
        if cursor < segment.end {
            var piece = segment
            piece.offset = cursor
            piece.data = Array(segment.data[Int(cursor - segment.offset)...])
            pieces.append(piece)
        }
        return pieces
    }
}

/// The receiving half of one reliable channel: reorders CTRL chunks into the
/// byte stream and says what to acknowledge.
public struct ReliableReceiver: Sendable {
    /// An ACK waits at most this long for more data to ride with (1 ms).
    public static let maxAckDelay: UInt64 = 1_000_000

    public let channel: ReliableChannelID
    public let window: Int
    /// The next offset needed; everything below it was delivered.
    public private(set) var cumulative: UInt64 = 0
    public private(set) var duplicateBytes = 0

    /// Out-of-order data above `cumulative`, ascending, never overlapping.
    private var held: [(offset: UInt64, data: [UInt8])] = []
    /// Arrival of the newest chunk not yet acknowledged.
    private var unackedSince: UInt64?
    private var newestArrival: UInt64 = 0
    private var immediateAck = false

    public init(channel: ReliableChannelID, window: Int = ReliableSender.defaultWindow) {
        self.channel = channel
        self.window = window
    }

    public var heldBytes: Int { held.reduce(0) { $0 + $1.data.count } }

    /// Takes one chunk; returns the bytes that became deliverable, in order.
    public mutating func receive(_ chunk: StreamChunk, now: UInt64) -> [UInt8] {
        precondition(chunk.channel == channel)
        if unackedSince == nil { unackedSince = now }
        newestArrival = now
        let limit = cumulative + UInt64(window)
        var start = max(chunk.offset, cumulative)
        let end = min(chunk.end, limit)
        guard start < end else {
            // Entirely old (a resend whose ACK was lost) or beyond the window: ack now.
            duplicateBytes += chunk.data.count
            immediateAck = true
            return []
        }
        if chunk.offset > cumulative { immediateAck = true } // a gap: tell the sender at once

        // Insert the new parts, skipping bytes already held.
        var index = held.firstIndex { $0.offset + UInt64($0.data.count) > start } ?? held.count
        while start < end {
            let nextHeldStart = index < held.count ? held[index].offset : end
            if start < nextHeldStart {
                let pieceEnd = min(end, nextHeldStart)
                let data = Array(chunk.data[Int(start - chunk.offset)..<Int(pieceEnd - chunk.offset)])
                held.insert((start, data), at: index)
                index += 1
                start = pieceEnd
            } else {
                let heldEnd = held[index].offset + UInt64(held[index].data.count)
                duplicateBytes += Int(min(heldEnd, end) - start)
                start = heldEnd
                index += 1
            }
        }

        var delivered: [UInt8] = []
        while let first = held.first, first.offset == cumulative {
            delivered += first.data
            cumulative += UInt64(first.data.count)
            held.removeFirst()
        }
        if !held.isEmpty { immediateAck = true }
        return delivered
    }

    /// When an ACK is owed: at once after a gap or duplicate, else within
    /// `maxAckDelay` of the first unacknowledged chunk.
    public var ackDeadline: UInt64? {
        guard let unackedSince else { return nil }
        return immediateAck ? unackedSince : unackedSince + Self.maxAckDelay
    }

    /// The ACK to send now, if one is owed.
    public mutating func makeAck(now: UInt64) -> ChannelAck? {
        guard unackedSince != nil else { return nil }
        var ranges: [ChannelAck.Range] = []
        for piece in held {
            let end = piece.offset + UInt64(piece.data.count)
            if let last = ranges.last, last.end == piece.offset {
                ranges[ranges.count - 1].end = end
            } else {
                guard ranges.count < ChannelAck.maxRanges else { break }
                ranges.append(.init(start: piece.offset, end: end))
            }
        }
        let delay = now >= newestArrival ? min(Int((now - newestArrival) / 1_000), Varint.maxValue) : 0
        unackedSince = nil
        immediateAck = false
        return ChannelAck(channel: channel, ackDelay: delay, cumulative: cumulative, ranges: ranges)
    }
}

/// Splits a channel's delivered bytes into messages (`MessageFraming`).
public struct MessageReassembler: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public var bufferedBytes: Int { buffer.count - start }

    public mutating func append(_ bytes: [UInt8]) {
        buffer += bytes
    }

    /// The next whole message, with its body copied out of the stream buffer.
    /// Throws when the stream is malformed, which ends the session.
    public mutating func next() throws(WireError) -> Message? {
        guard let (message, consumed) = try MessageFraming.next(in: buffer[start...]) else { return nil }
        let copy = Message(type: message.type, body: Array(message.body)[...])
        start += consumed
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 65_536, start * 2 > buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return copy
    }
}
