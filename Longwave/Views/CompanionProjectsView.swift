#if !os(macOS)
import SwiftUI

/// Both visionOS and iOS use the Companion's project catalog and launch policy.
/// Only a revocable Projects invitation is stored on the client.
struct CompanionProjectsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    @Environment(\.openWindow) private var openWindow
    var reenter: (SSHSessionID) -> Void

    @AppStorage("projects.companion.lastDevice") private var lastDevice = ""
    @State private var devices = Self.loadDevices()
    @State private var invitationText = ""
    @State private var agent = SSHAgent.claude
    @State private var snapshot: ProjectsProtocol.Snapshot?
    @State private var client: ProjectsClient?
    @State private var busy = false
    @State private var error: String?
    @State private var generation = 0
    private static let devicesKey = "projects.companion.devices.v1"

    private var selected: ProjectsProtocol.Device? {
        devices.first { $0.id.uuidString == lastDevice } ?? devices.first
    }

    var body: some View {
        List {
            Section("Companion") {
                if !devices.isEmpty {
                    Picker("Mac", selection: Binding(get: { selected?.id.uuidString ?? "" }, set: { lastDevice = $0 })) {
                        ForEach(devices) { device in Text(device.name + " · " + device.host).tag(device.id.uuidString) }
                    }
                    if let device = selected {
                        TextField("Mac address", text: Binding(get: { device.host }, set: { value in
                            guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
                            devices[index].host = value
                            saveDevices()
                        }))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Connect / Refresh") { Task { await connect() } }.disabled(busy)
                        Button("Forget This Invitation", role: .destructive) { forget(device) }.disabled(busy)
                    }
                }
                SecureField("Paste Projects invitation", text: $invitationText)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Add Companion") { addInvitation() }.disabled(invitationText.isEmpty || busy)
                Text("On the Mac: Longwave Companion → Projects → Remote Projects access → Create and Copy Invitation. Agent sign-ins are managed there.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if busy { ProgressView("Working with the Companion…") }
            if let error { Text(error).foregroundStyle(.red) }

            if let snapshot {
                Section("Sandbox") {
                    LabeledContent("Account", value: snapshot.account)
                    LabeledContent("Desktop", value: snapshot.desktopRunning ? "Running" : "Not logged in")
                    if !snapshot.available {
                        Text("Set up the sandbox in the Companion's Projects window on the Mac.")
                    } else if !snapshot.desktopRunning {
                        Button("Log In Sandbox Desktop") { action { try await $0.ensureDesktop() } }
                            .disabled(busy)
                        Text("Only needed for GUI tools such as the visionOS simulator. Starting an agent does not log the desktop in.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Projects") {
                    Picker("Agent", selection: $agent) {
                        ForEach([SSHAgent.claude, .codex, .copilot]) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    if !snapshot.configuredAgents.contains(agent.rawValue) {
                        Text("Sign in to \(agent.displayName) in the Companion's Projects window.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if snapshot.projects.isEmpty {
                        Text("Import a repository in the Companion's Projects window on the Mac.")
                    }
                    ForEach(snapshot.projects) { project in
                        Button("Open \(agent.displayName) in \(project.name)") {
                            action { client in
                                let session = try await client.start(project: project.id, agent: agent.rawValue)
                                open(session, invitation: client.invitation, account: snapshot.account)
                            }
                        }
                        .disabled(busy || !snapshot.available || !snapshot.configuredAgents.contains(agent.rawValue))
                    }
                }
                Section("Running Sandbox Sessions") {
                    if snapshot.sessions.isEmpty { Text("None") }
                    ForEach(snapshot.sessions) { session in
                        Button {
                            guard let client else { return }
                            open(session, invitation: client.invitation, account: snapshot.account)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.title)
                                Text(session.folder).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(busy)
                        .swipeActions {
                            Button("Stop", role: .destructive) { action { try await $0.stop(session: session.id) } }
                        }
                    }
                }
            }
        }
        .task(id: selected?.id) { await connect() }
        .onDisappear { client?.disconnect(); client = nil }
    }

    private func connect() async {
        generation += 1
        let current = generation
        client?.disconnect()
        client = nil
        snapshot = nil
        busy = false
        guard let device = selected else { return }
        guard let key = ProjectsKeyStore.load(device.id) else { error = "This invitation's key is unavailable. Add it again."; return }
        let connection = ProjectsClient(invitation: .init(id: device.id, name: device.name, host: device.host, port: device.port, key: key))
        client = connection
        busy = true
        error = nil
        defer { if current == generation { busy = false } }
        do {
            try await connection.connect()
            let status = try await connection.snapshot()
            guard current == generation, !Task.isCancelled else { connection.disconnect(); return }
            snapshot = status
        } catch { if current == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func action(_ work: @escaping (ProjectsClient) async throws -> Void) {
        guard !busy, let client else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await work(client); snapshot = try await client.snapshot() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func open(_ session: ProjectsProtocol.Session, invitation: ProjectsProtocol.Invitation, account: String) {
        let alreadyOpen = sshManager.sessions.contains {
            $0.id.raw == "projects-\(invitation.id.uuidString)-\(session.id)"
        }
        let id = sshManager.openProjectsSession(session, invitation: invitation, account: account)
        #if os(visionOS)
        openWindow(id: "ssh-terminal", value: id)
        #else
        if alreadyOpen { reenter(id) }
        #endif
    }

    private func addInvitation() {
        do {
            let invitation = try ProjectsProtocol.Invitation.parse(invitationText)
            try ProjectsKeyStore.save(invitation.key, id: invitation.id)
            devices.removeAll { $0.id == invitation.id }
            devices.append(.init(id: invitation.id, name: invitation.name, host: invitation.host, port: invitation.port))
            saveDevices()
            lastDevice = invitation.id.uuidString
            invitationText = ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func forget(_ device: ProjectsProtocol.Device) {
        do {
            try ProjectsKeyStore.delete(device.id)
            for session in sshManager.sessions where session.projectsInvitation?.id == device.id { sshManager.remove(session.id) }
            devices.removeAll { $0.id == device.id }
            saveDevices()
            client?.disconnect()
            client = nil
            snapshot = nil
        } catch { self.error = error.localizedDescription }
    }

    private func saveDevices() { UserDefaults.standard.set(try? JSONEncoder().encode(devices), forKey: Self.devicesKey) }
    private static func loadDevices() -> [ProjectsProtocol.Device] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return [] }
        return (try? JSONDecoder().decode([ProjectsProtocol.Device].self, from: data)) ?? []
    }
}
#endif
