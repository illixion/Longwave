import SwiftUI

/// App delegate whose sole job is to surface the Local Network permission
/// prompt as early as possible — before the user tries to connect to a VNC,
/// Moonlight, or audio sender on the LAN. Without the grant, `NWConnection`
/// and the audio receiver's `NWListener` silently fail to reach the host.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Guards the home-screen re-invoke summon so it fires only for the first
    /// activation of the process. A gaze-resume after visionOS suspends the
    /// app also calls `applicationDidBecomeActive`; without this guard, merely
    /// looking back at a wall-pinned window would pop an unwanted main window.
    private var didHandleInitialActivation = false

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        triggerLocalNetworkAccessPrompt()
        // Watch app-wide text entry from launch: keyboard-capture views consult
        // it before taking first responder, and streaming windows pace themselves
        // against it so their UIKit churn can't end a dictation session.
        TextInputActivity.shared.start()
        return true
    }

    /// Home-screen re-invoke fix: if the app re-activates with no main window
    /// open — e.g. the only connected scene is the audio-stream window snapped
    /// in a room the user has left — summon a main window so tapping the app
    /// icon does something instead of silently reactivating a far-away pop-out.
    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !didHandleInitialActivation else { return }
        didHandleInitialActivation = true
        Task { @MainActor in
            // Let SwiftUI attach restored scenes and run their onAppear first,
            // so `mainWindowCount` reflects reality before we decide to summon.
            try? await Task.sleep(for: .milliseconds(400))
            WindowSessionRegistry.shared.ensureMainWindowVisible()
        }
    }

    /// Accessing `ProcessInfo.processInfo.hostName` performs a local-network
    /// lookup, which is enough to make the system show the Local Network
    /// permission dialog. The value is discarded — the read is the trigger.
    private func triggerLocalNetworkAccessPrompt() {
        let hostName = ProcessInfo.processInfo.hostName
        AppLog.app.line("Local network access prompt triggered (host: \(hostName))")
    }
}
