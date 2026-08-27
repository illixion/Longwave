import SwiftUI
import SwiftData
#if FOVEATED_ENABLED && !targetEnvironment(simulator)
import FoveatedStreaming
#endif

@main
struct LongwaveApp: App {
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
    @State private var pcvrStore = PCVRStore()
    @State private var pcvrLimiter = PCVRSessionLimiter()
    @State private var pcvrBandwidth = PCVRBandwidthMonitor()

    /// Bridges the manager's style to the scene's existential binding.
    ///
    /// One-way, with the setter deliberately empty. SwiftUI writes back through this
    /// as a space opens and closes, and those writes carry transitional and stale
    /// values: recording them and preferring them over our own left the tab stuck
    /// reporting progressive while the session was demonstrably mixed. What the space
    /// was opened with is the fact worth keeping, and the PC decided it before the
    /// space existed.
    private var foveatedImmersionBinding: Binding<any ImmersionStyle> {
        Binding(get: { foveatedManager.effectiveImmersionStyle.systemStyle }, set: { _ in })
    }
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
                .environment(pcvrStore)
                .environment(pcvrLimiter)
                .environment(pcvrBandwidth)
                #endif
                .task {
                    // Let the VNC manager drive a companion audio stream in
                    // lockstep with its connection lifecycle.
                    connectionManager.audioManager = audioManager
                }
                #if FOVEATED_ENABLED
                .task {
                    // Resolve entitlements before anything can start a session:
                    // the limiter refuses to run its clock until StoreKit has
                    // answered, so this is what lets a paying customer play.
                    await pcvrStore.resolveEntitlements()
                    // Started from the app, not a view. A trial clock hosted by
                    // whatever happens to be on screen stops counting the moment
                    // the user switches tabs or closes the window.
                    pcvrLimiter.start(manager: foveatedManager, store: pcvrStore)
                    // Independent of the trial clock and of StoreKit: a metered host
                    // costs real money whether or not the trial has been paid for.
                    pcvrBandwidth.start(manager: foveatedManager)
                }
                #endif
        } defaultValue: {
            .shared
        }
        .modelContainer(for: SavedConnection.self)

        WindowGroup("Console", id: "console") {
            ConsoleWindowView()
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
        // `.plain` so AudioStreamView supplies its own glass around just the
        // content: the slack it reserves above the panel for short artwork then
        // shows nothing, instead of a tall empty slab of system glass.
        .windowStyle(.plain)
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
        // .contentSize, not .contentMinSize: this one window group swaps
        // between a freely resizable full-bleed video view and several
        // fixed-size panels (the audio mini player, the window picker, the
        // empty placeholder) depending on what's live. .contentMinSize would
        // keep the window pinned at its oversized video default even for
        // those fixed panels, leaving dead space below them and a resize
        // handle that does nothing useful. .contentSize re-measures on every
        // state change instead, so the window hugs whichever content is
        // showing — screenContent stays freely resizable because it declares
        // a wide min/max frame; the fixed-size panels get sized exactly to
        // their content and stop being resizable.
        .windowResizability(.contentSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        WindowGroup(
            "Unity Controls",
            id: "mac-native-unity-controls",
            for: MacNativeUnityControlID.self
        ) { _ in
            MacNativeUnityControlView()
                .environment(macNativeManager)
                .environment(audioManager)
                .trackWindowSession(id: "mac-native-unity-controls")
        } defaultValue: {
            .shared
        }
        .defaultSize(width: 980, height: 180)
        .windowResizability(.contentSize)
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)

        // Unity-style per-window streams: one chrome-free scene per streamed
        // host window, keyed by the host window ID. No ornament by design —
        // the scene is just the remote window's pixels; control lives in the
        // Unity Controls window above.
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

        WindowGroup("Native Keyboard", id: "mac-native-keyboard") {
            MacNativeKeyboardView()
                .homeOrnament()
                .environment(macNativeManager)
                .trackWindowSession(id: "mac-native-keyboard")
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
                .environment(pcvrLimiter)
                .environment(pcvrBandwidth)
                .environment(pcvrStore)
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
                .environment(pcvrLimiter)
                .environment(pcvrBandwidth)
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
                .environment(pcvrLimiter)
                .environment(pcvrBandwidth)
                // Hide the Home indicator. It is summoned by raising a palm and looking
                // at it, which is precisely the wrist HUD's gesture — leave it on and the
                // two fight over the same intent.
                .persistentSystemOverlays(.hidden)
        }
        // A live binding, not a constant: writing to it restyles a space that is
        // already open, which is what lets the PC's Passthrough cutouts switch move the
        // headset between the two without dropping the session. Progressive is the
        // default and the only one the Digital Crown answers — wound all the way out it
        // *is* full immersion, which is why `.full` is not offered. `.mixed` is the only
        // one where the system composites the stream's alpha as passthrough; in
        // `.progressive` the portal is backed with black, which would turn the host's
        // ALPHA_BLEND cut-outs into black holes. Opaque game frames cover the view in
        // either, so games themselves are unaffected.
        .immersionStyle(selection: foveatedImmersionBinding, in: .progressive, .mixed)
        .upperLimbVisibility(.hidden)
        #endif
        #endif
    }
}
