import Crypto
import XCTest
@testable import Longwave

/// The pure half of the Mac Projects tab's local agent sandbox: helper argv and
/// status JSON, git import/fetch commands, the in-sandbox clone script, the
/// Terminal attach command, the OpenSSH key parser and session discovery.
@MainActor
final class LocalSandboxTests: XCTestCase {

    // MARK: - Helper verbs and status

    func testHelperArgvIsFixedAndNonInteractive() {
        XCTAssertEqual(LocalSandbox.sudoArguments(.status), ["-n", "/usr/local/libexec/longwave-sandbox", "status"])
        XCTAssertEqual(LocalSandbox.sudoArguments(.snapshotGolden).last, "snapshot-golden")
        XCTAssertEqual(LocalSandbox.sudoArguments(.firewall(on: false)).suffix(2), ["firewall", "off"])
        // The key travels as one argv element — never through a shell.
        let line = "ssh-ed25519 AAAA key; rm -rf /"
        XCTAssertEqual(LocalSandbox.sudoArguments(.authorizeKey(line)).suffix(2), ["authorize-key", line])
    }

    func testDecodesHelperStatus() throws {
        // Verbatim shape of `longwave-sandbox status` on the dev Mac.
        let json = #"{"agentUser":"longwave-agent","agentUID":552,"ownerUser":"ixion","userExists":true,"guiSession":false,"tmuxSessions":0,"homeSizeKB":null,"goldenPresent":true,"goldenSnapshotAt":"2026-09-30T13:29:28Z","lastResetAt":null,"firewallWanted":false,"firewallAnchorLoaded":false,"pfEnabled":true,"daemonLoaded":true}"#
        let status = try LocalSandbox.decodeStatus(Data(json.utf8))
        XCTAssertEqual(status.agentUser, "longwave-agent")
        XCTAssertEqual(status.agentUID, 552)
        XCTAssertFalse(status.guiSession)
        XCTAssertNil(status.homeSizeKB)
        XCTAssertNil(status.lastResetAt)
        XCTAssertNotNil(LocalSandbox.parseTimestamp(status.goldenSnapshotAt))
        XCTAssertNil(LocalSandbox.parseTimestamp(nil))
    }

    func testPublicKeyPrecheck() {
        XCTAssertTrue(LocalSandbox.isAcceptablePublicKey("ssh-ed25519 AAAAC3Nz longwave"))
        XCTAssertTrue(LocalSandbox.isAcceptablePublicKey("ecdsa-sha2-nistp256 AAAAE2Vj"))
        XCTAssertFalse(LocalSandbox.isAcceptablePublicKey("ssh-rsa AAAAB3Nz"))
        XCTAssertFalse(LocalSandbox.isAcceptablePublicKey("command=\"x\" ssh-ed25519 AAAA"))
        XCTAssertFalse(LocalSandbox.isAcceptablePublicKey("ssh-ed25519"))
        XCTAssertFalse(LocalSandbox.isAcceptablePublicKey("ssh-ed25519 AAAA\nssh-ed25519 BBBB"))
    }

    // MARK: - Moving work in and out

    func testImportCreatesSharedBareRepoThenPushesBranch() {
        let repo = URL(fileURLWithPath: "/Users/me/Projects/My App")
        let cmds = LocalSandbox.importCommands(repo: repo, branch: "main")
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(cmds[0], ["init", "--bare", "--shared=group", "--initial-branch=main",
                                 "/Library/Longwave/exchange/My-App.git"])
        XCTAssertEqual(cmds[1], ["-C", "/Users/me/Projects/My App", "push",
                                 "/Library/Longwave/exchange/My-App.git", "HEAD:refs/heads/main"])
    }

    func testFetchBackOnlyFetches() {
        let repo = URL(fileURLWithPath: "/Users/me/p")
        let fresh = LocalSandbox.fetchBackCommands(repo: repo, bareRepo: "/Library/Longwave/exchange/p.git", remoteExists: false)
        XCTAssertEqual(fresh, [["-C", "/Users/me/p", "remote", "add", "sandbox", "/Library/Longwave/exchange/p.git"],
                               ["-C", "/Users/me/p", "fetch", "sandbox"]])
        let again = LocalSandbox.fetchBackCommands(repo: repo, bareRepo: "x", remoteExists: true)
        XCTAssertEqual(again, [["-C", "/Users/me/p", "fetch", "sandbox"]])
        // Nothing that would check out or run the agent's content.
        XCTAssertFalse((fresh + again).flatMap { $0 }.contains { ["pull", "merge", "checkout"].contains($0) })
    }

    func testSandboxCloneMarksExchangeSafeAndIsIdempotent() {
        let script = LocalSandbox.sandboxCloneScript(bareRepo: "My-App.git")
        XCTAssertTrue(script.contains("git config --global --add safe.directory '/Library/Longwave/exchange/*'"))
        XCTAssertTrue(script.contains("[ -d \"$HOME\"/'Projects/My-App'/.git ] || git clone -q '/Library/Longwave/exchange/My-App.git' \"$HOME\"/'Projects/My-App'"))
        XCTAssertTrue(script.hasSuffix("&& pwd"))
    }

    func testTerminalAttachCarriesNoSecretsAndAttachesExactly() {
        let cmd = LocalSandbox.terminalAttachCommand(keyPath: "/Users/me/.ssh/longwave_sandbox_ed25519",
                                                     agentUser: "longwave-agent", tmuxSession: "proj-codex")
        XCTAssertTrue(cmd.hasPrefix("exec /usr/bin/ssh -t -i '/Users/me/.ssh/longwave_sandbox_ed25519' -o IdentitiesOnly=yes"))
        XCTAssertTrue(cmd.contains("'longwave-agent'@127.0.0.1"))
        XCTAssertTrue(cmd.contains("tmux attach -d -t"))
        XCTAssertTrue(cmd.contains("=proj-codex"))
        // The attach step never carries environment (tokens went over stdin).
        for name in ["CLAUDE_CODE_OAUTH_TOKEN", "CODEX_", "COPILOT_GITHUB_TOKEN", "GH_TOKEN"] {
            XCTAssertFalse(cmd.contains(name), name)
        }
    }

    func testDeviceHubCommandIsFixedPath() {
        XCTAssertEqual(LocalSandbox.openDeviceHubCommand,
                       "/usr/bin/open -a '/Applications/Xcode.app/Contents/Applications/DeviceHub.app'")
    }

    // MARK: - Session discovery (shared with SSHTerminalManager)

    func testDiscoveryParsesTaggedAgentSessionsOnly() {
        let out = """
        Last login: banner line
        proj\t/Users/longwave-agent/Projects/proj\t1
        proj-codex\t/Users/longwave-agent/Projects/proj\t1
        vnc-shell\t/Users/longwave-agent\t1
        mine\t/tmp\t
        """
        let found = AgentSessionCommands.parseDiscoveredSessions(out)
        XCTAssertEqual(found.map(\.name), ["proj", "proj-codex"])
        XCTAssertEqual(found[1].title, "proj (Codex)")
        XCTAssertEqual(found[0].folder, "/Users/longwave-agent/Projects/proj")
    }

    func testBuildersAreIdenticalThroughEitherType() {
        XCTAssertEqual(AgentSessionCommands.attachCommand(tmuxSession: "x"),
                       SSHTerminalManager.attachCommand(tmuxSession: "x"))
        XCTAssertEqual(AgentSessionCommands.slug("A b/c"), SSHTerminalManager.slug("A b/c"))
    }

    // MARK: - OpenSSH private key file

    /// Throwaway key generated for this test (`ssh-keygen -t ed25519 -N ''`).
    private let ed25519PEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACCicqEopD3R1QnZ5Cg3LLmrnWfayZOfQveS3Lm21cI2ZgAAAJA0N6fhNDen
    4QAAAAtzc2gtZWQyNTUxOQAAACCicqEopD3R1QnZ5Cg3LLmrnWfayZOfQveS3Lm21cI2Zg
    AAAEB9sxAkLvaj3sS1f2OWBZfDZDeMzkJtnoii9mTpHw6ugKJyoSikPdHVCdnkKDcsuaud
    Z9rJk59C95LcubbVwjZmAAAAB2ZpeHR1cmUBAgMEBQY=
    -----END OPENSSH PRIVATE KEY-----
    """
    /// Its `.pub` blob.
    private let ed25519PublicBlob = "AAAAC3NzaC1lZDI1NTE5AAAAIKJyoSikPdHVCdnkKDcsuaudZ9rJk59C95LcubbVwjZm"

    func testParsesUnencryptedEd25519Key() throws {
        let seed = try OpenSSHPrivateKey.ed25519Seed(fromPEM: ed25519PEM)
        XCTAssertEqual(seed.count, 32)
        // The seed must regenerate exactly the public key in the .pub file.
        let derived = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let blob = try XCTUnwrap(Data(base64Encoded: ed25519PublicBlob))
        XCTAssertEqual(blob.suffix(32), derived)
        XCTAssertNoThrow(try OpenSSHPrivateKey.nioPrivateKey(fromPEM: ed25519PEM))
    }

    func testRejectsEncryptedAndOtherKeyTypes() {
        let encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC/H9FAPn
        DoRozFrpD04PVYAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDsKGCBEZnxMZDf3
        2xdvP4AstJtNNS780TsSW7t+kz5jAAAAkFaK4K7RqFAMmzGqPpLg+ffiBYsu9o7lX1bes4
        lTY1S+lrJfu7rIdNa5mwotzqfFSH1kJceD1VPnGI2kxIocD1eLswzyLEvgGQgr/Tv5tnTm
        4Mtkqexgg3a80u605Fy5NJiDeArD5Hwu+/1p4Vn8ry7KfggrlBqqFJQ6XMAsNFL5yCvhBk
        geJJ2Fsu17Xd4wzQ==
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHPrivateKey.ed25519Seed(fromPEM: encrypted)) {
            XCTAssertEqual($0 as? OpenSSHPrivateKey.ParseError, .encrypted)
        }
        let ecdsa = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQSATeahKKSJ8lSQM36MGASEx5xfXMUy
        XwBfTzfr1eojoVB4CYqizFV+YfPhGUGWimRX+T+jnJgVIYI+NNEPZqiyAAAAoO+enZrvnp
        2aAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIBN5qEopInyVJAz
        fowYBITHnF9cxTJfAF9PN+vV6iOhUHgJiqLMVX5h8+EZQZaKZFf5P6OcmBUhgj400Q9mqL
        IAAAAgDnFElnKi4sXK2bSsyA3dDXhK8kni/rzMyE6JQknXUu4AAAACZngBAgMEBQY=
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertThrowsError(try OpenSSHPrivateKey.ed25519Seed(fromPEM: ecdsa)) {
            XCTAssertEqual($0 as? OpenSSHPrivateKey.ParseError, .unsupportedKeyType("ecdsa-sha2-nistp256"))
        }
        XCTAssertThrowsError(try OpenSSHPrivateKey.ed25519Seed(fromPEM: "not a key"))
    }

    // MARK: - Unpersisted connection flags

    func testTokenFlagsRederivedFromKeychain() {
        let a = SavedConnection(hostname: "127.0.0.1", port: 22, label: "Local sandbox", connectionType: .ssh)
        a.setSSHAuthToken("gh-token", for: .copilot)
        defer { a.setSSHAuthToken(nil, for: .copilot) }
        // A fresh instance with the same id (how the Mac rebuilds the sandbox
        // connection each launch) starts with flags off…
        let b = SavedConnection(hostname: "127.0.0.1", port: 22, label: "Local sandbox", connectionType: .ssh)
        b.id = a.id
        XCTAssertFalse(b.hasToken(for: .copilot))
        // …until they're re-derived from the keychain.
        b.refreshTokenFlagsFromKeychain()
        XCTAssertTrue(b.hasToken(for: .copilot))
        XCTAssertFalse(b.hasToken(for: .claude))
        XCTAssertEqual(b.resolvedSSHEnvironment(for: .copilot).first { $0.name == "COPILOT_GITHUB_TOKEN" }?.value, "gh-token")
    }
}
