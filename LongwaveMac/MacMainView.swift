import RAVEConsole
import SwiftUI

/// Root of the macOS main window: a sidebar (`NavigationSplitView`) replacing
/// the visionOS bottom ornament tab bar. Broadcast is omitted (no Vision Pro
/// cameras), and so is the embedded SSH terminal. Projects lives in Longwave
/// Companion (the agent sandbox is host-side); this app only shows the sandbox
/// desktop when the Companion asks.
struct MacMainView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case sessions = "Sessions"
        case projects = "Projects"
        case console = "Console"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .connections: "rectangle.connected.to.line.below"
            case .sessions: "macwindow.on.rectangle"
            case .projects: "sparkles"
            case .console: "terminal"
            }
        }
    }

    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(VNCConnectionManager.self) private var vnc
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: Tab? = .connections
    @State private var desktopError: String?

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .navigationTitle("Longwave")
        } detail: {
            switch selectedTab ?? .connections {
            case .connections: ConnectionListView()
            case .sessions:    SessionsView()
            case .projects:    MacProjectsPointerView()
            case .console:     RAVEConsoleScreen()
            }
        }
        .onOpenURL { url in
            // AirDropped audio pairing URLs from the macOS companion.
            if let token = AudioTokenURL.parseToken(from: url) {
                selectedTab = .connections
                audioManager.importToken(token)
            } else if url.absoluteString == LocalSandbox.desktopURL {
                Task { await openSandboxDesktop() }
            }
        }
        .alert("Can't show the sandbox desktop", isPresented: Binding(
            get: { desktopError != nil }, set: { if !$0 { desktopError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(desktopError ?? "")
        }
    }

    /// The Companion's "Sandbox Desktop": the agent's desktop over loopback
    /// Screen Sharing. The password comes from the item install.sh wrote to the
    /// login keychain and goes straight to the connection; it's never saved.
    private func openSandboxDesktop() async {
        let user = LocalSandbox.defaultAgentUser
        guard let password = await Task.detached(operation: { LocalSandbox.readAgentPassword(account: user) }).value else {
            desktopError = "The sandbox password isn't in your login keychain (\(LocalSandbox.keychainService)), or access was denied."
            return
        }
        vnc.connect(hostname: LocalSandbox.host, port: LocalSandbox.vncPort,
                    username: user, password: password, title: "Sandbox Desktop")
        openWindow(id: "remote-desktop")
    }
}
