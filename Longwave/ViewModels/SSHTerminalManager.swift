import DebugTrace
import Foundation
import SwiftTerm
import NIOSSH
import NIOTransportServices

/// Window value for a terminal scene — one window per SSH session.
///
/// `Identifiable` because a platform with one window presents a terminal as a
/// cover or a sheet, and those address content by item identity rather than by
/// window value. The id already existed; this only says so.
struct SSHSessionID: Hashable, Codable, Sendable, Identifiable {
    let raw: String

    var id: String { raw }
}


/// A single interactive SSH terminal session. MainActor `@Observable` view
/// model that owns an off-main `SSHConnection` and bridges its byte stream to a
/// SwiftTerm `TerminalView`. Persistence/re-attach across drops is delegated to
/// `tmux` on the Mac, so this holds no scrollback state of its own — a reopened
/// window just re-runs `tmux new -A` and the server replays the pane.
@Observable
@MainActor
final class SSHSession: Identifiable {
    let id: SSHSessionID
    let title: String
    let host: String
    let port: Int
    let username: String
    let kind: Kind
    /// Working directory for managed Claude sessions (nil for plain shells).
    let cwd: String?

    enum Kind: Sendable { case shell, claude }

    /// tmux session name on the host. Claude sessions use the bare slug; shell
    /// sessions are namespaced with a `vnc-` prefix (see `newShellSession`). A
    /// non-tmux shell has no such session — killing this name is a harmless no-op.
    var tmuxSessionName: String { kind == .claude ? id.raw : "vnc-\(id.raw)" }

    enum State: Equatable {
        case connecting
        case ready
        case closed(String?)
        case failed(String)
    }
    private(set) var state: State = .connecting

    /// The live terminal view, set when a window attaches. Weak: the window can
    /// come and go while the session (and its SSH connection) lives on.
    weak var terminalView: TerminalView?
    private var pendingOutput: [UInt8] = []
    private var connection: SSHConnection?

    // Output pacing. Every `feed` drives UIKit hard — SwiftTerm rewrites its
    // scroll offset per emitted line, repaints through CoreText and runs a
    // display link — and a stream like a coding agent's TUI arrives in dozens of
    // small reads a second. That churn is what still ended visionOS dictation
    // after the first-responder thefts were fixed ("dictation stops while a
    // window has actively changing text"), from a *sibling* window and without
    // touching the responder chain. So while text entry is live anywhere in the
    // app, reads coalesce into one paced feed (see `TextEntryPacing`); with
    // nothing being edited there is no pacing at all and output feeds as it
    // arrives, exactly as before.
    private var bufferedOutput: [UInt8] = []
    private var lastFeed: ContinuousClock.Instant?
    private var feedTask: Task<Void, Never>?

    /// Last size reported by the terminal view; reconnects open the PTY at
    /// this size instead of the config default.
    private var lastCols = 80
    private var lastRows = 24

    /// A non-PTY step run before every PTY connect — the create half of an
    /// `AgentLaunch`, with its env payload for stdin.
    struct Prelaunch: Sendable {
        let command: String
        let stdin: Data
    }

    // Retained so `restart()` can rebuild the connection with the same launch.
    private var config: SSHConnection.Config?
    private var prelaunch: Prelaunch?
    /// Bumped on every connect so a create step that finishes after a newer
    /// connect (or a terminate) can't open a stale PTY.
    private var connectGeneration = 0
    private var privateKey: NIOSSHPrivateKey?
    private var group: NIOTSEventLoopGroup?

    // Auto-reconnect (mirrors AudioStreamManager's idioms): a drop while the
    // session's window is visible schedules a capped-backoff retry; scene
    // activation retries immediately. tmux on the host makes this lossless.
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 2
    private var pendingDetachTask: Task<Void, Never>?
    private var windowVisible = false
    private var userTerminated = false
    /// True while a drop-triggered reconnect is pending or in flight (drives
    /// the "Reconnecting…" status row).
    private(set) var isAutoReconnecting = false

    /// Backoff: doubled per consecutive failure, capped at 30 s.
    static func nextRetryDelay(_ current: TimeInterval) -> TimeInterval {
        min(current * 2, 30)
    }

    init(id: SSHSessionID, title: String, host: String, port: Int, username: String,
         kind: Kind, cwd: String?) {
        self.id = id
        self.title = title
        self.host = host
        self.port = port
        self.username = username
        self.kind = kind
        self.cwd = cwd
    }

    func start(config: SSHConnection.Config, privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup,
               prelaunch: Prelaunch? = nil) {
        self.config = config
        self.privateKey = privateKey
        self.group = group
        self.prelaunch = prelaunch
        connect()
    }

    /// Register a session that should connect lazily — when its window first
    /// appears — rather than immediately. Used for sessions rediscovered on the
    /// host after an app restart: marking the state `.closed` makes the window's
    /// `onAppear` (`ensureConnected`) bring up the stored launch command, so we
    /// don't open an SSH connection for every live session the user never views.
    func prepareLazy(config: SSHConnection.Config, privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup) {
        self.config = config
        self.privateKey = privateKey
        self.group = group
        state = .closed(nil)
    }

    /// Reconnect after a drop or a wedged launch (manual button or auto-retry).
    /// Re-runs the original launch: the create step (if any) is a no-op for a
    /// surviving remote session and recreates it if the program exited (e.g.
    /// claude after Ctrl+C), then the PTY re-attaches.
    func restart() {
        userTerminated = false
        retryTask?.cancel()
        retryTask = nil
        connection?.close()
        // Full terminal reset (RIS) so stale output from the dead connection
        // doesn't mix with the relaunch.
        let reset: [UInt8] = [0x1B, 0x63]
        // Drop anything still paced from the dead connection first — it must not
        // land after the reset and mix into the relaunch.
        feedTask?.cancel()
        feedTask = nil
        bufferedOutput.removeAll()
        terminalView?.feed(byteArray: reset[...])
        pendingOutput.removeAll()
        connect()
    }

    /// Window became visible (appear / scene re-activation): revive a dead
    /// connection immediately — scene activation shouldn't wait out backoff.
    /// A connection killed silently during suspension surfaces via TCP
    /// keepalive within seconds and routes through `.closed` → retry.
    func ensureConnected() {
        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        windowVisible = true
        guard !userTerminated else { return }
        switch state {
        case .closed, .failed:
            retryDelay = 2
            isAutoReconnecting = true
            restart()
        case .connecting, .ready:
            break
        }
    }

    /// Window went away. visionOS fires transient `onDisappear` during space
    /// restoration, so visibility flips only after a 2 s grace (same idiom as
    /// `AudioStreamManager.windowDisappeared`). The connection itself is kept —
    /// sessions outlive windows by design — only auto-retry stops.
    func windowDisappeared() {
        pendingDetachTask?.cancel()
        pendingDetachTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.windowVisible = false
            self.retryTask?.cancel()
            self.retryTask = nil
            self.isAutoReconnecting = false
        }
    }

    private func scheduleRetry() {
        guard windowVisible, !userTerminated else { return }
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = Self.nextRetryDelay(retryDelay)
        isAutoReconnecting = true
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.windowVisible, !self.userTerminated else {
                self.isAutoReconnecting = false
                return
            }
            switch self.state {
            case .closed, .failed:
                self.restart()
            case .connecting, .ready:
                break
            }
        }
    }

    private func connect() {
        guard let privateKey, let group, config != nil else { return }
        state = .connecting
        connectGeneration += 1
        guard let prelaunch else {
            openTerminal()
            return
        }
        let generation = connectGeneration
        connection = nil
        SSHCommandRunner.run(host: host, port: port, username: username, command: prelaunch.command,
                             stdin: prelaunch.stdin, privateKey: privateKey, group: group) { result in
            Task { @MainActor [weak self] in
                guard let self, generation == self.connectGeneration, !self.userTerminated else { return }
                self.finishPrelaunch(result)
            }
        }
    }

    private func finishPrelaunch(_ result: Result<String, Error>) {
        switch result {
        case .success(let output) where output.contains(SSHTerminalManager.agentCreatedMarker):
            openTerminal()
        case .success(let output) where output.contains(SSHTerminalManager.agentNoTmuxMarker):
            // Retrying can't install tmux, so don't schedule one.
            state = .failed("tmux isn't installed on this host (or isn't on the login shell's PATH).")
        case .success:
            state = .failed("The session couldn't be created on the host.")
            scheduleRetry()
        case .failure(let error):
            state = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    private func openTerminal() {
        guard var config, let privateKey, let group else { return }
        config.cols = lastCols
        config.rows = lastRows
        let conn = SSHConnection(config: config, privateKey: privateKey, group: group)
        // Events are dropped unless they come from the *current* connection, so
        // a discarded connection's close can't clobber a restarted session.
        conn.onEvent = { [weak self, weak conn] event in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, conn === self.connection else { return }
                self.handle(event)
            }
        }
        connection = conn
        conn.start()
    }

    private func handle(_ event: SSHConnection.Event) {
        switch event {
        case .ready:
            state = .ready
            retryDelay = 2
            isAutoReconnecting = false
            // Belt-and-braces: replay the live size in case the PTY opened at
            // the config default (idempotent — tmux ignores no-op resizes).
            connection?.resize(cols: lastCols, rows: lastRows)
            if let queued = queuedComposerText {
                queuedComposerText = nil
                _ = sendText(queued)
                sendSubmitReturn()
            }
        case .output(let bytes):
            if terminalView != nil {
                bufferedOutput.append(contentsOf: bytes)
                pumpBufferedOutput()
            } else {
                pendingOutput.append(contentsOf: bytes)
            }
        case .closed(let reason):
            state = .closed(reason)
            scheduleRetry()
        case .failed(let message):
            state = .failed(message)
            scheduleRetry()
        }
    }

    /// Feed coalesced output if the current pacing allows, otherwise arm a timer
    /// for the remaining wait. The level is re-read on every wake, so output
    /// returns to full rate as soon as the text session ends.
    private func pumpBufferedOutput() {
        guard !bufferedOutput.isEmpty, let view = terminalView else { return }
        let interval = TextInputActivity.shared.minimumUpdateInterval
        let now = ContinuousClock.now
        // No previous feed counts as due, and an unpaced (`.zero`) interval is
        // always due — so the idle path feeds straight through.
        let elapsed = lastFeed.map { now - $0 } ?? interval
        if elapsed >= interval {
            feedTask?.cancel()
            feedTask = nil
            let bytes = bufferedOutput
            bufferedOutput.removeAll(keepingCapacity: true)
            lastFeed = now
            view.feed(byteArray: bytes[...])
            return
        }
        guard feedTask == nil else { return }
        let remaining = interval - elapsed
        feedTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: remaining)
            guard let self, !Task.isCancelled else { return }
            self.feedTask = nil
            self.pumpBufferedOutput()
        }
    }

    /// Bind the terminal view, flushing any output that arrived before attach.
    func attach(_ view: TerminalView) {
        terminalView = view
        if !pendingOutput.isEmpty {
            view.feed(byteArray: pendingOutput[...])
            pendingOutput.removeAll()
            lastFeed = ContinuousClock.now
        }
        pumpBufferedOutput()
    }

    func detach() {
        terminalView = nil
        feedTask?.cancel()
        feedTask = nil
        // Nothing paced is lost: it goes back in the pre-attach queue, ahead of
        // anything that arrives while no view is bound.
        if !bufferedOutput.isEmpty {
            pendingOutput.insert(contentsOf: bufferedOutput, at: 0)
            bufferedOutput.removeAll()
        }
    }

    /// Scroll the terminal a page. Routed through `scrollPage(up:)` so the
    /// buttons land wherever the drag gesture would: the emulator's scrollback
    /// for a plain terminal, wheel events for a program tracking the mouse.
    func scrollPageUp() { terminalView?.scrollPage(up: true) }
    func scrollPageDown() { terminalView?.scrollPage(up: false) }

    /// Scroll by steps — positive moves toward earlier output. Backs the keyboard
    /// window's scroll pad, and lands in the same place a drag would.
    func scrollSteps(_ steps: Int) { terminalView?.scrollBySteps(steps) }

    var isReady: Bool { state == .ready }

    /// Composer text that couldn't be delivered (connection down), shown as a
    /// pending chip in the UI and flushed on the next `.ready`. Historically
    /// this text was silently dropped and the composer cleared — lost input.
    private(set) var queuedComposerText: String?

    @discardableResult
    func sendBytes(_ bytes: [UInt8]) -> Bool { connection?.send(bytes) ?? false }

    @discardableResult
    func sendText(_ text: String) -> Bool { connection?.send(Array(text.utf8)) ?? false }

    /// Send composer text and submit it, or queue it for delivery on the next
    /// `.ready` when the connection is down. Returns whether it was sent
    /// immediately.
    @discardableResult
    func sendComposerText(_ text: String) -> Bool {
        if sendText(text) {
            sendSubmitReturn()
            queuedComposerText = nil
            return true
        }
        queuedComposerText = text
        return false
    }

    /// Send a lone carriage return (Enter) as its own delayed write. TUI agents
    /// like claude/copilot detect pastes by chunk content: a CR arriving in the
    /// same PTY read() as the message text is inserted as a literal newline
    /// instead of submitting. Delivering Enter on a separate, slightly-delayed
    /// read makes it register as a submit keypress (matches what sending a bare
    /// Return from the quick-key row does).
    private func sendSubmitReturn() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            self?.sendBytes([0x0D])
        }
    }

    /// Drop queued composer text (user changed their mind).
    func clearQueuedComposerText() { queuedComposerText = nil }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        lastCols = cols
        lastRows = rows
        connection?.resize(cols: cols, rows: rows)
    }

    func terminate() {
        userTerminated = true
        retryTask?.cancel()
        retryTask = nil
        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        isAutoReconnecting = false
        connection?.close()
    }
}

/// Owns the device SSH key, the shared NIO event-loop group, and the set of
/// live terminal sessions.
@Observable
@MainActor
final class SSHTerminalManager: AgentSessionCommandBuilding {
    private(set) var sessions: [SSHSession] = []

    private let group = NIOTSEventLoopGroup()
    private var cachedKey: SecureEnclaveSSHKey?
    private let log = DebugLogger(subsystem: "pro.longwave", category: "SSHManager")

    /// The Vision Pro's SSH identity (Secure Enclave where available).
    func deviceKey() throws -> SecureEnclaveSSHKey {
        if let cachedKey { return cachedKey }
        let key = try SecureEnclaveSSHKey.loadOrCreate()
        cachedKey = key
        return key
    }

    func session(_ id: SSHSessionID) -> SSHSession? {
        sessions.first { $0.id == id }
    }

    /// Open or re-attach a generic interactive SSH terminal. Empty `command`
    /// requests a login shell; a non-empty command is exec'd verbatim. With
    /// `useTmux` (default) the session is tmux-backed — same drop-survival as
    /// Claude sessions — falling back to a plain shell on hosts without tmux.
    @discardableResult
    func newShellSession(host: String, port: Int, username: String,
                         displayName: String, command: String,
                         environment: [(name: String, value: String)] = [],
                         useTmux: Bool = true) throws -> SSHSessionID {
        let title = displayName.isEmpty ? host : displayName
        let slug = Self.slug(title)
        // "vnc-" namespaces terminal sessions apart from Claude project slugs.
        let launch = useTmux
            ? Self.persistentShellCommand(tmuxSession: "vnc-\(slug)", launch: command,
                                          environment: environment)
            : Self.shellCommand(launch: command, environment: environment)
        return try startSession(slug: slug, title: title, host: host, port: port,
                                username: username, command: launch, kind: .shell, cwd: nil)
    }

    /// Open or re-attach a managed Claude session in `folder`, tmux-backed so it
    /// survives disconnects (created if absent, then attached) under a
    /// login+interactive shell (brew/nvm/bun PATHs resolve). Creation and attach
    /// are separate channels so the token never reaches an argv — see
    /// `AgentLaunch`.
    ///
    /// `agentKey` distinguishes agents launched in the same folder: it's folded
    /// into both the tmux session name and the `SSHSessionID`, so switching from
    /// (say) Claude to Copilot starts a separate tmux session instead of
    /// re-attaching the one still running the previous agent (an existing
    /// session would otherwise ignore the new command/token). Empty for the
    /// default agent so pre-existing sessions keep their bare slug.
    @discardableResult
    func newClaudeSession(host: String, port: Int, username: String,
                          folder: String, projectName: String,
                          clientCommand: String = "claude",
                          agentKey: String = "",
                          environment: [(name: String, value: String)] = [],
                          setup: AgentSessionSetup? = nil) throws -> SSHSessionID {
        let title = projectName.isEmpty ? Self.folderName(folder) : projectName
        let base = Self.slug(title)
        let slug = agentKey.isEmpty ? base : Self.slug("\(base)-\(agentKey)")
        let launch = Self.agentLaunch(tmuxSession: slug, folder: folder,
                                      clientCommand: clientCommand,
                                      environment: environment,
                                      setup: setup)
        return try startSession(slug: slug, title: title, host: host, port: port,
                                username: username, command: launch.attach, kind: .claude, cwd: folder,
                                prelaunch: SSHSession.Prelaunch(command: launch.create, stdin: launch.payload))
    }

    private func startSession(slug: String, title: String, host: String, port: Int,
                              username: String, command: String,
                              kind: SSHSession.Kind, cwd: String?,
                              prelaunch: SSHSession.Prelaunch? = nil) throws -> SSHSessionID {
        let id = SSHSessionID(raw: slug)
        if let existing = session(id) { return existing.id }

        let key = try deviceKey()
        let config = SSHConnection.Config(
            host: host, port: port, username: username,
            command: command, cols: 80, rows: 24
        )
        let session = SSHSession(id: id, title: title, host: host, port: port, username: username, kind: kind, cwd: cwd)
        sessions.append(session)
        session.start(config: config, privateKey: key.nioPrivateKey, group: group, prelaunch: prelaunch)
        log.info("Opened SSH session \(slug, privacy: .private(mask: .hash)) to \(host, privacy: .private(mask: .hash))")
        return id
    }

    func remove(_ id: SSHSessionID) {
        session(id)?.terminate()
        sessions.removeAll { $0.id == id }
    }

    /// Stop a session from the UI. This also kills the tmux session on the host,
    /// so the agent (or shell) actually exits — a plain disconnect leaves it
    /// running (the user previously had to Ctrl+C on the Mac) and it would be
    /// resurrected by the next rediscovery pass.
    func stopSession(_ id: SSHSessionID) {
        if let s = session(id) {
            killTmux(host: s.host, port: s.port, username: s.username, name: s.tmuxSessionName)
        }
        remove(id)
    }

    /// Force a clean restart for a wedged session (e.g. a frozen shell that a
    /// plain reconnect would just re-attach to): kill the remote tmux session so
    /// the next launch creates a fresh one, then relaunch. Waits for the kill to
    /// land before restarting so `tmux new -A` can't re-attach the dead pane.
    func forceRestartSession(_ id: SSHSessionID) {
        guard let s = session(id) else { return }
        let host = s.host, port = s.port, user = s.username, name = s.tmuxSessionName
        Task { [weak self] in
            _ = try? await self?.runTmux(
                host: host, port: port, username: user,
                command: "tmux kill-session -t \(Self.target(name)) 2>/dev/null")
            s.restart()
        }
    }

    /// Fire-and-forget `tmux kill-session` on the host (no-op if no such session).
    private func killTmux(host: String, port: Int, username: String, name: String) {
        Task { [weak self] in
            _ = try? await self?.runTmux(
                host: host, port: port, username: username,
                command: "tmux kill-session -t \(Self.target(name)) 2>/dev/null")
        }
    }

    // MARK: - Remote directory browsing (Projects folder picker)

    /// Absolute home directory on the host — the browser's start point.
    func homeDirectory(host: String, port: Int, username: String) async throws -> String {
        let out = try await runCommand(host: host, port: port, username: username, command: "pwd")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Directory entries at `absolutePath` (dirs first; dotfiles hidden — a
    /// project picker doesn't need `.git`/`.config` noise).
    func listDirectory(host: String, port: Int, username: String, absolutePath: String) async throws -> [DirEntry] {
        let command = "ls -1p -- \(Self.shellSingleQuote(absolutePath))"
        let out = try await runCommand(host: host, port: port, username: username, command: command)
        return Self.parseLsEntries(out)
    }

    // MARK: - Stale-session garbage collection

    /// Reap abandoned app-created sessions on the host. Run on connect, before
    /// rediscovery, so reaped sessions simply don't reappear in the list. Silent
    /// on any failure (no tmux, no server, host unreachable).
    func reapStaleSessions(host: String, port: Int, username: String) async {
        let command = Self.staleSessionReapCommand(ttlSeconds: Self.staleSessionTTLSeconds)
        _ = try? await runTmux(host: host, port: port, username: username, command: command)
    }

    // MARK: - Session rediscovery (after app restart)

    /// The in-memory `sessions` list doesn't survive an app relaunch, but the
    /// agents' tmux sessions keep running on the host. Query the host's tmux
    /// server and register a lazily-connecting `SSHSession` for each agent
    /// session not already tracked, so they reappear under "Running Sessions"
    /// and a tap re-attaches. Generic shell sessions (`vnc-` prefix) are skipped.
    /// Silent on any failure (no tmux, no server, host unreachable).
    func discoverClaudeSessions(host: String, port: Int, username: String) async {
        // Tab-separated so paths with spaces survive; `2>/dev/null` keeps the
        // "no server running" stderr out of the parsed output. Parsing (the
        // `@longwave` marker filter, skipping `vnc-` shell sessions, titles) is
        // shared with the Mac client in `parseDiscoveredSessions`.
        guard let out = try? await runTmux(host: host, port: port, username: username,
                                           command: Self.discoverSessionsCommand) else {
            return
        }
        let key = try? deviceKey()
        for found in Self.parseDiscoveredSessions(out) {
            let name = found.name, folder = found.folder, title = found.title
            let id = SSHSessionID(raw: name)
            guard session(id) == nil else { continue }
            let session = SSHSession(id: id, title: title, host: host, port: port, username: username,
                                     kind: .claude, cwd: folder.isEmpty ? nil : folder)
            if let key {
                let config = SSHConnection.Config(host: host, port: port, username: username,
                                                  command: Self.attachCommand(tmuxSession: name),
                                                  cols: 80, rows: 24)
                session.prepareLazy(config: config, privateKey: key.nioPrivateKey, group: group)
            }
            sessions.append(session)
            log.info("Rediscovered tmux session \(name, privacy: .private(mask: .hash)) on \(host, privacy: .private(mask: .hash))")
        }
    }

    /// Run a remote command that needs the user's real `PATH` — i.e. anything
    /// invoking `tmux`. `runCommand` alone is not enough: it goes down an SSH
    /// exec channel, which runs a non-interactive shell that never sources the
    /// files Homebrew's PATH lives in, so `tmux` isn't on it and every call
    /// failed as `command not found` into the `2>/dev/null` these commands
    /// carry. Silent no-ops were the result: "Close Session" left the agent
    /// running, and rediscovery after a restart found nothing to restore.
    ///
    /// An interactive shell's rc files can print banners, so callers must parse
    /// defensively — `discoverClaudeSessions` already requires three
    /// tab-separated fields with the `@longwave` marker last, which no banner
    /// line satisfies.
    private func runTmux(host: String, port: Int, username: String, command: String) async throws -> String {
        try await runCommand(host: host, port: port, username: username,
                             command: Self.loginShellCommand(command))
    }

    private func runCommand(host: String, port: Int, username: String, command: String) async throws -> String {
        let key = try deviceKey()
        let group = self.group
        return try await withCheckedThrowingContinuation { continuation in
            SSHCommandRunner.run(host: host, port: port, username: username, command: command,
                                 privateKey: key.nioPrivateKey, group: group) { result in
                continuation.resume(with: result)
            }
        }
    }

}
