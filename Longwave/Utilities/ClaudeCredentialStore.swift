import Foundation
import os

/// Keychain home for the full `ClaudeOAuth.Credential` bundle (access token +
/// refresh token + expiry + granted scopes), one per saved connection.
///
/// This sits *alongside* `SavedConnection`'s single-string token slot rather than
/// replacing it. A credential minted by the in-app sign-in lands here and wins;
/// a token typed into the paste field stays where it always was. That keeps the
/// paste path working as an escape hatch (and keeps every previously stored
/// token valid) with no migration.
///
/// Nothing here is written to SwiftData — only to the keychain, at the same
/// `…AfterFirstUnlockThisDeviceOnly` tier as the SSH device key, so the refresh
/// token never syncs off the headset. The Mac only ever sees a short-lived access
/// token, and only inside the SSH channel.
enum ClaudeCredentialStore {

    private static let service = "com.illixion.Longwave.claudeOAuthCredential"
    private static let log = Logger(subsystem: "com.illixion.Longwave", category: "ClaudeCredentials")

    // MARK: - Storage

    static func load(connectionID: UUID) -> ClaudeOAuth.Credential? {
        guard let json = KeychainStore.get(service: service, account: connectionID.uuidString),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeOAuth.Credential.self, from: data)
    }

    static func save(_ credential: ClaudeOAuth.Credential, connectionID: UUID) {
        guard let data = try? JSONEncoder().encode(credential),
              let json = String(data: data, encoding: .utf8) else { return }
        KeychainStore.set(service: service, account: connectionID.uuidString, value: json)
    }

    static func delete(connectionID: UUID) {
        KeychainStore.delete(service: service, account: connectionID.uuidString)
    }

    /// Drop the local credential and tell the server to invalidate it too, so a
    /// "remove token" in the UI doesn't leave a live refresh token behind.
    static func revokeAndDelete(connectionID: UUID) async {
        if let credential = load(connectionID: connectionID) {
            await ClaudeOAuth.revoke(credential)
        }
        delete(connectionID: connectionID)
    }

    // MARK: - Access

    /// The access token to inject, refreshed first if it's near expiry.
    ///
    /// This is the piece that makes an 8-hour credential workable: a managed
    /// session gets a token minted moments before `claude` reads it, so the
    /// working window starts full-length. It pairs with the tmux idle teardown —
    /// sessions that outlive their token don't accumulate, they get reaped, and
    /// the next launch mints again.
    ///
    /// A refresh failure is non-fatal: the existing token is returned and the
    /// session is allowed to start. A still-valid-but-unrefreshable token beats
    /// refusing to launch, and if it really is dead the agent's own auth error is
    /// a clearer signal than a launch that silently didn't happen.
    static func validCredential(connectionID: UUID) async -> ClaudeOAuth.Credential? {
        guard let credential = load(connectionID: connectionID) else { return nil }
        guard !credential.isFresh() else { return credential }
        guard credential.canRefresh else {
            log.line("Credential stale and not refreshable; using it as-is")
            return credential
        }
        do {
            let refreshed = try await ClaudeOAuth.refresh(credential)
            save(refreshed, connectionID: connectionID)
            return refreshed
        } catch {
            log.line("Refresh failed (\(error.localizedDescription)); falling back to stored credential")
            return credential
        }
    }

    /// Convenience for callers that only need the token itself.
    static func validAccessToken(connectionID: UUID) async -> String? {
        await validCredential(connectionID: connectionID)?.accessToken
    }

    /// Human-readable state for the login sheet — what was granted and how long
    /// it lasts, so a server-side scope downgrade is visible rather than showing
    /// up later as a confusing permission error.
    static func summary(connectionID: UUID) -> String? {
        guard let credential = load(connectionID: connectionID) else { return nil }
        var parts: [String] = []
        if credential.hasFullScopes {
            parts.append("Full session scopes")
        } else if credential.hasProfileScope {
            parts.append("Scopes: \(credential.scopes.joined(separator: ", "))")
        } else {
            parts.append("⚠︎ Missing user:profile — granted: \(credential.scopes.joined(separator: ", "))")
        }
        // The plan is reported separately from the scopes because it comes from a
        // separate request, and a missing plan is its own distinct failure: the
        // session runs, but the CLI shows it as "Claude API" and gates
        // plan-included models behind usage credits.
        if let plan = credential.subscriptionType {
            parts.append("plan: \(plan)")
        } else {
            parts.append("⚠︎ no plan detected — models included with your subscription will ask for usage credits")
        }
        if let email = credential.accountEmail {
            parts.append(email)
        }
        if let expiresAt = credential.expiresAt {
            let style = Date.RelativeFormatStyle(presentation: .named)
            parts.append(credential.isLongLived
                         ? "long-lived, expires \(expiresAt.formatted(.dateTime.month().day().year()))"
                         : "refreshes automatically, expires \(expiresAt.formatted(style))")
        }
        return parts.joined(separator: " · ")
    }
}
