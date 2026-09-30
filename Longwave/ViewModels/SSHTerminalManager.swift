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
    /// `SSHTerminalManager.AgentLaunch`, with its env payload for stdin.
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
final class SSHTerminalManager {
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
                          environment: [(name: String, value: String)] = []) throws -> SSHSessionID {
        let title = projectName.isEmpty ? Self.folderName(folder) : projectName
        let base = Self.slug(title)
        let slug = agentKey.isEmpty ? base : Self.slug("\(base)-\(agentKey)")
        let launch = Self.agentLaunch(tmuxSession: slug, folder: folder,
                                      clientCommand: clientCommand,
                                      environment: environment)
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

    /// A tmux `-t` target for exactly this session, quoted. The leading `=` is
    /// tmux's exact-match prefix: without it `-t` falls back to *prefix*
    /// matching, so `kill-session -t longwave` would happily take out
    /// `longwave-reaper`, and an attach could land on a neighbouring session.
    ///
    /// Accepted by `has-session`, `attach-session`, `kill-session` and
    /// `set-environment` — **not** by `set-option`, whose `-t` is a *pane*
    /// target and which answers `no such session: =name`. Use `optionTarget`
    /// there; a bare name is safe for it because tmux prefers an exact match
    /// and the session has just been created under that exact name.
    static func target(_ tmuxSession: String) -> String {
        shellSingleQuote("=" + tmuxSession)
    }

    /// `set-option -t` target: quoted, but without the `=` exact-match prefix
    /// that `set-option` rejects. Verified against tmux 3.6 — and it fails into
    /// the `2>/dev/null` these lines carry, so getting it wrong would silently
    /// drop the `@longwave` tag (breaking rediscovery and the reaper) and
    /// `mouse on` (breaking scrollback) with no visible error at all.
    static func optionTarget(_ tmuxSession: String) -> String {
        shellSingleQuote(tmuxSession)
    }

    /// Wrap `inner` in a login + interactive shell.
    ///
    /// Interactive is not optional: an SSH *exec* channel runs the login shell
    /// non-interactively, which on macOS sources neither `/etc/zprofile` nor
    /// `~/.zshrc`, so `PATH` comes back as the bare system one. Homebrew's
    /// `/opt/homebrew/bin` is absent from it and `tmux` is simply not found —
    /// verified on this host, where `zsh -c 'command -v tmux'` finds nothing
    /// and `zsh -lic` finds `/opt/homebrew/bin/tmux`. Every remote tmux call
    /// goes through here for that reason.
    static func loginShellCommand(_ inner: String) -> String {
        "zsh -lic \(shellSingleQuote(inner))"
    }

    /// The tmux create-or-attach line for persistent shell sessions. Empty
    /// `client` → tmux runs its default shell. Managed agent sessions don't use
    /// this: their environment carries tokens, so they split creation onto its
    /// own channel (`agentLaunch`) instead of inlining values here.
    private static func tmuxLaunchLine(tmuxSession: String, folder: String,
                                       client: String,
                                       environment: [(name: String, value: String)]) -> String {
        var line = tmuxCreateLine(tmuxSession: tmuxSession, folder: folder, client: client,
                                  environment: environment, inlineValues: true)
        line += sessionOptions(tmuxSession: tmuxSession)
        // `attach -d` detaches stale clients left behind by dropped connections
        // (tracking loss) so they can't pin the tmux window at the old size —
        // it also displaces any other legitimately attached client, accepted
        // for this app's one-window-per-session model.
        line += "exec tmux attach -d -t \(target(tmuxSession))"
        return line
    }

    /// Registers the env names with tmux, creates the session if absent and tags
    /// it. With `inlineValues` the values ride as `NAME='value'` assignments on
    /// `tmux new` (shell sessions, whose environment is non-secret by contract);
    /// without, the caller must already have exported them into this shell.
    private static func tmuxCreateLine(tmuxSession: String, folder: String, client: String,
                                       environment: [(name: String, value: String)],
                                       inlineValues: Bool) -> String {
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
        // Create only if it isn't already there. NOT `tmux new -A -d`: with
        // `-A`, an existing session turns the command into `attach-session`,
        // and tmux then reads `-d` as attach's own flag rather than "stay
        // detached" (the man page maps new-session's `-D` onto it). So the
        // create line silently *attached* whenever the session already
        // existed — verified: `session_attached` goes 0 → 1. `has-session`
        // has no such double meaning. A simultaneous second launch loses the
        // create race with a harmless "duplicate session" on discarded stderr.
        line += "tmux has-session -t \(target(tmuxSession)) 2>/dev/null || "
        // Interactive shells honor TMOUT only while sitting at a prompt. It
        // lets abandoned shell sessions close themselves without interrupting
        // a command or agent that is still running.
        line += "TMOUT=\(promptIdleTimeoutSeconds) "
        if inlineValues {
            for v in vars {
                line += "\(v.name)=\(shellSingleQuote(v.value)) "
            }
        }
        line += "tmux new -d -s \(tmuxSession)"
        if !folder.isEmpty { line += " -c \(shellSingleQuote(folder))" }
        if !client.isEmpty { line += " \(client)" }
        line += "; "
        // Tag sessions this app creates with a user option so rediscovery after
        // an app restart can tell them apart from the user's own stray tmux
        // sessions (which it must never list or offer to kill).
        line += "tmux set-option -t \(optionTarget(tmuxSession)) @longwave 1 >/dev/null 2>&1; "
        return line
    }

    /// A managed agent launch, split in two so no secret is ever in an argv.
    ///
    /// Everything on a process's command line is readable by every local user
    /// through `ps` — macOS redacts another user's *environment*, not its argv.
    /// Inlining `TOKEN='…'` into the exec'd `zsh -lic '<line>'` therefore
    /// published the token for as long as that zsh lived, which includes the
    /// whole of its rc-file startup. On a single-user Mac that was moot; with a
    /// second local account (the agent sandbox) it isn't.
    ///
    /// So `create` runs first on its own non-PTY exec channel and reads the
    /// environment from **stdin** (`payload`, one `NAME=<base64>` line per
    /// variable), exports it inside the shell — never on a command line — and
    /// creates the tmux session. `attach` then goes down the PTY channel and
    /// carries no env at all; it is the same command rediscovered sessions use.
    struct AgentLaunch: Sendable {
        /// Exec'd on a non-PTY channel with `payload` on stdin.
        let create: String
        /// `NAME=<base64(value)>\n` per variable. Send it, then EOF.
        let payload: Data
        /// Exec'd under the PTY once `create` has succeeded.
        let attach: String
    }

    /// Printed by a successful create step; its absence means the create failed.
    static let agentCreatedMarker = "LONGWAVE-SESSION-READY"
    /// Printed when the host has no tmux, so the UI can say so instead of
    /// retrying a launch that can never work.
    static let agentNoTmuxMarker = "LONGWAVE-NO-TMUX"

    static func agentLaunch(tmuxSession: String, folder: String,
                            clientCommand: String = "claude",
                            environment: [(name: String, value: String)] = []) -> AgentLaunch {
        let vars = environment.filter { SavedConnection.isValidEnvName($0.name) }
        let inner = agentCreateScript(tmuxSession: tmuxSession, folder: folder,
                                      clientCommand: clientCommand, names: vars.map(\.name))
        // The reader runs in a plain POSIX `sh` *before* the login shell, so an
        // rc file can't swallow stdin, and whatever shell sshd hands us (bash,
        // zsh, fish) only has to exec `/bin/sh`. The exported values reach
        // `zsh -lic` — and from it `tmux new` — through the environment.
        let create = "/bin/sh -c " + shellSingleQuote(envStdinReader + "exec " + loginShellCommand(inner))
        return AgentLaunch(create: create, payload: envPayload(vars),
                           attach: attachCommand(tmuxSession: tmuxSession))
    }

    /// The login-shell half of `AgentLaunch.create`: registers `names` with
    /// tmux (their values are already exported by `envStdinReader`), creates
    /// and tags the session, and reports the outcome on stdout.
    static func agentCreateScript(tmuxSession: String, folder: String,
                                  clientCommand: String, names: [String]) -> String {
        let client = clientCommand.isEmpty ? "claude" : clientCommand
        var script = "command -v tmux >/dev/null 2>&1 || { echo \(agentNoTmuxMarker); exit 1; }; "
        script += tmuxCreateLine(tmuxSession: tmuxSession, folder: folder, client: client,
                                 environment: names.map { (name: $0, value: "") },
                                 inlineValues: false)
        script += "tmux has-session -t \(target(tmuxSession)) 2>/dev/null && echo \(agentCreatedMarker)"
        return script
    }

    /// Encodes `environment` for `envStdinReader`: base64 keeps quotes,
    /// newlines and `$` in values from ever meeting a shell parser.
    static func envPayload(_ environment: [(name: String, value: String)]) -> Data {
        var out = ""
        for v in environment where SavedConnection.isValidEnvName(v.name) {
            out += "\(v.name)=\(Data(v.value.utf8).base64EncodedString())\n"
        }
        return Data(out.utf8)
    }

    /// POSIX `sh` that exports each `NAME=<base64>` line from stdin.
    ///
    /// Every step that touches a value is a builtin (`read`, `printf`, `export`)
    /// or reads it from a pipe (`base64`), so no value is ever an argument of an
    /// exec'd process. The name check mirrors `SavedConnection.isValidEnvName`.
    /// `printf x` / `${v%x}` preserves trailing newlines that command
    /// substitution would otherwise strip. GNU coreutils decodes with `-d`,
    /// older macOS `base64` only knew `-D`.
    static let envStdinReader =
        "if printf eA== | base64 -d >/dev/null 2>&1; then d=-d; else d=-D; fi; "
        + "while IFS= read -r l || [ -n \"$l\" ]; do "
        + "case $l in *=*) ;; *) continue;; esac; "
        + "n=${l%%=*}; v=${l#*=}; "
        + "case $n in ''|[0-9]*|*[!A-Za-z0-9_]*) continue;; esac; "
        + "v=$(printf %s \"$v\" | base64 $d; printf x); v=${v%x}; "
        + "export \"$n=$v\"; "
        + "done; "

    /// Re-attach an already-running tmux session — no create, no command, no
    /// token (the live session already carries the agent and its env). Used to
    /// reconnect to sessions rediscovered on the host after an app restart.
    /// Session options are deliberately re-applied here so sessions created by
    /// older Longwave versions gain scrolling and the prompt timeout too.
    static func attachCommand(tmuxSession: String) -> String {
        let inner = sessionOptions(tmuxSession: tmuxSession)
            + "exec tmux attach -d -t \(target(tmuxSession))"
        return loginShellCommand(inner)
    }

    /// Options every app-managed session must have, including old sessions
    /// being re-attached after an upgrade.
    ///
    /// `TMOUT` here only ever reaches a **shell**, and only one sitting at a
    /// prompt. A managed agent session's pane process is the agent itself
    /// (verified: `pane_current_command` is the `claude` binary, not a shell), so
    /// TMOUT is structurally incapable of closing one — that's the watchdog's job.
    private static func sessionOptions(tmuxSession: String) -> String {
        "tmux set-environment -t \(target(tmuxSession)) TMOUT \(promptIdleTimeoutSeconds) >/dev/null 2>&1; "
            + mouseOption(tmuxSession: tmuxSession)
            + reaperWatchdogCommand(ttlSeconds: staleSessionTTLSeconds,
                                    intervalSeconds: reaperIntervalSeconds)
    }

    /// Turn on tmux's own mouse handling, scoped to this session.
    ///
    /// Without it the terminal has nothing to scroll: tmux is a full-screen
    /// program, so it lives in the alternate screen buffer where the emulator
    /// keeps no scrollback of its own — the history is tmux's, and only tmux can
    /// move it. With `mouse on` tmux enables mouse tracking (verified: it emits
    /// DECSET 1000/1002/1006 to the client), so the wheel events a drag or a
    /// paging button sends land in its copy-mode instead of falling through to
    /// the shell as PageUp/PageDown — which zsh reads as history navigation, and
    /// which is what "the scroll buttons scroll my history" looked like.
    ///
    /// Deliberately not `-g`: this is the app's own session, and the user's
    /// other tmux sessions on the host are none of its business.
    private static func mouseOption(tmuxSession: String) -> String {
        "tmux set-option -t \(optionTarget(tmuxSession)) mouse on >/dev/null 2>&1; "
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
        return loginShellCommand(inner)
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

    /// Shells exit only after this much inactivity while waiting at a prompt.
    /// `TMOUT` is inherited by the initial shell and stored in the tmux session
    /// environment for any panes created later.
    static let promptIdleTimeoutSeconds = 12 * 60 * 60  // 12h

    /// How long an app-created tmux session may sit with no attached client and
    /// no activity before it's considered abandoned and reaped. Short disconnects
    /// (window close, network blip, reconnect) stay well under this, so the
    /// reconnect-to-a-running-agent behaviour is preserved; what it kills is the
    /// long tail of sessions nobody came back to. Reaping them also frees agents
    /// pinning a stale on-disk binary after a `claude` self-update (a running
    /// process keeps executing the old inode until it exits and relaunches).
    ///
    /// Deliberately **shorter than a full-scope Claude access token's ~8h life**
    /// (see `ClaudeOAuth`). A token is injected once, at launch, into the agent
    /// process's environment — a running process's env can't be rewritten, so
    /// re-attaching a session whose token has expired hands back an agent that
    /// can't authenticate and can only be fixed by restarting it. Reaping before
    /// that point means a stale session is always gone rather than broken.
    static let staleSessionTTLSeconds = 6 * 60 * 60  // 6h

    /// How often the host-side watchdog re-checks. Cheap (one `tmux
    /// list-sessions` per tick), so this is set for responsiveness near the TTL
    /// boundary rather than to save cycles.
    static let reaperIntervalSeconds = 15 * 60

    /// tmux session name for the host-side watchdog. Deliberately **not** tagged
    /// `@longwave`, which keeps it out of both the reap set (it must not kill
    /// itself) and session rediscovery (it isn't a session the user opened).
    static let reaperSessionName = "longwave-reaper"

    /// Starts (or re-uses) a detached watchdog on the host that reaps stale
    /// sessions on an interval and exits once none remain.
    ///
    /// This exists because `reapStaleSessions` only runs when the app connects,
    /// which means nothing collects abandoned sessions while the headset is off —
    /// observed in practice as app-tagged sessions alive after 13h, 14h and 88h
    /// detached against a 12h TTL. A host-side timer is the only thing that closes
    /// them without the app present.
    ///
    /// `has-session ||` is the whole concurrency story: it can't produce a
    /// duplicate, and it transparently restarts a watchdog that died, so no
    /// lockfile or pidfile is needed and nothing is left on the host's disk. Two
    /// launches racing the guard is harmless — the loser's `new` fails with
    /// "duplicate session" onto discarded stderr. The script is base64'd because
    /// it has to survive three levels of shell quoting (`zsh -lic '…'` →
    /// `tmux new … sh -c "…"` → the loop itself); encoded, it carries no quotes
    /// or `$` for an outer layer to chew on.
    static func reaperWatchdogCommand(ttlSeconds: Int, intervalSeconds: Int) -> String {
        // `session_activity` is the idle signal: it advances on pane *output*, and
        // an agent waiting at its prompt is silent, so it stops climbing when the
        // session is genuinely abandoned (verified against real sessions).
        let script = """
        while :; do
        sleep \(intervalSeconds)
        now=$(date +%s)
        tmux list-sessions -F '#{session_attached}|#{session_activity}|#{@longwave}|#{session_name}' 2>/dev/null | while IFS='|' read -r att act mark name; do
        [ "$mark" = 1 ] && [ "$att" = 0 ] && [ $((now - act)) -gt \(ttlSeconds) ] && tmux kill-session -t "$name"
        done
        tmux list-sessions -F '#{@longwave}' 2>/dev/null | grep -q 1 || exit 0
        done
        """
        let encoded = Data(script.utf8).base64EncodedString()
        // `has-session ||` rather than `new -A -d` for the reason given in
        // `tmuxLaunchLine`, and here it was the visible bug: this line runs at
        // the end of every launch, so once a watchdog existed the next launch
        // attached the user's terminal to *it* instead of leaving it detached.
        // What you got was a bare shell under a `[longwave-reaper] 0:bash`
        // status bar — input worked, the project session was nowhere, and the
        // `exec tmux attach` below never ran because this line never returned.
        return "tmux has-session -t \(target(reaperSessionName)) 2>/dev/null || "
            + "tmux new -d -s \(reaperSessionName) "
            + "sh -c \"echo \(encoded)|base64 -d|sh\" >/dev/null 2>&1; "
    }

    /// Server-side reap pipeline: for every `@longwave`-tagged session with zero
    /// attached clients whose last activity is older than `ttlSeconds`, kill it.
    /// The host's own clock (`date +%s` vs tmux `#{session_activity}`, both host
    /// epoch) is used so device/host clock skew can't mis-fire. Untagged sessions
    /// (the user's own) and currently-attached ones (in use on this or another
    /// device) are never touched. POSIX-`sh`-safe so it runs under either login
    /// shell sshd hands us.
    static func staleSessionReapCommand(ttlSeconds: Int) -> String {
        "now=$(date +%s); tmux list-sessions "
            + "-F '#{session_attached}|#{session_activity}|#{@longwave}|#{session_name}' 2>/dev/null "
            + "| while IFS='|' read -r att act mark name; do "
            + "[ \"$mark\" = 1 ] && [ \"$att\" = 0 ] && [ $((now - act)) -gt \(ttlSeconds) ] "
            + "&& tmux kill-session -t \"$name\"; done"
    }

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
        // "no server running" stderr out of the parsed output. The `@longwave`
        // marker (set on every session this app creates) filters out the user's
        // own stray tmux sessions; shell sessions (`vnc-` prefix) are skipped too.
        let command = "tmux list-sessions -F '#{session_name}\t#{session_path}\t#{@longwave}' 2>/dev/null"
        guard let out = try? await runTmux(host: host, port: port, username: username, command: command) else {
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
