import StreamWire
import XCTest

final class VarintTests: XCTestCase {
    func testGoldenEncodings() throws {
        let vectors: [(Int, [UInt8])] = [
            (0, hex("00")), (1, hex("01")), (127, hex("7f")),
            (128, hex("8001")), (300, hex("ac02")), (16383, hex("ff7f")),
            (16384, hex("808001")), (Varint.maxValue, hex("ffff7f")),
        ]
        for (value, bytes) in vectors {
            var writer = WireWriter()
            try writer.writeVarint(value)
            XCTAssertEqual(writer.bytes, bytes, "\(value)")
            XCTAssertEqual(Varint.encodedLength(value), bytes.count)
            XCTAssertEqual(try Varint.parsePrefix(bytes[...]), .complete(value: value, length: bytes.count))
        }
    }

    func testRejectsNonCanonicalAndOverlong() {
        XCTAssertWireError(.nonCanonicalVarint) { try Varint.parsePrefix(hex("8000")[...]) }
        XCTAssertWireError(.nonCanonicalVarint) { try Varint.parsePrefix(hex("818000")[...]) }
        XCTAssertWireError(.varintTooLong) { try Varint.parsePrefix(hex("80808001")[...]) }
        XCTAssertEqual(try Varint.parsePrefix(hex("80")[...]), .incomplete)
        XCTAssertEqual(try Varint.parsePrefix([][...]), .incomplete)
    }

    func testWriteRejectsOutOfRange() {
        var writer = WireWriter()
        XCTAssertWireError(.tooLarge("varint")) { try writer.writeVarint(Varint.maxValue + 1) }
        XCTAssertWireError(.tooLarge("varint")) { try writer.writeVarint(-1) }
    }
}

final class FrameLayerTests: XCTestCase {
    func testGoldenDatagramBody() throws {
        var writer = WireWriter()
        try writer.appendFrame(.ping, body: hex("0102030405060708"))
        try writer.appendFrame(.ack, body: [])
        writer.appendPadding(3)
        XCTAssertEqual(writer.bytes, hex("07 08 0102030405060708", "02 00", "000000"))

        let frames = try FrameReader.frames(in: writer.bytes)
        XCTAssertEqual(frames.map(\.type), [.ping, .ack])
        // Padding may lead, trail, or sit between frames, in any amount.
        XCTAssertEqual(try FrameReader.frames(in: hex("00", "02 00", "0000", "02 00", "00")).map(\.type), [.ack, .ack])
        XCTAssertEqual(Array(frames[0].body), hex("0102030405060708"))
    }

    func testUnknownFrameTypesAreSkippedByLength() throws {
        let body = hex("f0 03 aabbcc", "07 01 99", "7f 00")
        var reader = FrameReader(body)
        let frame = try reader.next()
        XCTAssertEqual(frame?.type, .ping)
        XCTAssertEqual(frame.map { Array($0.body) }, [0x99])
        XCTAssertNil(try reader.next())
        XCTAssertEqual(reader.skippedUnknownFrames, 2)
    }

    func testMalformedBodies() {
        XCTAssertWireError(.truncated) { try FrameReader.frames(in: hex("07 05 0102")) }
        XCTAssertWireError(.truncated) { try FrameReader.frames(in: hex("07")) }
        XCTAssertWireError(.truncated) { try FrameReader.frames(in: hex("f0 80")) }
        XCTAssertWireError(.nonCanonicalVarint) { try FrameReader.frames(in: hex("07 8000")) }
        // Padding is one byte with no length, so "00 08" is padding then a
        // truncated pong, not a 5-byte padding frame.
        XCTAssertWireError(.truncated) { try FrameReader.frames(in: hex("00 08")) }
        var writer = WireWriter()
        XCTAssertWireError(.invalid("frame.padding")) { try writer.appendFrame(.padding, body: [0]) }
    }

    func testMediaFramesNeverShareADatagram() throws {
        let header = VideoShardHeader(streamID: 0, frameNumber: 1, captureTime: 2, flags: [.lastBlock], block: 0,
                                      blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 1)
        var one = WireWriter()
        try one.appendVideoShard(header, data: [1, 2, 3])
        try one.appendFrame(.feedback, body: [9])
        XCTAssertEqual(try FrameReader.frames(in: one.bytes).map(\.type), [.video, .feedback])

        var two = one
        try two.appendAudioShard(AudioShardHeader(channelID: 0, fecIndex: 0, codec: .opus, firstSample: 0,
                                                  frameSamples: 240, fecGroup: 0), packet: [1])
        XCTAssertWireError(.inconsistent("datagram.mediaFrames")) { try FrameReader.frames(in: two.bytes) }
    }

    func testAppendVideoShardMatchesGenericFrame() throws {
        let header = VideoShardHeader(streamID: 5, frameNumber: 9, captureTime: 1, flags: [.key, .lastBlock], block: 0,
                                      blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 0)
        let data = [UInt8](repeating: 0xAB, count: 200)
        var direct = WireWriter()
        try direct.appendVideoShard(header, data: data)
        var generic = WireWriter()
        try generic.appendFrame(.video, body: try header.encoded() + data)
        XCTAssertEqual(direct.bytes, generic.bytes)
        let frame = try XCTUnwrap(try FrameReader.frames(in: direct.bytes).first)
        let (decoded, payload) = try VideoShardHeader.split(frame.body)
        XCTAssertEqual(decoded, header)
        XCTAssertEqual(Array(payload), data)
    }

    /// The shard data size the packetizer must use, accounting for every byte
    /// in the datagram (section 4.2's "payload - 24" leaves out 32 of them).
    func testDatagramBudget() throws {
        XCTAssertEqual(DatagramLayout.sealedBodyCapacity(udpPayload: 1200), 1171)
        XCTAssertEqual(DatagramLayout.videoShardDataCapacity(udpPayload: 1200), 1144)
        XCTAssertEqual(DatagramLayout.videoShardDataCapacity(udpPayload: 1452), 1396)
        XCTAssertEqual(DatagramLayout.audioPacketCapacity(udpPayload: 1200), 1152)
        XCTAssertEqual(DatagramLayout.videoShardDataCapacity(udpPayload: 60), 5)

        // A shard of exactly that size fills the sealed body to the byte.
        let header = VideoShardHeader(streamID: 0, frameNumber: 0, captureTime: 0, flags: [.lastBlock], block: 0,
                                      blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 1)
        var writer = WireWriter()
        try writer.appendVideoShard(header, data: [UInt8](repeating: 0, count: 1144))
        XCTAssertEqual(writer.count, 1171)
    }
}

final class MessageFramingTests: XCTestCase {
    func testStreamParsingWaitsForCompleteMessages() throws {
        var stream = try MessageFraming.encode(.focusWindow, body: hex("0000000000000000 2a000000"))
        stream += try MessageFraming.encode(.releaseAll, body: hex("0100000000000000"))
        XCTAssertEqual(Array(stream.prefix(2)), hex("46 0c"))

        // Every proper prefix of the first message is "need more bytes".
        for cut in 0..<14 {
            XCTAssertNil(try MessageFraming.next(in: stream[0..<cut]), "cut \(cut)")
        }
        let first = try XCTUnwrap(try MessageFraming.next(in: stream[...]))
        XCTAssertEqual(first.consumed, 14)
        XCTAssertEqual(first.message.type, .focusWindow)
        let messages = try MessageFraming.messages(in: stream)
        XCTAssertEqual(messages.map(\.type), [.focusWindow, .releaseAll])
    }

    func testRejectsOversizedMessages() throws {
        var writer = WireWriter()
        writer.writeUInt8(0x20)
        try writer.writeVarint(MessageFraming.maxBodyLength + 1)
        XCTAssertWireError(.tooLarge("message.body")) { try MessageFraming.next(in: writer.bytes[...]) }
        XCTAssertWireError(.tooLarge("message.body")) {
            try MessageFraming.encode(.formatDescription, body: [UInt8](repeating: 0, count: MessageFraming.maxBodyLength + 1))
        }
    }

    func testSlicesKeepTheirOwnIndices() throws {
        // A message parsed out of the middle of a larger buffer.
        let buffer = hex("ffff") + (try MessageFraming.encode(.releaseAll, body: hex("0000000000000000")))
        let parsed = try XCTUnwrap(try MessageFraming.next(in: buffer[2...]))
        let event = try XCTUnwrap(try TimedInputEvent(message: parsed.message))
        XCTAssertEqual(event, TimedInputEvent(hostTime: 0, event: .releaseAll))
    }
}

final class ReaderTests: XCTestCase {
    func testLittleEndianFields() throws {
        var reader = WireReader(hex("01 0201 04030201 0807060504030201 feff 0000803f"))
        XCTAssertEqual(try reader.readUInt8(), 1)
        XCTAssertEqual(try reader.readUInt16(), 0x0102)
        XCTAssertEqual(try reader.readUInt32(), 0x0102_0304)
        XCTAssertEqual(try reader.readUInt64(), 0x0102_0304_0506_0708)
        XCTAssertEqual(try reader.readInt16(), -2)
        XCTAssertEqual(try reader.readFloat32(), 1.0)
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertWireError(.truncated) { try reader.readUInt8() }
        XCTAssertWireError(.truncated) { try reader.readBytes(-1) }
    }

    func testDecodingRequiresExactLength() throws {
        let bytes = try CapabilitySet([.pcvr]).encoded()
        XCTAssertWireError(.trailingBytes(1)) { try CapabilitySet(decoding: bytes + [0]) }
    }
}
