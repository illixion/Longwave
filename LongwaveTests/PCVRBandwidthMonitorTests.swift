import XCTest
@testable import Longwave

/// The bandwidth counter is monthly and host-persisted, unlike the trial clock
/// this otherwise mirrors — which means its WARNING/STOP flags stay set for the
/// rest of the month once crossed, not just for the session that crossed them.
/// These tests exist because of one specific failure mode a naive level-triggered
/// `advance` reproduces: a reconnect made specifically to raise the limit or hit
/// Reset getting auto-disconnected within a second, because the flag never
/// cleared from the *previous* session. See `PCVRBandwidthMonitor`'s header.
///
/// Gated with the feature — PCVR, and therefore this monitor, only exists in the
/// App Store edition.
#if FOVEATED_ENABLED
final class PCVRBandwidthMonitorTests: XCTestCase {

    private func packet(enabled: Bool = true, warning: Bool = false, stop: Bool = false,
                        usedGB: Float = 0, warningThresholdGB: Float = 60,
                        stopThresholdGB: Float = 90) -> ControllerBridgeBandwidth {
        var flags: ControllerBridgeBandwidth.Flags = []
        if enabled { flags.insert(.enabled) }
        if warning { flags.insert(.warning) }
        if stop { flags.insert(.stop) }
        return ControllerBridgeBandwidth(flags: flags, usedGB: usedGB,
                                         warningThresholdGB: warningThresholdGB,
                                         stopThresholdGB: stopThresholdGB)
    }

    // MARK: The bug this file exists to pin down

    /// A session that begins already over the cap (a reconnect after a previous
    /// session crossed it) must NOT be auto-disconnected — that would make the
    /// Reset button, which only renders while connected, permanently unreachable
    /// for the rest of the month.
    func testReconnectAfterCapDoesNotAutoDisconnect() {
        let monitor = PCVRBandwidthMonitor()
        let shouldEnd = monitor.advance(disconnected: false,
                                        bandwidth: packet(stop: true, usedGB: 95),
                                        now: 1_000)
        XCTAssertFalse(shouldEnd, "a session that starts over the cap must be left connected")
        XCTAssertTrue(monitor.isOverStopThreshold, "the panel still needs to know the cap is reached")
    }

    /// A fresh crossing *during* an active session is the one case that should
    /// actually end the stream — and only once, even though the flag then stays
    /// set for every subsequent tick this session.
    func testFreshCrossingEndsSessionExactlyOnce() {
        let monitor = PCVRBandwidthMonitor()
        XCTAssertFalse(monitor.advance(disconnected: false,
                                       bandwidth: packet(usedGB: 85), now: 1_000),
                       "below the cap: nothing should fire")
        XCTAssertTrue(monitor.advance(disconnected: false,
                                      bandwidth: packet(stop: true, usedGB: 91), now: 1_001),
                     "the tick that crosses the cap should fire exactly once")
        XCTAssertFalse(monitor.advance(disconnected: false,
                                       bandwidth: packet(stop: true, usedGB: 92), now: 1_002),
                      "must not fire again on a later tick, even though the flag is still set")
    }

    /// Resetting the counter mid-session (dropping usage back below the cap) and
    /// then crossing it again for real must fire again — this is a genuinely new
    /// crossing, not a repeat of the first one.
    func testCrossingAgainAfterAMidSessionResetFiresAgain() {
        let monitor = PCVRBandwidthMonitor()
        // Prime with a below-cap tick first — a fresh session that starts already
        // capped gets the grace policy tested above, not an auto-fire.
        _ = monitor.advance(disconnected: false, bandwidth: packet(usedGB: 85), now: 999)
        XCTAssertTrue(monitor.advance(disconnected: false,
                                      bandwidth: packet(stop: true, usedGB: 91), now: 1_000))
        // The counter was reset (host applied a reset command) and usage is now low.
        XCTAssertFalse(monitor.advance(disconnected: false,
                                       bandwidth: packet(usedGB: 2), now: 1_001))
        XCTAssertTrue(monitor.advance(disconnected: false,
                                      bandwidth: packet(stop: true, usedGB: 91), now: 1_002),
                     "a genuinely new crossing in the same session must fire again")
    }

    // MARK: Level vs. edge state

    func testDisabledMonitoringClearsDisplayState() {
        let monitor = PCVRBandwidthMonitor()
        _ = monitor.advance(disconnected: false, bandwidth: packet(usedGB: 50), now: 1_000)
        XCTAssertNotNil(monitor.usedGB)
        _ = monitor.advance(disconnected: false, bandwidth: packet(enabled: false), now: 1_001)
        XCTAssertNil(monitor.usedGB)
        XCTAssertFalse(monitor.isOverStopThreshold)
    }

    func testNilPacketNeverFiresAStop() {
        let monitor = PCVRBandwidthMonitor()
        XCTAssertFalse(monitor.advance(disconnected: false, bandwidth: nil, now: 1_000))
    }

    func testDisconnectResetsAllState() {
        let monitor = PCVRBandwidthMonitor()
        _ = monitor.advance(disconnected: false, bandwidth: packet(stop: true, usedGB: 95), now: 1_000)
        XCTAssertTrue(monitor.isOverStopThreshold)
        _ = monitor.advance(disconnected: true, bandwidth: nil, now: 1_001)
        XCTAssertFalse(monitor.isOverStopThreshold)
        XCTAssertNil(monitor.usedGB)
    }

    // MARK: Warning banner

    func testWarningBannerFiresOnceThenClearsItself() {
        let monitor = PCVRBandwidthMonitor()
        _ = monitor.advance(disconnected: false, bandwidth: packet(warning: true, usedGB: 65), now: 1_000)
        XCTAssertEqual(monitor.bannerKind, .warning)
        _ = monitor.advance(disconnected: false, bandwidth: packet(warning: true, usedGB: 66),
                            now: 1_000 + PCVRBandwidthMonitor.bannerDuration + 1)
        XCTAssertNil(monitor.bannerKind, "the banner should fade on its own")
    }

    func testWarningReachedAtConnectStillFiresOnce() {
        // Unlike the stop threshold, a warning reached at connect is informational
        // only — it should still surface once, not be suppressed the way a
        // born-capped stop is.
        let monitor = PCVRBandwidthMonitor()
        _ = monitor.advance(disconnected: false, bandwidth: packet(warning: true, usedGB: 65), now: 1_000)
        XCTAssertEqual(monitor.bannerKind, .warning)
    }
}
#endif
