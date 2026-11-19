#if !os(macOS)
import SwiftData
import SwiftUI
import RAVEUI

/// Projects → iTerm2: the Mac's iTerm2 windows, tabs and split panes, over a
/// saved SSH connection. Opening a session mirrors it live in a terminal
/// window (`iterm-tool view` on the Mac); typing there types into it. Tabs can
/// be opened, renamed, closed and brought forward on the Mac.
///
/// Everything runs as SSH commands (`ITermCommands`): there is no Companion
/// protocol or grant for this, since the SSH login already lets this device
/// do anything that account's terminals can.
struct ITermProjectsView: View {
    @Environment(SSHTerminalManager.self) private var sshManager
    /// Terminals take the main window's place (see `SessionWindowPush`).
    @PushSessionWindow private var pushSessionWindow
    @Query(sort: \SavedConnection.lastConnected, order: .reverse) private var connections: [SavedConnection]
    var reenter: (SSHSessionID) -> Void

    @AppStorage("projects.iterm.lastHost") private var lastHostID = ""
    @State private var windows: [ITermCommands.Window] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var renaming: ITermCommands.Session?
    @State private var renameText = ""
    @State private var closing: (session: ITermCommands.Session, tab: Bool)?

    private var sshConnections: [SavedConnection] {
        connections.filter { $0.connectionType == .ssh }
    }

    private var host: SavedConnection? {
        sshConnections.first { $0.id.uuidString == lastHostID } ?? sshConnections.first
    }

    var body: some View {
        if sshConnections.isEmpty {
            ContentUnavailableView {
                Label("No SSH Hosts", systemImage: "apple.terminal")
            } description: {
                Text("Add an SSH connection to your Mac in the Connections tab. iTerm2 is driven over that login.")
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Picker("Mac", selection: Binding(get: { host?.id }, set: { lastHostID = $0?.uuidString ?? "" })) {
                    ForEach(sshConnections) { conn in Text(conn.displayName).tag(Optional(conn.id)) }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(loading || busy)
            } header: {
                Text("iTerm2")
            } footer: {
                Text("Runs iterm-tool on the Mac over SSH. Longwave Companion installs it; iTerm2 needs Settings → General → Magic → Enable Python API, and the Mac asks once to let SSH control iTerm2.")
            }

            if loading && !loaded { ProgressView("Asking iTerm2…") }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }

            if loaded && windows.isEmpty && error == nil {
                Text("iTerm2 has no windows open.").foregroundStyle(.secondary)
            }

            ForEach(windows) { window in
                Section {
                    ForEach(window.tabs) { tab in
                        ForEach(tab.sessions) { session in
                            row(session, in: tab)
                        }
                    }
                    Button("New Tab", systemImage: "plus") {
                        newTab(in: window)
                    }
                    .disabled(busy)
                } header: {
                    Text(window.isFront ? "Window \(window.number) · Front" : "Window \(window.number)")
                }
            }

            if loaded {
                Section {
                    Button("New Window", systemImage: "macwindow.badge.plus") { newTab(in: nil) }
                        .disabled(busy)
                }
            }
        }
        .task(id: host?.id) {
            windows = []
            loaded = false
            error = nil
            // Tabs change on the Mac too; keep the list roughly current while shown.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .alert("Rename Tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let session = renaming { run(["rename", session.sessionID, renameText]) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave empty to go back to iTerm2's automatic title.")
        }
        .confirmationDialog(closing?.tab == true ? "Close this tab on the Mac?" : "Close this session on the Mac?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible) {
            Button("Close", role: .destructive) {
                if let closing { close(closing.session, tab: closing.tab) }
                closing = nil
            }
        } message: {
            Text("Anything still running there is ended.")
        }
    }

    private func row(_ session: ITermCommands.Session, in tab: ITermCommands.Tab) -> some View {
        Button {
            open(session)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.sessions.count > 1 ? (session.name ?? session.displayTitle) : session.displayTitle)
                        .font(.headline).lineLimit(1)
                    Text(detail(session))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if tab.isCurrent && session.currentSession == true {
                    Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("Selected on the Mac")
                }
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
            }
        }
        .disabled(busy)
        .swipeActions(edge: .trailing) {
            Button("Close", systemImage: "xmark", role: .destructive) { closing = (session, false) }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { open(session) }
            Button("Show on Mac", systemImage: "macwindow") { run(["focus", session.sessionID]) }
            Button("Rename Tab…", systemImage: "pencil") {
                renameText = session.title ?? ""
                renaming = session
            }
            Divider()
            if tab.sessions.count > 1 {
                Button("Close Pane", systemImage: "xmark", role: .destructive) { closing = (session, false) }
            }
            Button("Close Tab", systemImage: "xmark.square", role: .destructive) { closing = (session, true) }
        }
    }

    private func detail(_ session: ITermCommands.Session) -> String {
        var parts: [String] = []
        if let job = session.job, !job.isEmpty { parts.append(job) }
        if let cwd = session.cwd, !cwd.isEmpty { parts.append(cwd) }
        if let cols = session.cols, let rows = session.rows { parts.append("\(cols)×\(rows)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Commands

    private func refresh() async {
        guard let host, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let output = try await sshManager.runITerm(host: host.hostname, port: host.port, username: host.sshUsername,
                                                       arguments: ["list", "--json", "--compact"])
            let sessions = try ITermCommands.decodeJSON([ITermCommands.Session].self, from: output)
            guard host.id == self.host?.id else { return }
            windows = ITermCommands.windows(from: sessions)
            loaded = true
            error = nil
        } catch {
            guard host.id == self.host?.id else { return }
            self.error = error.localizedDescription
        }
    }

    /// Runs a management command, then reloads the list.
    private func run(_ arguments: [String], then: ((String) -> Void)? = nil) {
        guard let host, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let output = try await sshManager.runITerm(host: host.hostname, port: host.port,
                                                           username: host.sshUsername, arguments: arguments)
                then?(output)
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }

    /// A new tab in `window` (a new window when nil), opened here at once. In
    /// the background on the Mac, so whoever is at it keeps their focus.
    private func newTab(in window: ITermCommands.Window?) {
        var arguments = ["new-window"]
        if let window, let anchor = window.tabs.first?.sessions.first {
            arguments = ["new-tab", anchor.sessionID, "--background"]
        }
        run(arguments) { output in
            if let session = try? ITermCommands.decodeJSON(ITermCommands.Session.self, from: output) {
                open(session)
            }
        }
    }

    private func close(_ session: ITermCommands.Session, tab: Bool) {
        // The mirror would only report "the session ended"; drop it with the tab.
        let mirrors = tab
            ? windows.flatMap(\.tabs).first { $0.id == session.tabID }?.sessions ?? [session]
            : [session]
        for mirrored in mirrors { sshManager.remove(SSHSessionID(raw: "iterm-\(mirrored.sessionID)")) }
        run(["close", session.sessionID, "--force"] + (tab ? ["--tab"] : []))
    }

    private func open(_ session: ITermCommands.Session) {
        guard let host else { return }
        let existing = sshManager.session(SSHSessionID(raw: "iterm-\(session.sessionID)"))
        // A mirror that ended (the tab closed, the link dropped) starts over.
        if let existing, existing.state != .ready, existing.state != .connecting {
            existing.restart()
        }
        do {
            let id = try sshManager.openITermView(host: host.hostname, port: host.port,
                                                  username: host.sshUsername, session: session)
            #if os(visionOS)
            pushSessionWindow(id: "ssh-terminal", value: id)
            #else
            // A new session is raised by the shell itself; only a running one
            // needs asking for again.
            if existing != nil { reenter(id) }
            #endif
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
