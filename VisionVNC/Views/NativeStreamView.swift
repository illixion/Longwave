#if os(visionOS)
import SwiftUI
import AVFoundation
import UIKit

private final class MacNativeLayerView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct MacNativeVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> MacNativeLayerView {
        MacNativeLayerView(displayLayer: displayLayer)
    }

    func updateUIView(_ uiView: MacNativeLayerView, context: Context) {}
}

/// The one window for a Native connection: Screen and Audio toggle
/// independently and live (an `.onChange` on each manager's `liveEnabled`
/// drives the actual connect/disconnect), with the layout adapting to
/// what's currently on — full-bleed video with a compact audio overlay
/// when both are on, the full audio mini-player when only Audio is on, or
/// a placeholder when both are off.
struct NativeStreamView: View {
    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var showEQ = false

    var body: some View {
        @Bindable var screenManager = screenManager
        @Bindable var audioManager = audioManager

        ZStack {
            Color.clear

            if screenManager.liveEnabled {
                screenContent
            } else if audioManager.liveEnabled {
                audioOnlyContent
            } else {
                emptyContent
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            controls(screenOn: $screenManager.liveEnabled, audioOn: $audioManager.liveEnabled)
        }
        .onAppear {
            resumeIfNeeded()
        }
        .onDisappear {
            // Soft teardown only — visionOS also fires this on transient
            // hides (space restore, snapping); a full forget happens only
            // from the explicit Disconnect button below.
            screenManager.disconnect()
            audioManager.windowDisappeared()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            resumeIfNeeded()
        }
        .onChange(of: screenManager.liveEnabled) { _, on in
            if on, let connection = screenManager.connection {
                screenManager.connect(to: connection)
            } else {
                screenManager.disconnect()
            }
        }
        .onChange(of: audioManager.liveEnabled) { _, on in
            if on {
                audioManager.reconnectLast()
            } else {
                audioManager.disconnect()
            }
        }
    }

    /// Recovers a toggle that's on but not actually connected — the normal
    /// case after a scene reactivation or a full space-restoration relaunch
    /// (a fresh manager with no in-memory state). A no-op when already
    /// running, so this is safe to call on every appear/activation.
    private func resumeIfNeeded() {
        if audioManager.liveEnabled {
            audioManager.ensureConnected()
        }
        if screenManager.liveEnabled, !screenManager.isEnabled, let connection = screenManager.connection {
            screenManager.connect(to: connection)
        }
    }

    // MARK: - Screen (with an optional compact Audio overlay)

    @ViewBuilder
    private var screenContent: some View {
        ZStack {
            if let displayLayer = screenManager.displayLayer {
                MacNativeVideoView(displayLayer: displayLayer)
                    .ignoresSafeArea()
            }

            if screenManager.state != .streaming {
                VStack(spacing: 16) {
                    if case .disconnected = screenManager.state {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 42))
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }
                    Text(screenManager.state.statusText)
                        .font(.headline)
                }
                .padding(24)
                .glassBackgroundEffect()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if audioManager.liveEnabled {
                compactAudioPanel
                    .padding(24)
            }
        }
    }

    /// Slim floating status/volume cluster for when Audio plays alongside
    /// video — the full album-art mini player would compete with it.
    private var compactAudioPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Text(compactAudioStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            AudioVolumeRow()
                .frame(width: 200)

            HStack(spacing: 16) {
                Button {
                    audioManager.toggleAudioMode()
                } label: {
                    Image(systemName: audioManager.audioMode == .music ? "music.note" : "hifispeaker")
                }
                .help(audioManager.audioMode == .music ? "Music Mode" : "Speaker Mode")

                Button {
                    showEQ.toggle()
                } label: {
                    Image(systemName: "waveform")
                }
                .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
                .help("Equalizer")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .glassBackgroundEffect()
        .sheet(isPresented: $showEQ) {
            EQEditorView()
                .environment(audioManager)
        }
    }

    private var compactAudioStatusText: String {
        if let title = audioManager.nowPlaying?.title, !title.isEmpty {
            return title
        }
        switch audioManager.state {
        case .streaming: return "Audio Streaming"
        case .connecting: return "Connecting Audio…"
        case .error(let message): return message
        case .idle: return "Audio"
        }
    }

    // MARK: - Audio only (full mini player)

    private static let audioOnlyWidth: CGFloat = 400

    private var audioOnlyContent: some View {
        VStack(spacing: 0) {
            AudioPlayerPanel(width: Self.audioOnlyWidth)

            AudioVolumeRow()
                .padding(.horizontal, 28)
                .padding(.top, 22)

            audioUtilityRow
                .padding(.top, 22)
        }
        .frame(width: Self.audioOnlyWidth)
        .glassBackgroundEffect()
        .sheet(isPresented: $showEQ) {
            EQEditorView()
                .environment(audioManager)
        }
    }

    private var audioUtilityRow: some View {
        HStack(spacing: 28) {
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
            .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
            .help("Equalizer")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    // MARK: - Nothing enabled

    private var emptyContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Screen and Audio are both off")
                .font(.headline)
            Text("Turn one on below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassBackgroundEffect()
    }

    // MARK: - Controls ornament

    private func controls(screenOn: Binding<Bool>, audioOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
            }

            Toggle(isOn: screenOn) {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .toggleStyle(.button)

            Toggle(isOn: audioOn) {
                Label("Audio", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.button)

            Button {
                screenManager.forget()
                audioManager.userDisconnect()
                WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
                    dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
                }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
    }
}
#endif
