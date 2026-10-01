import Foundation
import Observation

/// The agent sandbox's credentials: what a `SavedConnection` is to an SSH host,
/// without SwiftData. Token values live in this app's keychain keyed by `id`,
/// exactly as a saved connection's do (`AgentCredentialHost`); the `sshHas…`
/// flags are re-derived from the keychain at launch, and the few non-secret
/// settings persist in UserDefaults.
@Observable
final class SandboxAgentAccount: AgentCredentialHost {
    let id: UUID
    var displayName: String { "the agent sandbox" }

    var sshClientCommand: String { didSet { store(sshClientCommand, Keys.clientCommand) } }
    var sshAuthEnvName: String { didSet { store(sshAuthEnvName, Keys.authEnvName) } }
    var sshEnvVars: String { didSet { store(sshEnvVars, Keys.envVars) } }
    var sshInjectClaudeRefreshToken: Bool {
        didSet { UserDefaults.standard.set(sshInjectClaudeRefreshToken, forKey: Keys.injectRefresh) }
    }

    var sshHasAuthToken = false
    var sshHasCopilotToken = false
    var sshHasCustomToken = false
    var sshHasCodexToken = false

    private enum Keys {
        static let clientCommand = "sandboxAccount.clientCommand"
        static let authEnvName = "sandboxAccount.authEnvName"
        static let envVars = "sandboxAccount.envVars"
        static let injectRefresh = "sandboxAccount.injectClaudeRefreshToken"
    }

    init(id: UUID) {
        self.id = id
        let defaults = UserDefaults.standard
        sshClientCommand = defaults.string(forKey: Keys.clientCommand) ?? ""
        sshAuthEnvName = defaults.string(forKey: Keys.authEnvName) ?? ""
        sshEnvVars = defaults.string(forKey: Keys.envVars) ?? ""
        sshInjectClaudeRefreshToken = defaults.bool(forKey: Keys.injectRefresh)
    }

    /// Everything persists as it changes; nothing to flush.
    func persistCredentialChanges() {}

    private func store(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
