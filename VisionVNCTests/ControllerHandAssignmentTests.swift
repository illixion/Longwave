import XCTest
import simd
@testable import VisionVNC

/// Coverage for working out which hand holds the physical controller.
///
/// `ControllerHandDetector` is deliberately flag-free and takes plain angular speeds, so
/// the whole decision is testable without a headset, a controller, or an IMU — which is
/// the point, since the thing it decides is only observable on hardware. Each test feeds a
/// synthetic motion trace and asserts the verdict.
final class ControllerHandAssignmentTests: XCTestCase {

    /// Feed `ticks` samples at 83 Hz. Speeds are in rad/s; nil = that wrist untracked.
    private func run(_ detector: inout ControllerHandDetector,
                     ticks: Int,
                     controller: Float,
                     left: Float?,
                     right: Float?,
                     startAt: Double = 1000) -> ControllerHolder {
        var verdict = detector.holder
        for i in 0..<ticks {
            verdict = detector.update(controllerSpeed: controller,
                                      leftWristSpeed: left,
                                      rightWristSpeed: right,
                                      now: startAt + Double(i) * (1.0 / 83.0))
        }
        return verdict
    }

    // MARK: The three real grips

    func testTwoHandedGripClaimsBothHands() {
        // A gamepad held in both hands: both wrists rotate with it.
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 2.0)
        XCTAssertEqual(verdict, .both)
        XCTAssertTrue(verdict.claimsLeft)
        XCTAssertTrue(verdict.claimsRight)
    }

    func testHeldInRightHandOnly() {
        // Wand grip: the right wrist tracks the controller, the left is still.
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: 0.05, right: 2.0)
        XCTAssertEqual(verdict, .right)
        XCTAssertFalse(verdict.claimsLeft)
        XCTAssertTrue(verdict.claimsRight)
    }

    func testHeldInLeftHandOnly() {
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 0.05)
        XCTAssertEqual(verdict, .left)
        XCTAssertTrue(verdict.claimsLeft)
        XCTAssertFalse(verdict.claimsRight)
    }

    // MARK: Refusing to guess

    func testControllerMovingWithNeitherHandIsUnknown() {
        /* On a desk being pressed, or in a lap. Both wrists disagree, so there is no
           honest answer — and `unknown` sends no gyro rather than picking a hand. */
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 3.0, left: 0.0, right: 0.0)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertFalse(verdict.claimsLeft)
        XCTAssertFalse(verdict.claimsRight)
    }

    func testStillControllerYieldsNoVerdict() {
        // Below the motion threshold nothing is learned: every hand "agrees" with a
        // stationary controller, so those samples are discarded rather than counted.
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 200, controller: 0.1, left: 0.1, right: 3.0)
        XCTAssertEqual(verdict, .unknown, "a motionless controller must not produce a verdict")
        XCTAssertNil(d.leftScore)
    }

    func testTooFewSamplesYieldsNoVerdict() {
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: ControllerHandDetector.minSamples - 1,
                          controller: 2.0, left: 2.0, right: 0.0)
        XCTAssertEqual(verdict, .unknown)
    }

    func testNearTieDoesNotSplitTheHands() {
        /* Both wrists agree closely. Picking the marginally better one would be a coin
           toss dressed as a measurement, and would make the IMU flap between hands. */
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 1.95)
        XCTAssertEqual(verdict, .both)
    }

    // MARK: Tracking dropouts

    func testUntrackedHandCannotWin() {
        // The right wrist is untracked throughout; only the left can be judged.
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: 2.0, right: nil)
        XCTAssertEqual(verdict, .left)
        XCTAssertNil(d.rightScore, "an untracked wrist must not be scored")
    }

    func testBothHandsUntrackedIsUnknown() {
        var d = ControllerHandDetector()
        let verdict = run(&d, ticks: 60, controller: 2.0, left: nil, right: nil)
        XCTAssertEqual(verdict, .unknown)
    }

    func testVerdictSurvivesAStillPeriod() {
        /* The window ages by time, but a verdict is held rather than recomputed once the
           samples drain — the user stopping moving must not un-decide which hand they are
           holding the thing in. */
        var d = ControllerHandDetector()
        XCTAssertEqual(run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 0.0), .left)
        let after = run(&d, ticks: 200, controller: 0.0, left: 0.0, right: 0.0, startAt: 1010)
        XCTAssertEqual(after, .left, "a still controller must not erase the verdict")
    }

    func testSwappingHandsIsNoticed() {
        var d = ControllerHandDetector()
        XCTAssertEqual(run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 0.0), .left)
        // Move it to the right hand; the old samples age out of the 1.5 s window.
        let after = run(&d, ticks: 200, controller: 2.0, left: 0.0, right: 2.0, startAt: 1010)
        XCTAssertEqual(after, .right)
    }

    func testResetClearsEverything() {
        var d = ControllerHandDetector()
        XCTAssertEqual(run(&d, ticks: 60, controller: 2.0, left: 2.0, right: 0.0), .left)
        d.reset()
        XCTAssertEqual(d.holder, .unknown)
        XCTAssertNil(d.leftScore)
        XCTAssertNil(d.rightScore)
    }

    // MARK: Scale independence
    //
    // The score normalises by the window's mean controller speed, which is what lets one
    // threshold cover a slow wrist turn and a fast swing. An absolute rad/s tolerance
    // would reject the first or accept everything in the second.

    func testSlowAndFastMotionDecideTheSameWay() {
        for speed in [Float(0.5), 2.0, 12.0] {
            var d = ControllerHandDetector()
            let verdict = run(&d, ticks: 60, controller: speed,
                              left: speed, right: speed * 0.02)
            XCTAssertEqual(verdict, .left,
                           "at \(speed) rad/s the left hand is the one moving with it")
        }
    }

    // MARK: angularSpeed

    func testAngularSpeedOfNoRotationIsZero() {
        let q = simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(ControllerHandDetector.angularSpeed(from: q, to: q, dt: 0.012) ?? -1,
                       0, accuracy: 1e-4)
    }

    func testAngularSpeedMatchesAKnownRotation() {
        // 0.5 rad about Y over 0.25 s = 2 rad/s.
        let a = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let b = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        let speed = ControllerHandDetector.angularSpeed(from: a, to: b, dt: 0.25)
        XCTAssertEqual(speed ?? -1, 2.0, accuracy: 1e-3)
    }

    func testAngularSpeedIsAxisIndependent() {
        // The same rotation magnitude about different axes must give the same speed —
        // this is the property that lets a wrist be compared to an unaligned IMU.
        let angle: Float = 0.4
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        var speeds: [Float] = []
        for axis in [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1),
                     simd_normalize(SIMD3<Float>(1, 1, 1))] {
            let rotated = simd_quatf(angle: angle, axis: axis)
            speeds.append(ControllerHandDetector.angularSpeed(
                from: identity, to: rotated, dt: 0.1) ?? -1)
        }
        for s in speeds { XCTAssertEqual(s, speeds[0], accuracy: 1e-3) }
    }

    func testAngularSpeedIgnoresQuaternionSign() {
        /* q and -q are the same rotation. Without taking the short way round, a hand whose
           quaternion crossed the antipode would read as a 2-pi flick — a spurious huge
           speed arriving exactly during fast motion, when it would be most believed. */
        let a = simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 1, 0))
        let negated = simd_quatf(vector: -a.vector)
        XCTAssertEqual(ControllerHandDetector.angularSpeed(from: a, to: negated, dt: 0.1) ?? -1,
                       0, accuracy: 1e-3)
    }

    func testAngularSpeedRejectsAZeroInterval() {
        let q = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        XCTAssertNil(ControllerHandDetector.angularSpeed(from: q, to: q, dt: 0))
        XCTAssertNil(ControllerHandDetector.angularSpeed(from: q, to: q, dt: -1))
    }

    // MARK: Preference

    func testPreferenceForcesAHolder() {
        XCTAssertNil(ControllerHandPreference.auto.forced)
        XCTAssertEqual(ControllerHandPreference.both.forced, .both)
        XCTAssertEqual(ControllerHandPreference.left.forced, .left)
        XCTAssertEqual(ControllerHandPreference.right.forced, .right)
    }

    func testHolderClaims() {
        XCTAssertEqual(ControllerHolder.both.claimsLeft, true)
        XCTAssertEqual(ControllerHolder.both.claimsRight, true)
        XCTAssertEqual(ControllerHolder.left.claimsLeft, true)
        XCTAssertEqual(ControllerHolder.left.claimsRight, false)
        XCTAssertEqual(ControllerHolder.right.claimsLeft, false)
        XCTAssertEqual(ControllerHolder.right.claimsRight, true)
        XCTAssertEqual(ControllerHolder.unknown.claimsLeft, false)
        XCTAssertEqual(ControllerHolder.unknown.claimsRight, false)
    }
}
