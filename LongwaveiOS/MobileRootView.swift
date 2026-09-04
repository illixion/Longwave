import SwiftUI

/// The tab shell. Stands in for both the visionOS `MainView` ornament tab bar and
/// the pop-out windows around it.
///
/// Presentation is driven off manager state, not off the button that was pressed.
/// Shared views (`ConnectionListView`, `ProjectsView`) still ask for a window with
/// `openWindow(id:)`, which does nothing in a single-scene app — so instead this
/// view watches for a VNC connection going active and for new SSH sessions
/// appearing, and covers the screen accordingly. Any shared view that starts a
/// session gets the right surface without being modified.
struct MobileRootView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(SSHTerminalManager.self) private var sshManager
    @Environment(MacNativeStreamManager.self) private var macNativeManager
    #if MOONLIGHT_ENABLED
    @Environment(MoonlightSessionStore.self) private var moonlightSessions
    #endif

    @State private var selectedTab: MobileTab = .connections
    @State private var showingDesktop = false
    @State private var showingNativeScreen = false
    @State private var presentedSession: SSHSessionID?
    #if MOONLIGHT_ENABLED
    /// The Moonlight session whose stream fills the screen. One at a time here:
    /// a phone has one screen, so the store's "up to three streams" becomes
    /// "whichever one is launching or streaming".
    @State private var presentedMoonlightSession: MoonlightSessionID?
    #endif
    /// Session ids already seen, so only a genuinely new session raises a
    /// terminal. Re-entering an existing one goes through the Terminals tab.
    @State private var knownSessions: Set<String> = []

    /// Five, deliberately. iOS collapses a sixth tab into a "More" list, and the
    /// visionOS tab bar's Console (an in-app log viewer) is the one that earns
    /// being cut: it exists because a headset cannot be tethered to Xcode, and a
    /// phone can. Broadcast and PCVR are absent from this target entirely.
    enum MobileTab: Hashable {
        case connections, projects, terminals, audio, settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Connections", systemImage: "rectangle.connected.to.line.below", value: .connections) {
                ConnectionListView()
            }
            Tab("Projects", systemImage: "sparkles", value: .projects) {
                ProjectsView()
            }
            Tab("Terminals", systemImage: "terminal", value: .terminals) {
                MobileTerminalsView(presentedSession: $presentedSession)
            }
            Tab("Audio", systemImage: "hifispeaker", value: .audio) {
                MobileAudioView()
            }
            Tab("Settings", systemImage: "gear", value: .settings) {
                SettingsView()
            }
        }
        // A VNC session takes the whole screen: a remote desktop shrunk into a
        // tab with a tab bar over it is unusable on a phone.
        .fullScreenCover(isPresented: $showingDesktop) {
            MobileRemoteDesktopView()
        }
        .fullScreenCover(item: $presentedSession) { id in
            MobileTerminalCover(sessionID: id)
        }
        // The Native desktop stream, like VNC, fills the screen. Driven off the
        // manager: `ConnectionListView` connects it and opens a window that
        // doesn't exist here. Audio-only Native connections never connect the
        // screen manager, so they stay in the Audio tab.
        .fullScreenCover(isPresented: $showingNativeScreen) {
            MobileNativeStreamView()
        }
        .onChange(of: macNativeManager.isEnabled) { _, enabled in
            if enabled {
                showingNativeScreen = true
            } else if showingNativeScreen {
                // Leave the stream up briefly so its own error state is
                // readable before the cover drops.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !macNativeManager.isEnabled {
                        showingNativeScreen = false
                    }
                }
            }
        }
        #if MOONLIGHT_ENABLED
        .fullScreenCover(item: $presentedMoonlightSession) { id in
            MobileMoonlightStreamView()
                .environment(moonlightSessions.session(for: id))
        }
        .onChange(of: moonlightSessions.activeSession?.slot) { _, slot in
            // The pairing sheet launched an app (or a dropped stream came back):
            // its `openWindow("moonlight-stream")` is a no-op here, so the cover
            // is driven off the session state instead, like the VNC desktop.
            if let slot {
                presentedMoonlightSession = MoonlightSessionID(slot: slot)
            } else if presentedMoonlightSession != nil {
                // Leave the stream up briefly so its own error state is
                // readable before the cover drops.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if moonlightSessions.activeSession == nil {
                        presentedMoonlightSession = nil
                    }
                }
            }
        }
        #endif
        .onChange(of: connectionManager.connectionState) { _, state in
            if state.isActive {
                showingDesktop = true
            } else if case .disconnected = state {
                // Leave the desktop up briefly so its own error state is
                // readable before the cover drops.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !connectionManager.connectionState.isActive {
                        showingDesktop = false
                    }
                }
            } else {
                showingDesktop = false
            }
        }
        .onChange(of: sshManager.sessions.map(\.id.raw)) { _, ids in
            let fresh = ids.filter { !knownSessions.contains($0) }
            knownSessions = Set(ids)
            // A new session means someone just asked for a terminal — show it.
            if let newest = fresh.last {
                presentedSession = SSHSessionID(raw: newest)
            }
        }
        .onAppear {
            knownSessions = Set(sshManager.sessions.map(\.id.raw))
        }
        .onOpenURL { url in
            // AirDropped pairing URLs from the macOS Companion. Broadcast setup
            // is not handled here — this target has no Broadcast tab.
            if let token = AudioTokenURL.parseToken(from: url) {
                selectedTab = .connections
                audioManager.importToken(token)
            }
        }
    }
}

/// Lists live SSH sessions so one can be re-entered after its cover is dismissed.
/// On visionOS these are separate windows you summon from the Sessions tab; here
/// the session outlives the screen it was shown on (tmux-backed, as before) and
/// this is how you get back to it.
private struct MobileTerminalsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    @Binding var presentedSession: SSHSessionID?

    var body: some View {
        NavigationStack {
            Group {
                if sshManager.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Terminals",
                        systemImage: "terminal",
                        description: Text("Open an SSH connection or a project to start a session.")
                    )
                } else {
                    List(sshManager.sessions) { session in
                        Button {
                            presentedSession = session.id
                        } label: {
                            sessionRow(session)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                sshManager.stopSession(session.id)
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Terminals")
        }
    }

    private func sessionRow(_ session: SSHSession) -> some View {
        HStack {
            Image(systemName: session.kind == .claude ? "sparkles" : "terminal")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.headline)
                Text("\(session.username)@\(session.host):\(session.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(stateLabel(session.state))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func stateLabel(_ state: SSHSession.State) -> String {
        switch state {
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .failed: "Failed"
        case .closed: "Closed"
        }
    }
}

/// Wraps the shared terminal view with a way out, since it was written for a
/// window that had a system close button.
private struct MobileTerminalCover: View {
    let sessionID: SSHSessionID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SSHTerminalView(sessionID: sessionID)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
