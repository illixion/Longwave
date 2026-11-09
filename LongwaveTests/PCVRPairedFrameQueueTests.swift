#if FOVEATED_ENABLED
import XCTest
@testable import Longwave

final class PCVRPairedFrameQueueTests: XCTestCase {
    private struct Frame: PCVRPlayoutFrame {
        var streamEpoch: UInt32 = 0
        var frameNumber: UInt32
        var spaceEpoch: UInt16 = 0
    }
    func testWaitsForExactDepthAndRetainsPairWhenDepthIsLate() throws {
        var queue = PCVRPairedFrameQueue<Frame, UInt32>()
        XCTAssertNil(queue.select(Frame(frameNumber: 10)) { _ in nil })
        XCTAssertEqual(queue.select(Frame(frameNumber: 10)) { $0 == 10 ? 10 : nil }?.depth, 10)
        let held = try XCTUnwrap(queue.select(Frame(frameNumber: 11)) { _ in nil })
        XCTAssertEqual(held.frame.frameNumber, 10)
        XCTAssertEqual(held.depth, 10)
        XCTAssertEqual(queue.pending.map(\.frameNumber), [11])
        XCTAssertEqual(queue.select(Frame(frameNumber: 11)) { $0 }?.frame.frameNumber, 11)
    }
    func testLateDepthCanMatchPendingColourBehindNewest() {
        var queue = PCVRPairedFrameQueue<Frame, UInt32>()
        _ = queue.select(Frame(frameNumber: 20)) { _ in nil }
        let pair = queue.select(Frame(frameNumber: 21)) { $0 == 20 ? 20 : nil }
        XCTAssertEqual(pair?.frame.frameNumber, 20)
        XCTAssertEqual(pair?.depth, 20)
        XCTAssertEqual(queue.pending.map(\.frameNumber), [21])
    }
    func testNewestMatchWinsAndPendingMemoryIsBounded() {
        var queue = PCVRPairedFrameQueue<Frame, UInt32>()
        for n in 0..<20 { _ = queue.select(Frame(frameNumber: UInt32(n))) { _ in nil } }
        XCTAssertEqual(queue.pending.map(\.frameNumber), [17, 18, 19])
        XCTAssertEqual(queue.select(Frame(frameNumber: 19)) { $0 }?.frame.frameNumber, 19)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(queue.select(Frame(frameNumber: 18)) { $0 }?.frame.frameNumber, 19)
    }
    func testRestartAndRecentreNeverRepeatTheOldPair() {
        var queue = PCVRPairedFrameQueue<Frame, UInt32>()
        _ = queue.select(Frame(frameNumber: 1)) { $0 }
        XCTAssertNil(queue.select(Frame(streamEpoch: 1, frameNumber: 1)) { _ in nil })
        _ = queue.select(Frame(streamEpoch: 1, frameNumber: 1)) { $0 }
        XCTAssertNil(queue.select(Frame(streamEpoch: 1, frameNumber: 2, spaceEpoch: 1)) { _ in nil })
    }
    func testFrameNumberWrapAndRepeatedPairSurviveStoreEviction() {
        var queue = PCVRPairedFrameQueue<Frame, UInt32>()
        _ = queue.select(Frame(frameNumber: .max)) { $0 }
        XCTAssertEqual(queue.select(Frame(frameNumber: 0)) { $0 }?.frame.frameNumber, 0)
        XCTAssertEqual(queue.select(Frame(frameNumber: 0)) { _ in nil }?.depth, 0)
    }
}
#endif
