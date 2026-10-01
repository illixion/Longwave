import DebugTrace
import Foundation
import RoyalVNCKit

/// Logs the sandbox agent into a GUI (Aqua) session without showing anything,
/// by authenticating to this Mac's own Screen Sharing server over loopback.
///
/// Why a GUI session at all: the visionOS simulator's device identity is a
/// Secure Enclave key in the user's data-protection keychain, which stays locked
/// until the user logs in through `loginwindow` — an SSH login (even with a
/// password) never unlocks it, so visionOS sims hang at boot without one. An ARD
/// (username + password) login as a user other than the console user makes
/// screensharingd create a separate *virtual* session for them, and that session
/// outlives the VNC connection, so connect → first framebuffer → disconnect is
/// enough. Screen Sharing.app refuses localhost; the server itself doesn't.
@MainActor
final class SandboxSessionKeeper: NSObject, VNCConnectionDelegate {
    enum Outcome: Equatable {
        case loggedIn
        /// Wrong password or account not allowed to use Screen Sharing — retrying
        /// can't fix it, so callers must not loop on this.
        case authFailed(String)
        case failed(String)
    }

    private let log = DebugLogger(subsystem: "pro.longwave", category: "SandboxSessionKeeper")
    private var connection: VNCConnection?
    private var username = ""
    private var password = ""
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var sawFramebuffer = false

    /// Resolves once the session is up (first framebuffer received, then the
    /// connection is closed) or the attempt failed. A virtual session's first
    /// frame normally arrives in 1–3 s, but an account's *first* login builds its
    /// whole session and took ~70 s on macOS 27. `timeout` is deliberately far
    /// beyond that: walking away from a login half-way leaves macOS with an
    /// orphaned root `loginwindow` for a half-created session, which has frozen
    /// the owner's menu bar (see `AGENT_SANDBOX_PLAN.md`, Phase A).
    func logIn(host: String, port: UInt16, username: String, password: String,
               timeout: Duration = .seconds(180)) async -> Outcome {
        guard continuation == nil else { return .failed("A login is already in progress") }
        self.username = username
        self.password = password
        sawFramebuffer = false
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false, hostname: host, port: port,
            isShared: true, isScalingEnabled: false, useDisplayLink: false,
            inputMode: .none, isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit, frameEncodings: .default)
        let conn = VNCConnection(settings: settings)
        conn.delegate = self
        connection = conn
        return await withCheckedContinuation { cont in
            continuation = cont
            conn.connect()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(.failed("Timed out waiting for the sandbox desktop"))
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let cont = continuation else { return }
        continuation = nil
        password = ""
        connection?.disconnect()
        connection = nil
        log.info("Sandbox GUI login finished: \(String(describing: outcome), privacy: .public)")
        cont.resume(returning: outcome)
    }

    // MARK: - VNCConnectionDelegate

    nonisolated func connection(_ connection: VNCConnection,
                                stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let error = connectionState.error
        Task { @MainActor [weak self] in
            guard let self, status == .disconnected else { return }
            if self.sawFramebuffer {
                self.finish(.loggedIn)
            } else if let error, (error as? VNCError)?.isAuthenticationError == true {
                self.finish(.authFailed(error.localizedDescription))
            } else {
                self.finish(.failed(error?.localizedDescription ?? "Screen Sharing closed the connection"))
            }
        }
    }

    nonisolated func connection(_ connection: VNCConnection,
                                credentialFor authenticationType: VNCAuthenticationType,
                                completion: @escaping ((any VNCCredential)?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, authenticationType.requiresUsername, !self.password.isEmpty else {
                // Only ARD (username + password) creates a separate session; a
                // VNC-password server would share the console instead.
                completion(nil)
                return
            }
            completion(VNCUsernamePasswordCredential(username: self.username, password: self.password))
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The virtual session exists once the server hands us its screen.
            // Disconnecting now leaves it logged in.
            self.sawFramebuffer = true
            self.connection?.disconnect()
        }
    }

    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16, width: UInt16, height: UInt16) {}
    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
