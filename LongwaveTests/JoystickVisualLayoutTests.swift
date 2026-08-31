import XCTest
import simd
import RAVEInput
@testable import Longwave

/// `JoystickVisualLayout` is the pure geometry FoveatedImmersiveView hands to its
/// RealityKit entities each frame — see JoystickVisualLayout.swift for why it is split
/// out from the RealityKit code at all. Gated with the feature, same as
/// PCVRSessionLimiterTests: this file only exists inside the PCVR/foveated build.
#if FOVEATED_ENABLED
final class JoystickVisualLayoutTests: XCTestCase {

    /// A visualization with the hand still at the anchor: engaged, but no deflection
    /// yet. `center` is offset from the world origin deliberately, so a test that
    /// forgot to subtract it back out would fail rather than pass by coincidence.
    private func visualization(
        handleOffset: SIMD3<Float> = .zero,
        deadzoneMeters: Float = 0.03,
        fullScaleMeters: Float = 0.18
    ) -> RAVEJoystickVisualization {
        let center = SIMD3<Float>(1, 1.2, -2)
        let basis = RAVEPlanarBasis(forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
        return RAVEJoystickVisualization(
            center: center,
            handle: center + handleOffset,
            basis: basis,
            deadzoneMeters: deadzoneMeters,
            fullScaleMeters: fullScaleMeters,
            value: .zero)
    }

    func testFullScaleDiameterIsTwiceTheRadius() {
        let layout = JoystickVisualLayout(visualization(fullScaleMeters: 0.2))
        XCTAssertEqual(layout.fullScaleDiameter, 0.4, accuracy: 1e-6)
    }

    /// A zero or negative full-scale radius must never collapse the disc to nothing —
    /// that would make the joystick invisible right when it most needs explaining.
    func testFullScaleDiameterIsFlooredAgainstZero() {
        let layout = JoystickVisualLayout(visualization(fullScaleMeters: 0))
        XCTAssertGreaterThan(layout.fullScaleDiameter, 0)
    }

    func testDeadzoneDiameterMatchesWhenAboveTheMinimum() {
        let layout = JoystickVisualLayout(visualization(deadzoneMeters: 0.03))
        guard let deadzoneDiameter = layout.deadzoneDiameter else {
            return XCTFail("expected a deadzone disc above the drawable minimum")
        }
        XCTAssertEqual(deadzoneDiameter, 0.06, accuracy: 1e-6)
    }

    /// Below the drawable minimum the deadzone disc must not appear at all — a sliver
    /// that flickers in and out at the rounding boundary is worse than nothing.
    func testDeadzoneDiameterIsNilBelowTheMinimum() {
        let layout = JoystickVisualLayout(visualization(deadzoneMeters: 0.001))
        XCTAssertNil(layout.deadzoneDiameter)
    }

    func testDeadzoneDiameterIsNilWhenZero() {
        let layout = JoystickVisualLayout(visualization(deadzoneMeters: 0))
        XCTAssertNil(layout.deadzoneDiameter)
    }

    /// No deflection at all: the handle sits on center and the stick must not draw a
    /// zero-length sliver either.
    func testHandleAtCenterHasNoStick() {
        let layout = JoystickVisualLayout(visualization(handleOffset: .zero))
        XCTAssertEqual(layout.handleOffset, .zero)
        XCTAssertNil(layout.stick)
    }

    /// A real deflection along +right must read as a positive x handle offset, and the
    /// stick must span exactly that distance.
    func testHandleOffsetAndStickLengthMatchADeflectionAlongRight() {
        let offset = SIMD3<Float>(0.1, 0, 0)
        let layout = JoystickVisualLayout(visualization(handleOffset: offset))
        XCTAssertEqual(layout.handleOffset, offset, accuracy: 1e-6)
        guard let stick = layout.stick else {
            return XCTFail("expected a stick for a non-zero deflection")
        }
        XCTAssertEqual(stick.length, 0.1, accuracy: 1e-6)
        XCTAssertEqual(stick.midpoint, SIMD3(0.05, 0, 0), accuracy: 1e-6)
    }

    /// The offset is defensively flattened to the horizontal plane even if the input
    /// (which the API contract says never happens) carried a vertical component.
    func testHandleOffsetIgnoresAnyVerticalComponent() {
        let layout = JoystickVisualLayout(visualization(handleOffset: SIMD3(0.1, 0.5, 0)))
        XCTAssertEqual(layout.handleOffset.y, 0)
    }

    /// A stick's orientation must actually rotate the unit +Y axis onto the deflection
    /// direction — that is the whole point of computing it, and a bug that flips or
    /// zeroes it would only be caught by checking the rotated vector, not just that
    /// `stick` is non-nil.
    func testStickOrientationPointsFromUpToTheDeflectionDirection() {
        let direction = SIMD3<Float>(0, 0, -1)
        let layout = JoystickVisualLayout(visualization(handleOffset: direction * 0.1))
        guard let stick = layout.stick else {
            return XCTFail("expected a stick")
        }
        let rotated = stick.orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(rotated, direction, accuracy: 1e-5)
    }

    /// A deflection right at the drawable-minimum boundary must not produce a stick —
    /// same "don't flicker at the threshold" rule as the deadzone disc.
    func testTinyDeflectionBelowMinimumStickLengthHasNoStick() {
        let layout = JoystickVisualLayout(visualization(handleOffset: SIMD3(0.0005, 0, 0)))
        XCTAssertNil(layout.stick)
    }
}

private func XCTAssertEqual(
    _ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, accuracy: Float,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
}
#endif
