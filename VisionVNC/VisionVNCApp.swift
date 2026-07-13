import SwiftUI
import SwiftData

@main
struct VisionVNCApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var sshManager = SSHTerminalManager()
    @State private var broadcastManager = BroadcastManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightManager = MoonlightConnectionManager()
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(sshManager)
                .environment(broadcastManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightManager)
                #endif
                .trackMainWindow()
                .task {
                    // Let the VNC manager drive a companion audio stream in
                    // lockstep with its connection lifecycle.
                    connectionManager.audioManager = audioManager
                }
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Console", id: "console") {
            ConsoleView(isPopout: true)
                .homeOrnament()
                .trackWindowSession(id: "console")
        }
        .defaultSize(width: 760, height: 480)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Audio Stream", id: "audio-stream") {
            AudioStreamView()
                .environment(audioManager)
                .trackWindowSession(id: "audio-stream")
        }
        .defaultSize(width: 400, height: 600)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Terminal", id: "ssh-terminal", for: SSHSessionID.self) { $sessionID in
            if let sessionID {
                SSHTerminalView(sessionID: sessionID)
                    .homeOrnament()
                    .environment(sshManager)
                    .trackWindowSession(id: "ssh-terminal")
            }
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup("Remote Desktop", id: "remote-desktop") {
            RemoteDesktopView()
                .environment(connectionManager)
                .environment(audioManager)
                .trackWindowSession(id: "remote-desktop")
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Stream", id: "moonlight-stream") {
            MoonlightStreamView()
                .environment(moonlightManager)
                .trackWindowSession(id: "moonlight-stream")
        }
        .defaultSize(width: 1920, height: 1080)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        #endif

        WindowGroup("Keyboard", id: "keyboard") {
            KeyboardInputView()
                .homeOrnament()
                .environment(connectionManager)
                .trackWindowSession(id: "keyboard")
        }
        .defaultSize(width: 500, height: 400)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard") {
            MoonlightKeyboardView()
                .homeOrnament()
                .environment(moonlightManager)
                .trackWindowSession(id: "moonlight-keyboard")
        }
        .defaultSize(width: 500, height: 450)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        #endif
    }
}
