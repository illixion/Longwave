#if FOVEATED_ENABLED
import Foundation
import Metal
import os

/// §4.7's `renderPose` side data: what a frame was rendered for. The receiver
/// shows the frame where it was rendered, not where the head is now, so without
/// this it cannot reproject at all.
nonisolated struct PCVRRenderPose: Equatable, Sendable {
    /// The head-pose snapshot (`PCVRHeadPoseSnapshot.sequence`) the host rendered from.
    var poseSequence: UInt64
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
    let frameNumber: UInt64
    let texture: any MTLTexture
    let renderPose: PCVRRenderPose
    /// When the frame became presentable (decode finished), receiver clock.
    let arrivalTime: TimeInterval
    private let release: (@Sendable () -> Void)?

    init(frameNumber: UInt64, texture: any MTLTexture, renderPose: PCVRRenderPose,
         arrivalTime: TimeInterval, release: (@Sendable () -> Void)? = nil) {
        self.frameNumber = frameNumber
        self.texture = texture
        self.renderPose = renderPose
        self.arrivalTime = arrivalTime
        self.release = release
    }

    deinit { release?() }
}

/// Latest-wins playout, as pure bookkeeping (§4.7 Pacing: a frame that misses
/// its display slot is dropped, never queued; a display slot with no new frame
/// repeats the last one, which reprojection then moves to the new head pose).
nonisolated struct PCVRLatestFrameSlot<Frame> {
    private(set) var pending: Frame?
    private(set) var current: Frame?
    /// Frames that arrived and were replaced before any display slot showed them.
    private(set) var dropped = 0
    /// Display slots that showed a frame already shown before.
    private(set) var repeated = 0
    /// Display slots that showed a frame for the first time.
    private(set) var presentedNew = 0

    init() {}

    mutating func deliver(_ frame: Frame) {
        if pending != nil { dropped += 1 }
        pending = frame
    }

    /// The frame for the next display slot, and whether it is new. Nil before
    /// the first frame arrives.
    mutating func takeForPresentation() -> (frame: Frame, isNew: Bool)? {
        if let next = pending {
            pending = nil
            current = next
            presentedNew += 1
            return (next, true)
        }
        guard let current else { return nil }
        repeated += 1
        return (current, false)
    }

    /// Forget every frame (a reconnect or a stream change) but keep the counts.
    mutating func reset() {
        pending = nil
        current = nil
    }
}

/// The thread-safe hand-off between a frame producer (the decoder, or the fake
/// remote) and the presenter's render loop.
nonisolated final class PCVRFrameMailbox: @unchecked Sendable {
    private let slot = OSAllocatedUnfairLock(initialState: PCVRLatestFrameSlot<PCVRDecodedFrame>())

    func deliver(_ frame: PCVRDecodedFrame) {
        // Swap under the lock, release outside it: a replaced frame's last
        // reference may go here, and its release callback must not run locked.
        let replaced: PCVRDecodedFrame? = slot.withLock { slot in
            let old = slot.pending
            slot.deliver(frame)
            return old
        }
        _ = replaced
    }

    func takeForPresentation() -> (frame: PCVRDecodedFrame, isNew: Bool)? {
        slot.withLock { $0.takeForPresentation() }
    }

    var counts: (dropped: Int, repeated: Int, presentedNew: Int) {
        slot.withLock { ($0.dropped, $0.repeated, $0.presentedNew) }
    }

    func reset() {
        let released: (PCVRDecodedFrame?, PCVRDecodedFrame?) = slot.withLock { slot in
            let frames = (slot.pending, slot.current)
            slot.reset()
            return frames
        }
        _ = released
    }
}
#endif
