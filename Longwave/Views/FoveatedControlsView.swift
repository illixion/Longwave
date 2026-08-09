//  FoveatedControlsView.swift
//
//  In-session controls for an active PCVR foveated stream: pause/resume and
//  disconnect, plus a live status line. The immersive space (the actual video)
//  is opened/closed automatically by the session's presentation behaviors.
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

struct FoveatedControlsView: View {
    /// Embedded in the PCVR tab's form rather than standing alone in the controls
    /// window: drop the card's own padding and width cap and let the row supply them.
    var embedded = false

    @Environment(FoveatedConnectionManager.self) private var manager
    @State private var showGameLibrary = false

    private var isPaused: Bool {
        if case .paused = manager.status { return true }
        return false
    }

    private var isBusy: Bool {
        switch manager.status {
        case .pausing, .resuming, .disconnecting: true
        default: false
        }
    }

    /// Show the PC's own screen on a panel in the home view.
    ///
    /// The state comes from the host, not from what we last asked for: the desktop
    /// companion has the same switch, and a button that reported only its own last press
    /// would sit there lying whenever the PC disagreed. Until the first telemetry lands
    /// there is nothing truthful to show, so it stays disabled rather than guessing.
    @ViewBuilder
    private var desktopPanelButton: some View {
        let shown = manager.controllerBridge?.desktopQuadShown
        Button {
            manager.controllerBridge?.setDesktopQuad(!(shown ?? false))
        } label: {
            Label(shown == true ? "Hide desktop" : "Show desktop",
                  systemImage: shown == true ? "display.trianglebadge.exclamationmark" : "display")
                .frame(minWidth: 120)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(shown == true ? .accentColor : nil)
        .disabled(shown == nil)
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                // The tab already leads with this icon at hero size; a second one a
                // few points below it just looks like a mistake.
                if !embedded {
                    Image(systemName: "visionpro")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                }
                Text(statusText)
                    .font(.title3).fontWeight(.semibold)
                if let bridge = manager.controllerBridge, bridge.isRunning {
                    Label("Controller bridge active", systemImage: "gamecontroller.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The library rides the bridge's data channel, so it only exists when
            // the bridge does. Without it there is nothing to launch games with.
            if manager.controllerBridge != nil {
                // Above Games/Quit, not below: those two are a pair about the running
                // title, and burying the desktop under them read as a footnote to a
                // question nobody asked. It belongs with "what am I looking at".
                desktopPanelButton

                HStack(spacing: 28) {
                    Button {
                        showGameLibrary = true
                    } label: {
                        Label("Games", systemImage: "square.grid.2x2.fill")
                            .frame(minWidth: 120)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)

                    // Beside Games on purpose: launching and quitting a title are the pair,
                    // and this is the second way to reach it. The wrist HUD's copy needs a
                    // palm raised in-session, which is no use if you have already looked away
                    // from the game — or if the title has no exit of its own and the HUD is
                    // what you are trying to get out of.
                    FoveatedQuitTitleButton(bridge: manager.controllerBridge, wide: true)
                }
            }

            HStack(spacing: 28) {
                Button {
                    Task { isPaused ? await manager.resume() : await manager.pause() }
                } label: {
                    Label(isPaused ? "Resume" : "Pause",
                          systemImage: isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 120)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                // No `role: .destructive`: on visionOS that tints the *label* red, and with a
                // red-tinted prominent background it came out red-on-red. The filled red
                // already carries the warning — the role only repeated it, illegibly.
                Button {
                    Task { await manager.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isBusy && manager.status != .pausing)
            }
        }
        .padding(embedded ? 0 : 28)
        .frame(maxWidth: embedded ? .infinity : 460)
        .sheet(isPresented: $showGameLibrary) {
            NavigationStack {
                FoveatedGameLibraryView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showGameLibrary = false }
                        }
                    }
            }
            // Wide enough for four columns of box art; tall enough that the second
            // row is visible without scrolling, which is what makes it read as a
            // shelf.
            .frame(minWidth: 760, minHeight: 620)
        }
    }

    private var statusText: String {
        switch manager.status {
        case .connected: "Streaming"
        case .paused: "Paused"
        case .pausing: "Pausing…"
        case .resuming: "Resuming…"
        case .disconnecting: "Disconnecting…"
        default: manager.status.description
        }
    }
}
#endif
