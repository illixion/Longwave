import StreamWire
import XCTest

final class StreamFormatTableTests: XCTestCase {
    private func shard(_ streamID: UInt32, frame: UInt32, time: UInt64) -> VideoShardHeader {
        VideoShardHeader(streamID: streamID, frameNumber: frame, captureTime: time, flags: [.lastBlock], block: 0,
                         blockCount: 1, shardIndex: 0, dataShards: 1, parityShards: 0, referenceDistance: 1)
    }

    private func tableWithGameAndDepth() throws -> StreamFormatTable {
        var table = StreamFormatTable()
        try table.apply(Fixtures.gameFormat)
        try table.apply(Fixtures.depthFormat)
        return table
    }

    func testAuxiliaryFramesPairByNumberAndCaptureTime() throws {
        let table = try tableWithGameAndDepth()
        let depthID = Fixtures.depthFormat.streamID
        let picture = shard(0, frame: 500, time: 123_456)
        let depth = shard(depthID, frame: 500, time: 123_456)

        try table.checkPairing(primary: picture, auxiliary: depth)
        XCTAssertEqual(table.pairKey(for: picture), FramePairKey(primaryStreamID: 0, frameNumber: 500))
        XCTAssertEqual(table.pairKey(for: depth), table.pairKey(for: picture))
        XCTAssertEqual(table.auxiliaries(of: 0), [.depth: depthID])

        XCTAssertWireError(.inconsistent("pairing.frameNumber")) {
            try table.checkPairing(primary: picture, auxiliary: shard(depthID, frame: 501, time: 123_456))
        }
        XCTAssertWireError(.inconsistent("pairing.captureTime")) {
            try table.checkPairing(primary: picture, auxiliary: shard(depthID, frame: 500, time: 123_457))
        }
        XCTAssertWireError(.inconsistent("pairing.primary")) { try table.checkPairing(primary: depth, auxiliary: picture) }
        XCTAssertWireError(.inconsistent("pairing.auxiliary")) { try table.checkPairing(primary: picture, auxiliary: picture) }
        XCTAssertNil(table.pairKey(for: shard(77, frame: 1, time: 1)))
    }

    func testAuxiliaryNeedsAnExistingPrimary() {
        var table = StreamFormatTable()
        XCTAssertWireError(.missing("streams.primary")) { try table.apply(Fixtures.depthFormat) }
    }

    func testNoAuxiliaryChains() throws {
        var table = try tableWithGameAndDepth()
        var alphaOfDepth = Fixtures.depthFormat
        alphaOfDepth.streamID = 0x8000_0001
        alphaOfDepth.auxiliary = AuxiliaryStream(role: .alpha, primaryStreamID: Fixtures.depthFormat.streamID)
        alphaOfDepth.depthEncoding = nil
        XCTAssertWireError(.inconsistent("streams.auxiliaryChain")) { try table.apply(alphaOfDepth) }
    }

    func testOneAuxiliaryPerRole() throws {
        var table = try tableWithGameAndDepth()
        var second = Fixtures.depthFormat
        second.streamID = 0x8000_0002
        XCTAssertWireError(.duplicate("streams.auxiliaryRole")) { try table.apply(second) }
        second.auxiliary?.role = .alpha
        second.depthEncoding = nil
        try table.apply(second) // an alpha auxiliary beside the depth one is fine
        XCTAssertEqual(table.auxiliaries(of: 0).count, 2)
    }

    func testRolesAreFixedForAStreamsLifetime() throws {
        var table = try tableWithGameAndDepth()
        var promoted = Fixtures.depthFormat
        promoted.firstFrameNumber = 200
        promoted.auxiliary = nil
        promoted.depthEncoding = nil
        XCTAssertWireError(.inconsistent("streams.roleChanged")) { try table.apply(promoted) }
    }

    func testFormatsApplyFromTheirFirstFrame() throws {
        var table = StreamFormatTable()
        try table.apply(Fixtures.gameFormat) // from frame 100
        var next = Fixtures.gameFormat
        next.firstFrameNumber = 160
        next.size = PixelSize(width: 1920, height: 1080)
        try table.apply(next)

        XCTAssertEqual(table.format(streamID: 0, frameNumber: 159)?.size.width, 2560) // overtook the change
        XCTAssertEqual(table.format(streamID: 0, frameNumber: 160)?.size.width, 1920)
        XCTAssertEqual(table.format(streamID: 0, frameNumber: 5000)?.size.width, 1920)
        XCTAssertNil(table.format(streamID: 0, frameNumber: 99))

        XCTAssertWireError(.inconsistent("streams.firstFrameNumber")) { try table.apply(next) }
        var stale = next
        stale.firstFrameNumber = 150
        XCTAssertWireError(.inconsistent("streams.firstFrameNumber")) { try table.apply(stale) }

        // Only `historyDepth` formats are kept.
        var third = next
        third.firstFrameNumber = 200
        try table.apply(third)
        XCTAssertNil(table.format(streamID: 0, frameNumber: 120))
    }

    func testFirstFrameNumbersWrap() throws {
        var table = StreamFormatTable()
        var first = Fixtures.gameFormat
        first.firstFrameNumber = UInt32.max - 1
        try table.apply(first)
        var wrapped = first
        wrapped.firstFrameNumber = 3
        try table.apply(wrapped)
        XCTAssertEqual(table.format(streamID: 0, frameNumber: UInt32.max)?.firstFrameNumber, UInt32.max - 1)
        XCTAssertEqual(table.format(streamID: 0, frameNumber: 4)?.firstFrameNumber, 3)
    }

    func testRemovingAPrimaryRemovesItsAuxiliaries() throws {
        var table = try tableWithGameAndDepth()
        XCTAssertEqual(Set(table.remove(0)), [0, Fixtures.depthFormat.streamID])
        XCTAssertTrue(table.streamIDs.isEmpty)
        XCTAssertEqual(table.remove(0), [])
    }
}
