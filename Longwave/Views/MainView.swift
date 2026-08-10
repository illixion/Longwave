import RAVEUI
import SwiftUI

/// Root of the main window: Connections / Settings / Console tabs,
/// switched by a bottom ornament tab bar (matches the app's ornament idiom;
/// each tab keeps its own NavigationStack for visionOS navigation titles).
struct MainView: View {

    enum Tab: String, CaseIterable, RAVETabItem {
        case connections = "Connections"
        #if FOVEATED_ENABLED
        /// Second, not buried: PCVR is a headline feature, and it is the one
        /// thing here that finds its own host instead of taking an address.
        case pcvr = "PCVR"
        #endif
        case projects = "Projects"
        case sessions = "Sessions"
        case broadcast = "Broadcast"
        case console = "Console"
        case settings = "Settings"

        var systemImage: String {
            switch self {
            case .connections: "rectangle.connected.to.line.below"
            #if FOVEATED_ENABLED
            case .pcvr: "visionpro"
            #endif
            case .projects: "sparkles"
            case .sessions: "macwindow.on.rectangle"
            case .broadcast: "dot.radiowaves.left.and.right"
            case .settings: "gear"
            case .console: "terminal"
            }
        }
    }

    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(BroadcastManager.self) private var broadcastManager
    @State private var selectedTab: Tab = .connections

    var body: some View {
        Group {
            switch selectedTab {
            case .connections:
                ConnectionListView()
            #if FOVEATED_ENABLED
            case .pcvr:
                PCVRTabView()
            #endif
            case .projects:
                ProjectsView()
            case .sessions:
                SessionsView()
            case .broadcast:
                BroadcastView()
            case .settings:
                SettingsView()
            case .console:
                ConsoleTabView()
            }
        }
        .onOpenURL { url in
            // AirDropped pairing URLs from the macOS companion.
            if let token = AudioTokenURL.parseToken(from: url) {
                // setAudioToken: stash the token and surface the Connections
                // tab so the form can auto-fill it.
                selectedTab = .connections
                audioManager.importToken(token)
            } else if let setup = BroadcastSetupURL.parse(from: url) {
                // setBroadcastServer: fill the Broadcast tab's server config.
                selectedTab = .broadcast
                broadcastManager.importSetup(setup)
            }
        }
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .top) {
            MainTabBar(selectedTab: $selectedTab)
        }
    }
}
