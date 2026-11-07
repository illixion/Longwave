import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
final class PCVRGazeProjectionTests: XCTestCase {
    private func eye(x: Float = 0, rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                     left: Float = -1, right: Float = 1) -> PCVREyeGeometry {
        PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: rotation, position: SIMD3(x, 0, 0)),
                        fieldOfView: PCVRFieldOfView(tangentLeft: left, tangentRight: right, tangentUp: 1, tangentDown: -1))
    }

    func testAsymmetricFrustaHaveDifferentForwardCentres() throws {
        let left = try XCTUnwrap(eye(x: -0.032, left: -1.2, right: 0.8).gazeCentre(direction: SIMD3(0, 0, -1)))
        let right = try XCTUnwrap(eye(x: 0.032, left: -0.8, right: 1.2).gazeCentre(direction: SIMD3(0, 0, -1)))
        XCTAssertEqual(left.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(right.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(left.y, 0.5)
    }

    func testFiniteFocusUsesEyeOffsetsAndUnknownDepthDoesNot() throws {
        let left = eye(x: -0.032), right = eye(x: 0.032)
        let l = try XCTUnwrap(left.gazeCentre(direction: SIMD3(0, 0, -2), distance: 1))
        let r = try XCTUnwrap(right.gazeCentre(direction: SIMD3(0, 0, -2), distance: 1))
        XCTAssertEqual(l.x, 0.516, accuracy: 1e-6)
        XCTAssertEqual(r.x, 0.484, accuracy: 1e-6)
        XCTAssertEqual(left.gazeCentre(direction: SIMD3(0, 0, -1))?.x, 0.5)
        XCTAssertEqual(right.gazeCentre(direction: SIMD3(0, 0, -1))?.x, 0.5)
    }

    func testEyeRotationAndTopLeftCoordinates() throws {
        let rotation = simd_quatf(angle: .pi / 6, axis: SIMD3(0, 1, 0))
        let centre = try XCTUnwrap(eye(rotation: rotation).gazeCentre(direction: rotation.act(SIMD3(0, 0, -1))))
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-6)
        let upRight = try XCTUnwrap(eye().gazeCentre(direction: SIMD3(0.5, 0.5, -1)))
        XCTAssertEqual(upRight.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(upRight.y, 0.25, accuracy: 1e-6)
    }

    func testInvalidAndBehindEyeGazeIsRejectedAndOffscreenClamps() {
        for direction: SIMD3<Float> in [.zero, SIMD3(.nan, 0, -1), SIMD3(0, 0, 1), SIMD3(1, 0, 0)] {
            XCTAssertNil(eye().gazeCentre(direction: direction))
        }
        XCTAssertNil(eye().gazeCentre(direction: SIMD3(0, 0, -1), distance: -1))
        XCTAssertNil(eye().gazeCentre(direction: SIMD3(0, 0, -1), distance: .infinity))
        XCTAssertEqual(eye().gazeCentre(direction: SIMD3(20, 20, -1))?.x, 1)
        XCTAssertEqual(eye().gazeCentre(direction: SIMD3(20, 20, -1))?.y, 0)
    }
}
#endif
