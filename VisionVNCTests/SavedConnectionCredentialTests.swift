import XCTest
@testable import VisionVNC

/// How an in-app-minted Claude credential interacts with the pre-existing
/// pasted-token slot on `SavedConnection`. The two coexist by design — the paste
/// field stays as an escape hatch — so what matters is that the credential wins,
/// that neither erases the other, and that the "is this host set up?" flag stays
/// truthful in every combination.
@MainActor
final class SavedConnectionCredentialTests: XCTestCase {

    private func makeConnection() -> SavedConnection {
        SavedConnection(hostname: "host", port: 22, connectionType: .ssh)
    }

    private func credential(_ token: String,
                            scopes: [String] = ClaudeOAuth.Constants.fullScopes) -> ClaudeOAuth.Credential {
        ClaudeOAuth.Credential(
            accessToken: token,
            refreshToken: "refresh",
            // Comfortably fresh, so the sync resolver is what's under test rather
            // than a refresh attempt.
            expiresAt: Date().addingTimeInterval(28_800),
            scopes: scopes
        )
    }

    /// Cleanup goes straight through the store: `clearClaudeCredential()` would
    /// try to revoke upstream, and these tests must not touch the network.
    private func cleanUp(_ c: SavedConnection) {
        ClaudeCredentialStore.delete(connectionID: c.id)
        c.setSSHAuthToken(nil, for: .claude)
    }

    func testCredentialSatisfiesTheSetUpFlag() {
        let c = makeConnection()
        defer { cleanUp(c) }

        XCTAssertFalse(c.hasToken(for: .claude))
        XCTAssertFalse(c.hasClaudeCredential)

        c.setClaudeCredential(credential("oauth-access"))

        XCTAssertTrue(c.hasClaudeCredential)
        XCTAssertTrue(c.hasToken(for: .claude), "an in-app sign-in is a complete setup on its own")
        XCTAssertEqual(c.claudeCredential?.accessToken, "oauth-access")
    }

    func testCredentialWinsOverPastedToken() {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)
        c.setClaudeCredential(credential("oauth-access"))

        let env = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .claude).map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "oauth-access",
                       "the full-scope credential should beat a hand-pasted one")
    }

    func testPastedTokenStillWorksWithoutACredential() {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)

        let env = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .claude).map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "pasted-token")
    }

    /// Regression guard: clearing the paste field used to be the only way to
    /// unset Claude, so it drove the flag directly. With a credential present
    /// that would have falsely reported the host as unconfigured.
    func testClearingPastedTokenKeepsFlagWhileCredentialRemains() {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)
        c.setClaudeCredential(credential("oauth-access"))

        c.setSSHAuthToken(nil, for: .claude)

        XCTAssertTrue(c.hasToken(for: .claude))
        XCTAssertTrue(c.hasClaudeCredential)
        let env = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .claude).map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "oauth-access")
    }

    func testClearingPastedTokenWithNoCredentialClearsFlag() {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)
        c.setSSHAuthToken(nil, for: .claude)

        XCTAssertFalse(c.hasToken(for: .claude))
        XCTAssertTrue(c.resolvedSSHEnvironment(for: .claude).isEmpty)
    }

    func testDeletingCredentialFallsBackToPastedToken() {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)
        c.setClaudeCredential(credential("oauth-access"))
        ClaudeCredentialStore.delete(connectionID: c.id)

        XCTAssertFalse(c.hasClaudeCredential)
        let env = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .claude).map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "pasted-token")
    }

    /// The credential store is keyed per connection and Claude-only; another
    /// agent on the same host must be unaffected by it.
    func testCredentialDoesNotLeakIntoOtherAgents() {
        let c = makeConnection()
        defer {
            ClaudeCredentialStore.delete(connectionID: c.id)
            c.setSSHAuthToken(nil, for: .claude)
            c.setSSHAuthToken(nil, for: .copilot)
        }

        c.setClaudeCredential(credential("oauth-access"))
        c.setSSHAuthToken("copilot-tok", for: .copilot)

        let copilotEnv = Dictionary(uniqueKeysWithValues:
            c.resolvedSSHEnvironment(for: .copilot).map { ($0.name, $0.value) })
        XCTAssertEqual(copilotEnv["COPILOT_GITHUB_TOKEN"], "copilot-tok")
        XCTAssertNil(copilotEnv["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testCredentialsAreScopedPerConnection() {
        let a = makeConnection()
        let b = makeConnection()
        defer {
            ClaudeCredentialStore.delete(connectionID: a.id)
            ClaudeCredentialStore.delete(connectionID: b.id)
        }

        a.setClaudeCredential(credential("token-a"))

        XCTAssertEqual(a.claudeCredential?.accessToken, "token-a")
        XCTAssertNil(b.claudeCredential, "a second host must not inherit the first's credential")
    }

    /// A fresh credential must not trigger a network refresh, so the async
    /// launch-path resolver returns the stored token unchanged.
    func testRenewingResolverPassesThroughAFreshCredential() async {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setClaudeCredential(credential("oauth-access"))

        let env = Dictionary(uniqueKeysWithValues:
            await c.resolvedSSHEnvironmentRenewingCredentials(for: .claude)
                .map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "oauth-access")
    }

    /// With no credential at all the async resolver must behave exactly like the
    /// sync one — no network, pasted token honored.
    func testRenewingResolverFallsBackWithoutACredential() async {
        let c = makeConnection()
        defer { cleanUp(c) }

        c.setSSHAuthToken("pasted-token", for: .claude)

        let env = Dictionary(uniqueKeysWithValues:
            await c.resolvedSSHEnvironmentRenewingCredentials(for: .claude)
                .map { ($0.name, $0.value) })
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "pasted-token")
    }
}
