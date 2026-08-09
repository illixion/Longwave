import XCTest
@testable import Longwave

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

    func testHelloCarriesProtocolVersion() {
        var buffer = P.encodeHello(deviceName: "AVP")
        let frames = P.drainFrames(&buffer)
        XCTAssertEqual(P.decodeHello(frames[0].payload)?.protocolVersion, P.protocolVersion)
    }

    func testV1HelloWithoutVersionStillDecodes() {
        let legacy = Data(#"{"deviceName":"Old Viewer"}"#.utf8)
        let hello = P.decodeHello(legacy)
        XCTAssertEqual(hello?.deviceName, "Old Viewer")
        XCTAssertNil(hello?.protocolVersion)
    }

    func testHelloAckRoundTripAndV1Fallback() {
        let ack = P.HelloAck(
            protocolVersion: 2,
            platform: "windows",
            keyCodeSpace: .hidUsage,
            supportsWindowStreams: true,
            supportsTransparentDesktop: false,
            supportsAudioStream: false
        )
        var buffer = P.encodeHelloAck(ack)
        let frames = P.drainFrames(&buffer)
        let decoded = P.decodeHelloAck(frames[0].payload)
        XCTAssertEqual(decoded?.platform, "windows")
        XCTAssertEqual(decoded?.keyCodeSpace, .hidUsage)
        XCTAssertEqual(decoded?.supportsWindowStreams, true)
        XCTAssertEqual(decoded?.supportsTransparentDesktop, false)
        XCTAssertEqual(decoded?.servesAudioStream, false)

        // A v1 server sends an empty helloAck payload.
        XCTAssertNil(P.decodeHelloAck(Data()))
    }

    /// A host that predates `supportsAudioStream` must still decode, and must
    /// fall back by platform — only the macOS companion ever served audio.
    func testHelloAckWithoutAudioCapabilityFallsBackToPlatform() throws {
        for (platform, expected) in [("macOS", true), ("windows", false)] {
            let json = """
            {"protocolVersion":2,"platform":"\(platform)","keyCodeSpace":"hidUsage",\
            "supportsWindowStreams":true,"supportsTransparentDesktop":false}
            """
            let decoded = try XCTUnwrap(P.decodeHelloAck(Data(json.utf8)))
            XCTAssertNil(decoded.supportsAudioStream)
            XCTAssertEqual(decoded.servesAudioStream, expected, "platform \(platform)")
        }
    }

    func testWindowInventoryRoundTrip() {
        let windows = [
            P.WindowInfo(id: 71, title: "Report.pages", appName: "Pages",
                         width: 1180, height: 820, isFocused: true),
            P.WindowInfo(id: 205, title: "", appName: "Finder",
                         width: 640, height: 480, isFocused: false),
        ]
        var buffer = P.encodeWindowInventory(windows)
        let frames = P.drainFrames(&buffer)
        XCTAssertEqual(frames[0].type, P.FrameType.windowList.rawValue)
        XCTAssertEqual(P.decodeWindowInventory(frames[0].payload), windows)
    }

    func testWindowIDFramesRoundTrip() {
        for type in [P.FrameType.windowStreamStart, .windowStreamStop, .focusWindow] {
            var buffer = P.encodeWindowID(type, windowID: 0xDEAD_BEEF)
            let frames = P.drainFrames(&buffer)
            XCTAssertEqual(frames[0].type, type.rawValue)
            XCTAssertEqual(P.decodeWindowID(frames[0].payload), 0xDEAD_BEEF)
        }
    }

    func testWindowFormatDescriptionRoundTrip() {
        let blob = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01])
        var buffer = P.encodeWindowFormatDescription(
            windowID: 9, kind: .hevcParameterSets, data: blob
        )
        let frames = P.drainFrames(&buffer)
        let decoded = P.decodeWindowFormatDescription(frames[0].payload)
        XCTAssertEqual(decoded?.windowID, 9)
        XCTAssertEqual(decoded?.kind, .hevcParameterSets)
        XCTAssertEqual(decoded?.data, blob)
    }

    func testWindowVideoFrameRoundTrip() {
        var buffer = P.encodeWindowVideoFrame(
            windowID: 314,
            Data([0xCA, 0xFE]),
            isKeyFrame: false,
            sequence: 8,
            timestampNanoseconds: 123_456
        )
        let frames = P.drainFrames(&buffer)
        let decoded = P.decodeWindowVideoFrame(frames[0].payload)
        XCTAssertEqual(decoded?.windowID, 314)
        XCTAssertEqual(decoded?.frame.data, Data([0xCA, 0xFE]))
        XCTAssertEqual(decoded?.frame.isKeyFrame, false)
        XCTAssertEqual(decoded?.frame.sequence, 8)
        XCTAssertEqual(decoded?.frame.timestampNanoseconds, 123_456)
    }

    func testWindowClosedRoundTrip() {
        var withReason = P.encodeWindowClosed(windowID: 5, reason: "App quit")
        var decoded = P.drainFrames(&withReason).first.flatMap { P.decodeWindowClosed($0.payload) }
        XCTAssertEqual(decoded?.windowID, 5)
        XCTAssertEqual(decoded?.reason, "App quit")

        var bare = P.encodeWindowClosed(windowID: 6)
        decoded = P.drainFrames(&bare).first.flatMap { P.decodeWindowClosed($0.payload) }
        XCTAssertEqual(decoded?.windowID, 6)
        XCTAssertNil(decoded?.reason)
    }

    func testWindowInputFramesRoundTrip() {
        var move = P.encodeWindowMouseMove(windowID: 3, x: 100, y: 200)
        let movDecoded = P.drainFrames(&move).first.flatMap { P.decodeWindowMouseMove($0.payload) }
        XCTAssertEqual(movDecoded?.windowID, 3)
        XCTAssertEqual(movDecoded?.x, 100)
        XCTAssertEqual(movDecoded?.y, 200)

        var down = P.encodeWindowMouseButton(.windowMouseDown, windowID: 3, button: .right, x: 8, y: 9)
        let downFrames = P.drainFrames(&down)
        XCTAssertEqual(downFrames[0].type, P.FrameType.windowMouseDown.rawValue)
        let downDecoded = P.decodeWindowMouseButton(downFrames[0].payload)
        XCTAssertEqual(downDecoded?.windowID, 3)
        XCTAssertEqual(downDecoded?.button, .right)
        XCTAssertEqual(downDecoded?.x, 8)
        XCTAssertEqual(downDecoded?.y, 9)

        var scroll = P.encodeWindowScroll(windowID: 3, x: 1, y: 2, deltaX: -3, deltaY: 4)
        let scrollDecoded = P.drainFrames(&scroll).first.flatMap { P.decodeWindowScroll($0.payload) }
        XCTAssertEqual(scrollDecoded?.windowID, 3)
        XCTAssertEqual(scrollDecoded?.deltaX, -3)
        XCTAssertEqual(scrollDecoded?.deltaY, 4)
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
