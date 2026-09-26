//  PCVRGestureInput.swift
//
//  The pure, per-frame decisions the Controller Bridge makes on top of RAVEInput's hand
//  sensing: how a title's joystick sensitivity becomes joystick geometry, the opt-in
//  gesture turn, and which gesture owns each hand this frame. Split out of
//  ControllerBridgeSender so it is host-testable without ARKit, the same reason
//  RAVEInput keeps its own sensing framework-free.
//
//  Why any of this exists: in Half-Life: Alyx (OpenComposite → VDXR, Index controllers)
//  the virtual joystick engaged on a brushed thumb, and finger poses made on the way to
//  something else read as input. Alyx has no controllerless mode — it needs a thumbstick
//  to walk and turn — so the answer is not fewer gestures but more deliberate ones:
//
//    - the joystick engages on RAVEInput's `.joystick` preset (index only, a heavier
//      hold) with smoothing and an axial deadzone, scaled by one per-title slider;
//    - turning needs a *held* clutch pinch before the hand's sideways travel counts,
//      and snap turns go out as one short full-deflection pulse per flick;
//    - arm-swing walking, when chosen, claims the swinging hands so the finger shapes of
//      a jogging fist never press a button, and a held pinch or joystick outranks it.
//
//  All value types with no isolation, like the RAVEInput types they wrap. Every
//  threshold here is unverified on device until the user says otherwise — the
//  simulator has no hand tracking.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import RAVEInput
import simd

// MARK: - Joystick geometry from sensitivity

/// The pinch joystick's feel for one sensitivity value. One slider moves all three
/// numbers together because they all answer the same question — how easily the stick
/// moves — and three sliders for one feeling is a settings page nobody can tune.
struct PCVRJoystickSettings: Equatable {
    /// How long left thumb + index must stay pinched before the stick engages.
    var holdThreshold: TimeInterval
    /// Wrist travel ignored around the anchor.
    var deadzoneMeters: Float
    /// Wrist travel that reads as full deflection.
    var fullScaleMeters: Float

    /// Low-pass on the wrist offset: takes ARKit wrist jitter out without the stick
    /// feeling late. Only effective through the timed `RAVEHandJoystick.update`.
    static let smoothingTime: TimeInterval = 0.05
    /// Per-axis deadzone after the radial one, so walking forward does not also strafe.
    static let axialDeadzone: Float = 0.12

    /// At 1 this is RAVEInput's own defaults (the `.joystick` preset's 150 ms hold, a
    /// 3 cm deadzone, 18 cm to full scale); the range scales them ±25% together.
    init(sensitivity: Float) {
        let s = sensitivity.isFinite
            ? min(max(sensitivity, GameInput.joystickSensitivityRange.lowerBound),
                  GameInput.joystickSensitivityRange.upperBound)
            : 1
        let factor = 1.5 - 0.5 * s           // 1.25 … 0.75
        holdThreshold = RAVEPinchTuning.joystick.holdThreshold * TimeInterval(factor)
        deadzoneMeters = 0.03 * factor
        fullScaleMeters = 0.18 * factor
    }

    /// The dedicated joystick detector's tuning: `.joystick` with this hold.
    var pinchTuning: RAVEPinchTuning {
        var tuning = RAVEPinchTuning.joystick
        tuning.holdThreshold = holdThreshold
        return tuning
    }

    func configure(_ joystick: inout RAVEHandJoystick) {
        joystick.deadzoneMeters = deadzoneMeters
        joystick.fullScaleMeters = fullScaleMeters
        joystick.axialDeadzone = Self.axialDeadzone
        joystick.smoothingTime = Self.smoothingTime
    }
}

// MARK: - Gesture turn

/// Turning by hand, for titles that need a right stick to turn and have no other way.
///
/// Designed to be hard to do by accident:
///   1. A **clutch**: thumb + middle on the turn hand, held through a 0.2 s
///      `RAVEGestureGate` on top of the pinch detector's own debounce. Middle rather than
///      index because index is the trigger — a trigger pull must never double as a turn.
///   2. Only the hand's **sideways travel from where the clutch engaged** counts, measured
///      along the head's right axis frozen at that moment (so looking around mid-turn
///      does not change what "sideways" means).
///   3. **Snap** needs 5 cm of travel and re-arms only once the hand comes back under
///      3 cm (`RAVESnapTurnDetector`'s hysteresis), and each step is a short full
///      deflection — long enough for a game polling its stick to see it, short enough
///      that it reads as one flick — followed by a gap before the next can fire.
///      **Smooth** is proportional, with its own deadzone.
struct GestureTurn: Equatable {
    /// The pinch that clutches turning. Never the index: that is the trigger.
    static let clutchFinger: BridgeFinger = .middle
    /// How long the clutch must be held before sideways travel counts.
    static let clutchHold: TimeInterval = 0.2
    /// Sideways travel that reads as full deflection.
    static let travelMeters: Float = 0.10
    /// How long one snap pulse holds the stick at full deflection.
    static let pulseDuration: TimeInterval = 0.10
    /// Minimum stick-at-rest time between two snap pulses, so a game sees two pushes.
    static let pulseGap: TimeInterval = 0.08
    /// Smooth turn's deadzone, as a fraction of `travelMeters` (2 cm).
    static let smoothDeadzone: Float = 0.2

    struct Output: Equatable {
        /// The right stick's X this frame, -1…1.
        var stickX: Float = 0
        /// True while the clutch is engaged.
        var engaged = false
        /// 0…1 across the clutch hold.
        var progress: Float = 0
        /// -1 / +1 on the frame a snap step fired, else 0.
        var fired = 0
    }

    private(set) var gate = RAVEGestureGate(tuning: .hold(GestureTurn.clutchHold))
    private var snap = RAVESnapTurnDetector(engage: 0.5, release: 0.3)
    private var anchor: SIMD3<Float>?
    private var anchorRight = SIMD3<Float>(1, 0, 0)
    private var pulseDirection: Float = 0
    private var pulseUntil: TimeInterval = -.infinity
    private var nextPulseAt: TimeInterval = -.infinity

    var isEngaged: Bool { gate.isEngaged }

    mutating func reset() {
        gate.reset()
        snap.reset()
        anchor = nil
        pulseDirection = 0
        pulseUntil = -.infinity
        nextPulseAt = -.infinity
    }

    /// Advance one frame.
    /// - Parameters:
    ///   - clutchHeld: the turn hand's pinch detector reports `clutchFinger` held.
    ///   - allowed: nothing else owns the turn hand (arm swing, the joystick, the HUD).
    ///   - wrist: the turn hand's wrist, in the same space as `right`.
    ///   - right: the head's horizontal right axis this frame.
    mutating func update(mode: GameTurnMode, clutchHeld: Bool, allowed: Bool,
                         wrist: SIMD3<Float>?, right: SIMD3<Float>,
                         now: TimeInterval) -> Output {
        guard mode != .off else {
            if gate.phase != .idle || pulseUntil > now { reset() }
            return Output()
        }
        var out = Output()
        let g = gate.update(active: clutchHeld && wrist != nil, now: now,
                            engageAllowed: allowed, holdAllowed: allowed)
        out.engaged = g.engaged
        out.progress = g.progress

        if g.began, let wrist {
            anchor = wrist
            let flat = SIMD3<Float>(right.x, 0, right.z)
            let length = simd_length(flat)
            anchorRight = length > 1e-4 && length.isFinite ? flat / length : SIMD3(1, 0, 0)
            snap.reset()
        }
        if !g.engaged {
            anchor = nil
            snap.reset()
        }

        var smooth: Float = 0
        if g.engaged, let wrist, let anchor {
            let axis = simd_dot(wrist - anchor, anchorRight) / Self.travelMeters
            switch mode {
            case .snap:
                let step = snap.update(axis, now: now)
                if step != 0, now >= nextPulseAt {
                    pulseDirection = Float(step)
                    pulseUntil = now + Self.pulseDuration
                    nextPulseAt = pulseUntil + Self.pulseGap
                    out.fired = step
                }
            case .smooth:
                let shaped = RAVEStickShaping.radialDeadzone(
                    SIMD2(min(max(axis, -1), 1), 0), deadzone: Self.smoothDeadzone)
                smooth = shaped.x
            case .off:
                break
            }
        }

        // A pulse that started runs its full length even if the clutch opened mid-flick:
        // a truncated pulse is exactly the kind of blip a game might not register.
        if mode == .snap, now < pulseUntil {
            out.stickX = pulseDirection
        } else {
            out.stickX = smooth
        }
        return out
    }
}

// MARK: - Hand ownership

/// What can own a hand this frame.
nonisolated enum PCVRHandGesture: Hashable, Sendable {
    /// Left thumb + index locomotion joystick.
    case joystick
    /// The gesture-turn clutch on the turn hand.
    case turnClutch
    /// Arm-swing walking, per swinging hand.
    case armSwing
    /// A pinch mapped to a controller button.
    case button
}

/// Who owns each hand, as one `RAVEHandOwnership` rule rather than a set of flags.
///
/// Priorities: the joystick and the turn clutch (2) out-rank everything — a held
/// joystick wins over arm swinging, which is the point of keeping it as a precision
/// override. Arm swing and button pinches share a priority (1), so whichever took the
/// hand first keeps it: a pinch held before the swing started blocks the swing on that
/// hand, and a swinging hand's finger shapes cannot press a button. After a gesture
/// lets go, the others wait out a 0.2 s holdoff, so opening a fist at the end of a
/// jog does not read as the pinch it passes through.
///
/// A button pinch that was refused stays refused until it is released, rather than
/// firing late the moment the holdoff lapses — a press you did not get immediately is
/// one you did not mean.
struct PCVRGestureArbiter {
    static let clutchPriority = 2
    static let sharedPriority = 1
    static let releaseHoldoff: TimeInterval = 0.2

    struct Input: Equatable {
        var joystickEngaged = false
        var turnEngaged = false
        var turnHand: BridgeHand = .right
        /// Hands the arm swinger reports swinging (only while it is engaged).
        var swingingLeft = false
        var swingingRight = false
        /// A pinch mapped to a real controller input is held on the hand.
        var leftButtonHeld = false
        var rightButtonHeld = false
    }

    struct Output: Equatable {
        var leftButtonsAllowed = true
        var rightButtonsAllowed = true
        /// The swinger wanted at least one hand and was refused every one it wanted.
        var swingBlocked = false

        func buttonsAllowed(_ hand: BridgeHand) -> Bool {
            hand == .left ? leftButtonsAllowed : rightButtonsAllowed
        }
    }

    private(set) var ownership = RAVEHandOwnership<PCVRHandGesture>(
        releaseHoldoff: PCVRGestureArbiter.releaseHoldoff)
    private var refusedLeft = false
    private var refusedRight = false

    mutating func reset() {
        ownership.reset()
        refusedLeft = false
        refusedRight = false
    }

    /// Owned by something other than a button pinch: the hand is busy walking, turning
    /// or steering, so nothing else (the wrist HUD, the turn clutch) should start on it.
    func isBusy(_ hand: BridgeHand) -> Bool {
        switch ownership.owner(of: hand) {
        case .none, .button?: false
        case .joystick?, .turnClutch?, .armSwing?: true
        }
    }

    /// Whether the turn clutch may start or stay on `hand`.
    func allowsTurn(on hand: BridgeHand) -> Bool {
        switch ownership.owner(of: hand) {
        case .joystick?, .armSwing?: false
        case .none, .button?, .turnClutch?: true
        }
    }

    mutating func resolve(_ input: Input, now: TimeInterval) -> Output {
        var out = Output()

        func clutch(_ gesture: PCVRHandGesture, _ hand: BridgeHand, _ engaged: Bool) {
            if engaged {
                ownership.claim(hand, for: gesture, priority: Self.clutchPriority, now: now)
            } else {
                ownership.release(hand, for: gesture, now: now)
            }
        }
        clutch(.joystick, .left, input.joystickEngaged)
        clutch(.turnClutch, input.turnHand, input.turnEngaged)
        // A turn hand that moved (the setting changed) must not strand a claim.
        let otherHand: BridgeHand = input.turnHand == .left ? .right : .left
        ownership.release(otherHand, for: .turnClutch, now: now)

        var wanted = 0, granted = 0
        for (hand, swinging) in [(BridgeHand.left, input.swingingLeft),
                                 (.right, input.swingingRight)] {
            if swinging {
                wanted += 1
                if ownership.claim(hand, for: .armSwing, priority: Self.sharedPriority,
                                   now: now).isGranted {
                    granted += 1
                }
            } else {
                ownership.release(hand, for: .armSwing, now: now)
            }
        }
        out.swingBlocked = wanted > 0 && granted == 0

        func button(_ hand: BridgeHand, held: Bool, refused: inout Bool) -> Bool {
            guard held else {
                ownership.release(hand, for: .button, now: now)
                refused = false
                return true
            }
            if refused { return false }
            if ownership.claim(hand, for: .button, priority: Self.sharedPriority,
                               now: now).isGranted {
                return true
            }
            refused = true
            return false
        }
        out.leftButtonsAllowed = button(.left, held: input.leftButtonHeld, refused: &refusedLeft)
        out.rightButtonsAllowed = button(.right, held: input.rightButtonHeld, refused: &refusedRight)
        return out
    }
}
#endif
