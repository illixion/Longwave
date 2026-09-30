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

    #if !os(visionOS)
    /// A running session the user asked to return to, presented as a cover
    /// because there is no second window to put it in.
    @State private var reenteredSession: SSHSessionID?
    #endif

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
        #if !os(visionOS)
        .fullScreenCover(item: $reenteredSession) { id in
            NavigationStack {
                SSHTerminalView(sessionID: id)
                    .environment(sshManager)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { reenteredSession = nil }
                        }
                    }
            }
        }
        #endif
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
                    if agent == .codex && host.hasCodexCredential {
                        LabeledContent("Login", value: "~/\(CodexOAuth.Constants.sessionHomeDirectory)/auth.json")
                            .font(.system(.body, design: .monospaced))
                        Text("Signed in with ChatGPT: each launch writes a fresh auth.json (no refresh token) into that folder and points CODEX_HOME at it; your config.toml, AGENTS.md and skills from ~/.codex are linked in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Token", value: host.effectiveEnvName(for: agent))
                            .font(.system(.body, design: .monospaced))
                        Text("\(agent.displayName) launches with this command; its token is injected as that env var. Set it under \(agent.displayName) Login above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if agent == .claude {
                        Text("Sessions still start in Claude's normal permission mode — the flag only makes “bypass permissions” selectable in the Shift+Tab cycle, so you can skip prompts from the headset without every session starting unguarded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                        #if os(visionOS)
                        openWindow(id: "ssh-terminal", value: session.id)
                        #else
                        // One window here, so re-entering a session presents it.
                        // Only the already-running ones: a session started from
                        // this view is brand new, and the shell watches for those
                        // and raises them itself.
                        reenteredSession = session.id
                        #endif
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
        // now. It only actually calls out when an in-app Claude or Codex
        // credential is stored and near expiry; every other agent resolves from
        // the keychain and falls straight through.
        Task {
            let environment = await host.resolvedSSHEnvironmentRenewingCredentials(for: agent)
            do {
                let id = try sshManager.newClaudeSession(
                    host: host.hostname, port: host.port, username: host.sshUsername,
                    folder: folder, projectName: "",
                    clientCommand: host.effectiveCommand(for: agent),
                    agentKey: agent.sessionKey,
                    environment: environment,
                    setup: host.sessionSetup(for: agent, environment: environment)
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
            Pasteboard.copy(key.openSSHPublicKeyLine(comment: "longwave"))
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
