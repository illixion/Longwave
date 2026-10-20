import Foundation

/// Claude Code's own credential file (`~/.claude/.credentials.json`), written
/// by the Companion for sandbox sessions instead of `CLAUDE_CODE_OAUTH_TOKEN`.
///
/// This is what lets a sandbox session outlive one ~8h access token without
/// the sandbox ever holding a refresh token. A running `claude` re-reads the
/// file once its in-memory token has expired (verified on CLI 2.1.304: a
/// session whose old token had stopped working picked up a rewritten one with
/// no 401 in between), so the Companion keeps the file current and every
/// session in the account follows. The environment variable can't do that: it
/// is fixed for a process's life, and while it is set the CLI keeps using it
/// rather than adopting the stored credential.
///
/// The CLI uses this file rather than the keychain because the sandbox's login
/// keychain is locked in its SSH sessions (`security show-keychain-info` exits
/// 36 there). The refresh token is written empty: Claude rotates refresh tokens
/// on use, and a CLI renewing from a copy would sign the Companion out.
enum ClaudeCredentialsFile {

    /// Carries the file's JSON over the create channel's stdin. The setup
    /// script consumes it, so it is never registered with tmux.
    static let envName = "LONGWAVE_CLAUDE_CREDENTIALS_JSON"

    /// Home-relative path the CLI reads.
    static let path = ".claude/.credentials.json"

    /// The variables an environment-authenticated session uses. Any of them
    /// left in a tmux server's environment from an older launch would win over
    /// the file, so the setup clears them.
    static let sessionEnvNames = [
        ClaudeOAuth.Constants.tokenEnvName,
        ClaudeOAuth.Constants.scopesEnvName,
        ClaudeOAuth.Constants.subscriptionTypeEnvName,
        ClaudeOAuth.Constants.rateLimitTierEnvName,
    ]

    /// Without a stated expiry the CLI should still come back for a new token
    /// regularly, so the file claims one this far out.
    static let unknownExpiryLifetime: TimeInterval = 60 * 60

    /// The file's contents for `credential`, in the CLI's own `claudeAiOauth`
    /// shape. `expiresAt` is in milliseconds, as the CLI stores it.
    static func json(for credential: ClaudeOAuth.Credential, now: Date = Date()) -> String? {
        let expiresAt = credential.expiresAt ?? now.addingTimeInterval(unknownExpiryLifetime)
        var oauth: [String: Any] = [
            "accessToken": credential.accessToken,
            "refreshToken": "",
            "expiresAt": Int64((expiresAt.timeIntervalSince1970 * 1000).rounded()),
            "scopes": credential.scopes,
        ]
        if let subscriptionType = credential.subscriptionType, !subscriptionType.isEmpty {
            oauth["subscriptionType"] = subscriptionType
        }
        if let rateLimitTier = credential.rateLimitTier, !rateLimitTier.isEmpty {
            oauth["rateLimitTier"] = rateLimitTier
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth],
                                                     options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes the file from `envName` and unsets it. Only builtins (`printf`,
    /// `[`, `unset`) touch the JSON, so it never appears in an argv; the write
    /// is atomic (temp file + `mv`) under `umask 077`.
    static let writeScript: String = {
        let dir = "\"$HOME/.claude\""
        let file = "\"$HOME/\(path)\""
        return "if [ -n \"$\(envName)\" ]; then "
            + "(umask 077; mkdir -p \(dir) && [ ! -L \(dir) ] || exit 1; "
            + "printf %s \"$\(envName)\" > \(file).longwave && "
            + "mv -f \(file).longwave \(file)) || exit 1; "
            + "fi; unset \(envName); "
    }()

    /// Clears `sessionEnvNames` from a running tmux server's global
    /// environment. Session environments drop them by themselves: the names are
    /// in `update-environment` from older launches and absent from this client.
    static let clearTmuxEnvironmentScript: String =
        sessionEnvNames.map { "tmux set-environment -gu \($0) >/dev/null 2>&1; " }.joined()

    /// The create-step setup for a session whose environment carries the file.
    static func sessionSetup(for environment: [(name: String, value: String)]) -> AgentSessionSetup? {
        guard environment.contains(where: { $0.name == envName }) else { return nil }
        return AgentSessionSetup(script: writeScript + clearTmuxEnvironmentScript,
                                 consumedNames: [envName])
    }

    /// Rewrites the file for sessions that are already running. Pair with
    /// `AgentSessionCommands.envPayload([(envName, json)])` on stdin.
    static var rewriteCommand: String {
        "/bin/sh -c " + AgentSessionCommands.shellSingleQuote(
            AgentSessionCommands.envStdinReader + writeScript + "echo \(writtenMarker)")
    }

    static let writtenMarker = "LONGWAVE_CLAUDE_CREDENTIALS_WRITTEN"

    /// Deletes the file, for a sign-out or before the home is snapshotted.
    static var removeCommand: String { "rm -f \"$HOME/\(path)\" \"$HOME/\(path).longwave\"" }
}
