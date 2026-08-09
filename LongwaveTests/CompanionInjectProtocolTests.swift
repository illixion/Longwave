import XCTest
@testable import Longwave

/// The text-injection wire protocol: typed length-prefixed frames, a
/// stream-draining parser that leaves partial frames buffered, and the
/// little-endian backspace-count payload.
final class CompanionInjectProtocolTests: XCTestCase {
    typealias P = CompanionInjectProtocol

    func testEncodeDrainRoundTrip() {
        var buf = Data()
        buf.append(P.encodeFrame(.injectText, Data("hé".utf8)))   // multi-byte payload
        buf.append(P.encodeFrame(.injectBackspace, P.encodeBackspace(3)))
        let frames = P.drainFrames(&buf)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].type, P.FrameType.injectText.rawValue)
        XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "hé")
        XCTAssertEqual(frames[1].type, P.FrameType.injectBackspace.rawValue)
        XCTAssertEqual(P.decodeBackspace(frames[1].payload), 3)
        XCTAssertTrue(buf.isEmpty, "complete frames should be consumed")
    }

    func testPartialFrameStaysBuffered() {
        let frame = P.encodeFrame(.injectText, Data("hello".utf8))
        var buf = Data(frame.prefix(frame.count - 2))   // missing last 2 bytes
        XCTAssertTrue(P.drainFrames(&buf).isEmpty)
        XCTAssertEqual(buf.count, frame.count - 2, "partial frame is retained")
        buf.append(frame.suffix(2))                      // rest arrives
        let frames = P.drainFrames(&buf)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "hello")
        XCTAssertTrue(buf.isEmpty)
    }

    func testEmptyPayloadFrame() {
        var buf = P.encodeFrame(.hello)
        let frames = P.drainFrames(&buf)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, P.FrameType.hello.rawValue)
        XCTAssertTrue(frames[0].payload.isEmpty)
    }

    func testBackspaceRoundTripAndClamp() {
        for n in [0, 1, 2, 255, 256, 65535, 70000] {
            XCTAssertEqual(P.decodeBackspace(P.encodeBackspace(n)), min(n, 65535))
        }
    }

    func testDecodeFrameLengthShortData() {
        XCTAssertNil(P.decodeFrameLength(Data([0x01, 0x02])))   // fewer than 4 bytes
    }

    func testDecodeBackspaceWrongSize() {
        XCTAssertNil(P.decodeBackspace(Data([0x01])))
        XCTAssertNil(P.decodeBackspace(Data([1, 2, 3])))
    }
}
