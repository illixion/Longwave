//  ControllerHandAssignment.swift
//
//  Works out which hand is holding the physical controller, so its IMU describes the
//  right wrist.
//
//  WHY THIS IS NEEDED AT ALL. The controller's gyro is a rotation rate for the object
//  the user is holding. Attributing it to the wrong hand is worse than not sending it:
//  a game reading angular velocity for a throw would fling from the empty hand, and the
//  dead-reckoning that keeps a controller pointing sensibly when ARKit loses sight of a
//  hand would steer the hand that never moved. The old sender copied one gyro onto BOTH
//  hands unconditionally, which is right for a two-handed gamepad grip — the ordinary way
//  a Switch Pro is held — and wrong the moment it is picked up in one hand like a wand.
//
//  WHY CORRELATION RATHER THAN A SETTING. We already have both signals: the controller
//  reports its own angular speed, and ARKit reports both wrists' orientations, from which
//  angular speed follows. A hand holding the controller moves with it; a hand that is not
//  does not. That makes every moment of motion a free labelled sample, the same bargain
//  the desk-Quest calibration strikes (see the PCVR design notes in
//  VisionVNC-PCVR-Host/docs/) — no ritual, no
//  "hold it up and press both triggers". A manual override still exists, because a user
//  who wants to pin it should not have to argue with a heuristic.
//
//  WHAT IS COMPARED. Angular SPEED only, not axes. Comparing axes would need the
//  controller's IMU frame aligned to the ARKit world frame, which is a calibration
//  problem of its own (and the Switch Pro's frame depends on how it is gripped). Speed is
//  frame-independent: |omega| is the same number in every orientation of the same
//  rotation, so a wrist and the controller it holds agree on it without any alignment.
//
//  Deliberately flag-free — no ARKit, no GameController, no FOVEATED_ENABLED — so it is
//  pure and unit-testable in the default build, mirroring FoveatedEndpoint and
//  GestureControllerMapping. The sender owns the sampling; this owns the decision.

import Foundation
import simd

/// Which hand (or hands) the controller's motion is attributed to.
enum ControllerHolder: String, Codable, Sendable, CaseIterable {
    /// A two-handed gamepad grip — both wrists move with it. The default, and the
    /// ordinary way a Switch Pro is held.
    case both
    case left
    case right
    /// Motion is present but we cannot say whose it is (and there is no override).
    /// Distinct from `both`: `both` is a positive finding, this is an absence of one.
    case unknown

    var claimsLeft: Bool { self == .both || self == .left }
    var claimsRight: Bool { self == .both || self == .right }

    /// Short label for the wrist HUD.
    var displayName: String {
        switch self {
        case .both:    "both hands"
        case .left:    "left hand"
        case .right:   "right hand"
        case .unknown: "unassigned"
        }
    }
}

/// The user's standing choice. `.auto` runs the correlation; the rest pin it.
enum ControllerHandPreference: String, Codable, Sendable, CaseIterable {
    case auto, both, left, right

    var displayName: String {
        switch self {
        case .auto:  "Automatic"
        case .both:  "Both hands"
        case .left:  "Left hand"
        case .right: "Right hand"
        }
    }

    /// The holder this preference forces, or nil for `.auto`.
    var forced: ControllerHolder? {
        switch self {
        case .auto:  nil
        case .both:  .both
        case .left:  .left
        case .right: .right
        }
    }
}

/// Rolling agreement between the controller's angular speed and each wrist's.
///
/// The measure is a windowed **mean absolute difference**, normalised by the window's
/// mean controller speed, and turned into a score in [0, 1]:
///
///     score = max(0, 1 - meanAbsDiff / meanControllerSpeed)
///
/// A hand rotating exactly with the controller scores 1; a still hand held against a
/// moving controller scores 0. Normalising by the controller's own speed is what makes
/// one threshold work for a gentle wrist turn and a fast swing alike — an absolute
/// rad/s tolerance would either reject slow motion or accept everything fast.
struct ControllerHandDetector {

    // MARK: Tuning
    //
    // These are first cuts chosen to be conservative in the direction that matters: it is
    // better to report `both` (the historical behaviour, and correct for a gamepad grip)
    // than to confidently pick the wrong single hand. On-device tuning pending.

    /// Below this the controller is effectively still, and every hand "agrees" with it.
    /// Samples under it are discarded rather than counted, or resting periods would
    /// slowly wash the window out to a tie.
    static let motionThreshold: Float = 0.35        // rad/s, ~20 deg/s

    /// Seconds of *moving* samples the window holds. Long enough to span a deliberate
    /// gesture, short enough that swapping hands is noticed within about a second.
    static let windowSeconds: Double = 1.5

    /// Moving samples required before any verdict is offered. At 83 Hz this is ~0.3 s of
    /// actual motion.
    static let minSamples = 25

    /// A hand must score at least this to be counted as holding the controller.
    static let claimScore: Float = 0.55

    /// ...and to be picked as the *sole* holder it must also beat the other hand by this
    /// margin. Without the margin, symmetric two-handed motion resolves to whichever hand
    /// noise favoured, and the controller's IMU would flap between wrists.
    static let soleMargin: Float = 0.20

    // MARK: State

    private struct Sample {
        var t: Double
        var controller: Float
        var leftDiff: Float?    // nil when that wrist was untracked for this sample
        var rightDiff: Float?
    }

    private var samples: [Sample] = []
    /// The last verdict, held through motionless stretches so the answer does not
    /// evaporate the moment the user stops moving.
    private(set) var holder: ControllerHolder = .unknown

    /// Scores behind the current verdict, for the HUD. nil until there is a verdict.
    private(set) var leftScore: Float?
    private(set) var rightScore: Float?

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        holder = .unknown
        leftScore = nil
        rightScore = nil
    }

    /// Feed one tick of angular speeds. Pass nil for a wrist ARKit is not tracking.
    /// `now` is a monotonic timestamp in seconds.
    ///
    /// Returns the current verdict, which is unchanged from the previous call unless this
    /// tick completed a fresh decision.
    @discardableResult
    mutating func update(controllerSpeed: Float,
                         leftWristSpeed: Float?,
                         rightWristSpeed: Float?,
                         now: Double) -> ControllerHolder {
        // Only motion carries information about who is holding it.
        if controllerSpeed >= Self.motionThreshold {
            samples.append(Sample(
                t: now,
                controller: controllerSpeed,
                leftDiff: leftWristSpeed.map { abs($0 - controllerSpeed) },
                rightDiff: rightWristSpeed.map { abs($0 - controllerSpeed) }))
        }
        // Age out, by time, regardless of whether this tick added anything — a window
        // that only advanced on motion would keep a stale verdict alive indefinitely.
        let cutoff = now - Self.windowSeconds
        if let first = samples.first, first.t < cutoff {
            samples.removeAll { $0.t < cutoff }
        }

        guard samples.count >= Self.minSamples else { return holder }

        var controllerSum: Float = 0
        var leftDiffSum: Float = 0, leftCount = 0
        var rightDiffSum: Float = 0, rightCount = 0
        for s in samples {
            controllerSum += s.controller
            if let d = s.leftDiff { leftDiffSum += d; leftCount += 1 }
            if let d = s.rightDiff { rightDiffSum += d; rightCount += 1 }
        }
        let meanController = controllerSum / Float(samples.count)
        guard meanController > 0 else { return holder }

        // A hand tracked for less than half the window cannot be judged: the samples it
        // does have are not a fair comparison against a hand present throughout.
        let quorum = samples.count / 2
        func score(_ diffSum: Float, _ count: Int) -> Float? {
            guard count > quorum else { return nil }
            return max(0, 1 - (diffSum / Float(count)) / meanController)
        }
        let left = score(leftDiffSum, leftCount)
        let right = score(rightDiffSum, rightCount)
        leftScore = left
        rightScore = right

        let leftClaims = (left ?? 0) >= Self.claimScore
        let rightClaims = (right ?? 0) >= Self.claimScore

        switch (leftClaims, rightClaims) {
        case (true, true):
            // Both agree. Only split them if one is clearly better — a two-handed grip
            // has both wrists rotating with the pad, and calling that "left" would be a
            // coin toss dressed up as a measurement.
            let l = left ?? 0, r = right ?? 0
            if l - r >= Self.soleMargin      { holder = .left }
            else if r - l >= Self.soleMargin { holder = .right }
            else                             { holder = .both }
        case (true, false):  holder = .left
        case (false, true):  holder = .right
        case (false, false):
            /* Neither wrist matches a controller that is definitely moving. Real, and it
               has an honest reading: the controller is resting on a desk being pressed, or
               sitting in a lap. Report `unknown` rather than guessing — the sender then
               sends no gyro at all, which is the same thing it did before this existed. */
            holder = .unknown
        }
        return holder
    }

    /// Angular speed in rad/s implied by two orientations `dt` apart.
    ///
    /// Frame-independent by construction: this is the magnitude of the rotation between
    /// them over time, which is why it can be compared against an IMU whose axes we have
    /// never aligned to anything.
    static func angularSpeed(from a: simd_quatf, to b: simd_quatf, dt: Double) -> Float? {
        guard dt > 1e-4 else { return nil }
        // Both signs of a quaternion are the same rotation; take the short way round or a
        // hand passing through the antipode reads as a 2-pi flick.
        var dot = simd_dot(a.vector, b.vector)
        dot = min(1, max(-1, abs(dot)))
        return 2 * acos(dot) / Float(dt)
    }
}

/// Persistence for the user's choice. Global rather than per-title: which hand you are
/// holding a controller in is a fact about you at this moment, not about the game.
enum ControllerHandPreferenceStore {
    static let defaultsKey = "foveatedControllerHand"

    static func load() -> ControllerHandPreference {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let value = ControllerHandPreference(rawValue: raw) else { return .auto }
        return value
    }

    static func save(_ preference: ControllerHandPreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: defaultsKey)
    }
}
