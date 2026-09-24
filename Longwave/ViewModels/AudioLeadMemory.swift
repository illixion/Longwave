import Foundation

/// The jitter-cushion lead each host's link demanded last time, so a new
/// session starts from it instead of learning it from its first stall.
///
/// The receiver holds its lead for the whole session and only raises it
/// when a stall or underrun proves it short (see `AudioStreamReceiver`), so
/// without this every session began at the 40 ms base and paid for the
/// first stall with audible pops before settling. What is stored is the
/// session's *measured* demand, never the primed value it started from — a
/// link that has since improved is remembered as having improved.
///
/// Keyed by host, port and transport: the stalls belong to a particular
/// Wi-Fi hop, and TCP and UDP ride it differently. Thread-safe (UserDefaults
/// is); called from the receiver's queue.
nonisolated enum AudioLeadMemory {
    /// A session shorter than this has probably not met a stall yet, and
    /// would teach the next one a lead too small for the link.
    static let minimumSessionSeconds: Double = 60
    /// Beyond this a remembered lead describes a network that may no longer
    /// exist (another room, another access point), so it is ignored.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    private static let defaultsKey = "audioLearnedLead"

    static func key(host: String, port: UInt16, lowLatency: Bool) -> String {
        "\(host.lowercased()):\(port)/\(lowLatency ? "udp" : "tcp")"
    }

    /// The remembered lead in seconds, or nil when there is none or it is
    /// stale.
    static func lead(
        host: String, port: UInt16, lowLatency: Bool,
        defaults: UserDefaults = .standard, now: Date = Date()
    ) -> Double? {
        guard let entries = defaults.dictionary(forKey: defaultsKey),
              let entry = entries[key(host: host, port: port, lowLatency: lowLatency)] as? [String: Double],
              let seconds = entry["seconds"], let savedAt = entry["savedAt"],
              seconds.isFinite, seconds > 0,
              now.timeIntervalSince1970 - savedAt <= maximumAge else { return nil }
        return seconds
    }

    static func remember(
        _ seconds: Double, host: String, port: UInt16, lowLatency: Bool,
        defaults: UserDefaults = .standard, now: Date = Date()
    ) {
        guard seconds.isFinite, seconds > 0 else { return }
        var entries = defaults.dictionary(forKey: defaultsKey) ?? [:]
        entries[key(host: host, port: port, lowLatency: lowLatency)] = [
            "seconds": seconds,
            "savedAt": now.timeIntervalSince1970,
        ]
        defaults.set(entries, forKey: defaultsKey)
    }
}
