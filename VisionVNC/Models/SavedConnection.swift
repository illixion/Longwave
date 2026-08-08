import SwiftData
import Foundation
import RoyalVNCKit

// MARK: - Connection Type

enum ConnectionType: String, CaseIterable, Codable {
    case vnc
    /// Streams from the VisionVNC Companion menu bar app: Screen (native
    /// window compositing) and Audio (system audio), toggled independently
    /// but sharing one host + token. Replaces the old, separate `macNative`
    /// and `audio` cases — see `SavedConnection.connectionType`'s getter for
    /// how existing rows using those raw values migrate.
    case native
    case ssh
    #if MOONLIGHT_ENABLED
    case moonlight
    #endif

    var label: String {
        switch self {
        case .vnc: "VNC"
        case .native: "Native"
        case .ssh: "SSH"
        #if MOONLIGHT_ENABLED
        case .moonlight: "Moonlight"
        #endif
        }
    }

    var systemImage: String {
        switch self {
        case .vnc: "display"
        case .native: "macwindow.on.rectangle"
        case .ssh: "terminal"
        #if MOONLIGHT_ENABLED
        case .moonlight: "gamecontroller"
        #endif
        }
    }

    /// Nominal only for `.native`: Screen and Audio each dial their own
    /// fixed Companion port (`MacNativeStreamProtocol`/`AudioStreamProtocol`
    /// `.defaultPort`), never a user-edited value.
    var defaultPort: Int {
        switch self {
        case .vnc: 5900
        case .native: Int(MacNativeStreamProtocol.defaultPort)
        case .ssh: 22
        #if MOONLIGHT_ENABLED
        case .moonlight: 47989
        #endif
        }
    }
}

// MARK: - Managed-session agent

/// A CLI coding agent the Projects tab can launch on a host over SSH. Each agent
/// authenticates headlessly via a long-lived token injected inline as an
/// environment variable (the macOS Keychain is unreachable over SSH). A host
/// stores a token per agent and remembers which one to launch by default.
enum SSHAgent: String, CaseIterable, Identifiable, Sendable {
    /// Claude Code — authenticates off `CLAUDE_CODE_OAUTH_TOKEN`, minted in-app
    /// by `ClaudeOAuth`'s PKCE flow (full session scopes, refreshed per launch).
    case claude
    /// GitHub Copilot CLI (`@github/copilot`) — auths off `COPILOT_GITHUB_TOKEN`
    /// (preferred over `GH_TOKEN`/`GITHUB_TOKEN` so it can't clobber other tools).
    case copilot
    /// Any other CLI: free-form command + token env-var name, set per host.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .copilot: "Copilot"
        case .custom: "Custom"
        }
    }

    /// SF Symbol for pickers / login rows.
    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .custom: "terminal"
        }
    }

    /// Built-in binary name. Empty for `.custom` (the user supplies it).
    var defaultCommand: String {
        switch self {
        case .claude: "claude"
        case .copilot: "copilot"
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
        case .copilot, .custom: []
        }
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
        case .custom: ""
        }
    }

    /// Title for the per-agent login/setup sheet.
    var setupTitle: String {
        switch self {
        case .claude: "Set up Claude"
        case .copilot: "Set up Copilot"
        case .custom: "Set up Token"
        }
    }

    /// Whether this agent supports the in-app GitHub OAuth device flow to mint
    /// its token (Copilot is a public GitHub App client). Others paste a token.
    var supportsDeviceFlow: Bool { self == .copilot }

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
        case .custom: ""
        }
    }

    /// Step-by-step instructions for obtaining the token, shown in the sheet.
    func setupInstructions(envName: String) -> String {
        switch self {
        case .claude:
            "Sign in below — VisionVNC opens Claude's consent page in-app, captures the credential on this headset, and injects it into each session as \(envName). It requests the full session scopes (including user:profile, so the agent can see which models your plan covers) and renews the token before each launch. The Mac's keychain is never touched."
        case .copilot:
            "Sign in with GitHub below — VisionVNC runs the device-authorization flow on this headset, captures the token, and injects it into each session as \(envName). The Mac's keychain is never touched. (Prefer a token? Paste a fine-grained PAT with the “Copilot Requests” permission instead — classic ghp_ tokens aren't supported.)"
        case .custom:
            "Paste the credential your CLI reads from \(envName). It's stored only on this device and injected into each session as that environment variable."
        }
    }
}

// MARK: - VNC Quality

/// Quality presets mapping to VNC color depth, JPEG quality, and compression level.
/// Note: 8-bit depth uses palettized color map mode which most modern
/// VNC servers (including macOS Screen Sharing) don't support, so the
/// lowest usable depth is 16-bit.
enum ConnectionQuality: Int, CaseIterable, Codable {
    case trackpadOnly = 0  // No video, transparent overlay for input only
    case low = 1           // 16-bit, aggressive JPEG compression
    case medium = 16       // 16-bit, balanced (was "low" before low tier existed)
    case high = 24         // 24-bit, full color

    var label: String {
        switch self {
        case .trackpadOnly: "Trackpad Only"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .trackpadOnly: "Transparent input overlay. Position over Mac Virtual Display for mouse and keyboard control."
        case .low: "16-bit, aggressive JPEG compression — lowest bandwidth"
        case .medium: "16-bit, balanced compression"
        case .high: "24-bit, full color — best quality"
        }
    }

    var vncColorDepth: VNCConnection.Settings.ColorDepth {
        switch self {
        case .trackpadOnly, .low, .medium: .depth16Bit
        case .high: .depth24Bit
        }
    }

    /// JPEG quality level for Tight encoding (0 = lowest, 9 = highest)
    var jpegQualityLevel: Int {
        switch self {
        case .trackpadOnly, .low: 2
        case .medium: 6
        case .high: 8
        }
    }

    /// Compression level (1 = lowest/fastest, 10 = highest/slowest)
    var compressionLevel: Int {
        switch self {
        case .trackpadOnly, .low: 9
        case .medium: 6
        case .high: 3
        }
    }
}

#if MOONLIGHT_ENABLED
// MARK: - Moonlight Enums

enum VideoCodecPreference: String, CaseIterable, Codable {
    case auto       // let server/client negotiate best option
    case h264
    case hevc
    case av1        // native AV1 OBU parsing via VideoToolbox

    var label: String {
        switch self {
        case .auto: "Auto"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        }
    }
}

enum AudioConfiguration: String, CaseIterable, Codable {
    case stereo     // 2ch
    case surround51 // 6ch
    case surround71 // 8ch
    case none       // no audio

    var label: String {
        switch self {
        case .stereo: "Stereo"
        case .surround51: "5.1 Surround"
        case .surround71: "7.1 Surround"
        case .none: "No Audio"
        }
    }

    var channelCount: Int {
        switch self {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        case .none: 0
        }
    }
}
#endif

// MARK: - Touch Mode

enum TouchMode: String, CaseIterable, Codable {
    case relative   // cursor-based, deltas — trackpad style
    case absolute   // direct screen coordinate mapping — tap where you want

    var label: String {
        switch self {
        case .relative: "Touchpad (Relative)"
        case .absolute: "Direct Touch (Absolute)"
        }
    }
}

// MARK: - Saved Connection Model

@Model
final class SavedConnection {
    var id: UUID
    var hostname: String
    var port: Int
    var label: String
    var lastConnected: Date?

    // Connection type discrimination
    var connectionTypeRawValue: String = ConnectionType.vnc.rawValue

    var connectionType: ConnectionType {
        get {
            // Rows saved before Screen/Audio merged into one `.native` type
            // still carry the old "macNative"/"audio" raw values on disk;
            // both read back as `.native` (see nativeScreenEnabled/
            // nativeAudioEnabled below for how the toggle infers from this).
            if connectionTypeRawValue == "macNative" || connectionTypeRawValue == "audio" {
                return .native
            }
            return ConnectionType(rawValue: connectionTypeRawValue) ?? .vnc
        }
        set { connectionTypeRawValue = newValue.rawValue }
    }

    // MARK: VNC-specific

    // Keep the original column name so lightweight migration works with existing stores
    @Attribute(originalName: "colorDepth")
    var qualityRawValue: Int = 24

    var autoLogin: Bool = false
    var savedUsername: String = ""
    var savedPassword: String = ""
    var vncTouchModeRawValue: String = TouchMode.relative.rawValue

    /// macOS only: hide the local (system) pointer while it's over the remote
    /// view, so only the remote's own cursor shows. Default false (show), safe
    /// for lightweight migration. Ignored on visionOS (no system cursor).
    var hideLocalCursor: Bool = false

    // MARK: Companion-specific (Native: Screen + Audio)

    /// Static auth token presented to the VisionVNC Companion, shared by both
    /// the Screen and Audio toggles of a `.native` connection. Renamed from
    /// `audioToken`; `originalName` keeps lightweight migration working.
    @Attribute(originalName: "audioToken")
    var companionToken: String = ""

    /// Backing storage for `nativeScreenEnabled`/`nativeAudioEnabled` — nil
    /// means "not explicitly set", so a legacy pre-merge row (saved as the
    /// old `macNative` or `audio` type) infers its one enabled toggle from
    /// which type it was until the connection is next edited and saved.
    var nativeScreenEnabledStorage: Bool?
    var nativeAudioEnabledStorage: Bool?

    /// Whether this Native connection streams the Mac's screen.
    var nativeScreenEnabled: Bool {
        get { nativeScreenEnabledStorage ?? (connectionTypeRawValue == "macNative") }
        set { nativeScreenEnabledStorage = newValue }
    }

    /// Whether this Native connection streams the Mac's system audio.
    var nativeAudioEnabled: Bool {
        get { nativeAudioEnabledStorage ?? (connectionTypeRawValue == "audio") }
        set { nativeAudioEnabledStorage = newValue }
    }

    /// Opt-in low-latency mode: carries PCM over UDP with a smaller jitter
    /// buffer (DTLS-encrypted) instead of TCP. Needs a clean LAN path. Default
    /// false so lightweight migration is safe and behavior is unchanged.
    var lowLatencyAudio: Bool = false

    /// On a VNC connection, the `id` of a saved **companion** (audio) connection
    /// to pair with the VNC session — it provides both the companion audio
    /// stream and, on the same host/token, the text-injection channel for the
    /// keyboard bypass. Lets the desktop run over an encrypted tunnel (e.g.
    /// Tailscale) while the companion runs on a different LAN host — the
    /// implicit same-hostname match can't express that. nil → fall back to the
    /// hostname match (or no companion). Renamed from `linkedAudioConnectionID`;
    /// `originalName` keeps lightweight migration of existing stores working.
    @Attribute(originalName: "linkedAudioConnectionID")
    var linkedCompanionConnectionID: UUID?

    // MARK: SSH-specific

    /// Username for SSH login. Auth is key-based — the device's Secure Enclave
    /// key is the credential. Default empty so lightweight migration is safe.
    var sshUsername: String = ""

    /// Remote command to run under the PTY. Empty → an interactive login shell
    /// (generic terminal). The Projects tab overrides this per launch to run
    /// `claude` in a chosen folder via tmux.
    var sshLaunchCommand: String = ""

    /// Managed-session client command (Projects tab). Empty → `claude`. Lets
    /// the same tmux-backed workflow drive a different CLI. Default empty so
    /// lightweight migration is safe.
    var sshClientCommand: String = ""

    /// Extra non-secret environment variables to inject over the (encrypted)
    /// SSH channel, `KEY=VALUE` one per line. Each name must be listed in the
    /// Mac's sshd `AcceptEnv`. The Claude auth token is handled separately
    /// (stored in the Keychain, not here). Default empty for safe migration.
    var sshEnvVars: String = ""

    /// Env var name the stored auth token is injected as. Empty →
    /// `CLAUDE_CODE_OAUTH_TOKEN` (Claude Code's headless credential — it's read
    /// before the macOS Keychain, which is unreachable in an SSH session).
    var sshAuthEnvName: String = ""

    /// Whether a **Claude** auth token is stored in the Keychain for this
    /// connection. The token *value* lives in `KeychainStore` (keyed by `id`),
    /// never in SwiftData; this is only a UI flag. Kept under its original name
    /// (no rename) so existing stores migrate without touching the column.
    /// Per-agent siblings below cover Copilot/Custom. Default false.
    var sshHasAuthToken: Bool = false

    /// UI flag: a **Copilot** token is stored in the Keychain. Default false.
    var sshHasCopilotToken: Bool = false

    /// UI flag: a **Custom**-agent token is stored in the Keychain. Default false.
    var sshHasCustomToken: Bool = false

    /// Which managed agent the Projects tab launches by default for this host.
    /// Empty → `.claude`. Remembered across launches; flippable before launch.
    var sshAgentRawValue: String = ""

    /// Hand managed Claude sessions the **refresh** token as well, so the CLI
    /// renews its own credential instead of living inside one access token's ~8h
    /// window.
    ///
    /// Default false, and that default is a security decision rather than
    /// conservatism: the access token expires in ~8h, which bounds the damage if
    /// anything on the host can read a process's environment, and a refresh token
    /// carries no such bound. Turning this on trades that boundary for sessions
    /// that don't need renewing at launch.
    var sshInjectClaudeRefreshToken: Bool = false

    /// Wrap terminal sessions in tmux so they survive connection drops
    /// (visionOS tracking loss suspends the app and kills the TCP link). Falls
    /// back to a plain shell at launch when tmux isn't installed on the host.
    /// Default true (with a default value so lightweight migration is safe).
    var sshUseTmux: Bool = true

    var quality: ConnectionQuality {
        get { ConnectionQuality(rawValue: qualityRawValue) ?? .high }
        set { qualityRawValue = newValue.rawValue }
    }

    var vncTouchMode: TouchMode {
        get { TouchMode(rawValue: vncTouchModeRawValue) ?? .relative }
        set { vncTouchModeRawValue = newValue.rawValue }
    }

    // MARK: SSH helpers

    private static let sshAuthTokenService = "com.illixion.VisionVNC.sshAuthToken"

    /// The remembered default agent for managed (Projects-tab) sessions.
    var sshAgent: SSHAgent {
        get { SSHAgent(rawValue: sshAgentRawValue) ?? .claude }
        set { sshAgentRawValue = newValue.rawValue }
    }

    /// Command launched in the project folder for `agent`. Built-ins use their
    /// fixed command line (binary + `SSHAgent.defaultFlags`); `.custom` uses the
    /// free-form `sshClientCommand` field, unflagged — its fallback is the bare
    /// `claude` binary, since flags belong to the agent the app knows it launched.
    func effectiveCommand(for agent: SSHAgent) -> String {
        switch agent {
        case .claude, .copilot:
            return agent.defaultLaunchCommand
        case .custom:
            return sshClientCommand.isEmpty ? SSHAgent.claude.defaultCommand : sshClientCommand
        }
    }

    /// Env-var name `agent`'s token is injected as. Built-ins use their fixed
    /// name; `.custom` uses the free-form `sshAuthEnvName` field.
    func effectiveEnvName(for agent: SSHAgent) -> String {
        switch agent {
        case .claude, .copilot:
            return agent.defaultEnvName
        case .custom:
            return sshAuthEnvName.isEmpty ? SSHAgent.claude.defaultEnvName : sshAuthEnvName
        }
    }

    // Back-compat conveniences (Custom agent's free-form fields).
    var effectiveSSHClientCommand: String { effectiveCommand(for: .custom) }
    var effectiveSSHAuthEnvName: String { effectiveEnvName(for: .custom) }

    /// Keychain account for `agent`'s token. Claude keeps the bare UUID (so
    /// tokens stored before multi-agent support are preserved untouched); other
    /// agents are suffixed.
    private func tokenAccount(_ agent: SSHAgent) -> String {
        agent == .claude ? id.uuidString : "\(id.uuidString).\(agent.rawValue)"
    }

    /// Whether a token sits in `agent`'s single keychain slot — the one the paste
    /// field writes (and, for Copilot, the device flow).
    ///
    /// Distinct from `hasToken(for:)`, which for Claude is also satisfied by an
    /// in-app OAuth credential. The paste UI must key off *this*, or a
    /// credential-only host shows a "stored token" it can't remove: the remove
    /// button would clear an empty slot and the flag would immediately re-light
    /// from the credential.
    func hasPastedToken(for agent: SSHAgent) -> Bool {
        !(sshAuthToken(for: agent) ?? "").isEmpty
    }

    /// Whether a token is stored for `agent` (the per-agent UI flag).
    func hasToken(for agent: SSHAgent) -> Bool {
        switch agent {
        case .claude: sshHasAuthToken
        case .copilot: sshHasCopilotToken
        case .custom: sshHasCustomToken
        }
    }

    private func setHasToken(_ present: Bool, for agent: SSHAgent) {
        switch agent {
        case .claude: sshHasAuthToken = present
        case .copilot: sshHasCopilotToken = present
        case .custom: sshHasCustomToken = present
        }
    }

    /// The stored token for `agent`, read from the Keychain (not SwiftData).
    func sshAuthToken(for agent: SSHAgent) -> String? {
        KeychainStore.get(service: Self.sshAuthTokenService, account: tokenAccount(agent))
    }

    /// Store (or clear) `agent`'s token in the Keychain and update its UI flag.
    /// An empty/nil value clears the stored secret.
    func setSSHAuthToken(_ value: String?, for agent: SSHAgent) {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(service: Self.sshAuthTokenService, account: tokenAccount(agent), value: v)
        // Clearing the pasted token doesn't mean Claude is unconfigured — an
        // in-app credential is a separate, sufficient way to be set up.
        let stillConfigured = !v.isEmpty
            || (agent == .claude && ClaudeCredentialStore.load(connectionID: id) != nil)
        setHasToken(stillConfigured, for: agent)
    }

    /// Back-compat alias for the Claude token (used by older call sites/tests).
    var sshAuthToken: String? {
        get { sshAuthToken(for: .claude) }
        set { setSSHAuthToken(newValue, for: .claude) }
    }

    /// Non-secret environment from the `sshEnvVars` lines (validated names).
    /// Used for generic terminal sessions; the auth token is **not** included
    /// here (it's a managed-Claude credential — see `resolvedSSHEnvironment`).
    func sshEnvironmentVariables() -> [(name: String, value: String)] {
        var env: [(name: String, value: String)] = []
        for raw in sshEnvVars.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard Self.isValidEnvName(name) else { continue }
            let value = String(line[line.index(after: eq)...])
            env.removeAll { $0.name == name }
            env.append((name: name, value: value))
        }
        return env
    }

    // MARK: In-app Claude credential (OAuth)

    /// Whether an in-app-minted OAuth credential (not just a pasted token) is
    /// stored for Claude on this host.
    var hasClaudeCredential: Bool {
        ClaudeCredentialStore.load(connectionID: id) != nil
    }

    /// The stored Claude credential, for showing granted scopes/expiry in the UI.
    var claudeCredential: ClaudeOAuth.Credential? {
        ClaudeCredentialStore.load(connectionID: id)
    }

    /// Persist a freshly minted credential and light up the same UI flag a pasted
    /// token sets, so every existing "is Claude set up?" check keeps working.
    func setClaudeCredential(_ credential: ClaudeOAuth.Credential) {
        ClaudeCredentialStore.save(credential, connectionID: id)
        setHasToken(true, for: .claude)
    }

    /// Remove the credential and revoke it upstream. The flag stays lit if a
    /// pasted token is still present — that's an independent way to be set up.
    func clearClaudeCredential() async {
        await ClaudeCredentialStore.revokeAndDelete(connectionID: id)
        let pasted = sshAuthToken(for: .claude) ?? ""
        setHasToken(!pasted.isEmpty, for: .claude)
    }

    /// The token to inject for `agent`, without touching the network. Claude
    /// prefers an in-app credential over a pasted one; everything else reads its
    /// single keychain slot as before.
    private func storedToken(for agent: SSHAgent) -> String? {
        if agent == .claude, let credential = ClaudeCredentialStore.load(connectionID: id) {
            return credential.accessToken
        }
        guard hasToken(for: agent) else { return nil }
        return sshAuthToken(for: agent)
    }

    /// Merges `additions` over `env`, last value winning per name, skipping any
    /// name that isn't a legal POSIX identifier (the shell assignment built in
    /// `SSHTerminalManager` depends on that).
    private static func merge(_ env: inout [(name: String, value: String)],
                              _ additions: [(name: String, value: String)]) {
        for addition in additions where isValidEnvName(addition.name) && !addition.value.isEmpty {
            env.removeAll { $0.name == addition.name }
            env.append(addition)
        }
    }

    /// Full environment for a managed session running `agent`: the non-secret
    /// vars plus whatever the agent needs to authenticate (which wins on
    /// conflict).
    ///
    /// An in-app Claude credential contributes **several** variables, not just the
    /// token — the CLI can't introspect a token handed to it via the environment,
    /// so it has to be told the granted scopes and the subscription tier
    /// separately or it assumes inference-only with no plan. See
    /// `ClaudeOAuth.Credential.sessionEnvironment(includeRefreshToken:)`.
    ///
    /// A **pasted** token deliberately gets none of that extra context: it's
    /// most likely a `setup-token` credential that really is inference-only, and
    /// asserting scopes it doesn't have would be a lie the CLI acts on.
    ///
    /// This is the offline view — it never refreshes. Launch paths should prefer
    /// `resolvedSSHEnvironmentRenewingCredentials(for:)` so a session doesn't
    /// start with an access token that's about to expire.
    func resolvedSSHEnvironment(for agent: SSHAgent) -> [(name: String, value: String)] {
        var env = sshEnvironmentVariables()
        if agent == .claude, let credential = ClaudeCredentialStore.load(connectionID: id) {
            Self.merge(&env, credential.sessionEnvironment(
                includeRefreshToken: sshInjectClaudeRefreshToken))
            return env
        }
        guard let token = storedToken(for: agent), !token.isEmpty else { return env }
        Self.merge(&env, [(name: effectiveEnvName(for: agent), value: token)])
        return env
    }

    /// Same as `resolvedSSHEnvironment(for:)`, but renews an in-app Claude
    /// credential first when it's close to expiring.
    ///
    /// Claude's full-scope tokens are short-lived (a custom expiry is refused for
    /// this scope set), so the working model is: mint a fresh access token
    /// immediately before `claude` reads it, and let the tmux idle reaper clear
    /// out sessions that outlive one. Refresh failures fall through to the stored
    /// credential rather than blocking the launch.
    ///
    /// With `sshInjectClaudeRefreshToken` on, the CLI renews itself and this
    /// pre-launch refresh stops being load-bearing — it's still done, since
    /// starting from a fresh token costs nothing.
    func resolvedSSHEnvironmentRenewingCredentials(for agent: SSHAgent) async -> [(name: String, value: String)] {
        guard agent == .claude, hasClaudeCredential else {
            return resolvedSSHEnvironment(for: agent)
        }
        var env = sshEnvironmentVariables()
        guard let credential = await ClaudeCredentialStore.validCredential(connectionID: id) else {
            return env
        }
        Self.merge(&env, credential.sessionEnvironment(
            includeRefreshToken: sshInjectClaudeRefreshToken))
        return env
    }

    /// Back-compat: the Claude session environment.
    func resolvedSSHEnvironment() -> [(name: String, value: String)] {
        resolvedSSHEnvironment(for: .claude)
    }

    /// POSIX environment-variable name (`[A-Za-z_][A-Za-z0-9_]*`). Guards the
    /// shell `NAME=value` assignment built in `SSHTerminalManager`.
    static func isValidEnvName(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.dropFirst().allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: Moonlight stored properties
    // IMPORTANT: All @Model stored properties MUST be outside #if blocks.
    // The @Model macro doesn't properly register properties inside #if,
    // causing "unknown key" crashes even on fresh install.
    // All use Optional so NULL is valid (lightweight migration safe).

    @Attribute(originalName: "moonlightBitrate")
    var moonlightBitrateStorage: Int?
    @Attribute(originalName: "moonlightFPS")
    var moonlightFPSStorage: Int?
    @Attribute(originalName: "moonlightResolutionWidth")
    var moonlightResolutionWidthStorage: Int?
    @Attribute(originalName: "moonlightResolutionHeight")
    var moonlightResolutionHeightStorage: Int?
    @Attribute(originalName: "moonlightVideoCodecRawValue")
    var moonlightVideoCodecRawValueStorage: String?
    @Attribute(originalName: "moonlightEnableHDR")
    var moonlightEnableHDRStorage: Bool?
    @Attribute(originalName: "moonlightUseFramePacing")
    var moonlightUseFramePacingStorage: Bool?
    @Attribute(originalName: "moonlightAudioConfigRawValue")
    var moonlightAudioConfigRawValueStorage: String?
    @Attribute(originalName: "moonlightPlayAudioOnPC")
    var moonlightPlayAudioOnPCStorage: Bool?
    @Attribute(originalName: "moonlightTouchModeRawValue")
    var moonlightTouchModeRawValueStorage: String?
    @Attribute(originalName: "moonlightMultiController")
    var moonlightMultiControllerStorage: Bool?
    @Attribute(originalName: "moonlightSwapABXY")
    var moonlightSwapABXYStorage: Bool?
    @Attribute(originalName: "moonlightOptimizeGameSettings")
    var moonlightOptimizeGameSettingsStorage: Bool?
    @Attribute(originalName: "moonlightShowStatsOverlay")
    var moonlightShowStatsOverlayStorage: Bool?

    #if MOONLIGHT_ENABLED
    // MARK: Moonlight computed properties (not persisted — safe inside #if)

    // Server identity (stored in UserDefaults, not SwiftData)
    var moonlightServerCert: Data? {
        get { UserDefaults.standard.data(forKey: "ml_cert_\(id.uuidString)") }
        set { UserDefaults.standard.set(newValue, forKey: "ml_cert_\(id.uuidString)") }
    }

    var moonlightUUID: String? {
        get { UserDefaults.standard.string(forKey: "ml_uuid_\(id.uuidString)") }
        set { UserDefaults.standard.set(newValue, forKey: "ml_uuid_\(id.uuidString)") }
    }

    // Nil-coalescing wrappers with defaults
    var moonlightBitrate: Int {
        get { moonlightBitrateStorage ?? 20000 }
        set { moonlightBitrateStorage = newValue }
    }

    var moonlightFPS: Int {
        get { moonlightFPSStorage ?? 60 }
        set { moonlightFPSStorage = newValue }
    }

    var moonlightResolutionWidth: Int {
        get { moonlightResolutionWidthStorage ?? 1920 }
        set { moonlightResolutionWidthStorage = newValue }
    }

    var moonlightResolutionHeight: Int {
        get { moonlightResolutionHeightStorage ?? 1080 }
        set { moonlightResolutionHeightStorage = newValue }
    }

    var moonlightVideoCodecRawValue: String {
        get { moonlightVideoCodecRawValueStorage ?? VideoCodecPreference.auto.rawValue }
        set { moonlightVideoCodecRawValueStorage = newValue }
    }
    var moonlightEnableHDR: Bool {
        get { moonlightEnableHDRStorage ?? false }
        set { moonlightEnableHDRStorage = newValue }
    }
    var moonlightUseFramePacing: Bool {
        get { moonlightUseFramePacingStorage ?? false }
        set { moonlightUseFramePacingStorage = newValue }
    }
    var moonlightPlayAudioOnPC: Bool {
        get { moonlightPlayAudioOnPCStorage ?? false }
        set { moonlightPlayAudioOnPCStorage = newValue }
    }
    var moonlightMultiController: Bool {
        get { moonlightMultiControllerStorage ?? true }
        set { moonlightMultiControllerStorage = newValue }
    }
    var moonlightSwapABXY: Bool {
        get { moonlightSwapABXYStorage ?? false }
        set { moonlightSwapABXYStorage = newValue }
    }
    var moonlightOptimizeGameSettings: Bool {
        get { moonlightOptimizeGameSettingsStorage ?? true }
        set { moonlightOptimizeGameSettingsStorage = newValue }
    }
    var moonlightShowStatsOverlay: Bool {
        get { moonlightShowStatsOverlayStorage ?? false }
        set { moonlightShowStatsOverlayStorage = newValue }
    }

    var moonlightVideoCodec: VideoCodecPreference {
        get { VideoCodecPreference(rawValue: moonlightVideoCodecRawValue) ?? .auto }
        set { moonlightVideoCodecRawValue = newValue.rawValue }
    }

    var moonlightAudioConfig: AudioConfiguration {
        get { AudioConfiguration(rawValue: moonlightAudioConfigRawValueStorage ?? AudioConfiguration.stereo.rawValue) ?? .stereo }
        set { moonlightAudioConfigRawValueStorage = newValue.rawValue }
    }

    var moonlightTouchMode: TouchMode {
        get { TouchMode(rawValue: moonlightTouchModeRawValueStorage ?? TouchMode.relative.rawValue) ?? .relative }
        set { moonlightTouchModeRawValueStorage = newValue.rawValue }
    }

    var moonlightResolutionLabel: String {
        let w = moonlightResolutionWidth
        let h = moonlightResolutionHeight
        switch (w, h) {
        case (1280, 720): return "720p"
        case (1920, 1080): return "1080p"
        case (2560, 1440): return "1440p"
        case (3840, 2160): return "4K"
        default: return "\(w)×\(h)"
        }
    }
    #endif

    // MARK: Init

    init(hostname: String, port: Int = 5900, label: String = "", quality: ConnectionQuality = .high, connectionType: ConnectionType = .vnc) {
        self.id = UUID()
        self.hostname = hostname
        self.port = port
        self.label = label.isEmpty ? "\(hostname):\(port)" : label
        self.qualityRawValue = quality.rawValue
        self.lastConnected = nil
        self.autoLogin = false
        self.savedUsername = ""
        self.savedPassword = ""
        self.connectionTypeRawValue = connectionType.rawValue
    }

    var displayName: String {
        label.isEmpty ? "\(hostname):\(port)" : label
    }

    #if MOONLIGHT_ENABLED
    // MARK: Bitrate Helpers

    /// Suggested bitrate (kbps) based on resolution and FPS
    static func suggestedBitrate(width: Int, height: Int, fps: Int) -> Int {
        let pixels = width * height
        let base: Int
        switch pixels {
        case ..<921_600:   base = 5000    // 720p -> 5 Mbps
        case ..<2_073_600: base = 10000   // 1080p -> 10 Mbps
        case ..<3_686_400: base = 20000   // 1440p -> 20 Mbps
        default:           base = 40000   // 4K -> 40 Mbps
        }
        return fps > 60 ? base * 2 : (fps > 30 ? base : base / 2)
    }

    /// Recalculates bitrate based on current resolution and FPS settings
    func recalculateBitrate() {
        moonlightBitrate = Self.suggestedBitrate(
            width: moonlightResolutionWidth,
            height: moonlightResolutionHeight,
            fps: moonlightFPS
        )
    }
    #endif
}
