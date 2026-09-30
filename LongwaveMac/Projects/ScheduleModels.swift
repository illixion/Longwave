import Foundation
import SwiftData

/// A recurring headless agent run against one sandbox project. Mac-only, and
/// kept in its own SwiftData store (`ScheduleStore`) rather than the shared
/// `SavedConnection` one, so schedules never enter backups or the visionOS
/// schema. Every property has a default, per the repo's migration rule.
@Model
final class ScheduledRun {
    var id: UUID = UUID()
    var name: String = ""
    /// Bare repo name in the exchange dir (`name.git`).
    var projectBareName: String = ""
    var agentRawValue: String = SSHAgent.claude.rawValue
    var prompt: String = ""

    /// "interval" or "daily".
    var cadenceKind: String = "interval"
    var intervalMinutes: Int = 60
    var dailyHour: Int = 9
    var dailyMinute: Int = 0
    /// Calendar weekdays (1 = Sunday … 7 = Saturday), comma-separated; empty = every day.
    var weekdaysRaw: String = ""

    var maxRuntimeMinutes: Int = 30
    var maxRunsPerDay: Int = 6
    var resetBeforeRun: Bool = false
    var isEnabled: Bool = true

    var createdAt: Date = Date()
    var lastRunAt: Date?
    var nextRunAt: Date?
    var lastStatusRaw: String?

    init() {}

    var agent: SSHAgent {
        get { SSHAgent(rawValue: agentRawValue) ?? .claude }
        set { agentRawValue = newValue.rawValue }
    }

    var weekdays: Set<Int> {
        get { Set(weekdaysRaw.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) }) }
        set { weekdaysRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }

    var cadence: AgentSchedule.Cadence {
        get {
            cadenceKind == "daily"
                ? .daily(hour: dailyHour, minute: dailyMinute, weekdays: weekdays)
                : .interval(minutes: intervalMinutes)
        }
        set {
            switch newValue {
            case .interval(let minutes):
                cadenceKind = "interval"
                intervalMinutes = max(minutes, AgentSchedule.Cadence.minimumIntervalMinutes)
            case .daily(let hour, let minute, let days):
                cadenceKind = "daily"
                dailyHour = hour
                dailyMinute = minute
                weekdays = days
            }
        }
    }

    var projectDisplayName: String {
        projectBareName.hasSuffix(".git") ? String(projectBareName.dropLast(4)) : projectBareName
    }

    var lastStatus: RunRecord.Status? { lastStatusRaw.flatMap(RunRecord.Status.init(rawValue:)) }
}

/// One execution (or skipped fire) of a `ScheduledRun`.
@Model
final class RunRecord {
    enum Status: String, CaseIterable, Sendable {
        case running, succeeded, failed, timedOut, stopped, skipped

        var label: String {
            switch self {
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .timedOut: "Timed out"
            case .stopped: "Stopped"
            case .skipped: "Skipped"
            }
        }

        var symbol: String {
            switch self {
            case .running: "hourglass"
            case .succeeded: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .timedOut: "clock.badge.exclamationmark"
            case .stopped: "stop.circle"
            case .skipped: "forward.end"
            }
        }
    }

    var id: UUID = UUID()
    var scheduleID: UUID = UUID()
    var runID: String = ""
    /// The tmux session in the sandbox while it runs (attachable).
    var tmuxSession: String = ""
    var startedAt: Date = Date()
    var endedAt: Date?
    var statusRaw: String = Status.running.rawValue
    var exitCode: Int?
    var transcriptPath: String?
    var summary: String = ""
    /// Whether the opt-in pf anchor was loaded when the run started (it's off
    /// by default because it disables iCloud Private Relay).
    var firewallOn: Bool = false
    var resetBefore: Bool = false
    var note: String = ""

    init() {}

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}

/// The schedules' own store: `~/Library/Application Support/Longwave/Schedules.store`.
enum ScheduleStore {
    static func makeContainer() -> ModelContainer? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Longwave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = ModelConfiguration("Schedules", url: dir.appendingPathComponent("Schedules.store"))
        return try? ModelContainer(for: ScheduledRun.self, RunRecord.self, configurations: config)
    }

    /// Where fetched transcripts live: `runs/<schedule id>/<timestamp>.log`.
    static func transcriptURL(scheduleID: UUID, startedAt: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Longwave/runs/\(scheduleID.uuidString)", isDirectory: true)
            .appendingPathComponent("\(f.string(from: startedAt)).log")
    }
}
