import Foundation

/// iTerm2 on a Mac, driven over a plain SSH login: the Projects tab's iTerm2
/// mode runs `iterm-tool` on the host and nothing else. There is no Companion
/// protocol and no grant of its own — whoever can SSH in as that user can
/// already type into their terminals, so SSH access *is* the permission.
///
/// `iterm-tool` ships inside Longwave Companion (`CompanionMac/ITerm/`), which
/// installs it at `installedPath` on launch; a copy on the login shell's PATH
/// is the fallback, for Macs without the Companion.
enum ITermCommands {
    /// Relative to `$HOME`. Kept in step with `ITermToolInstaller` on the Mac.
    static let installedPath = "Library/Application Support/Longwave/iterm/iterm-tool"
    static let venvPath = "Library/Application Support/Longwave/iterm/venv"
    static let exitMarker = "@@LONGWAVE-ITERM-EXIT:"

    /// One `iterm-tool` call as a shell line: the Companion's copy (with its
    /// own venv) when installed, else whatever `iterm-tool` the PATH has. Run
    /// inside a login shell (`loginShellCommand`) so `python3` resolves the way
    /// it does in the user's terminal.
    ///
    /// `exec` replaces the shell with the tool (the live view's PTY), and has
    /// to sit on the tool call itself: in front of the whole line it would
    /// try to run the `T=…` assignment as a program.
    static func invocation(_ arguments: [String], exec: Bool = false) -> String {
        let args = arguments.map(AgentSessionCommands.shellSingleQuote).joined(separator: " ")
        let run = exec ? "exec " : ""
        return "T=\"$HOME/\(installedPath)\"; "
            + "if [ -x \"$T\" ]; then ITERM_TOOL_VENV=\"$HOME/\(venvPath)\" \(run)\"$T\" \(args); "
            + "elif command -v iterm-tool >/dev/null 2>&1; then \(run)iterm-tool \(args); "
            + "else echo 'iterm-tool is not installed on this Mac. Install Longwave Companion, or put iterm-tool on the PATH.' >&2; exit 127; fi"
    }

    /// An exec-channel command that reports stderr and the exit status, which
    /// `SSHCommandRunner` (stdout only) would otherwise lose.
    static func captured(_ arguments: [String]) -> String {
        AgentSessionCommands.loginShellCommand("{ \(invocation(arguments)); } 2>&1; echo \"\(exitMarker)$?\"")
    }

    /// The PTY command for a live mirror of one session.
    static func viewCommand(sessionID: String) -> String {
        AgentSessionCommands.loginShellCommand(invocation(["view", sessionID], exec: true))
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Splits captured output into the tool's output and its exit status;
    /// throws with the tool's own words when it failed. rc-file banners before
    /// the output are left in; callers that parse JSON skip them.
    static func result(_ raw: String) throws -> String {
        guard let range = raw.range(of: exitMarker, options: .backwards) else {
            throw Failure(message: "The Mac's shell ended before iterm-tool finished.")
        }
        let body = String(raw[..<range.lowerBound])
        let status = Int(raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        guard status == 0 else {
            let lines = body.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.hasPrefix("[notice]") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let detail = lines.suffix(4).joined(separator: "\n")
            throw Failure(message: detail.isEmpty ? "iterm-tool failed (exit \(status))." : detail)
        }
        return body
    }

    /// One session from `iterm-tool list --json`.
    struct Session: Codable, Identifiable, Hashable, Sendable {
        let w: Int
        let t: Int
        let windowID: String
        let tabID: String
        let sessionID: String
        let name: String?
        let title: String?
        let job: String?
        let cwd: String?
        let cols: Int?
        let rows: Int?
        let currentTab: Bool?
        let currentSession: Bool?
        let frontWindow: Bool?

        var id: String { sessionID }
        /// The tab's title when it has one, else the session's own name.
        var displayTitle: String {
            [title, name].compactMap { $0 }.first { !$0.isEmpty } ?? "Session \(t)"
        }

        enum CodingKeys: String, CodingKey {
            case w, t, name, title, job, cwd, cols, rows
            case windowID = "window_id", tabID = "tab_id", sessionID = "session_id"
            case currentTab = "current_tab", currentSession = "current_session", frontWindow = "front_window"
        }
    }

    struct Tab: Identifiable, Hashable, Sendable {
        let id: String
        let number: Int
        let sessions: [Session]
        var title: String { sessions.first { $0.currentSession == true }?.displayTitle ?? sessions.first?.displayTitle ?? "Tab \(number)" }
        var isCurrent: Bool { sessions.contains { $0.currentTab == true } }
    }

    struct Window: Identifiable, Hashable, Sendable {
        let id: String
        let number: Int
        let tabs: [Tab]
        var isFront: Bool { tabs.contains { $0.sessions.contains { $0.frontWindow == true } } }
    }

    /// The last line that parses as a JSON value: rc banners and pip notices
    /// can come first on a login shell.
    static func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
                  let value = try? JSONDecoder().decode(T.self, from: Data(trimmed.utf8)) else { continue }
            return value
        }
        throw Failure(message: "iterm-tool's reply wasn't understood. Update Longwave Companion on the Mac.")
    }

    /// Windows in `list` order, each with its tabs and their split panes.
    static func windows(from sessions: [Session]) -> [Window] {
        var order: [String] = []
        var byWindow: [String: [Session]] = [:]
        for session in sessions {
            if byWindow[session.windowID] == nil { order.append(session.windowID) }
            byWindow[session.windowID, default: []].append(session)
        }
        return order.map { windowID in
            let members = byWindow[windowID] ?? []
            var tabOrder: [String] = []
            var byTab: [String: [Session]] = [:]
            for session in members {
                if byTab[session.tabID] == nil { tabOrder.append(session.tabID) }
                byTab[session.tabID, default: []].append(session)
            }
            let tabs = tabOrder.map { tabID in
                let panes = byTab[tabID] ?? []
                return Tab(id: tabID, number: panes.first?.t ?? 0, sessions: panes)
            }
            return Window(id: windowID, number: members.first?.w ?? 0, tabs: tabs)
        }
    }
}
