import Foundation

/// Keychain service for pasted per-agent tokens. Unchanged from when this code
/// lived on `SavedConnection`, so tokens stored by earlier builds keep resolving.
private let agentTokenService = "pro.longwave.sshAuthToken"

/// Environment-variable rules shared by every agent launch path.
enum AgentEnvironment {
    /// POSIX environment-variable name (`[A-Za-z_][A-Za-z0-9_]*`). Guards the
    /// shell `NAME=value` assignment built for each managed session.
    static func isValidEnvName(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.dropFirst().allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }
}

/// Something that holds per-agent credentials and builds a managed session's
/// environment from them: a saved SSH host (`SavedConnection`) on the clients,
/// the agent sandbox's account in the Companion.
///
/// Token *values* live in the keychain keyed by `id`; the `sshHas…` flags are
/// only UI state mirroring what's stored. Everything except the stored
/// properties is provided below, so every host resolves tokens, Claude/Codex
/// credentials and session setup the same way.
protocol AgentCredentialHost: AnyObject {
    var id: UUID { get }
    var displayName: String { get }

    /// Free-form command line and token env-var name for `.custom`.
    var sshClientCommand: String { get set }
    var sshAuthEnvName: String { get set }
    /// Extra non-secret `KEY=VALUE` lines injected into each session.
    var sshEnvVars: String { get set }
    /// Hand Claude sessions the refresh token too (off by default — see
    /// `SavedConnection.sshInjectClaudeRefreshToken`).
    var sshInjectClaudeRefreshToken: Bool { get set }

    var sshHasAuthToken: Bool { get set }
    var sshHasCopilotToken: Bool { get set }
    var sshHasCustomToken: Bool { get set }
    var sshHasCodexToken: Bool { get set }

    /// Persists the non-secret state above after a credential change (a
    /// SwiftData save for `SavedConnection`).
    func persistCredentialChanges()
}

extension AgentCredentialHost {
    /// Command launched in the project folder for `agent`. Built-ins use their
    /// fixed command line (binary + `SSHAgent.defaultFlags`); `.custom` uses the
    /// free-form `sshClientCommand` field, unflagged — its fallback is the bare
    /// `claude` binary, since flags belong to the agent the app knows it launched.
    func effectiveCommand(for agent: SSHAgent) -> String {
        switch agent {
        case .claude, .copilot, .codex:
            return agent.defaultLaunchCommand
        case .custom:
            return sshClientCommand.isEmpty ? SSHAgent.claude.defaultCommand : sshClientCommand
        }
    }

    /// Env-var name `agent`'s token is injected as. Built-ins use their fixed
    /// name; `.custom` uses the free-form `sshAuthEnvName` field.
    func effectiveEnvName(for agent: SSHAgent) -> String {
        switch agent {
        case .claude, .copilot, .codex:
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
    fileprivate func tokenAccount(_ agent: SSHAgent) -> String {
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
        case .codex: sshHasCodexToken
        case .custom: sshHasCustomToken
        }
    }

    fileprivate func setHasToken(_ present: Bool, for agent: SSHAgent) {
        switch agent {
        case .claude: sshHasAuthToken = present
        case .copilot: sshHasCopilotToken = present
        case .codex: sshHasCodexToken = present
        case .custom: sshHasCustomToken = present
        }
    }

    /// The stored token for `agent`, read from the Keychain (not SwiftData).
    func sshAuthToken(for agent: SSHAgent) -> String? {
        KeychainStore.get(service: agentTokenService, account: tokenAccount(agent))
    }

    /// Store (or clear) `agent`'s token in the Keychain and update its UI flag.
    /// An empty/nil value clears the stored secret.
    func setSSHAuthToken(_ value: String?, for agent: SSHAgent) {
        let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(service: agentTokenService, account: tokenAccount(agent), value: v)
        // Clearing the pasted token doesn't mean Claude/Codex is unconfigured —
        // an in-app credential is a separate, sufficient way to be set up.
        let stillConfigured = !v.isEmpty
            || (agent == .claude && ClaudeCredentialStore.load(connectionID: id) != nil)
            || (agent == .codex && CodexCredentialStore.load(connectionID: id) != nil)
        setHasToken(stillConfigured, for: agent)
    }

    /// Re-derive every agent's "configured" flag from the keychain. A
    /// connection that isn't persisted in SwiftData — the Mac's local agent
    /// sandbox, a fixed-UUID instance rebuilt each launch — would otherwise
    /// start with all flags false while its tokens are still in the keychain,
    /// and `storedToken(for:)` ignores a pasted token whose flag is off.
    func refreshTokenFlagsFromKeychain() {
        for agent in SSHAgent.allCases {
            let present = hasPastedToken(for: agent)
                || (agent == .claude && ClaudeCredentialStore.load(connectionID: id) != nil)
                || (agent == .codex && CodexCredentialStore.load(connectionID: id) != nil)
            setHasToken(present, for: agent)
        }
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

    // MARK: In-app Codex credential (ChatGPT device sign-in)

    var hasCodexCredential: Bool {
        CodexCredentialStore.load(connectionID: id) != nil
    }

    var codexCredential: CodexOAuth.Credential? {
        CodexCredentialStore.load(connectionID: id)
    }

    func setCodexCredential(_ credential: CodexOAuth.Credential) {
        CodexCredentialStore.save(credential, connectionID: id)
        setHasToken(true, for: .codex)
    }

    /// Remove the credential and revoke it upstream; the flag stays lit if a
    /// pasted token is still present.
    func clearCodexCredential() async {
        await CodexCredentialStore.revokeAndDelete(connectionID: id)
        let pasted = sshAuthToken(for: .codex) ?? ""
        setHasToken(!pasted.isEmpty, for: .codex)
    }

    /// The token to inject for `agent`, without touching the network. Claude
    /// prefers an in-app credential over a pasted one; everything else reads its
    /// single keychain slot as before. (A Codex credential isn't a token in this
    /// sense — it's delivered as `auth.json`, see `resolvedSSHEnvironment`.)
    fileprivate func storedToken(for agent: SSHAgent) -> String? {
        if agent == .claude, let credential = ClaudeCredentialStore.load(connectionID: id) {
            return credential.accessToken
        }
        guard hasToken(for: agent) else { return nil }
        return sshAuthToken(for: agent)
    }

    /// Merges `additions` over `env`, last value winning per name, skipping any
    /// name that isn't a legal POSIX identifier (the shell assignment built in
    /// `SSHTerminalManager` depends on that).
    fileprivate static func merge(_ env: inout [(name: String, value: String)],
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
        // A ChatGPT credential wins over a pasted PAT, and replaces it rather
        // than joining it: the CLI prefers `CODEX_ACCESS_TOKEN` over `auth.json`,
        // so injecting both would silently run the session on the PAT.
        if agent == .codex, let credential = CodexCredentialStore.load(connectionID: id) {
            Self.merge(&env, credential.sessionEnvironment())
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
        if agent == .codex, hasCodexCredential {
            var env = sshEnvironmentVariables()
            if let credential = await CodexCredentialStore.validCredential(connectionID: id) {
                Self.merge(&env, credential.sessionEnvironment())
            }
            return env
        }
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

    /// The create-step setup a session running `agent` with `environment`
    /// needs, if any — today only a Codex ChatGPT credential, which must be
    /// written to `auth.json` because the CLI reads it from no variable.
    func sessionSetup(for agent: SSHAgent,
                      environment: [(name: String, value: String)]) -> AgentSessionSetup? {
        agent == .codex ? CodexOAuth.sessionSetup(for: environment) : nil
    }

    /// Back-compat: the Claude session environment.
    func resolvedSSHEnvironment() -> [(name: String, value: String)] {
        resolvedSSHEnvironment(for: .claude)
    }

    /// POSIX environment-variable name — see `AgentEnvironment.isValidEnvName`.
    static func isValidEnvName(_ s: String) -> Bool { AgentEnvironment.isValidEnvName(s) }
}
