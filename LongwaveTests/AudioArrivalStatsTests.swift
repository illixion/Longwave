import XCTest
@testable import Longwave

/// Covers the v8 `PCMStamp` and the receiver's loss / reorder / jitter
/// bookkeeping built on it. The classification is what the next round of
/// cushion tuning will be read from, so a hole booked as a resume — or a
/// suppressed stretch booked as loss — would send that work the wrong way.
final class AudioArrivalStatsTests: XCTestCase {
    private let rate = 48_000.0
    /// One UDP datagram's worth of stereo int24 at the 1100-byte budget.
    private let frames = 181

    private func nanos(forFrame index: UInt64, lateMs: Double = 0) -> UInt64 {
        UInt64((Double(index) / rate + lateMs / 1000) * 1_000_000_000) + 1_000_000_000
    }

    // MARK: - Stamp

    func testStampRoundTrips() {
        let stamp = PCMStamp(sampleIndex: 0x0102_0304_0506_0708, flags: .resumed)
        let data = stamp.encoded()
        XCTAssertEqual(data.count, PCMStamp.size)
        XCTAssertEqual(Array(data), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x01])
        XCTAssertEqual(PCMStamp(parsing: data), stamp)
    }

    func testStampParsesFromSlice() {
        var payload = Data([0xAA, 0xBB])
        payload.append(PCMStamp(sampleIndex: 42).encoded())
        payload.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(PCMStamp(parsing: payload.dropFirst(2)), PCMStamp(sampleIndex: 42))
        XCTAssertNil(PCMStamp(parsing: Data(count: PCMStamp.size - 1)))
    }

    // MARK: - Classification

    func testContiguousStreamHasNoHoles() {
        var stats = AudioArrivalStats(sampleRate: rate)
        for i in 0..<100 {
            let index = UInt64(i * frames)
            XCTAssertEqual(stats.record(stamp: PCMStamp(sampleIndex: index), frames: frames, arrivalNanos: nanos(forFrame: index)), .play)
        }
        let report = stats.takeReport()
        XCTAssertEqual(report.payloads, 100)
        XCTAssertEqual(report.holes, 0)
        XCTAssertEqual(report.late, 0)
        XCTAssertEqual(report.delayMaxMs, 0, accuracy: 0.01)
    }

    func testLostDatagramIsAHole() {
        var stats = AudioArrivalStats(sampleRate: rate)
        for i in [0, 1, 3, 4] {
            let index = UInt64(i * frames)
            _ = stats.record(stamp: PCMStamp(sampleIndex: index), frames: frames, arrivalNanos: nanos(forFrame: index))
        }
        let report = stats.takeReport()
        XCTAssertEqual(report.holes, 1)
        XCTAssertEqual(report.holeFrames, frames)
        XCTAssertEqual(report.late, 0)
    }

    func testReorderedDatagramIsDroppedAsLate() {
        var stats = AudioArrivalStats(sampleRate: rate)
        let order = [0, 2, 1, 3]
        var dispositions: [AudioArrivalStats.Disposition] = []
        for i in order {
            let index = UInt64(i * frames)
            dispositions.append(stats.record(stamp: PCMStamp(sampleIndex: index), frames: frames, arrivalNanos: nanos(forFrame: 2 * UInt64(frames))))
        }
        XCTAssertEqual(dispositions, [.play, .play, .late, .play])
        let report = stats.takeReport()
        XCTAssertEqual(report.holes, 1, "the reordered datagram's slot was a hole when its successor arrived")
        XCTAssertEqual(report.late, 1)
    }

    func testFlaggedGapIsSuppressionNotLoss() {
        var stats = AudioArrivalStats(sampleRate: rate)
        _ = stats.record(stamp: PCMStamp(sampleIndex: 0), frames: frames, arrivalNanos: nanos(forFrame: 0))
        // Five seconds of suppressed silence, then the sender resumes.
        let resumed = UInt64(5 * rate)
        _ = stats.record(stamp: PCMStamp(sampleIndex: resumed, flags: .resumed), frames: frames, arrivalNanos: nanos(forFrame: resumed))
        let report = stats.takeReport()
        XCTAssertEqual(report.holes, 0)
        XCTAssertEqual(report.resumes, 1)
        XCTAssertEqual(report.discontinuities, 0)
        XCTAssertEqual(report.delayMaxMs, 0, accuracy: 0.01, "suppression must not read as delay")
    }

    func testUnflaggedLongJumpIsARestart() {
        var stats = AudioArrivalStats(sampleRate: rate)
        _ = stats.record(stamp: PCMStamp(sampleIndex: 10_000_000), frames: frames, arrivalNanos: nanos(forFrame: 0))
        // Tap recreated: the device clock started over near zero.
        XCTAssertEqual(stats.record(stamp: PCMStamp(sampleIndex: 0), frames: frames, arrivalNanos: nanos(forFrame: 0)), .play)
        XCTAssertEqual(stats.record(stamp: PCMStamp(sampleIndex: UInt64(frames)), frames: frames, arrivalNanos: nanos(forFrame: UInt64(frames))), .play)
        let report = stats.takeReport()
        XCTAssertEqual(report.discontinuities, 1)
        XCTAssertEqual(report.holes, 0)
        XCTAssertEqual(report.late, 0)
    }

    // MARK: - Delay

    func testStallShowsAsDelayOfItsLength() {
        var stats = AudioArrivalStats(sampleRate: rate)
        // 100 on-time payloads, then 30 held back by a 165 ms stall and
        // released together — the pattern measured on the headset's link.
        for i in 0..<130 {
            let index = UInt64(i * frames)
            let arrival = i < 100 ? nanos(forFrame: index) : nanos(forFrame: UInt64(100 * frames), lateMs: 165)
            _ = stats.record(stamp: PCMStamp(sampleIndex: index), frames: frames, arrivalNanos: arrival)
        }
        let report = stats.takeReport()
        XCTAssertEqual(report.delayP50Ms, 0, accuracy: 0.5)
        XCTAssertEqual(report.delayMaxMs, 165, accuracy: 0.5)
        XCTAssertGreaterThan(report.delayP95Ms, 50)
    }

    func testTakeReportStartsANewWindow() {
        var stats = AudioArrivalStats(sampleRate: rate)
        _ = stats.record(stamp: PCMStamp(sampleIndex: 0), frames: frames, arrivalNanos: nanos(forFrame: 0))
        _ = stats.record(stamp: PCMStamp(sampleIndex: UInt64(2 * frames)), frames: frames, arrivalNanos: nanos(forFrame: 0, lateMs: 50))
        XCTAssertEqual(stats.takeReport().holes, 1)
        let next = stats.takeReport()
        XCTAssertEqual(next, AudioArrivalStats.Report())
    }
}
