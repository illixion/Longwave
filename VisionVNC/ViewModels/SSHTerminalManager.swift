import Foundation
import SwiftTerm
import NIOSSH
import NIOTransportServices
import os

/// Window value for a terminal scene — one window per SSH session.
struct SSHSessionID: Hashable, Codable, Sendable {
    let raw: String
}

/// A remote directory entry from the Projects folder browser.
struct DirEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isDir: Bool
    var id: String { name }
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

    // Retained so `restart()` can rebuild the connection with the same launch.
    private var config: SSHConnection.Config?
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

    func start(config: SSHConnection.Config, privateKey: NIOSSHPrivateKey, group: NIOTSEventLoopGroup) {
        self.config = config
        self.privateKey = privateKey
        self.group = group
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
    /// Re-runs the original launch command: tmux `new -A` re-attaches a
    /// surviving remote session, or creates a fresh one if the program exited
    /// (e.g. claude after Ctrl+C).
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
        guard var config, let privateKey, let group else { return }
        state = .connecting
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

    /// Scroll the terminal scrollback a page. SwiftTerm's iOS view scrolls via
    /// the terminal's yDisp (driven by this public API), not the UIScrollView
    /// drag — so explicit controls are the way to reach history.
    func scrollPageUp() { terminalView?.pageUp() }
    func scrollPageDown() { terminalView?.pageDown() }

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
final class SSHTerminalManager {
    private(set) var sessions: [SSHSession] = []

    private let group = NIOTSEventLoopGroup()
    private var cachedKey: SecureEnclaveSSHKey?
    private let log = Logger(subsystem: "com.illixion.VisionVNC", category: "SSHManager")

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
    /// survives disconnects (`-A` = attach-or-create) under a login+interactive
    /// shell (brew/nvm/bun PATHs resolve).
    ///
    /// `agentKey` distinguishes agents launched in the same folder: it's folded
    /// into both the tmux session name and the `SSHSessionID`, so switching from
    /// (say) Claude to Copilot starts a separate tmux session instead of
    /// re-attaching the one still running the previous agent (`tmux new -A`
    /// would otherwise ignore the new command/token). Empty for the default
    /// agent so pre-existing sessions keep their bare slug.
    @discardableResult
    func newClaudeSession(host: String, port: Int, username: String,
                          folder: String, projectName: String,
                          clientCommand: String = "claude",
                          agentKey: String = "",
                          environment: [(name: String, value: String)] = []) throws -> SSHSessionID {
        let title = projectName.isEmpty ? Self.folderName(folder) : projectName
        let base = Self.slug(title)
        let slug = agentKey.isEmpty ? base : Self.slug("\(base)-\(agentKey)")
        let command = Self.claudeCommand(tmuxSession: slug, folder: folder,
                                         clientCommand: clientCommand,
                                         environment: environment)
        return try startSession(slug: slug, title: title, host: host, port: port,
                                username: username, command: command, kind: .claude, cwd: folder)
    }

    private func startSession(slug: String, title: String, host: String, port: Int,
                              username: String, command: String,
                              kind: SSHSession.Kind, cwd: String?) throws -> SSHSessionID {
        let id = SSHSessionID(raw: slug)
        if let existing = session(id) { return existing.id }

        let key = try deviceKey()
        let config = SSHConnection.Config(
            host: host, port: port, username: username,
            command: command, cols: 80, rows: 24
        )
        let session = SSHSession(id: id, title: title, host: host, port: port, username: username, kind: kind, cwd: cwd)
        sessions.append(session)
        session.start(config: config, privateKey: key.nioPrivateKey, group: group)
        log.info("Opened SSH session \(slug, privacy: .public) to \(host, privacy: .public)")
        return id
    }

    func remove(_ id: SSHSessionID) {
        session(id)?.terminate()
        sessions.removeAll { $0.id == id }
    }

    /// Stop a session from the UI. For managed agent sessions this also kills
    /// the tmux session on the host, so the agent actually exits (a plain
    /// disconnect leaves it running — the user previously had to Ctrl+C on the
    /// Mac) and it isn't resurrected by the next rediscovery pass.
    func stopSession(_ id: SSHSessionID) {
        if let s = session(id), s.kind == .claude {
            let host = s.host, port = s.port, user = s.username, name = id.raw
            Task { [weak self] in
                _ = try? await self?.runCommand(
                    host: host, port: port, username: user,
                    command: "tmux kill-session -t \(Self.shellSingleQuote(name)) 2>/dev/null")
            }
        }
        remove(id)
    }

    /// tmux-safe session name: alphanumerics, dashes collapsed, never empty.
    static func slug(_ input: String) -> String {
        let scalars = input.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        var out = String(scalars)
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "claude" : out
    }

    private static func folderName(_ path: String) -> String {
        let trimmed = (path.hasSuffix("/") && path != "/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    /// Wrap a string as a single-quoted shell token (robust against spaces and
    /// quotes via the close/escape/reopen idiom). Applied twice for the Claude
    /// command — once for the folder, once for the whole inner command — so the
    /// double shell nesting (sshd's `$SHELL -c` → `zsh -lic`) stays correct.
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The tmux create-or-attach line shared by managed Claude sessions and
    /// persistent shell sessions. Empty `client` → tmux runs its default shell.
    private static func tmuxLaunchLine(tmuxSession: String, folder: String,
                                       client: String,
                                       environment: [(name: String, value: String)]) -> String {
        let vars = environment.filter { !$0.name.isEmpty }
        var line = ""
        // A tmux server started before these vars existed snapshots an env
        // without them, and new sessions inherit that snapshot. Registering the
        // names in update-environment makes tmux import them from this client
        // when the session is created — so the token reaches `claude` even if a
        // server is already running, while staying scoped to this session (not
        // the server's global env). Verified on tmux 3.6.
        for v in vars {
            line += "tmux set -gqa update-environment \(shellSingleQuote(v.name)) >/dev/null 2>&1; "
        }
        // Inline assignments scope the secret to the short-lived `tmux new`
        // child's environment — never written to disk, and macOS redacts a
        // process's env from other (non-root) processes.
        for v in vars {
            line += "\(v.name)=\(shellSingleQuote(v.value)) "
        }
        line += "tmux new -A -d -s \(tmuxSession)"
        if !folder.isEmpty { line += " -c \(shellSingleQuote(folder))" }
        if !client.isEmpty { line += " \(client)" }
        line += "; "
        // Tag sessions this app creates with a user option so rediscovery after
        // an app restart can tell them apart from the user's own stray tmux
        // sessions (which it must never list or offer to kill).
        line += "tmux set-option -t \(tmuxSession) @visionvnc 1 >/dev/null 2>&1; "
        // `exec` replaces this shell with the attach client, so the token-
        // bearing argv of `tmux new` is shed within milliseconds of launch.
        // `attach -d` detaches stale clients left behind by dropped connections
        // (tracking loss) so they can't pin the tmux window at the old size —
        // it also displaces any other legitimately attached client, accepted
        // for this app's one-window-per-session model.
        line += "exec tmux attach -d -t \(tmuxSession)"
        return line
    }

    static func claudeCommand(tmuxSession: String, folder: String,
                              clientCommand: String = "claude",
                              environment: [(name: String, value: String)] = []) -> String {
        let client = clientCommand.isEmpty ? "claude" : clientCommand
        let inner = tmuxLaunchLine(tmuxSession: tmuxSession, folder: folder,
                                   client: client, environment: environment)
        return "zsh -lic \(shellSingleQuote(inner))"
    }

    /// Re-attach an already-running tmux session — no create, no command, no
    /// token (the live session already carries the agent and its env). Used to
    /// reconnect to sessions rediscovered on the host after an app restart.
    static func attachCommand(tmuxSession: String) -> String {
        "zsh -lic \(shellSingleQuote("exec tmux attach -d -t \(tmuxSession)"))"
    }

    /// tmux-wrapped generic terminal session: survives connection drops like a
    /// Claude session, with a runtime fallback to a plain (non-persistent)
    /// shell on hosts without tmux installed.
    static func persistentShellCommand(tmuxSession: String, launch: String,
                                       environment: [(name: String, value: String)] = []) -> String {
        let tmuxPath = tmuxLaunchLine(tmuxSession: tmuxSession, folder: "",
                                      client: launch, environment: environment)
        var fallback = shellCommand(launch: launch, environment: environment)
        if fallback.isEmpty { fallback = "exec \"$SHELL\" -l" }
        let inner = "if command -v tmux >/dev/null 2>&1; then \(tmuxPath); else \(fallback); fi"
        return "zsh -lic \(shellSingleQuote(inner))"
    }

    /// Builds a generic (non-tmux) session command carrying non-secret
    /// `environment`. No env → `launch` unchanged (empty → a login shell).
    /// Otherwise the assignments prefix the command, or an exec'd login shell.
    static func shellCommand(launch: String,
                             environment: [(name: String, value: String)] = []) -> String {
        let assignments = environment
            .filter { !$0.name.isEmpty }
            .map { "\($0.name)=\(shellSingleQuote($0.value)) " }
            .joined()
        guard !assignments.isEmpty else { return launch }
        if launch.isEmpty { return "\(assignments)exec \"$SHELL\" -l" }
        return "\(assignments)\(launch)"
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

    /// How long an app-created tmux session may sit with no attached client and
    /// no activity before it's considered abandoned and reaped. Short disconnects
    /// (window close, network blip, reconnect) stay well under this, so the
    /// reconnect-to-a-running-agent behaviour is preserved; what it kills is the
    /// long tail of sessions nobody came back to. Reaping them also frees agents
    /// pinning a stale on-disk binary after a `claude` self-update (a running
    /// process keeps executing the old inode until it exits and relaunches).
    static let staleSessionTTLSeconds = 12 * 60 * 60  // 12h

    /// Server-side reap pipeline: for every `@visionvnc`-tagged session with zero
    /// attached clients whose last activity is older than `ttlSeconds`, kill it.
    /// The host's own clock (`date +%s` vs tmux `#{session_activity}`, both host
    /// epoch) is used so device/host clock skew can't mis-fire. Untagged sessions
    /// (the user's own) and currently-attached ones (in use on this or another
    /// device) are never touched. POSIX-`sh`-safe so it runs under either login
    /// shell sshd hands us.
    static func staleSessionReapCommand(ttlSeconds: Int) -> String {
        "now=$(date +%s); tmux list-sessions "
            + "-F '#{session_attached}|#{session_activity}|#{@visionvnc}|#{session_name}' 2>/dev/null "
            + "| while IFS='|' read -r att act mark name; do "
            + "[ \"$mark\" = 1 ] && [ \"$att\" = 0 ] && [ $((now - act)) -gt \(ttlSeconds) ] "
            + "&& tmux kill-session -t \"$name\"; done"
    }

    /// Reap abandoned app-created sessions on the host. Run on connect, before
    /// rediscovery, so reaped sessions simply don't reappear in the list. Silent
    /// on any failure (no tmux, no server, host unreachable).
    func reapStaleSessions(host: String, port: Int, username: String) async {
        let command = Self.staleSessionReapCommand(ttlSeconds: Self.staleSessionTTLSeconds)
        _ = try? await runCommand(host: host, port: port, username: username, command: command)
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
        // "no server running" stderr out of the parsed output. The `@visionvnc`
        // marker (set on every session this app creates) filters out the user's
        // own stray tmux sessions; shell sessions (`vnc-` prefix) are skipped too.
        let command = "tmux list-sessions -F '#{session_name}\t#{session_path}\t#{@visionvnc}' 2>/dev/null"
        guard let out = try? await runCommand(host: host, port: port, username: username, command: command) else {
            return
        }
        let key = try? deviceKey()
        for raw in out.split(separator: "\n") {
            // name \t path \t marker — marker is the last field; the middle is
            // rejoined so a (pathological) tab in the path can't shift it.
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            guard !name.isEmpty, !name.hasPrefix("vnc-"), parts[parts.count - 1] == "1" else { continue }
            let id = SSHSessionID(raw: name)
            guard session(id) == nil else { continue }
            let folder = parts[1..<(parts.count - 1)].joined(separator: "\t")
            let base = folder.isEmpty ? name : Self.folderName(folder)
            // Surface the agent suffix (`proj-copilot` → "proj (Copilot)") so two
            // agents launched in the same folder are distinguishable as rows.
            var title = base
            let baseSlug = Self.slug(base)
            if name != baseSlug, name.hasPrefix(baseSlug + "-") {
                title = "\(base) (\(name.dropFirst(baseSlug.count + 1).capitalized))"
            }
            let session = SSHSession(id: id, title: title, host: host, port: port, username: username,
                                     kind: .claude, cwd: folder.isEmpty ? nil : folder)
            if let key {
                let config = SSHConnection.Config(host: host, port: port, username: username,
                                                  command: Self.attachCommand(tmuxSession: name),
                                                  cols: 80, rows: 24)
                session.prepareLazy(config: config, privateKey: key.nioPrivateKey, group: group)
            }
            sessions.append(session)
            log.info("Rediscovered tmux session \(name, privacy: .public) on \(host, privacy: .public)")
        }
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

    static func parseLsEntries(_ output: String) -> [DirEntry] {
        output.split(separator: "\n").compactMap { raw -> DirEntry? in
            let s = String(raw)
            guard !s.isEmpty else { return nil }
            if s.hasSuffix("/") {
                return DirEntry(name: String(s.dropLast()), isDir: true)
            }
            return DirEntry(name: s, isDir: false)
        }
        .sorted { ($0.isDir ? 0 : 1, $0.name.lowercased()) < ($1.isDir ? 0 : 1, $1.name.lowercased()) }
    }
}
