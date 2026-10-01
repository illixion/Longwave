import RAVEConsole
import SwiftUI
import SwiftData
import DebugTraceServer
import AppKit

/// macOS app entry: the client half only — VNC, Moonlight, Native desktop
/// stream, audio, console and soft-keyboard scenes, without the visionOS
/// SwiftTerm terminal (the Mac already ships one). Everything host-side —
/// streaming this Mac, the agent sandbox, schedules — is Longwave Companion's,
/// a separate process; this app only shows the sandbox desktop when asked.
@main
struct LongwaveMacApp: App {
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var macNativeSessions = MacNativeSessionStore()
    #if MOONLIGHT_ENABLED
    @State private var moonlightSessions = MoonlightSessionStore()
    #endif

    init() {
        AppLog.configureDebugTrace()
        DebugTraceServer.startIfRequested()
    }

    var body: some Scene {
        // Value-typed with the shared constant identity so every
        // `openWindow(id: "main", value:)` reactivates this one window instead
        // of opening duplicates — matching visionOS. See `MainWindowID`.
        WindowGroup(id: "main", for: MainWindowID.self) { _ in
            MacMainView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(macNativeSessions)
                #if MOONLIGHT_ENABLED
                .environment(moonlightSessions)
                #endif
                .frame(minWidth: 720, minHeight: 480)
                .task { connectionManager.audioManager = audioManager }
        } defaultValue: {
            .shared
        }
        .modelContainer(for: SavedConnection.self)

        // Cmd-, : the client's new-connection defaults. Needs its own
        // `.modelContainer` — `SettingsView`'s Backup section reads
        // `modelContext`, and a Scene's container doesn't span other Scenes.
        Settings {
            SettingsView()
                .formStyle(.grouped)
                .frame(width: 560, height: 520)
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Console", id: "console") {
            RAVEConsoleScreen()
                .trackWindowSession(id: "console")
        }
        .defaultSize(width: 760, height: 480)

        WindowGroup("Audio Stream", id: "audio-stream") {
            AudioStreamView()
                .environment(audioManager)
                .trackWindowSession(id: "audio-stream")
        }
        .defaultSize(width: 400, height: 600)
        .windowResizability(.contentSize)

        WindowGroup("Remote Desktop", id: "remote-desktop") {
            MacRemoteDesktopView()
                .environment(connectionManager)
                .environment(audioManager)
                .trackWindowSession(id: "remote-desktop")
        }
        .defaultSize(width: 1280, height: 800)

        WindowGroup("Keyboard", id: "keyboard") {
            KeyboardInputView()
                .environment(connectionManager)
                .trackWindowSession(id: "keyboard")
        }
        .defaultSize(width: 800, height: 440)

        // The Native (desktop stream + audio) window — one per session like on
        // visionOS, keyed by the connection, so a second host opens its own
        // window instead of taking this one. Per-window Unity scenes stay
        // visionOS-only.
        WindowGroup("Native", id: "mac-native-stream", for: MacNativeSessionID.self) { $sessionID in
            if let sessionID {
                MacNativeStreamWindowView(sessionID: sessionID)
                    .environment(macNativeSessions.session(for: sessionID))
                    .environment(macNativeSessions)
                    // This session's own audio player, not the app's shared
                    // one — see `MacNativeSessionStore.audioPlayer(for:)`.
                    .environment(macNativeSessions.audioPlayer(for: sessionID))
                    .trackWindowSession(id: "mac-native-stream", instance: sessionID.registryInstance)
            }
        }
        .defaultSize(width: 1440, height: 900)

        WindowGroup("Native Keyboard", id: "mac-native-keyboard", for: MacNativeSessionID.self) { $sessionID in
            if let sessionID {
                MacNativeKeyboardView()
                    .environment(macNativeSessions.session(for: sessionID))
                    .trackWindowSession(id: "mac-native-keyboard", instance: sessionID.registryInstance)
            }
        }
        .defaultSize(width: 800, height: 440)

        #if MOONLIGHT_ENABLED
        // One window per Moonlight session — see `MoonlightSessionStore`.
        WindowGroup("Moonlight Stream", id: "moonlight-stream", for: MoonlightSessionID.self) { $sessionID in
            if let sessionID {
                MacMoonlightStreamView()
                    .environment(moonlightSessions.session(for: sessionID))
                    .environment(moonlightSessions)
                    .trackWindowSession(id: "moonlight-stream")
            }
        }
        .defaultSize(width: 1920, height: 1080)

        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard", for: MoonlightSessionID.self) { $sessionID in
            if let sessionID {
                MoonlightKeyboardView()
                    .environment(moonlightSessions.session(for: sessionID))
                    .trackWindowSession(id: "moonlight-keyboard")
            }
        }
        .defaultSize(width: 800, height: 440)
        #endif
    }
}
