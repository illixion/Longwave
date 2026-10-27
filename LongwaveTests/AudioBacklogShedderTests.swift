import XCTest
@testable import Longwave

/// Covers the backlog shedder that replaced playing fast to catch up. What
/// matters is what it must *not* do: change pitch, introduce a step into the
/// waveform, touch audio it was not asked to shed, or reorder anything.
final class AudioBacklogShedderTests: XCTestCase {
    private let rate = 48_000.0
    private let bufferFrames = 512

    private func sine(_ frequency: Double, frames: Int, amplitude: Float = 0.5, offset: Int = 0) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * frequency * Double($0 + offset) / rate)) }
    }

    /// Feeds `signal` (identical on both channels) through a shedder in
    /// receiver-sized buffers, shedding up to `budget` per buffer while
    /// `shedding`, and returns the left channel of everything released.
    private func run(
        _ signal: [Float],
        budget: Int,
        shedder: inout AudioBacklogShedder,
        flush: Bool = true
    ) -> [Float] {
        var output: [Float] = []
        var start = 0
        while start < signal.count {
            let chunk = Array(signal[start..<min(start + bufferFrames, signal.count)])
            shedder.append(frames: chunk.count) { frame, _ in chunk[frame] }
            shedder.shed(budget: budget)
            output += shedder.take(shedder.releasable(holdingBack: true))[0]
            start += chunk.count
        }
        if flush { output += shedder.take(shedder.releasable(holdingBack: false))[0] }
        return output
    }

    func testPassesAudioThroughUntouchedWhenNotShedding() {
        var shedder = AudioBacklogShedder(channels: 2, sampleRate: rate)
        let left = sine(440, frames: 1000)
        let right = sine(660, frames: 1000)
        shedder.append(frames: 1000) { frame, channel in channel == 0 ? left[frame] : right[frame] }
        let out = shedder.take(shedder.releasable(holdingBack: false))
        XCTAssertEqual(out[0], left)
        XCTAssertEqual(out[1], right)
        XCTAssertEqual(shedder.pendingFrames, 0)
        XCTAssertEqual(shedder.totalFramesShed, 0)
    }

    func testHoldsBackLookaheadWhileShedding() {
        var shedder = AudioBacklogShedder(channels: 1, sampleRate: rate)
        let tone = sine(440, frames: 4000)
        shedder.append(frames: tone.count) { frame, _ in tone[frame] }
        XCTAssertEqual(shedder.releasable(holdingBack: true), 4000 - shedder.lookaheadFrames)
    }

    func testDropsSilenceFirstAndLeavesTheOnsetIntact() {
        var shedder = AudioBacklogShedder(channels: 2, sampleRate: rate)
        let silence = [Float](repeating: 0, count: 4800)
        let onset = sine(880, frames: 4800)
        // Exactly the silence's worth of budget, minus what the fade needs.
        let budget = 2000
        var output: [Float] = []
        var budgetLeft = budget
        for (index, chunkStart) in stride(from: 0, to: 9600, by: bufferFrames).enumerated() {
            _ = index
            let signal = silence + onset
            let chunk = Array(signal[chunkStart..<min(chunkStart + bufferFrames, signal.count)])
            shedder.append(frames: chunk.count) { frame, _ in chunk[frame] }
            budgetLeft -= shedder.shed(budget: budgetLeft)
            output += shedder.take(shedder.releasable(holdingBack: true))[0]
        }
        output += shedder.take(shedder.releasable(holdingBack: false))[0]

        XCTAssertEqual(shedder.quietFramesShed, budget)
        XCTAssertEqual(shedder.splicedFramesShed, 0)
        XCTAssertEqual(output.count, 9600 - budget)
        // Everything audible comes out bit-exact, right after the shortened
        // silence.
        XCTAssertEqual(Array(output.suffix(onset.count)), onset)
        XCTAssertTrue(output.prefix(output.count - onset.count).allSatisfy { $0 == 0 })
    }

    func testSplicesToneWithoutChangingPitch() {
        var shedder = AudioBacklogShedder(channels: 2, sampleRate: rate)
        let frequency = 440.0
        let input = sine(frequency, frames: Int(rate) * 3)
        let output = run(input, budget: .max, shedder: &shedder)

        // It actually shed, at about the configured share, and lost nothing
        // else.
        XCTAssertGreaterThan(shedder.splicedFramesShed, 0)
        XCTAssertEqual(output.count + shedder.totalFramesShed, input.count)
        let share = Double(shedder.totalFramesShed) / Double(input.count)
        XCTAssertEqual(share, shedder.ratio, accuracy: 0.01)

        // Same pitch: count rising zero crossings over the output. Playing
        // 4% fast would read ~458 Hz here.
        var crossings = 0
        for i in 1..<output.count where output[i - 1] < 0 && output[i] >= 0 { crossings += 1 }
        let measured = Double(crossings) / (Double(output.count) / rate)
        XCTAssertEqual(measured, frequency, accuracy: frequency * 0.005)

        // No step anywhere: the largest sample-to-sample change stays that of
        // the sine itself.
        let maxSineStep = Float(0.5 * 2 * .pi * frequency / rate)
        var maxStep: Float = 0
        for i in 1..<output.count { maxStep = max(maxStep, abs(output[i] - output[i - 1])) }
        XCTAssertLessThan(maxStep, maxSineStep * 1.1)
    }

    func testNeverShedsMoreThanTheBudget() {
        var shedder = AudioBacklogShedder(channels: 1, sampleRate: rate)
        let input = [Float](repeating: 0, count: 2000) + sine(330, frames: 20_000)
        var budget = 1500
        var start = 0
        while start < input.count {
            let chunk = Array(input[start..<min(start + bufferFrames, input.count)])
            shedder.append(frames: chunk.count) { frame, _ in chunk[frame] }
            budget -= shedder.shed(budget: budget)
            _ = shedder.take(shedder.releasable(holdingBack: true))
            start += chunk.count
        }
        XCTAssertGreaterThanOrEqual(budget, 0)
        XCTAssertLessThanOrEqual(shedder.totalFramesShed, 1500)
    }

    func testLeavesNoiseAloneRatherThanSmearingIt() {
        var shedder = AudioBacklogShedder(channels: 1, sampleRate: rate)
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<20_000).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        _ = run(noise, budget: .max, shedder: &shedder)
        // Uncorrelated material has no period to splice on; the receiver
        // waits for material that does (or the ceiling trim, for an outage).
        XCTAssertLessThan(shedder.splicedFramesShed, 2 * shedder.maxShiftFrames)
    }

    func testResetDiscardsHeldAudio() {
        var shedder = AudioBacklogShedder(channels: 2, sampleRate: rate)
        shedder.append(frames: 3000) { _, _ in 0.25 }
        shedder.reset()
        XCTAssertEqual(shedder.pendingFrames, 0)
        XCTAssertEqual(shedder.take(100)[0], [])
    }
}
