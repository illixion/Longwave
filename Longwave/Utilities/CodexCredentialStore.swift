import DebugTrace
import Foundation

/// Keychain home for a host's Codex `CodexOAuth.Credential` (access, id and
/// refresh tokens), one per saved connection — the Codex twin of
/// `ClaudeCredentialStore`.
///
/// Same tier as the SSH device key (`…AfterFirstUnlockThisDeviceOnly`), so the
/// refresh token never syncs off this device, and a host only ever receives an
/// `auth.json` without it. That matters more for Codex than for Claude: OpenAI's
/// refresh tokens rotate on every use, so a second holder would not just be a
/// leak — the first refresh on either side would sign the other out.
enum CodexCredentialStore {
    private static let service = "pro.longwave.codexOAuthCredential"
    private static let log = DebugLogger(subsystem: "pro.longwave", category: "CodexCredentials")

    // MARK: - Storage

    static func load(connectionID: UUID) -> CodexOAuth.Credential? {
        guard let json = KeychainStore.get(service: service, account: connectionID.uuidString),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CodexOAuth.Credential.self, from: data)
    }

    static func save(_ credential: CodexOAuth.Credential, connectionID: UUID) {
        guard let data = try? JSONEncoder().encode(credential),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(service: service, account: connectionID.uuidString, value: json)
    }

    static func delete(connectionID: UUID) {
        KeychainStore.delete(service: service, account: connectionID.uuidString)
    }

    /// Drop the local credential and revoke it upstream too.
    static func revokeAndDelete(connectionID: UUID) async {
        if let credential = load(connectionID: connectionID) {
            await CodexOAuth.revoke(credential)
        }
        delete(connectionID: connectionID)
    }

    // MARK: - Access

    /// The credential to hand a session, refreshed first when under a day of
    /// access-token life remains (`CodexOAuth.Credential.isFresh`).
    ///
    /// The rotated credential is saved **before** it's returned: the old refresh
    /// token is spent the moment the server answers, so losing the new one would
    /// mean signing in again. A failed refresh is non-fatal — the stored
    /// credential still works until its access token actually expires, and a
    /// dead one produces the agent's own auth error, which is clearer than a
    /// launch that silently didn't happen.
    static func validCredential(connectionID: UUID) async -> CodexOAuth.Credential? {
        guard let credential = load(connectionID: connectionID) else { return nil }
        guard !credential.isFresh() else { return credential }
        guard credential.canRefresh else {
            log.log("Codex credential stale and not refreshable; using it as-is")
            return credential
        }
        do {
            let refreshed = try await CodexOAuth.refresh(credential)
            save(refreshed, connectionID: connectionID)
            return refreshed
        } catch {
            log.log("Codex refresh failed (\(error.localizedDescription)); falling back to stored credential")
            return credential
        }
    }

    /// Human-readable state for the setup sheet: account, plan, access-token life.
    static func summary(connectionID: UUID) -> String? {
        guard let credential = load(connectionID: connectionID) else { return nil }
        var parts: [String] = []
        if let email = credential.email { parts.append(email) }
        if let plan = credential.planType { parts.append("\(plan.capitalized) plan") }
        if let expiresAt = credential.expiresAt {
            let remaining = expiresAt.timeIntervalSinceNow
            if !credential.isFresh() {
                parts.append(credential.canRefresh ? "token renews at next launch"
                             : remaining > 0 ? "token expires soon" : "token expired")
            } else {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                parts.append("token expires \(formatter.localizedString(for: expiresAt, relativeTo: Date()))")
            }
        }
        return parts.isEmpty ? "Signed in with ChatGPT" : parts.joined(separator: " · ")
    }
}
