import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A portable snapshot of everything Longwave persists **except secrets** —
/// saved connections (minus their passwords/tokens) and app preferences.
/// Keychain-backed material (SSH agent tokens, the Claude OAuth credential,
/// the device's Secure Enclave SSH identity, the broadcast publish password)
/// never enters this struct, and neither does anything that's just a
/// regenerable runtime/reconnect cache (Moonlight pairing state, the
/// last-resumed-audio-session cache, per-host recent-folder lists).
///
/// Every field is `Optional` so a backup written by an older or newer build
/// still decodes: an absent field is simply left untouched on import rather
/// than resetting anything to a default. This mirrors Hypnos's
/// `SettingsBackup` design — see that project's `Model/SettingsBackup.swift`.
struct LongwaveBackup: Codable {
    /// Schema version — increment when a field's meaning or type changes.
    static let currentVersion = 1

    let version: Int
    let exportDate: Date
    let appVersion: String

    var connections: [ConnectionBackup]?
    var preferences: PreferencesBackup?
}

/// `SavedConnection`, minus `savedPassword` and `companionToken` — the two
/// plaintext secrets that live in SwiftData rather than the Keychain. The
/// per-agent SSH token flags (`sshHasAuthToken` etc.) travel as booleans
/// only; the token values themselves stay in the Keychain, keyed by `id`, and
/// re-attach automatically on restore to the same device.
struct ConnectionBackup: Codable {
    var id: UUID
    var hostname: String
    var port: Int
    var label: String
    var lastConnected: Date?

    var connectionTypeRawValue: String
    var qualityRawValue: Int

    // VNC
    var autoLogin: Bool
    var savedUsername: String
    var vncTouchModeRawValue: String
    var hideLocalCursor: Bool

    // Native (Companion Screen + Audio)
    var nativeScreenEnabledStorage: Bool?
    var nativeAudioEnabledStorage: Bool?
    var nativeUnityEnabledStorage: Bool?
    var nativeUnityAutoShowStorage: Bool?
    var lowLatencyAudio: Bool
    var linkedCompanionConnectionID: UUID?

    // SSH
    var sshUsername: String
    var sshLaunchCommand: String
    var sshClientCommand: String
    var sshEnvVars: String
    var sshAuthEnvName: String
    var sshHasAuthToken: Bool
    var sshHasCopilotToken: Bool
    var sshHasCustomToken: Bool
    /// Optional where its siblings aren't: it postdates them, so backups
    /// written before Codex support simply lack the key and must still decode.
    var sshHasCodexToken: Bool?
    var sshAgentRawValue: String
    var sshInjectClaudeRefreshToken: Bool
    var sshUseTmux: Bool

    // Moonlight (declared unconditionally, like `SavedConnection` itself —
    // see the note above its own storage properties)
    var moonlightBitrateStorage: Int?
    var moonlightFPSStorage: Int?
    var moonlightResolutionWidthStorage: Int?
    var moonlightResolutionHeightStorage: Int?
    var moonlightVideoCodecRawValueStorage: String?
    var moonlightEnableHDRStorage: Bool?
    var moonlightUseFramePacingStorage: Bool?
    var moonlightAudioConfigRawValueStorage: String?
    var moonlightPlayAudioOnPCStorage: Bool?
    var moonlightTouchModeRawValueStorage: String?
    var moonlightMultiControllerStorage: Bool?
    var moonlightSwapABXYStorage: Bool?
    var moonlightOptimizeGameSettingsStorage: Bool?
    var moonlightShowStatsOverlayStorage: Bool?

    // Foveated (PCVR / CloudXR)
    var foveatedConnectionModeStorage: String?
    var foveatedRemoteServerName: String?
    var foveatedImmersionStyleStorage: String?
    var foveatedMicEnabledStorage: Bool?
    var controllerBridgeEnabledStorage: Bool?

    init(from connection: SavedConnection) {
        id = connection.id
        hostname = connection.hostname
        port = connection.port
        label = connection.label
        lastConnected = connection.lastConnected
        connectionTypeRawValue = connection.connectionTypeRawValue
        qualityRawValue = connection.qualityRawValue
        autoLogin = connection.autoLogin
        savedUsername = connection.savedUsername
        vncTouchModeRawValue = connection.vncTouchModeRawValue
        hideLocalCursor = connection.hideLocalCursor
        nativeScreenEnabledStorage = connection.nativeScreenEnabledStorage
        nativeAudioEnabledStorage = connection.nativeAudioEnabledStorage
        nativeUnityEnabledStorage = connection.nativeUnityEnabledStorage
        nativeUnityAutoShowStorage = connection.nativeUnityAutoShowStorage
        lowLatencyAudio = connection.lowLatencyAudio
        linkedCompanionConnectionID = connection.linkedCompanionConnectionID
        sshUsername = connection.sshUsername
        sshLaunchCommand = connection.sshLaunchCommand
        sshClientCommand = connection.sshClientCommand
        sshEnvVars = connection.sshEnvVars
        sshAuthEnvName = connection.sshAuthEnvName
        sshHasAuthToken = connection.sshHasAuthToken
        sshHasCopilotToken = connection.sshHasCopilotToken
        sshHasCustomToken = connection.sshHasCustomToken
        sshHasCodexToken = connection.sshHasCodexToken
        sshAgentRawValue = connection.sshAgentRawValue
        sshInjectClaudeRefreshToken = connection.sshInjectClaudeRefreshToken
        sshUseTmux = connection.sshUseTmux
        moonlightBitrateStorage = connection.moonlightBitrateStorage
        moonlightFPSStorage = connection.moonlightFPSStorage
        moonlightResolutionWidthStorage = connection.moonlightResolutionWidthStorage
        moonlightResolutionHeightStorage = connection.moonlightResolutionHeightStorage
        moonlightVideoCodecRawValueStorage = connection.moonlightVideoCodecRawValueStorage
        moonlightEnableHDRStorage = connection.moonlightEnableHDRStorage
        moonlightUseFramePacingStorage = connection.moonlightUseFramePacingStorage
        moonlightAudioConfigRawValueStorage = connection.moonlightAudioConfigRawValueStorage
        moonlightPlayAudioOnPCStorage = connection.moonlightPlayAudioOnPCStorage
        moonlightTouchModeRawValueStorage = connection.moonlightTouchModeRawValueStorage
        moonlightMultiControllerStorage = connection.moonlightMultiControllerStorage
        moonlightSwapABXYStorage = connection.moonlightSwapABXYStorage
        moonlightOptimizeGameSettingsStorage = connection.moonlightOptimizeGameSettingsStorage
        moonlightShowStatsOverlayStorage = connection.moonlightShowStatsOverlayStorage
        foveatedConnectionModeStorage = connection.foveatedConnectionModeStorage
        foveatedRemoteServerName = connection.foveatedRemoteServerName
        foveatedImmersionStyleStorage = connection.foveatedImmersionStyleStorage
        foveatedMicEnabledStorage = connection.foveatedMicEnabledStorage
        controllerBridgeEnabledStorage = connection.controllerBridgeEnabledStorage
    }

    /// Writes every field but `id` onto `connection`. Never touches
    /// `savedPassword`/`companionToken` — those aren't in this struct, so a
    /// restored connection keeps whatever secret (or blank) it already had.
    func apply(to connection: SavedConnection) {
        connection.hostname = hostname
        connection.port = port
        connection.label = label
        connection.lastConnected = lastConnected
        connection.connectionTypeRawValue = connectionTypeRawValue
        connection.qualityRawValue = qualityRawValue
        connection.autoLogin = autoLogin
        connection.savedUsername = savedUsername
        connection.vncTouchModeRawValue = vncTouchModeRawValue
        connection.hideLocalCursor = hideLocalCursor
        connection.nativeScreenEnabledStorage = nativeScreenEnabledStorage
        connection.nativeAudioEnabledStorage = nativeAudioEnabledStorage
        connection.nativeUnityEnabledStorage = nativeUnityEnabledStorage
        connection.nativeUnityAutoShowStorage = nativeUnityAutoShowStorage
        connection.lowLatencyAudio = lowLatencyAudio
        connection.linkedCompanionConnectionID = linkedCompanionConnectionID
        connection.sshUsername = sshUsername
        connection.sshLaunchCommand = sshLaunchCommand
        connection.sshClientCommand = sshClientCommand
        connection.sshEnvVars = sshEnvVars
        connection.sshAuthEnvName = sshAuthEnvName
        connection.sshHasAuthToken = sshHasAuthToken
        connection.sshHasCopilotToken = sshHasCopilotToken
        connection.sshHasCustomToken = sshHasCustomToken
        connection.sshHasCodexToken = sshHasCodexToken ?? false
        connection.sshAgentRawValue = sshAgentRawValue
        connection.sshInjectClaudeRefreshToken = sshInjectClaudeRefreshToken
        connection.sshUseTmux = sshUseTmux
        connection.moonlightBitrateStorage = moonlightBitrateStorage
        connection.moonlightFPSStorage = moonlightFPSStorage
        connection.moonlightResolutionWidthStorage = moonlightResolutionWidthStorage
        connection.moonlightResolutionHeightStorage = moonlightResolutionHeightStorage
        connection.moonlightVideoCodecRawValueStorage = moonlightVideoCodecRawValueStorage
        connection.moonlightEnableHDRStorage = moonlightEnableHDRStorage
        connection.moonlightUseFramePacingStorage = moonlightUseFramePacingStorage
        connection.moonlightAudioConfigRawValueStorage = moonlightAudioConfigRawValueStorage
        connection.moonlightPlayAudioOnPCStorage = moonlightPlayAudioOnPCStorage
        connection.moonlightTouchModeRawValueStorage = moonlightTouchModeRawValueStorage
        connection.moonlightMultiControllerStorage = moonlightMultiControllerStorage
        connection.moonlightSwapABXYStorage = moonlightSwapABXYStorage
        connection.moonlightOptimizeGameSettingsStorage = moonlightOptimizeGameSettingsStorage
        connection.moonlightShowStatsOverlayStorage = moonlightShowStatsOverlayStorage
        connection.foveatedConnectionModeStorage = foveatedConnectionModeStorage
        connection.foveatedRemoteServerName = foveatedRemoteServerName
        connection.foveatedImmersionStyleStorage = foveatedImmersionStyleStorage
        connection.foveatedMicEnabledStorage = foveatedMicEnabledStorage
        connection.controllerBridgeEnabledStorage = controllerBridgeEnabledStorage
    }
}

/// App-wide, non-secret preferences: new-connection defaults
/// (`ConnectionDefaults`), terminal/keyboard toggles, Moonlight/Foveated
/// globals, and Broadcast server settings. Key strings are duplicated from
/// their owning types rather than referencing `ConnectionDefaults.Keys`
/// (which is partly compiled out under `#if MOONLIGHT_ENABLED`/
/// `#if FOVEATED_ENABLED`) so this struct — and the export/import that reads
/// raw `UserDefaults` keys — builds identically in every edition.
struct PreferencesBackup: Codable {
    var vncQualityRawValue: Int?
    var vncTouchModeRawValue: String?
    var vncPort: Int?
    var terminalFontSize: Double?
    var terminalQuickKeysRawValue: String?
    var keyboardScrollPad: Bool?
    var terminalScrollPad: Bool?
    var projectsLastHost: String?
    var spatialAudioModeRawValue: String?

    // Moonlight defaults + globals
    var moonlightPort: Int?
    var moonlightResolutionRawValue: String?
    var moonlightFPS: Int?
    var moonlightBitrate: Int?
    var moonlightCodecRawValue: String?
    var moonlightAudioConfigRawValue: String?
    var moonlightTouchModeRawValue: String?
    var moonlightSpatialAudioEnabled: Bool?

    // Foveated (PCVR) defaults + globals
    var foveatedPort: Int?
    var foveatedModeRawValue: String?
    var foveatedControllerBridge: Bool?
    var foveatedControllerHandRawValue: String?
    var foveatedShowSentSkeleton: Bool?
    var foveatedWristHUD: Bool?
    var foveatedWristHUDOnRight: Bool?
    /// Double-encoded `[String: GameProfile]` (`GameProfiles.saved()`), kept
    /// as an opaque blob so this struct doesn't need `GameProfile`, which is
    /// declared inside `#if FOVEATED_ENABLED`.
    var foveatedGameProfilesData: Data?
    /// The pinned web panels (`PCVRWebPanelStore`), opaque for the same reason.
    var foveatedWebPanelsData: Data?

    // Broadcast (non-secret half — the publish password stays in Keychain)
    var broadcastCameraID: String?
    var broadcastMicEnabled: Bool?
    var broadcastHost: String?
    var broadcastPort: Int?
    var broadcastPath: String?
    var broadcastViewPath: String?
    var broadcastUsername: String?
    var broadcastBitrateMbps: Int?
    var broadcastCertFingerprint: String?
}

/// `.fileExporter`/`.fileImporter` wrapper for a `LongwaveBackup`'s encoded JSON.
struct LongwaveBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
