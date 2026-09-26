//  TrackedControllerForwarding.swift
//
//  The pure half of forwarding real controllers to the PCVR host: RAVEInput's tracked-
//  controller sources in, the 0x10 packet (`ControllerBridgeTrackedControllers`) out, plus
//  the two decisions the headset owns because only it can make them — which device a side
//  belongs to, and where a game's haptic pulse for that side should go.
//
//  Two backends feed it, both producing `RAVETrackedControllerState` already registered in
//  the ARKit world the 0x03 wrists are sent in:
//    - `RAVESpatialAccessorySource`: PSVR2 Sense, tracked by the headset itself.
//    - `RAVEQuestBridgeSource`: Quest Touch, tracked by a Quest on the desk that streams to
//      THIS device (UDP :9520 on the headset), aligned against the ARKit hands we feed it.
//  The host only obeys the flags: a held side's controls, and a tracked held side's pose,
//  replace that side of the 0x03 state. It never calibrates and never learns more about the
//  device than `source`.
//
//  No ARKit, no networking, no actor — so all of it is unit-tested
//  (LongwaveTests/ControllerBridgeTrackedControllersTests.swift).

#if FOVEATED_ENABLED
import Foundation
import RAVEInput
import simd

enum TrackedControllerForwarding {

    typealias Source = ControllerBridgeTrackedController.Source

    // MARK: Pose convention

    /// The device origin → OpenXR grip pose, per source: the host treats a forwarded
    /// controller exactly like a hand's grip, so the conversion happens here, once.
    ///
    /// - Quest: identity. The Controller Bridge app streams the OpenXR *grip* pose, and
    ///   `RAVEQuestBridgeSource` only rotates and translates it into the ARKit world.
    /// - Sense: identity for now. ARKit's accessory anchor origin has never been compared
    ///   with a grip pose on hardware (see `RAVESpatialAccessorySource`); this is the one
    ///   place to put the measured offset once it has.
    static func gripFromOrigin(_ source: Source) -> (rotation: simd_quatf, translation: SIMD3<Float>) {
        switch source {
        case .quest, .sense, .unknown:
            return (simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), .zero)
        }
    }

    // MARK: One side

    /// One RAVE reading as a wire side.
    static func side(_ state: RAVETrackedControllerState, source: Source) -> ControllerBridgeTrackedController {
        var out = ControllerBridgeTrackedController()
        var flags: ControllerBridgeTrackedController.Flags = [.present]
        if state.isTracked { flags.insert(.tracked) }
        if state.isInHand { flags.insert(.inHand) }
        if state.touchValid { flags.insert(.touchValid) }

        let grip = gripFromOrigin(source)
        let orientation = simd_normalize(state.orientation)
        out.position = state.position + orientation.act(grip.translation)
        out.orientation = simd_normalize(orientation * grip.rotation)
        if let angular = state.angularVelocity, angular.allFinite {
            out.angularVelocity = angular
            flags.insert(.angularVelocity)
        }
        out.trigger = clampUnit(state.trigger)
        out.grip = clampUnit(state.grip)
        out.stick = SIMD2(clampSigned(state.stick.x), clampSigned(state.stick.y))
        out.buttons = state.buttons.rawValue
        out.source = source
        out.battery = state.batteryPercent.map { min($0, 100) } ?? ControllerBridgeTrackedController.batteryUnknown
        // A pose that is not finite is not tracked, whatever the backend said.
        if !(out.position.allFinite && out.orientation.vector.allFinite) {
            out.position = .zero
            out.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            flags.remove(.tracked)
        }
        out.flags = flags
        return out
    }

    /// Two backends can both claim a side (a Sense connected while a Quest streams). The
    /// one that can drive the pose wins, then the one in the hand, then whatever is there;
    /// on a tie the Sense does, because the headset tracks it directly with no alignment
    /// in between.
    static func choose(quest: RAVETrackedControllerState?,
                       sense: RAVETrackedControllerState?) -> ControllerBridgeTrackedController {
        func rank(_ state: RAVETrackedControllerState?) -> Int {
            guard let state else { return 0 }
            if state.isTracked && state.isInHand { return 3 }
            if state.isInHand { return 2 }
            return 1
        }
        let q = rank(quest), s = rank(sense)
        if s == 0 && q == 0 { return .absent }
        if s >= q, let sense { return side(sense, source: .sense) }
        if let quest { return side(quest, source: .quest) }
        return .absent
    }

    /// The whole packet for one send tick.
    ///
    /// `questAligned`: the Quest source has a confirmed transform. Until it does, its
    /// controllers are forwarded as present but NOT in hand, so they override nothing —
    /// the user is waving them around to calibrate, and before alignment the source's
    /// put-down detector cannot tell a held controller from one lying on the desk, which
    /// would otherwise let two idle controllers silence the hand gestures.
    static func packet(quest: RAVETrackedControllerFrame, sense: RAVETrackedControllerFrame,
                       questAligned: Bool, sequence: UInt8,
                       now: TimeInterval) -> ControllerBridgeTrackedControllers {
        func gate(_ state: RAVETrackedControllerState?) -> RAVETrackedControllerState? {
            guard var state, !questAligned else { return state }
            state.isInHand = false
            state.isTracked = false
            return state
        }
        var packet = ControllerBridgeTrackedControllers()
        packet.sequence = sequence
        packet.timestampNs = UInt64(max(0, now) * 1_000_000_000)
        packet.left = choose(quest: gate(quest.left), sense: sense.left)
        packet.right = choose(quest: gate(quest.right), sense: sense.right)
        return packet
    }

    /// Whether a Quest source's status means its poses are aligned the way `poll` counts
    /// them (a restored transform is not, until fresh pairs confirm it).
    static func questAligned(_ status: RAVEQuestBridgeSource.Status?) -> Bool {
        guard let status, case .calibrated = status.phase else { return false }
        return !status.isWarmStart
    }

    // MARK: Haptics

    enum HapticTarget: Equatable {
        /// Relay to the Quest (`RAVEQuestBridgeSource.sendHaptic`).
        case quest
        /// Play on the Sense controller (`RAVESpatialAccessorySource.sendHaptic`).
        case sense
        /// The paired gamepad's own CoreHaptics, as before controllers were forwarded.
        case pad
    }

    /// Where a game's pulse for `hand` goes: to whatever device the host was told holds
    /// that side, so the rumble lands in the hand the game thinks it is shaking.
    static func hapticTarget(for hand: BridgeHand,
                             lastSent: ControllerBridgeTrackedControllers?,
                             questAvailable: Bool,
                             senseAvailable: Bool) -> HapticTarget {
        guard let side = lastSent?[hand], side.isHeld else { return .pad }
        switch side.source {
        case .quest where questAvailable: return .quest
        case .sense where senseAvailable: return .sense
        default: return .pad
        }
    }

    /// A pulse off the wire (`cb_haptic_packet_t`) as a RAVE haptic for `hand`.
    static func haptic(_ pulse: ControllerBridgeHaptic, hand: BridgeHand) -> RAVEControllerHaptic {
        RAVEControllerHaptic(chirality: hand, duration: max(0, pulse.duration),
                             frequency: pulse.frequency, amplitude: clampUnit(pulse.amplitude))
    }

    // MARK: Helpers

    private static func clampUnit(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : 0 }
    private static func clampSigned(_ v: Float) -> Float { v.isFinite ? min(max(v, -1), 1) : 0 }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

// MARK: - The HUD's Quest line

/// What the wrist HUD says about Quest controllers, from the headset's own source. Pure so
/// the wording is testable; the view only lays it out.
enum QuestControllerStatusText {

    enum Tone: Equatable { case neutral, good, warning }

    static func detail(enabled: Bool, status: RAVEQuestBridgeSource.Status?,
                       startError: String?) -> (text: String, tone: Tone) {
        guard enabled else {
            return ("Use a Quest's Touch controllers: turn this on, then open Controller Bridge on the Quest.",
                    .neutral)
        }
        if let startError {
            return ("Could not listen for the Quest: \(startError)", .warning)
        }
        guard let status, status.isListening else {
            return ("Starting…", .neutral)
        }
        switch status.phase {
        case .idle:
            let name = status.advertisedName.map { " \u{201C}\($0)\u{201D}" } ?? " this headset"
            return ("Waiting for the Quest — open Controller Bridge on it and pick\(name).", .neutral)
        case .seen:
            return ("Receiving the controllers — waiting for hand tracking to calibrate.", .neutral)
        case .collecting(let samples, let spread):
            // Spread is the number that actually blocks the solve, so the nag is keyed to
            // it: pair count alone rises fine with a resting hand.
            if spread < RAVEQuestCalibration.spreadTargetMeters {
                return (String(format: "Hold the controllers and wave your arms — spread %.0f of %.0f cm.",
                               spread * 100, RAVEQuestCalibration.spreadTargetMeters * 100), .neutral)
            }
            return ("Calibrating: \(samples) of \(RAVEQuestCalibration.minSamples) pairs…", .neutral)
        case .calibrated(let residualMm):
            var text = status.isWarmStart
                ? "Restored from last session — confirming."
                : String(format: "Aligned, ±%.0f mm.", residualMm)
            if !status.leftTracked || !status.rightTracked {
                let missing = status.leftTracked ? "right" : (status.rightTracked ? "left" : "")
                text += missing.isEmpty ? " Neither controller is tracked."
                                        : " The \(missing) controller is not tracked."
            }
            return (text, .good)
        case .lost:
            return ("Signal lost — is the Quest awake with its cameras facing you?", .warning)
        }
    }
}
#endif
