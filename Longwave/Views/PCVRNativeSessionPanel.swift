#if FOVEATED_ENABLED && os(visionOS)
import SwiftData
import SwiftUI
import RAVECompanion
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
                    ForEach(PCVRFrameRatePreset.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Microphone to PC", isOn: $session.microphoneEnabled)
                Text(microphoneLine)
                    .font(.caption).foregroundStyle(session.microphoneMessage == nil ? Color.secondary : Color.red)
                if session.availableChoices.count > 1 {
                    Picker("Renderer", selection: $session.presenterChoice) {
                        ForEach(session.availableChoices) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.state == .connecting)
                    Text("Eye-tracked lets the PC sharpen where you look. Low latency uses Longwave's own renderer, with sharpness fixed at the centre of view. Switching while you play restarts the picture; the game keeps running.")
                        .font(.caption).foregroundStyle(.secondary)
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

    private var microphoneLine: String {
        if let message = session.microphoneMessage { return message }
        guard session.microphoneEnabled else { return "Games on the PC don't hear you." }
        switch session.microphoneTakenByPC {
        case true?: return "Your voice plays into the PC's virtual cable: choose its microphone (\u{201C}Line 1\u{201D}) in the game, or make it Windows' default recording device."
        case false?: return "The PC has no virtual audio cable to play your voice into, so games can't hear you. Install one (Virtual Audio Cable or VB-CABLE) and restart the stream."
        case nil: return "Your voice goes to the PC while you stream, into its virtual audio cable for games to use as a microphone."
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
            let target = try PCVRNativeSession.target(
                pcvrHost: connection.hostname, connections: connections,
                windowsHostIDs: Set(CompanionLocator.shared.nearby.filter(\.isWindows).map(\.macID)))
            await session.start(target: target, shell: shell, gameLibrary: manager.gameLibrary)
        } catch {
            startError = error.localizedDescription
        }
    }
}

#endif
