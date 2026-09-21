import XCTest
@testable import Longwave

/// Covers the v7 chunked-artwork framing. Artwork shares the single ordered
/// TCP stream with PCM, so it is split into small frames the sender dribbles
/// out between audio frames; the receiver concatenates until the final flag.
/// These tests are the reassembly contract both ends depend on.
final class AudioArtworkChunkingTests: XCTestCase {
    typealias P = AudioStreamProtocol

    /// Reassembles a sequence of encoded artwork frames the way the receiver
    /// does: strip the length prefix and type byte, take the continuation
    /// flag off the front, append the rest, emit on the final flag.
    private func reassemble(_ frames: [Data]) -> [Data] {
        var completed: [Data] = []
        var assembly = Data()
        for frame in frames {
            guard let length = P.decodeFrameLength(frame) else {
                XCTFail("frame has no length prefix")
                continue
            }
            XCTAssertEqual(Int(length), frame.count - P.frameLengthPrefixSize)
            XCTAssertEqual(frame[frame.startIndex + P.frameLengthPrefixSize], P.FrameType.artwork.rawValue)

            let payload = frame.subdata(in: (frame.startIndex + P.frameLengthPrefixSize + 1)..<frame.endIndex)
            guard let final = payload.first else {
                XCTFail("artwork payload is missing its continuation flag")
                continue
            }
            assembly.append(payload.dropFirst())
            if final == 1 {
                completed.append(assembly)
                assembly = Data()
            }
        }
        XCTAssertTrue(assembly.isEmpty, "stream ended mid-artwork")
        return completed
    }

    func testSingleChunkRoundTrip() {
        let artwork = Data((0..<512).map { UInt8($0 % 251) })
        let frames = P.encodeArtworkFrames(artwork)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(reassemble(frames), [artwork])
    }

    func testMultiChunkRoundTrip() {
        // Two and a bit chunks, so the final one is a partial.
        let artwork = Data((0..<(P.artworkChunkBytes * 2 + 123)).map { UInt8($0 % 256) })
        let frames = P.encodeArtworkFrames(artwork)

        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(reassemble(frames), [artwork])
    }

    func testExactMultipleOfChunkSizeHasNoTrailingEmptyFrame() {
        let artwork = Data(repeating: 0xAB, count: P.artworkChunkBytes * 2)
        let frames = P.encodeArtworkFrames(artwork)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(reassemble(frames), [artwork])
    }

    func testEmptyArtworkStillTerminates() {
        // A single final empty chunk — this is how the receiver's artwork
        // gets cleared rather than left stale.
        let frames = P.encodeArtworkFrames(Data())

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(reassemble(frames), [Data()])
    }

    func testChunksStayUnderTheFrameCap() {
        let artwork = Data(repeating: 0x7F, count: P.artworkChunkBytes * 3 + 1)
        for frame in P.encodeArtworkFrames(artwork) {
            XCTAssertLessThanOrEqual(UInt32(frame.count - P.frameLengthPrefixSize), P.maxFrameBytes)
            // Small enough that the PCM queued behind one chunk is delayed by
            // well under a millisecond of link time — the whole point.
            XCTAssertLessThanOrEqual(frame.count, P.artworkChunkBytes + 16)
        }
    }

    func testBackToBackArtworkReassemblesIndependently() {
        let first = Data(repeating: 0x11, count: P.artworkChunkBytes + 5)
        let second = Data(repeating: 0x22, count: 64)
        let frames = P.encodeArtworkFrames(first) + P.encodeArtworkFrames(second)

        XCTAssertEqual(reassemble(frames), [first, second])
    }
}
