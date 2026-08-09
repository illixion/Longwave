import Foundation
import os

/// Central os.Logger instances, one category per subsystem component.
/// Logs are visible in Console.app/Xcode and surfaced in-app by the
/// Console tab (`LogStore` polls OSLogStore for this subsystem).
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "pro.longwave"

    static let audioStream = Logger(subsystem: subsystem, category: "AudioStream")
    static let broadcast = Logger(subsystem: subsystem, category: "Broadcast")
    static let cryptoManager = Logger(subsystem: subsystem, category: "CryptoManager")
    static let gamepadManager = Logger(subsystem: subsystem, category: "GamepadManager")
    static let moonlightAudio = Logger(subsystem: subsystem, category: "MoonlightAudio")
    static let moonlightBridge = Logger(subsystem: subsystem, category: "MoonlightBridge")
    static let moonlightStream = Logger(subsystem: subsystem, category: "MoonlightStream")
    static let moonlightVideo = Logger(subsystem: subsystem, category: "MoonlightVideo")
    static let nvHTTPClient = Logger(subsystem: subsystem, category: "NvHTTPClient")
    static let app = Logger(subsystem: subsystem, category: "App")
}

extension Logger {
    /// Log a pre-formatted message at default level, visible (non-redacted)
    /// in OSLogStore. Only use for messages with no sensitive content.
    func line(_ message: String) {
        self.log("\(message, privacy: .public)")
    }
}
