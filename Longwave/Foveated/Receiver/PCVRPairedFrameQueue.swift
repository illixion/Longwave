#if FOVEATED_ENABLED
/// Joins independently decoded colour and depth without guessing geometry.
/// A late depth may match a recent pending colour; until then the last exact
/// pair stays available for reprojection. Neither arrival order nor frame-number
/// proximity establishes a match. One presenter thread owns this queue.
nonisolated struct PCVRPairedFrameQueue<Frame: PCVRPlayoutFrame, Depth> {
    struct Pair {
        var frame: Frame
        var depth: Depth
    }
    private(set) var pending: [Frame] = []
    private(set) var current: Pair?
    private(set) var held = 0
    private(set) var dropped = 0
    private let capacity: Int

    init(capacity: Int = 3) { self.capacity = max(1, capacity) }

    mutating func select(_ frame: Frame, exactDepth: (UInt32) -> Depth?) -> Pair? {
        if let previous = pending.last ?? current?.frame,
           previous.streamEpoch != frame.streamEpoch || previous.spaceEpoch != frame.spaceEpoch {
            pending.removeAll()
            current = nil
        }
        let newerThanCurrent = current.map { PCVRSerialNumber.isNewer(frame.frameNumber, than: $0.frame.frameNumber) } ?? true
        if newerThanCurrent, !pending.contains(where: { $0.frameNumber == frame.frameNumber }) {
            pending.append(frame)
            if pending.count > capacity {
                pending.removeFirst(pending.count - capacity)
                dropped += 1
            }
        }
        // Scan newest first, but don't lose an older colour whose depth arrived
        // while the newest one is still decoding.
        for index in pending.indices.reversed() {
            let candidate = pending[index]
            if let depth = exactDepth(candidate.frameNumber) {
                current = Pair(frame: candidate, depth: depth)
                dropped += index
                pending.removeFirst(index + 1)
                return current
            }
        }
        held += 1
        return current
    }
}
#endif
