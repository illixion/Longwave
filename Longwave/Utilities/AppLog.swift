import DebugTrace
import Foundation

/// Central loggers, one category per subsystem component.
///
/// `DebugLogger` keeps every line (debug included) in DebugTrace's in-memory
/// ring, which the Console tab tails and debug traces export, and forwards it
/// to the unified log with non-public values withheld. Privacy is per
/// interpolation, os_log style: numbers and bools are public, everything else
/// is private unless marked. Mark code-defined values `.public`; leave
/// anything from the user, the network or the filesystem private (use
/// `.private(mask: .hash)` for a host or id worth matching across lines), and
/// mark credentials `.sensitive`.
///
/// `nonisolated` because the loggers are `Sendable` and are called from the
/// audio, video and network queues as much as from the main actor.
nonisolated enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "pro.longwave"

    static let audioStream = DebugLogger(subsystem: subsystem, category: "AudioStream")
    static let broadcast = DebugLogger(subsystem: subsystem, category: "Broadcast")
    static let cryptoManager = DebugLogger(subsystem: subsystem, category: "CryptoManager")
    static let gamepadManager = DebugLogger(subsystem: subsystem, category: "GamepadManager")
    static let moonlightAudio = DebugLogger(subsystem: subsystem, category: "MoonlightAudio")
    static let moonlightBridge = DebugLogger(subsystem: subsystem, category: "MoonlightBridge")
    static let moonlightStream = DebugLogger(subsystem: subsystem, category: "MoonlightStream")
    static let moonlightVideo = DebugLogger(subsystem: subsystem, category: "MoonlightVideo")
    static let nvHTTPClient = DebugLogger(subsystem: subsystem, category: "NvHTTPClient")
    static let app = DebugLogger(subsystem: subsystem, category: "App")

    /// Every subsystem the app logs under: the bundle id (`AppLog`, the
    /// broadcast core), the fixed `pro.longwave` most feature loggers use, and
    /// on macOS the companion code built into the app.
    static var subsystems: [String] {
        var all = [subsystem, "pro.longwave"]
        #if os(macOS)
        all.append("pro.longwave.companion")
        #endif
        return all.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Call once at launch, before the first line worth keeping.
    static func configureDebugTrace() {
        DebugTrace.configure(.init(subsystems: subsystems))
    }
}
