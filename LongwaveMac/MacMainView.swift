import RAVEConsole
import SwiftUI

/// Root of the macOS main window: a sidebar (`NavigationSplitView`) replacing
/// the visionOS bottom ornament tab bar. Broadcast is omitted (no Vision Pro
/// cameras), and so is the embedded SSH terminal: Projects runs agents in the
/// local sandbox account and attaches them in Terminal.app.
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
    @State private var selectedTab: Tab? = .connections

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
            case .projects:    MacProjectsView()
            case .console:     RAVEConsoleScreen()
            }
        }
        .onOpenURL { url in
            // AirDropped audio pairing URLs from the macOS companion.
            if let token = AudioTokenURL.parseToken(from: url) {
                selectedTab = .connections
                audioManager.importToken(token)
            }
        }
    }
}
