import StreamWire
import XCTest

/// Golden vectors for the transport frame bodies, worked out by hand from the
/// layouts in TransportFrames.swift: the interop reference for other hosts.
final class TransportFrameTests: XCTestCase {
    static let chunk = StreamChunk(channel: .input, offset: 0x0102, data: [0xAA, 0xBB])
    static let chunkBytes = hex("01", "0201000000000000", "aabb")

    static let ack = ChannelAck(channel: .control, ackDelay: 300, cumulative: 1000,
                                ranges: [.init(start: 1010, end: 1020), .init(start: 2000, end: 2500)])
    static let ackBytes = hex("00", "ac02", "e803000000000000", "02", "0a 0a", "d407 f403")

    static let feedback = Feedback(
        reportSequence: 0x0102, referenceTime: 1_000_000,
        packets: [
            .init(packetNumber: 100, arrival: 1_000_010, ecn: .ect0),
            .init(packetNumber: 101, arrival: nil),
            .init(packetNumber: 102, arrival: nil),
            .init(packetNumber: 103, arrival: 1_000_005),   // reordered: arrived before 100
            .init(packetNumber: 104, arrival: 1_000_400),
        ],
        streams: [.init(streamID: 1, lastDecodableFrame: 50, framesLost: 2,
                        latenessP50: 1500, latenessP95: 4000, latenessP99: 9000)])
    static let feedbackBytes = hex(
        "0201", "6400000000000000", "40420f0000000000",
        "03", "0e 10 14",                // ect0 received x1, lost x2, received x2
        "14 09 9606",                    // +10, -5, +395 µs
        "01", "01000000 32000000 02000000", "dc0b a01f a846")

    static let nack = ShardNack(streamID: 2, frameNumber: 0x10, scope: .shards(block: 1, needed: 2, dataIndices: [3, 5, 9]))
    static let nackBytes = hex("02000000", "10000000", "02", "01 02 03", "03 05 09")

    func testGoldenVectors() throws {
        XCTAssertEqual(try Self.chunk.encoded(), Self.chunkBytes)
        XCTAssertEqual(try StreamChunk(decoding: Self.chunkBytes), Self.chunk)
        XCTAssertEqual(try Self.ack.encoded(), Self.ackBytes)
        XCTAssertEqual(try ChannelAck(decoding: Self.ackBytes), Self.ack)
        XCTAssertEqual(try Self.feedback.encoded(), Self.feedbackBytes)
        XCTAssertEqual(try Feedback(decoding: Self.feedbackBytes), Self.feedback)
        XCTAssertEqual(try Self.nack.encoded(), Self.nackBytes)
        XCTAssertEqual(try ShardNack(decoding: Self.nackBytes), Self.nack)

        let ping = Ping(id: 7, sendTime: 0x0102_0304_0506_0708)
        XCTAssertEqual(try ping.encoded(), hex("07000000", "0807060504030201"))
        let pong = Pong(id: 7, pingSendTime: 1, receiveTime: 2, sendTime: 5)
        XCTAssertEqual(try pong.encoded(), hex("07000000", "0100000000000000", "0200000000000000", "0500000000000000"))
        XCTAssertEqual(try Pong(decoding: try pong.encoded()), pong)

        for nack in [ShardNack(streamID: 1, frameNumber: 2, scope: .wholeFrame),
                     ShardNack(streamID: 1, frameNumber: 2, scope: .wholeBlock(3))] {
            XCTAssertEqual(try ShardNack(decoding: try nack.encoded()), nack)
        }
        XCTAssertEqual(FrameType(rawValue: 0x09), .nack)
    }

    func testAckCoverage() {
        XCTAssertTrue(Self.ack.covers(start: 0, end: 1000))
        XCTAssertFalse(Self.ack.covers(start: 999, end: 1001))
        XCTAssertTrue(Self.ack.covers(start: 1010, end: 1020))
        XCTAssertTrue(Self.ack.covers(start: 2100, end: 2200))
        XCTAssertFalse(Self.ack.covers(start: 1015, end: 1025))
        XCTAssertFalse(Self.ack.covers(start: 1020, end: 1021))
    }

    func testRejections() {
        XCTAssertWireError(.invalid("streamChunk.data")) { try StreamChunk(decoding: hex("00", "0000000000000000")) }
        XCTAssertWireError(.invalid("streamChunk.channel")) { try StreamChunk(decoding: hex("03", "0000000000000000", "01")) }
        XCTAssertWireError(.tooLarge("streamChunk.offset")) { try StreamChunk(decoding: hex("00", "ffffffffffffffff", "01")) }

        // A range touching cumulative (gap 0), an empty range, too many ranges.
        XCTAssertWireError(.invalid("ack.range")) { try ChannelAck(decoding: hex("00", "00", "0000000000000000", "01", "00 05")) }
        XCTAssertWireError(.invalid("ack.range")) { try ChannelAck(decoding: hex("00", "00", "0000000000000000", "01", "01 00")) }
        XCTAssertWireError(.tooLarge("ack.ranges")) { try ChannelAck(decoding: hex("00", "00", "0000000000000000", "21")) }
        XCTAssertWireError(.trailingBytes(1)) { try ChannelAck(decoding: Self.ackBytes + [0]) }
        XCTAssertWireError(.invalid("ack.range")) {
            try ChannelAck(channel: .bulk, ackDelay: 0, cumulative: 10, ranges: [.init(start: 10, end: 20)]).encoded()
        }

        // Neighbouring equal runs, ECN on a lost run, a zero-length run, no packets.
        XCTAssertWireError(.invalid("feedback.run")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "02 08 08", "00"))
        }
        XCTAssertWireError(.invalid("feedback.ecn")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "01 09", "00"))
        }
        XCTAssertWireError(.invalid("feedback.run")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "01 04", "00"))
        }
        XCTAssertWireError(.missing("feedback.packets")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "00", "00"))
        }
        // An arrival before time zero.
        XCTAssertWireError(.invalid("feedback.delta")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "01 0c", "01", "00"))
        }
        // A lost run far longer than the cap costs three bytes; it must not allocate.
        XCTAssertWireError(.tooLarge("feedback.packets")) {
            try Feedback(decoding: hex("0000", "0000000000000000", "0000000000000000", "01 f8ff7f", "00"))
        }
        XCTAssertWireError(.tooLarge("feedback.delta")) {
            try Feedback(reportSequence: 0, referenceTime: 0,
                         packets: [.init(packetNumber: 0, arrival: UInt64(Feedback.maxDelta) + 1)]).encoded()
        }
        XCTAssertWireError(.invalid("feedback.packetNumber")) {
            try Feedback(reportSequence: 0, referenceTime: 0,
                         packets: [.init(packetNumber: 0, arrival: 1), .init(packetNumber: 2, arrival: 2)]).encoded()
        }

        XCTAssertWireError(.inconsistent("pong.times")) {
            try Pong(id: 1, pingSendTime: 0, receiveTime: 5, sendTime: 4).encoded()
        }
        XCTAssertWireError(.invalid("nack.indices")) { try ShardNack(decoding: hex("00000000", "00000000", "02", "00 01 02", "05 03")) }
        XCTAssertWireError(.invalid("nack.needed")) { try ShardNack(decoding: hex("00000000", "00000000", "02", "00 00 00")) }
        XCTAssertWireError(.invalid("nack.scope")) { try ShardNack(decoding: hex("00000000", "00000000", "03")) }
    }

    /// Generated reports with loss, reordering and every ECN mark round-trip.
    func testRandomFeedbackRoundTrips() throws {
        var rng = SplitMix64(seed: 0xFEED)
        for _ in 0..<500 {
            let count = 1 + Int(rng.next() % 600)
            let base = rng.next() % (1 << 40)
            var arrival: UInt64 = 5_000_000 + rng.next() % 1_000_000
            var packets: [Feedback.Packet] = []
            for index in 0..<count {
                if rng.next() % 5 == 0 {
                    packets.append(.init(packetNumber: base + UInt64(index), arrival: nil))
                } else {
                    let step = Int64(rng.next() % 3000) - 500
                    arrival = UInt64(Int64(arrival) + step)
                    packets.append(.init(packetNumber: base + UInt64(index), arrival: arrival,
                                         ecn: ECNMark(rawValue: UInt8(rng.next() % 4))!))
                }
            }
            let report = Feedback(reportSequence: UInt16(truncatingIfNeeded: rng.next()), referenceTime: 5_000_000,
                                  packets: packets)
            XCTAssertEqual(try Feedback(decoding: try report.encoded()), report)
        }
    }
}
