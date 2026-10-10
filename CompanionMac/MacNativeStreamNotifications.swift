import AppKit
import Foundation
import UserNotifications

final class MacNativeStreamNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNativeStreamNotifications()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One viewer joined. There is no "replaced" case any more — viewers now
    /// watch alongside each other instead of taking each other's place.
    func connected(deviceName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Native Screen Connected"
        content.body = "\(deviceName) connected."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mac-native-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// A headset asked for something a missing grant blocks. Clicking it
    /// opens the setup assistant.
    func permissionMissing(_ permission: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(permission) Needed"
        content.body = "A headset tried to use a feature that needs \(permission). Click to allow it."
        content.userInfo = ["url": PermissionCenter.setupURL.absoluteString]
        // One identifier per permission: repeats replace instead of piling up.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "permission-\(permission)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init(string:)) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
