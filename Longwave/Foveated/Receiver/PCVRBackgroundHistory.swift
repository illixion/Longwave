#if FOVEATED_ENABLED
import DebugTrace

/// Two time-separated observations are required for a background fill.
/// Three reduced-colour keyframes leave room for the newest one to age in.
nonisolated struct PCVRBackgroundHistory {
    static let toggle = "pcvr.warp.backgroundHistory"
    static var isEnabled: Bool {
        DebugTunables.boolean(toggle, false, label: "PCVR: fill exposed background from older frames")
    }

    private static let interval = 0.5
    private static let minimumAge = 0.18
    private static let maximumAge = 1.6
    private var samples: [PCVRDepthWarper.FillSource] = []

    mutating func expire(for frame: PCVRDecodedFrame) {
        samples.removeAll { sample in
            let age = frame.arrivalTime - sample.frame.arrivalTime
            return sample.frame.streamEpoch != frame.streamEpoch || sample.frame.spaceEpoch != frame.spaceEpoch ||
                age < 0 || age > Self.maximumAge
        }
    }

    func shouldSample(_ frame: PCVRDecodedFrame) -> Bool {
        guard let latest = samples.last else { return true }
        return frame.arrivalTime - latest.frame.arrivalTime >= Self.interval
    }

    mutating func remember(_ sample: PCVRDepthWarper.FillSource) {
        if samples.count == 3 { samples.removeFirst() }
        samples.append(sample)
    }

    func pair(for frame: PCVRDecodedFrame) -> PCVRDepthWarper.BackgroundSources? {
        let older = samples.filter { frame.arrivalTime - $0.frame.arrivalTime >= Self.minimumAge }
        guard older.count >= 2 else { return nil }
        return .init(newer: older[older.count - 1], older: older[older.count - 2])
    }
}
#endif
