#if FOVEATED_ENABLED
import Foundation
import Metal
import os

/// §4.7's `renderPose` side data: what a frame was rendered for. The receiver
/// shows the frame where it was rendered, not where the head is now, so without
/// this it cannot reproject at all.
/// Counters that wrap, compared the way the v3 wire compares them (StreamWire's
/// `SerialNumber`): anything less than half the range ahead counts as newer.
nonisolated enum PCVRSerialNumber {
    static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        a != b && a &- b < 0x8000_0000
    }
}

nonisolated struct PCVRRenderPose: Equatable, Sendable {
    /// The head-pose snapshot (`PCVRHeadPoseSnapshot.sequence`) the host rendered from.
    var poseSequence: UInt32
    /// The space epoch of that snapshot, so a recentre between pose and render
    /// can be told apart from head motion.
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
    /// Per stream, wraps (compare with `PCVRSerialNumber`).
    let frameNumber: UInt32
    let texture: any MTLTexture
    let renderPose: PCVRRenderPose
    /// When the frame became presentable (decode finished), receiver clock.
    let arrivalTime: TimeInterval
    private let release: (@Sendable () -> Void)?

    init(frameNumber: UInt32, texture: any MTLTexture, renderPose: PCVRRenderPose,
         arrivalTime: TimeInterval, release: (@Sendable () -> Void)? = nil) {
        self.frameNumber = frameNumber
        self.texture = texture
        self.renderPose = renderPose
        self.arrivalTime = arrivalTime
        self.release = release
    }

    deinit { release?() }
}

/// A frame the playout slot can order: its per-stream number, which wraps.
nonisolated protocol PCVRNumberedFrame {
    var frameNumber: UInt32 { get }
}

extension PCVRDecodedFrame: PCVRNumberedFrame {}

/// Latest-wins playout, as pure bookkeeping (§4.7 Pacing: a frame that misses
/// its display slot is dropped, never queued; a display slot with no new frame
/// repeats the last one, which reprojection then moves to the new head pose).
///
/// Every mutating call returns the frame it displaced, if any, so a caller
/// holding a lock can let that last reference go after unlocking.
nonisolated struct PCVRLatestFrameSlot<Frame: PCVRNumberedFrame> {
    private(set) var pending: Frame?
    private(set) var current: Frame?
    /// Frames that arrived and were replaced before any display slot showed
    /// them, or that arrived older than one already received.
    private(set) var dropped = 0
    /// Display slots that showed a frame already shown before.
    private(set) var repeated = 0
    /// Display slots that showed a frame for the first time.
    private(set) var presentedNew = 0

    init() {}

    @discardableResult
    mutating func deliver(_ frame: Frame) -> Frame? {
        // Late or reordered: showing it would step the picture backwards.
        if let newest = pending ?? current, !PCVRSerialNumber.isNewer(frame.frameNumber, than: newest.frameNumber) {
            dropped += 1
            return frame
        }
        let displaced = pending
        if displaced != nil { dropped += 1 }
        pending = frame
        return displaced
    }

    /// The frame for the next display slot, whether it is new, and the frame it
    /// replaced as current. Nil before the first frame arrives.
    mutating func takeForPresentation() -> (frame: Frame, isNew: Bool, displaced: Frame?)? {
        if let next = pending {
            pending = nil
            let displaced = current
            current = next
            presentedNew += 1
            return (next, true, displaced)
        }
        guard let current else { return nil }
        repeated += 1
        return (current, false, nil)
    }

    /// Forget every frame (a reconnect or a stream change) but keep the counts.
    /// Returns the frames it let go of.
    mutating func reset() -> (Frame?, Frame?) {
        defer {
            pending = nil
            current = nil
        }
        return (pending, current)
    }
}

/// The thread-safe hand-off between a frame producer (the decoder, or the fake
/// remote) and the presenter's render loop.
nonisolated final class PCVRFrameMailbox: @unchecked Sendable {
    private let slot = OSAllocatedUnfairLock(initialState: PCVRLatestFrameSlot<PCVRDecodedFrame>())

    // Every method takes the frame the slot let go of out of the lock and lets it
    // drop after unlocking: it may be that frame's last reference, and its
    // release callback (a texture going back to a pool) must not run locked.

    func deliver(_ frame: PCVRDecodedFrame) {
        let displaced = slot.withLock { $0.deliver(frame) }
        withExtendedLifetime(displaced) {}
    }

    func takeForPresentation() -> (frame: PCVRDecodedFrame, isNew: Bool)? {
        guard let taken = slot.withLock({ $0.takeForPresentation() }) else { return nil }
        withExtendedLifetime(taken.displaced) {}
        return (taken.frame, taken.isNew)
    }

    var counts: (dropped: Int, repeated: Int, presentedNew: Int) {
        slot.withLock { ($0.dropped, $0.repeated, $0.presentedNew) }
    }

    func reset() {
        let released = slot.withLock { $0.reset() }
        withExtendedLifetime(released) {}
    }
}
#endif
