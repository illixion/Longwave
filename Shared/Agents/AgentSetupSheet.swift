import SwiftUI
#if !os(macOS)
import RAVEUI
#endif

/// Gives a host a per-agent login that works over SSH. The macOS Keychain is
/// locked outside the desktop session, so each agent instead gets a long-lived
/// token that Longwave injects into every session as its env var (see
/// `AgentCredentialHost.resolvedSSHEnvironment(for:)`) — stored only on this device,
/// never written to the Mac. Claude signs in through the in-app browser
/// (`ClaudeOAuth`), Copilot and Codex through device-code flows
/// (`AgentDeviceSignIn`), and any of them can paste a token instead.
struct AgentSetupSheet<Host: AgentCredentialHost & Observable>: View {
    @Bindable var host: Host
    let agent: SSHAgent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var token = ""

    // Device-flow state (Copilot, Codex).
    @State private var deviceCode: DeviceSignInPrompt?
    @State private var flowTask: Task<Void, Never>?
    @State private var flowError: String?
    @State private var signingIn = false

    // In-app browser OAuth state (Claude).
    @State private var showingWebLogin = false
    @State private var showingCodexWebLogin = false
    /// Mirrors the stored credential for display. Held in view state rather than
    /// read inline because it lives in the keychain, not SwiftData — no
    /// observation would fire when it changes, so sign-in/out refresh it by hand.
    @State private var claudeCredential: ClaudeOAuth.Credential?
    @State private var claudeCredentialSummary: String?
    /// Same, for a Codex ChatGPT credential.
    @State private var codexCredentialSummary: String?

    private var envName: String { host.effectiveEnvName(for: agent) }

    var body: some View {
        Form {
            Section {
                Text(host.credentialSetupInstructions(for: agent))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let flowError { Text(flowError).foregroundStyle(.red).font(.caption) }

            if agent.supportsWebOAuth {
                webOAuthSection
            }

            if agent.supportsDeviceFlow {
                deviceFlowSection
            }

            if !agent.tokenGenerateCommand.isEmpty {
                Section("Generate a token on the Mac") {
                    Text("In Terminal on the Mac, run once:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(agent.tokenGenerateCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section(agent.supportsDeviceFlow || agent.supportsWebOAuth ? "Or paste a token" : "Paste the token") {
                SecureField(envName, text: $token)
                    #if !os(macOS)
                    .textFieldTapTarget()
                    #endif
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif

                // Keyed on the pasted slot specifically, not `hasToken`: for Claude
                // that flag is also satisfied by an in-app credential, which this
                // button can't remove — it would clear an empty slot and the flag
                // would re-light from the credential, so the row appeared to be a
                // stored token you couldn't get rid of. Signing out is what removes
                // a credential.
                if host.hasPastedToken(for: agent) {
                    Label("A pasted token is stored on this device for \(host.displayName).", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Remove Pasted Token", role: .destructive) {
                        guard host.setSSHAuthToken(nil, for: agent) else {
                            flowError = "Couldn't remove the token from Keychain."; return
                        }
                        host.persistCredentialChanges()
                        token = ""
                    }
                }
            }
        }
        .navigationTitle(agent.setupTitle)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard host.setSSHAuthToken(token, for: agent) else {
                        flowError = "Couldn't save the token in Keychain."; return
                    }
                    host.persistCredentialChanges()
                    dismiss()
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { reloadClaudeCredential(); reloadCodexCredential(); renewStaleClaudeCredential() }
        .onDisappear { flowTask?.cancel() }
        .sheet(isPresented: $showingWebLogin) {
            ClaudeLoginSheet { credential in
                guard host.setClaudeCredential(credential) else {
                    flowError = "Couldn't save the Claude login in Keychain. Sign in again after checking Keychain access."; return
                }
                host.persistCredentialChanges()
                reloadClaudeCredential()
            }
        }
        .sheet(isPresented: $showingCodexWebLogin) {
            CodexLoginSheet { credential in
                guard host.setCodexCredential(credential) else {
                    flowError = "Couldn't save the Codex login in Keychain. Sign in again after checking Keychain access."; return
                }
                host.persistCredentialChanges()
                reloadCodexCredential()
            }
        }
    }

    @ViewBuilder
    private var webOAuthSection: some View {
        Section("Sign in with Claude") {
            Button {
                showingWebLogin = true
            } label: {
                Label(claudeCredential == nil ? "Sign In with Claude" : "Sign In Again",
                      systemImage: "person.crop.circle.badge.checkmark")
            }

            if let credential = claudeCredential {
                let healthy = credential.hasProfileScope && !credential.needsSignIn
                Label {
                    Text(claudeCredentialSummary ?? "").font(.caption)
                } icon: {
                    Image(systemName: healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(credential.needsSignIn ? .red : healthy ? .green : .orange)

                if credential.needsSignIn {
                    Text(credential.refreshRejectedAt != nil
                         ? "Claude no longer accepts this sign-in, so sessions can't get a new token. Organizations can sign members out on a schedule, and signing out elsewhere does the same. Sign in again to keep launching sessions."
                         : "This token has expired and can't be renewed. Sign in again to keep launching sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !credential.hasProfileScope {
                    Text("Without user:profile the agent can't read your plan's model entitlements. Sign in again, and if it keeps coming back narrowed, Anthropic has tightened what this flow may request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if host.isAgentSandbox {
                    Text("Sandbox refresh credentials stay in the Companion's Keychain. Sessions receive only an access token.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label {
                        Text("Sessions get an access token that lasts about 8 hours, renewed at each launch. For long or unattended work, use the Companion Sandbox in Projects: the Mac keeps its sessions supplied with new tokens so they run past 8 hours, schedules run without this device, and the agent runs as its own account, away from your files.")
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Button("Sign Out of Claude", role: .destructive) {
                    Task {
                        await host.clearClaudeCredential()
                        // Revoking the credential but leaving the browser session
                        // cookied would mean "sign out" still left a way straight
                        // back in.
                        await ClaudeLoginSession.clearPersistedSession()
                        host.persistCredentialChanges()
                        reloadClaudeCredential()
                    }
                }
            }
        }
    }

    private func reloadClaudeCredential() {
        claudeCredential = host.claudeCredential
        claudeCredentialSummary = ClaudeCredentialStore.summary(connectionID: host.id)
    }

    /// Renews a stale credential as soon as the sheet opens rather than at the
    /// next launch, so a sign-in Claude has since revoked shows up here instead
    /// of as a 401 inside a session.
    private func renewStaleClaudeCredential() {
        guard let credential = host.claudeCredential, !credential.isFresh(), credential.canRefresh else { return }
        Task {
            _ = await ClaudeCredentialStore.validCredential(connectionID: host.id)
            reloadClaudeCredential()
        }
    }

    private var deviceSignIn: AgentDeviceSignIn? {
        switch agent {
        case .copilot: CopilotDeviceSignIn()
        case .codex: CodexDeviceSignIn()
        case .claude, .custom: nil
        }
    }

    private func reloadCodexCredential() {
        codexCredentialSummary = CodexCredentialStore.summary(connectionID: host.id)
    }

    @ViewBuilder
    private var deviceFlowSection: some View {
        let provider = deviceSignIn?.providerName ?? ""
        Section("Sign in with \(provider)") {
            if agent == .codex {
                Button {
                    showingCodexWebLogin = true
                } label: {
                    Label(codexCredentialSummary == nil ? "Sign in with ChatGPT" : "Sign in with ChatGPT again",
                          systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            if agent == .codex, let summary = codexCredentialSummary {
                Label(summary, systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Sign Out of ChatGPT", role: .destructive) {
                    Task {
                        await host.clearCodexCredential()
                        host.persistCredentialChanges()
                        reloadCodexCredential()
                    }
                }
            }
            if let code = deviceCode {
                Text("Open the link and enter this code:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(code.userCode)
                        .font(.system(.title2, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        Pasteboard.copy(code.userCode)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
                Button {
                    if let url = URL(string: code.verificationURI) { openURL(url) }
                } label: {
                    Label(code.verificationURI, systemImage: "safari")
                }
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for authorization…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    startDeviceFlow()
                } label: {
                    HStack {
                        Label(agent == .codex ? "Sign in with device code"
                              : "Sign in with \(provider)",
                              systemImage: "person.crop.circle.badge.checkmark")
                        if signingIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(signingIn)
            }
        }
    }

    private func startDeviceFlow() {
        guard let signIn = deviceSignIn else { return }
        flowError = nil
        signingIn = true
        flowTask?.cancel()
        flowTask = Task {
            do {
                deviceCode = try await signIn.requestCode()
                try await signIn.awaitAuthorization(storingInto: host, agent: agent)
                host.persistCredentialChanges()
                dismiss()
            } catch is CancellationError {
                // sheet dismissed; nothing to do
            } catch {
                flowError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                deviceCode = nil
            }
            signingIn = false
        }
    }
}

// MARK: - Device-code sign-in

/// What the user acts on during a device-code sign-in.
struct DeviceSignInPrompt: Sendable, Equatable {
    let userCode: String
    let verificationURI: String
}

/// One provider's device-code flow, as the setup sheet drives it: show a code,
/// wait for approval, store the result on the host. Stateful (the code issued by
/// `requestCode` is what `awaitAuthorization` polls), so each sign-in attempt
/// gets a fresh instance.
@MainActor
protocol AgentDeviceSignIn: AnyObject {
    var providerName: String { get }
    func requestCode() async throws -> DeviceSignInPrompt
    func awaitAuthorization(storingInto host: any AgentCredentialHost, agent: SSHAgent) async throws
}

/// Copilot: GitHub's RFC 8628 flow; the minted token goes in the agent's
/// pasted-token slot (Copilot reads it from `COPILOT_GITHUB_TOKEN`).
@MainActor
private final class CopilotDeviceSignIn: AgentDeviceSignIn {
    private var code: GitHubDeviceFlow.DeviceCode?
    let providerName = "GitHub"

    func requestCode() async throws -> DeviceSignInPrompt {
        let code = try await GitHubDeviceFlow.requestCode()
        self.code = code
        return DeviceSignInPrompt(userCode: code.userCode, verificationURI: code.verificationURI)
    }

    func awaitAuthorization(storingInto host: any AgentCredentialHost, agent: SSHAgent) async throws {
        guard let code else { return }
        let minted = try await GitHubDeviceFlow.pollForToken(code)
        guard host.setSSHAuthToken(minted, for: agent) else { throw ProjectsProtocol.Failure("Couldn't save the GitHub login in Keychain.") }
    }
}

/// Codex: OpenAI's device flow; the whole credential goes to
/// `CodexCredentialStore` so this device keeps the refresh token.
@MainActor
private final class CodexDeviceSignIn: AgentDeviceSignIn {
    private var code: CodexOAuth.DeviceCode?
    let providerName = "ChatGPT"

    func requestCode() async throws -> DeviceSignInPrompt {
        let code = try await CodexOAuth.requestCode()
        self.code = code
        return DeviceSignInPrompt(userCode: code.userCode, verificationURI: code.verificationURL)
    }

    func awaitAuthorization(storingInto host: any AgentCredentialHost, agent: SSHAgent) async throws {
        guard let code else { return }
        guard host.setCodexCredential(try await CodexOAuth.pollForCredential(code)) else { throw ProjectsProtocol.Failure("Couldn't save the Codex login in Keychain.") }
    }
}
