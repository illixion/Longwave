import SwiftUI

/// iOS app delegate. Same job as the visionOS `AppDelegate` — surface the Local
/// Network prompt before the user tries to reach a host, and start watching
/// app-wide text entry — minus the home-screen re-invoke handling, which exists
/// only because a visionOS pop-out window can be left behind in another room.
/// There is one window here, so there is nothing to summon.
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        triggerLocalNetworkAccessPrompt()
        // Keyboard-capture views consult this before taking first responder, and
        // the terminal paces its output against it.
        TextInputActivity.shared.start()
        return true
    }

    /// Reading `ProcessInfo.processInfo.hostName` performs a local-network
    /// lookup, which is enough to make the system show the Local Network
    /// permission dialog. The value is discarded — the read is the trigger.
    private func triggerLocalNetworkAccessPrompt() {
        let hostName = ProcessInfo.processInfo.hostName
        AppLog.app.line("Local network access prompt triggered (host: \(hostName))")
    }
}
