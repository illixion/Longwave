import StreamWire
import XCTest
@testable import Longwave

/// The test scene's stamp, read back from pictures painted the way the PC's
/// shader paints it: unwarped, and through a foveation warp.
#if FOVEATED_ENABLED
final class PCVRFrameStampTests: XCTestCase {
    /// A BGRA picture of two `eyeWidth` x `height` eyes, mid grey, with `values`
    /// ([eye][row]) stamped where the render-space blocks land on the wire.
    private func picture(eyeWidth: Int, height: Int, values: [[UInt16]], foveation: PCVRFoveation?) -> [UInt8] {
        let width = 2 * eyeWidth
        var bytes = [UInt8](repeating: 128, count: width * height * 4)
        for eye in 0..<2 {
            let mapping = foveation.map { eye == 0 ? $0.mapping.left : $0.mapping.right }
            for row in 0..<2 {
                for block in 0..<PCVRFrameStamp.blocks {
                    let white = block == 0 ? true : block == 17 ? false : (values[eye][row] >> (16 - block)) & 1 == 1
                    let render = PCVRFrameStamp.centre(block: block, row: row)
                    let wire = mapping.flatMap { $0.wireUV(forRender: render) } ?? render
                    let cx = eye * eyeWidth + Int(wire.x * Float(eyeWidth)), cy = Int(wire.y * Float(height))
                    for y in max(cy - 3, 0)...min(cy + 3, height - 1) {
                        for x in max(cx - 3, 0)...min(cx + 3, width - 1) {
                            let i = (y * width + x) * 4
                            let v: UInt8 = white ? 250 : 5
                            (bytes[i], bytes[i + 1], bytes[i + 2]) = (v, v, v)
                        }
                    }
                }
            }
        }
        return bytes
    }

    private func read(_ bytes: [UInt8], eyeWidth: Int, height: Int, foveation: PCVRFoveation?) -> PCVRFrameStamp.Reading {
        bytes.withUnsafeBytes {
            PCVRFrameStamp.read(bytes: $0.baseAddress!, bytesPerRow: 2 * eyeWidth * 4, width: 2 * eyeWidth, height: height,
                                foveation: foveation)
        }
    }

    func testAnUnwarpedStampReadsBack() {
        let values: [[UInt16]] = [[0xBEEF, 0xBEEF], [0xBEEF, 0xBEEF]]
        let bytes = picture(eyeWidth: 1600, height: 1200, values: values, foveation: nil)
        XCTAssertEqual(read(bytes, eyeWidth: 1600, height: 1200, foveation: nil), values.map { $0.map { Optional($0) } })
    }

    func testAStampReadsBackThroughTheFoveationWarp() throws {
        let parameters = FoveationParameters(epoch: 3, warp: .centreEdge(PCVRProfile.defaultWarp))
        let side = FoveationSideData(parameterEpoch: 3, leftCentre: NormalizedPoint(x: 0.62, y: 0.45),
                                     rightCentre: NormalizedPoint(x: 0.35, y: 0.45))
        let foveation = try XCTUnwrap(PCVRFoveation(parameters: parameters, frame: side,
                                                    renderEye: PixelSize(width: 5184, height: 4160)))
        let values: [[UInt16]] = [[0x1234, 0x1234], [0x1234, 0x1234]]
        let bytes = picture(eyeWidth: 2592, height: 2080, values: values, foveation: foveation)
        XCTAssertEqual(read(bytes, eyeWidth: 2592, height: 2080, foveation: foveation), values.map { $0.map { Optional($0) } })
        // Read as if unwarped, the blocks are elsewhere.
        XCTAssertNotEqual(read(bytes, eyeWidth: 2592, height: 2080, foveation: nil), values.map { $0.map { Optional($0) } })
    }

    func testAPictureWithoutAStampIsUnreadable() {
        let bytes = [UInt8](repeating: 128, count: 2 * 800 * 600 * 4)
        XCTAssertEqual(read(bytes, eyeWidth: 800, height: 600, foveation: nil), [[nil, nil], [nil, nil]])
    }

    func testTheCheckerTellsTheFaultsApart() {
        let checker = PCVRStampChecker()
        checker.record([[7, 7], [7, 7]], frameNumber: 1, poseSequence: 7)
        checker.record([[7, 8], [7, 7]], frameNumber: 2, poseSequence: 7)
        checker.record([[7, 7], [8, 8]], frameNumber: 3, poseSequence: 7)
        checker.record([[6, 6], [6, 6]], frameNumber: 4, poseSequence: 7)
        checker.record([[nil, 7], [7, 7]], frameNumber: 5, poseSequence: 7)
        checker.record([[7, 7], [7, 7]], frameNumber: 6, poseSequence: 0x1_0007) // low 16 bits
        let counts = checker.counts
        XCTAssertEqual(counts.checked, 6)
        XCTAssertEqual(counts.matching, 2)
        XCTAssertEqual(counts.torn, 1)
        XCTAssertEqual(counts.eyesDiffer, 1)
        XCTAssertEqual(counts.poseMismatch, 1)
        XCTAssertEqual(counts.unreadable, 1)
        XCTAssertTrue(counts.lastProblem?.hasPrefix("unreadable") ?? false)
    }
}
#endif
