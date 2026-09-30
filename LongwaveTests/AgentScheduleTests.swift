import XCTest
@testable import Longwave

final class AgentScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Riga")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // MARK: Cadence

    func testIntervalFiresAfterReference() {
        let ref = date(2026, 9, 30, 10, 0)
        XCTAssertEqual(AgentSchedule.Cadence.interval(minutes: 90).nextFire(after: ref, calendar: calendar),
                       date(2026, 9, 30, 11, 30))
    }

    func testIntervalHasAFloor() {
        let ref = date(2026, 9, 30, 10, 0)
        XCTAssertEqual(AgentSchedule.Cadence.interval(minutes: 1).nextFire(after: ref, calendar: calendar),
                       ref.addingTimeInterval(TimeInterval(AgentSchedule.Cadence.minimumIntervalMinutes * 60)))
    }

    func testDailyLaterToday() {
        let next = AgentSchedule.Cadence.daily(hour: 18, minute: 30, weekdays: [])
            .nextFire(after: date(2026, 9, 30, 10, 0), calendar: calendar)
        XCTAssertEqual(next, date(2026, 9, 30, 18, 30))
    }

    func testDailyAlreadyPassedMovesToTomorrow() {
        let next = AgentSchedule.Cadence.daily(hour: 9, minute: 0, weekdays: [])
            .nextFire(after: date(2026, 9, 30, 9, 0), calendar: calendar)
        XCTAssertEqual(next, date(2026, 10, 1, 9, 0), "exactly at the fire time counts as passed")
    }

    func testDailyWeekdayFilter() {
        // 2026-09-30 is a Wednesday; Monday (2) only → Monday 2026-10-05.
        let next = AgentSchedule.Cadence.daily(hour: 9, minute: 0, weekdays: [2])
            .nextFire(after: date(2026, 9, 30, 12, 0), calendar: calendar)
        XCTAssertEqual(next, date(2026, 10, 5, 9, 0))
        XCTAssertEqual(calendar.component(.weekday, from: next!), 2)
    }

    func testDailyAcrossSpringForwardGap() {
        // Riga springs forward 2027-03-28 03:00 → 04:00, so 03:30 doesn't exist.
        let next = AgentSchedule.Cadence.daily(hour: 3, minute: 30, weekdays: [])
            .nextFire(after: date(2027, 3, 27, 12, 0), calendar: calendar)
        let unwrapped = try! XCTUnwrap(next)
        XCTAssertEqual(calendar.component(.day, from: unwrapped), 28, "the skipped time still fires that day")
        XCTAssertGreaterThanOrEqual(calendar.component(.hour, from: unwrapped), 4)
    }

    func testDailyAcrossFallBackFiresOnce() {
        // Riga falls back 2026-10-25 04:00 → 03:00, so 03:30 happens twice.
        let cadence = AgentSchedule.Cadence.daily(hour: 3, minute: 30, weekdays: [])
        let first = try! XCTUnwrap(cadence.nextFire(after: date(2026, 10, 24, 12, 0), calendar: calendar))
        let second = try! XCTUnwrap(cadence.nextFire(after: first, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: first), 25)
        XCTAssertEqual(calendar.component(.day, from: second), 26, "the repeated hour doesn't fire twice")
    }

    func testSummaries() {
        XCTAssertEqual(AgentSchedule.Cadence.interval(minutes: 120).summary, "Every 2 hours")
        XCTAssertEqual(AgentSchedule.Cadence.interval(minutes: 60).summary, "Every hour")
        XCTAssertEqual(AgentSchedule.Cadence.interval(minutes: 15).summary, "Every 15 minutes")
        XCTAssertEqual(AgentSchedule.Cadence.daily(hour: 7, minute: 5, weekdays: []).summary, "Daily at 07:05")
    }

    // MARK: Run or skip

    func testNoOverlap() {
        XCTAssertEqual(AgentSchedule.decide(isRunning: true, runsToday: 0, maxRunsPerDay: 10), .skipOverlap)
    }

    func testDailyCap() {
        XCTAssertEqual(AgentSchedule.decide(isRunning: false, runsToday: 3, maxRunsPerDay: 3), .skipDailyCap)
        XCTAssertEqual(AgentSchedule.decide(isRunning: false, runsToday: 2, maxRunsPerDay: 3), .run)
        XCTAssertEqual(AgentSchedule.decide(isRunning: false, runsToday: 99, maxRunsPerDay: 0), .run, "0 = no limit")
    }

    func testRunsStartedCountsOnlyToday() {
        let now = date(2026, 9, 30, 15, 0)
        let starts = [date(2026, 9, 29, 23, 59), date(2026, 9, 30, 0, 1), date(2026, 9, 30, 14, 0)]
        XCTAssertEqual(AgentSchedule.runsStarted(on: now, starts: starts, calendar: calendar), 2)
    }

    func testDailyCapMovesToTomorrow() {
        let now = date(2026, 9, 30, 15, 0)
        XCTAssertEqual(AgentSchedule.nextFireAfterDailyCap(.interval(minutes: 30), now: now, calendar: calendar),
                       date(2026, 10, 1, 0, 0))
        XCTAssertEqual(AgentSchedule.nextFireAfterDailyCap(.daily(hour: 0, minute: 0, weekdays: []), now: now, calendar: calendar),
                       date(2026, 10, 1, 0, 0), "a midnight daily run tomorrow is not skipped")
    }

    // MARK: Runtime cap

    func testRuntimeCap() {
        let start = date(2026, 9, 30, 10, 0)
        XCTAssertFalse(AgentSchedule.hasExceededRuntime(started: start, now: start.addingTimeInterval(29 * 60), maxRuntimeMinutes: 30))
        XCTAssertTrue(AgentSchedule.hasExceededRuntime(started: start, now: start.addingTimeInterval(31 * 60), maxRuntimeMinutes: 30))
        XCTAssertFalse(AgentSchedule.hasExceededRuntime(started: start, now: start.addingTimeInterval(9999 * 60), maxRuntimeMinutes: 0))
    }

    // MARK: Headless commands

    private let secretPrompt = "Fix it; don't `rm -rf` $HOME — 'quoted' \"too\"\nsecond line"
    private let token = "sk-ant-oat01-SECRETTOKENVALUE"

    func testPromptAndTokensNeverInOuterCommand() {
        for agent in AgentSchedule.schedulableAgents {
            let runID = AgentSchedule.runID(scheduleName: "Nightly", at: date(2026, 9, 30, 10, 0))
            let env = AgentSchedule.environment(credentials: [(name: "CLAUDE_CODE_OAUTH_TOKEN", value: token)],
                                                prompt: secretPrompt)
            let launch = AgentSessionCommands.agentLaunch(
                tmuxSession: runID, folder: "/Users/longwave-agent/Projects/demo",
                clientCommand: AgentSchedule.paneCommand(agent: agent, runID: runID),
                environment: env)
            for command in [launch.create, launch.attach] {
                XCTAssertFalse(command.contains("SECRETTOKENVALUE"), "\(agent): token in argv")
                XCTAssertFalse(command.contains("rm -rf"), "\(agent): prompt text in argv")
                XCTAssertFalse(command.contains("second line"), "\(agent): prompt text in argv")
            }
            let payload = String(decoding: launch.payload, as: UTF8.self)
            XCTAssertTrue(payload.contains("\(AgentSchedule.promptEnvName)="), "prompt travels on stdin")
            XCTAssertTrue(launch.create.contains("update-environment") && launch.create.contains(AgentSchedule.promptEnvName),
                          "tmux must import the prompt variable into the pane")
        }
    }

    func testPromptPayloadRoundTrips() {
        let env = AgentSchedule.environment(credentials: [], prompt: secretPrompt)
        let payload = String(decoding: AgentSessionCommands.envPayload(env), as: UTF8.self)
        let line = try! XCTUnwrap(payload.split(separator: "\n").first { $0.hasPrefix(AgentSchedule.promptEnvName + "=") })
        let b64 = String(line.dropFirst(AgentSchedule.promptEnvName.count + 1))
        XCTAssertEqual(String(decoding: Data(base64Encoded: b64)!, as: UTF8.self), secretPrompt)
    }

    func testEnvironmentReplacesAnyInjectedPromptVariable() {
        let env = AgentSchedule.environment(credentials: [(name: AgentSchedule.promptEnvName, value: "evil")], prompt: "good")
        XCTAssertEqual(env.filter { $0.name == AgentSchedule.promptEnvName }.map(\.value), ["good"])
    }

    func testAgentInvocations() {
        XCTAssertTrue(AgentSchedule.agentInvocation(for: .claude).hasPrefix("claude -p \"$LONGWAVE_RUN_PROMPT\""))
        XCTAssertTrue(AgentSchedule.agentInvocation(for: .claude).contains("--output-format stream-json"))
        XCTAssertTrue(AgentSchedule.agentInvocation(for: .codex).hasPrefix("codex exec "))
        XCTAssertTrue(AgentSchedule.agentInvocation(for: .copilot).hasPrefix("copilot -p \"$LONGWAVE_RUN_PROMPT\""))
        XCTAssertEqual(AgentSchedule.agentInvocation(for: .custom), "zsh -c \"$LONGWAVE_RUN_PROMPT\"")
    }

    func testPaneCommandRecordsExitAndLog() {
        let pane = AgentSchedule.paneCommand(agent: .claude, runID: "run-x-1")
        XCTAssertTrue(pane.hasPrefix("zsh -c '"))
        XCTAssertTrue(pane.contains(".longwave-runs/run-x-1.log"))
        XCTAssertTrue(pane.contains(".longwave-runs/run-x-1.exit"))
        XCTAssertTrue(pane.contains("${pipestatus[1]}"), "the agent's status, not tee's")
    }

    func testRunIDIsASafeSessionName() {
        let id = AgentSchedule.runID(scheduleName: "Nightly tests: iOS & visionOS!", at: date(2026, 9, 30, 10, 0))
        XCTAssertTrue(id.hasPrefix("run-"))
        XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: " :&!'\"$/.")))
    }

    // MARK: Progress and transcripts

    func testParseProgress() {
        XCTAssertEqual(AgentSchedule.parseProgress("banner\nRUNNING\n"), .running)
        XCTAssertEqual(AgentSchedule.parseProgress("EXIT 0\n"), .exited(0))
        XCTAssertEqual(AgentSchedule.parseProgress("p10k junk\nEXIT 3"), .exited(3))
        XCTAssertEqual(AgentSchedule.parseProgress("GONE"), .vanished)
        XCTAssertNil(AgentSchedule.parseProgress("nothing useful"))
    }

    func testExtractTranscriptDropsBanners() {
        let out = "Last login…\n\(AgentSchedule.transcriptBegin)\nline 1\nline 2\n\n\(AgentSchedule.transcriptEnd)\n"
        XCTAssertEqual(AgentSchedule.extractTranscript(out), "line 1\nline 2\n")
    }

    func testSummaryPrefersClaudeResult() {
        let t = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{}}
        {"type":"result","subtype":"success","is_error":false,"result":"On branch main.\\nDone."}
        """
        XCTAssertEqual(AgentSchedule.summary(ofTranscript: t), "On branch main. Done.")
        XCTAssertEqual(AgentSchedule.summary(ofTranscript: "a\nlast line\n\n"), "last line")
    }

    // MARK: Self-scheduling guard

    func testMissingDenies() {
        let ok = #"{"permissions":{"deny":["CronCreate","CronDelete","ScheduleWakeup","RemoteTrigger"]}}"#
        XCTAssertEqual(AgentSchedule.missingClaudeDenies(settingsJSON: ok), [])
        let partial = #"banner\n{"permissions":{"deny":["CronCreate"]}}"#
        XCTAssertEqual(AgentSchedule.missingClaudeDenies(settingsJSON: partial), ["CronDelete", "ScheduleWakeup", "RemoteTrigger"])
        XCTAssertEqual(AgentSchedule.missingClaudeDenies(settingsJSON: ""), AgentSchedule.requiredClaudeDenies)
    }
}
