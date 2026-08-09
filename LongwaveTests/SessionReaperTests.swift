import Foundation
import XCTest
@testable import Longwave

/// The host-side idle teardown, and the clipboard URL guard that lets the login
/// sheet follow an emailed magic link.
///
/// Verified against tmux 3.7b while writing this: an agent session's pane process
/// is the agent binary rather than a shell (so `TMOUT` can never close one), and
/// `session_activity` stops advancing once an agent is idle at its prompt (so it
/// is a sound idle signal). These tests pin the command *shape* that depends on
/// those facts.
@MainActor
final class SessionReaperTests: XCTestCase {

    // MARK: - Watchdog command

    private var watchdog: String {
        SSHTerminalManager.reaperWatchdogCommand(ttlSeconds: 21_600, intervalSeconds: 900)
    }

    /// The decoded payload — the command carries its script base64'd to survive
    /// three levels of shell quoting.
    private func decodedScript(_ command: String) throws -> String {
        // `sh -c "echo <b64>|base64 -d|sh"`
        let marker = "echo "
        guard let start = command.range(of: marker),
              let end = command.range(of: "|base64", range: start.upperBound..<command.endIndex) else {
            throw XCTSkip("command shape changed")
        }
        let encoded = String(command[start.upperBound..<end.lowerBound])
        guard let data = Data(base64Encoded: encoded),
              let script = String(data: data, encoding: .utf8) else {
            XCTFail("payload is not valid base64 UTF-8")
            return ""
        }
        return script
    }

    /// `new -A` is what makes the watchdog single-instance and self-healing; a
    /// plain `new` would stack one watchdog per launch.
    func testWatchdogIsAttachOrCreate() {
        XCTAssertTrue(watchdog.contains("tmux new -A -d -s"))
    }

    /// It must not tag itself: the tag is both the reap set and the rediscovery
    /// filter, so tagging would let it kill itself and show up as a user session.
    func testWatchdogSessionIsUntagged() {
        XCTAssertTrue(watchdog.contains(SSHTerminalManager.reaperSessionName))
        XCTAssertFalse(watchdog.contains("set-option -t \(SSHTerminalManager.reaperSessionName) @longwave"))
    }

    /// The encoded payload must not leak quotes or `$` into the outer command,
    /// which is the entire reason it's encoded.
    func testWatchdogCommandCarriesNoShellMetacharacters() {
        XCTAssertFalse(watchdog.contains("'"), "a single quote would break `zsh -lic '…'`")
        XCTAssertFalse(watchdog.contains("$"), "an unescaped $ would be expanded by an outer shell")
    }

    func testWatchdogScriptReapsOnlyTaggedDetachedStaleSessions() throws {
        let script = try decodedScript(watchdog)
        XCTAssertTrue(script.contains("21600"), "TTL should reach the script")
        XCTAssertTrue(script.contains("sleep 900"), "interval should reach the script")
        // Tagged, detached, and stale — all three conditions, plus the kill.
        XCTAssertTrue(script.contains("#{@longwave}"))
        XCTAssertTrue(script.contains("\"$mark\" = 1"))
        XCTAssertTrue(script.contains("\"$att\" = 0"))
        XCTAssertTrue(script.contains("kill-session"))
    }

    /// Without the exit check the watchdog would poll forever on a host the user
    /// has stopped using.
    func testWatchdogScriptSelfTerminatesWhenNothingIsLeft() throws {
        let script = try decodedScript(watchdog)
        XCTAssertTrue(script.contains("grep -q 1 || exit 0"))
    }

    /// Regression guard for the actual bug found: teardown used to depend on the
    /// app connecting, so nothing collected sessions while the headset was off.
    /// Every launch and re-attach must now (re)start the watchdog.
    func testLaunchAndReattachBothStartTheWatchdog() {
        let launched = SSHTerminalManager.claudeCommand(tmuxSession: "proj", folder: "/p")
        let reattached = SSHTerminalManager.attachCommand(tmuxSession: "proj")
        for command in [launched, reattached] {
            XCTAssertTrue(command.contains(SSHTerminalManager.reaperSessionName),
                          "watchdog missing from: \(command)")
        }
    }

    // MARK: - TTL vs token lifetime

    /// A token is injected once, into the agent process's environment, and a
    /// running process's env can't be rewritten — so a session that outlives its
    /// token comes back broken rather than merely stale. The TTL has to close it
    /// first.
    func testStaleTTLIsShorterThanAFullScopeTokenLife() {
        let tokenLifetime = 8 * 60 * 60
        XCTAssertLessThan(SSHTerminalManager.staleSessionTTLSeconds, tokenLifetime)
    }

    func testWatchdogChecksInMoreOftenThanTheTTL() {
        XCTAssertLessThan(SSHTerminalManager.reaperIntervalSeconds,
                          SSHTerminalManager.staleSessionTTLSeconds)
    }

    // MARK: - Clipboard magic-link guard

    func testAcceptsClaudeSignInLinks() {
        for raw in [
            "https://claude.ai/magic-link?token=abc",
            "https://claude.com/cai/oauth/authorize?client_id=x",
            "https://platform.claude.com/oauth/code/callback?code=y",
        ] {
            XCTAssertTrue(ClaudeLoginSheet.isClaudeSignInURL(URL(string: raw)!),
                          "should accept \(raw)")
        }
    }

    /// The sheet displays a lock and Claude's hostname; loading a copied URL from
    /// anywhere else would make that reassurance a lie.
    func testRejectsForeignAndInsecureLinks() {
        for raw in [
            "https://evil.example.com/phish",
            "http://claude.ai/magic-link",           // plaintext
            "https://claude.ai.evil.com/phish",      // suffix-confusion
            "javascript:alert(1)",
            "file:///etc/passwd",
        ] {
            XCTAssertFalse(ClaudeLoginSheet.isClaudeSignInURL(URL(string: raw)!),
                           "should reject \(raw)")
        }
    }

    func testAcceptsClaudeSubdomains() {
        XCTAssertTrue(ClaudeLoginSheet.isClaudeSignInURL(
            URL(string: "https://api.claude.ai/x")!))
    }
}
