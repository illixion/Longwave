#if FOVEATED_ENABLED
import DebugTrace
import Foundation
import os
import simd

/// A gaze sample on the head-pose uplink. Always invalid until the provider
/// entitlement brings gaze (§4.7 "What the entitlement adds later"); the field
/// exists now so the wire format doesn't change when it does.
nonisolated struct PCVRGazeSample: Equatable, Sendable {
    var direction: SIMD3<Float>
    var distance: Float
    var timestamp: TimeInterval
    var isValid: Bool

    static let invalid = PCVRGazeSample(direction: SIMD3(0, 0, -1), distance: 0, timestamp: 0, isValid: false)
}

/// §4.7's uplink head-pose STATE, as the plain value the v3 client will
/// serialise and send at the display rate. Nothing here is a wire encoding yet.
nonisolated struct PCVRHeadPoseSnapshot: Equatable, Sendable {
    var sequence: UInt64
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
    var spaceEpoch: UInt32
    /// Per-eye offsets and frusta: set on the first snapshot and whenever they
    /// change (IPD), nil otherwise.
    var eyes: PCVRStereo<PCVREyeGeometry>?
    /// The last frame shown and when, for motion-to-photon on every frame.
    var lastPresentedFrame: UInt64?
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
    private let epoch = OSAllocatedUnfairLock(initialState: UInt32(0))

    private var sequence: UInt64 = 0
    private var lastSentEyes: PCVRStereo<PCVREyeGeometry>?
    private var lastPresented: (frame: UInt64, time: TimeInterval)?
    /// Recent snapshots by sequence, to match a frame's `poseSequence` back to
    /// when and for what time its pose was taken.
    private var history: [(sequence: UInt64, sampledAt: TimeInterval, baseDisplayTime: TimeInterval)] = []
    private static let historyLength = 256
    private var smoothedLatency: TimeInterval?
    private var lastLogTime: TimeInterval = 0

    /// The current prediction horizon (zero until something has been measured).
    var predictionHorizon: TimeInterval {
        min(max(smoothedLatency ?? 0, 0), Self.maximumPredictionHorizon)
    }

    /// Starts a new space epoch: call when the immersive space's origin moves
    /// (a recentre). The next snapshot carries the new epoch and the eye offsets.
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
                      baseDisplayTime: TimeInterval, displayTime: TimeInterval) -> PCVRHeadPoseSnapshot {
        sequence += 1
        let spaceEpoch = epoch.withLock { $0 }
        let eyesChanged = lastSentEyes.map { !($0.left.isClose(to: eyes.left) && $0.right.isClose(to: eyes.right)) } ?? true
        if eyesChanged { lastSentEyes = eyes }
        let snapshot = PCVRHeadPoseSnapshot(
            sequence: sequence,
            sampledAt: sampledAt,
            displayTime: displayTime,
            head: head,
            spaceEpoch: spaceEpoch,
            eyes: eyesChanged ? eyes : nil,
            lastPresentedFrame: lastPresented?.frame,
            lastPresentTime: lastPresented?.time,
            gaze: .invalid
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
    func recordPresentation(frameNumber: UInt64, poseSequence: UInt64,
                            presentTime: TimeInterval) -> TimeInterval? {
        lastPresented = (frameNumber, presentTime)
        guard let entry = history.last(where: { $0.sequence == poseSequence }) else { return nil }
        let latency = presentTime - entry.baseDisplayTime
        smoothedLatency = smoothedLatency.map { $0 + (latency - $0) * 0.1 } ?? latency
        return presentTime - entry.sampledAt
    }

    /// Forget measurements (a new stream): the next frames re-learn the horizon.
    func reset() {
        history.removeAll()
        smoothedLatency = nil
        lastPresented = nil
        lastSentEyes = nil
    }

    /// One line a second: enough to see the uplink is alive and sane in a trace
    /// without flooding the console at 90 Hz. Poses are room-scale numbers about
    /// the headset, not about the person, so they are logged as plain numbers.
    private func logIfDue(_ snapshot: PCVRHeadPoseSnapshot) {
        guard snapshot.sampledAt - lastLogTime >= 1 else { return }
        lastLogTime = snapshot.sampledAt
        let p = snapshot.head.position
        let ahead = (snapshot.displayTime - snapshot.sampledAt) * 1000
        log.info("Head pose #\(snapshot.sequence) epoch \(snapshot.spaceEpoch) at (\(p.x, format: .fixed(precision: 3)), \(p.y, format: .fixed(precision: 3)), \(p.z, format: .fixed(precision: 3))) predicted \(ahead, format: .fixed(precision: 1)) ms ahead, horizon \(self.predictionHorizon * 1000, format: .fixed(precision: 1)) ms, last presented \(snapshot.lastPresentedFrame.map { Int($0) } ?? -1)\(snapshot.eyes != nil ? ", eye offsets changed" : "", privacy: .public)")
    }
}
#endif
