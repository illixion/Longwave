import StreamPlayout
import XCTest

final class MicrophonePlayoutTests: XCTestCase {
    private func render(_ playout: MicrophonePlayout, _ frames: Int) -> [Float] {
        var out = [Float](repeating: -9, count: frames)
        out.withUnsafeMutableBufferPointer { playout.render(into: $0) }
        return out
    }

    private func packet(_ index: Int, value: Float = 0.5) -> [Float] {
        [Float](repeating: value, count: 240)
    }

    func testPrimesToFortyMillisecondsThenPlaysInOrder() {
        let p = MicrophonePlayout(sampleRate: 48_000)
        p.receive(firstSample: 0, discontinuity: true, samples: packet(0, value: 0.1))
        XCTAssertEqual(render(p, 240), [Float](repeating: 0, count: 240))   // still priming (5 of 40 ms)
        for i in 1..<8 { p.receive(firstSample: UInt64(i * 240), discontinuity: false, samples: packet(i, value: Float(i + 1) / 10)) }
        let out = render(p, 480)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(out[240], 0.2, accuracy: 1e-6)
    }

    func testShortGapsBecomeSilenceAndLatePacketsAreDropped() {
        let p = MicrophonePlayout(sampleRate: 48_000)
        for i in 0..<8 { p.receive(firstSample: UInt64(i * 240), discontinuity: false, samples: packet(i)) }
        // Packet 8 lost; 9 arrives, then 8 late.
        p.receive(firstSample: 9 * 240, discontinuity: false, samples: packet(9, value: 0.9))
        p.receive(firstSample: 8 * 240, discontinuity: false, samples: packet(8, value: 0.8))
        let out = render(p, 10 * 240)
        XCTAssertEqual(out[8 * 240], 0, accuracy: 1e-6)            // the hole, kept in time
        XCTAssertEqual(out[9 * 240], 0.9, accuracy: 1e-6)
        let health = p.takeHealth()
        XCTAssertEqual(health.lostFrames, 240)
        XCTAssertEqual(health.latePackets, 1)
    }

    func testUnderrunGrowsTheCushionAndExcessIsTrimmed() {
        let p = MicrophonePlayout(sampleRate: 48_000)
        for i in 0..<8 { p.receive(firstSample: UInt64(i * 240), discontinuity: false, samples: packet(i)) }
        _ = render(p, 48 * 50)   // far more than buffered: an underrun
        XCTAssertEqual(p.takeHealth().targetSeconds, 0.06, accuracy: 1e-9)
        // A burst far past target + slack once playing gets trimmed back to the target.
        var index = 8
        for _ in 0..<12 { p.receive(firstSample: UInt64(index * 240), discontinuity: false, samples: packet(index)); index += 1 }
        _ = render(p, 240)       // primed again (60 ms) and playing
        for _ in 0..<60 { p.receive(firstSample: UInt64(index * 240), discontinuity: false, samples: packet(index)); index += 1 }
        let health = p.takeHealth()
        XCTAssertGreaterThan(health.trimmedFrames, 0)
        XCTAssertLessThanOrEqual(health.bufferedSeconds, 0.06 + 0.061)   // target + trim slack
    }
}

