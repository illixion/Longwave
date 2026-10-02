import XCTest
@testable import Longwave

final class MicrophoneProtocolTests: XCTestCase {

    func testHeaderCarriesCapabilities() throws {
        let header = AudioStreamHeader(sampleRate: 48_000, channelCount: 2, capabilities: [.acceptsMicrophone])
        let parsed = try XCTUnwrap(AudioStreamHeader(parsing: header.encoded()))
        XCTAssertEqual(parsed, header)
        XCTAssertTrue(parsed.capabilities.contains(.acceptsMicrophone))
    }

    func testHeaderFromOlderSenderOffersNothing() throws {
        // A sender that predates capabilities wrote zeros in bytes 6-7.
        var bytes = AudioStreamHeader(sampleRate: 48_000, channelCount: 2).encoded()
        bytes[6] = 0
        let parsed = try XCTUnwrap(AudioStreamHeader(parsing: bytes))
        XCTAssertEqual(parsed.capabilities, [])
    }

    func testMicrophonePacketRoundTrips() throws {
        let samples = Data((0..<(MicrophonePacket.maxFramesPerPacket * 3)).map { UInt8(truncatingIfNeeded: $0) })
        let packet = MicrophonePacket(
            stamp: PCMStamp(sampleIndex: 123_456_789, flags: .resumed),
            sampleRate: 48_000, channelCount: 1, samples: samples
        )
        let frame = packet.encodedFrame()
        XCTAssertEqual(AudioStreamProtocol.decodeFrameLength(frame), UInt32(frame.count - 4))
        XCTAssertEqual(frame[4], AudioStreamProtocol.FrameType.microphone.rawValue)
        let parsed = try XCTUnwrap(MicrophonePacket(parsing: frame.subdata(in: 5..<frame.count)))
        XCTAssertEqual(parsed, packet)
        XCTAssertEqual(parsed.frameCount, MicrophonePacket.maxFramesPerPacket)
        // A 5 ms mono packet stays well inside one datagram.
        XCTAssertLessThan(frame.count, 1_000)
    }

    func testMicrophonePacketRejectsNonsense() {
        XCTAssertNil(MicrophonePacket(parsing: Data(count: 5)))
        var payload = PCMStamp(sampleIndex: 0).encoded()
        payload.append(contentsOf: [0, 0, 0, 0, 1]) // 0 Hz
        XCTAssertNil(MicrophonePacket(parsing: payload))
    }
}
