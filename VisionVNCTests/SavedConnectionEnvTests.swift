import XCTest
@testable import VisionVNC

/// SSH environment parsing/validation on `SavedConnection`: the `KEY=VALUE`
/// line parser and the POSIX env-name validator that guards the shell
/// assignment built in `SSHTerminalManager`.
@MainActor
final class SavedConnectionEnvTests: XCTestCase {

    func testValidEnvNames() {
        XCTAssertTrue(SavedConnection.isValidEnvName("CLAUDE_CODE_OAUTH_TOKEN"))
        XCTAssertTrue(SavedConnection.isValidEnvName("_underscore"))
        XCTAssertTrue(SavedConnection.isValidEnvName("A1B2"))
    }

    func testInvalidEnvNames() {
        XCTAssertFalse(SavedConnection.isValidEnvName(""))
        XCTAssertFalse(SavedConnection.isValidEnvName("1LEADING"))  // leading digit
        XCTAssertFalse(SavedConnection.isValidEnvName("HAS SPACE"))
        XCTAssertFalse(SavedConnection.isValidEnvName("HAS=EQ"))
        XCTAssertFalse(SavedConnection.isValidEnvName("FÖÖ"))       // non-ASCII
    }

    func testEnvParsing() {
        let connection = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        connection.sshEnvVars = """
        FOO=bar
        # a comment line
        EMPTY=
        PATH=/usr/bin:/bin
        bad name=skipme
        =noName
        QUOTED=a=b=c
        """
        let env = connection.sshEnvironmentVariables()
        let dict = Dictionary(uniqueKeysWithValues: env.map { ($0.name, $0.value) })

        XCTAssertEqual(dict["FOO"], "bar")
        XCTAssertEqual(dict["EMPTY"], "")                 // empty value kept
        XCTAssertEqual(dict["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(dict["QUOTED"], "a=b=c")           // only the first '=' splits
        XCTAssertNil(dict["bad name"])                    // invalid name dropped
        XCTAssertFalse(env.contains { $0.name.isEmpty })  // "=noName" dropped
        XCTAssertFalse(env.contains { $0.name.hasPrefix("#") })  // comment dropped
    }

    func testEnvParsingDedupesLastWins() {
        let connection = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        connection.sshEnvVars = "A=1\nA=2"
        let env = connection.sshEnvironmentVariables()
        XCTAssertEqual(env.filter { $0.name == "A" }.count, 1)
        XCTAssertEqual(env.first { $0.name == "A" }?.value, "2")
    }

    // MARK: - Per-agent command / env-name resolution

    func testAgentDefaultCommandsAndEnvNames() {
        let c = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        XCTAssertEqual(c.effectiveCommand(for: .claude),
                       "claude --allow-dangerously-skip-permissions")
        XCTAssertEqual(c.effectiveCommand(for: .copilot), "copilot")
        XCTAssertEqual(c.effectiveEnvName(for: .claude), "CLAUDE_CODE_OAUTH_TOKEN")
        XCTAssertEqual(c.effectiveEnvName(for: .copilot), "COPILOT_GITHUB_TOKEN")

        // Custom falls back to the bare claude binary until overridden — the
        // permission flag is only added to the agent the app launches itself.
        XCTAssertEqual(c.effectiveCommand(for: .custom), "claude")
        XCTAssertEqual(c.effectiveEnvName(for: .custom), "CLAUDE_CODE_OAUTH_TOKEN")
        c.sshClientCommand = "aider"
        c.sshAuthEnvName = "OPENAI_API_KEY"
        XCTAssertEqual(c.effectiveCommand(for: .custom), "aider")
        XCTAssertEqual(c.effectiveEnvName(for: .custom), "OPENAI_API_KEY")
    }

    func testSSHAgentDefaultsToClaude() {
        let c = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        XCTAssertEqual(c.sshAgent, .claude)   // empty raw value
        c.sshAgent = .copilot
        XCTAssertEqual(c.sshAgentRawValue, "copilot")
        XCTAssertEqual(c.sshAgent, .copilot)
    }

    // MARK: - Per-agent token storage (keychain-backed; runs on simulator)

    func testPerAgentTokensAreIsolatedAndInjectedUnderTheirEnvName() {
        let c = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        defer {                                   // keep the simulator keychain clean
            c.setSSHAuthToken(nil, for: .claude)
            c.setSSHAuthToken(nil, for: .copilot)
        }

        c.setSSHAuthToken("claude-tok", for: .claude)
        c.setSSHAuthToken("copilot-tok", for: .copilot)

        // Stored independently — one doesn't clobber the other.
        XCTAssertEqual(c.sshAuthToken(for: .claude), "claude-tok")
        XCTAssertEqual(c.sshAuthToken(for: .copilot), "copilot-tok")
        XCTAssertTrue(c.hasToken(for: .claude))
        XCTAssertTrue(c.hasToken(for: .copilot))
        XCTAssertFalse(c.hasToken(for: .custom))

        // Each resolves under the agent's own env-var name.
        let claudeEnv = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .claude).map { ($0.name, $0.value) })
        let copilotEnv = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .copilot).map { ($0.name, $0.value) })
        XCTAssertEqual(claudeEnv["CLAUDE_CODE_OAUTH_TOKEN"], "claude-tok")
        XCTAssertNil(claudeEnv["COPILOT_GITHUB_TOKEN"])
        XCTAssertEqual(copilotEnv["COPILOT_GITHUB_TOKEN"], "copilot-tok")
        XCTAssertNil(copilotEnv["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testClearingOneAgentTokenLeavesTheOther() {
        let c = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        defer { c.setSSHAuthToken(nil, for: .claude) }

        c.setSSHAuthToken("claude-tok", for: .claude)
        c.setSSHAuthToken("copilot-tok", for: .copilot)
        c.setSSHAuthToken(nil, for: .copilot)

        XCTAssertEqual(c.sshAuthToken(for: .claude), "claude-tok")
        XCTAssertNil(c.sshAuthToken(for: .copilot))
        XCTAssertFalse(c.hasToken(for: .copilot))
    }

    func testGitHubDeviceFlowConstants() {
        // The public GitHub App client used by Copilot CLI's device flow.
        XCTAssertEqual(GitHubDeviceFlow.clientID, "Ov23ctDVkRmgkPke0Mmm")
        XCTAssertTrue(GitHubDeviceFlow.scope.contains("read:user"))
    }
}
