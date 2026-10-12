#if os(visionOS)
import Foundation

/// Pairs a primary video stream's frames with its depth auxiliary's by
/// `frameNumber`, the auxiliary-stream rule of NATIVE_V3_PROTOCOL.md §4.2: an
/// auxiliary frame carries the same number as the primary frame it belongs to;
/// a primary frame whose auxiliary is missing is shown with the last good one.
///
/// The two streams decode independently, so either half can arrive first. A
/// depth frame that arrives first waits for its picture. A picture that
/// arrives first is held, and released with its own depth when that arrives,
/// or with the last good depth when the caller gives up on it (`expire`) or the
/// next picture arrives. Only one picture is held: a stream that has moved on
/// shows its newest frame, not a backlog.
///
/// Time-free and generic, so the policy is testable; the owner decides how
/// long a picture may wait.
nonisolated struct DepthFramePairer<Picture, Depth> {
    struct Pair {
        let frameNumber: UInt32
        let picture: Picture
        /// The frame's own depth, the last good one, or nil.
        let depth: Depth?
        /// True when `depth` belongs to an earlier frame.
        let depthIsStale: Bool
    }

    /// How many frames old the last good depth may be before it is dropped:
    /// beyond this the depth stream has stopped (unsubscribed, a decoder
    /// lost), and a stale map on a moving picture is worse than none.
    var maxStaleFrames: UInt32 = 30
    /// Depth frames kept waiting for their pictures.
    var maxWaitingDepth = 8

    private var heldPicture: (frameNumber: UInt32, picture: Picture)?
    private var waitingDepth: [(frameNumber: UInt32, depth: Depth)] = []
    private var lastGood: (frameNumber: UInt32, depth: Depth)?
    /// The newest picture received, held or already released.
    private var newestPicture: UInt32?

    init() {}

    /// Whether a picture is waiting for its depth.
    var isHoldingPicture: Bool { heldPicture != nil }

    /// A decoded picture. Returns what can be shown now.
    mutating func receive(picture: Picture, frameNumber: UInt32) -> [Pair] {
        var released: [Pair] = []
        if newestPicture.map({ Self.isBefore($0, frameNumber) }) ?? true {
            newestPicture = frameNumber
        }
        if let held = heldPicture {
            released.append(pairWithFallback(held.frameNumber, held.picture))
            heldPicture = nil
        }
        if let index = waitingDepth.firstIndex(where: { $0.frameNumber == frameNumber }) {
            let depth = waitingDepth.remove(at: index).depth
            noteGood(depth, frameNumber: frameNumber)
            released.append(Pair(frameNumber: frameNumber, picture: picture, depth: depth, depthIsStale: false))
        } else {
            heldPicture = (frameNumber, picture)
        }
        return released
    }

    /// A decoded depth frame. Returns the held picture if this is its depth.
    mutating func receive(depth: Depth, frameNumber: UInt32) -> [Pair] {
        if let held = heldPicture, held.frameNumber == frameNumber {
            heldPicture = nil
            noteGood(depth, frameNumber: frameNumber)
            return [Pair(frameNumber: frameNumber, picture: held.picture, depth: depth, depthIsStale: false)]
        }
        // Depth for a picture already shown is too late to use, but it is
        // still the newest good depth.
        if let newest = newestPicture, frameNumber == newest || Self.isBefore(frameNumber, newest) {
            noteGood(depth, frameNumber: frameNumber)
            return []
        }
        waitingDepth.append((frameNumber, depth))
        if waitingDepth.count > maxWaitingDepth {
            waitingDepth.removeFirst(waitingDepth.count - maxWaitingDepth)
        }
        return []
    }

    /// Gives up waiting for the held picture's depth.
    mutating func expire() -> Pair? {
        guard let held = heldPicture else { return nil }
        heldPicture = nil
        return pairWithFallback(held.frameNumber, held.picture)
    }

    mutating func reset() {
        heldPicture = nil
        waitingDepth.removeAll()
        lastGood = nil
        newestPicture = nil
    }

    private mutating func noteGood(_ depth: Depth, frameNumber: UInt32) {
        if let last = lastGood, Self.isBefore(frameNumber, last.frameNumber) { return }
        lastGood = (frameNumber, depth)
        waitingDepth.removeAll { !Self.isBefore(frameNumber, $0.frameNumber) }
    }

    private func pairWithFallback(_ frameNumber: UInt32, _ picture: Picture) -> Pair {
        guard let last = lastGood, frameNumber &- last.frameNumber <= maxStaleFrames,
              !Self.isBefore(frameNumber, last.frameNumber) else {
            return Pair(frameNumber: frameNumber, picture: picture, depth: nil, depthIsStale: false)
        }
        return Pair(frameNumber: frameNumber, picture: picture, depth: last.depth, depthIsStale: last.frameNumber != frameNumber)
    }

    /// Serial-number order for a wrapping 32-bit counter (RFC 1982).
    static func isBefore(_ a: UInt32, _ b: UInt32) -> Bool {
        a != b && Int32(bitPattern: a &- b) < 0
    }
}
#endif
