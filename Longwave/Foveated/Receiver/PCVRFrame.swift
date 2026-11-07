#if FOVEATED_ENABLED
import Foundation
import Metal
import os

/// Counters that wrap, compared the way the v3 wire compares them: anything
/// less than half the range ahead counts as newer.
///
/// Must match StreamWire's `SerialNumber.isNewer` (and the frame source's
/// `lw_fs_serial_newer`). It is a local copy only because the app does not
/// link the LongwaveStream package yet; replace it with `SerialNumber` when it
/// does. `PCVRPlayoutTests` mirrors StreamWire's wraparound cases.
nonisolated enum PCVRSerialNumber {
    static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && a &- b < 0x8000_0000
    }
}

/// §4.7's `renderPose` side data: what a frame was rendered for. The receiver
/// shows the frame where it was rendered, not where the head is now, so without
/// this it cannot reproject at all.
nonisolated struct PCVRRenderPose: Equatable, Sendable {
    /// The head-pose snapshot (`PCVRHeadPoseSnapshot.sequence`) the host rendered from.
    var poseSequence: UInt32
    /// The space epoch of that snapshot. A frame is only shown while the display
    /// pose is in the same epoch: across a recentre its pose means a different
    /// place, and reprojecting it would jump the picture.
    var spaceEpoch: UInt16
    /// The display time the host rendered for, on the receiver's clock.
    var displayTime: TimeInterval
    var eyes: PCVRStereo<PCVREyeView>
}

/// A decoded stereo frame ready to present: both eyes side by side in one
/// texture, left eye in the left half, plus the pose it was rendered at.
///
/// A class so the texture stays leased for exactly as long as anything still
/// needs it: the mailbox, the frame being presented, and every command buffer
/// that samples it (they retain the frame until they complete). `release` runs
/// when the last of those lets go, which is when a producer may reuse the
/// texture.
nonisolated final class PCVRDecodedFrame: @unchecked Sendable {
    /// Identifies one run of the stream's frame numbering. The producer bumps it
    /// whenever numbering starts over (a host reconnect or stream restart, a new
    /// format); the v3 client maps it from the stream's format generation.
    /// Wraps (compare with `PCVRSerialNumber`).
    let streamEpoch: UInt32
    /// Per stream epoch, wraps (compare with `PCVRSerialNumber`).
    let frameNumber: UInt32
    /// Both eyes side by side, at wire size: smaller than rendered when the
    /// host foveated it (`foveation`, which maps render UVs into it).
    let texture: any MTLTexture
    let renderPose: PCVRRenderPose
    /// The host's centre/edge warp for this frame, or nil for an unwarped one.
    let foveation: PCVRFoveation?
    /// When the frame became presentable (decode finished), receiver clock.
    let arrivalTime: TimeInterval
    private let release: (@Sendable () -> Void)?

    init(streamEpoch: UInt32, frameNumber: UInt32, texture: any MTLTexture, renderPose: PCVRRenderPose,
         foveation: PCVRFoveation? = nil, arrivalTime: TimeInterval, release: (@Sendable () -> Void)? = nil) {
        self.streamEpoch = streamEpoch
        self.frameNumber = frameNumber
        self.texture = texture
        self.renderPose = renderPose
        self.foveation = foveation
        self.arrivalTime = arrivalTime
        self.release = release
    }

    deinit { release?() }
}

/// What the playout slot needs to know about a frame.
nonisolated protocol PCVRPlayoutFrame {
    var streamEpoch: UInt32 { get }
    var frameNumber: UInt32 { get }
    var spaceEpoch: UInt16 { get }
}

extension PCVRDecodedFrame: PCVRTimedPlayoutFrame {
    var spaceEpoch: UInt16 { renderPose.spaceEpoch }
    var displayTime: TimeInterval { renderPose.displayTime }
    var poseSequence: UInt32 { renderPose.poseSequence }
}

/// Latest-wins playout, as pure bookkeeping (§4.7 Pacing: a frame that misses
/// its display slot is dropped, never queued; a display slot with no new frame
/// repeats the last one, which reprojection then moves to the new head pose).
///
/// Two epochs gate it. A newer stream epoch starts the frame numbering over, so
/// its frames are accepted whatever their numbers and the old run's pending
/// frame is dropped. A frame is presented only in its own space epoch; across a
/// recentre the slot shows nothing until frames rendered in the new epoch arrive.
///
/// Every mutating call returns the frames it let go of, so a caller holding a
/// lock can drop those last references after unlocking.
nonisolated struct PCVRLatestFrameSlot<Frame: PCVRPlayoutFrame> {
    /// What a display slot gets: the frame to show (nil for nothing), whether it
    /// is shown for the first time, and the frames the slot released.
    struct Presentation {
        var frame: Frame?
        var isNew: Bool
        var released: [Frame]
    }

    private(set) var pending: Frame?
    private(set) var current: Frame?
    /// Frames never shown: replaced before a display slot came, older than one
    /// already received, from an older stream epoch, or from another space epoch.
    private(set) var dropped = 0
    /// Display slots that showed a frame already shown before.
    private(set) var repeated = 0
    /// Display slots that showed a frame for the first time.
    private(set) var presentedNew = 0

    init() {}

    @discardableResult
    mutating func deliver(_ frame: Frame) -> Frame? {
        if let newest = pending ?? current {
            let restarted = PCVRSerialNumber.isNewer(frame.streamEpoch, than: newest.streamEpoch)
            let sameRun = frame.streamEpoch == newest.streamEpoch
            // From a stream run already replaced, or late or reordered within
            // this one: showing it would step the picture backwards.
            guard restarted || (sameRun && PCVRSerialNumber.isNewer(frame.frameNumber, than: newest.frameNumber)) else {
                dropped += 1
                return frame
            }
        }
        let displaced = pending
        if displaced != nil { dropped += 1 }
        pending = frame
        return displaced
    }

    /// The frame for the next display slot, shown at a display pose in `spaceEpoch`.
    mutating func takeForPresentation(spaceEpoch: UInt16) -> Presentation {
        var released: [Frame] = []
        if let next = pending {
            pending = nil
            if next.spaceEpoch == spaceEpoch {
                if let previous = current { released.append(previous) }
                current = next
                presentedNew += 1
                return Presentation(frame: next, isNew: true, released: released)
            }
            // Rendered for another origin; it can never be placed correctly.
            dropped += 1
            released.append(next)
        }
        guard let current, current.spaceEpoch == spaceEpoch else {
            return Presentation(frame: nil, isNew: false, released: released)
        }
        repeated += 1
        return Presentation(frame: current, isNew: false, released: released)
    }
}

/// The thread-safe hand-off between a frame producer (the decoder, or the fake
/// remote) and the presenter's render loop.
nonisolated final class PCVRFrameMailbox: @unchecked Sendable {
    /// How frames meet display slots.
    enum Playout: String, Sendable {
        /// The newest frame at each slot (`PCVRLatestFrameSlot`): least latency,
        /// for a presenter that reprojects each frame to the display pose.
        case latest
        /// One frame per slot in order, a slot behind when arrivals jitter
        /// (`PCVRPacedFrameQueue`): for a presenter that shows frames where they
        /// were rendered, where smooth motion is worth a slot of delay.
        case paced
        /// Each frame in the slot its render display time falls in
        /// (`PCVRPacedFrameQueue.takeForPresentation(spaceEpoch:now:until:)`):
        /// any source rate on any display rate.
        case timed
    }

    private enum Slot {
        case latest(PCVRLatestFrameSlot<PCVRDecodedFrame>)
        case paced(PCVRPacedFrameQueue<PCVRDecodedFrame>)
    }

    let playout: Playout
    private let slot: OSAllocatedUnfairLock<Slot>

    init(playout: Playout = .latest) {
        self.playout = playout
        slot = OSAllocatedUnfairLock(initialState: playout == .latest ? .latest(PCVRLatestFrameSlot()) : .paced(PCVRPacedFrameQueue()))
        // .timed uses the same queue, taken by display time.
    }

    // Every method takes the frames the slot let go of out of the lock and lets
    // them drop after unlocking: one may be a frame's last reference, and its
    // release callback (a texture going back to a pool) must not run locked.

    func deliver(_ frame: PCVRDecodedFrame) {
        let displaced: [PCVRDecodedFrame] = slot.withLock {
            switch $0 {
            case .latest(var latest):
                let displaced = latest.deliver(frame)
                $0 = .latest(latest)
                return displaced.map { [$0] } ?? []
            case .paced(var paced):
                let released = paced.deliver(frame)
                $0 = .paced(paced)
                return released
            }
        }
        withExtendedLifetime(displaced) {}
    }

    /// A `.timed` mailbox's next frame: the newest rendered for no later than `target`.
    func takeForPresentation(spaceEpoch: UInt16, now: TimeInterval, until target: TimeInterval)
        -> (frame: PCVRDecodedFrame, isNew: Bool)? {
        let taken: (frame: PCVRDecodedFrame?, isNew: Bool, released: [PCVRDecodedFrame]) = slot.withLock {
            guard case .paced(var queue) = $0 else { return (nil, false, []) }
            let p = queue.takeForPresentation(spaceEpoch: spaceEpoch, now: now, until: target)
            $0 = .paced(queue)
            return (p.frame, p.isNew, p.released)
        }
        withExtendedLifetime(taken.released) {}
        return taken.frame.map { ($0, taken.isNew) }
    }

    /// Frames delivered since the last call (pose sequence, arrival time); empty for `.latest`.
    func drainArrivals() -> [(poseSequence: UInt32, time: TimeInterval)] {
        slot.withLock {
            guard case .paced(var queue) = $0 else { return [] }
            let arrivals = queue.drainArrivals()
            $0 = .paced(queue)
            return arrivals
        }
    }

    /// The frame to show at a display pose in `spaceEpoch`, or nil for nothing.
    /// `now` (the `arrivalTime` clock) paces a `.paced` mailbox; `.latest` ignores it.
    func takeForPresentation(spaceEpoch: UInt16, now: TimeInterval = 0) -> (frame: PCVRDecodedFrame, isNew: Bool)? {
        let taken: (frame: PCVRDecodedFrame?, isNew: Bool, released: [PCVRDecodedFrame]) = slot.withLock {
            switch $0 {
            case .latest(var latest):
                let p = latest.takeForPresentation(spaceEpoch: spaceEpoch)
                $0 = .latest(latest)
                return (p.frame, p.isNew, p.released)
            case .paced(var paced):
                let p = paced.takeForPresentation(spaceEpoch: spaceEpoch, now: now)
                $0 = .paced(paced)
                return (p.frame, p.isNew, p.released)
            }
        }
        withExtendedLifetime(taken.released) {}
        return taken.frame.map { ($0, taken.isNew) }
    }

    var counts: (dropped: Int, repeated: Int, presentedNew: Int) {
        slot.withLock {
            switch $0 {
            case .latest(let s): (s.dropped, s.repeated, s.presentedNew)
            case .paced(let s): (s.dropped, s.repeated, s.presentedNew)
            }
        }
    }

    /// The paced queue's own measures, nil for `.latest`.
    var pacing: (trimmed: Int, periodMs: Double, lastWaitMs: Double, queued: Int)? {
        slot.withLock {
            guard case .paced(let s) = $0 else { return nil }
            return (s.trimmed, s.period * 1000, s.lastWait * 1000, s.queued.count)
        }
    }
}
#endif
