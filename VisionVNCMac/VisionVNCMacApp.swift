import SwiftUI
import SwiftData
import AppKit

/// macOS app entry. Mirrors the visionOS `VisionVNCApp` scene set (minus the
/// Broadcast windows): a main window plus separate windows for console, audio,
/// SSH terminals, the VNC desktop, the Moonlight stream, and the soft keyboards.
/// `openWindow`/`dismissWindow` drive them, exactly as on visionOS.
@main
struct VisionVNCMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var sshManager = SSHTerminalManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightManager = MoonlightConnectionManager()
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
                .environment(sshManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightManager)
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
                Text("\(track) ♪")
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
            ConsoleView(isPopout: true)
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

        WindowGroup("Terminal", id: "ssh-terminal", for: SSHSessionID.self) { $sessionID in
            if let sessionID {
                SSHTerminalView(sessionID: sessionID)
                    .environment(sshManager)
                    .trackWindowSession(id: "ssh-terminal")
            }
        }
        .defaultSize(width: 900, height: 640)

        WindowGroup("Terminal Keyboard", id: "ssh-keyboard", for: SSHSessionID.self) { $sessionID in
            if let sessionID {
                SSHKeyboardView(sessionID: sessionID)
                    .environment(sshManager)
                    .trackWindowSession(id: "ssh-keyboard")
            }
        }
        .defaultSize(width: 800, height: 640)

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

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Stream", id: "moonlight-stream") {
            MacMoonlightStreamView()
                .environment(moonlightManager)
                .trackWindowSession(id: "moonlight-stream")
        }
        .defaultSize(width: 1920, height: 1080)

        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard") {
            MoonlightKeyboardView()
                .environment(moonlightManager)
                .trackWindowSession(id: "moonlight-keyboard")
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
