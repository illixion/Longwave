import Foundation

/// The pure half of the Mac Projects tab's scheduled agent runs: cadence
/// arithmetic, the run/skip decision, the runtime cap, and the commands a
/// headless run is made of. Shared (not Mac-only) so it's unit-tested with the
/// rest; nothing here runs a process or touches SwiftData.
///
/// Scheduling is deliberately the **app's** job, not the agent's: the sandbox
/// denies cron/at to the agent account and Claude's own self-scheduling tools
/// (`CronCreate`, `CronDelete`, `ScheduleWakeup`, `RemoteTrigger`), so the only
/// loop an agent can be in is one the user configured here.
enum AgentSchedule {

    // MARK: - Cadence

    enum Cadence: Codable, Equatable, Sendable {
        /// Every `minutes` minutes, counted from the previous run's start (or
        /// from when the schedule was saved/enabled, before its first run).
        case interval(minutes: Int)
        /// At `hour:minute` local time, on the given `Calendar` weekdays
        /// (1 = Sunday … 7 = Saturday); an empty set means every day.
        case daily(hour: Int, minute: Int, weekdays: Set<Int>)

        /// Shortest allowed interval — a floor against a typo scheduling a run
        /// every minute and burning a subscription's quota.
        static let minimumIntervalMinutes = 5

        /// The next fire strictly after `reference`.
        ///
        /// Daily times go through `Calendar.nextDate(…, matchingPolicy:
        /// .nextTime)`, so a time skipped by a DST jump fires at the next valid
        /// instant instead of being lost, and a repeated hour fires once.
        func nextFire(after reference: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .interval(let minutes):
                let m = max(minutes, Self.minimumIntervalMinutes)
                return reference.addingTimeInterval(TimeInterval(m * 60))
            case .daily(let hour, let minute, let weekdays):
                let wanted = DateComponents(hour: hour, minute: minute)
                var cursor = reference
                // Eight tries covers a full week plus the reference day.
                for _ in 0..<8 {
                    guard let candidate = calendar.nextDate(after: cursor, matching: wanted,
                                                            matchingPolicy: .nextTime,
                                                            repeatedTimePolicy: .first) else { return nil }
                    if weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: candidate)) {
                        return candidate
                    }
                    cursor = candidate
                }
                return nil
            }
        }

        var summary: String {
            switch self {
            case .interval(let minutes):
                let m = max(minutes, Self.minimumIntervalMinutes)
                if m % 60 == 0 { return m == 60 ? "Every hour" : "Every \(m / 60) hours" }
                return "Every \(m) minutes"
            case .daily(let hour, let minute, let weekdays):
                let time = String(format: "%02d:%02d", hour, minute)
                if weekdays.isEmpty || weekdays.count == 7 { return "Daily at \(time)" }
                let names = Calendar.current.shortWeekdaySymbols
                let days = weekdays.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
                return "\(days.joined(separator: ", ")) at \(time)"
            }
        }
    }

    // MARK: - Run or skip

    enum Decision: Equatable, Sendable {
        case run
        /// The previous run of this schedule is still going. Runs never
        /// overlap; this fire is dropped (and recorded as skipped).
        case skipOverlap
        /// `maxRunsPerDay` reached; the next fire moves to tomorrow.
        case skipDailyCap
    }

    /// What to do with a fire. `runsToday` counts runs actually started today
    /// (skips don't count).
    static func decide(isRunning: Bool, runsToday: Int, maxRunsPerDay: Int) -> Decision {
        if isRunning { return .skipOverlap }
        if maxRunsPerDay > 0, runsToday >= maxRunsPerDay { return .skipDailyCap }
        return .run
    }

    /// Runs started on `now`'s calendar day.
    static func runsStarted(on now: Date, starts: [Date], calendar: Calendar = .current) -> Int {
        starts.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }

    /// Where the next fire goes after a daily-cap skip: the first cadence fire
    /// on or after the start of tomorrow.
    static func nextFireAfterDailyCap(_ cadence: Cadence, now: Date, calendar: Calendar = .current) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        switch cadence {
        case .interval:
            // An interval schedule restarts its count at midnight.
            return tomorrow
        case .daily:
            return cadence.nextFire(after: tomorrow.addingTimeInterval(-1), calendar: calendar)
        }
    }

    // MARK: - Runtime cap

    static func hasExceededRuntime(started: Date, now: Date, maxRuntimeMinutes: Int) -> Bool {
        maxRuntimeMinutes > 0 && now.timeIntervalSince(started) > TimeInterval(maxRuntimeMinutes * 60)
    }

    // MARK: - The headless run

    /// Carries the prompt into the run through the create channel's stdin
    /// payload (base64, like the tokens), so it's never an argument of the ssh
    /// exec or of anything on the owner's side. Inside the sandbox the pane's
    /// shell expands it into the agent's own argv, which is the agent's business.
    static let promptEnvName = "LONGWAVE_RUN_PROMPT"
    /// Per-run files in the agent's home; a reset wipes them with the rest.
    static let runsDir = ".longwave-runs"

    /// A run id safe as a tmux session name and a file name.
    static func runID(scheduleName: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return AgentSessionCommands.slug("run-\(scheduleName)") + "-" + f.string(from: date)
    }

    /// The agents that have a non-interactive mode worth scheduling. `.custom`
    /// is a plain shell command (the prompt *is* the command) — no model, no
    /// credentials; useful for scheduled scripts and for testing the pipeline.
    static let schedulableAgents: [SSHAgent] = [.claude, .codex, .copilot, .custom]

    static func displayName(for agent: SSHAgent) -> String {
        agent == .custom ? "Shell command" : agent.displayName
    }

    /// The agent's non-interactive invocation. Permission prompts are bypassed
    /// on purpose: nobody is there to answer them, and the sandbox account —
    /// not the agent's own sandbox — is the security boundary (Codex's Seatbelt
    /// sandbox would also break xcodebuild).
    static func agentInvocation(for agent: SSHAgent) -> String {
        let prompt = "\"$\(promptEnvName)\""
        switch agent {
        case .claude:
            return "claude -p \(prompt) --dangerously-skip-permissions --output-format stream-json --verbose"
        case .codex:
            return "codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check --color never \(prompt)"
        case .copilot:
            // --allow-all = tools + paths + URLs (--allow-all-tools/-paths left
            // URL fetches prompting, which a headless run can't answer).
            return "copilot -p \(prompt) --allow-all"
        case .custom:
            return "zsh -c \(prompt)"
        }
    }

    /// The tmux pane command: run the agent, tee everything to the run's log,
    /// record its exit status, and exit (which ends the session). Contains the
    /// prompt only as a variable reference.
    static func paneCommand(agent: SSHAgent, runID: String) -> String {
        let log = "\"$HOME/\(runsDir)/\(runID).log\""
        let exit = "\"$HOME/\(runsDir)/\(runID).exit\""
        let inner = "mkdir -p \"$HOME/\(runsDir)\"; "
            + "\(agentInvocation(for: agent)) </dev/null 2>&1 | tee \(log); "
            + "echo \"${pipestatus[1]}\" > \(exit)"
        return "zsh -c " + AgentSessionCommands.shellSingleQuote(inner)
    }

    /// The run's environment: the agent's resolved credentials plus the prompt.
    static func environment(credentials: [(name: String, value: String)],
                            prompt: String) -> [(name: String, value: String)] {
        credentials.filter { $0.name != promptEnvName } + [(name: promptEnvName, value: prompt)]
    }

    enum Progress: Equatable, Sendable {
        case running
        case exited(Int32)
        /// The session is gone with no exit status: killed (stop / runtime cap)
        /// or it died before the agent finished.
        case vanished
    }

    /// Prints `EXIT <code>`, `RUNNING` or `GONE`. Run through `loginShellCommand`.
    static func progressCommand(runID: String, tmuxSession: String) -> String {
        let exit = "\"$HOME/\(runsDir)/\(runID).exit\""
        return "if [ -s \(exit) ]; then printf 'EXIT %s\\n' \"$(cat \(exit))\"; "
            + "elif tmux has-session -t \(AgentSessionCommands.target(tmuxSession)) 2>/dev/null; then echo RUNNING; "
            + "else echo GONE; fi"
    }

    /// Reads `progressCommand` output; rc-file banners before it are ignored.
    static func parseProgress(_ output: String) -> Progress? {
        for line in output.split(separator: "\n").reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s == "RUNNING" { return .running }
            if s == "GONE" { return .vanished }
            if s.hasPrefix("EXIT ") {
                return .exited(Int32(s.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? -1)
            }
        }
        return nil
    }

    /// Transcripts are capped when fetched back so a runaway log can't balloon.
    static let transcriptByteCap = 8 * 1024 * 1024

    /// Prints the run's log (last `transcriptByteCap` bytes) between markers,
    /// so rc-file banners can't leak into the saved transcript.
    static func fetchTranscriptCommand(runID: String) -> String {
        "echo \(transcriptBegin); tail -c \(transcriptByteCap) \"$HOME/\(runsDir)/\(runID).log\" 2>/dev/null; echo; echo \(transcriptEnd)"
    }

    static let transcriptBegin = "LONGWAVE-TRANSCRIPT-BEGIN"
    static let transcriptEnd = "LONGWAVE-TRANSCRIPT-END"

    static func extractTranscript(_ output: String) -> String {
        guard let begin = output.range(of: transcriptBegin + "\n") else { return output }
        let rest = output[begin.upperBound...]
        guard let end = rest.range(of: "\n" + transcriptEnd, options: .backwards) else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    static func cleanupCommand(runID: String) -> String {
        "rm -f \"$HOME/\(runsDir)/\(runID).log\" \"$HOME/\(runsDir)/\(runID).exit\""
    }

    static func killCommand(tmuxSession: String) -> String {
        "tmux kill-session -t \(AgentSessionCommands.target(tmuxSession)) 2>/dev/null; true"
    }

    /// One line for the finish notification: Claude's final `result` event when
    /// the transcript is stream-json, otherwise the last non-empty line.
    static func summary(ofTranscript transcript: String, maxLength: Int = 180) -> String {
        let lines = transcript.split(separator: "\n").map(String.init)
        for line in lines.reversed() where line.hasPrefix("{") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["type"] as? String == "result" {
                let text = (obj["result"] as? String) ?? (obj["subtype"] as? String) ?? ""
                return clip(text, maxLength)
            }
        }
        let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return clip(last, maxLength)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }

    // MARK: - Self-scheduling guard

    /// Claude tools the sandbox's settings must deny.
    static let requiredClaudeDenies = ["CronCreate", "CronDelete", "ScheduleWakeup", "RemoteTrigger"]

    static let readClaudeSettingsCommand = "cat \"$HOME/.claude/settings.json\" 2>/dev/null"

    /// The required denies missing from a `~/.claude/settings.json`. A missing
    /// or unreadable file is missing all of them.
    static func missingClaudeDenies(settingsJSON: String) -> [String] {
        guard let start = settingsJSON.firstIndex(of: "{"),
              let data = String(settingsJSON[start...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return requiredClaudeDenies
        }
        let deny = ((obj["permissions"] as? [String: Any])?["deny"] as? [String]) ?? []
        return requiredClaudeDenies.filter { !deny.contains($0) }
    }
}
