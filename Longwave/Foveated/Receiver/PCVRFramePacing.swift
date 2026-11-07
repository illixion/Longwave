#if FOVEATED_ENABLED
import Foundation

/// A playout frame that knows when it became presentable.
nonisolated protocol PCVRTimedPlayoutFrame: PCVRPlayoutFrame {
    /// When the frame could first have been shown (decode finished), on the
    /// same clock as the `now` its presenter passes in.
    var arrivalTime: TimeInterval { get }
}

/// In-order playout with a small delay that sets itself: one new frame per
/// display slot, in frame order, never two in one slot.
///
/// For a presenter that places each frame where it was rendered, so a frame
/// shown a slot later still holds still in the world and only its animation is
/// older. There, latest-wins (`PCVRLatestFrameSlot`) is the wrong trade: frames
/// from a 90 Hz host reach a 90 Hz display with a few milliseconds of jitter,
/// and when they arrive near the slot boundary latest-wins turns that jitter
/// into a repeat followed by a drop. On the headset that was one slot in five
/// (6,934 dropped and 6,404 repeated of 33,459, 2026-11-07), seen as
/// microstutter in anything animated. Here the frame that missed its slot is
/// shown in the next one and the stream simply runs a slot behind.
///
/// That slot of delay is given back when it is not needed: if every frame over
/// `window` takes had already been waiting longer than a display period (plus
/// `margin`), each could have been shown a slot earlier, so one frame is
/// skipped (`trimmed`). If frames pile up anyway (the presenter stalled), the
/// oldest are dropped until one is left waiting behind the frame shown.
nonisolated struct PCVRPacedFrameQueue<Frame: PCVRTimedPlayoutFrame> {
    struct Presentation {
        var frame: Frame?
        var isNew: Bool
        var released: [Frame]
    }

    /// Slack a frame must have beyond a display period before the delay is cut:
    /// covers how much the presenter's own ticks jitter.
    var margin: TimeInterval = 0.003
    /// Takes over which every frame must have waited too long before one is skipped.
    var window = 180
    /// Frames left waiting behind the one just shown; more are dropped.
    static var queuedAfterTake: Int { 1 }
    /// Frames held at most while nothing takes any.
    static var capacity: Int { 8 }

    private(set) var queued: [Frame] = []
    private(set) var current: Frame?
    /// Frames never shown: late or out of order, from a replaced stream run or
    /// another space epoch, piled up, or trimmed.
    private(set) var dropped = 0
    /// Display slots that showed a frame already shown before.
    private(set) var repeated = 0
    /// Display slots that showed a frame for the first time.
    private(set) var presentedNew = 0
    /// Frames skipped to give back a slot of delay (also counted in `dropped`).
    private(set) var trimmed = 0
    /// The display period, measured from the takes.
    private(set) var period: TimeInterval = 1.0 / 90
    /// How long the frame shown last had waited for its slot.
    private(set) var lastWait: TimeInterval = 0

    private var lastTake: TimeInterval?
    private var minimumWait = TimeInterval.infinity
    private var waits = 0

    init() {}

    /// Queues a frame; returns the frames let go of.
    mutating func deliver(_ frame: Frame) -> [Frame] {
        var released: [Frame] = []
        if let newest = queued.last ?? current {
            let restarted = PCVRSerialNumber.isNewer(frame.streamEpoch, than: newest.streamEpoch)
            let sameRun = frame.streamEpoch == newest.streamEpoch
            // From a stream run already replaced, or late or reordered within
            // this one: showing it would step the picture backwards.
            guard restarted || (sameRun && PCVRSerialNumber.isNewer(frame.frameNumber, than: newest.frameNumber)) else {
                dropped += 1
                return [frame]
            }
            if restarted {
                // The old run's frames are no longer worth their slots.
                dropped += queued.count
                released = queued
                queued = []
            }
        }
        queued.append(frame)
        while queued.count > Self.capacity {
            released.append(queued.removeFirst())
            dropped += 1
        }
        return released
    }

    /// The frame for the display slot at `now`, shown at a display pose in `spaceEpoch`.
    mutating func takeForPresentation(spaceEpoch: UInt16, now: TimeInterval) -> Presentation {
        if let lastTake {
            let interval = now - lastTake
            // Only plausible display intervals: a stall says nothing about the period.
            if interval > 1.0 / 150, interval < 1.0 / 40 { period += 0.05 * (interval - period) }
        }
        lastTake = now

        var released: [Frame] = []
        // Rendered for another origin; it can never be placed correctly.
        while let head = queued.first, head.spaceEpoch != spaceEpoch {
            released.append(queued.removeFirst())
            dropped += 1
        }
        guard !queued.isEmpty else {
            guard let current, current.spaceEpoch == spaceEpoch else {
                return Presentation(frame: nil, isNew: false, released: released)
            }
            repeated += 1
            return Presentation(frame: current, isNew: false, released: released)
        }
        // Piled up: show the older of the last two, keeping one behind it.
        while queued.count > Self.queuedAfterTake + 1 {
            released.append(queued.removeFirst())
            dropped += 1
        }
        minimumWait = min(minimumWait, now - queued[0].arrivalTime)
        waits += 1
        if waits >= window, minimumWait > period + margin {
            // Every frame in the window was in time for the slot before its
            // own. Skip one, once the next has arrived to take its place.
            if queued.count >= 2 {
                released.append(queued.removeFirst())
                dropped += 1
                trimmed += 1
                minimumWait = .infinity
                waits = 0
            }
        } else if waits >= window {
            minimumWait = .infinity
            waits = 0
        }
        let next = queued.removeFirst()
        lastWait = now - next.arrivalTime
        if let previous = current { released.append(previous) }
        current = next
        presentedNew += 1
        return Presentation(frame: next, isNew: true, released: released)
    }
}
#endif
