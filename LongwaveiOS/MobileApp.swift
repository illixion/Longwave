import SwiftUI
import SwiftData

/// iPhone / iPad entry point.
///
/// The visionOS app is a multi-window design: the remote desktop, every
/// terminal, every keyboard and the audio player are separate scenes, opened
/// with `openWindow` and kept alive independently. iPhone has exactly one
/// window, and iPad multi-window would need a scene-restoration story the shared
/// `WindowSessionRegistry` does not have — so this target keeps the same
/// managers and the same views, and replaces the scene graph with a tab shell
/// that presents those surfaces as navigation instead (see `MobileRootView`).
///
/// The consequence worth knowing: shared views still call `openWindow(id:)` on
/// their own. Those calls are no-ops here rather than errors, so the shell drives
/// presentation off manager state — a VNC connection becoming active, a new SSH
/// session appearing — which works no matter which shared view started it.
///
/// What is deliberately absent, and why:
///
/// - **PCVR / foveated streaming.** There is nothing to be immersed in on a
///   phone, and `com.apple.developer.foveated-streaming-session` is a visionOS
///   entitlement. All of it is behind `FOVEATED_ENABLED`, which this target
///   never defines.
/// - **Broadcast.** The ReplayKit extension is a visionOS target, and what it
///   broadcasts is a view of a room.
///
/// Moonlight is present: this target links moonlight-common-c (all three linked
/// copies — see `MoonlightSessionStore`) and defines `MOONLIGHT_ENABLED`, so the
/// GPLv3 terms of the Moonlight build apply to it exactly as they do to the
/// `oss-moonlight` visionOS edition. The touch surface is `MobileMoonlightStreamView`.
/// The Native desktop stream is present too (`MobileNativeStreamView`); only its
/// per-window Unity scenes, a spatial idea, stay on visionOS.
@main
struct LongwaveMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var macNativeManager = MacNativeStreamManager()
    @State private var sshManager = SSHTerminalManager()
    #if MOONLIGHT_ENABLED
    @State private var moonlightSessions = MoonlightSessionStore()
    #endif

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(macNativeManager)
                .environment(sshManager)
                #if MOONLIGHT_ENABLED
                .environment(moonlightSessions)
                #endif
                .task {
                    // Let the VNC manager drive a companion audio stream in
                    // lockstep with its connection lifecycle, as on visionOS.
                    connectionManager.audioManager = audioManager
                }
        }
        .modelContainer(for: SavedConnection.self)
    }
}
