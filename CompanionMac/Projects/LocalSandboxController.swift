import AppKit
import DebugTrace
import Foundation
import NIOSSH
import NIOTransportServices
import Security

/// Drives the local agent sandbox for the Mac Projects tab: the root helper
/// (`sudo -n longwave-sandbox <verb>`), the agent's GUI session, projects moved
/// through the exchange dir, and agent sessions launched over SSH into tmux and
/// attached in Terminal.app.
///
/// Pure command construction lives in `LocalSandbox` / `AgentSessionCommands`
/// (shared and unit-tested); this type only runs things.
@Observable
@MainActor
final class LocalSandboxController {
    enum Availability: Equatable {
        case unknown
        /// The helper isn't installed — show `LocalSandbox.installCommand`.
        case notInstalled
        /// The helper exists but `sudo -n` refuses it (sudoers rule missing).
        case sudoNotConfigured(String)
        case failed(String)
        case ready
    }

    enum DesktopState: Equatable {
        case unknown, running, absent, loggingIn
        case failed(String)
        /// Wrong password / not allowed — never retried automatically.
        case authFailed(String)
    }

    struct Project: Identifiable, Hashable {
        /// Bare repo name in the exchange dir (`name.git`).
        let bareName: String
        var id: String { bareName }
        var displayName: String { String(bareName.dropLast(4)) }
        /// Host checkout it was imported from, if this Mac imported it.
        var checkout: URL?
    }

    private(set) var availability: Availability = .unknown
    private(set) var status: LocalSandbox.Status?
    private(set) var desktop: DesktopState = .unknown
    private(set) var projects: [Project] = []
    private(set) var sessions: [DiscoveredAgentSession] = []
    /// A short "Resetting…"-style label while a long operation runs.
    private(set) var busy: String?
    var lastError: String?
    var lastMessage: String?

    /// The credentials for sandbox sessions: a fixed-UUID account whose tokens
    /// live in this app's keychain under that UUID, exactly as a saved
    /// connection's do, with its flags re-derived each launch.
    let account: SandboxAgentAccount

    private static let connectionID = UUID(uuidString: "5A0D7E5B-0C4A-4B1E-9C3E-5A7D1B0C0001")!
    private static let setupCompleteKey = "localSandbox.setupCompleteAt"
    private static let checkoutsKey = "localSandbox.checkouts"
    private static let agentChoiceKey = "localSandbox.agentChoice"

    private let log = DebugLogger(subsystem: "pro.longwave", category: "LocalSandbox")
    private let group = NIOTSEventLoopGroup()
    private let keeper = SandboxSessionKeeper()
    private var privateKey: NIOSSHPrivateKey?

    init() {
        account = SandboxAgentAccount(id: Self.connectionID)
        account.refreshTokenFlagsFromKeychain()
    }

    var agentUser: String { status?.agentUser ?? LocalSandbox.defaultAgentUser }

    /// Whether this app can reach the sandbox account's home through the helper
    /// (see `LocalSandbox.fullDiskAccessProbePath`). Re-read on every refresh,
    /// since the user grants it in System Settings while the app runs.
    private(set) var hasFullDiskAccess = LocalSandboxController.probeFullDiskAccess()

    nonisolated static func probeFullDiskAccess() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: LocalSandbox.fullDiskAccessProbePath) else { return false }
        try? handle.close()
        return true
    }

    /// Full Disk Access has no request API and no prompt: the app never shows
    /// up in that list until the user adds it. `FullDiskAccessAssistant` opens
    /// the pane with a floating panel holding the app's icon to drag into it.
    func openFullDiskAccessSettings() {
        FullDiskAccessAssistant.shared.show()
    }

    func relaunch() { Self.relaunchApp() }

    /// A Full Disk Access grant only applies to processes started after it, so
    /// the probe keeps failing until the app is relaunched. Detached `open`
    /// outlives this process and brings the same bundle back up.
    static func relaunchApp() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    // MARK: - Onboarding

    /// Set once the user has completed macOS first-run setup in the sandbox
    /// desktop and the post-setup golden snapshot was taken.
    var setupComplete: Bool {
        get {
            access(keyPath: \.setupComplete)
            return UserDefaults.standard.object(forKey: Self.setupCompleteKey) != nil
        }
        set {
            withMutation(keyPath: \.setupComplete) {
                if newValue {
                    UserDefaults.standard.set(Date(), forKey: Self.setupCompleteKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.setupCompleteKey)
                }
            }
        }
    }

    /// "Setup complete": configure the agent's desktop (screen lock off, no
    /// screen saver, black wallpaper — a locked virtual session would stall
    /// anything waiting on the GUI), snapshot the set-up home as the golden copy
    /// (which logs the agent out), then log it back in.
    func completeSetup() async {
        await ensureDesktopSession(force: true)
        guard status?.guiSession == true else {
            lastError = "The sandbox needs a desktop session to finish setup."
            return
        }
        guard let password = await agentPassword() else {
            lastError = "The sandbox password isn't in your login keychain."
            return
        }
        guard await perform(.configureDesktop, label: "Configuring the sandbox desktop…",
                            stdin: Data((password + "\n").utf8)) else { return }
        guard await perform(.snapshotGolden, label: "Saving the set-up home…") else { return }
        setupComplete = true
        await ensureDesktopSession(force: true)
    }

    // MARK: - Status and helper verbs

    func refresh() async {
        hasFullDiskAccess = Self.probeFullDiskAccess()
        guard FileManager.default.isExecutableFile(atPath: LocalSandbox.helperPath) else {
            availability = .notInstalled
            status = nil
            return
        }
        let result = await Self.run(LocalSandbox.sudoPath, LocalSandbox.sudoArguments(.status))
        guard result.status == 0 else {
            if result.err.contains("password is required") || result.err.contains("not allowed") {
                availability = .sudoNotConfigured(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                availability = .failed(Self.firstLine(result.err) ?? "longwave-sandbox status failed")
            }
            return
        }
        do {
            let decoded = try LocalSandbox.decodeStatus(Data(result.out.utf8))
            status = decoded
            availability = decoded.userExists ? .ready : .failed("The sandbox account is missing — re-run the installer.")
            // A failure stays on screen (and blocks automatic attempts) until a
            // session shows up or the user presses Retry.
            if desktop != .loggingIn {
                if decoded.guiSession { desktop = .running }
                else if !isAuthFailed, !isFailed { desktop = .absent }
            }
        } catch {
            availability = .failed("Unreadable status from the helper: \(error.localizedDescription)")
        }
        loadProjects()
        await refreshSessions()
    }

    private var isAuthFailed: Bool {
        if case .authFailed = desktop { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = desktop { return true }
        return false
    }

    /// Runs one helper verb, reporting failures in `lastError`. Returns success.
    @discardableResult
    func perform(_ verb: LocalSandbox.Verb, label: String, stdin: Data? = nil) async -> Bool {
        busy = label
        defer { busy = nil }
        let result = await Self.run(LocalSandbox.sudoPath, LocalSandbox.sudoArguments(verb), stdin: stdin)
        if result.status != 0 {
            lastError = Self.firstLine(result.err) ?? "\(verb.arguments.first ?? "helper") failed"
            await refresh()
            return false
        }
        lastError = nil
        await refresh()
        return true
    }

    func reset() async {
        guard await perform(.reset, label: "Resetting the sandbox…") else { return }
        sessions = []
        await ensureDesktopSession(force: true)
    }

    func stop() async {
        await perform(.stop, label: "Stopping the sandbox…")
        sessions = []
    }

    func setFirewall(_ on: Bool) async {
        await perform(.firewall(on: on), label: on ? "Loading the firewall…" : "Removing the firewall…")
    }

    func authorizeKey(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalSandbox.isAcceptablePublicKey(trimmed) else {
            lastError = "Paste one ssh-ed25519 or ecdsa-sha2-nistp256 public key line."
            return
        }
        if await perform(.authorizeKey(trimmed), label: "Authorizing the key…") {
            lastMessage = "Key authorized. It survives resets."
        }
    }

    // MARK: - GUI session keeper

    /// Makes sure the agent has a GUI session (needed by visionOS simulators and
    /// Xcode), logging it in headlessly over loopback VNC if not. One attempt per
    /// call and no automatic retries: every attempt makes macOS start building a
    /// session, and repeated half-finished ones destabilise the window server for
    /// everyone. After a failure only an explicit Retry (`force`) tries again.
    func ensureDesktopSession(force: Bool = false) async {
        if !force, isAuthFailed || isFailed { return }
        await refresh()
        guard availability == .ready, let status, !status.guiSession else { return }
        // Shown while macOS may be asking to let this app read the password.
        desktop = .loggingIn
        guard let password = await agentPassword() else {
            desktop = .failed("The sandbox password isn't in your login keychain (\(LocalSandbox.keychainService)), or access was denied.")
            return
        }
        let outcome = await keeper.logIn(host: LocalSandbox.host, port: LocalSandbox.vncPort,
                                         username: status.agentUser, password: password)
        switch outcome {
        case .loggedIn:
            // The session registers with launchd a moment after the first frame.
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
                if self.status?.guiSession == true { break }
            }
            desktop = self.status?.guiSession == true ? .running
                : .failed("Logged in, but no desktop session appeared")
        case .authFailed(let message):
            desktop = .authFailed(message)
        case .failed(let message):
            desktop = .failed(message)
        }
    }

    /// The agent's password, from the item install.sh wrote to the owner's login
    /// keychain. The first read from this app can show macOS's keychain access
    /// prompt ("Always Allow" makes it silent afterwards), and SecItemCopyMatching
    /// blocks its thread for as long as that prompt is up — so it runs off the
    /// main actor.
    func agentPassword() async -> String? {
        let account = agentUser
        return await Task.detached { LocalSandbox.readAgentPassword(account: account) }.value
    }

    /// Shows the agent's desktop. The Companion has no VNC viewer of its own
    /// (process separation: it only ever logs the session in), so the desktop
    /// opens in Longwave for Mac, which reads the password itself.
    func openDesktop() {
        guard let url = URL(string: LocalSandbox.desktopURL),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            lastError = "Install Longwave for Mac to view the sandbox desktop here, or connect any VNC client to this Mac as \(agentUser)."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openDeviceHub() async {
        await ensureDesktopSession(force: true)
        guard status?.guiSession == true else {
            lastError = "The sandbox has no desktop session to open Device Hub in."
            return
        }
        do {
            _ = try await ssh(LocalSandbox.openDeviceHubCommand)
            lastMessage = "Device Hub opened in the sandbox desktop."
        } catch {
            lastError = "Couldn't open Device Hub: \(error.localizedDescription)"
        }
    }

    // MARK: - Projects

    private var checkouts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.checkoutsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.checkoutsKey) }
    }

    func loadProjects() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: LocalSandbox.exchangeDir)) ?? []
        let map = checkouts
        projects = names.filter { $0.hasSuffix(".git") }.sorted().map {
            Project(bareName: $0, checkout: map[$0].map { URL(fileURLWithPath: $0) })
        }
    }

    /// Publishes a local checkout's current branch into the exchange dir and
    /// clones it inside the sandbox.
    func importRepository(at repo: URL) async {
        busy = "Importing \(repo.lastPathComponent)…"
        defer { busy = nil }
        let branchResult = await Self.run("/usr/bin/git", ["-C", repo.path, "rev-parse", "--abbrev-ref", "HEAD"])
        guard branchResult.status == 0 else {
            lastError = "\(repo.lastPathComponent) isn't a git repository."
            return
        }
        var branch = branchResult.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty || branch == "HEAD" { branch = "main" }
        let bareName = LocalSandbox.bareRepoName(forRepoAt: repo)
        guard !FileManager.default.fileExists(atPath: LocalSandbox.bareRepoPath(named: bareName)) else {
            lastError = "\(bareName) already exists in the exchange — use Fetch back, or remove it first."
            return
        }
        for args in LocalSandbox.importCommands(repo: repo, branch: branch) {
            let r = await Self.run("/usr/bin/git", args)
            guard r.status == 0 else {
                lastError = "git \(args.first == "-C" ? args[2] : args[0]) failed: \(Self.firstLine(r.err) ?? "")"
                // Don't strand a half-made bare repo that blocks the retry; this
                // call created it (the exists check above ran first).
                try? FileManager.default.removeItem(atPath: LocalSandbox.bareRepoPath(named: bareName))
                return
            }
        }
        var map = checkouts
        map[bareName] = repo.path
        checkouts = map
        loadProjects()
        do {
            _ = try await sandboxClone(bareName)
            lastError = nil
            lastMessage = "Imported \(repo.lastPathComponent) (\(branch)) into the sandbox."
        } catch {
            lastError = "Published, but the sandbox clone failed: \(error.localizedDescription)"
        }
    }

    /// Fetches the sandbox's branches back into the host checkout as the
    /// `sandbox` remote. Fetch only — no hooks or checkouts run.
    func fetchBack(_ project: Project) async {
        guard let repo = project.checkout else {
            lastError = "No host checkout is recorded for \(project.displayName)."
            return
        }
        busy = "Fetching \(project.displayName)…"
        defer { busy = nil }
        let remotes = await Self.run("/usr/bin/git", ["-C", repo.path, "remote"])
        let exists = remotes.out.split(separator: "\n").contains("sandbox")
        for args in LocalSandbox.fetchBackCommands(repo: repo,
                                                   bareRepo: LocalSandbox.bareRepoPath(named: project.bareName),
                                                   remoteExists: exists) {
            let r = await Self.run("/usr/bin/git", args)
            guard r.status == 0 else {
                lastError = "git failed: \(Self.firstLine(r.err) ?? "")"
                return
            }
        }
        lastError = nil
        lastMessage = "Fetched \(project.displayName) into the sandbox remote of \(repo.path)."
    }

    /// Clones the project inside the sandbox if needed and returns its path there.
    func sandboxClone(_ bareName: String) async throws -> String {
        let out = try await ssh(AgentSessionCommands.loginShellCommand(LocalSandbox.sandboxCloneScript(bareRepo: bareName)))
        // rc files may print banners; `pwd` is the last line.
        guard let path = out.split(separator: "\n").last.map(String.init), path.hasPrefix("/") else {
            throw SandboxError.message("The sandbox couldn't clone \(bareName).")
        }
        return path
    }

    // MARK: - Agent sessions

    func agentChoice(for project: Project) -> SSHAgent {
        let raw = (UserDefaults.standard.dictionary(forKey: Self.agentChoiceKey) as? [String: String])?[project.bareName]
        return raw.flatMap(SSHAgent.init(rawValue:)) ?? .claude
    }

    func setAgentChoice(_ agent: SSHAgent, for project: Project) {
        var map = UserDefaults.standard.dictionary(forKey: Self.agentChoiceKey) as? [String: String] ?? [:]
        map[project.bareName] = agent.rawValue
        UserDefaults.standard.set(map, forKey: Self.agentChoiceKey)
    }

    /// Creates (or reuses) the project's tmux session for `agent` in the sandbox
    /// — tokens go over the create channel's stdin, never an argv — then attaches
    /// it in Terminal.app.
    func launch(_ project: Project, agent: SSHAgent) async {
        busy = "Starting \(agent.displayName) in \(project.displayName)…"
        defer { busy = nil }
        do {
            let folder = try await sandboxClone(project.bareName)
            let environment = await account.resolvedSSHEnvironmentRenewingCredentials(for: agent)
            let base = AgentSessionCommands.slug(project.displayName)
            let slug = agent.sessionKey.isEmpty ? base : AgentSessionCommands.slug("\(base)-\(agent.sessionKey)")
            let launch = AgentSessionCommands.agentLaunch(
                tmuxSession: slug, folder: folder,
                // The sandbox account is the boundary, so built-in agents start
                // with their own permission prompts off; custom stays verbatim.
                clientCommand: agent == .custom ? account.effectiveCommand(for: agent)
                                                : agent.sandboxLaunchCommand,
                environment: environment,
                setup: account.sessionSetup(for: agent, environment: environment))
            let out = try await ssh(launch.create, stdin: launch.payload)
            if out.contains(AgentSessionCommands.agentNoTmuxMarker) {
                throw SandboxError.message("tmux isn't on the sandbox's login PATH.")
            }
            guard out.contains(AgentSessionCommands.agentCreatedMarker) else {
                throw SandboxError.message("The session couldn't be created in the sandbox.")
            }
            try attach(tmuxSession: slug)
            lastError = nil
            await refreshSessions()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Starts a scheduled, non-interactive run: a tagged tmux session (so it
    /// can be attached live) whose pane runs the agent headless, tees its output
    /// to `~/.longwave-runs/<runID>.log` and records the exit status. Tokens and
    /// the prompt both travel on the create channel's stdin. Returns the tmux
    /// session name.
    func startHeadlessRun(project bareName: String, agent: SSHAgent, runID: String,
                          prompt: String) async throws -> String {
        let folder = try await sandboxClone(bareName)
        let credentials = await account.resolvedSSHEnvironmentRenewingCredentials(for: agent)
        let environment = AgentSchedule.environment(credentials: credentials, prompt: prompt)
        let launch = AgentSessionCommands.agentLaunch(
            tmuxSession: runID, folder: folder,
            clientCommand: AgentSchedule.paneCommand(agent: agent, runID: runID),
            environment: environment,
            setup: account.sessionSetup(for: agent, environment: credentials))
        let out = try await ssh(launch.create, stdin: launch.payload)
        if out.contains(AgentSessionCommands.agentNoTmuxMarker) {
            throw SandboxError.message("tmux isn't on the sandbox's login PATH.")
        }
        // A trivial run can finish before the create step checks for the
        // session, so a missing marker is only fatal if the run left no trace.
        if !out.contains(AgentSessionCommands.agentCreatedMarker) {
            let probe = try? await ssh(AgentSessionCommands.loginShellCommand(
                AgentSchedule.progressCommand(runID: runID, tmuxSession: runID)))
            if case .exited = AgentSchedule.parseProgress(probe ?? "") {} else {
                throw SandboxError.message("The run's session couldn't be created in the sandbox.")
            }
        }
        await refreshSessions()
        return runID
    }

    func refreshSessions() async {
        guard availability == .ready else { sessions = []; return }
        let command = AgentSessionCommands.loginShellCommand(AgentSessionCommands.discoverSessionsCommand)
        guard let out = try? await ssh(command) else { return }
        sessions = AgentSessionCommands.parseDiscoveredSessions(out)
    }

    func stopSession(_ session: DiscoveredAgentSession) async {
        let kill = "tmux kill-session -t \(AgentSessionCommands.target(session.name)) 2>/dev/null"
        _ = try? await ssh(AgentSessionCommands.loginShellCommand(kill))
        await refreshSessions()
    }

    /// Opens Terminal.app on the attach command. A `.command` file in the
    /// per-user (0700) temp dir rather than AppleScript, so no Automation
    /// permission is needed; it contains no secret.
    func attach(tmuxSession: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("longwave-sandbox-terminal", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(tmuxSession).command")
        let script = "#!/bin/zsh\n"
            + LocalSandbox.terminalAttachCommand(keyPath: LocalSandbox.keyURL().path,
                                                 agentUser: agentUser, tmuxSession: tmuxSession) + "\n"
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor [weak self] in self?.lastError = "Terminal: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Plumbing

    enum SandboxError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): m }
        }
    }

    private func key() throws -> NIOSSHPrivateKey {
        if let privateKey { return privateKey }
        do {
            let k = try OpenSSHPrivateKey.nioPrivateKey(contentsOf: LocalSandbox.keyURL())
            privateKey = k
            return k
        } catch {
            throw SandboxError.message("Can't read \(LocalSandbox.keyURL().path): \(error)")
        }
    }

    /// One command in the sandbox over SSH (non-PTY exec), optionally with stdin.
    func ssh(_ command: String, stdin: Data? = nil) async throws -> String {
        let key = try key()
        let group = self.group
        let user = agentUser
        return try await withCheckedThrowingContinuation { continuation in
            SSHCommandRunner.run(host: LocalSandbox.host, port: LocalSandbox.sshPort, username: user,
                                 command: command, stdin: stdin, privateKey: key, group: group) { result in
                continuation.resume(with: result)
            }
        }
    }

    struct ProcessResult: Sendable {
        let status: Int32
        let out: String
        let err: String
    }

    /// Runs an executable with a fixed argv (never through a shell), off the
    /// main actor. `stdin` (e.g. a password) is written to a pipe, so it never
    /// appears in any process's argv.
    nonisolated static func run(_ executable: String, _ arguments: [String],
                                stdin: Data? = nil) async -> ProcessResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let inPipe = stdin.map { _ in Pipe() }
            process.standardInput = inPipe ?? FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return ProcessResult(status: -1, out: "", err: error.localizedDescription)
            }
            if let inPipe, let stdin {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(status: process.terminationStatus,
                                 out: String(decoding: out, as: UTF8.self),
                                 err: String(decoding: err, as: UTF8.self))
        }.value
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}
