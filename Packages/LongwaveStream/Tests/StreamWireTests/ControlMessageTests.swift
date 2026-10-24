import StreamWire
import XCTest

final class ControlMessageTests: XCTestCase {
    func testRecoveryRequestGoldenBytes() throws {
        let request = RecoveryRequest(streamID: 1, firstLostFrame: 0x0102_0304)
        XCTAssertEqual(hexString(try request.encoded()), "0100000004030201")
        XCTAssertEqual(try RecoveryRequest(decoding: try request.encoded()), request)
        XCTAssertThrowsError(try RecoveryRequest(decoding: hex("01000000 040302")))
        let message = try MessageFraming.encode(.recoveryRequest, body: request.encoded())
        XCTAssertEqual(hexString(message), "21080100000004030201")
    }

    func testTextBodies() throws {
        XCTAssertEqual(try TextBody.decode(try TextBody.encode("Mac sleeping")[...]), "Mac sleeping")
        XCTAssertEqual(try TextBody.decode([][...]), "")
        XCTAssertThrowsError(try TextBody.decode(hex("c328")[...]), "invalid UTF-8")
        XCTAssertThrowsError(try TextBody.encode(String(repeating: "a", count: 1_025)))
    }
}
