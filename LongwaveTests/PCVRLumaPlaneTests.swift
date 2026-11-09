#if FOVEATED_ENABLED
import XCTest
@testable import Longwave

final class PCVRLumaPlaneTests: XCTestCase {
    func testCopyPreservesPackedBytesIncludingZeroAndMaxDepth() {
        let input: [UInt8] = [0, 255, 17, 3, 254, 0]
        let output = input.withUnsafeBytes {
            PCVRLumaPlane.copy(base: $0.baseAddress!, width: 3, height: 2, stride: 3)
        }
        XCTAssertEqual(output, input)
    }

    func testRowPaddingNeverBecomesDepthData() {
        let input: [UInt8] = [0, 1, 2, 99, 99, 253, 254, 255, 99, 99]
        let output = input.withUnsafeBytes {
            PCVRLumaPlane.copy(base: $0.baseAddress!, width: 3, height: 2, stride: 5)
        }
        XCTAssertEqual(output, [0, 1, 2, 253, 254, 255])
    }
}
#endif
