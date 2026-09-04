import RAVEConsole
import SwiftUI
import SwiftData
import AppKit

/// macOS app entry. The Mac already ships an SSH client, so this target keeps
/// the shared VNC, Moonlight, Native desktop stream, audio, console, and
/// soft-keyboard scenes without compiling the visionOS SSH/SwiftTerm feature set.
@main
struct LongwaveMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var macNativeManager = MacNativeStreamManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightSessions = MoonlightSessionStore()
    #endif
    // Host (companion) side: system-audio streaming + broadcast/OBS provisioning.
    @State private var companionController = AudioStreamerController()
    @State private var broadcastServer = BroadcastServerManager()

    var body: some Scene {
        // Value-typed with the shared constant identity so every
        // `openWindow(id: "main", value:)` reactivates this one window instead
        // of opening duplicates — matching visionOS. See `MainWindowID`.
        WindowGroup(id: "main", for: MainWindowID.self) { _ in
            MacMainView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(macNativeManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightSessions)
                #endif
                .frame(minWidth: 720, minHeight: 480)
                .task { connectionManager.audioManager = audioManager }
        } defaultValue: {
            .shared
        }
        .modelContainer(for: SavedConnection.self)

        // Menu-bar quick controls (stream toggle + now-playing title), reusing
        // the companion's popover. Always alive, so it also hosts the
        // "summon main window on reopen" bridge from MacAppDelegate.
        MenuBarExtra {
            MenuBarHostContent(controller: companionController, broadcastServer: broadcastServer)
        } label: {
            if companionController.isInjecting {
                Image(systemName: "keyboard.fill")
            } else if let track = companionController.menuBarTrackText {
                // Already carries the ♪ and is pre-trimmed to the room the menu
                // bar has — the label can't constrain its own width, so the
                // string is what has to be the right length.
                Text(track)
            } else {
                Image(systemName: companionController.isRunning ? "speaker.wave.2.fill" : "speaker.slash")
            }
        }
        .menuBarExtraStyle(.window)

        // Single Settings window (Cmd-,): client defaults + all host config.
        Settings {
            MacSettingsView(controller: companionController, broadcastServer: broadcastServer)
        }

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

        // The Native (desktop stream + audio) window — value-typed with one
        // constant identity like on visionOS, so a connection reactivates the
        // one window. Per-window Unity scenes stay visionOS-only.
        WindowGroup("Native", id: "mac-native-stream", for: MacNativeWindowID.self) { _ in
            MacNativeStreamWindowView()
                .environment(macNativeManager)
                .environment(audioManager)
                .trackWindowSession(id: "mac-native-stream")
        } defaultValue: {
            .shared
        }
        .defaultSize(width: 1440, height: 900)

        WindowGroup("Native Keyboard", id: "mac-native-keyboard") {
            MacNativeKeyboardView()
                .environment(macNativeManager)
                .trackWindowSession(id: "mac-native-keyboard")
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

/// MenuBarExtra content: the companion's quick-controls popover plus the bridge
/// that turns `MacAppDelegate.summonMainWindow` into an `openWindow("main")`.
/// This view is always instantiated (the status item is permanent), so it works
/// even when the app is running headless with no other windows.
private struct MenuBarHostContent: View {
    @Bindable var controller: AudioStreamerController
    @Bindable var broadcastServer: BroadcastServerManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        CompanionMenuView(
            controller: controller,
            broadcastServer: broadcastServer,
            openMainAction: { openWindow(id: "main", value: MainWindowID.shared) }
        )
        .onReceive(NotificationCenter.default.publisher(for: MacAppDelegate.summonMainWindow)) { _ in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main", value: MainWindowID.shared)
        }
    }
}
