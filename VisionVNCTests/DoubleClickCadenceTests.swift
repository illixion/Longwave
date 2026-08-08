import XCTest
@testable import VisionVNC

final class DoubleClickCadenceTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)

    func testFirstClickPassesThroughUnchanged() {
        var cadence = DoubleClickCadence()
        let point = cadence.resolve((x: 400, y: 300), now: origin)
        XCTAssertEqual(point.x, 400)
        XCTAssertEqual(point.y, 300)
    }

    /// The case that made double-clicking impossible: a second tap that drifted
    /// further than the host's 4 px proximity rule allows.
    func testQuickSecondClickSnapsToTheFirst() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        let second = cadence.resolve((x: 418, y: 289), now: origin.addingTimeInterval(0.18))
        XCTAssertEqual(second.x, 400)
        XCTAssertEqual(second.y, 300)
    }

    /// A third quick tap must land on the same anchor too, or triple-click
    /// (select-paragraph, select-line) breaks.
    func testThirdQuickClickKeepsTheSameAnchor() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        _ = cadence.resolve((x: 415, y: 310), now: origin.addingTimeInterval(0.15))
        let third = cadence.resolve((x: 430, y: 320), now: origin.addingTimeInterval(0.30))
        XCTAssertEqual(third.x, 400)
        XCTAssertEqual(third.y, 300)
    }

    func testSlowSecondClickIsLeftWhereItLanded() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        let second = cadence.resolve((x: 404, y: 302), now: origin.addingTimeInterval(0.9))
        XCTAssertEqual(second.x, 404)
        XCTAssertEqual(second.y, 302)
    }

    /// Deliberately clicking somewhere else must not be dragged back to the
    /// previous target just because it was quick.
    func testDistantSecondClickIsLeftWhereItLanded() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        let second = cadence.resolve((x: 900, y: 300), now: origin.addingTimeInterval(0.1))
        XCTAssertEqual(second.x, 900)
        XCTAssertEqual(second.y, 300)
    }

    /// After a far-away click, the anchor must follow — otherwise a later
    /// double-click there would snap back to a stale point.
    func testAnchorMovesAfterANonSnappedClick() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        _ = cadence.resolve((x: 900, y: 300), now: origin.addingTimeInterval(0.1))
        let third = cadence.resolve((x: 910, y: 305), now: origin.addingTimeInterval(0.2))
        XCTAssertEqual(third.x, 900)
        XCTAssertEqual(third.y, 300)
    }

    func testResetForgetsTheAnchor() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 400, y: 300), now: origin)
        cadence.reset()
        let next = cadence.resolve((x: 410, y: 305), now: origin.addingTimeInterval(0.1))
        XCTAssertEqual(next.x, 410)
        XCTAssertEqual(next.y, 305)
    }

    /// UInt16 coordinates near the origin must not underflow when the deltas
    /// are computed.
    func testNoUnderflowNearTheOrigin() {
        var cadence = DoubleClickCadence()
        _ = cadence.resolve((x: 2, y: 1), now: origin)
        let second = cadence.resolve((x: 30, y: 20), now: origin.addingTimeInterval(0.1))
        XCTAssertEqual(second.x, 2)
        XCTAssertEqual(second.y, 1)
    }
}
