import Foundation
import OSLog
import Observation

/// In-app log viewer backend. Polls OSLogStore for this process's entries
/// in our subsystem (everything logged through `AppLog`) while the Console
/// tab is visible, keeping a capped in-memory buffer.
@Observable
final class LogStore {

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let level: OSLogEntryLog.Level
        let message: String
    }

    static let shared = LogStore()

    private(set) var entries: [Entry] = []
    var minimumLevel: OSLogEntryLog.Level = .debug
    var categoryFilter: String? // nil = all

    var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    var filteredEntries: [Entry] {
        entries.filter { entry in
            entry.level.rawValue >= minimumLevel.rawValue
                && (categoryFilter == nil || entry.category == categoryFilter)
        }
    }

    private static let maxEntries = 2000
    private static let pollInterval: Duration = .seconds(1)

    private var pollTask: Task<Void, Never>?
    private var lastSeenDate: Date?
    /// Console tab and pop-out window each retain the poller.
    private var viewerCount = 0

    private init() {}

    /// Begin polling. Called when a console view appears.
    func start() {
        viewerCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stop polling once no console view remains visible.
    func stop() {
        viewerCount = max(0, viewerCount - 1)
        guard viewerCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func clear() {
        entries.removeAll()
        lastSeenDate = Date()
    }

    private func poll() {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // The process-scoped store only holds this launch's entries, so
            // the first poll reads from the beginning — logs emitted before
            // the console was first opened (e.g. launch-time reconnect
            // errors) are still captured.
            let since = lastSeenDate ?? .distantPast
            let position = store.position(date: since)
            let subsystem = AppLog.subsystem

            var new: [Entry] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: position)
            where entry.subsystem == subsystem && entry.date > since {
                new.append(Entry(
                    date: entry.date,
                    category: entry.category,
                    level: entry.level,
                    message: entry.composedMessage
                ))
            }
            guard !new.isEmpty else { return }
            lastSeenDate = new.last?.date ?? lastSeenDate
            entries.append(contentsOf: new)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        } catch {
            // OSLogStore access failed — nothing useful to do but retry next tick.
        }
    }
}

extension OSLogEntryLog.Level {
    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .error: return "Error"
        case .fault: return "Fault"
        case .undefined: return "—"
        @unknown default: return "?"
        }
    }
}
