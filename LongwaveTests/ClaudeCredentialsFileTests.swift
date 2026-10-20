import XCTest
@testable import Longwave

/// The sandbox's Claude credentials file: its shape, the setup that writes it,
/// and that only the sandbox ever gets it.
@MainActor
final class ClaudeCredentialsFileTests: XCTestCase {

    private func credential(expiresAt: Date? = Date().addingTimeInterval(28_800)) -> ClaudeOAuth.Credential {
        var c = ClaudeOAuth.Credential(accessToken: "access", refreshToken: "refresh-secret",
                                       expiresAt: expiresAt, scopes: ClaudeOAuth.Constants.fullScopes)
        c.subscriptionType = "max"
        c.rateLimitTier = "default_claude_max_20x"
        return c
    }

    private func oauth(_ json: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(json?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
    }

    // MARK: - File contents

    func testFileUsesTheCLIsShapeWithAnEmptyRefreshToken() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let json = ClaudeCredentialsFile.json(for: credential(expiresAt: expiry))
        let o = try oauth(json)
        XCTAssertEqual(o["accessToken"] as? String, "access")
        XCTAssertEqual(o["refreshToken"] as? String, "")
        XCTAssertEqual((o["expiresAt"] as? NSNumber)?.int64Value, 1_800_000_000_000, "milliseconds")
        XCTAssertEqual(o["scopes"] as? [String], ClaudeOAuth.Constants.fullScopes)
        XCTAssertEqual(o["subscriptionType"] as? String, "max")
        XCTAssertEqual(o["rateLimitTier"] as? String, "default_claude_max_20x")
        XCTAssertFalse(json?.contains("refresh-secret") ?? true, "the refresh token never enters the sandbox")
    }

    /// Without a stated expiry the file still claims a near one, so the CLI
    /// comes back for a new token instead of holding one forever.
    func testUnknownExpiryClaimsAnHour() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let o = try oauth(ClaudeCredentialsFile.json(for: credential(expiresAt: nil), now: now))
        XCTAssertEqual((o["expiresAt"] as? NSNumber)?.int64Value, 1_800_003_600_000)
    }

    // MARK: - Setup script

    func testSetupOnlyAppliesWhenTheFileIsInTheEnvironment() {
        XCTAssertNil(ClaudeCredentialsFile.sessionSetup(for: [("CLAUDE_CODE_OAUTH_TOKEN", "t")]))
        let setup = ClaudeCredentialsFile.sessionSetup(for: [(ClaudeCredentialsFile.envName, "{}")])
        XCTAssertEqual(setup?.consumedNames, [ClaudeCredentialsFile.envName],
                       "the JSON must not be registered with tmux")
    }

    func testSetupWritesWithBuiltinsAndClearsStaleTokenVariables() throws {
        let script = try XCTUnwrap(ClaudeCredentialsFile.sessionSetup(
            for: [(ClaudeCredentialsFile.envName, "{}")])?.script)
        XCTAssertTrue(script.contains("printf %s \"$\(ClaudeCredentialsFile.envName)\""))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains("mv -f"), "written atomically")
        XCTAssertTrue(script.contains("unset \(ClaudeCredentialsFile.envName)"))
        // A token left in an older tmux server's environment would win over the file.
        for name in ClaudeCredentialsFile.sessionEnvNames {
            XCTAssertTrue(script.contains("tmux set-environment -gu \(name)"), name)
        }
    }

    func testRewriteReadsTheJSONFromStdinAndReportsSuccess() {
        let command = ClaudeCredentialsFile.rewriteCommand
        XCTAssertTrue(command.hasPrefix("/bin/sh -c "))
        XCTAssertTrue(command.contains(ClaudeCredentialsFile.writtenMarker))
        XCTAssertFalse(command.contains("tmux"), "a rewrite never touches running sessions")
    }

    // MARK: - Only the sandbox

    /// A full-user SSH host's `~/.claude/.credentials.json` is the user's own
    /// CLI login, so it keeps the environment variables and gets no file.
    func testSSHHostNeverGetsTheFile() async {
        let c = SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
        defer { ClaudeCredentialStore.delete(connectionID: c.id) }
        c.setClaudeCredential(credential())

        let env = await c.resolvedSSHEnvironmentRenewingCredentials(for: .claude)
        XCTAssertFalse(env.contains { $0.name == ClaudeCredentialsFile.envName })
        XCTAssertTrue(env.contains { $0.name == "CLAUDE_CODE_OAUTH_TOKEN" })
        XCTAssertNil(c.sessionSetup(for: .claude, environment: env))
        XCTAssertEqual(c.requiredCredentialEnvName(for: .claude), "CLAUDE_CODE_OAUTH_TOKEN")
    }

    func testSandboxGetsTheFileAndNoTokenVariables() async throws {
        let host = SandboxHost()
        defer { ClaudeCredentialStore.delete(connectionID: host.id) }
        host.setClaudeCredential(credential())

        let env = await host.resolvedSSHEnvironmentRenewingCredentials(for: .claude)
        let json = try XCTUnwrap(env.first { $0.name == ClaudeCredentialsFile.envName }?.value)
        XCTAssertEqual(try oauth(json)["accessToken"] as? String, "access")
        for name in ClaudeCredentialsFile.sessionEnvNames {
            XCTAssertFalse(env.contains { $0.name == name }, name)
        }
        XCTAssertNotNil(host.sessionSetup(for: .claude, environment: env))
        XCTAssertEqual(host.requiredCredentialEnvName(for: .claude), ClaudeCredentialsFile.envName)
    }
}

/// The Companion's `SandboxAgentAccount` lives in the Mac target, which these
/// tests don't build; this stands in for it.
private final class SandboxHost: AgentCredentialHost {
    let id = UUID()
    var displayName: String { "sandbox" }
    var sshClientCommand = ""
    var sshAuthEnvName = ""
    var sshEnvVars = ""
    var isAgentSandbox: Bool { true }
    var sshHasAuthToken = false
    var sshHasCopilotToken = false
    var sshHasCustomToken = false
    var sshHasCodexToken = false
    func persistCredentialChanges() {}
}
