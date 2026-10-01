import Foundation

/// One-time carry-over of host settings from LongwaveMac, which hosted the
/// Companion's features itself until the two apps were split (2026-10-01). The
/// apps have different bundle identifiers, so each has its own defaults domain;
/// without this a Mac that used LongwaveMac as its host would come up with a new
/// pairing token (every paired headset breaks), new broadcast/OBS passwords and
/// forgotten sandbox projects.
///
/// Copies only keys the Companion doesn't have yet — never overwrites — and
/// skips AppKit/SwiftUI window state. Must run before anything reads defaults
/// (before `AudioStreamerController` generates a fresh token).
enum LongwaveMacSettingsMigration {
    private static let legacyDomain = "pro.longwave.mac"
    private static let doneKey = "migratedHostSettingsFromLongwaveMac"

    static func runOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in legacy where shouldCopy(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private static func shouldCopy(_ key: String) -> Bool {
        !["NS", "Apple", "com_apple_", "com.apple."].contains { key.hasPrefix($0) }
    }
}
