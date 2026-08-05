import SwiftUI

/// Settings tab: defaults applied when creating a new connection.
/// Existing saved connections are not affected.
struct SettingsView: View {
    // VNC
    @AppStorage(ConnectionDefaults.Keys.vncQuality) private var vncQualityRaw = ConnectionQuality.high.rawValue
    @AppStorage(ConnectionDefaults.Keys.vncTouchMode) private var vncTouchModeRaw = TouchMode.relative.rawValue
    @AppStorage(ConnectionDefaults.Keys.vncPort) private var vncPort = ConnectionType.vnc.defaultPort

    // Audio
    @AppStorage(ConnectionDefaults.Keys.audioPort) private var audioPort = ConnectionType.audio.defaultPort

    #if os(visionOS)
    // Terminal (applies live to open terminal windows, unlike the
    // new-connection defaults above)
    @AppStorage(ConnectionDefaults.Keys.terminalFontSize) private var terminalFontSize = ConnectionDefaults.terminalFontSizeDefault
    @AppStorage(ConnectionDefaults.Keys.terminalQuickKeys) private var quickKeysRaw = TerminalQuickKey.defaultSelectionStored
    #endif

    #if MOONLIGHT_ENABLED
    @AppStorage(ConnectionDefaults.Keys.moonlightPort) private var moonlightPort = ConnectionType.moonlight.defaultPort
    @AppStorage(ConnectionDefaults.Keys.moonlightResolution) private var moonlightResolutionRaw = MoonlightResolution.r1080p.rawValue
    @AppStorage(ConnectionDefaults.Keys.moonlightFPS) private var moonlightFPS = 60
    @AppStorage(ConnectionDefaults.Keys.moonlightBitrate) private var moonlightBitrate = 20000
    @AppStorage(ConnectionDefaults.Keys.moonlightCodec) private var moonlightCodecRaw = VideoCodecPreference.auto.rawValue
    @AppStorage(ConnectionDefaults.Keys.moonlightAudioConfig) private var moonlightAudioConfigRaw = AudioConfiguration.stereo.rawValue
    @AppStorage(ConnectionDefaults.Keys.moonlightTouchMode) private var moonlightTouchModeRaw = TouchMode.relative.rawValue
    #endif

    var body: some View {
        // On macOS this is hosted in a Settings tab, which provides the title —
        // a NavigationStack would add a redundant header. visionOS needs the
        // stack for its navigation title.
        #if os(macOS)
        formContent
        #else
        NavigationStack {
            formContent
                .navigationTitle("Settings")
        }
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
            Form {
                Section {
                    Text("Defaults pre-filled when adding a new connection. Existing connections keep their own settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("VNC") {
                    Picker("Quality", selection: $vncQualityRaw) {
                        ForEach(ConnectionQuality.allCases, id: \.rawValue) { q in
                            Text(q.label).tag(q.rawValue)
                        }
                    }
                    Picker("Touch Mode", selection: $vncTouchModeRaw) {
                        ForEach(TouchMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    portField("Port", value: $vncPort)
                }

                Section("Audio Stream") {
                    portField("Port", value: $audioPort)
                }

                #if os(visionOS)
                Section("Terminal") {
                    LabeledContent("Font Size") {
                        Stepper(value: $terminalFontSize, in: 10...24, step: 1) {
                            Text("\(Int(terminalFontSize)) pt")
                                .monospacedDigit()
                        }
                    }
                    DisclosureGroup("Quick Keys") {
                        quickKeyToggles
                    }
                    Text("Applies to open terminal windows immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                #if MOONLIGHT_ENABLED
                Section("Moonlight") {
                    Picker("Resolution", selection: $moonlightResolutionRaw) {
                        ForEach(MoonlightResolution.allCases, id: \.rawValue) { res in
                            Text(res.label).tag(res.rawValue)
                        }
                    }
                    Picker("Frame Rate", selection: $moonlightFPS) {
                        Text("30 FPS").tag(30)
                        Text("60 FPS").tag(60)
                        Text("90 FPS").tag(90)
                        Text("120 FPS").tag(120)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text(bitrateLabel)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(moonlightBitrate) },
                                set: { moonlightBitrate = Int($0) }
                            ),
                            in: 500...150_000,
                            step: 500
                        )
                    }
                    Picker("Video Codec", selection: $moonlightCodecRaw) {
                        ForEach(VideoCodecPreference.allCases, id: \.rawValue) { codec in
                            Text(codec.label).tag(codec.rawValue)
                        }
                    }
                    Picker("Audio Configuration", selection: $moonlightAudioConfigRaw) {
                        ForEach(AudioConfiguration.allCases, id: \.rawValue) { config in
                            Text(config.label).tag(config.rawValue)
                        }
                    }
                    Picker("Touch Mode", selection: $moonlightTouchModeRaw) {
                        ForEach(TouchMode.allCases, id: \.rawValue) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    portField("Port", value: $moonlightPort)
                }
                #endif

                Section("About") {
                    LabeledContent("Version", value: appVersionString)
                }
            }
    }

    /// "0.1.0 (abc1234)" — commit baked in by scripts/set-build-info.sh
    /// via Configuration/BuildInfo.xcconfig; falls back to the bare
    /// version for builds without it (e.g. plain Xcode builds).
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let commitHash = Bundle.main.infoDictionary?["CommitHash"] as? String
        if let commitHash, !commitHash.isEmpty, commitHash != "unknown" {
            return "\(version) (\(commitHash))"
        }
        return version
    }

    #if os(visionOS)
    /// One toggle per catalog key, shown with its row glyph. The enabled set
    /// round-trips through the comma-joined id string the terminal row reads.
    private var quickKeyToggles: some View {
        ForEach(TerminalQuickKey.catalog) { key in
            Toggle(isOn: Binding(
                get: { TerminalQuickKey.enabledIDs(from: quickKeysRaw).contains(key.id) },
                set: { on in
                    var enabled = TerminalQuickKey.enabledIDs(from: quickKeysRaw)
                    if on { enabled.insert(key.id) } else { enabled.remove(key.id) }
                    quickKeysRaw = TerminalQuickKey.encodeSelection(enabled)
                }
            )) {
                HStack(spacing: 12) {
                    Text(key.label)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 44, alignment: .leading)
                    Text(key.name)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, text: Binding(
                get: { String(value.wrappedValue) },
                set: { value.wrappedValue = Int($0) ?? value.wrappedValue }
            ))
            .labelsHidden()  // the LabeledContent already shows the title (avoids "Port Port")
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
        }
    }

    #if MOONLIGHT_ENABLED
    private var bitrateLabel: String {
        let mbps = Double(moonlightBitrate) / 1000
        return mbps >= 1
            ? String(format: "%.1f Mbps", mbps)
            : "\(moonlightBitrate) Kbps"
    }
    #endif
}
