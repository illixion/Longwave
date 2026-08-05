import SwiftUI
import SwiftData

/// The managed-Claude tab: choose an SSH host, browse its folders, and launch
/// `claude` (tmux-backed) in a project directory. Reuses saved `.ssh`
/// connections as the available hosts.
struct ProjectsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var connections: [SavedConnection]

    private var sshConnections: [SavedConnection] {
        connections.filter { $0.connectionType == .ssh }
    }

    /// The host picked last time, so reopening the tab lands on the machine you
    /// were working on rather than on whichever connection was used most recently
    /// elsewhere in the app. Falls back to the most recent SSH connection when
    /// unset, or when the remembered one has since been deleted.
    @AppStorage(ConnectionDefaults.Keys.projectsLastHost)
    private var lastHostID: String = ""

    @State private var homePath = ""
    @State private var path = ""
    @State private var entries: [DirEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var keyStatus: String?
    @State private var showingAgentSetup = false

    private var selectedHost: SavedConnection? {
        sshConnections.first { $0.id.uuidString == lastHostID } ?? sshConnections.first
    }

    /// The agent the selected host will launch — its remembered default.
    private var agent: SSHAgent { selectedHost?.sshAgent ?? .claude }

    var body: some View {
        NavigationStack {
            Group {
                if sshConnections.isEmpty {
                    ContentUnavailableView {
                        Label("No SSH Hosts", systemImage: "terminal")
                    } description: {
                        Text("Add an SSH connection in the Connections tab to run Claude on that machine.")
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy Public Key", systemImage: "key") { copyPublicKey() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Picker("Host", selection: Binding(
                    get: { selectedHost?.id },
                    set: { lastHostID = $0?.uuidString ?? "" }
                )) {
                    ForEach(sshConnections) { conn in
                        Text(conn.displayName).tag(Optional(conn.id))
                    }
                }
                if let keyStatus {
                    Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                }
                if selectedHost != nil {
                    Picker("Agent", selection: agentBinding) {
                        ForEach(SSHAgent.allCases) { agent in
                            Label(agent.displayName, systemImage: agent.systemImage).tag(agent)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        showingAgentSetup = true
                    } label: {
                        HStack {
                            Label("\(agent.displayName) Login", systemImage: "person.badge.key")
                            Spacer()
                            if selectedHost?.hasToken(for: agent) == true {
                                Label("Configured", systemImage: "checkmark.seal.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Set up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            environmentSection
            runningSessionsSection
            recentsSection
            folderBrowserSection

            Section {
                Button {
                    openAgent(in: path)
                } label: {
                    Label("Open \(agent.displayName) Here", systemImage: agent.systemImage)
                }
                .disabled(selectedHost == nil || path.isEmpty || loading)
            }
        }
        .task(id: selectedHost?.id) {
            await loadHome()
            await discoverSessions()
        }
        .sheet(isPresented: $showingAgentSetup) {
            if let host = selectedHost {
                NavigationStack { AgentSetupSheet(host: host, agent: agent) }
            }
        }
    }

    private var agentBinding: Binding<SSHAgent> {
        Binding(get: { selectedHost?.sshAgent ?? .claude },
                set: { selectedHost?.sshAgent = $0 })
    }

    // MARK: Sections

    /// Per-host environment config, editable in place. Built-in agents
    /// (Claude/Copilot) use fixed commands + token env names, shown read-only;
    /// the **Custom** agent exposes a free-form command and token env-var name so
    /// any other CLI works. The `KEY=VALUE` extra-vars editor applies to all.
    @ViewBuilder
    private var environmentSection: some View {
        if let host = selectedHost {
            Section("Environment Variables") {
                if agent == .custom {
                    TextField("claude", text: clientCommandBinding)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Command launched in the project folder for the Custom agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("TOKEN_ENV_NAME", text: authEnvNameBinding)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Env-var name the Custom-agent token is injected as. Default: \(SSHAgent.claude.defaultEnvName).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Command", value: host.effectiveCommand(for: agent))
                        .font(.system(.body, design: .monospaced))
                    LabeledContent("Token", value: host.effectiveEnvName(for: agent))
                        .font(.system(.body, design: .monospaced))
                    Text("\(agent.displayName) launches with this command; its token is injected as that env var. Set it under \(agent.displayName) Login above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("KEY=VALUE (one per line)", text: envVarsBinding, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("Extra non-secret vars injected into every session on this host (e.g. PATH entries). Applies to newly launched sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clientCommandBinding: Binding<String> {
        Binding(get: { selectedHost?.sshClientCommand ?? "" },
                set: { selectedHost?.sshClientCommand = $0 })
    }

    private var authEnvNameBinding: Binding<String> {
        Binding(get: { selectedHost?.sshAuthEnvName ?? "" },
                set: { selectedHost?.sshAuthEnvName = $0 })
    }

    private var envVarsBinding: Binding<String> {
        Binding(get: { selectedHost?.sshEnvVars ?? "" },
                set: { selectedHost?.sshEnvVars = $0 })
    }

    @ViewBuilder
    private var runningSessionsSection: some View {
        let claudeSessions = sshManager.sessions.filter { $0.kind == .claude }
        if !claudeSessions.isEmpty {
            Section("Running Sessions") {
                ForEach(claudeSessions) { session in
                    Button {
                        openWindow(id: "ssh-terminal", value: session.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(.headline)
                                if let cwd = session.cwd {
                                    Text(cwd).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            sshManager.stopSession(session.id)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        let recents = recentFolders(host: selectedHost?.hostname ?? "")
        if !recents.isEmpty {
            Section("Recent Projects") {
                ForEach(recents, id: \.self) { folder in
                    Button {
                        openAgent(in: folder)
                    } label: {
                        Label(displayName(of: folder), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderBrowserSection: some View {
        Section("Folder") {
            HStack {
                Button {
                    goUp()
                } label: {
                    Label("Up", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)
                .disabled(path.isEmpty || path == "/")
                Spacer()
                Text(displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }

            if loading {
                ProgressView()
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ForEach(entries.filter(\.isDir)) { entry in
                Button {
                    enter(entry.name)
                } label: {
                    Label(entry.name, systemImage: "folder")
                }
            }
        }
    }

    // MARK: Path helpers

    private var displayPath: String {
        guard !homePath.isEmpty else { return path }
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    private func displayName(of folder: String) -> String {
        let trimmed = (folder.hasSuffix("/") && folder != "/") ? String(folder.dropLast()) : folder
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }

    // MARK: Browsing

    private func loadHome() async {
        guard let host = selectedHost else { return }
        loading = true; error = nil
        do {
            let home = try await sshManager.homeDirectory(host: host.hostname, port: host.port, username: host.sshUsername)
            homePath = home
            path = home
            entries = try await sshManager.listDirectory(host: host.hostname, port: host.port, username: host.sshUsername, absolutePath: home)
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    /// Repopulate "Running Sessions" with agent tmux sessions still alive on the
    /// host (the in-memory list is lost on app relaunch).
    private func discoverSessions() async {
        guard let host = selectedHost else { return }
        // Reap abandoned sessions first so they don't reappear in the list (and
        // so stale post-update agent binaries get relaunched on next open).
        await sshManager.reapStaleSessions(host: host.hostname, port: host.port, username: host.sshUsername)
        await sshManager.discoverClaudeSessions(host: host.hostname, port: host.port, username: host.sshUsername)
    }

    private func reload() async {
        guard let host = selectedHost, !path.isEmpty else { return }
        loading = true; error = nil
        do {
            entries = try await sshManager.listDirectory(host: host.hostname, port: host.port, username: host.sshUsername, absolutePath: path)
        } catch {
            self.error = "\(error)"
        }
        loading = false
    }

    private func enter(_ name: String) {
        path = path.hasSuffix("/") ? path + name : path + "/" + name
        Task { await reload() }
    }

    private func goUp() {
        guard !path.isEmpty, path != "/" else { return }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parent = (trimmed as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        Task { await reload() }
    }

    // MARK: Launch

    private func openAgent(in folder: String) {
        guard let host = selectedHost, !folder.isEmpty else { return }
        let agent = host.sshAgent
        // Renewing the credential is a network round-trip, so the launch is async
        // now. It only actually calls out when an in-app Claude credential is
        // stored and near expiry; every other agent resolves from the keychain and
        // falls straight through.
        Task {
            let environment = await host.resolvedSSHEnvironmentRenewingCredentials(for: agent)
            do {
                let id = try sshManager.newClaudeSession(
                    host: host.hostname, port: host.port, username: host.sshUsername,
                    folder: folder, projectName: "",
                    clientCommand: host.effectiveCommand(for: agent),
                    agentKey: agent.sessionKey,
                    environment: environment
                )
                addRecent(host: host.hostname, folder: folder)
                openWindow(id: "ssh-terminal", value: id)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func copyPublicKey() {
        do {
            let key = try sshManager.deviceKey()
            Pasteboard.copy(key.openSSHPublicKeyLine(comment: "visionvnc"))
            keyStatus = "Copied (\(key.sshFingerprint())). Add to ~/.ssh/authorized_keys on the host."
        } catch {
            keyStatus = "Key error: \(error)"
        }
    }

    // MARK: Recents (per host, UserDefaults)

    private func recentsKey(_ host: String) -> String { "claudeRecentFolders.\(host)" }

    private func recentFolders(host: String) -> [String] {
        guard !host.isEmpty else { return [] }
        return UserDefaults.standard.stringArray(forKey: recentsKey(host)) ?? []
    }

    private func addRecent(host: String, folder: String) {
        var list = recentFolders(host: host)
        list.removeAll { $0 == folder }
        list.insert(folder, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentsKey(host))
    }
}

/// Gives a host a per-agent login that works over SSH. The macOS Keychain is
/// locked outside the desktop session, so each agent instead gets a long-lived
/// token that VisionVNC injects into every session as its env var (see
/// `SavedConnection.resolvedSSHEnvironment(for:)`) — stored only on this device,
/// never written to the Mac. Claude/Custom paste a token; Copilot can mint one
/// in-app via GitHub's device-authorization flow (`GitHubDeviceFlow`).
private struct AgentSetupSheet: View {
    @Bindable var host: SavedConnection
    let agent: SSHAgent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var token = ""

    // Device-flow state (Copilot).
    @State private var deviceCode: GitHubDeviceFlow.DeviceCode?
    @State private var flowTask: Task<Void, Never>?
    @State private var flowError: String?
    @State private var signingIn = false

    // In-app browser OAuth state (Claude).
    @State private var showingWebLogin = false
    /// Mirrors the stored credential for display. Held in view state rather than
    /// read inline because it lives in the keychain, not SwiftData — no
    /// observation would fire when it changes, so sign-in/out refresh it by hand.
    @State private var claudeCredential: ClaudeOAuth.Credential?
    @State private var claudeCredentialSummary: String?

    private var envName: String { host.effectiveEnvName(for: agent) }

    var body: some View {
        Form {
            Section {
                Text(agent.setupInstructions(envName: envName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

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
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

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
                        host.setSSHAuthToken(nil, for: agent)
                        try? host.modelContext?.save()
                        token = ""
                    }
                }
            }
        }
        .navigationTitle(agent.setupTitle)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    host.setSSHAuthToken(token, for: agent)
                    try? host.modelContext?.save()
                    dismiss()
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { reloadClaudeCredential() }
        .onDisappear { flowTask?.cancel() }
        .sheet(isPresented: $showingWebLogin) {
            ClaudeLoginSheet { credential in
                host.setClaudeCredential(credential)
                try? host.modelContext?.save()
                reloadClaudeCredential()
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
                Label {
                    Text(claudeCredentialSummary ?? "").font(.caption)
                } icon: {
                    Image(systemName: credential.hasProfileScope
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(credential.hasProfileScope ? .green : .orange)

                if !credential.hasProfileScope {
                    Text("Without user:profile the agent can't read your plan's model entitlements. Sign in again, and if it keeps coming back narrowed, Anthropic has tightened what this flow may request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: Binding(
                    get: { host.sshInjectClaudeRefreshToken },
                    set: { host.sshInjectClaudeRefreshToken = $0; try? host.modelContext?.save() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Let sessions renew their own token")
                        Text(host.sshInjectClaudeRefreshToken
                             ? "The refresh token is sent to the Mac, so a session isn't limited to one 8-hour token. Unlike this device's keychain, a process environment there is readable by anything running as you, and a refresh token never expires on its own."
                             : "Only the access token leaves this device, so anything that reads it on the Mac loses access within ~8 hours. Long sessions are renewed at launch instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!credential.canRefresh)

                Button("Sign Out of Claude", role: .destructive) {
                    Task {
                        await host.clearClaudeCredential()
                        // Revoking the credential but leaving the browser session
                        // cookied would mean "sign out" still left a way straight
                        // back in.
                        await ClaudeLoginSession.clearPersistedSession()
                        try? host.modelContext?.save()
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

    @ViewBuilder
    private var deviceFlowSection: some View {
        Section("Sign in with GitHub") {
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
                        Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                        if signingIn { Spacer(); ProgressView() }
                    }
                }
                .disabled(signingIn)
            }
            if let flowError {
                Text(flowError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func startDeviceFlow() {
        flowError = nil
        signingIn = true
        flowTask?.cancel()
        flowTask = Task {
            do {
                let code = try await GitHubDeviceFlow.requestCode()
                deviceCode = code
                let minted = try await GitHubDeviceFlow.pollForToken(code)
                host.setSSHAuthToken(minted, for: agent)
                try? host.modelContext?.save()
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
