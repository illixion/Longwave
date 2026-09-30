import RAVEConsole
import SwiftUI
import SwiftData
import DebugTraceServer
import AppKit

/// macOS app entry. The Mac already ships a terminal, so this target keeps the
/// shared VNC, Moonlight, Native desktop stream, audio, console, and
/// soft-keyboard scenes without the visionOS SwiftTerm terminal; its Projects
/// tab drives agents in the local sandbox account and attaches in Terminal.app.
@main
struct LongwaveMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var macNativeSessions = MacNativeSessionStore()
    #if MOONLIGHT_ENABLED
    @State private var moonlightSessions = MoonlightSessionStore()
    #endif
    // Host (companion) side: system-audio streaming + broadcast/OBS provisioning.
    @State private var companionController = AudioStreamerController()
    @State private var broadcastServer = BroadcastServerManager()
    // Projects: the local agent sandbox (scripts/agent-sandbox) and the
    // scheduler that fires recurring headless runs into it while the app runs.
    @State private var sandbox: LocalSandboxController
    @State private var scheduler: LocalScheduler

    init() {
        AppLog.configureDebugTrace()
        DebugTraceServer.startIfRequested()
        let sandbox = LocalSandboxController()
        let scheduler = LocalScheduler(sandbox: sandbox)
        _sandbox = State(initialValue: sandbox)
        _scheduler = State(initialValue: scheduler)
        // Started here, not from a window's .task: schedules must keep firing
        // when the main window is closed (the menu-bar extra keeps the app up).
        scheduler.start()
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
                .environment(sandbox)
                .environment(scheduler)
                #if MOONLIGHT_ENABLED
                .environment(moonlightSessions)
                #endif
                .frame(minWidth: 720, minHeight: 480)
                .task { connectionManager.audioManager = audioManager }
                // Keep the sandbox agent's desktop session alive (visionOS
                // simulators need one). A no-op when the sandbox isn't installed.
                .task { await sandbox.ensureDesktopSession() }
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
        // Needs its own `.modelContainer` — `SettingsView`'s Backup section
        // reads `modelContext`, and a Scene's container doesn't span other
        // Scenes, only the one it's attached to (see the "main" WindowGroup
        // above). Same underlying SwiftData store either way.
        Settings {
            MacSettingsView(controller: companionController, broadcastServer: broadcastServer)
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
