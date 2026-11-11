import StreamWire
import XCTest

final class MicrophoneTests: XCTestCase {
    func testFormatRoundTripsAndRejectsNonsense() throws {
        let format = MicrophoneFormat(sampleRate: 48_000)
        XCTAssertEqual(try format.encoded(), [0x80, 0xBB, 0x00, 0x00, 0x01])  // u32 little-endian, then channels
        XCTAssertEqual(try MicrophoneFormat(decoding: format.encoded()), format)
        XCTAssertTrue(try MicrophoneFormat(decoding: MicrophoneFormat.stopped.encoded()).isStopped)
        XCTAssertThrowsError(try MicrophoneFormat(decoding: MicrophoneFormat(sampleRate: 1_000).encoded()))
        XCTAssertThrowsError(try MicrophoneFormat(decoding: MicrophoneFormat(sampleRate: 48_000, channels: 2).encoded()))
    }

    /// The same packing as the headset's (and VVAS's) PCM24: little-endian.
    func testPCM24IsLittleEndianAndRoundTrips() {
        XCTAssertEqual(MicrophoneAudio.encode([0.5]), [0x00, 0x00, 0x40])
        XCTAssertEqual(MicrophoneAudio.encode([-1]), [0x01, 0x00, 0x80])
        let samples: [Float] = [0, 0.25, -0.25, 0.999, -0.999]
        let back = MicrophoneAudio.decode(MicrophoneAudio.encode(samples))
        for (a, b) in zip(samples, back) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    func testHeadersAreValidDataShards() throws {
        for sequence in UInt32(0)..<10 {
            let header = MicrophoneAudio.header(firstSample: UInt64(sequence) * 240, frames: 240, sequence: sequence,
                                                discontinuity: sequence == 0)
            XCTAssertNoThrow(try header.validate())
            XCTAssertFalse(header.isParity)
            XCTAssertEqual(header.codec, .pcm24)
        }
    }

    func testMicrophoneNeedsNothingElse() {
        let both = CapabilitySet([.microphone, .nack])
        XCTAssertTrue(CapabilitySet.negotiated(both, both).contains(.microphone))
        XCTAssertFalse(CapabilitySet.negotiated(both, CapabilitySet([.nack])).contains(.microphone))
        XCTAssertEqual(Capability.microphone.description, "microphone")
    }
}
