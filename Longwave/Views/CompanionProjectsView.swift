#if !os(macOS)
import SwiftData
import SwiftUI

/// Both visionOS and iOS use the Companion's project catalog and launch policy.
/// Access is this device's pairing with the Mac, used only while the Mac allows
/// it Projects; nothing else is stored for it.
struct CompanionProjectsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \SavedConnection.lastConnected, order: .reverse) private var connections: [SavedConnection]
    var reenter: (SSHSessionID) -> Void

    @AppStorage("projects.companion.lastConnection") private var lastConnection = ""
    @State private var agent = SSHAgent.claude
    @State private var snapshot: ProjectsProtocol.Snapshot?
    @State private var client: ProjectsClient?
    @State private var busy = false
    @State private var error: String?
    @State private var generation = 0
    @State private var pairing: CompanionPairingClient?

    /// Paired Macs: Native connections holding a key of their own.
    private var macs: [SavedConnection] {
        connections.filter { $0.connectionType == .native && $0.companionDeviceToken != nil }
    }

    private var selected: SavedConnection? {
        macs.first { $0.id.uuidString == lastConnection } ?? macs.first
    }

    var body: some View {
        List {
            Section {
                if macs.isEmpty {
                    Text("Pair a Mac first: Connections → Add → Native → Computers Nearby. Its Companion decides whether this device may use Projects.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Mac", selection: Binding(get: { selected?.id.uuidString ?? "" }, set: { lastConnection = $0 })) {
                        ForEach(macs) { mac in Text(mac.displayName).tag(mac.id.uuidString) }
                    }
                    if let mac = selected {
                        if mac.companionGrants.contains(.projects) {
                            Button("Connect / Refresh") { Task { await connect() } }.disabled(busy)
                        } else {
                            Text("This Mac hasn't allowed this device Projects. Request access to pair again with Projects ticked, or tick it for this device under Devices in Longwave Companion and refresh.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Request Access") { requestAccess(on: mac) }.disabled(busy || isPairing)
                                Button("Refresh") { Task { await connect() } }.disabled(busy || isPairing)
                            }
                            pairingStatus
                        }
                    }
                }
            } header: {
                Text("Companion")
            } footer: {
                Text("Agent sign-ins, projects and schedules are managed in the Companion's Projects window on the Mac.")
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
                                open(session, access: client.access, account: snapshot.account)
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
                            open(session, access: client.access, account: snapshot.account)
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
        .task(id: selected?.id) {
            if selected?.companionGrants.contains(.projects) == true { await connect() }
        }
        .onAppear { CompanionLocator.shared.startBrowsing() }
        .onDisappear {
            CompanionLocator.shared.stopBrowsing()
            pairing?.cancel()
            client?.disconnect(); client = nil
        }
        .onChange(of: pairing?.state) { _, state in
            guard case .paired(let grant) = state, let mac = selected,
                  mac.setCompanionDeviceToken(grant.token) else { return }
            mac.companionGrants = Set((grant.grants ?? []).compactMap(CompanionGrant.init(rawValue:)))
            Task { await connect() }
        }
    }

    private func connect() async {
        generation += 1
        let current = generation
        client?.disconnect()
        client = nil
        snapshot = nil
        busy = false
        guard let mac = selected, let token = mac.companionDeviceToken,
              let deviceID = UUID(uuidString: CompanionLocator.headsetID) else { return }
        busy = true
        error = nil
        defer { if current == generation { busy = false } }
        // Knock first, as the Native stream does, so a Mac that opens its
        // ports only for nearby paired devices opens them.
        var host = mac.hostname
        if let macID = mac.companionMacID,
           let found = await CompanionLocator.shared.locate(macID: macID, token: token) {
            host = found
        }
        guard current == generation else { return }
        let connection = ProjectsClient(access: .init(id: deviceID, name: mac.displayName, host: host, key: token))
        client = connection
        do {
            try await connection.connect()
            let status = try await connection.snapshot()
            guard current == generation, !Task.isCancelled else { connection.disconnect(); return }
            snapshot = status
            if !mac.companionGrants.contains(.projects) { mac.companionGrants.insert(.projects) }
        } catch { if current == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private var isPairing: Bool {
        switch pairing?.state {
        case .waitingForMac, .confirming: true
        default: false
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing?.state {
        case .waitingForMac:
            HStack { ProgressView(); Text("Asking the Mac…") }
        case .confirming(let code):
            VStack(alignment: .leading, spacing: 4) {
                Text(PairingExchange.display(code)).font(.system(.title, design: .monospaced).weight(.semibold))
                Text("Check that the Mac shows this code, tick Projects there and choose Pair.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    /// Pairs again asking for Projects on top of what the Mac already allows.
    /// The Mac must be nearby for this; by address, tick Projects on the Mac.
    private func requestAccess(on mac: SavedConnection) {
        guard let macID = mac.companionMacID,
              let nearby = CompanionLocator.shared.nearby.first(where: { $0.macID == macID }) else {
            error = "The Mac isn't nearby. Tick Projects for this device under Devices in Longwave Companion, then refresh."
            return
        }
        let client = CompanionPairingClient(mac: nearby, requested: CompanionGrant.defaults.union(mac.companionGrants).union([.projects]))
        pairing = client
        client.start()
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

    private func open(_ session: ProjectsProtocol.Session, access: ProjectsProtocol.Access, account: String) {
        let alreadyOpen = sshManager.sessions.contains {
            $0.id.raw == "projects-\(access.id.uuidString)-\(session.id)"
        }
        let id = sshManager.openProjectsSession(session, access: access, account: account)
        #if os(visionOS)
        openWindow(id: "ssh-terminal", value: id)
        #else
        if alreadyOpen { reenter(id) }
        #endif
    }

}
#endif
