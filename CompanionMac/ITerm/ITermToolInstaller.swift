import DebugTrace
import Foundation

/// Installs the bundled `iterm-tool` where Longwave's Projects → iTerm2 mode
/// looks for it over SSH (`ITermCommands.installedPath`), and prepares its
/// Python venv, so iTerm2 on the headset needs nothing installed by hand.
///
/// Runs on every launch: a copy that differs from the bundled one (an older
/// Companion's) is replaced; the venv is created once. Nothing here talks to
/// iTerm2 — that, and the one-time "allow SSH to control iTerm2" prompt,
/// happen on the first headset request.
@Observable
@MainActor
final class ITermToolInstaller {
    static let shared = ITermToolInstaller()

    enum State: Equatable {
        case idle
        case installing
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "ITermTool")

    var toolURL: URL { home.appending(path: ITermCommands.installedPath) }
    private var venvURL: URL { home.appending(path: ITermCommands.venvPath) }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    func install() {
        guard state != .installing else { return }
        guard let bundled = Bundle.main.url(forResource: "iterm-tool", withExtension: "py") else {
            state = .failed("This build of the Companion doesn't include iterm-tool.")
            return
        }
        state = .installing
        let tool = toolURL, venv = venvURL
        Task.detached(priority: .utility) {
            let result = Self.installSync(from: bundled, to: tool, venv: venv)
            await MainActor.run {
                switch result {
                case .success:
                    self.state = .ready
                    self.log.info("iterm-tool installed")
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.log.error("iterm-tool install failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated private static func installSync(from bundled: URL, to tool: URL, venv: URL) -> Result<Void, Error> {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: bundled)
            if (try? Data(contentsOf: tool)) != data {
                let staged = tool.appendingPathExtension("new")
                try data.write(to: staged, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                _ = try fm.replaceItemAt(tool, withItemAt: staged)
            }
            // The venv once; `setup` exits straight after it, without iTerm2.
            // Through a login shell, so `python3` is the one the headset's SSH
            // command will also find.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let quoted = "'" + tool.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let venvQuoted = "'" + venv.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            process.arguments = ["-lc", "ITERM_TOOL_VENV=\(venvQuoted) \(quoted) setup"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let tail = text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
                if text.contains("xcrun") || text.contains("command line developer tools") {
                    throw Failure(message: "Python 3 is missing: install the Xcode Command Line Tools (xcode-select --install), then Reinstall.")
                }
                throw Failure(message: tail.isEmpty ? "iterm-tool setup failed (exit \(process.terminationStatus))." : tail)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
