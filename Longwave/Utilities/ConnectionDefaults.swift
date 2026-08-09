import Foundation

/// New-connection defaults, configured in the Settings tab and used to seed
/// `ConnectionFormView` when creating a connection. Stored in UserDefaults
/// (enums by rawValue) — `SettingsView` binds the same keys via @AppStorage.
enum ConnectionDefaults {

    enum Keys {
        static let vncQuality = "default_vnc_quality"
        static let vncTouchMode = "default_vnc_touch_mode"
        static let vncPort = "default_vnc_port"
        static let terminalFontSize = "default_terminal_font_size"
        static let terminalQuickKeys = "terminal_quick_keys"
        /// Whether the keyboard windows show the gaze scroll pad below the keys.
        static let keyboardScrollPad = "keyboard_scroll_pad"
        /// Same, for the terminal keyboard — on by default, since scrollback is
        /// the thing people reach for most in a terminal.
        static let terminalScrollPad = "terminal_scroll_pad"
        /// UUID of the SSH host last picked in the Projects tab.
        static let projectsLastHost = "projects_last_host"
        #if MOONLIGHT_ENABLED
        static let moonlightPort = "default_ml_port"
        static let moonlightResolution = "default_ml_resolution"
        static let moonlightFPS = "default_ml_fps"
        static let moonlightBitrate = "default_ml_bitrate"
        static let moonlightCodec = "default_ml_codec"
        static let moonlightAudioConfig = "default_ml_audio_config"
        static let moonlightTouchMode = "default_ml_touch_mode"
        #endif
        #if FOVEATED_ENABLED
        static let foveatedPort = "default_fov_port"
        static let foveatedMode = "default_fov_mode"
        static let foveatedImmersion = "default_fov_immersion"
        static let foveatedControllerBridge = "default_fov_controller_bridge"
        #endif
    }

    private static var defaults: UserDefaults { .standard }

    static var vncQuality: ConnectionQuality {
        ConnectionQuality(rawValue: defaults.object(forKey: Keys.vncQuality) as? Int ?? -1) ?? .high
    }

    static var vncTouchMode: TouchMode {
        TouchMode(rawValue: defaults.string(forKey: Keys.vncTouchMode) ?? "") ?? .relative
    }

    /// SwiftTerm's default is 12 pt; stored 0/absent means "not customized".
    static let terminalFontSizeDefault: Double = 12

    static var terminalFontSize: Double {
        let stored = defaults.double(forKey: Keys.terminalFontSize)
        return stored > 0 ? stored : terminalFontSizeDefault
    }

    /// Default port for a connection type, honoring Settings overrides.
    static func port(for type: ConnectionType) -> Int {
        let stored: Int
        switch type {
        case .vnc: stored = defaults.integer(forKey: Keys.vncPort)
        case .native: stored = 0  // Screen/Audio each dial a fixed protocol port, never user-edited
        case .ssh: stored = 0  // no Settings override; falls back to port 22
        #if MOONLIGHT_ENABLED
        case .moonlight: stored = defaults.integer(forKey: Keys.moonlightPort)
        #endif
        #if FOVEATED_ENABLED
        case .foveated: stored = defaults.integer(forKey: Keys.foveatedPort)
        #endif
        }
        return stored > 0 ? stored : type.defaultPort
    }

    #if MOONLIGHT_ENABLED
    static var moonlightResolution: MoonlightResolution {
        MoonlightResolution(rawValue: defaults.string(forKey: Keys.moonlightResolution) ?? "") ?? .r1080p
    }

    static var moonlightFPS: Int {
        let stored = defaults.integer(forKey: Keys.moonlightFPS)
        return stored > 0 ? stored : 60
    }

    static var moonlightBitrate: Int {
        let stored = defaults.integer(forKey: Keys.moonlightBitrate)
        return stored > 0 ? stored : 20000
    }

    static var moonlightCodec: VideoCodecPreference {
        VideoCodecPreference(rawValue: defaults.string(forKey: Keys.moonlightCodec) ?? "") ?? .auto
    }

    static var moonlightAudioConfig: AudioConfiguration {
        AudioConfiguration(rawValue: defaults.string(forKey: Keys.moonlightAudioConfig) ?? "") ?? .stereo
    }

    static var moonlightTouchMode: TouchMode {
        TouchMode(rawValue: defaults.string(forKey: Keys.moonlightTouchMode) ?? "") ?? .relative
    }
    #endif

    #if FOVEATED_ENABLED
    static var foveatedMode: FoveatedConnectionMode {
        FoveatedConnectionMode(rawValue: defaults.string(forKey: Keys.foveatedMode) ?? "") ?? .systemDiscovered
    }

    static var foveatedImmersion: FoveatedImmersionStyle {
        FoveatedImmersionStyle(rawValue: defaults.string(forKey: Keys.foveatedImmersion) ?? "") ?? .progressive
    }

    /// Defaults to **on**: CloudXR does not forward Vision Pro hands as OpenXR input on
    /// visionOS 27 (see the PCVR design notes in Longwave-PCVR-Host/docs/), so with the
    /// bridge off a PCVR session has no input at all — the useful default is the one that
    /// gives you hands.
    /// `defaults.bool(forKey:)` returns false for an unset key, so check for absence.
    static var foveatedControllerBridge: Bool {
        defaults.object(forKey: Keys.foveatedControllerBridge) as? Bool ?? true
    }
    #endif
}
