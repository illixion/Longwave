import StreamHost
import StreamTransport
import StreamWire
import XCTest

/// An auxiliary stream's sender (PCVR depth, section 4.8) numbers its frames
/// after the primary frames they go with.
final class AuxiliaryStreamSenderTests: XCTestCase {
    func testAuxiliaryFramesTakeTheirPrimaryFramesNumbers() throws {
        var sender = VideoStreamSender(configuration: .init(streamID: PCVRProfile.depthStreamID))
        let depth = SideData(depthRange: .planes(near: 0.15, far: .infinity, convergence: 0))
        func submit(_ number: UInt32, key: Bool, at now: UInt64) throws -> VideoStreamSender.Submission {
            try sender.submit(accessUnit: [0, 0, 0, 1, 0x40, 1, 2, 3], isKeyFrame: key, captureTime: now, sideData: depth,
                              frameNumber: number, udpPayload: 1_452, now: now)
        }
        XCTAssertEqual(try submit(7, key: true, at: 1_000_000), .queued(frameNumber: 7))
        XCTAssertEqual(sender.upcomingFrameNumber, 8)
        // The primary skipped 8 for this viewer: the auxiliary follows it to 9,
        // predicting from 7.
        XCTAssertEqual(try submit(9, key: false, at: 12_000_000), .queued(frameNumber: 9))
        var headers: [VideoShardHeader] = []
        while let output = sender.next(now: 100_000_000) {
            if case .shard(let header, _) = output { headers.append(header) }
        }
        let second = try XCTUnwrap(headers.first { $0.frameNumber == 9 })
        XCTAssertEqual(second.streamID, PCVRProfile.depthStreamID)
        XCTAssertEqual(second.referenceDistance, 2)
        XCTAssertEqual(sender.upcomingFrameNumber, 10)
    }
}
