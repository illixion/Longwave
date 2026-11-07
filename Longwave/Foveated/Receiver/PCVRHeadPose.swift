#if FOVEATED_ENABLED
import DebugTrace
import Foundation
import os
import simd
import StreamWire
import RAVEInput

/// A gaze sample on the head-pose uplink. Device-relative, -Z forward.
/// `timestamp` is the capture time in CACurrentMediaTime seconds, never Date
/// or the predicted head-pose display time. Missing capture time means invalid.
nonisolated struct PCVRGazeSample: Equatable, Sendable {
    var direction: SIMD3<Float>
    var distance: Float
    var timestamp: TimeInterval
    var isValid: Bool

    /// Initial safety budget for foveation; tune from measured provider latency.
    static let maximumAge: TimeInterval = 0.1

    func wireSample(now: TimeInterval, negotiated: Bool,
                    hostTime: (TimeInterval) -> UInt64?) -> GazeSample? {
        let age = now - timestamp
        let length = simd_length(direction)
        guard negotiated, isValid, now.isFinite, timestamp.isFinite, timestamp >= 0,
              age >= 0, age <= Self.maximumAge,
              length.isFinite, length > 1e-6,
              distance.isFinite, distance >= 0,
              let time = hostTime(timestamp) else { return nil }
        let unit = direction / length
        return GazeSample(direction: Vector3(unit.x, unit.y, unit.z), distance: distance, sampleTime: time)
    }

    static func from(_ sample: RAVEGazeSample?, now: TimeInterval) -> Self {
        guard let sample, let capture = sample.localCaptureTime else { return .invalid }
        let gaze = Self(direction: sample.direction, distance: sample.distance ?? 0,
                        timestamp: capture, isValid: true)
        return gaze.wireSample(now: now, negotiated: true, hostTime: { _ in 0 }) == nil ? .invalid : gaze
    }

    static let invalid = PCVRGazeSample(direction: SIMD3(0, 0, -1), distance: 0, timestamp: 0, isValid: false)
}

/// §4.7's uplink head-pose STATE, as the plain value the v3 client will
/// serialise and send at the display rate. Nothing here is a wire encoding yet.
nonisolated struct PCVRHeadPoseSnapshot: Equatable, Sendable {
    /// Wraps; compare with `PCVRSerialNumber`.
    var sequence: UInt32
    /// When the pose was queried, receiver clock. Not on the wire; kept so a
    /// frame's pose-to-present time can be measured when it comes back.
    var sampledAt: TimeInterval
    /// The display time the pose was predicted for, on the receiver's clock.
    /// The v3 client converts it to host time (§5) when it sends it.
    var displayTime: TimeInterval
    /// Device pose in the immersive space.
    var head: PCVRPose
    /// Bumped whenever the immersive space's origin moves under the poses (a
    /// recentre), so the host never blends poses from two different origins.
    var spaceEpoch: UInt16
    /// Per-eye offsets and frusta, in every snapshot. STATE frames are
    /// unreliable, so a value sent only when it changed could be lost for good,
    /// and the host cannot render without the headset's per-eye projection
    /// (the encoding StreamWire settled for §4.7).
    var eyes: PCVRStereo<PCVREyeGeometry>
    /// The last frame shown and when, for motion-to-photon on every frame.
    var lastPresentedFrame: UInt32?
    var lastPresentTime: TimeInterval?
    var gaze: PCVRGazeSample
}

/// Produces the head-pose snapshots at the display rate and measures what came
/// back. Used from one thread, the presenter's render loop, except for
/// `bumpSpaceEpoch()`, which is safe from anywhere.
///
/// It also owns the prediction horizon: how far past the next drawable's
/// presentation time the pose should be predicted so that the host renders for
/// when its frame will actually be shown. That is the measured gap between the
/// display time a snapshot was taken for and the time its frame was finally
/// presented (encode, network, decode and playout), smoothed and clamped.
nonisolated final class PCVRHeadPoseProducer: @unchecked Sendable {
    /// Called with every snapshot, on the render thread. The v3 client sends it;
    /// the fake remote renders from it.
    var onSnapshot: (@Sendable (PCVRHeadPoseSnapshot) -> Void)?

    /// Longest horizon predicted past the drawable. ARKit's prediction degrades
    /// quickly beyond a few tens of milliseconds; past this, reprojection is the
    /// better bet than an extrapolated head.
    static let maximumPredictionHorizon: TimeInterval = 0.1

    private let log = DebugLogger(subsystem: "pro.longwave", category: "PCVRShell")
    /// A thread-safe gaze source (the official provider's push source, or a
    /// local feed's), read on the render thread. Only samples with a local
    /// capture time count. The session owner attaches/detaches the feed; its
    /// reset clears this view.
    private let gazeSource: (any RAVEGazeSource & Sendable)?

    init(gazeSource: (any RAVEGazeSource & Sendable)? = nil) {
        self.gazeSource = gazeSource
    }

    private let epoch = OSAllocatedUnfairLock(initialState: UInt16(0))

    private var sequence: UInt32 = 0
    private var lastPresented: (frame: UInt32, time: TimeInterval)?
    /// Recent snapshots by sequence, to match a frame's `poseSequence` back to
    /// when and for what time its pose was taken.
    private var history: [(sequence: UInt32, sampledAt: TimeInterval, baseDisplayTime: TimeInterval)] = []
    private static let historyLength = 256
    private var smoothedLatency: TimeInterval?
    private var lastLogTime: TimeInterval = 0

    /// What the prediction horizon is measured from.
    enum HorizonSource: Sendable {
        /// When frames were shown (smoothed): right for a presenter that shows
        /// each frame as soon as it can.
        case presentation
        /// When frames could first have been shown (`recordReadiness`), at the
        /// 90th percentile: for a presenter that holds each frame until the
        /// display time it was rendered for. Measured from presentation there,
        /// the horizon could only ever grow: a frame held to its time is shown
        /// exactly a horizon late, and one that came late raises it.
        case readiness
    }
    var horizonSource = HorizonSource.presentation
    /// Which readiness latency the `.readiness` horizon takes: 0.9 holds nearly
    /// every frame to its time (smoothest, a Wi-Fi tail adds its jitter to the
    /// latency of every frame); 0.5 shows the later half as they come.
    var readinessPercentile = 0.9
    private var readinessLatencies: [TimeInterval] = []
    private static let readinessWindow = 120

    /// The current prediction horizon (zero until something has been measured).
    var predictionHorizon: TimeInterval {
        let measured: TimeInterval?
        switch horizonSource {
        case .presentation:
            measured = smoothedLatency
        case .readiness:
            let sorted = readinessLatencies.sorted()
            let rank = Int(min(max(readinessPercentile, 0), 1) * Double(max(sorted.count - 1, 0)) + 0.5)
            measured = sorted.isEmpty ? nil : sorted[min(sorted.count - 1, rank)]
        }
        return min(max(measured ?? 0, 0), Self.maximumPredictionHorizon)
    }

    /// The recorded readiness latencies at 10, 50 and 90 per cent, seconds.
    var readinessQuantiles: (low: TimeInterval, median: TimeInterval, high: TimeInterval)? {
        let sorted = readinessLatencies.sorted()
        guard !sorted.isEmpty else { return nil }
        func at(_ q: Double) -> TimeInterval { sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1) + 0.5))] }
        return (at(0.1), at(0.5), at(0.9))
    }

    /// Records the earliest display time a frame could have been shown at (its
    /// decode finished, plus what the presenter needs to put it up), for the
    /// `.readiness` horizon.
    func recordReadiness(poseSequence: UInt32, readyDisplayTime: TimeInterval) {
        guard let entry = history.last(where: { $0.sequence == poseSequence }) else { return }
        readinessLatencies.append(readyDisplayTime - entry.baseDisplayTime)
        if readinessLatencies.count > Self.readinessWindow {
            readinessLatencies.removeFirst(readinessLatencies.count - Self.readinessWindow)
        }
    }

    /// The current space epoch: what the next snapshot carries, and what a
    /// frame's `renderPose.spaceEpoch` must equal for it to be presented.
    var spaceEpoch: UInt16 { epoch.withLock { $0 } }

    /// Starts a new space epoch: call when the immersive space's origin moves
    /// (a recentre). The next snapshot carries the new epoch, and frames rendered
    /// in the old one stop being presented. Nothing calls it on a real recentre
    /// yet: ARKit reports no recentre event, so detecting one is still open.
    func bumpSpaceEpoch() {
        epoch.withLock { $0 &+= 1 }
    }

    /// Makes the next snapshot and hands it to `onSnapshot`.
    /// - Parameters:
    ///   - head: The device pose predicted for `displayTime`.
    ///   - baseDisplayTime: The presentation time of the drawable this display
    ///     frame renders, before any prediction horizon was added.
    @discardableResult
    func makeSnapshot(head: PCVRPose, eyes: PCVRStereo<PCVREyeGeometry>, sampledAt: TimeInterval,
                      baseDisplayTime: TimeInterval, displayTime: TimeInterval,
                      gaze: PCVRGazeSample? = nil) -> PCVRHeadPoseSnapshot {
        sequence &+= 1
        let spaceEpoch = epoch.withLock { $0 }
        let snapshot = PCVRHeadPoseSnapshot(
            sequence: sequence,
            sampledAt: sampledAt,
            displayTime: displayTime,
            head: head,
            spaceEpoch: spaceEpoch,
            eyes: eyes,
            lastPresentedFrame: lastPresented?.frame,
            lastPresentTime: lastPresented?.time,
            gaze: gaze ?? .from(gazeSource?.latest, now: sampledAt)
        )
        history.append((sequence, sampledAt, baseDisplayTime))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        logIfDue(snapshot)
        onSnapshot?(snapshot)
        return snapshot
    }

    /// Records a frame shown for the first time. Returns its pose-to-present
    /// time (motion-to-photon for the content), or nil when its pose is too old
    /// to still be in the history.
    @discardableResult
    func recordPresentation(frameNumber: UInt32, poseSequence: UInt32,
                            presentTime: TimeInterval) -> TimeInterval? {
        lastPresented = (frameNumber, presentTime)
        guard let entry = history.last(where: { $0.sequence == poseSequence }) else { return nil }
        let latency = presentTime - entry.baseDisplayTime
        smoothedLatency = smoothedLatency.map { $0 + (latency - $0) * 0.1 } ?? latency
        return presentTime - entry.sampledAt
    }

    /// One line a second: enough to see the uplink is alive and sane in a trace
    /// without flooding the console at 90 Hz. Head position is a room-scale
    /// number about the headset and is logged plainly; the eye offsets are the
    /// wearer's IPD, a measurement of the person, and are not logged.
    private func logIfDue(_ snapshot: PCVRHeadPoseSnapshot) {
        guard snapshot.sampledAt - lastLogTime >= 1 else { return }
        lastLogTime = snapshot.sampledAt
        let p = snapshot.head.position
        let ahead = (snapshot.displayTime - snapshot.sampledAt) * 1000
        log.info("Head pose #\(snapshot.sequence) epoch \(snapshot.spaceEpoch) at (\(p.x, format: .fixed(precision: 3)), \(p.y, format: .fixed(precision: 3)), \(p.z, format: .fixed(precision: 3))) predicted \(ahead, format: .fixed(precision: 1)) ms ahead, horizon \(self.predictionHorizon * 1000, format: .fixed(precision: 1)) ms, last presented \(snapshot.lastPresentedFrame.map { Int($0) } ?? -1)")
    }
}
#endif
