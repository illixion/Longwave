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
    /// Sandbox processes never receive the owner's refresh credential. Ignore
    /// an older preference or a shared login sheet trying to enable delegation.
    var sshInjectClaudeRefreshToken: Bool { get { false } set {} }
    var allowsRefreshTokenDelegation: Bool { false }

    func credentialSetupInstructions(for agent: SSHAgent) -> String {
        let common = "The login is stored in the Companion's Keychain on this Mac. Mobile Projects clients control sessions without receiving agent credentials. "
        switch agent {
        case .claude, .codex:
            return common + "Sign in below. The Companion renews access tokens before launch; refresh tokens stay here. The access token is still readable by code running as the sandbox account."
        case .copilot, .custom:
            return common + "Sign in or paste a token below. The token is passed to the sandbox CLI at launch and is readable by code running as that account. Its lifetime is determined by the provider."
        }
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
        defaults.removeObject(forKey: Keys.injectRefresh)
    }

    /// Everything persists as it changes; nothing to flush.
    func persistCredentialChanges() {}

    private func store(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
