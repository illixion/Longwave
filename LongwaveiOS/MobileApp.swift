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
/// - **Moonlight.** Same reason the App Store edition drops it — this target
///   simply does not define `MOONLIGHT_ENABLED`, so those files compile away.
/// - **Broadcast.** The ReplayKit extension is a visionOS target, and what it
///   broadcasts is a view of a room.
/// - **The native Mac stream.** Its receiver is `#if os(visionOS)`; the Audio
///   half of a Native connection does work here.
@main
struct LongwaveMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @State private var connectionManager = VNCConnectionManager()
    @State private var audioManager = AudioStreamManager()
    @State private var sshManager = SSHTerminalManager()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(connectionManager)
                .environment(audioManager)
                .environment(sshManager)
                .task {
                    // Let the VNC manager drive a companion audio stream in
                    // lockstep with its connection lifecycle, as on visionOS.
                    connectionManager.audioManager = audioManager
                }
        }
        .modelContainer(for: SavedConnection.self)
    }
}
