#if FOVEATED_ENABLED
import Foundation

/// A playout frame that knows when it became presentable.
nonisolated protocol PCVRTimedPlayoutFrame: PCVRPlayoutFrame {
    /// When the frame could first have been shown (decode finished), on the
    /// same clock as the `now` its presenter passes in.
    var arrivalTime: TimeInterval { get }
    /// The display time it was rendered for (its render pose's), same clock.
    var displayTime: TimeInterval { get }
    /// The head-pose snapshot it was rendered from.
    var poseSequence: UInt32 { get }
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
/// A source at a whole fraction of the display rate (60 fps on 120 Hz) has
/// each frame held for exactly that many slots (`cadence`), so a frame a
/// millisecond late shifts the stream by a slot once instead of showing for
/// three slots and its successor for one.
///
/// That slot of delay is given back when it is not needed: if every frame over
/// `window` shows had already been waiting longer than a display period (plus
/// `margin`), each could have been shown a slot earlier. With a cadence of one
/// a frame is skipped for it; above one, a hold is a slot shorter (`trimmed`
/// either way). If frames pile up anyway (the presenter stalled), the oldest
/// are dropped until one is left waiting behind the frame shown.
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
    /// Slots of delay given back: frames skipped (also counted in `dropped`)
    /// at a cadence of one, holds shortened above it.
    private(set) var trimmed = 0
    /// Timed playout's hold-back: how long every frame is held past its render
    /// display time, whole display periods, so that frames that come late
    /// still land in slots a whole number apart.
    ///
    /// A frame rendered for a display time it cannot make (the prediction
    /// horizon capped short of the pipeline: Cyberpunk is ready 133 ms after
    /// its pose against a 100 ms cap, 2026-11-17) is eligible as soon as it
    /// arrives, and then its slot is decided by its arrival jitter: arrivals
    /// near a slot boundary show one frame for three slots and the next for
    /// one, or two in one slot and the first never (165 dropped and ~230
    /// missing of 22,900 frames at 45 fps on 90 Hz, about one hitch a second).
    /// Held back by how late frames come (`holdBackPercentile` of the lateness
    /// over `holdBackWindow` frames), each is due again in its own slot. Zero
    /// while frames come in time, which leaves on-time playout as it was.
    private(set) var holdBack: TimeInterval = 0
    /// Which lateness the hold-back covers: the rest are shown as they come.
    var holdBackPercentile = 0.95
    static var holdBackWindow: Int { 90 }
    /// The most a frame is held back: past this the stream is broken, not late.
    static var maximumHoldBack: TimeInterval { 0.1 }
    /// Frames sampled before the hold-back is trusted.
    static var holdBackMinimumSamples: Int { 20 }
    /// How far each recent frame's first possible slot was past its display time.
    private var lateness: [TimeInterval] = []
    /// The newest frame whose lateness was sampled (stream epoch, frame number).
    private var lastSampled: (epoch: UInt32, frame: UInt32)?

    /// The interval between frames, measured from their arrivals.
    private(set) var sourcePeriod: TimeInterval = 1.0 / 90
    /// Display slots per frame when the source runs at a whole fraction of
    /// the display rate, else 1 (frames shown as they come, one per slot).
    var cadence: Int {
        let ratio = sourcePeriod / period, whole = ratio.rounded()
        return whole >= 2 && abs(ratio - whole) < 0.1 ? Int(whole) : 1
    }
    /// The same whole cadence for this many frames in a row hands timed
    /// playout over to arrival order (`takeForPresentation(spaceEpoch:now:until:)`):
    /// the measured source period glides from its start through every ratio
    /// on its way to the true one.
    static var cadenceFrames: Int { 45 }
    private var streakCadence = 1
    private var cadenceStreak = 0
    /// The cadence settled on (1: none). Once settled it holds until the
    /// measured ratio has been more than `cadenceSlack` off it for
    /// `cadenceFrames` frames in a row: the measured period wanders with
    /// arrival jitter, and each time it left the narrow band that settles a
    /// cadence, playout fell back to display time for a second and dropped
    /// frames, 80 in 22 s once the broker waited longer for the game (headset,
    /// 2026-11-17).
    private(set) var settledCadence = 1
    private var offCadence = 0
    static var cadenceSlack: Double { 0.3 }

    /// The display period, measured from the takes.
    private(set) var period: TimeInterval = 1.0 / 90
    /// How long the frame shown last had waited for its slot.
    private(set) var lastWait: TimeInterval = 0

    private var lastTake: TimeInterval?
    private var lastArrival: TimeInterval?
    /// Frames delivered since `drainArrivals()`: pose sequence and arrival time.
    private(set) var arrivals: [(poseSequence: UInt32, time: TimeInterval)] = []
    private var minimumWait = TimeInterval.infinity
    private var waits = 0
    /// Slots the current frame has been shown in.
    private var heldSlots = 0
    /// A slot of delay to give back by cutting the current hold short.
    private var shortenHold = false

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
        if let lastArrival {
            // Bursts and gaps average out; only a stall is left out.
            let interval = frame.arrivalTime - lastArrival
            if interval >= 0, interval < 0.1 { sourcePeriod += 0.05 * (interval - sourcePeriod) }
        }
        lastArrival = frame.arrivalTime
        let now = cadence
        if now == streakCadence { cadenceStreak += 1 } else { streakCadence = now; cadenceStreak = 1 }
        if settledCadence > 1 {
            offCadence = abs(sourcePeriod / period - Double(settledCadence)) > Self.cadenceSlack ? offCadence + 1 : 0
            if offCadence >= Self.cadenceFrames {
                settledCadence = 1
                offCadence = 0
            }
        } else if streakCadence > 1, cadenceStreak >= Self.cadenceFrames {
            settledCadence = streakCadence
            offCadence = 0
        }
        arrivals.append((frame.poseSequence, frame.arrivalTime))
        if arrivals.count > Self.capacity * 4 { arrivals.removeFirst(arrivals.count - Self.capacity * 4) }
        queued.append(frame)
        while queued.count > Self.capacity {
            released.append(queued.removeFirst())
            dropped += 1
        }
        return released
    }

    /// The frames that arrived since the last call, oldest first.
    mutating func drainArrivals() -> [(poseSequence: UInt32, time: TimeInterval)] {
        defer { arrivals = [] }
        return arrivals
    }

    /// Timed playout: the newest frame rendered for a display time no later
    /// than `target` (the display time of the slot it will be shown in, plus
    /// half a slot), whatever the rates. Frames rendered for later wait; older
    /// eligible ones are superseded. With nothing eligible the slot repeats.
    ///
    /// The source runs at whatever rate it manages and every frame is shown
    /// in the slot its content was meant for, so animation moves at its own
    /// pace with no cadence to match: 50 fps on 120 Hz, or a game wavering
    /// between 70 and 90, holds each frame for as long as its time lasts.
    mutating func takeForPresentation(spaceEpoch: UInt16, now: TimeInterval, until target: TimeInterval) -> Presentation {
        // A source at a whole fraction of the display rate (45 fps on 90 Hz) plays
        // in arrival order, each frame held its cadence: by display time, frames
        // whose render display times jitter by a slot (they take the newest head
        // pose, on the display's own grid) came due two in one slot and one was
        // dropped, 53 of 713 in 16 s on the headset (2026-11-17), the microstutter
        // left once everything else was fixed. The hold-back is still measured,
        // for when the rate leaves the cadence.
        if settledCadence >= 2 {
            sampleLateness(slotTime: target - period / 2)
            return takeForPresentation(spaceEpoch: spaceEpoch, now: now)
        }
        if let lastTake {
            let interval = now - lastTake
            if interval > 1.0 / 150, interval < 1.0 / 40 { period += 0.05 * (interval - period) }
        }
        lastTake = now
        sampleLateness(slotTime: target - period / 2)
        var released: [Frame] = []
        var next: Frame?
        while let head = queued.first {
            if head.spaceEpoch != spaceEpoch {
                released.append(queued.removeFirst())
                dropped += 1
                continue
            }
            guard head.displayTime + holdBack <= target else { break }
            if let superseded = next {
                released.append(superseded)
                dropped += 1
            }
            next = queued.removeFirst()
        }
        guard let next else {
            guard let current, current.spaceEpoch == spaceEpoch else {
                return Presentation(frame: nil, isNew: false, released: released)
            }
            repeated += 1
            return Presentation(frame: current, isNew: false, released: released)
        }
        lastWait = now - next.arrivalTime
        if let previous = current { released.append(previous) }
        current = next
        presentedNew += 1
        return Presentation(frame: next, isNew: true, released: released)
    }

    /// Notes, for each frame queued since the last take, how far past its
    /// display time the first slot it could be shown in is (`slotTime`), and
    /// sets the hold-back from them. Measured from where a frame could first
    /// be shown, not where it was, so the hold-back never feeds itself.
    private mutating func sampleLateness(slotTime: TimeInterval) {
        var sampled = false
        for frame in queued {
            if let last = lastSampled, frame.streamEpoch == last.epoch,
               !PCVRSerialNumber.isNewer(frame.frameNumber, than: last.frame) { continue }
            lastSampled = (frame.streamEpoch, frame.frameNumber)
            lateness.append(slotTime - frame.displayTime)
            sampled = true
        }
        guard sampled else { return }
        if lateness.count > Self.holdBackWindow { lateness.removeFirst(lateness.count - Self.holdBackWindow) }
        guard lateness.count >= Self.holdBackMinimumSamples, period > 0 else { return }
        let sorted = lateness.sorted()
        let rank = Int(min(max(holdBackPercentile, 0), 1) * Double(sorted.count - 1) + 0.5)
        let late = sorted[min(sorted.count - 1, rank)]
        // Slots and display times sit on one grid, so lateness comes in whole
        // periods plus clock noise: the nearest whole number of them.
        let periods = max(0, (late / period).rounded())
        holdBack = min(periods * period, Self.maximumHoldBack)
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
        let showing = current.flatMap { $0.spaceEpoch == spaceEpoch ? $0 : nil }
        // The settled cadence when there is one: the measured one flickers with arrival jitter,
        // and a hold cut to one slot by a flicker is a stutter.
        let cadence = settledCadence > 1 ? settledCadence : self.cadence
        // Held for its cadence, unless frames are piling up behind it or a
        // slot of delay is being given back. Above a cadence of one, two may
        // wait: a late frame followed closely by the next is arrival jitter, and
        // cutting the hold for it showed one frame for a single slot.
        let piledUp = queued.count >= (cadence > 1 ? 3 : 2)
        let holding = showing != nil && heldSlots < cadence && !piledUp && !shortenHold
        guard !queued.isEmpty, !holding else {
            guard let showing else {
                return Presentation(frame: nil, isNew: false, released: released)
            }
            repeated += 1
            heldSlots += 1
            return Presentation(frame: showing, isNew: false, released: released)
        }
        if heldSlots < cadence, shortenHold { trimmed += 1 }
        shortenHold = false
        // Piled up: show the oldest that keeps at most one (two above a cadence of one) behind it.
        while queued.count > Self.queuedAfterTake + (cadence > 1 ? 2 : 1) {
            released.append(queued.removeFirst())
            dropped += 1
        }
        minimumWait = min(minimumWait, now - queued[0].arrivalTime)
        waits += 1
        if waits >= window, minimumWait > period + margin {
            // Every frame in the window was in time for the slot before its
            // own. Above a cadence of one, the next hold ends a slot early;
            // otherwise skip a frame, once the next has arrived to take its place.
            if cadence > 1 {
                shortenHold = true
                minimumWait = .infinity
                waits = 0
            } else if queued.count >= 2 {
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
        heldSlots = 1
        presentedNew += 1
        return Presentation(frame: next, isNew: true, released: released)
    }
}
#endif
