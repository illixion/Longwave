import SwiftUI
import SwiftData
#if FOVEATED_ENABLED && !targetEnvironment(simulator)
import FoveatedStreaming
#endif

@main
struct VisionVNCApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var macNativeManager = MacNativeStreamManager()
    @State private var sshManager = SSHTerminalManager()
    @State private var broadcastManager = BroadcastManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightManager = MoonlightConnectionManager()
    #endif
    #if FOVEATED_ENABLED
    @State private var foveatedManager = FoveatedConnectionManager()
    #endif

    var body: some Scene {
        // Value-typed with a single constant identity (`MainWindowID.shared`)
        // so every `openWindow(id: "main", value:)` reactivates this one window
        // rather than minting duplicates. See `MainWindowID`.
        WindowGroup(id: "main", for: MainWindowID.self) { _ in
            MainView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(macNativeManager)
                .environment(sshManager)
                .environment(broadcastManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightManager)
                #endif
                .trackMainWindow()
                #if FOVEATED_ENABLED
                .environment(foveatedManager)
                #endif
                .task {
                    // Let the VNC manager drive a companion audio stream in
                    // lockstep with its connection lifecycle.
                    connectionManager.audioManager = audioManager
                }
        } defaultValue: {
            .shared
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Console", id: "console") {
            ConsoleView(isPopout: true)
                .homeOrnament()
                .trackWindowSession(id: "console")
        }
        .defaultSize(width: 760, height: 480)
        .defaultLaunchBehavior(.suppressed)

        // Popped out of the unified Native window by its pop-out button
        // (`NativeStreamView`); stays a separate window for as long as it's
        // open, tracked live via `WindowSessionRegistry` so the Native
        // window knows to hide its own inline audio UI meanwhile.
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

        WindowGroup("Terminal Keyboard", id: "ssh-keyboard", for: SSHSessionID.self) { $sessionID in
            if let sessionID {
                SSHKeyboardView(sessionID: sessionID)
                    .homeOrnament()
                    .environment(sshManager)
                    .trackWindowSession(id: "ssh-keyboard")
            }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentSize)
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

        WindowGroup(
            "Native",
            id: "mac-native-stream",
            for: MacNativeWindowID.self
        ) { _ in
            NativeStreamView()
                .environment(macNativeManager)
                .environment(audioManager)
                .trackWindowSession(id: "mac-native-stream")
        } defaultValue: {
            .shared
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        // Unity-style per-window streams: one chrome-free scene per streamed
        // host window, keyed by the host window ID. No ornament by design —
        // the scene is just the remote window's pixels; control lives in the
        // Native controller window above.
        WindowGroup(
            "Mac Window",
            id: "mac-native-window",
            for: MacNativeWindowStreamID.self
        ) { $streamID in
            if let streamID {
                NativeWindowStreamView(windowID: streamID.windowID)
                    .environment(macNativeManager)
            }
        }
        .defaultSize(width: 960, height: 720)
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
        .defaultSize(width: 1180, height: 540)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        #if MOONLIGHT_ENABLED
        WindowGroup("Moonlight Keyboard", id: "moonlight-keyboard") {
            MoonlightKeyboardView()
                .homeOrnament()
                .environment(moonlightManager)
                .trackWindowSession(id: "moonlight-keyboard")
        }
        .defaultSize(width: 1180, height: 540)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        #endif

        #if FOVEATED_ENABLED
        // Value-matched to a single identity (`PCVRWindowID.shared`), like the main
        // window, so the three places that surface it reactivate the one panel instead
        // of stacking copies. Open it through `WindowSessionRegistry.surface(_:using:)`.
        WindowGroup("PCVR", id: "foveated-controls", for: PCVRWindowID.self) { _ in
            FoveatedControlWindowView()
                .environment(foveatedManager)
        }
        .defaultSize(width: 480, height: 520)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // The streamed immersive content. On device this binds to the session
        // so the system composites the foveated video; on the simulator the
        // framework is absent, so a plain immersive space hosts the overlay
        // widgets only (no video — the mock session can't stream).
        #if targetEnvironment(simulator)
        ImmersiveSpace(id: "foveated-immersive") {
            FoveatedImmersiveView()
                .environment(foveatedManager)
                .persistentSystemOverlays(.hidden)
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
        .upperLimbVisibility(.hidden)
        #else
        // Hide the passthrough hands/arms: PCVR titles render their own avatar hands
        // from the bridge's tracking, and the system compositing the real ones on top
        // shows two misaligned pairs at once.
        ImmersiveSpace(foveatedStreaming: foveatedManager.session) {
            FoveatedImmersiveView()
                .environment(foveatedManager)
                // Hide the Home indicator. It is summoned by raising a palm and looking
                // at it, which is precisely the wrist HUD's gesture — leave it on and the
                // two fight over the same intent.
                .persistentSystemOverlays(.hidden)
        }
        .immersionStyle(selection: .constant(.progressive), in: .progressive)
        .upperLimbVisibility(.hidden)
        #endif
        #endif
    }
}
