import XCTest
@testable import Longwave

/// The wrist HUD's eye-tracking verdict. Each broken link in the gaze chain has
/// its own wording, and the first broken one is the one named.
#if FOVEATED_ENABLED
final class PCVRGazeHealthTests: XCTestCase {

    private func uplink(offered: Bool = true, negotiated: Bool = true, rate: Double = 60,
                        foveated: Bool = true) -> PCVRGazeUplink {
        PCVRGazeUplink(offered: offered, negotiated: negotiated, posesPerSecond: rate, foveated: foveated,
                       centres: [0.5, 0.5, 0.5, 0.5])
    }

    private func health(feed: Bool = true, since: TimeInterval? = 0.02, rate: Double = 60,
                        uplink: PCVRGazeUplink?, centreMoved: TimeInterval? = 0.5) -> PCVRGazeHealth {
        PCVRGazeHealth.evaluate(hasFeed: feed, sinceNewSample: since, feedRate: rate,
                                uplink: uplink, sinceCentreMoved: centreMoved)
    }

    func testWholeChainWorking() {
        let h = health(uplink: uplink())
        XCTAssertEqual(h.level, .ok)
        XCTAssertEqual(h.verdict, "Gaze is reaching the PC.")
        XCTAssertEqual(h.hops.map(\.level), [.ok, .ok, .ok])
    }

    func testNoFeed() {
        let h = health(feed: false, since: nil, uplink: uplink(rate: 0))
        XCTAssertEqual(h.level, .broken)
        XCTAssertEqual(h.verdict, "No gaze source is running.")
    }

    func testFeedWithoutSamples() {
        let h = health(since: nil, uplink: nil)
        XCTAssertEqual(h.level, .broken)
        XCTAssertTrue(h.verdict.contains("no samples"))
    }

    func testFeedWentSilent() {
        let h = health(since: 14, uplink: uplink(rate: 0))
        XCTAssertEqual(h.level, .broken)
        XCTAssertEqual(h.verdict, "Gaze stopped 14 s ago.")
        XCTAssertEqual(h.hops[0].detail, "silent 14 s")
    }

    func testLiveWithoutAStream() {
        let h = health(uplink: nil)
        XCTAssertEqual(h.level, .ok)
        XCTAssertTrue(h.verdict.contains("No PC stream"))
        XCTAssertEqual(h.hops[1].level, .idle)
    }

    func testNotOffered() {
        let h = health(uplink: uplink(offered: false, negotiated: false, rate: 0))
        XCTAssertEqual(h.level, .broken)
        XCTAssertEqual(h.verdict, "The PC stream started without gaze.")
    }

    func testDeclinedByThePC() {
        let h = health(uplink: uplink(negotiated: false, rate: 0))
        XCTAssertEqual(h.level, .broken)
        XCTAssertTrue(h.verdict.contains("did not accept gaze"))
    }

    func testAcceptedButPosesCarryNone() {
        let h = health(uplink: uplink(rate: 0))
        XCTAssertEqual(h.level, .broken)
        XCTAssertTrue(h.verdict.contains("no pose carries"))
    }

    func testPCNotFoveating() {
        let h = health(uplink: uplink(foveated: false))
        XCTAssertEqual(h.level, .warning)
        XCTAssertTrue(h.verdict.contains("not foveating"))
    }

    func testCentreStandingStill() {
        let h = health(uplink: uplink(), centreMoved: 9)
        XCTAssertEqual(h.level, .warning)
        XCTAssertEqual(h.hops[2].detail, "still 9 s")
    }

    func testFeedBreakIsNamedBeforeALaterHop() {
        // Silent feed and the PC declined: the first link is the one reported.
        let h = health(since: 30, uplink: uplink(negotiated: false, rate: 0))
        XCTAssertEqual(h.verdict, "Gaze stopped 30 s ago.")
        XCTAssertEqual(h.hops[1].level, .broken)
        XCTAssertEqual(h.hops[2].level, .idle)
    }

    // MARK: Watch

    func testWatchRateFromSequenceCounter() {
        var watch = PCVRGazeWatch()
        for i in 0...10 { watch.observe(sequence: i * 6, centres: nil, now: Double(i) * 0.1) }
        XCTAssertEqual(watch.sampleRate(), 60, accuracy: 0.01)
        XCTAssertEqual(watch.sinceNewSample(now: 1.0)!, 0, accuracy: 1e-9)
    }

    func testWatchSeesAFeedStop() {
        var watch = PCVRGazeWatch()
        for i in 0...5 { watch.observe(sequence: i, centres: nil, now: Double(i) * 0.1) }
        for i in 6...30 { watch.observe(sequence: 5, centres: nil, now: Double(i) * 0.1) }
        XCTAssertEqual(watch.sinceNewSample(now: 3.0)!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(watch.sampleRate(), 0, accuracy: 1e-9)
    }

    func testWatchForgetsWhenTheFeedGoes() {
        var watch = PCVRGazeWatch()
        watch.observe(sequence: 1, centres: nil, now: 0)
        watch.observe(sequence: nil, centres: nil, now: 1)
        XCTAssertNil(watch.sinceNewSample(now: 2))
    }

    func testWatchCentreMoves() {
        var watch = PCVRGazeWatch()
        watch.observe(sequence: nil, centres: [0.5, 0.5, 0.5, 0.5], now: 0)
        watch.observe(sequence: nil, centres: [0.5005, 0.5, 0.5, 0.5], now: 1) // pixel snapping, not a move
        XCTAssertEqual(watch.sinceCentreMoved(now: 2)!, 2, accuracy: 1e-9)
        watch.observe(sequence: nil, centres: [0.6, 0.5, 0.5, 0.5], now: 2)
        XCTAssertEqual(watch.sinceCentreMoved(now: 2.5)!, 0.5, accuracy: 1e-9)
    }
}
#endif
