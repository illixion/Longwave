import SwiftUI

/// Shared mini-player UI for an active audio stream: large album art
/// (falling back to the speaker status glyph), the track title/artist
/// labels, and the prev / play-pause / next / mute transport row.
///
/// Used both by the standalone audio-stream window (`AudioStreamView`,
/// which wraps this with window-management chrome) and by the companion
/// popover surfaced from the remote desktop toolbar. Both observe the same
/// `AudioStreamManager`, so they stay in sync.
struct AudioPlayerPanel: View {
    @Environment(AudioStreamManager.self) private var audioManager

    /// Width of the panel; the album art is an edge-to-edge square of this
    /// size, iTunes-mini-player style.
    var width: CGFloat = 400

    /// Whether a local-output volume row is shown below the transport row.
    /// The standalone window hosts its own volume row, so it leaves this
    /// false; the companion popover enables it. Muting is folded into the
    /// volume slider (0 = muted), so there is no separate mute control.
    var showsVolume: Bool = false

    @State private var showTechInfo = false
    @State private var techInfoHideTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            artworkPane

            VStack(spacing: 2) {
                Text(primaryLine)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            transportRow
                .padding(.top, 14)

            if showsVolume {
                AudioVolumeRow()
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
            }
        }
        .frame(width: width)
    }

    // MARK: - Artwork

    /// Big square album art; when there is none (streaming-only Apple
    /// Music tracks expose no artwork via scripting) or nothing playing,
    /// shows the speaker status glyph instead. Tapping the art reveals
    /// technical stream info in the bottom-trailing corner, which
    /// auto-hides after a few seconds.
    private var artworkPane: some View {
        ZStack {
            if let artwork = audioManager.artworkImage {
                Image(platformImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.fill.tertiary)
                // `variableValue` 0 draws the wave bars empty (none
                // highlighted); the variableColor animation overrides it while
                // active. Without it the effect's resting state lights *every*
                // bar, so stopping looked like it froze fully-highlighted —
                // pinning to 0 makes it settle on the empty frame instead.
                Image(systemName: iconName, variableValue: isAudioActive ? 1 : 0)
                    .font(.system(size: 64))
                    .foregroundStyle(audioManager.state == .streaming ? Color.accentColor : .secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isAudioActive)
                    .animation(.easeInOut(duration: 0.35), value: isAudioActive)
            }
        }
        .frame(width: width, height: width)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleTechInfo)
        .overlay(alignment: .bottomTrailing) {
            if audioManager.state == .streaming, showTechInfo {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(audioManager.formatLabel)
                    Text(dataLabel)
                        .monospacedDigit()
                    if audioManager.lowLatencyRequested || audioManager.lowLatencyDegraded {
                        Text(audioManager.transportLabel)
                            .foregroundStyle(audioManager.lowLatencyDegraded ? .orange : .secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
    }

    /// Tap on the art: show the tech info and auto-hide it after a few
    /// seconds; tapping again while visible hides it immediately.
    private func toggleTechInfo() {
        techInfoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showTechInfo.toggle()
        }
        guard showTechInfo else { return }
        techInfoHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showTechInfo = false
            }
        }
    }

    // MARK: - Labels

    private var primaryLine: String {
        if let title = audioManager.nowPlaying?.title, !title.isEmpty {
            return title
        }
        return statusText
    }

    private var secondaryLine: String {
        if let artist = audioManager.nowPlaying?.artist, !artist.isEmpty {
            return artist
        }
        if case .error(let message) = audioManager.state {
            return message
        }
        return " " // keep layout height stable
    }

    // MARK: - Transport

    /// [prev] [play/pause] [next]
    private var transportRow: some View {
        HStack(spacing: 34) {
            Button {
                audioManager.sendCommand(.previous)
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!hasTransport)
            .help("Previous track")

            Button {
                audioManager.sendCommand(.toggle)
            } label: {
                Image(systemName: audioManager.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 48))
            }
            .disabled(!hasTransport)
            .help("Play / pause")

            Button {
                audioManager.sendCommand(.next)
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!hasTransport)
            .help("Next track")
        }
        .buttonStyle(.borderless)
        .font(.largeTitle)
    }

    private var hasTransport: Bool {
        audioManager.state == .streaming && audioManager.nowPlaying != nil
    }

    // MARK: - Status

    /// True only while real sound is arriving — gates the pulsing animation.
    /// The glyph and its accent tint stay put; only the `variableColor`
    /// motion toggles, so a streaming-but-silent stream (e.g. Music paused
    /// while another app plays) shows the same still, accent-tinted icon
    /// without the moving highlight and with no layout shift.
    private var isAudioActive: Bool {
        audioManager.state == .streaming && audioManager.isReceivingAudio
    }

    private var iconName: String {
        switch audioManager.state {
        case .streaming: "speaker.wave.3.fill"
        case .connecting: "speaker.wave.1"
        case .error: "speaker.slash"
        case .idle: "speaker"
        }
    }

    private var statusText: String {
        switch audioManager.state {
        case .idle: "Not Connected"
        case .connecting: "Connecting…"
        case .streaming: "Streaming"
        case .error: "Connection Lost"
        }
    }

    private var dataLabel: String {
        let mb = Double(audioManager.bytesReceived) / 1_048_576
        return String(format: "%.1f MB", mb)
    }
}

/// Local output-volume control for this device only — doesn't affect the
/// Mac or other listeners. Muting is folded into the slider: dragging to 0
/// engages the internal mute, raising it resumes (see
/// `AudioStreamManager.volume`). The flanking speaker glyphs are decorative
/// (the leading one switches to a slash at 0 to signal the muted state) and
/// symmetric so the Liquid Glass slider stays centered. Shared by the
/// standalone mini player and the remote-desktop companion popover so both
/// stay in sync on the same `AudioStreamManager`.
struct AudioVolumeRow: View {
    @Environment(AudioStreamManager.self) private var audioManager

    var body: some View {
        @Bindable var audioManager = audioManager
        return HStack(spacing: 16) {
            Image(systemName: audioManager.volume <= 0 ? "speaker.slash.fill" : "speaker.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Slider(value: $audioManager.volume, in: 0...1)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .font(.title3)
    }
}
