import Foundation

// MARK: - Managed-session agent

/// A CLI coding agent the Projects tab can launch on a host over SSH. Each agent
/// authenticates headlessly from credentials this device injects per session
/// (the macOS Keychain is unreachable over SSH) — an environment variable for
/// most, an `auth.json` for Codex's ChatGPT sign-in. A host stores a token per
/// agent and remembers which one to launch by default.
enum SSHAgent: String, CaseIterable, Identifiable, Sendable {
    /// Claude Code — authenticates off `CLAUDE_CODE_OAUTH_TOKEN`, minted in-app
    /// by `ClaudeOAuth`'s PKCE flow (full session scopes, refreshed per launch).
    case claude
    /// GitHub Copilot CLI (`@github/copilot`) — auths off `COPILOT_GITHUB_TOKEN`
    /// (preferred over `GH_TOKEN`/`GITHUB_TOKEN` so it can't clobber other tools).
    case copilot
    /// OpenAI Codex CLI — signed in with ChatGPT through the CLI's own device
    /// flow (`CodexOAuth`), delivered as a session-only `auth.json`; a pasted
    /// personal access token rides as `CODEX_ACCESS_TOKEN` instead.
    case codex
    /// Any other CLI: free-form command + token env-var name, set per host.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .copilot: "Copilot"
        case .codex: "Codex"
        case .custom: "Custom"
        }
    }

    /// SF Symbol for pickers / login rows.
    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .codex: "curlybraces"
        case .custom: "terminal"
        }
    }

    /// Built-in binary name. Empty for `.custom` (the user supplies it).
    var defaultCommand: String {
        switch self {
        case .claude: "claude"
        case .copilot: "copilot"
        case .codex: "codex"
        case .custom: ""
        }
    }

    /// Flags appended to `defaultCommand` for built-in agents.
    ///
    /// Claude gets `--allow-dangerously-skip-permissions`, deliberately **not**
    /// `--dangerously-skip-permissions`: the former only *unlocks* bypass mode in
    /// the Shift+Tab cycle, leaving the session in its normal default (auto) mode,
    /// while the latter starts the session in bypass outright. A managed headset
    /// session is exactly where the difference matters — approving each permission
    /// prompt through a floating terminal is the worst part of driving an agent
    /// from Vision Pro, but silently starting every session with all checks off is
    /// not the trade to make on the user's behalf. This way one Shift+Tab reaches
    /// bypass when the user wants it, and nothing changes until they ask.
    ///
    /// Only built-ins are flagged: `.custom` is a free-form command line the user
    /// owns, so it's passed through verbatim.
    var defaultFlags: [String] {
        switch self {
        case .claude: ["--allow-dangerously-skip-permissions"]
        case .copilot, .codex, .custom: []
        }
    }

    /// Flags for a session inside the macOS agent sandbox (LongwaveMac's local
    /// Projects), where the separate, resettable account is the security
    /// boundary: every CLI starts with its own prompts and sandbox fully off.
    /// Codex's Seatbelt sandbox would also break xcodebuild and the simulators.
    /// Never used for SSH hosts — those are the user's real accounts, which keep
    /// `defaultFlags`. `.custom` stays verbatim, as above.
    var sandboxFlags: [String] {
        switch self {
        case .claude: ["--dangerously-skip-permissions"]
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .copilot: ["--allow-all"]
        case .custom: []
        }
    }

    /// Launch command line for the macOS agent sandbox (binary + `sandboxFlags`).
    var sandboxLaunchCommand: String {
        ([defaultCommand] + sandboxFlags)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Full built-in launch command line (binary + `defaultFlags`).
    var defaultLaunchCommand: String {
        ([defaultCommand] + defaultFlags)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Built-in env-var name the token is injected as. Empty for `.custom`.
    var defaultEnvName: String {
        switch self {
        case .claude: "CLAUDE_CODE_OAUTH_TOKEN"
        case .copilot: "COPILOT_GITHUB_TOKEN"
        // The paste path only: a personal access token (`at-…`). A ChatGPT
        // sign-in can't use this variable — see `CodexOAuth`.
        case .codex: "CODEX_ACCESS_TOKEN"
        case .custom: ""
        }
    }

    /// Title for the per-agent login/setup sheet.
    var setupTitle: String {
        switch self {
        case .claude: "Set up Claude"
        case .copilot: "Set up Copilot"
        case .codex: "Set up Codex"
        case .custom: "Set up Token"
        }
    }

    /// Whether this agent signs in through an in-app device-code flow: GitHub's
    /// for Copilot (a public GitHub App client), OpenAI's for Codex (the CLI's
    /// public ChatGPT client). Others paste a token.
    var supportsDeviceFlow: Bool { self == .copilot || self == .codex }

    /// Whether this agent can be signed in through the in-app browser
    /// (authorization code + PKCE, see `ClaudeOAuth`). Claude Code's OAuth client
    /// is public, so the headset can run the whole flow itself and mint a token
    /// with the full session scope set — including `user:profile`, which
    /// `claude setup-token` withholds and without which the agent can't read the
    /// account's model entitlements.
    var supportsWebOAuth: Bool { self == .claude }

    /// Slug component that distinguishes this agent's managed sessions for the
    /// same folder. Claude is bare (so tmux sessions / `SSHSessionID`s created
    /// before multi-agent support keep working, mirroring `tokenAccount`); the
    /// others are suffixed so switching agent gives a distinct tmux session
    /// rather than re-attaching the one still running the previous agent.
    var sessionKey: String {
        switch self {
        case .claude: ""
        case .copilot: "copilot"
        case .codex: "codex"
        case .custom: "custom"
        }
    }

    /// The command the user runs on the Mac to mint a token (shown monospaced).
    /// Empty when an in-app flow replaces it.
    var tokenGenerateCommand: String {
        switch self {
        // Claude used to send the user to `claude setup-token` on the Mac. The
        // in-app sign-in replaces it outright: same browser consent, but it runs
        // on the headset, asks for the full scope set instead of inference-only,
        // and lands the credential in this device's keychain without a copy-paste
        // step.
        case .claude: ""
        case .copilot: ""
        case .codex: ""
        case .custom: ""
        }
    }

    /// Step-by-step instructions for obtaining the token, shown in the sheet.
    func setupInstructions(envName: String) -> String {
        switch self {
        case .claude:
            "Sign in below — Longwave opens Claude's consent page in-app, captures the credential on this headset, and injects it into each session as \(envName). It requests the full session scopes (including user:profile, so the agent can see which models your plan covers) and renews the token before each launch. The Mac's keychain is never touched."
        case .copilot:
            "Sign in with GitHub below — Longwave runs the device-authorization flow on this headset, captures the token, and injects it into each session as \(envName). The Mac's keychain is never touched. (Prefer a token? Paste a fine-grained PAT with the “Copilot Requests” permission instead — classic ghp_ tokens aren't supported.)"
        case .codex:
            "Sign in with ChatGPT below — Longwave runs Codex's device sign-in on this headset and keeps the credential here. Each session gets its own auth.json (in ~/\(CodexOAuth.Constants.sessionHomeDirectory) on the host, so your own Codex login there is untouched) without the refresh token, which never leaves this device; the token is renewed before a launch when under a day remains. (Prefer a token? Paste a ChatGPT personal access token, injected as \(envName).)"
        case .custom:
            "Paste the credential your CLI reads from \(envName). It's stored only on this device and injected into each session as that environment variable."
        }
    }
}

/// Extra work a managed session's create step does after its environment has
/// been exported and before tmux starts — the hook for credentials a CLI only
/// reads from a file (Codex's `auth.json`, see `CodexOAuth.sessionSetup`).
///
/// `consumedNames` are variables the script reads and unsets: they travel over
/// the stdin channel like any token but are never registered with tmux, so the
/// agent never sees them. `exportedNames` are variables the script sets that
/// tmux must import into the session.
struct AgentSessionSetup: Sendable, Equatable {
    var script: String
    var exportedNames: [String] = []
    var consumedNames: Set<String> = []
}
