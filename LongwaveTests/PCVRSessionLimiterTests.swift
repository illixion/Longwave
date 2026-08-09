import XCTest
@testable import Longwave

/// The trial clock is the one piece of Longwave that takes something away from
/// the user, so its edges are worth pinning down: when it counts, when it holds,
/// when it warns, and when it stops. `advance` takes the session state as plain
/// booleans and the time as a parameter, so twenty minutes runs here instantly.
///
/// Gated with the feature — PCVR, and therefore the limit, only exists in the
/// App Store edition.
#if FOVEATED_ENABLED
final class PCVRSessionLimiterTests: XCTestCase {

    /// Steps a limiter forward in one-second ticks, returning the time the limit
    /// was reached (relative to `from`), or nil if it never was.
    @discardableResult
    private func run(_ limiter: PCVRSessionLimiter,
                     seconds: Int,
                     from: TimeInterval = 1_000,
                     streaming: Bool = true,
                     trial: Bool = true) -> TimeInterval? {
        for step in 0...seconds {
            let now = from + TimeInterval(step)
            if limiter.advance(disconnected: false, streaming: streaming, trial: trial, now: now) {
                return TimeInterval(step)
            }
        }
        return nil
    }

    // MARK: Counting

    func testSessionEndsAtTwentyMinutes() {
        let limiter = PCVRSessionLimiter()
        let hit = try? XCTUnwrap(run(limiter, seconds: 25 * 60))
        XCTAssertEqual(hit ?? 0, PCVRSessionLimiter.sessionLimit, accuracy: 2)
    }

    func testRemainingCountsDown() {
        let limiter = PCVRSessionLimiter()
        run(limiter, seconds: 60)
        XCTAssertEqual(limiter.remaining ?? 0, PCVRSessionLimiter.sessionLimit - 60, accuracy: 2)
    }

    /// An unlocked session has no clock at all — not a clock that never expires.
    func testUnlockedNeverCounts() {
        let limiter = PCVRSessionLimiter()
        XCTAssertNil(run(limiter, seconds: 30 * 60, trial: false))
        XCTAssertNil(limiter.remaining)
        XCTAssertEqual(limiter.elapsed, 0)
    }

    /// The same applies before StoreKit has answered: `trial` is false until it
    /// is known to be true, so an unresolved entitlement cannot end a session.
    func testUnresolvedEntitlementDoesNotCount() {
        let limiter = PCVRSessionLimiter()
        XCTAssertNil(run(limiter, seconds: 25 * 60, trial: false))
    }

    // MARK: Pausing

    /// Pausing stops the clock…
    func testPauseHoldsTheClock() {
        let limiter = PCVRSessionLimiter()
        run(limiter, seconds: 300)
        let atPause = limiter.elapsed
        for step in 0...600 {
            limiter.advance(disconnected: false, streaming: false, trial: true, now: 2_000 + TimeInterval(step))
        }
        XCTAssertEqual(limiter.elapsed, atPause, accuracy: 0.01,
                       "paused time must not be charged")
    }

    /// …but does not rewind it. Otherwise pausing every nineteen minutes would
    /// be an unlimited session.
    func testPauseDoesNotRefund() {
        let limiter = PCVRSessionLimiter()
        run(limiter, seconds: 19 * 60)
        limiter.advance(disconnected: false, streaming: false, trial: true, now: 5_000)
        run(limiter, seconds: 5 * 60, from: 6_000)
        XCTAssertGreaterThanOrEqual(limiter.elapsed, PCVRSessionLimiter.sessionLimit - 2)
    }

    /// Disconnecting does rewind it: sessions are unlimited, their length is not.
    func testDisconnectResetsForTheNextSession() {
        let limiter = PCVRSessionLimiter()
        run(limiter, seconds: 15 * 60)
        limiter.advance(disconnected: true, streaming: false, trial: true, now: 5_000)
        XCTAssertEqual(limiter.elapsed, 0)
        XCTAssertNil(limiter.remaining)
        XCTAssertNil(run(limiter, seconds: 19 * 60, from: 6_000),
                     "a fresh session gets the full twenty minutes")
    }

    // MARK: Warnings

    func testBannerRaisedAtEachWarningMark() {
        for mark in PCVRSessionLimiter.warningMarks {
            let limiter = PCVRSessionLimiter()
            let untilMark = Int(PCVRSessionLimiter.sessionLimit - mark)
            run(limiter, seconds: untilMark)
            XCTAssertNotNil(limiter.bannerRemaining,
                            "no banner at \(Int(mark))s remaining")
        }
    }

    func testBannerClearsItself() {
        let limiter = PCVRSessionLimiter()
        let firstMark = PCVRSessionLimiter.warningMarks[0]
        run(limiter, seconds: Int(PCVRSessionLimiter.sessionLimit - firstMark))
        XCTAssertNotNil(limiter.bannerRemaining)
        run(limiter, seconds: Int(PCVRSessionLimiter.bannerDuration) + 5,
            from: 1_000 + PCVRSessionLimiter.sessionLimit - firstMark)
        XCTAssertNil(limiter.bannerRemaining, "banner should fade on its own")
    }

    func testEveryWarningLandsBeforeTheLimit() {
        for mark in PCVRSessionLimiter.warningMarks {
            XCTAssertGreaterThan(mark, 0)
            XCTAssertLessThan(mark, PCVRSessionLimiter.sessionLimit)
        }
        XCTAssertEqual(PCVRSessionLimiter.warningMarks,
                       PCVRSessionLimiter.warningMarks.sorted(by: >),
                       "marks are consumed longest-first")
    }

    // MARK: Suspension

    /// A large jump between ticks means the app was suspended, not that the user
    /// played through it. Charging it would end a session the moment someone
    /// took the headset off and put it back on.
    func testSuspensionIsNotCharged() {
        let limiter = PCVRSessionLimiter()
        limiter.advance(disconnected: false, streaming: true, trial: true, now: 1_000)
        limiter.advance(disconnected: false, streaming: true, trial: true, now: 1_000 + 3_600)
        XCTAssertLessThanOrEqual(limiter.elapsed, 2)
    }

    // MARK: Formatting

    func testClockFormatting() {
        XCTAssertEqual(PCVRSessionLimiter.clock(300), "5:00")
        XCTAssertEqual(PCVRSessionLimiter.clock(61), "1:01")
        XCTAssertEqual(PCVRSessionLimiter.clock(9), "0:09")
        XCTAssertEqual(PCVRSessionLimiter.clock(0), "0:00")
    }
}
#endif
