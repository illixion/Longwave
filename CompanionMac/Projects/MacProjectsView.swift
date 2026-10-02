import AppKit
import SwiftUI

/// The Companion's Projects window: agents run as the local sandbox account
/// (`scripts/agent-sandbox/`), not as you. Sessions are tmux-backed in the
/// sandbox and attach in Terminal.app — the Mac has a real terminal, so there's
/// no in-app one, and the sandbox desktop opens in Longwave for Mac's viewer.
struct MacProjectsView: View {
    @Environment(LocalSandboxController.self) private var sandbox

    @State private var setupAgent: SSHAgent?
    @State private var keyLine = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            switch sandbox.availability {
            case .ready:
                if !sandbox.hasFullDiskAccess { fullDiskAccessSection }
                statusSection
                if !sandbox.setupComplete { onboardingSection }
                agentsSection
                projectsSection
                sessionsSection
                SchedulesSection()
                advancedSection
            case .unknown:
                Section { ProgressView("Checking the sandbox…") }
            case .notInstalled:
                installSection(reason: "The agent sandbox isn't installed on this Mac.")
            case .sudoNotConfigured(let detail):
                installSection(reason: "Longwave Companion can't run the sandbox helper without a password (\(detail)).")
            case .failed(let message):
                installSection(reason: message)
            }
            if let error = sandbox.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            } else if let message = sandbox.lastMessage {
                Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                if let busy = sandbox.busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.callout) }
                } else {
                    Button { Task { await sandbox.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
        }
        // Status only: opening this window must not log the agent in.
        .task { await sandbox.refresh() }
        .sheet(item: $setupAgent) { agent in
            AgentSetupSheet(host: sandbox.account, agent: agent)
                .frame(minWidth: 520, minHeight: 420)
        }
        .confirmationDialog("Reset the sandbox?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Task { await sandbox.reset() } }
        } message: {
            Text("Logs the agent out and restores its home from the golden copy. Work not pushed to the exchange is lost.")
        }
    }

    // MARK: Sections

    private func installSection(reason: String) -> some View {
        Section("Agent sandbox") {
            Text(reason)
            Text("Install it from the Longwave repo (Touch ID once):")
                .foregroundStyle(.secondary)
            HStack {
                Text(LocalSandbox.installCommand).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
                Button("Copy") { Pasteboard.copy(LocalSandbox.installCommand) }
            }
            Button("Check again") { Task { await sandbox.refresh() } }
        }
    }

    private var fullDiskAccessSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Give Longwave Companion Full Disk Access").font(.headline)
                    Text("Reset, Setup complete and golden snapshots work inside the sandbox account's home, which macOS protects even from the root helper unless the app calling it has Full Disk Access. Sessions and schedules without \"Reset before run\" work without it.")
                        .foregroundStyle(.secondary)
                    Text("macOS never asks for this permission. Grant Access opens the Full Disk Access list with a small window beside it: drag the Companion's icon from it into the list, switch it on, then relaunch.")
                        .foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "lock.shield").foregroundStyle(.orange) }
            HStack {
                Button("Grant Access…") { sandbox.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Relaunch Companion") { sandbox.relaunch() }
                Button("Check again") { Task { await sandbox.refresh() } }
            }
        }
    }

    private var statusSection: some View {
        Section("Sandbox") {
            if let s = sandbox.status {
                LabeledContent("Account", value: "\(s.agentUser) (uid \(s.agentUID))")
                LabeledContent("Desktop session") { desktopLabel }
                LabeledContent("Golden home", value: Self.format(s.goldenSnapshotAt) ?? "not saved yet")
                LabeledContent("Last reset", value: Self.format(s.lastResetAt) ?? "never")
            }
            HStack {
                Button("Sandbox Desktop") {
                    sandbox.openDesktop()
                }
                Button("Open Device Hub") { Task { await sandbox.openDeviceHub() } }
                Spacer()
                Button("Stop") { Task { await sandbox.stop() } }
                Button("Reset…", role: .destructive) { confirmReset = true }
            }
            .disabled(sandbox.busy != nil)
        }
    }

    @ViewBuilder
    private var desktopLabel: some View {
        switch sandbox.desktop {
        case .running: Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loggingIn: HStack { ProgressView().controlSize(.small); Text("Logging in…") }
        case .absent, .unknown:
            HStack {
                Text("Not logged in").foregroundStyle(.secondary)
                Button("Log In") { Task { await sandbox.ensureDesktopSession(force: true) } }
            }
        case .failed(let m), .authFailed(let m):
            HStack {
                Text(m).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { Task { await sandbox.ensureDesktopSession(force: true) } }
            }
        }
    }

    private var onboardingSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish the sandbox's first-run setup").font(.headline)
                    Text("Open the Sandbox Desktop, complete macOS setup for the agent account yourself, then press Setup complete. Every reset restores the home saved at that moment.")
                        .foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "person.crop.circle.badge.exclamationmark") }
            HStack {
                Button("Sandbox Desktop") {
                    sandbox.openDesktop()
                }
                Button("Setup complete") { Task { await sandbox.completeSetup() } }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Already done") { sandbox.setupComplete = true }
            }
        }
    }

    private var agentsSection: some View {
        Section {
            ForEach([SSHAgent.claude, .codex, .copilot]) { agent in
                HStack {
                    Label(agent.displayName, systemImage: agent.systemImage)
                    Spacer()
                    Text(sandbox.account.hasToken(for: agent) ? "Signed in" : "Not signed in")
                        .foregroundStyle(sandbox.account.hasToken(for: agent) ? .green : .secondary)
                    Button(sandbox.account.hasToken(for: agent) ? "Manage…" : "Sign In…") { setupAgent = agent }
                }
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Credentials stay in this Mac's keychain; each session gets short-lived tokens on stdin.")
        }
    }

    private var projectsSection: some View {
        Section {
            if sandbox.projects.isEmpty {
                Text("No projects yet. Import a local git repository to give the agents a copy.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sandbox.projects) { project in
                ProjectRow(project: project)
            }
            Button("Import Repository…") { chooseRepository() }
        } header: {
            Text("Projects")
        } footer: {
            Text("Projects move through \(LocalSandbox.exchangeDir): Import pushes your branch there, Fetch back brings the agent's branches home as the `sandbox` remote — fetch only, nothing of the agent's runs.")
        }
    }

    private var sessionsSection: some View {
        Section("Running Sessions") {
            if sandbox.sessions.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(sandbox.sessions, id: \.name) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text(session.title)
                        Text(session.folder).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Attach") {
                        do { try sandbox.attach(tmuxSession: session.name) } catch { sandbox.lastError = "\(error)" }
                    }
                    Button("Stop", role: .destructive) { Task { await sandbox.stopSession(session) } }
                }
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            Toggle(isOn: Binding(
                get: { sandbox.status?.firewallWanted ?? false },
                set: { on in Task { await sandbox.setFirewall(on) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network firewall")
                    Text("Keeps the agent off your LAN, tailnet and localhost services. While it's on, macOS turns iCloud Private Relay off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Authorize a key (e.g. the headset's, from Projects → Copy Public Key):")
                HStack {
                    TextField("ssh-ed25519 AAAA… or ecdsa-sha2-nistp256 AAAA…", text: $keyLine)
                        .font(.body.monospaced())
                    Button("Authorize") {
                        let line = keyLine
                        Task { await sandbox.authorizeKey(line); keyLine = "" }
                    }
                    .disabled(keyLine.isEmpty)
                }
            }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a git repository to copy into the agent sandbox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sandbox.importRepository(at: url) }
    }

    private static func format(_ stamp: String?) -> String? {
        LocalSandbox.parseTimestamp(stamp).map { $0.formatted(date: .abbreviated, time: .shortened) }
    }
}

/// One project: agent picker, launch, fetch back.
private struct ProjectRow: View {
    @Environment(LocalSandboxController.self) private var sandbox
    let project: LocalSandboxController.Project
    @State private var agent: SSHAgent = .claude

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(project.displayName)
                Text(project.checkout?.path ?? "imported elsewhere")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Agent", selection: $agent) {
                ForEach([SSHAgent.claude, .codex, .copilot]) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: agent) { _, new in sandbox.setAgentChoice(new, for: project) }
            Button("Open") { Task { await sandbox.launch(project, agent: agent) } }
                .buttonStyle(.borderedProminent)
            Button("Fetch back") { Task { await sandbox.fetchBack(project) } }
                .disabled(project.checkout == nil)
        }
        .onAppear { agent = sandbox.agentChoice(for: project) }
        .disabled(sandbox.busy != nil)
    }
}
