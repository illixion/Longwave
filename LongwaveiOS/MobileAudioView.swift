import SwiftUI
import SwiftData
import RAVEMedia

/// The Audio tab: the shared mini-player, plus the controls that still mean
/// something here.
///
/// Not `AudioStreamView`. That one is a standalone visionOS *window* — fixed at
/// 400 pt, sized to a `.plain` glass panel, and its chrome is window chrome: a
/// close button that dismisses the scene and a home button that summons the
/// connection manager back into the room. On a phone the width overflows, and
/// both of those buttons address windows that do not exist. The panel and the
/// volume row underneath it are the parts worth sharing, and they are shared.
///
/// Spatial audio is left out rather than shown doing nothing:
/// `setIntendedSpatialExperience` is visionOS-only API, so the toggle would be
/// inert here (see `AudioStreamManager`).
struct MobileAudioView: View {
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var savedConnections: [SavedConnection]

    @State private var showEQ = false

    /// Audio-only Native connections, hidden from the Connections list on
    /// iOS (see `ConnectionListView.visibleConnections`) so this tab is
    /// their one entry point.
    private var audioOnlyConnections: [SavedConnection] {
        savedConnections.filter(\.isNativeAudioOnly)
    }

    var body: some View {
        NavigationStack {
            Group {
                if audioManager.state == .idle {
                    if audioOnlyConnections.isEmpty {
                        ContentUnavailableView(
                            "No Audio Stream",
                            systemImage: "hifispeaker",
                            description: Text("Start a Native connection with Audio enabled to stream your Mac's system audio here.")
                        )
                    } else {
                        connectionPicker
                    }
                } else {
                    player
                }
            }
            .navigationTitle("Audio")
        }
        .onAppear { audioManager.ensureConnected() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { audioManager.ensureConnected() }
        }
    }

    private var connectionPicker: some View {
        List(audioOnlyConnections) { connection in
            Button {
                connect(connection)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(connection.hostname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func connect(_ connection: SavedConnection) {
        audioManager.liveEnabled = true
        audioManager.connect(
            hostname: connection.hostname,
            port: AudioStreamProtocol.defaultPort,
            token: connection.companionToken,
            title: connection.displayName,
            lowLatency: connection.lowLatencyAudio
        )
    }

    private var player: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // The panel lays the artwork out edge to edge at the width it
                    // is given, so it gets the screen's width rather than the
                    // window width the visionOS player assumes.
                    AudioPlayerPanel(width: geometry.size.width)

                    AudioVolumeRow()
                        .padding(.horizontal, 24)
                        .padding(.top, 20)

                    utilityRow
                        .padding(.top, 20)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    /// Disconnect, manual recovery, playback mode, EQ. No close and no home:
    /// this is a tab, and the way out of it is the tab bar.
    private var utilityRow: some View {
        HStack(spacing: 28) {
            Button(role: .destructive) {
                audioManager.userDisconnect()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel("Disconnect")

            Button {
                audioManager.reconnectLast()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(audioManager.state == .connecting)
            .accessibilityLabel("Reconnect")

            Button {
                audioManager.toggleAudioMode()
            } label: {
                Image(systemName: audioManager.audioModeSymbol)
            }
            .accessibilityLabel(audioManager.audioModeLabel)

            Button {
                showEQ.toggle()
            } label: {
                Image(systemName: "waveform")
            }
            // `waveform` has no .fill variant — tint marks the EQ as active.
            .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
            .sheet(isPresented: $showEQ) {
                @Bindable var audioManager = audioManager
                NavigationStack {
                    EQEditorView(settings: $audioManager.eqSettings)
                }
            }
            .accessibilityLabel("Equalizer")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }
}
