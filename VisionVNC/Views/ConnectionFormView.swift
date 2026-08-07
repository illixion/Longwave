import SwiftUI
import SwiftData

struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager

    var savedConnection: SavedConnection?

    /// All saved connections, used to populate the audio-companion picker.
    @Query private var allConnections: [SavedConnection]
    private var audioConnections: [SavedConnection] {
        allConnections.filter { $0.connectionType == .audio }
    }

    // Common — new connections are seeded from ConnectionDefaults (Settings tab)
    @State private var connectionType: ConnectionType = .vnc
    @State private var hostname: String = ""
    @State private var port: String = String(ConnectionDefaults.port(for: .vnc))
    @State private var label: String = ""

    /// True when `hostname` was auto-filled from a detected Windows hotspot (shows a hint).
    @State private var didDetectHotspotHost: Bool = false

    // VNC
    @State private var quality: ConnectionQuality = ConnectionDefaults.vncQuality
    @State private var autoLogin: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var vncTouchMode: TouchMode = ConnectionDefaults.vncTouchMode
    @State private var linkedAudioConnectionID: UUID?
    /// macOS: hide the system pointer over the remote view. Default depends on
    /// type — Moonlight hides (games draw their own cursor), VNC shows (the
    /// remote may not draw one). See `defaultHideLocalCursor(for:)`.
    @State private var hideLocalCursor: Bool = false

    // Audio
    @State private var audioToken: String = ""
    @State private var lowLatencyAudio: Bool = false

    // SSH
    @State private var sshUsername: String = ""
    @State private var sshLaunchCommand: String = ""
    @State private var sshClientCommand: String = ""
    @State private var sshEnvVars: String = ""
    @State private var sshUseTmux: Bool = true

    private enum Field: Hashable {
        case hostname, port, username, password, label, audioToken, sshUsername, sshLaunchCommand
        case sshClientCommand, sshEnvVars
    }
    @FocusState private var focusedField: Field?

    #if MOONLIGHT_ENABLED
    // Moonlight — Video
    @State private var moonlightResolution: MoonlightResolution = ConnectionDefaults.moonlightResolution
    @State private var moonlightFPS: Int = ConnectionDefaults.moonlightFPS
    @State private var moonlightBitrate: Double = Double(ConnectionDefaults.moonlightBitrate)
    @State private var moonlightVideoCodec: VideoCodecPreference = ConnectionDefaults.moonlightCodec
    @State private var moonlightEnableHDR: Bool = false
    @State private var moonlightUseFramePacing: Bool = false

    // Moonlight — Audio
    @State private var moonlightAudioConfig: AudioConfiguration = ConnectionDefaults.moonlightAudioConfig
    @State private var moonlightPlayAudioOnPC: Bool = false

    // Moonlight — Input
    @State private var moonlightTouchMode: TouchMode = ConnectionDefaults.moonlightTouchMode
    @State private var moonlightMultiController: Bool = true
    @State private var moonlightSwapABXY: Bool = false

    // Moonlight — Server
    @State private var moonlightOptimizeGameSettings: Bool = true

    // Moonlight — Debug
    @State private var moonlightShowStatsOverlay: Bool = false
    #endif

    private var hasCredentials: Bool {
        !password.isEmpty
    }

    private var isEditing: Bool {
        savedConnection != nil
    }

    /// Only VNC/Moonlight connect to the hotspot host (the Windows box). Audio/SSH target a Mac.
    private var typeTargetsHotspotHost: Bool {
        switch connectionType {
        case .vnc: return true
        #if MOONLIGHT_ENABLED
        case .moonlight: return true
        #endif
        default: return false
        }
    }

    /// Pre-fill the host with the Windows ICS gateway when this device is on a hotspot subnet —
    /// a smart, overridable default. New, host-targeting connections with an empty host only.
    private func prefillHotspotHostIfAvailable() {
        guard !isEditing, typeTargetsHotspotHost, hostname.isEmpty else { return }
        if let host = LocalNetwork.windowsHotspotHost() {
            hostname = host
            didDetectHotspotHost = true
        }
    }

    var body: some View {
        Form {
            connectionTypeSection
            serverSection

            switch connectionType {
            case .vnc:
                vncSections
            case .macNative:
                macNativeSections
            case .ssh:
                sshSections
            #if MOONLIGHT_ENABLED
            case .moonlight:
                moonlightSections
            #endif
            case .audio:
                audioSections
            }

            labelSection
        }
        .navigationTitle(isEditing ? "Edit Connection" : "New Connection")
        // macOS: the default `.columns` form style right-aligns field titles in a
        // narrow column that clips long labels ("Hostname or IP Address"); grouped
        // style lays them out cleanly. And sheets size to content, so switching
        // connection type would jump the window — pin a stable size (the Form
        // scrolls for tall Moonlight content).
        #if os(macOS)
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveConnection()
                }
                .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            loadFromSavedConnection()
            if !isEditing { hideLocalCursor = defaultHideLocalCursor(for: connectionType) }
            consumePendingImportedToken()
            prefillHotspotHostIfAvailable()
        }
        .onChange(of: connectionType) { _, newType in
            port = String(ConnectionDefaults.port(for: newType))
            // New connections only (type is locked when editing): apply the
            // type-appropriate local-cursor default.
            hideLocalCursor = defaultHideLocalCursor(for: newType)
            // Re-evaluate the hotspot pre-fill for the newly selected type; clear a stale hint.
            if hostname.isEmpty { didDetectHotspotHost = false }
            prefillHotspotHostIfAvailable()
        }
        .onChange(of: audioManager.pendingImportedToken) { _, _ in
            consumePendingImportedToken()
        }
    }

    // MARK: - Shared Sections

    private var connectionTypeSection: some View {
        Section {
            Picker("Type", selection: $connectionType) {
                ForEach(availableConnectionTypes, id: \.self) { type in
                    Label(type.label, systemImage: type.systemImage).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isEditing) // Can't change type after creation
        }
    }

    private var availableConnectionTypes: [ConnectionType] {
        #if os(macOS)
        ConnectionType.allCases.filter { $0 != .ssh && $0 != .macNative }
        #else
        ConnectionType.allCases
        #endif
    }

    // MARK: - Native Mac Sections

    @ViewBuilder
    private var macNativeSections: some View {
        Section("Native Mac Stream") {
            Text("Streams the Mac's visible windows over a transparent background using ScreenCaptureKit and hardware HEVC with alpha.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Companion Token") {
            TextField("Token", text: $audioToken)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .audioToken)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .audioToken }

            Text("Use the same token shown in VisionVNC Companion. A new authenticated viewer replaces the previous viewer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("Hostname or IP Address", text: $hostname)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .hostname)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .hostname }

            TextField("Port", text: $port)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .port)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .port }

            if didDetectHotspotHost && hostname == LocalNetwork.windowsIcsGateway {
                Label("Detected a Windows hotspot — host set to its gateway (\(LocalNetwork.windowsIcsGateway)). Edit if needed.",
                      systemImage: "wifi.router")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var labelSection: some View {
        Section("Label") {
            TextField("Display Name (optional)", text: $label)
                .focused($focusedField, equals: .label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .label }
        }
    }

    // MARK: - VNC Sections

    @ViewBuilder
    private var vncSections: some View {
        Section("Authentication") {
            Toggle("Auto Login", isOn: $autoLogin)

            if autoLogin {
                TextField("Username (optional)", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .username)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { focusedField = .username }

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { focusedField = .password }

                if isEditing && hasCredentials {
                    Button("Clear Saved Credentials", role: .destructive) {
                        username = ""
                        password = ""
                    }
                }
            }
        }

        Section("Quality") {
            Picker("Quality", selection: $quality) {
                ForEach(ConnectionQuality.allCases, id: \.self) { q in
                    Text(q.label).tag(q)
                }
            }
            .pickerStyle(.segmented)

            Text(quality.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Input") {
            #if os(macOS)
            // A Mac uses absolute pointing (its real cursor) — no touch mode.
            Toggle("Hide local cursor over the screen", isOn: $hideLocalCursor)
                .help("Hide the Mac pointer while it's over the remote screen, so only the remote cursor shows.")
            #else
            Picker("Touch Mode", selection: $vncTouchMode) {
                ForEach(TouchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Text(vncTouchMode == .relative
                ? "Drag to move the cursor. Tap to click at the cursor position. Double-tap for right-click."
                : "Tap and drag directly on the remote screen. Double-tap for right-click.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }

        Section("Audio Companion") {
            if audioConnections.isEmpty {
                Text("Create an Audio connection first to link one here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Linked Audio", selection: $linkedAudioConnectionID) {
                    Text("None").tag(UUID?.none)
                    ForEach(audioConnections) { conn in
                        Text(conn.displayName).tag(Optional(conn.id))
                    }
                }

                Text("Pairs this desktop with a companion (the Mac menu-bar app). It starts the audio stream automatically and enables the keyboard bypass — typed text and dictation route through the Mac instead of VNC key codes (modifier-safe). When unset, a companion on the same host is used if one exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio Sections

    @ViewBuilder
    private var audioSections: some View {
        Section("Audio Stream") {
            Text("Streams uncompressed system audio from the VisionVNC Companion menu bar app on your Mac. Unlike Mac Virtual Display audio, playback respects this app's Spatial Audio setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Access Token") {
            TextField("Token", text: $audioToken)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .audioToken)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .audioToken }

            Text("Copy the token from the Companion menu bar app, or AirDrop it to auto-fill this field. The token both authorizes and encrypts the connection (TLS) — no VPN needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Latency") {
            Toggle("Low-Latency Mode (UDP)", isOn: $lowLatencyAudio)

            Text("Sends audio over UDP (DTLS-encrypted) with a smaller jitter buffer for lower latency. Needs a clean local network — falls back to the standard stream if UDP can't get through.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - SSH Sections

    @ViewBuilder
    private var sshSections: some View {
        Section("SSH") {
            TextField("Username", text: $sshUsername)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .sshUsername)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .sshUsername }

            Text("Key-based login. Add this device's SSH key (Projects tab → Copy Public Key) to ~/.ssh/authorized_keys on the host. The private key never leaves the Secure Enclave.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Command") {
            TextField("Login shell (default)", text: $sshLaunchCommand)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .sshLaunchCommand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .sshLaunchCommand }

            Text("Optional command to run on connect. Empty = an interactive login shell. To run Claude in a project folder, use the Projects tab instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Persist session with tmux", isOn: $sshUseTmux)

            Text("Wraps the session in tmux on the host so it survives drops (e.g. visionOS tracking loss) and reconnects right where you left off. Falls back to a plain shell if tmux isn't installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Custom Agent Command (Projects tab)") {
            TextField("claude", text: $sshClientCommand)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .sshClientCommand)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { focusedField = .sshClientCommand }

            Text("Command for the Projects tab's “Custom” agent — point it at any CLI. Claude and Copilot are built in with fixed commands. Pick the agent and set its login in the Projects tab.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Environment") {
            TextField("KEY=VALUE (one per line)", text: $sshEnvVars, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...6)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .sshEnvVars)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Injected before the command runs (inline; readable by your own processes on the Mac, so keep these non-secret). Agent login tokens (Claude / Copilot / Custom) are set separately per agent in the Projects tab and kept in this device's keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #if MOONLIGHT_ENABLED
    // MARK: - Moonlight Sections

    @ViewBuilder
    private var moonlightSections: some View {
        moonlightVideoSection
        moonlightAudioSection
        moonlightInputSection
        moonlightServerSection
        moonlightDebugSection
    }

    private var moonlightVideoSection: some View {
        Section("Video") {
            Picker("Resolution", selection: $moonlightResolution) {
                ForEach(MoonlightResolution.allCases, id: \.self) { res in
                    Text(res.label).tag(res)
                }
            }
            .onChange(of: moonlightResolution) { _, _ in
                recalculateSuggestedBitrate()
            }

            Picker("Frame Rate", selection: $moonlightFPS) {
                Text("30 FPS").tag(30)
                Text("60 FPS").tag(60)
                Text("90 FPS").tag(90)
                Text("120 FPS").tag(120)
            }
            .onChange(of: moonlightFPS) { _, _ in
                recalculateSuggestedBitrate()
            }

            VStack(alignment: .leading) {
                HStack {
                    Text("Bitrate")
                    Spacer()
                    Text(bitrateLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $moonlightBitrate, in: 500...150_000, step: 500)
            }

            Picker("Video Codec", selection: $moonlightVideoCodec) {
                ForEach(VideoCodecPreference.allCases, id: \.self) { codec in
                    Text(codec.label).tag(codec)
                }
            }

            Toggle("HDR", isOn: $moonlightEnableHDR)
            if moonlightEnableHDR && moonlightVideoCodec == .h264 {
                Text("HDR requires HEVC or AV1. H.264 will auto-upgrade to HEVC Main 10 if supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Frame Delivery", selection: $moonlightUseFramePacing) {
                Text("Lowest Latency").tag(false)
                Text("Smoothest Video").tag(true)
            }
        }
    }

    private var moonlightAudioSection: some View {
        Section("Audio") {
            Picker("Audio Configuration", selection: $moonlightAudioConfig) {
                ForEach(AudioConfiguration.allCases, id: \.self) { config in
                    Text(config.label).tag(config)
                }
            }

            Toggle("Play Audio on Host PC", isOn: $moonlightPlayAudioOnPC)
        }
    }

    private var moonlightInputSection: some View {
        Section("Input") {
            #if os(macOS)
            // A Mac uses absolute pointing (its real cursor) — no touch mode.
            Toggle("Hide local cursor over the stream", isOn: $hideLocalCursor)
                .help("Hide the Mac pointer while it's over the stream, so only the game/remote cursor shows.")
            #else
            Picker("Touch Mode", selection: $moonlightTouchMode) {
                ForEach(TouchMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            #endif

            Toggle("Multi-Controller Support", isOn: $moonlightMultiController)
            Toggle("Swap A/B and X/Y Buttons", isOn: $moonlightSwapABXY)
        }
    }

    private var moonlightServerSection: some View {
        Section("Server") {
            Toggle("Optimize Game Settings", isOn: $moonlightOptimizeGameSettings)
        }
    }

    private var moonlightDebugSection: some View {
        Section("Debug") {
            Toggle("Statistics Overlay", isOn: $moonlightShowStatsOverlay)
        }
    }

    // MARK: - Helpers

    private var bitrateLabel: String {

        let mbps = moonlightBitrate / 1000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        } else {
            return String(format: "%.0f Kbps", moonlightBitrate)
        }
    }

    private func recalculateSuggestedBitrate() {
        let (w, h) = moonlightResolution.dimensions
        moonlightBitrate = Double(SavedConnection.suggestedBitrate(width: w, height: h, fps: moonlightFPS))
    }
    #endif

    // MARK: - Load / Save

    /// Default local-cursor behavior for a new connection of the given type.
    /// macOS: Moonlight hides (games render their own cursor), other types show.
    /// visionOS: always show (there's no system cursor — the value is ignored).
    private func defaultHideLocalCursor(for type: ConnectionType) -> Bool {
        #if os(macOS)
        return type == .moonlight
        #else
        return false
        #endif
    }

    private func loadFromSavedConnection() {
        guard let saved = savedConnection else { return }
        hideLocalCursor = saved.hideLocalCursor

        connectionType = saved.connectionType
        hostname = saved.hostname
        port = String(saved.port)
        label = saved.label

        // VNC fields
        quality = saved.quality
        autoLogin = saved.autoLogin
        username = saved.savedUsername
        password = saved.savedPassword
        vncTouchMode = saved.vncTouchMode
        linkedAudioConnectionID = saved.linkedCompanionConnectionID
        audioToken = saved.audioToken
        lowLatencyAudio = saved.lowLatencyAudio
        sshUsername = saved.sshUsername
        sshLaunchCommand = saved.sshLaunchCommand
        sshClientCommand = saved.sshClientCommand
        sshEnvVars = saved.sshEnvVars
        sshUseTmux = saved.sshUseTmux

        #if MOONLIGHT_ENABLED
        // Moonlight fields
        moonlightResolution = MoonlightResolution.from(
            width: saved.moonlightResolutionWidth,
            height: saved.moonlightResolutionHeight
        )
        moonlightFPS = saved.moonlightFPS
        moonlightBitrate = Double(saved.moonlightBitrate)
        moonlightVideoCodec = saved.moonlightVideoCodec
        moonlightEnableHDR = saved.moonlightEnableHDR
        moonlightUseFramePacing = saved.moonlightUseFramePacing
        moonlightAudioConfig = saved.moonlightAudioConfig
        moonlightPlayAudioOnPC = saved.moonlightPlayAudioOnPC
        moonlightTouchMode = saved.moonlightTouchMode
        moonlightMultiController = saved.moonlightMultiController
        moonlightSwapABXY = saved.moonlightSwapABXY
        moonlightOptimizeGameSettings = saved.moonlightOptimizeGameSettings
        moonlightShowStatsOverlay = saved.moonlightShowStatsOverlay
        #endif
    }

    private func saveConnection() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        let portNum = Int(port) ?? connectionType.defaultPort

        if let saved = savedConnection {
            saved.hostname = trimmedHost
            saved.port = portNum
            saved.label = label.isEmpty ? "\(trimmedHost):\(portNum)" : label
            saveTypeSpecificFields(to: saved)
        } else {
            let newConnection = SavedConnection(
                hostname: trimmedHost,
                port: portNum,
                label: label,
                connectionType: connectionType
            )
            saveTypeSpecificFields(to: newConnection)
            modelContext.insert(newConnection)
        }

        dismiss()
    }

    private func saveTypeSpecificFields(to connection: SavedConnection) {
        connection.hideLocalCursor = hideLocalCursor
        switch connectionType {
        case .vnc:
            connection.quality = quality
            connection.autoLogin = autoLogin
            connection.savedUsername = autoLogin ? username : ""
            connection.savedPassword = autoLogin ? password : ""
            connection.vncTouchMode = vncTouchMode
            connection.linkedCompanionConnectionID = linkedAudioConnectionID

        case .macNative:
            connection.audioToken = audioToken.trimmingCharacters(in: .whitespacesAndNewlines)

        #if MOONLIGHT_ENABLED
        case .moonlight:
            let (w, h) = moonlightResolution.dimensions
            connection.moonlightResolutionWidth = w
            connection.moonlightResolutionHeight = h
            connection.moonlightFPS = moonlightFPS
            connection.moonlightBitrate = Int(moonlightBitrate)
            connection.moonlightVideoCodec = moonlightVideoCodec
            connection.moonlightEnableHDR = moonlightEnableHDR
            connection.moonlightUseFramePacing = moonlightUseFramePacing
            connection.moonlightAudioConfig = moonlightAudioConfig
            connection.moonlightPlayAudioOnPC = moonlightPlayAudioOnPC
            connection.moonlightTouchMode = moonlightTouchMode
            connection.moonlightMultiController = moonlightMultiController
            connection.moonlightSwapABXY = moonlightSwapABXY
            connection.moonlightOptimizeGameSettings = moonlightOptimizeGameSettings
            connection.moonlightShowStatsOverlay = moonlightShowStatsOverlay
        #endif

        case .audio:
            connection.audioToken = audioToken.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.lowLatencyAudio = lowLatencyAudio

        case .ssh:
            connection.sshUsername = sshUsername.trimmingCharacters(in: .whitespaces)
            connection.sshLaunchCommand = sshLaunchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.sshClientCommand = sshClientCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.sshEnvVars = sshEnvVars.trimmingCharacters(in: .whitespacesAndNewlines)
            connection.sshUseTmux = sshUseTmux
        }
    }

    /// Consumes a token delivered via an AirDropped x-callback URL: switches
    /// a new form to the Audio type and fills the token field. For an
    /// existing connection, only fills if it's already an audio connection.
    private func consumePendingImportedToken() {
        guard let token = audioManager.pendingImportedToken else { return }
        if isEditing {
            guard connectionType == .audio else { return }
        } else {
            connectionType = .audio
        }
        audioToken = token
        audioManager.pendingImportedToken = nil
    }
}

#if MOONLIGHT_ENABLED
// MARK: - Resolution Helper

enum MoonlightResolution: String, CaseIterable {
    case r720p
    case r1080p
    case r1440p
    case r4k

    var label: String {
        switch self {
        case .r720p: "720p"
        case .r1080p: "1080p"
        case .r1440p: "1440p"
        case .r4k: "4K"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .r720p: (1280, 720)
        case .r1080p: (1920, 1080)
        case .r1440p: (2560, 1440)
        case .r4k: (3840, 2160)
        }
    }

    static func from(width: Int, height: Int) -> MoonlightResolution {
        switch (width, height) {
        case (1280, 720): return .r720p
        case (1920, 1080): return .r1080p
        case (2560, 1440): return .r1440p
        case (3840, 2160): return .r4k
        default: return .r1080p
        }
    }
}
#endif
