import XCTest
import simd
import StreamWire
@testable import Longwave

#if FOVEATED_ENABLED
final class PCVRMetadataTests: XCTestCase {
    private let sample = PCVRGazeSample(direction: SIMD3(1, 0, -2), distance: 2,
                                      timestamp: 10, isValid: true)

    func testGazeRequiresFreshSampleNegotiationAndClock() {
        func wire(_ sample: PCVRGazeSample, now: Double = 10.05, negotiated: Bool = true) -> GazeSample? {
            sample.wireSample(now: now, negotiated: negotiated) { UInt64($0 * 1e9) + 500 }
        }
        XCTAssertNil(wire(.invalid))
        XCTAssertNil(wire(sample, negotiated: false))
        XCTAssertNil(wire(sample, now: 10.101))
        XCTAssertNil(wire(sample, now: 9.99))
        XCTAssertNil(sample.wireSample(now: 10.05, negotiated: true) { _ in nil })
        var bad = sample
        bad.direction = .zero
        XCTAssertNil(wire(bad))
        bad.direction = SIMD3(.nan, 0, -1)
        XCTAssertNil(wire(bad))
        bad = sample
        bad.timestamp = .nan
        XCTAssertNil(wire(bad))
        bad.timestamp = -1
        XCTAssertNil(wire(bad, now: -0.95))
        bad = sample
        bad.distance = -.infinity
        XCTAssertNil(wire(bad))
    }

    func testGazePreservesHeadSpaceAndCaptureTime() throws {
        let wire = try XCTUnwrap(sample.wireSample(now: 10.05, negotiated: true) { UInt64($0 * 1e9) + 500 })
        XCTAssertEqual(wire.sampleTime, 10_000_000_500)
        XCTAssertEqual(wire.direction.x, 1 / sqrt(5), accuracy: 1e-6)
        XCTAssertEqual(wire.direction.z, -2 / sqrt(5), accuracy: 1e-6)
        XCTAssertEqual(wire.distance, 2)
    }

    func testRenderMetadataRequiresPoseAndClockAndPreservesEpoch() throws {
        XCTAssertNil(PCVRV3Remote.renderMetadata(nil) { $0 })
        let eye = EyeView(pose: Pose(orientation: Quaternion(x: 0, y: 0, z: 0, w: 1),
                                     position: Vector3(0.03, 0, 0)),
                          fieldOfView: FieldOfView(angleLeft: -0.8, angleRight: 0.9, angleUp: 1, angleDown: -1))
        let pose = RenderPose(poseSequence: 42, spaceEpoch: 7, displayTime: 10_000_000_000, left: eye, right: eye)
        XCTAssertNil(PCVRV3Remote.renderMetadata(pose) { _ in nil })
        let converted = try XCTUnwrap(PCVRV3Remote.renderMetadata(pose) { $0 + 1_000_000_000 })
        XCTAssertEqual(converted.displayTime, 11)
        XCTAssertEqual(converted.spaceEpoch, 7)
        XCTAssertEqual(converted.poseSequence, 42)
        XCTAssertEqual(converted.eyes.left.pose.position.x, 0.03)
        XCTAssertEqual(converted.eyes.left.fieldOfView.angleLeft, -0.8)
    }
}
#endif
