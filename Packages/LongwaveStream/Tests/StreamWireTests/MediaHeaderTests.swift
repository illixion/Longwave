import StreamWire
import XCTest

final class VideoShardHeaderTests: XCTestCase {
    static let parity = VideoShardHeader(
        streamID: 0x1122_3344, frameNumber: 0x0000_0102, captureTime: 0x0102_0304_0506_0708,
        flags: [.recovery, .lastBlock], block: 2, blockCount: 3, shardIndex: 200, dataShards: 180,
        parityShards: 36, referenceDistance: 5)

    /// Interop vector: the C++ side must produce exactly these bytes.
    func testGolden() throws {
        let expected = hex(
            "44332211",          // streamID
            "02010000",          // frameNumber 0x102
            "0807060504030201",  // captureTime
            "0a",                // flags: recovery | lastBlock
            "02", "03",          // block 2 of 3
            "c8",                // shardIndex 200 (parity: >= dataShards)
            "b4", "24",          // k = 180, m = 36
            "0500")              // referenceDistance 5
        XCTAssertEqual(expected.count, VideoShardHeader.wireSize)
        XCTAssertEqual(try Self.parity.encoded(), expected)
        let decoded = try VideoShardHeader(decoding: expected)
        XCTAssertEqual(decoded, Self.parity)
        XCTAssertTrue(decoded.isParity)
        XCTAssertEqual(decoded.referenceFrame, 0x0FD)
    }

    func testKeyFrameHasNoReference() throws {
        let key = VideoShardHeader(streamID: 0, frameNumber: 0, captureTime: 0, flags: [.key, .lastBlock], block: 0,
                                   blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 2, referenceDistance: 0)
        XCTAssertEqual(try key.encoded(), hex("00000000 00000000 0000000000000000 09 00 01 00 01 02 0000"))
        XCTAssertNil(key.referenceFrame)
        XCTAssertEqual(key.totalShards, 3)
    }

    func testReferenceDistanceWrapsAcrossZero() {
        var header = Self.parity
        header.frameNumber = 2
        header.referenceDistance = 5
        XCTAssertEqual(header.referenceFrame, UInt32.max - 2)
    }

    func testValidation() {
        func expect(_ error: WireError, _ change: (inout VideoShardHeader) -> Void) {
            var header = Self.parity
            change(&header)
            XCTAssertWireError(error) { try header.encoded() }
            // And the same fields, forced onto the wire, fail to decode.
            XCTAssertWireError(error) { try VideoShardHeader(decoding: rawBytes(header)) }
        }
        expect(.invalid("videoShard.flags")) { $0.flags = VideoShardFlags(rawValue: 0x28) }
        expect(.invalid("videoShard.block")) { $0.blockCount = 0 }
        expect(.invalid("videoShard.block")) { $0.block = 3 }
        expect(.invalid("videoShard.dataShards")) { $0.dataShards = 0 }
        expect(.tooLarge("videoShard.shards")) { $0.parityShards = 76 }
        expect(.invalid("videoShard.shardIndex")) { $0.shardIndex = 216 }
        expect(.inconsistent("videoShard.lastBlock")) { $0.flags = [.recovery] }
        expect(.inconsistent("videoShard.lastBlock")) { $0.block = 1 }
        expect(.inconsistent("videoShard.key")) { $0.flags.insert(.key) }
        expect(.inconsistent("videoShard.discardable")) { $0.flags.formUnion([.discardable, .longTermReference]) }
    }

    func testTruncatedHeadersThrow() throws {
        let bytes = try Self.parity.encoded()
        for length in 0..<bytes.count {
            XCTAssertWireError(.truncated) { try VideoShardHeader(decoding: bytes[0..<length]) }
        }
    }
}

/// The header's bytes laid out by hand, bypassing `encode`'s validation, so
/// invalid headers can be fed to the decoder.
private func rawBytes(_ h: VideoShardHeader) -> [UInt8] {
    var w = WireWriter()
    w.writeUInt32(h.streamID)
    w.writeUInt32(h.frameNumber)
    w.writeUInt64(h.captureTime)
    w.writeUInt8(h.flags.rawValue)
    w.writeBytes([h.block, h.blockCount, h.shardIndex, h.dataShards, h.parityShards])
    w.writeUInt16(h.referenceDistance)
    return w.bytes
}

final class AudioShardHeaderTests: XCTestCase {
    func testGolden() throws {
        let header = AudioShardHeader(channelID: 0, fecIndex: 2, inBandFEC: true, codec: .opus,
                                      firstSample: 0x0000_0001_0000_00F0, frameSamples: 240, fecGroup: 0xBEEF)
        let expected = hex(
            "0000",              // channelID 0 (bed)
            "12",                // flags: fecIndex 2 | inBandFEC
            "01",                // codec Opus
            "f000000001000000",  // firstSample
            "f000",              // frameSamples 240
            "efbe")              // fecGroup
        XCTAssertEqual(expected.count, AudioShardHeader.wireSize)
        XCTAssertEqual(try header.encoded(), expected)
        XCTAssertEqual(try AudioShardHeader(decoding: expected), header)
    }

    func testParityAndObjectChannel() throws {
        let parity = AudioShardHeader(channelID: 7, fecIndex: 5, codec: .pcm24, firstSample: 9600,
                                      frameSamples: 480, fecGroup: 1)
        XCTAssertTrue(parity.isParity)
        XCTAssertEqual(try parity.encoded(), hex("0700 05 02 8025000000000000 e001 0100"))
        let (decoded, packet) = try AudioShardHeader.split((try parity.encoded() + [1, 2])[...])
        XCTAssertEqual(decoded, parity)
        XCTAssertEqual(Array(packet), [1, 2])
    }

    func testValidation() {
        XCTAssertWireError(.invalid("audioShard.fecIndex")) { try AudioShardHeader(decoding: hex("0000 06 01 0000000000000000 f000 0000")) }
        XCTAssertWireError(.invalid("audioShard.flags")) { try AudioShardHeader(decoding: hex("0000 20 01 0000000000000000 f000 0000")) }
        XCTAssertWireError(.invalid("audioShard.codec")) { try AudioShardHeader(decoding: hex("0000 00 03 0000000000000000 f000 0000")) }
        XCTAssertWireError(.invalid("audioShard.frameSamples")) { try AudioShardHeader(decoding: hex("0000 00 01 0000000000000000 0000 0000")) }
        XCTAssertWireError(.invalid("audioShard.frameSamples")) { try AudioShardHeader(decoding: hex("0000 00 01 0000000000000000 8116 0000")) }
        XCTAssertWireError(.inconsistent("audioShard.parityFlags")) { try AudioShardHeader(decoding: hex("0000 0c 01 0000000000000000 f000 0000")) }
        XCTAssertWireError(.truncated) { try AudioShardHeader(decoding: hex("0000 00 01 0000")) }
    }
}
