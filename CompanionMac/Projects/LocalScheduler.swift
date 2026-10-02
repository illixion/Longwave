import AppKit
import DebugTrace
import Foundation
import ServiceManagement
import SwiftData
import UserNotifications

/// Fires `ScheduledRun`s into the local sandbox **while the Companion is
/// running** — there's no background daemon; "Open at login" keeps it running.
///
/// One run per schedule at a time (a fire during a run is recorded as skipped),
/// `maxRunsPerDay` caps started runs per calendar day, an optional sandbox
/// reset precedes a run, and `maxRuntimeMinutes` kills the run's tmux session.
/// The pure rules live in `AgentSchedule` and are unit-tested there.
@Observable
@MainActor
final class LocalScheduler {
    private(set) var schedules: [ScheduledRun] = []
    /// schedule id → the record of its in-flight run.
    private(set) var active: [UUID: RunRecord] = [:]
    /// Required Claude denies missing from the sandbox's settings (empty = OK,
    /// nil = not checked yet / sandbox unreachable).
    private(set) var missingDenies: [String]?
    var lastError: String?

    let sandbox: LocalSandboxController
    private let container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }
    private var loop: Task<Void, Never>?
    /// Schedules the user asked to stop mid-run.
    private var stopRequested: Set<UUID> = []
    private let log = DebugLogger(subsystem: "pro.longwave", category: "LocalScheduler")

    static let tickInterval: Duration = .seconds(20)
    static let pollInterval: Duration = .seconds(5)

    init(sandbox: LocalSandboxController) {
        self.sandbox = sandbox
        container = ScheduleStore.makeContainer()
        if container == nil { lastError = "Couldn't open the schedules store." }
        reload()
    }

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        recoverInterruptedRuns()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func reload() {
        guard let context else { return }
        let fetch = FetchDescriptor<ScheduledRun>(sortBy: [SortDescriptor(\.createdAt)])
        schedules = (try? context.fetch(fetch)) ?? []
    }

    func records(for schedule: ScheduledRun, limit: Int = 20) -> [RunRecord] {
        guard let context else { return [] }
        let id = schedule.id
        var fetch = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.scheduleID == id },
                                               sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        fetch.fetchLimit = limit
        return (try? context.fetch(fetch)) ?? []
    }

    // MARK: - Editing

    func save(_ schedule: ScheduledRun, isNew: Bool) {
        guard let context else { return }
        if isNew { context.insert(schedule) }
        schedule.nextRunAt = schedule.isEnabled
            ? schedule.cadence.nextFire(after: schedule.lastRunAt ?? Date())
            : nil
        try? context.save()
        reload()
        requestNotificationPermission()
    }

    func setEnabled(_ schedule: ScheduledRun, _ on: Bool) {
        schedule.isEnabled = on
        // Re-enabling counts from now, not from a run days ago (no burst of catch-up).
        schedule.nextRunAt = on ? schedule.cadence.nextFire(after: Date()) : nil
        try? context?.save()
        reload()
    }

    func delete(_ schedule: ScheduledRun) {
        guard let context, active[schedule.id] == nil else {
            lastError = "Stop the running run before deleting its schedule."
            return
        }
        for record in records(for: schedule, limit: 10_000) { context.delete(record) }
        context.delete(schedule)
        try? context.save()
        reload()
    }

    // MARK: - Firing

    private func tick() async {
        let now = Date()
        for schedule in schedules where schedule.isEnabled {
            if schedule.nextRunAt == nil {
                schedule.nextRunAt = schedule.cadence.nextFire(after: schedule.lastRunAt ?? now)
            }
            guard let due = schedule.nextRunAt, due <= now else { continue }
            fire(schedule, now: now, manual: false)
        }
        try? context?.save()
    }

    /// "Run now" ignores the cadence but not the overlap rule or the daily cap.
    func runNow(_ schedule: ScheduledRun) {
        fire(schedule, now: Date(), manual: true)
    }

    private func fire(_ schedule: ScheduledRun, now: Date, manual: Bool) {
        let starts = records(for: schedule, limit: 500).filter { $0.status != .skipped }.map(\.startedAt)
        let decision = AgentSchedule.decide(isRunning: active[schedule.id] != nil,
                                            runsToday: AgentSchedule.runsStarted(on: now, starts: starts),
                                            maxRunsPerDay: schedule.maxRunsPerDay)
        switch decision {
        case .skipOverlap:
            recordSkip(schedule, note: "The previous run was still going.")
            if !manual { schedule.nextRunAt = schedule.cadence.nextFire(after: now) }
        case .skipDailyCap:
            if manual {
                lastError = "\(schedule.name) already ran \(schedule.maxRunsPerDay) times today."
            } else {
                schedule.nextRunAt = AgentSchedule.nextFireAfterDailyCap(schedule.cadence, now: now)
            }
        case .run:
            schedule.lastRunAt = now
            schedule.nextRunAt = schedule.isEnabled ? schedule.cadence.nextFire(after: now) : nil
            let record = RunRecord()
            record.scheduleID = schedule.id
            record.startedAt = now
            record.resetBefore = schedule.resetBeforeRun
            record.firewallOn = sandbox.status?.firewallAnchorLoaded ?? false
            record.runID = AgentSchedule.runID(scheduleName: schedule.name.isEmpty ? schedule.projectDisplayName : schedule.name,
                                               at: now)
            context?.insert(record)
            schedule.lastStatusRaw = RunRecord.Status.running.rawValue
            active[schedule.id] = record
            try? context?.save()
            Task { await execute(schedule, record) }
        }
    }

    private func recordSkip(_ schedule: ScheduledRun, note: String) {
        let record = RunRecord()
        record.scheduleID = schedule.id
        record.status = .skipped
        record.endedAt = record.startedAt
        record.note = note
        context?.insert(record)
        try? context?.save()
    }

    // MARK: - One run

    private func execute(_ schedule: ScheduledRun, _ record: RunRecord) async {
        let scheduleID = schedule.id
        defer {
            active[scheduleID] = nil
            stopRequested.remove(scheduleID)
            try? context?.save()
        }
        do {
            if schedule.resetBeforeRun {
                guard LocalSandboxController.probeFullDiskAccess() else {
                    throw LocalSandboxController.SandboxError.message(
                        "Reset before run needs Full Disk Access for Longwave Companion (System Settings → Privacy & Security).")
                }
                await sandbox.reset(logInAfter: true)
                if let error = sandbox.lastError { throw LocalSandboxController.SandboxError.message("Reset failed: \(error)") }
            } else {
                await sandbox.refresh()
            }
            guard sandbox.availability == .ready else {
                throw LocalSandboxController.SandboxError.message("The sandbox isn't ready.")
            }
            record.firewallOn = sandbox.status?.firewallAnchorLoaded ?? false
            if schedule.agent != .custom, !sandbox.account.hasToken(for: schedule.agent) {
                throw LocalSandboxController.SandboxError.message("\(schedule.agent.displayName) isn't signed in on this Mac.")
            }
            record.tmuxSession = try await sandbox.startHeadlessRun(
                project: schedule.projectBareName, agent: schedule.agent,
                runID: record.runID, prompt: schedule.prompt)
            try? context?.save()
            try await monitor(schedule, record)
        } catch {
            record.status = .failed
            record.note = error.localizedDescription
            log.log("Scheduled run failed: \(error.localizedDescription, privacy: .private)")
        }
        record.endedAt = record.endedAt ?? Date()
        await collectTranscript(schedule, record)
        schedule.lastStatusRaw = record.status.rawValue
        notify(schedule, record)
    }

    private func monitor(_ schedule: ScheduledRun, _ record: RunRecord) async throws {
        let progressCommand = AgentSessionCommands.loginShellCommand(
            AgentSchedule.progressCommand(runID: record.runID, tmuxSession: record.tmuxSession))
        var failures = 0
        while true {
            if stopRequested.contains(schedule.id) {
                _ = try? await sandbox.ssh(AgentSessionCommands.loginShellCommand(
                    AgentSchedule.killCommand(tmuxSession: record.tmuxSession)))
                record.status = .stopped
                return
            }
            if AgentSchedule.hasExceededRuntime(started: record.startedAt, now: Date(),
                                                maxRuntimeMinutes: schedule.maxRuntimeMinutes) {
                _ = try? await sandbox.ssh(AgentSessionCommands.loginShellCommand(
                    AgentSchedule.killCommand(tmuxSession: record.tmuxSession)))
                record.status = .timedOut
                record.note = "Killed after \(schedule.maxRuntimeMinutes) minutes."
                return
            }
            do {
                let out = try await sandbox.ssh(progressCommand)
                failures = 0
                switch AgentSchedule.parseProgress(out) {
                case .exited(let code):
                    record.exitCode = Int(code)
                    record.status = code == 0 ? .succeeded : .failed
                    return
                case .vanished:
                    record.status = .failed
                    record.note = "The run's session ended without an exit status."
                    return
                case .running, nil:
                    break
                }
            } catch {
                failures += 1
                // A reset or sshd hiccup; give it a minute before calling it lost.
                if failures >= 12 { throw error }
            }
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    private func collectTranscript(_ schedule: ScheduledRun, _ record: RunRecord) async {
        // No session means the run never started (e.g. a failed reset): there's
        // nothing to fetch, and an empty transcript would only mislead.
        guard !record.tmuxSession.isEmpty, record.status != .skipped else { return }
        guard let out = try? await sandbox.ssh(AgentSchedule.fetchTranscriptCommand(runID: record.runID)) else { return }
        let transcript = AgentSchedule.extractTranscript(out)
        let url = ScheduleStore.transcriptURL(scheduleID: schedule.id, startedAt: record.startedAt)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(transcript.utf8).write(to: url, options: .atomic)
            record.transcriptPath = url.path
            record.summary = AgentSchedule.summary(ofTranscript: transcript)
            _ = try? await sandbox.ssh(AgentSchedule.cleanupCommand(runID: record.runID))
        } catch {
            record.note += (record.note.isEmpty ? "" : " ") + "Transcript not saved: \(error.localizedDescription)"
        }
    }

    /// After a relaunch, runs left "running" are either still going (resume
    /// watching) or finished while the app was away (collect them).
    private func recoverInterruptedRuns() {
        guard let context else { return }
        let running = RunRecord.Status.running.rawValue
        let fetch = FetchDescriptor<RunRecord>(predicate: #Predicate { $0.statusRaw == running })
        for record in (try? context.fetch(fetch)) ?? [] {
            guard let schedule = schedules.first(where: { $0.id == record.scheduleID }),
                  !record.tmuxSession.isEmpty else {
                record.status = .failed
                record.note = "Longwave Companion quit before the run started."
                record.endedAt = record.endedAt ?? Date()
                continue
            }
            active[schedule.id] = record
            Task {
                do { try await monitor(schedule, record) } catch {
                    record.status = .failed
                    record.note = error.localizedDescription
                }
                record.endedAt = record.endedAt ?? Date()
                await collectTranscript(schedule, record)
                schedule.lastStatusRaw = record.status.rawValue
                active[schedule.id] = nil
                try? context.save()
                notify(schedule, record)
            }
        }
        try? context.save()
    }

    func stop(_ schedule: ScheduledRun) {
        guard active[schedule.id] != nil else { return }
        stopRequested.insert(schedule.id)
    }

    func attach(_ record: RunRecord) {
        do { try sandbox.attach(tmuxSession: record.tmuxSession) } catch { lastError = "\(error)" }
    }

    // MARK: - Self-scheduling guard

    func checkSelfSchedulingGuard() async {
        guard sandbox.availability == .ready,
              let out = try? await sandbox.ssh(AgentSchedule.readClaudeSettingsCommand) else {
            missingDenies = nil
            return
        }
        missingDenies = AgentSchedule.missingClaudeDenies(settingsJSON: out)
    }

    // MARK: - Notifications and login item

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ schedule: ScheduledRun, _ record: RunRecord) {
        let content = UNMutableNotificationContent()
        let name = schedule.name.isEmpty ? schedule.projectDisplayName : schedule.name
        content.title = "\(name): \(record.status.label)"
        var body = record.summary.isEmpty ? record.note : record.summary
        if body.isEmpty { body = "\(schedule.agent.displayName) in \(schedule.projectDisplayName)" }
        content.body = body
        content.threadIdentifier = schedule.id.uuidString
        content.userInfo = ["transcript": record.transcriptPath ?? ""]
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error { log.log("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Open at login: \(error.localizedDescription)"
            }
        }
    }
}
