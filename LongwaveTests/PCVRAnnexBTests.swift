import XCTest
import simd
import StreamWire
@testable import Longwave

/// The v3 PCVR receiver's byte handling: NVENC's Annex-B output into what
/// VideoToolbox takes, and poses between the shell's types and the wire's.
/// Gated with the feature, like the rest of PCVR.
#if FOVEATED_ENABLED
final class PCVRAnnexBTests: XCTestCase {
    // HEVC NAL headers: type << 1 in the first byte, then layer/TID byte 0x01.
    private let vps: [UInt8] = [0x40, 0x01, 0x0C, 0x01]
    private let sps: [UInt8] = [0x42, 0x01, 0x01, 0x60]
    private let pps: [UInt8] = [0x44, 0x01, 0xC1, 0x72]
    private let aud: [UInt8] = [0x46, 0x01, 0x50]
    private let idr: [UInt8] = [0x26, 0x01, 0xAF, 0x09, 0x40]   // IDR_W_RADL (19)
    private let sei: [UInt8] = [0x4E, 0x01, 0x05, 0x80]          // prefix SEI (39)

    private func annexB(_ units: [[UInt8]], longStartCodes: Bool = true) -> [UInt8] {
        units.flatMap { (longStartCodes ? [0, 0, 0, 1] : [0, 0, 1]) + $0 }
    }

    func testSplitsBothStartCodeLengths() {
        let stream = [0, 0, 0, 1] + vps + [0, 0, 1] + sps + [0, 0, 0, 1] + pps
        XCTAssertEqual(PCVRAnnexB.nalUnits(stream).map(Array.init), [vps, sps, pps])
    }

    func testIgnoresLeadingGarbageAndEmptyUnits() {
        let stream: [UInt8] = [0xFF, 0x12] + [0, 0, 1] + [0, 0, 0, 1] + idr
        XCTAssertEqual(PCVRAnnexB.nalUnits(stream).map(Array.init), [idr])
    }

    func testParameterSetsFromConfiguration() throws {
        let sets = try XCTUnwrap(PCVRAnnexB.parameterSets(annexB([vps, sps, pps])))
        XCTAssertEqual(sets.vps, vps)
        XCTAssertEqual(sets.sps, sps)
        XCTAssertEqual(sets.pps, pps)
        XCTAssertNil(PCVRAnnexB.parameterSets(annexB([vps, pps])), "an SPS is required")
    }

    func testSampleDropsParameterSetsAndDelimitersAndLengthPrefixes() {
        let accessUnit = annexB([aud, vps, sps, pps, sei, idr], longStartCodes: false)
        let sample = PCVRAnnexB.lengthPrefixedSample(accessUnit)
        XCTAssertEqual(sample, [0, 0, 0, UInt8(sei.count)] + sei + [0, 0, 0, UInt8(idr.count)] + idr)
    }

    func testSampleOfOnlyParameterSetsIsEmpty() {
        XCTAssertTrue(PCVRAnnexB.lengthPrefixedSample(annexB([vps, sps, pps])).isEmpty)
    }

    func testLargeUnitLengthIsBigEndian() {
        let big = [UInt8](repeating: 0x55, count: 70_000)
        let unit: [UInt8] = [0x02, 0x01] + big   // TRAIL_R (1)
        let sample = PCVRAnnexB.lengthPrefixedSample(annexB([unit]))
        XCTAssertEqual(Array(sample.prefix(4)), [0x00, 0x01, 0x11, 0x72])   // 70_002
        XCTAssertEqual(sample.count, 4 + unit.count)
    }

    func testPoseRoundTripsThroughTheWire() {
        let rotation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.2, 1, -0.3)))
        let fov = PCVRFieldOfView(angleLeft: -0.9, angleRight: 0.8, angleUp: 0.85, angleDown: -0.95)
        let eye = PCVREyeGeometry(deviceFromEye: PCVRPose(rotation: rotation, position: SIMD3(-0.031, 0.01, -0.02)),
                                  fieldOfView: fov)
        let wire = PCVRV3Remote.wireEye(eye)
        let back = PCVRV3Remote.eyeView(wire)
        XCTAssertTrue(back.pose.isClose(to: eye.deviceFromEye, metres: 1e-6, radians: 1e-5))
        XCTAssertEqual(back.fieldOfView.angleLeft, fov.angleLeft)
        XCTAssertEqual(back.fieldOfView.angleDown, fov.angleDown)
        // What the host gets must pass the wire's own validation.
        let pose = HeadPose(displayTime: 1, spaceEpoch: 0, head: PCVRV3Remote.wirePose(.identity),
                            leftEye: wire, rightEye: wire)
        let snapshot = StateSnapshot(sequence: 1, hostTime: 1, payload: .headPose(pose))
        XCTAssertNoThrow(try snapshot.validate())
    }
}
#endif
