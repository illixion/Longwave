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

/// Per-title input handling. `nil` fields mean "inherit the global setting", so a profile
/// only has to state what makes this title different.
struct GameInput: Equatable, Codable {
    /// Overrides the global gesture→button map for this title.
    var gestureMapping: GestureControllerMapping?
    /// Whether to present emulated controllers at all. A title that tracks hands natively
    /// through the runtime can be better off without them.
    var emulateControllers: Bool?

    var isEmpty: Bool { gestureMapping == nil && emulateControllers == nil }
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
        resolve(for: game).profile.input.gestureMapping ?? global
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
