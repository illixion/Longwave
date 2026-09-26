//  GameProfile.swift
//
//  Per-title settings for PCVR streaming, keyed by the executable the host reports in
//  its telemetry (0x07).
//
//  This used to be a hand-alignment calibration table: every title carried a measured
//  offset and yaw to drag its rendered hands back onto the user's real ones. That whole
//  layer is gone. The residual it corrected came from the broker estimating an
//  ARKit→runtime transform from the head while near-still, which cancelled its own error
//  only at the position it was solved at and drifted with every step the user took. The
//  broker now takes wrists from the runtime's own action spaces, where no estimate is
//  involved — measured on device at 21 mm / 9.8° of error removed — so a per-title
//  positional correction has nothing left to correct. Shipping one would be re-adding a
//  constant to compensate for an error that no longer exists.
//
//  What genuinely does vary per title is what the game expects from us:
//    - Input: which gestures have to map to which controller buttons. A title that reads
//      grip for grabbing needs a different mapping than one that reads trigger, and a
//      title with native hand support may want no emulated controllers at all.
//    - Graphics: see `GameGraphics` — currently advisory, see the note there.
//
//  Two layers, in precedence order: `saved` (what this device configured, in
//  UserDefaults) then `shipped` (built into the app). A title with neither gets the
//  global defaults, which is the honest behaviour for a game nobody has tested.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import RAVEInput

/// How a title's player walks without a thumbstick.
enum GameLocomotionMode: String, Codable, CaseIterable, Sendable {
    /// Left thumb + index held, then move the hand: a wrist-delta joystick.
    case pinchJoystick
    /// Pump both fists like jogging (`RAVEArmSwinger`). The pinch joystick stays
    /// available as a precision override and wins while it is held.
    case armSwing
    /// No gesture locomotion at all; left thumb + index is free and presses nothing.
    case off

    static let `default`: GameLocomotionMode = .pinchJoystick

    var displayName: String {
        switch self {
        case .pinchJoystick: "Pinch joystick"
        case .armSwing:      "Arm swing"
        case .off:           "Off"
        }
    }
}

/// Whether, and how, hand gestures turn the player (the emulated right stick's X axis).
enum GameTurnMode: String, Codable, CaseIterable, Sendable {
    case off
    /// A short full-deflection pulse per flick: the game's own snap turn decides the angle.
    case snap
    /// Deflection proportional to how far the clutched hand has moved sideways.
    case smooth

    static let `default`: GameTurnMode = .off

    var displayName: String {
        switch self {
        case .off:    "Off"
        case .snap:   "Snap"
        case .smooth: "Smooth"
        }
    }
}

/// Per-title input handling. `nil` fields mean "inherit the global setting", so a profile
/// only has to state what makes this title different.
///
/// Decoding is hand-written so a saved profile always loads: every key is optional, and
/// the newer ones are read with `try?` as well, because `GameProfiles.saved()` decodes the
/// whole dictionary at once — a single unreadable value (an enum case from a newer build,
/// say) would otherwise throw away every title's settings, not just the one field.
struct GameInput: Equatable, Codable {
    /// Overrides the global gesture→button map for this title.
    var gestureMapping: GestureControllerMapping?
    /// Whether to present emulated controllers at all. A title that tracks hands natively
    /// through the runtime can be better off without them.
    var emulateControllers: Bool?
    /// Gesture locomotion. nil = `GameLocomotionMode.default`.
    var locomotion: GameLocomotionMode?
    /// Pinch-joystick sensitivity, `joystickSensitivityRange`. Higher engages sooner,
    /// with a smaller deadzone and less travel to full deflection. nil = 1.
    var joystickSensitivity: Float?
    /// Gesture turning. nil = `GameTurnMode.default` (off).
    var turn: GameTurnMode?
    /// The hand whose thumb + middle clutch turns. nil = right, the stick a real
    /// controller turns with.
    var turnHand: BridgeHand?

    init(gestureMapping: GestureControllerMapping? = nil,
         emulateControllers: Bool? = nil,
         locomotion: GameLocomotionMode? = nil,
         joystickSensitivity: Float? = nil,
         turn: GameTurnMode? = nil,
         turnHand: BridgeHand? = nil) {
        self.gestureMapping = gestureMapping
        self.emulateControllers = emulateControllers
        self.locomotion = locomotion
        self.joystickSensitivity = joystickSensitivity
        self.turn = turn
        self.turnHand = turnHand
    }

    private enum CodingKeys: String, CodingKey {
        case gestureMapping, emulateControllers, locomotion, joystickSensitivity, turn, turnHand
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gestureMapping = (try? c.decodeIfPresent(GestureControllerMapping.self, forKey: .gestureMapping)) ?? nil
        emulateControllers = (try? c.decodeIfPresent(Bool.self, forKey: .emulateControllers)) ?? nil
        locomotion = (try? c.decodeIfPresent(GameLocomotionMode.self, forKey: .locomotion)) ?? nil
        joystickSensitivity = (try? c.decodeIfPresent(Float.self, forKey: .joystickSensitivity)) ?? nil
        turn = (try? c.decodeIfPresent(GameTurnMode.self, forKey: .turn)) ?? nil
        turnHand = (try? c.decodeIfPresent(BridgeHand.self, forKey: .turnHand)) ?? nil
    }

    var isEmpty: Bool {
        gestureMapping == nil && emulateControllers == nil && locomotion == nil
            && joystickSensitivity == nil && turn == nil && turnHand == nil
    }

    // MARK: Resolved values

    static let joystickSensitivityRange: ClosedRange<Float> = 0.5...1.5

    var resolvedLocomotion: GameLocomotionMode { locomotion ?? .default }
    var resolvedTurn: GameTurnMode { turn ?? .default }
    var resolvedTurnHand: BridgeHand { turnHand ?? .right }
    var resolvedJoystickSensitivity: Float {
        let value = joystickSensitivity ?? 1
        guard value.isFinite else { return 1 }
        return min(max(value, Self.joystickSensitivityRange.lowerBound),
                   Self.joystickSensitivityRange.upperBound)
    }

    /// The mapping in force for this title: its own if it has one, else the global one.
    func effectiveMapping(global: GestureControllerMapping) -> GestureControllerMapping {
        gestureMapping ?? global
    }

    /// Store `mapping` as this title's own. A mapping identical to the global one is
    /// stored as no override at all, so the title keeps following later global edits
    /// instead of freezing a copy of today's.
    mutating func setMappingOverride(_ mapping: GestureControllerMapping?,
                                     global: GestureControllerMapping) {
        gestureMapping = (mapping == nil || mapping == global) ? nil : mapping
    }

    /// Normalise to the "only what differs" form the saved layer keeps: explicit
    /// defaults become nil, so they read as inherited and `isEmpty` can remove them.
    mutating func dropDefaults() {
        if emulateControllers == true { emulateControllers = nil }
        if locomotion == .default { locomotion = nil }
        if turn == .default { turn = nil }
        if turnHand == .right { turnHand = nil }
        if let s = joystickSensitivity, abs(s - 1) < 0.001 { joystickSensitivity = nil }
    }
}

/// Per-title graphics preferences.
///
/// These are recorded per title but not yet applied: every knob that actually moves
/// (foveation extents, encoder pacing) lives in the host's CloudXR configuration and the
/// game's own launch, neither of which the headset can reach today. Wiring them needs the
/// launch command on the backend channel. Deliberately not including a MetalFX option —
/// on the foveated path Apple's FoveatedStreaming framework owns decode and composition
/// and never hands us pixels, so there is no stage for us to upscale in.
struct GameGraphics: Equatable, Codable {
    /// Frame-rate ceiling for this title, or nil for the host's own pacing. Note that
    /// CloudXR's `maxFps` is not the mechanism — it switches the runtime to a fixed
    /// timestep that slips overrunning frames by a whole period (measured 2026-07-27, felt
    /// as constant microstutter), so a cap has to come from the game or the broker.
    var frameRateLimit: Int?

    var isEmpty: Bool { frameRateLimit == nil }
}

struct GameProfile: Equatable, Codable {
    var input = GameInput()
    var graphics = GameGraphics()

    static let empty = GameProfile()
    var isEmpty: Bool { input.isEmpty && graphics.isEmpty }
}

/// Where a resolved profile came from — surfaced in the HUD so a tester always knows
/// whether they are looking at their own configuration or a shipped one.
enum GameProfileSource: String {
    case saved      // this device
    case shipped    // built into the app
    case global     // no profile for this title; the global settings apply
}

enum GameProfiles {

    /// Key for the title the host reported. Case-folded because the host reports whatever
    /// casing the filesystem has.
    static func key(for game: String?) -> String {
        guard let game, !game.isEmpty else { return defaultKey }
        return game.lowercased()
    }

    /// Used when no game is submitting frames yet (or an unnamed one is).
    static let defaultKey = "default"

    /// Profiles built into the app — the artifact that ships to users. Empty until a
    /// title is measured to need something other than the globals.
    static let shipped: [String: GameProfile] = [:]

    // MARK: Resolution

    static func resolve(for game: String?) -> (profile: GameProfile, source: GameProfileSource) {
        let key = key(for: game)
        if let saved = saved()[key] { return (saved, .saved) }
        if let shipped = shipped[key] { return (shipped, .shipped) }
        return (.empty, .global)
    }

    /// The mapping this title should use: its override if it has one, else the global.
    static func gestureMapping(for game: String?, global: GestureControllerMapping)
        -> GestureControllerMapping {
        resolve(for: game).profile.input.effectiveMapping(global: global)
    }

    /// Edit a title's input settings in the saved layer, starting from whatever currently
    /// resolves for it (so a shipped profile is carried over rather than dropped), and
    /// storing only what differs from the defaults.
    static func updateSavedInput(for game: String?, _ edit: (inout GameInput) -> Void) {
        var profile = resolve(for: game).profile
        edit(&profile.input)
        profile.input.dropDefaults()
        setSaved(profile, for: game)
    }

    // MARK: Saved layer

    private static let savedKey = "foveatedGameProfiles.v1"

    static func saved() -> [String: GameProfile] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let decoded = try? JSONDecoder().decode([String: GameProfile].self, from: data)
        else { return [:] }
        return decoded
    }

    static func setSaved(_ profile: GameProfile, for game: String?) {
        var all = saved()
        /* An emptied profile is a removal, not a stored blank: resolution has to fall
           through to the shipped layer, which an empty entry would shadow. */
        if profile.isEmpty {
            all.removeValue(forKey: key(for: game))
        } else {
            all[key(for: game)] = profile
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    static func clearSaved(for game: String?) {
        var all = saved()
        all.removeValue(forKey: key(for: game))
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    // MARK: Export

    /// Everything configured on this device, as JSON — paste into `shipped` (or hand back)
    /// to turn a testing pass into profiles that ship.
    static func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved()),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
#endif
