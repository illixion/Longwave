import Foundation
import Security

/// The pure half of the Mac Projects tab's local agent sandbox: the root
/// helper's argv and status JSON, and the git / ssh commands that move work in
/// and out of the sandbox account. Shared (not Mac-only) so it's unit-tested
/// with the rest; nothing here runs a process.
///
/// The sandbox itself is `scripts/agent-sandbox/` — a hidden standard user
/// (`longwave-agent`) the agents run as, reset from a golden home by a
/// fixed-verb root helper that only the owner may run via `sudo -n`.
enum LocalSandbox {
    static let helperPath = "/usr/local/libexec/longwave-sandbox"
    static let sudoPath = "/usr/bin/sudo"
    static let exchangeDir = "/Library/Longwave/exchange"
    static let defaultAgentUser = "longwave-agent"
    /// Generic-password item install.sh writes to the owner's login keychain.
    static let keychainService = "pro.longwave.sandbox"
    /// Owner-side SSH key install.sh generates and authorizes for the agent.
    static let keyFileName = "longwave_sandbox_ed25519"
    static let host = "127.0.0.1"
    static let sshPort = 22
    static let vncPort: UInt16 = 5900
    static let deviceHubPath = "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
    /// What the user runs to install (or repair) the sandbox.
    static let installCommand = "sudo scripts/agent-sandbox/install.sh"

    /// macOS protects another user's home folder from any process whose
    /// *responsible app* lacks Full Disk Access — root included. The helper runs
    /// under `sudo -n` from LongwaveMac, so LongwaveMac is the responsible app,
    /// and without the grant `reset` / `snapshot-golden` / `configure-desktop`
    /// fail inside `/Users/<agent>` ("Operation not permitted"; verified on
    /// macOS 27 — the same verbs work from a terminal that has the grant). The
    /// system TCC database is a file only FDA can open, which makes it the probe.
    static let fullDiskAccessProbePath = "/Library/Application Support/com.apple.TCC/TCC.db"
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// `NSHomeDirectory()` is the real home: LongwaveMac isn't app-sandboxed.
    static func keyURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent(".ssh").appendingPathComponent(keyFileName)
    }

    /// Verbs the helper accepts. The helper validates every argument itself;
    /// this just keeps the app from composing anything else.
    enum Verb: Equatable {
        case status, stop, reset, snapshotGolden
        /// Screen lock off, no screen saver, black wallpaper — needs the
        /// agent's GUI session and its password on **stdin** (never argv).
        case configureDesktop
        case firewall(on: Bool)
        case authorizeKey(String)

        var arguments: [String] {
            switch self {
            case .status: ["status"]
            case .stop: ["stop"]
            case .reset: ["reset"]
            case .snapshotGolden: ["snapshot-golden"]
            case .configureDesktop: ["configure-desktop"]
            case .firewall(let on): ["firewall", on ? "on" : "off"]
            case .authorizeKey(let line): ["authorize-key", line]
            }
        }
    }

    /// `sudo -n <helper> <verb…>` — a fixed argv for `Process`, never a shell
    /// string. `-n` makes a missing sudoers rule fail instead of prompting.
    static func sudoArguments(_ verb: Verb) -> [String] {
        ["-n", helperPath] + verb.arguments
    }

    /// `longwave-sandbox status` output.
    struct Status: Decodable, Equatable {
        var agentUser: String
        var agentUID: Int
        var ownerUser: String
        var userExists: Bool
        var guiSession: Bool
        var tmuxSessions: Int
        var homeSizeKB: Int?
        var goldenPresent: Bool
        var goldenSnapshotAt: String?
        var lastResetAt: String?
        var firewallWanted: Bool
        var firewallAnchorLoaded: Bool
        var pfEnabled: Bool
        var daemonLoaded: Bool
    }

    static func decodeStatus(_ data: Data) throws -> Status {
        try JSONDecoder().decode(Status.self, from: data)
    }

    /// The helper stamps state with `date -u +%Y-%m-%dT%H:%M:%SZ`.
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    /// Accepts exactly one public-key line of the kinds the helper takes, so
    /// the UI can reject junk before a sudo round-trip.
    static func isAcceptablePublicKey(_ line: String) -> Bool {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, !line.contains("\n") else { return false }
        return ["ssh-ed25519", "ecdsa-sha2-nistp256"].contains(String(parts[0]))
    }

    // MARK: - Moving work in and out

    /// Bare-repo name in the exchange dir for a local checkout.
    static func bareRepoName(forRepoAt repo: URL) -> String {
        AgentSessionCommands.slug(repo.lastPathComponent) + ".git"
    }

    static func bareRepoPath(named name: String) -> String {
        (exchangeDir as NSString).appendingPathComponent(name)
    }

    /// Where a project lives inside the sandbox home.
    static func sandboxProjectPath(forBareRepo name: String) -> String {
        "~/Projects/" + (name.hasSuffix(".git") ? String(name.dropLast(4)) : name)
    }

    /// Local `git` argv lists (run as the owner, in order) that publish
    /// `branch` of `repo` into a new shared bare repo in the exchange dir.
    /// `--shared=group` keeps objects group-writable so the agent (a member of
    /// the exchange group, whose setgid dir fixes the group) can push back.
    ///
    /// `--no-verify` skips pre-push hooks: this push copies work to a local
    /// directory on the same Mac, not to a remote, and a global pre-push hook
    /// that guards remotes (e.g. one refusing unsigned commits) otherwise
    /// blocks every import — verified on the dev Mac.
    static func importCommands(repo: URL, branch: String) -> [[String]] {
        let bare = bareRepoPath(named: bareRepoName(forRepoAt: repo))
        return [
            ["init", "--bare", "--shared=group", "--initial-branch=\(branch)", bare],
            ["-C", repo.path, "push", "--no-verify", bare, "HEAD:refs/heads/\(branch)"],
        ]
    }

    /// Local `git` argv lists that bring the sandbox's branches back as the
    /// `sandbox` remote — fetch only, so nothing of the agent's executes (hooks
    /// never travel with a fetch).
    static func fetchBackCommands(repo: URL, bareRepo: String, remoteExists: Bool) -> [[String]] {
        var cmds: [[String]] = []
        if !remoteExists { cmds.append(["-C", repo.path, "remote", "add", "sandbox", bareRepo]) }
        cmds.append(["-C", repo.path, "fetch", "sandbox"])
        return cmds
    }

    /// Runs inside the sandbox (over SSH, through `loginShellCommand`): clones
    /// the bare repo into `~/Projects/<name>` unless already there. The exchange
    /// repo is owned by the owner, so the agent's git needs it marked safe or
    /// every operation fails with "dubious ownership"; the setting is re-added
    /// here because a reset wipes the agent's global config.
    static func sandboxCloneScript(bareRepo name: String) -> String {
        let src = AgentSessionCommands.shellSingleQuote(bareRepoPath(named: name))
        let safe = AgentSessionCommands.shellSingleQuote(exchangeDir + "/*")
        let dest = sandboxProjectPath(forBareRepo: name)
        let destQ = "\"$HOME\"/" + AgentSessionCommands.shellSingleQuote(String(dest.dropFirst(2)))
        return "git config --global --get-all safe.directory 2>/dev/null | grep -qxF \(safe) "
            + "|| git config --global --add safe.directory \(safe); "
            + "mkdir -p \"$HOME/Projects\"; "
            + "[ -d \(destQ)/.git ] || git clone -q \(src) \(destQ); "
            + "cd \(destQ) && pwd"
    }

    /// The command Terminal.app runs to attach a sandbox tmux session. It
    /// carries no secret: the key is a file path and the attach step takes no
    /// environment (tokens went in through the create channel's stdin).
    static func terminalAttachCommand(keyPath: String, agentUser: String, tmuxSession: String) -> String {
        let q = AgentSessionCommands.shellSingleQuote
        return "exec /usr/bin/ssh -t -i \(q(keyPath)) -o IdentitiesOnly=yes -o IdentityAgent=none "
            + "-o StrictHostKeyChecking=accept-new \(q(agentUser))@\(host) "
            + q(AgentSessionCommands.attachCommand(tmuxSession: tmuxSession))
    }

    /// Opens Device Hub in the agent's GUI session: `open` run over SSH as the
    /// agent is routed by LaunchServices to that user's Aqua session.
    static var openDeviceHubCommand: String {
        "/usr/bin/open -a " + AgentSessionCommands.shellSingleQuote(deviceHubPath)
    }
}

// MARK: - Agent desktop

extension LocalSandbox {
    /// Opened by the Companion's "Sandbox Desktop"; Longwave for Mac handles it
    /// by showing the agent's desktop in its VNC viewer. Carries nothing secret.
    static let desktopURL = "longwave://sandbox-desktop"

    /// The agent's password, from the item install.sh wrote to the owner's login
    /// keychain (its ACL lists both Mac apps). Blocks while macOS shows a
    /// keychain access prompt, so call it off the main actor.
    nonisolated static func readAgentPassword(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
