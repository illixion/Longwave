import StreamHost
import XCTest

final class AnnexBRepackerTests: XCTestCase {
    func testParameterSetsLeaveTheSampleAndTheRestIsLengthPrefixed() {
        let vps: [UInt8] = [0x40, 0x01, 0xAA]
        let sps: [UInt8] = [0x42, 0x01, 0xBB, 0xBC]
        let pps: [UInt8] = [0x44, 0x01]
        let idr: [UInt8] = [0x26, 0x01, 0x10, 0x20, 0x30]
        let unit = [0, 0, 0, 1] + vps + [0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 1] + idr
        let repacked = AnnexBRepacker.repack(hevc: unit)
        XCTAssertEqual(repacked.parameterSets, [0, 0, 0, 1] + vps + [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps)
        XCTAssertEqual(repacked.sample, [0, 0, 0, 5] + idr)
    }

    func testAPredictedFrameHasNoParameterSets() {
        let slice: [UInt8] = [0x02, 0x01, 0x99]
        let suffix: [UInt8] = [0x50, 0x01, 0x07]
        let repacked = AnnexBRepacker.repack(hevc: [0, 0, 0, 1] + slice + [0, 0, 0, 1] + suffix)
        XCTAssertTrue(repacked.parameterSets.isEmpty)
        XCTAssertEqual(repacked.sample, [0, 0, 0, 3] + slice + [0, 0, 0, 3] + suffix)
    }

    func testNothingToSplit() {
        XCTAssertEqual(AnnexBRepacker.repack(hevc: [UInt8]()), .init(parameterSets: [], sample: []))
        XCTAssertEqual(AnnexBRepacker.repack(hevc: [1, 2, 3]), .init(parameterSets: [], sample: []))
    }
}
