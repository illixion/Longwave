import Foundation
import SwiftData

/// Builds and applies a `LongwaveBackup` — the JSON export/import behind the
/// Settings tab's Backup section. See `LongwaveBackup.swift` for exactly what
/// is and isn't included.
enum BackupManager {
    enum RestoreError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "This backup was made by a newer version of Longwave (schema \(version)) and can't be fully restored by this version."
            }
        }
    }

    // MARK: - Export

    static func exportBackup(context: ModelContext) -> LongwaveBackup {
        let connections = (try? context.fetch(FetchDescriptor<SavedConnection>())) ?? []
        return LongwaveBackup(
            version: LongwaveBackup.currentVersion,
            exportDate: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            connections: connections.map(ConnectionBackup.init(from:)),
            preferences: exportPreferences()
        )
    }

    private static func exportPreferences() -> PreferencesBackup {
        let d = UserDefaults.standard
        var prefs = PreferencesBackup()

        prefs.vncQualityRawValue = d.object(forKey: "default_vnc_quality") as? Int
        prefs.vncTouchModeRawValue = d.string(forKey: "default_vnc_touch_mode")
        prefs.vncPort = d.object(forKey: "default_vnc_port") as? Int
        prefs.terminalFontSize = d.object(forKey: "default_terminal_font_size") as? Double
        prefs.terminalQuickKeysRawValue = d.string(forKey: "terminal_quick_keys")
        prefs.keyboardScrollPad = d.object(forKey: "keyboard_scroll_pad") as? Bool
        prefs.terminalScrollPad = d.object(forKey: "terminal_scroll_pad") as? Bool
        prefs.projectsLastHost = d.string(forKey: "projects_last_host")
        prefs.spatialAudioModeRawValue = d.string(forKey: "default_spatial_audio_mode")

        prefs.moonlightPort = d.object(forKey: "default_ml_port") as? Int
        prefs.moonlightResolutionRawValue = d.string(forKey: "default_ml_resolution")
        prefs.moonlightFPS = d.object(forKey: "default_ml_fps") as? Int
        prefs.moonlightBitrate = d.object(forKey: "default_ml_bitrate") as? Int
        prefs.moonlightCodecRawValue = d.string(forKey: "default_ml_codec")
        prefs.moonlightAudioConfigRawValue = d.string(forKey: "default_ml_audio_config")
        prefs.moonlightTouchModeRawValue = d.string(forKey: "default_ml_touch_mode")
        prefs.moonlightSpatialAudioEnabled = d.object(forKey: "moonlightSpatialAudioEnabled") as? Bool

        prefs.foveatedPort = d.object(forKey: "default_fov_port") as? Int
        prefs.foveatedModeRawValue = d.string(forKey: "default_fov_mode")
        prefs.foveatedControllerBridge = d.object(forKey: "default_fov_controller_bridge") as? Bool
        prefs.foveatedControllerHandRawValue = d.string(forKey: "foveatedControllerHand")
        prefs.foveatedShowSentSkeleton = d.object(forKey: "foveatedShowSentSkeleton") as? Bool
        prefs.foveatedWristHUD = d.object(forKey: "foveatedWristHUD") as? Bool
        prefs.foveatedWristHUDOnRight = d.object(forKey: "foveatedWristHUDOnRight") as? Bool
        prefs.foveatedGameProfilesData = d.data(forKey: "foveatedGameProfiles.v1")

        #if os(visionOS)
        let broadcast = BroadcastShared.defaults
        prefs.broadcastCameraID = broadcast.string(forKey: BroadcastShared.Keys.camera)
        prefs.broadcastMicEnabled = broadcast.object(forKey: BroadcastShared.Keys.mic) as? Bool
        prefs.broadcastHost = broadcast.string(forKey: BroadcastShared.Keys.host)
        prefs.broadcastPort = broadcast.object(forKey: BroadcastShared.Keys.port) as? Int
        prefs.broadcastPath = broadcast.string(forKey: BroadcastShared.Keys.path)
        prefs.broadcastViewPath = broadcast.string(forKey: BroadcastShared.Keys.viewPath)
        prefs.broadcastUsername = broadcast.string(forKey: BroadcastShared.Keys.username)
        prefs.broadcastBitrateMbps = broadcast.object(forKey: BroadcastShared.Keys.bitrate) as? Int
        prefs.broadcastCertFingerprint = broadcast.string(forKey: BroadcastShared.Keys.certFingerprint)
        #endif

        return prefs
    }

    // MARK: - Import

    /// Replaces the saved-connection list with `backup.connections` (matched
    /// by `id` so a restore to the same device keeps its Keychain-backed
    /// tokens attached) and merges in every preference `backup.preferences`
    /// has a value for, leaving anything absent untouched.
    static func restore(_ backup: LongwaveBackup, context: ModelContext) throws {
        if backup.version > LongwaveBackup.currentVersion {
            throw RestoreError.unsupportedVersion(backup.version)
        }

        if let connectionBackups = backup.connections {
            try restoreConnections(connectionBackups, context: context)
        }
        if let preferences = backup.preferences {
            restorePreferences(preferences)
        }
    }

    private static func restoreConnections(_ backups: [ConnectionBackup], context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<SavedConnection>())
        var existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for backup in backups {
            if let connection = existingByID.removeValue(forKey: backup.id) {
                backup.apply(to: connection)
            } else {
                let connection = SavedConnection(hostname: backup.hostname, port: backup.port, label: backup.label)
                connection.id = backup.id
                backup.apply(to: connection)
                context.insert(connection)
            }
        }

        // Anything left in `existingByID` wasn't in the backup — a restore
        // replaces the connection list rather than merging into it.
        for stale in existingByID.values {
            context.delete(stale)
        }
    }

    private static func restorePreferences(_ prefs: PreferencesBackup) {
        let d = UserDefaults.standard

        if let v = prefs.vncQualityRawValue { d.set(v, forKey: "default_vnc_quality") }
        if let v = prefs.vncTouchModeRawValue { d.set(v, forKey: "default_vnc_touch_mode") }
        if let v = prefs.vncPort { d.set(v, forKey: "default_vnc_port") }
        if let v = prefs.terminalFontSize { d.set(v, forKey: "default_terminal_font_size") }
        if let v = prefs.terminalQuickKeysRawValue { d.set(v, forKey: "terminal_quick_keys") }
        if let v = prefs.keyboardScrollPad { d.set(v, forKey: "keyboard_scroll_pad") }
        if let v = prefs.terminalScrollPad { d.set(v, forKey: "terminal_scroll_pad") }
        if let v = prefs.projectsLastHost { d.set(v, forKey: "projects_last_host") }
        if let v = prefs.spatialAudioModeRawValue { d.set(v, forKey: "default_spatial_audio_mode") }

        if let v = prefs.moonlightPort { d.set(v, forKey: "default_ml_port") }
        if let v = prefs.moonlightResolutionRawValue { d.set(v, forKey: "default_ml_resolution") }
        if let v = prefs.moonlightFPS { d.set(v, forKey: "default_ml_fps") }
        if let v = prefs.moonlightBitrate { d.set(v, forKey: "default_ml_bitrate") }
        if let v = prefs.moonlightCodecRawValue { d.set(v, forKey: "default_ml_codec") }
        if let v = prefs.moonlightAudioConfigRawValue { d.set(v, forKey: "default_ml_audio_config") }
        if let v = prefs.moonlightTouchModeRawValue { d.set(v, forKey: "default_ml_touch_mode") }
        if let v = prefs.moonlightSpatialAudioEnabled { d.set(v, forKey: "moonlightSpatialAudioEnabled") }

        if let v = prefs.foveatedPort { d.set(v, forKey: "default_fov_port") }
        if let v = prefs.foveatedModeRawValue { d.set(v, forKey: "default_fov_mode") }
        if let v = prefs.foveatedControllerBridge { d.set(v, forKey: "default_fov_controller_bridge") }
        if let v = prefs.foveatedControllerHandRawValue { d.set(v, forKey: "foveatedControllerHand") }
        if let v = prefs.foveatedShowSentSkeleton { d.set(v, forKey: "foveatedShowSentSkeleton") }
        if let v = prefs.foveatedWristHUD { d.set(v, forKey: "foveatedWristHUD") }
        if let v = prefs.foveatedWristHUDOnRight { d.set(v, forKey: "foveatedWristHUDOnRight") }
        if let v = prefs.foveatedGameProfilesData { d.set(v, forKey: "foveatedGameProfiles.v1") }

        #if os(visionOS)
        let broadcast = BroadcastShared.defaults
        if let v = prefs.broadcastCameraID { broadcast.set(v, forKey: BroadcastShared.Keys.camera) }
        if let v = prefs.broadcastMicEnabled { broadcast.set(v, forKey: BroadcastShared.Keys.mic) }
        if let v = prefs.broadcastHost { broadcast.set(v, forKey: BroadcastShared.Keys.host) }
        if let v = prefs.broadcastPort { broadcast.set(v, forKey: BroadcastShared.Keys.port) }
        if let v = prefs.broadcastPath { broadcast.set(v, forKey: BroadcastShared.Keys.path) }
        if let v = prefs.broadcastViewPath { broadcast.set(v, forKey: BroadcastShared.Keys.viewPath) }
        if let v = prefs.broadcastUsername { broadcast.set(v, forKey: BroadcastShared.Keys.username) }
        if let v = prefs.broadcastBitrateMbps { broadcast.set(v, forKey: BroadcastShared.Keys.bitrate) }
        if let v = prefs.broadcastCertFingerprint { broadcast.set(v, forKey: BroadcastShared.Keys.certFingerprint) }
        #endif
    }
}
