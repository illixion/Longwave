import XCTest
@testable import StreamWire

/// The golden cases of the headset's `PCVRGazeProjectionTests`, on the wire
/// types the host projects with: both sides must place the warp centre alike.
final class GazeProjectionTests: XCTestCase {
    private func fov(left: Float = -1, right: Float = 1, up: Float = 1, down: Float = -1) -> FieldOfView {
        FieldOfView(angleLeft: atanf(left), angleRight: atanf(right), angleUp: atanf(up), angleDown: atanf(down))
    }

    private func eye(x: Float = 0, yaw: Float = 0) -> Pose {
        Pose(orientation: Quaternion(x: 0, y: sinf(yaw / 2), z: 0, w: cosf(yaw / 2)), position: Vector3(x, 0, 0))
    }

    private func centre(_ direction: Vector3, distance: Float = 0, eye pose: Pose? = nil,
                        fov view: FieldOfView? = nil) -> NormalizedPoint? {
        GazeProjection.centre(direction: direction, distance: distance, deviceFromEye: pose ?? eye(),
                              fieldOfView: view ?? fov())
    }

    func testAsymmetricFrustaHaveDifferentForwardCentres() throws {
        let left = try XCTUnwrap(centre(Vector3(0, 0, -1), eye: eye(x: -0.032), fov: fov(left: -1.2, right: 0.8)))
        let right = try XCTUnwrap(centre(Vector3(0, 0, -1), eye: eye(x: 0.032), fov: fov(left: -0.8, right: 1.2)))
        XCTAssertEqual(left.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(right.x, 0.4, accuracy: 1e-6)
        XCTAssertEqual(left.y, 0.5, accuracy: 1e-6)
    }

    func testFiniteFocusUsesEyeOffsetsAndUnknownDepthDoesNot() throws {
        let l = try XCTUnwrap(centre(Vector3(0, 0, -2), distance: 1, eye: eye(x: -0.032)))
        let r = try XCTUnwrap(centre(Vector3(0, 0, -2), distance: 1, eye: eye(x: 0.032)))
        XCTAssertEqual(l.x, 0.516, accuracy: 1e-6)
        XCTAssertEqual(r.x, 0.484, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(centre(Vector3(0, 0, -1), eye: eye(x: -0.032))).x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(centre(Vector3(0, 0, -1), eye: eye(x: 0.032))).x, 0.5, accuracy: 1e-6)
    }

    func testEyeRotationAndTopLeftCoordinates() throws {
        // An eye yawed 30 degrees left, looking along its own axis, sees the gaze at its centre.
        let yaw: Float = .pi / 6
        let ahead = Vector3(-sinf(yaw), 0, -cosf(yaw))
        let rotated = try XCTUnwrap(centre(ahead, eye: eye(yaw: yaw)))
        XCTAssertEqual(rotated.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(rotated.y, 0.5, accuracy: 1e-6)
        let upRight = try XCTUnwrap(centre(Vector3(0.5, 0.5, -1)))
        XCTAssertEqual(upRight.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(upRight.y, 0.25, accuracy: 1e-6)
    }

    func testInvalidAndBehindEyeGazeIsRejectedAndOffscreenClamps() throws {
        for direction in [Vector3.zero, Vector3(.nan, 0, -1), Vector3(0, 0, 1), Vector3(1, 0, 0)] {
            XCTAssertNil(centre(direction))
        }
        XCTAssertNil(centre(Vector3(0, 0, -1), distance: -1))
        XCTAssertNil(centre(Vector3(0, 0, -1), distance: .infinity))
        let clamped = try XCTUnwrap(centre(Vector3(20, 20, -1)))
        XCTAssertEqual(clamped.x, 1)
        XCTAssertEqual(clamped.y, 0)
    }

    func testRotateMatchesTheQuaternionSandwich() throws {
        let q = try XCTUnwrap(Quaternion(x: 0.1, y: -0.3, z: 0.2, w: 0.9).normalized)
        let v = Vector3(0.3, -0.7, 0.5)
        // q v q*, written out with the Hamilton product.
        func multiply(_ a: Quaternion, _ b: Quaternion) -> Quaternion {
            Quaternion(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                       y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                       z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                       w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
        }
        let sandwich = multiply(multiply(q, Quaternion(x: v.x, y: v.y, z: v.z, w: 0)), q.conjugate)
        let rotated = q.rotate(v)
        XCTAssertEqual(rotated.x, sandwich.x, accuracy: 1e-6)
        XCTAssertEqual(rotated.y, sandwich.y, accuracy: 1e-6)
        XCTAssertEqual(rotated.z, sandwich.z, accuracy: 1e-6)
    }
}
