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

    func connected(deviceName: String, replacedDeviceName: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Native Mac Stream Connected"
        if let replacedDeviceName {
            content.body = "\(deviceName) connected and replaced \(replacedDeviceName)."
        } else {
            content.body = "\(deviceName) connected."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mac-native-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
