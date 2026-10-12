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
    let texture: any MTLTexture
    let renderPose: PCVRRenderPose
    /// When the frame became presentable (decode finished), receiver clock.
    let arrivalTime: TimeInterval
    private let release: (@Sendable () -> Void)?

    init(streamEpoch: UInt32, frameNumber: UInt32, texture: any MTLTexture, renderPose: PCVRRenderPose,
         arrivalTime: TimeInterval, release: (@Sendable () -> Void)? = nil) {
        self.streamEpoch = streamEpoch
        self.frameNumber = frameNumber
        self.texture = texture
        self.renderPose = renderPose
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

extension PCVRDecodedFrame: PCVRPlayoutFrame {
    var spaceEpoch: UInt16 { renderPose.spaceEpoch }
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
    private let slot = OSAllocatedUnfairLock(initialState: PCVRLatestFrameSlot<PCVRDecodedFrame>())

    // Every method takes the frames the slot let go of out of the lock and lets
    // them drop after unlocking: one may be a frame's last reference, and its
    // release callback (a texture going back to a pool) must not run locked.

    func deliver(_ frame: PCVRDecodedFrame) {
        let displaced = slot.withLock { $0.deliver(frame) }
        withExtendedLifetime(displaced) {}
    }

    /// The frame to show at a display pose in `spaceEpoch`, or nil for nothing.
    func takeForPresentation(spaceEpoch: UInt16) -> (frame: PCVRDecodedFrame, isNew: Bool)? {
        let taken = slot.withLock { $0.takeForPresentation(spaceEpoch: spaceEpoch) }
        withExtendedLifetime(taken.released) {}
        return taken.frame.map { ($0, taken.isNew) }
    }

    var counts: (dropped: Int, repeated: Int, presentedNew: Int) {
        slot.withLock { ($0.dropped, $0.repeated, $0.presentedNew) }
    }
}
#endif
