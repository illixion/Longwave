import AppKit
import DebugTrace
import Foundation
import Security

/// Installs (or repairs) the agent sandbox from the copy of
/// `scripts/agent-sandbox/` bundled in the Companion, behind one administrator
/// prompt — no checkout, Terminal or command-line tools.
///
/// The installer runs as root through `osascript … with administrator
/// privileges`, which is outside the owner's login session, so it can't be
/// trusted to write the owner's login keychain. Instead the Companion generates
/// the agent's password, hands it over on stdin (`--password-stdin`, from a
/// 0600 file in this user's private temp dir, never argv), and saves the
/// keychain item itself once the installer has set it.
@Observable
@MainActor
final class SandboxInstaller {
    enum State: Equatable {
        case idle
        case running(String)
        case failed(String)
        case succeeded
    }

    private(set) var state: State = .idle
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "SandboxInstaller")

    var isRunning: Bool { if case .running = state { true } else { false } }

    /// The bundled installer, or nil in a build without the script phase.
    static var bundledDirectory: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("agent-sandbox"),
              FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("install.sh").path) else { return nil }
        return dir
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Longwave/sandbox-install.log")
    }

    /// Runs the installer. Returns whether it succeeded; `state` says why not.
    @discardableResult
    func install(agentUser: String = LocalSandbox.defaultAgentUser) async -> Bool {
        guard !isRunning else { return false }
        guard let dir = Self.bundledDirectory else {
            state = .failed("This build of Longwave Companion doesn't include the sandbox installer.")
            return false
        }
        // A new password only when there is nothing to keep: no account yet, or
        // no keychain item to log it in with. Otherwise the installer keeps the
        // account's current password and the keychain stays in step with it.
        let password: String? = (getpwnam(agentUser) == nil || !Self.keychainItemExists(account: agentUser))
            ? Self.randomHexPassword() : nil

        state = .running("Waiting for administrator approval…")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lw-sandbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Created by this user so the root installer's output stays readable here.
            try Data().write(to: Self.logURL)
            guard FileManager.default.createFile(atPath: temp.path, contents: Data(((password ?? "") + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            state = .failed("Couldn't prepare the installer: \(error.localizedDescription)")
            return false
        }

        let command = "SUDO_USER=\(Self.shellQuoted(NSUserName())) /bin/bash \(Self.shellQuoted(dir.appendingPathComponent("install.sh").path))"
            + " --password-stdin < \(Self.shellQuoted(temp.path)) > \(Self.shellQuoted(Self.logURL.path)) 2>&1"
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" with administrator privileges"

        let progress = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let line = Self.lastStepLine() else { continue }
                self.state = .running(line)
            }
        }
        let result = await Self.runOSAScript(script)
        progress.cancel()

        switch result {
        case .cancelled:
            state = .idle
            return false
        case .failed(let message):
            let detail = Self.lastErrorLine() ?? message
            log.error("Sandbox install failed: \(detail, privacy: .public)")
            state = .failed("Installing the sandbox failed: \(detail). The full log is in \(Self.logURL.path).")
            return false
        case .succeeded:
            break
        }

        if let password {
            state = .running("Saving the agent's password to your keychain…")
            guard await Self.saveKeychainItem(account: agentUser, password: password) else {
                state = .failed("The sandbox is installed, but saving the agent's password to your login keychain failed. Install again to set a new one.")
                return false
            }
        }
        log.info("Sandbox installed")
        state = .succeeded
        return true
    }

    // MARK: - Keychain

    /// Attributes only: reading them never raises a keychain access prompt.
    private nonisolated static func keychainItemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: LocalSandbox.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// `security -i` reads its commands on stdin, so the value never shows in
    /// `ps`. `-T` pre-authorizes both Mac apps, exactly as install.sh does when
    /// run from a Terminal, so neither raises a prompt reading it.
    private nonisolated static func saveKeychainItem(account: String, password: String) async -> Bool {
        var trusted = [Bundle.main.bundleURL.path]
        let mac = "/Applications/LongwaveMac.app"
        if FileManager.default.fileExists(atPath: mac), mac != trusted[0] { trusted.append(mac) }
        let flags = trusted.map { "-T \"\($0)\"" }.joined(separator: " ")
        let command = "add-generic-password -U -s \(LocalSandbox.keychainService) -a \(account) -l \"Longwave agent sandbox\" -D \"application password\" \(flags) -w \(password)\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        input.fileHandleForWriting.write(Data(command.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return keychainItemExists(account: account)
    }

    // MARK: - Running the installer

    private enum ScriptResult { case succeeded, cancelled, failed(String) }

    private nonisolated static func runOSAScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded)
                } else if text.contains("-128") {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    /// The installer's latest `==> step` line, for the progress label.
    private static func lastStepLine() -> String? {
        logLines().last { $0.hasPrefix("==> ") }.map { String($0.dropFirst(4)) }
    }

    private static func lastErrorLine() -> String? {
        logLines().last { $0.hasPrefix("install.sh: ") }.map { String($0.dropFirst(12)) }
    }

    private static func logLines() -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func randomHexPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
