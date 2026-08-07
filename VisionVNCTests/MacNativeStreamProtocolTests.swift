import XCTest
@testable import VisionVNC

final class MacNativeStreamProtocolTests: XCTestCase {
    typealias P = MacNativeStreamProtocol

    func testHelloRoundTrip() {
        var buffer = P.encodeHello(deviceName: "Ixion Vision Pro")
        let frames = P.drainFrames(&buffer)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, P.FrameType.hello.rawValue)
        XCTAssertEqual(P.decodeHello(frames[0].payload)?.deviceName, "Ixion Vision Pro")
        XCTAssertTrue(buffer.isEmpty)
    }

    func testVideoFrameRoundTrip() {
        let encoded = P.encodeVideoFrame(
            Data([0x01, 0x02, 0x03]),
            isKeyFrame: true,
            sequence: 42,
            timestampNanoseconds: 9_876_543_210
        )
        var buffer = encoded
        let frames = P.drainFrames(&buffer)
        let video = frames.first.flatMap { P.decodeVideoFrame($0.payload) }

        XCTAssertEqual(frames.first?.type, P.FrameType.videoFrame.rawValue)
        XCTAssertEqual(video?.data, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(video?.isKeyFrame, true)
        XCTAssertEqual(video?.sequence, 42)
        XCTAssertEqual(video?.timestampNanoseconds, 9_876_543_210)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPartialLargeFrameRemainsBuffered() {
        let encoded = P.encodeVideoFrame(
            Data(repeating: 0xab, count: 32_000),
            isKeyFrame: false,
            sequence: 7,
            timestampNanoseconds: 11
        )
        var buffer = Data(encoded.prefix(encoded.count - 100))
        XCTAssertTrue(P.drainFrames(&buffer).isEmpty)

        buffer.append(encoded.suffix(100))
        let frames = P.drainFrames(&buffer)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(P.decodeVideoFrame(frames[0].payload)?.data.count, 32_000)
    }
}
