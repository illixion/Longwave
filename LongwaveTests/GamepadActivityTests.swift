import RAVEInput
import XCTest
@testable import Longwave

final class GamepadActivityTests: XCTestCase {

    func testRepeatedReadingsAreNotChanges() {
        var activity = GamepadActivity()
        let still = RAVEGamepadSnapshot(rotationRate: SIMD3(0.02, 0, 0), acceleration: SIMD3(0, 0, -1))
        for t in 0..<10 { activity.record(still, at: TimeInterval(t)) }
        XCTAssertEqual(activity.inputChanges, 0)
        XCTAssertEqual(activity.motionChanges, 0)
        XCTAssertNil(activity.secondsSinceMotionChange(now: 10), "a frozen reading never counts as live")
        XCTAssertEqual(activity.gyroTrace.count, 10)
    }

    func testInputAndMotionAreTrackedApart() {
        var activity = GamepadActivity()
        activity.record(RAVEGamepadSnapshot(), at: 0)
        activity.record(RAVEGamepadSnapshot(leftStick: SIMD2(1, 0)), at: 1)
        activity.record(RAVEGamepadSnapshot(leftStick: SIMD2(1, 0), rotationRate: SIMD3(0, 1, 0)), at: 2)
        XCTAssertEqual(activity.inputChanges, 1)
        XCTAssertEqual(activity.motionChanges, 1)
        XCTAssertEqual(activity.secondsSinceInputChange(now: 5), 4)
        XCTAssertEqual(activity.secondsSinceMotionChange(now: 5), 3)
    }

    func testTraceKeepsTheNewestSamples() {
        var activity = GamepadActivity()
        for t in 0..<(GamepadActivity.traceLength + 30) {
            activity.record(RAVEGamepadSnapshot(rotationRate: SIMD3(Float(t), 0, 0)), at: TimeInterval(t))
        }
        XCTAssertEqual(activity.gyroTrace.count, GamepadActivity.traceLength)
        XCTAssertEqual(activity.gyroTrace.last?.x, Float(GamepadActivity.traceLength + 29))
    }
}
