//  HandGestureEngine.swift
//
//  Per-finger thumb-pinch detection + a wrist-delta locomotion joystick, ported
//  from Spatialcraft's HandTracker. Feeds the Controller Bridge so hand gestures
//  can drive an emulated VR controller (the physical Switch Pro is optional).
//
//  Two adaptations vs. the Spatialcraft original:
//    1. Exposes the *held* finger per hand (a sustained, debounced pinch), not a
//       one-shot rising-edge event — a VR controller button must stay DOWN for the
//       duration of the pinch so holding a trigger works.
//    2. Reuses the sender's existing HandTrackingProvider (anchors are pushed in via
//       `update(_:)`); it does not open its own ARKit session.
//
//  Filtering (carried over from Spatialcraft, tunable on-device):
//    - Fist suppressor: 3+ curled fingers → no pinch (stops accidental thumb brushes).
//    - Hysteresis: engage at 2.5cm, release at 4.5cm (no flapping at the threshold).
//    - Hold debounce: a pinch must persist 0.10s before it counts (ignores brushes).
//  One pinch is tracked per hand at a time (the nearest finger) — you press one
//  button per hand, which fits the minimal ABXY + triggers + menu target set.

#if FOVEATED_ENABLED
import ARKit
import simd
import QuartzCore

@MainActor
final class HandGestureEngine {

    struct Output {
        /// The currently-held (sustained, debounced) pinch finger per hand, or nil.
        var heldLeft: BridgeFinger?
        var heldRight: BridgeFinger?
        /// How long that pinch has been held, per hand; 0 when there is none. Exposed so
        /// a target whose misfire is expensive can ask for more than the 0.10 s debounce.
        var heldLeftFor: TimeInterval = 0
        var heldRightFor: TimeInterval = 0
        /// Head-relative (x = strafe, y = forward) locomotion vector, |v| ≤ 1.
        /// Non-zero only while left thumb+index is sustained.
        var joystick: SIMD2<Float> = .zero
    }

    // MARK: Tunables
    let pinchEnterDistance: Float = 0.025      // 2.5cm — engage
    let pinchExitDistance: Float = 0.045       // 4.5cm — release (hysteresis)
    let pinchHoldThreshold: TimeInterval = 0.10
    let fistCurlThreshold: Float = 0.06        // tip-to-metacarpal < 6cm = curled
    let joystickFullScaleMeters: Float = 0.18  // hand 18cm from anchor = full tilt

    // MARK: State
    private struct PinchState {
        var finger: BridgeFinger
        var startTime: TimeInterval
        var fired: Bool
    }
    private var leftPinch: PinchState?
    private var rightPinch: PinchState?
    private var joystickAnchorWorld: SIMD3<Float>?

    private var leftAnchor: HandAnchor?
    private var rightAnchor: HandAnchor?

    /// Hands whose pinches must not reach the game. Set while the wrist HUD is up: the
    /// same pinch that presses a button on the panel is also mapped to a controller
    /// button, so without this, checking your frame times fires a trigger in-game.
    /// Suppression is per hand, so the other hand keeps playing.
    var suppressedHands: Set<BridgeHand> = []

    /// Push the latest hand anchor (called from the sender's ARKit update loop).
    func update(_ anchor: HandAnchor) {
        let tracked = anchor.isTracked ? anchor : nil
        switch anchor.chirality {
        case .left:  leftAnchor = tracked
        case .right: rightAnchor = tracked
        @unknown default: break
        }
    }

    /// Evaluate both hands. `worldForward`/`worldRight` are the head-relative XZ
    /// basis used to project the joystick delta into locomotion.
    func tick(
        now: TimeInterval = CACurrentMediaTime(),
        worldForward: SIMD3<Float>,
        worldRight: SIMD3<Float>
    ) -> Output {
        var out = Output()
        out.heldLeft = processHand(.left, anchor: leftAnchor, now: now)
        out.heldRight = processHand(.right, anchor: rightAnchor, now: now)
        if let left = leftPinch, left.fired { out.heldLeftFor = now - left.startTime }
        if let right = rightPinch, right.fired { out.heldRightFor = now - right.startTime }
        out.joystick = computeJoystick(worldForward: worldForward, worldRight: worldRight)
        return out
    }

    // MARK: Pinch processing

    private func processHand(_ hand: BridgeHand, anchor: HandAnchor?, now: TimeInterval) -> BridgeFinger? {
        guard let anchor, let skeleton = anchor.handSkeleton, !suppressedHands.contains(hand)
        else {
            setPinch(nil, for: hand)
            return nil
        }

        let originFromAnchor = anchor.originFromAnchorTransform
        func jointWorld(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let thumbTip = jointWorld(.thumbTip)
        let fingerJoints: [(BridgeFinger, HandSkeleton.JointName, HandSkeleton.JointName)] = [
            (.index,  .indexFingerTip,  .indexFingerMetacarpal),
            (.middle, .middleFingerTip, .middleFingerMetacarpal),
            (.ring,   .ringFingerTip,   .ringFingerMetacarpal),
            (.little, .littleFingerTip, .littleFingerMetacarpal)
        ]

        var curledCount = 0
        var nearestFinger: BridgeFinger = .index
        var nearestDistance: Float = .infinity
        for (finger, tipJoint, metacarpalJoint) in fingerJoints {
            let tip = jointWorld(tipJoint)
            let metacarpal = jointWorld(metacarpalJoint)
            if simd_distance(tip, metacarpal) < fistCurlThreshold { curledCount += 1 }
            let d = simd_distance(tip, thumbTip)
            if d < nearestDistance { nearestDistance = d; nearestFinger = finger }
        }

        if curledCount >= 3 {                 // fist → suppress
            setPinch(nil, for: hand)
            return nil
        }

        var state = pinch(for: hand)
        defer { setPinch(state, for: hand) }

        if let active = state {
            // Release on exit hysteresis, or if a different finger is now nearest.
            let crossedFingers = nearestFinger != active.finger && nearestDistance < pinchEnterDistance
            if nearestDistance > pinchExitDistance || crossedFingers {
                state = nil
            } else if !active.fired && (now - active.startTime) >= pinchHoldThreshold {
                state?.fired = true
            }
        } else if nearestDistance < pinchEnterDistance {
            state = PinchState(finger: nearestFinger, startTime: now, fired: false)
        }

        if let s = state, s.fired { return s.finger }
        return nil
    }

    // MARK: Joystick (left thumb+index sustained pinch)

    private func computeJoystick(worldForward: SIMD3<Float>, worldRight: SIMD3<Float>) -> SIMD2<Float> {
        guard let pinch = leftPinch, pinch.finger == .index, pinch.fired,
              let anchor = leftAnchor, let skeleton = anchor.handSkeleton else {
            joystickAnchorWorld = nil
            return .zero
        }

        let m = anchor.originFromAnchorTransform * skeleton.joint(.wrist).anchorFromJointTransform
        let wristWorld = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        if joystickAnchorWorld == nil { joystickAnchorWorld = wristWorld }
        let delta = wristWorld - (joystickAnchorWorld ?? wristWorld)

        let forward = SIMD3<Float>(worldForward.x, 0, worldForward.z)
        let right = SIMD3<Float>(worldRight.x, 0, worldRight.z)
        let scale = 1.0 / joystickFullScaleMeters
        var x = simd_dot(delta, right) * scale
        var y = simd_dot(delta, forward) * scale
        let mag = (x * x + y * y).squareRoot()
        if mag > 1 { x /= mag; y /= mag }
        return SIMD2(x, y)
    }

    // MARK: Palm geometry (the wrist HUD's mount)

    struct PalmPose {
        /// Midpoint of wrist and middle-finger knuckle — the centre of the palm.
        var position: SIMD3<Float>
        /// Unit normal out of the palm, the direction a held object would face.
        var normalOut: SIMD3<Float>
        /// Unit vector up the hand, wrist → knuckle.
        var fingersDirection: SIMD3<Float>
    }

    /// The palm plane comes from joint *positions*, and which side of it is the palm is
    /// resolved **from the hand's own anatomy** rather than from a chirality rule.
    ///
    /// Two previous versions of this got the side wrong, in both cases by reasoning about a
    /// convention instead of measuring something. The first took the wrist frame's −Y,
    /// lifted from Spatialcraft where it is only ever applied to the right hand. The second
    /// derived a per-hand sign for `cross(fingers, across)` from a hand-drawn diagram — and
    /// a sign convention that has to be talked through is a sign convention that can be
    /// talked through wrongly.
    ///
    /// So: the thumb decides. The thumb's column is rotated roughly 90° out of the plane of
    /// the fingers and sits on the **palmar** side of it — that is true of both hands, in
    /// any pose, and does not depend on how ARKit numbers its axes. Project the thumb
    /// knuckle onto the plane normal and take whichever direction it agrees with.
    func palmPose(_ hand: BridgeHand) -> PalmPose? {
        guard let anchor = hand == .left ? leftAnchor : rightAnchor,
              let skeleton = anchor.handSkeleton else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func jointWorld(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let wrist = jointWorld(.wrist)
        let knuckle = jointWorld(.middleFingerKnuckle)
        guard simd_distance(wrist, knuckle) > 1e-4 else { return nil }
        let fingers = simd_normalize(knuckle - wrist)

        let across = jointWorld(.littleFingerKnuckle) - jointWorld(.indexFingerKnuckle)
        guard simd_length(across) > 1e-4 else { return nil }
        var normal = simd_cross(fingers, simd_normalize(across))
        guard simd_length(normal) > 1e-4 else { return nil }
        normal = simd_normalize(normal)

        // Which way is out of the palm? The way the thumb leans.
        let palmCenter = (wrist + knuckle) * 0.5
        let thumbOffset = jointWorld(.thumbKnuckle) - palmCenter
        let thumbAlongNormal = simd_dot(thumbOffset, normal)
        // Under ~5 mm the thumb is too close to the plane to be evidence — a flat splayed
        // hand seen edge-on. Better to report nothing than to flip the panel's mount.
        guard abs(thumbAlongNormal) > 0.005 else { return nil }
        if thumbAlongNormal < 0 { normal = -normal }

        return PalmPose(position: palmCenter,
                        normalOut: normal,
                        fingersDirection: fingers)
    }

    /// World position of the thumb tip — where a pinch physically happens, and so where
    /// the charging indicator belongs: the user is already looking at their fingers.
    func thumbTipWorld(_ hand: BridgeHand) -> SIMD3<Float>? {
        guard let anchor = hand == .left ? leftAnchor : rightAnchor,
              let skeleton = anchor.handSkeleton else { return nil }
        let m = anchor.originFromAnchorTransform
            * skeleton.joint(.thumbTip).anchorFromJointTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// How directly a palm faces `headWorld`: +1 = squarely toward the viewer, 0 = edge-on,
    /// −1 = away. nil when that hand isn't tracked.
    ///
    /// A plain dot product, unlike Spatialcraft's pitch-invariant version this was ported
    /// from. That one strips the finger-axis component so a hand tilted up or down still
    /// counts, which suits a game that wants a forgiving trigger — but here it widens the
    /// engaging cone until the panel shows up on almost any orientation with a sideways
    /// component. "Turn your palm toward your face" should mean exactly that.
    func palmFacing(_ hand: BridgeHand, towards headWorld: SIMD3<Float>) -> Float? {
        guard let pose = palmPose(hand) else { return nil }
        let toHead = headWorld - pose.position
        let headLength = simd_length(toHead)
        guard headLength > 1e-4 else { return nil }
        return simd_dot(pose.normalOut, toHead / headLength)
    }

    // MARK: State accessors

    private func pinch(for hand: BridgeHand) -> PinchState? {
        hand == .left ? leftPinch : rightPinch
    }

    private func setPinch(_ state: PinchState?, for hand: BridgeHand) {
        switch hand {
        case .left:  leftPinch = state
        case .right: rightPinch = state
        }
    }
}
#endif
