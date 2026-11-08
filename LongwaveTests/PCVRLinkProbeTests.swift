#if FOVEATED_ENABLED
import XCTest
@testable import Longwave

final class PCVRLinkProbeTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// A paced 60 fps stream with one 120 ms stall: the stall is listed, and
    /// the frame that arrives after it carries the backlog as excess age.
    func testStallAndTheFrameAfterIt() throws {
        var probe = PCVRLinkProbe()
        let start: UInt64 = 1_000 * ms
        var now = start
        for frame in 0..<120 {
            let capture = start + UInt64(frame) * 16 * ms
            // Encode 8 ms, then 10 shards 0.5 ms apart; frame 60's are held 120 ms by the radio.
            let held: UInt64 = frame == 60 ? 120 * ms : 0
            for shard in 0..<10 {
                now = max(now, capture + 8 * ms + UInt64(shard) * ms / 2 + held)
                probe.datagram(at: now)
                probe.shard(frame: UInt32(frame), captureTime: capture, key: frame == 0, now: now, remoteNow: now)
            }
        }
        let report = probe.report(seconds: 20, now: now)
        let gaps = try XCTUnwrap(report["gapsMs"] as? [String: Any])
        XCTAssertEqual(gaps["over100"] as? Int, 1)
        let stalls = try XCTUnwrap(report["stalls"] as? [[String: Any]])
        XCTAssertEqual(stalls.count, 1)
        // From frame 59's last shard (12.5 ms after its capture) to frame 60's first (16 + 8 + 120 ms).
        XCTAssertEqual(try XCTUnwrap(stalls.first?["ms"] as? Double), 131.5, accuracy: 0.01)
        let after = try XCTUnwrap(report["excessAfterStallMs"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(after["max"] as? Double), 120, accuracy: 0.6)
        let age = try XCTUnwrap(report["frameAgeMs"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(age["min"] as? Double), 12.5, accuracy: 0.01)
        XCTAssertEqual(report["frames"] as? Int, 120)
        // The frames queued behind the stalled one are late too.
        XCTAssertGreaterThanOrEqual(report["framesLateOver20ms"] as? Int ?? 0, 1)
    }

    func testRTTSamplesAreTakenOncePerNewSample() throws {
        var probe = PCVRLinkProbe()
        probe.rtt(latest: 5 * ms, sampleCount: 1, now: 10 * ms)
        probe.rtt(latest: 5 * ms, sampleCount: 1, now: 11 * ms)
        probe.rtt(latest: 9 * ms, sampleCount: 2, now: 12 * ms)
        let rtt = try XCTUnwrap(probe.report(seconds: 20, now: 13 * ms)["rttMs"] as? [String: Any])
        XCTAssertEqual(rtt["max"] as? Double, 9)
        XCTAssertEqual(rtt["min"] as? Double, 5)
    }
}
#endif
