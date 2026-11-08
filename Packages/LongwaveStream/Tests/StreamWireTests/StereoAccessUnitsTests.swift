import XCTest
@testable import StreamWire

final class StereoAccessUnitsTests: XCTestCase {
    func testPairKeepsBothEyesAndRejectsEveryTruncation() throws {
        let pair = StereoAccessUnits(left: [0,0,0,1,0x26,1], right: [0,0,0,1,0x26,2,3])
        let bytes = try pair.encoded()
        XCTAssertEqual(try StereoAccessUnits(decoding: bytes), pair)
        XCTAssertEqual(Array(bytes.prefix(8)), [6,0,0,0,7,0,0,0])
        for end in 0..<bytes.count {
            XCTAssertThrowsError(try StereoAccessUnits(decoding: Array(bytes.prefix(end))))
        }
        XCTAssertThrowsError(try StereoAccessUnits(decoding: bytes + [0]))
    }

    func testSeparateFormatDescribesOneEyeAndRoundTrips() throws {
        var format = Fixtures.pcvrFormat
        format.pcvr?.layout = .separateAccessUnits
        format.size = try XCTUnwrap(format.pcvr?.wireSize)
        XCTAssertEqual(try FormatDescription(decoding: format.encoded()), format)
        format.size.width *= 2
        XCTAssertThrowsError(try format.encoded())
    }

    func testEmptyAndUnboundedEyesAreRejected() {
        XCTAssertThrowsError(try StereoAccessUnits(left: [], right: [1]).encoded())
        XCTAssertThrowsError(try StereoAccessUnits(decoding: [255,255,255,255,1,0,0,0]))
    }

    func testSeparateEyesRequirePCVRNegotiation() {
        let offered = PCVRProfile.clientCapabilities(gaze: false, depth: false, separateEyes: true)
        XCTAssertTrue(offered.contains(.separateEyeVideo))
        XCTAssertTrue(CapabilitySet.negotiated(offered, PCVRProfile.hostCapabilities).contains(.separateEyeVideo))
        XCTAssertFalse(CapabilitySet.negotiated(CapabilitySet([.separateEyeVideo]), .known).contains(.separateEyeVideo))
    }
}
