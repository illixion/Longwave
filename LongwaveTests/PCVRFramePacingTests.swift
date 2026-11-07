import XCTest
import Metal
import simd
@testable import Longwave

/// Paced playout: one frame per display slot, in order, with the delay set by
/// the arrivals. Timelines are written out, not waited for.
#if FOVEATED_ENABLED
final class PCVRFramePacingTests: XCTestCase {
    private struct Frame: PCVRTimedPlayoutFrame, Equatable {
        var streamEpoch: UInt32 = 0
        let frameNumber: UInt32
        var spaceEpoch: UInt16 = 0
        let arrivalTime: TimeInterval
        var displayTime: TimeInterval = 0
        var poseSequence: UInt32 = 0
    }

    private let period = 1.0 / 90

    /// Frame n arrives at n periods plus `offset(n)`; the display takes at whole
    /// periods. Returns what each take showed (nil for nothing).
    private func run(_ queue: inout PCVRPacedFrameQueue<Frame>, frames: Int, takes: Int,
                     offset: (Int) -> TimeInterval) -> [UInt32?] {
        var arrivals = (0..<frames).map { n in Frame(frameNumber: UInt32(n), arrivalTime: Double(n) * period + offset(n)) }
        var shown: [UInt32?] = []
        for slot in 0..<takes {
            let now = Double(slot) * period
            while let next = arrivals.first, next.arrivalTime <= now { _ = queue.deliver(arrivals.removeFirst()) }
            let p = queue.takeForPresentation(spaceEpoch: 0, now: now)
            shown.append(p.isNew ? p.frame?.frameNumber : nil)
        }
        return shown
    }

    func testArrivalsJitteringAcrossTheSlotBoundaryPlayOnePerSlot() {
        // Frames land 1 ms either side of the slot: latest-wins repeats one and
        // drops the next every time one is late.
        var queue = PCVRPacedFrameQueue<Frame>()
        let shown = run(&queue, frames: 400, takes: 400) { n in n % 3 == 0 ? 0.001 : -0.001 }
        // After the first late frame the stream runs a slot behind, smoothly.
        let settled = Array(shown.dropFirst(5))
        XCTAssertFalse(settled.contains(nil), "no repeats once settled: \(shown.prefix(12))")
        let numbers = settled.compactMap { $0 }
        XCTAssertEqual(numbers, Array(numbers.first!...numbers.last!), "every frame, in order")
        XCTAssertEqual(queue.trimmed, 0, "the slot of delay is needed, so it stays")
        XCTAssertLessThanOrEqual(queue.repeated, 2)
    }

    /// Frames every `source` seconds (plus `offset`), takes every `display`.
    private func runRates(_ queue: inout PCVRPacedFrameQueue<Frame>, source: TimeInterval, display: TimeInterval,
                          takes: Int, offset: (Int) -> TimeInterval) -> [UInt32?] {
        let frames = Int(Double(takes) * display / source) + 2
        var arrivals = (0..<frames).map { n in Frame(frameNumber: UInt32(n), arrivalTime: Double(n) * source + offset(n)) }
        var shown: [UInt32?] = []
        for slot in 0..<takes {
            let now = Double(slot) * display
            while let next = arrivals.first, next.arrivalTime <= now { _ = queue.deliver(arrivals.removeFirst()) }
            let p = queue.takeForPresentation(spaceEpoch: 0, now: now)
            shown.append(p.isNew ? p.frame?.frameNumber : nil)
        }
        return shown
    }

    /// How many slots each frame stayed up for, in order.
    private func holds(_ shown: [UInt32?]) -> [Int] {
        var result: [Int] = []
        for entry in shown {
            if entry != nil { result.append(1) } else if !result.isEmpty { result[result.count - 1] += 1 }
        }
        return result
    }

    func testAHalfRateSourceIsHeldTwoSlotsEachThroughJitter() {
        // 60 fps on a 120 Hz display, frames landing 1 ms either side of a
        // slot: shown as they come that would be holds of 3 and 1.
        var queue = PCVRPacedFrameQueue<Frame>()
        let display = 1.0 / 120, source = 1.0 / 60
        let shown = runRates(&queue, source: source, display: display, takes: 1200) { n in n % 3 == 0 ? 0.001 : -0.001 }
        XCTAssertEqual(queue.cadence, 2)
        let settled = holds(Array(shown.dropFirst(300))).dropFirst().dropLast()
        XCTAssertEqual(Set(settled), [2], "every frame up for exactly two slots: \(Array(settled.prefix(20)))")
    }

    func testAHalfRateSourceGivesBackASlotByShorteningAHold() {
        // Frames arrive half a slot early, until one is held up 1.2 slots on
        // the network: from then on the stream runs a slot later than it must.
        var queue = PCVRPacedFrameQueue<Frame>()
        queue.window = 30
        let display = 1.0 / 120, source = 1.0 / 60
        let shown = runRates(&queue, source: source, display: display, takes: 1200) { n in
            n == 200 ? 1.2 * display : -0.5 * display
        }
        XCTAssertGreaterThanOrEqual(queue.trimmed, 1)
        XCTAssertLessThan(queue.lastWait, display, "shown in the slot it arrived for")
        let tail = holds(Array(shown.suffix(400))).dropFirst().dropLast()
        XCTAssertEqual(Set(tail), [2])
        XCTAssertEqual(queue.dropped, 0, "no frame skipped to do it")
    }

    func testANinetyHertzSourceOnOneTwentyIsNotHeld() {
        var queue = PCVRPacedFrameQueue<Frame>()
        let shown = runRates(&queue, source: 1.0 / 90, display: 1.0 / 120, takes: 1200) { _ in 0.0005 }
        XCTAssertEqual(queue.cadence, 1)
        let numbers = shown.dropFirst(200).compactMap { $0 }
        XCTAssertEqual(numbers, Array(numbers.first!...numbers.last!), "every frame, in order")
    }

    func testDelayNobodyNeedsIsGivenBack() {
        // Frames arrive mid-slot, but an early burst left the queue a frame
        // ahead: every frame waits more than a period for nothing.
        var queue = PCVRPacedFrameQueue<Frame>()
        queue.window = 30
        _ = queue.deliver(Frame(frameNumber: 0, arrivalTime: -2 * period))
        let shown = run(&queue, frames: 200, takes: 190) { _ in -1.5 * period }
        XCTAssertEqual(queue.trimmed, 1)
        XCTAssertLessThan(queue.lastWait, period, "back to showing each frame in the slot it arrived for")
        XCTAssertFalse(shown.dropFirst(2).contains(nil))
    }

    func testAPileUpIsDroppedToOneWaiting() {
        var queue = PCVRPacedFrameQueue<Frame>()
        for n in 0..<5 { _ = queue.deliver(Frame(frameNumber: UInt32(n), arrivalTime: 0)) }
        let p = queue.takeForPresentation(spaceEpoch: 0, now: 0.05)
        XCTAssertEqual(p.frame?.frameNumber, 3)
        XCTAssertEqual(p.released.map(\.frameNumber), [0, 1, 2])
        XCTAssertEqual(queue.queued.map(\.frameNumber), [4])
        XCTAssertEqual(queue.takeForPresentation(spaceEpoch: 0, now: 0.06).frame?.frameNumber, 4)
    }

    func testAnEmptySlotRepeatsAndLateFramesAreDropped() {
        var queue = PCVRPacedFrameQueue<Frame>()
        XCTAssertNil(queue.takeForPresentation(spaceEpoch: 0, now: 0).frame)
        _ = queue.deliver(Frame(frameNumber: 5, arrivalTime: 0))
        XCTAssertEqual(queue.takeForPresentation(spaceEpoch: 0, now: period).isNew, true)
        let repeatShown = queue.takeForPresentation(spaceEpoch: 0, now: 2 * period)
        XCTAssertEqual(repeatShown.frame?.frameNumber, 5)
        XCTAssertFalse(repeatShown.isNew)
        XCTAssertEqual(queue.deliver(Frame(frameNumber: 4, arrivalTime: 0)).map(\.frameNumber), [4], "older than shown")
        XCTAssertEqual(queue.repeated, 1)
        XCTAssertEqual(queue.dropped, 1)
    }

    func testANewStreamRunReplacesTheOldRunsQueue() {
        var queue = PCVRPacedFrameQueue<Frame>()
        _ = queue.deliver(Frame(frameNumber: 100, arrivalTime: 0))
        _ = queue.deliver(Frame(frameNumber: 101, arrivalTime: 0))
        let released = queue.deliver(Frame(streamEpoch: 1, frameNumber: 0, arrivalTime: 0))
        XCTAssertEqual(released.map(\.frameNumber), [100, 101])
        XCTAssertEqual(queue.takeForPresentation(spaceEpoch: 0, now: 0).frame?.frameNumber, 0)
    }

    func testFramesFromAnotherSpaceEpochAreNeverShown() {
        var queue = PCVRPacedFrameQueue<Frame>()
        _ = queue.deliver(Frame(frameNumber: 1, spaceEpoch: 0, arrivalTime: 0))
        _ = queue.deliver(Frame(frameNumber: 2, spaceEpoch: 1, arrivalTime: 0))
        let p = queue.takeForPresentation(spaceEpoch: 1, now: 0)
        XCTAssertEqual(p.frame?.frameNumber, 2)
        XCTAssertEqual(queue.dropped, 1)
    }

    func testThePeriodIsMeasuredFromTheTakes() {
        var queue = PCVRPacedFrameQueue<Frame>()
        for slot in 0..<200 { _ = queue.takeForPresentation(spaceEpoch: 0, now: Double(slot) / 100) }
        XCTAssertEqual(queue.period, 0.01, accuracy: 0.0002)
    }

    // MARK: Timed

    /// Frames every `source` seconds, each rendered for `lead` after it was
    /// started and arriving `latency(n)` after that; slots every `display`. A
    /// frame written at a slot is shown in the next one. Returns, per frame
    /// shown, how far its slot's display time was from its render display time.
    private func runTimed(source: TimeInterval, display: TimeInterval, seconds: TimeInterval, lead: TimeInterval,
                          latency: (Int) -> TimeInterval) -> (errors: [TimeInterval], shown: [UInt32], queue: PCVRPacedFrameQueue<Frame>) {
        var queue = PCVRPacedFrameQueue<Frame>()
        let count = Int(seconds / source)
        var frames = (0..<count).map { n -> Frame in
            let start = Double(n) * source
            return Frame(frameNumber: UInt32(n), arrivalTime: start + latency(n), displayTime: start + lead)
        }
        frames.sort { $0.arrivalTime < $1.arrivalTime }
        var errors: [TimeInterval] = [], shown: [UInt32] = []
        for slot in 0..<Int(seconds / display) {
            let now = Double(slot) * display
            while let next = frames.first, next.arrivalTime <= now { _ = queue.deliver(frames.removeFirst()) }
            let showAt = now + display
            let p = queue.takeForPresentation(spaceEpoch: 0, now: now, until: showAt + display / 2)
            if p.isNew, let frame = p.frame {
                errors.append(showAt - frame.displayTime)
                shown.append(frame.frameNumber)
            }
        }
        return (errors, shown, queue)
    }

    func testTimedPlayoutShowsEachFrameInItsOwnSlotAtAnyRate() {
        // 50 fps on 120 Hz, 75 on 90 and 90 on 100: no whole cadence, 4 ms of
        // arrival jitter, and a horizon that covers arrival plus the slot a
        // write takes before its show (the presenter sizes it so: 24 + 2 x 11 ms).
        let rates: [(source: TimeInterval, display: TimeInterval)] = [(1.0 / 50, 1.0 / 120), (1.0 / 75, 1.0 / 90), (1.0 / 90, 1.0 / 100)]
        for (source, display) in rates {
            let run = runTimed(source: source, display: display, seconds: 4, lead: 0.05) { n -> TimeInterval in
                n % 3 == 0 ? 0.024 : 0.02
            }
            let worst: TimeInterval = run.errors.dropFirst(5).map { abs($0) }.max() ?? 1
            XCTAssertLessThanOrEqual(worst, display / 2 + 1e-9, "every frame within half a slot of its time (\(source), \(display))")
            let numbers = run.shown.dropFirst(5)
            XCTAssertEqual(Array(numbers), Array(numbers.first!...numbers.last!), "every frame shown, in order")
        }
    }

    func testTimedPlayoutShowsALateFrameAtOnceAndSkipsWhatItsLatenessCovered() {
        // A 90 fps source whose frame 100 arrives 30 ms late, after the two behind it.
        let run = runTimed(source: 1.0 / 90, display: 1.0 / 90, seconds: 3, lead: 0.045) { n in n == 100 ? 0.05 : 0.02 }
        XCTAssertFalse(run.shown.contains(100), "superseded by the frames meant for its slot and after")
        XCTAssertTrue(run.shown.contains(101))
        // Its own slot repeats the frame before (nothing else was meant for it),
        // and the stream does not fall behind: the frames after it keep their slots.
        XCTAssertLessThanOrEqual(run.queue.repeated, 1)
        let after = zip(run.shown, run.errors).filter { $0.0 > 101 }.map { abs($0.1) }
        XCTAssertLessThanOrEqual(after.max() ?? 1, 1.0 / 180 + 1e-9)
    }

    func testTimedPlayoutTellsThePresenterWhatArrived() {
        var queue = PCVRPacedFrameQueue<Frame>()
        _ = queue.deliver(Frame(frameNumber: 1, arrivalTime: 0.5, poseSequence: 41))
        _ = queue.deliver(Frame(frameNumber: 2, arrivalTime: 0.6, poseSequence: 43))
        let arrivals = queue.drainArrivals()
        XCTAssertEqual(arrivals.map(\.poseSequence), [41, 43])
        XCTAssertEqual(arrivals.map(\.time), [0.5, 0.6])
        XCTAssertTrue(queue.drainArrivals().isEmpty)
    }

    func testThePacedMailboxHandsOutFramesInOrder() {
        let mailbox = PCVRFrameMailbox(playout: .paced)
        let device = try? XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard let device, let texture = device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 2, height: 1, mipmapped: false)) else { return }
        let eye = PCVREyeView(pose: PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: .zero),
                              fieldOfView: PCVRFieldOfView(tangentLeft: -1, tangentRight: 1, tangentUp: 1, tangentDown: -1))
        let pose = PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: 0, eyes: PCVRStereo(left: eye, right: eye))
        for n in UInt32(1)...2 {
            mailbox.deliver(PCVRDecodedFrame(streamEpoch: 0, frameNumber: n, texture: texture, renderPose: pose, arrivalTime: 0))
        }
        XCTAssertEqual(mailbox.takeForPresentation(spaceEpoch: 0, now: 0.01)?.frame.frameNumber, 1)
        XCTAssertEqual(mailbox.takeForPresentation(spaceEpoch: 0, now: 0.02)?.frame.frameNumber, 2)
        XCTAssertEqual(mailbox.pacing?.trimmed, 0)
    }
}
#endif
