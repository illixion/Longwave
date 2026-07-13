import SwiftUI

/// Standalone mini-player window for an active audio-only stream from the
/// VisionVNC Companion Mac menu bar app. Wraps the shared
/// `AudioPlayerPanel` (album art + labels + transport) with window-level
/// chrome: lifecycle handling and a disconnect / home / reconnect row.
struct AudioStreamView: View {
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    /// Width of the window content; the album art is an edge-to-edge
    /// square of this size, iTunes-mini-player style.
    private static let playerWidth: CGFloat = 400

    @State private var showEQ = false

    var body: some View {
        VStack(spacing: 0) {
            AudioPlayerPanel(width: Self.playerWidth)

            AudioVolumeRow()
                .padding(.horizontal, 28)
                .padding(.top, 22)

            utilityRow
                .padding(.top, 22)
                .padding(.bottom, 22)
        }
        .frame(width: Self.playerWidth)
        .onAppear {
            // Resumes the last stream when visionOS restores this window
            // after an app relaunch (snapped-window space restoration).
            audioManager.ensureConnected()
        }
        .onDisappear {
            // Grace-period teardown — transient hides (space restore)
            // re-trigger onAppear/scenePhase, which cancels it.
            audioManager.windowDisappeared()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                audioManager.ensureConnected()
            }
        }
    }

    /// Action row: disconnect + home + manual stream-recovery. The home
    /// button lives here instead of the bottom ornament — the ornament
    /// floats over the album art and overlaps the transport controls.
    /// (Muting is folded into the volume slider above — 0 = muted.)
    private var utilityRow: some View {
        HStack(spacing: 28) {
            Button(role: .destructive) {
                audioManager.userDisconnect()
                // Surface the connection manager (a no-op if it's already
                // open; visionOS won't let an app close its own last window).
                openWindow(id: "main", value: MainWindowID.shared)
                dismissWindow(id: "audio-stream")
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Disconnect")

            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Image(systemName: "house")
            }
            .help("Open the connection manager")

            Button {
                audioManager.reconnectLast()
            } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .disabled(audioManager.state == .connecting)
            .help("Reconnect the audio stream")

            Button {
                audioManager.toggleAudioMode()
            } label: {
                Image(systemName: audioManager.audioMode == .music ? "music.note" : "hifispeaker")
            }
            .help(audioManager.audioMode == .music
                  ? "Music Mode — exclusive playback with Control Center; pauses on interruption"
                  : "Speaker Mode — mixes with other audio and auto-recovers")

            Button {
                showEQ.toggle()
            } label: {
                Image(systemName: "waveform")
            }
            // `waveform` has no .fill variant — tint marks the EQ as active.
            .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
            // A sheet, not a popover: the editor is wider than this 400 pt
            // window, and visionOS clips popovers to their anchor window's
            // presentation bounds.
            .sheet(isPresented: $showEQ) {
                EQEditorView()
                    .environment(audioManager)
            }
            .help("Equalizer")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }
}
