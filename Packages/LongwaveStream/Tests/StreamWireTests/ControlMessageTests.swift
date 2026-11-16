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

    func testStreamSubscriptionGoldenBytes() throws {
        let subscription = StreamSubscription(streamID: 7)
        XCTAssertEqual(hexString(try MessageFraming.encode(.streamStart, body: subscription.encoded())), "270407000000")
        XCTAssertEqual(try StreamSubscription(decoding: hex("07000000")), subscription)
        XCTAssertThrowsError(try StreamSubscription(decoding: hex("0700")))
    }

    func testStreamClosedGoldenBytes() throws {
        let closed = StreamClosed(streamID: 7, reason: "ab")
        XCTAssertEqual(hexString(try MessageFraming.encode(.streamClosed, body: closed.encoded())), "2d0807000000020061" + "62")
        XCTAssertEqual(try StreamClosed(decoding: hex("07000000020061" + "62")), closed)
        XCTAssertEqual(try StreamClosed(decoding: hex("070000000000")), StreamClosed(streamID: 7))
        XCTAssertThrowsError(try StreamClosed(decoding: hex("0700000003006162")), "short reason")
        XCTAssertThrowsError(try StreamClosed(decoding: hex("070000000100ff")), "invalid UTF-8")
    }

    func testTextBodies() throws {
        XCTAssertEqual(try TextBody.decode(try TextBody.encode("Mac sleeping")[...]), "Mac sleeping")
        XCTAssertEqual(try TextBody.decode([][...]), "")
        XCTAssertThrowsError(try TextBody.decode(hex("c328")[...]), "invalid UTF-8")
        XCTAssertThrowsError(try TextBody.encode(String(repeating: "a", count: 1_025)))
    }
}
