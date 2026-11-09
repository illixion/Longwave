#if FOVEATED_ENABLED && os(visionOS)
import SwiftData
import SwiftUI
import StreamWire

/// The PCVR tab's session panel in Native mode: presets, start and stop, pause,
/// what the PC settled on, the desktop and the game library. Everything here
/// goes through `PCVRNativeSession`, which doesn't care what draws the stream.
struct PCVRNativeSessionPanel: View {
    let connection: SavedConnection

    @Environment(PCVRNativeSession.self) private var session
    @Environment(PCVRShellSession.self) private var shell
    @Environment(FoveatedConnectionManager.self) private var manager
    @Query private var connections: [SavedConnection]
    @State private var showGameLibrary = false
    @State private var startError: String?

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 16) {
            if case .failed(let message) = session.state {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if let startError {
                Text(startError).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("Quality", selection: $session.quality) {
                    ForEach(PCVRQualityPreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $session.frameRate) {
                    ForEach(PCVRFrameRatePreset.offered, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Quality sets how many pixels the game renders. Match display follows the headset's refresh as visionOS changes it; Half display rate shows every frame for two refreshes (60 fps at 120 Hz, 45 at 90), easier on the PC with an even cadence. Never below 45 fps. Changes apply while you play; a new render size reaches a game when it next starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)

            if session.isActive {
                activeControls
            } else {
                Button {
                    Task { await start() }
                } label: {
                    Text("Start streaming").frame(maxWidth: 320).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                Text("Streams with Longwave's own protocol from the PC's Companion (choose Native in its PCVR panel).")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .sheet(isPresented: $showGameLibrary) {
            NavigationStack {
                FoveatedGameLibraryView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showGameLibrary = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var activeControls: some View {
        VStack(spacing: 6) {
            Text(stateLine).font(.headline)
            if let line = hostLine { Text(line).font(.callout).foregroundStyle(.secondary) }
            if let name = session.presenterName {
                Text("Presented with \(name)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        HStack(spacing: 12) {
            Button(session.state == .paused ? "Resume" : "Pause") {
                Task { session.state == .paused ? await session.resume() : await session.pause() }
            }
            .buttonStyle(.bordered)
            .disabled(session.state == .connecting)

            let shown = session.controllerBridge?.desktopQuadShown
            Button(shown == true ? "Hide desktop" : "Show desktop") {
                session.controllerBridge?.setDesktopQuad(!(shown ?? false))
            }
            .buttonStyle(.bordered)
            .disabled(shown == nil)

            Button("Games") { showGameLibrary = true }
                .buttonStyle(.bordered)
                .disabled(session.controllerBridge == nil)

            Button("Stop", role: .destructive) {
                Task { await session.stop() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var stateLine: String {
        switch session.state {
        case .idle: "Not streaming"
        case .connecting: "Connecting to the PC…"
        case .streaming: session.hostSession?.producer == .title ? "Playing" : "Streaming — start a game from Games or the PC"
        case .paused: "Paused"
        case .failed: "Stopped"
        }
    }

    private var hostLine: String? {
        guard let host = session.hostSession, host.renderEye.width > 0 else {
            return session.display.map { String(format: "Display %g Hz", $0.hertz) }
        }
        var parts = ["\(host.renderEye.width)×\(host.renderEye.height) per eye",
                     String(format: "%g fps", Double(host.streamMillihertz) / 1000)]
        if let display = session.display { parts.append(String(format: "display %g Hz", display.hertz)) }
        if host.flags.contains(.rateLimitedByHost) { parts.append("held back by the PC") }
        if host.flags.contains(.renderSizePending) { parts.append("new size with the next game") }
        return parts.joined(separator: " · ")
    }

    private func start() async {
        startError = nil
        do {
            let target = try PCVRNativeSession.target(pcvrHost: connection.hostname, connections: connections)
            await session.start(target: target, shell: shell, gameLibrary: manager.gameLibrary)
        } catch {
            startError = error.localizedDescription
        }
    }
}

extension PCVRQualityPreset {
    var label: String {
        switch self {
        case .performance: "Performance — 70%, the lightest"
        case .balanced: "Balanced — 85%"
        case .quality: "Quality — native density"
        case .maximum: "Maximum — 115%, supersampled"
        }
    }
}

extension PCVRFrameRatePreset {
    /// What the tab offers: fixed caps don't divide every display rate, so they'd judder.
    static let offered: [PCVRFrameRatePreset] = [.matchDisplay, .halfDisplay]

    var label: String {
        switch self {
        case .halfDisplay: "Half display rate"
        case .matchDisplay: "Match display"
        case .cap60: "At most 60 fps"
        case .cap72: "At most 72 fps"
        case .cap90: "At most 90 fps"
        case .cap120: "At most 120 fps"
        }
    }
}
#endif
