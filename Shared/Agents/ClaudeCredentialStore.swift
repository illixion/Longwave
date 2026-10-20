import DebugTrace
import Foundation

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

    private static let service = "pro.longwave.claudeOAuthCredential"
    private static let log = DebugLogger(subsystem: "pro.longwave", category: "ClaudeCredentials")
    private static var refreshes: [UUID: Task<ClaudeOAuth.Credential?, Never>] = [:]

    // MARK: - Storage

    static func load(connectionID: UUID) -> ClaudeOAuth.Credential? {
        guard let json = KeychainStore.get(service: service, account: connectionID.uuidString),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeOAuth.Credential.self, from: data)
    }

    @discardableResult
    static func save(_ credential: ClaudeOAuth.Credential, connectionID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(credential),
              let json = String(data: data, encoding: .utf8) else { return false }
        return KeychainStore.set(service: service, account: connectionID.uuidString, value: json)
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

    /// The credential to inject, refreshed first if it's near expiry, or nil
    /// when nothing stored can authenticate a session.
    ///
    /// This is the piece that makes an 8-hour credential workable: a managed
    /// session gets a token minted moments before `claude` reads it, so the
    /// working window starts full-length. It pairs with the tmux idle teardown —
    /// sessions that outlive their token don't accumulate, they get reaped, and
    /// the next launch mints again.
    ///
    /// A refresh that fails for a passing reason (network, a 5xx) still returns
    /// the stored token while it hasn't expired. An **expired** token is never
    /// returned: handing it to a session only produces a 401 from inside the
    /// agent, so the caller gets nil and can say "sign in again" instead. A
    /// refresh the server rejects outright (`invalid_grant` — an organisation's
    /// forced sign-out, a revocation) is recorded on the credential, so the
    /// setup sheet shows it and later launches don't retry a dead token.
    ///
    /// `margin` is how much life the token must have left to be used as is: a
    /// launch needs enough to start, while the sandbox's credentials keeper asks
    /// for more so its rewrite lands well before a running session needs it.
    static func validCredential(connectionID: UUID,
                                margin: TimeInterval = 10 * 60) async -> ClaudeOAuth.Credential? {
        if let pending = refreshes[connectionID] { return await pending.value }
        guard let credential = load(connectionID: connectionID) else { return nil }
        guard !credential.isFresh(margin: margin) else { return credential }
        guard credential.canRefresh else {
            log.log("Credential stale and not refreshable; expired=\(credential.isExpired, privacy: .public)")
            return unexpired(credential)
        }
        let task = Task<ClaudeOAuth.Credential?, Never> {
            do {
                let refreshed = try await ClaudeOAuth.refresh(credential)
                // A sign-out or new sign-in while awaiting the network must
                // not be undone by an older refresh finishing afterwards.
                guard load(connectionID: connectionID)?.refreshToken == credential.refreshToken else {
                    return load(connectionID: connectionID).flatMap(unexpired)
                }
                guard save(refreshed, connectionID: connectionID) else {
                    log.error("Couldn't persist refreshed Claude credential")
                    return nil
                }
                return refreshed
            } catch ClaudeOAuth.FlowError.signedOut {
                log.error("Refresh token rejected; Claude sign-in required")
                markRefreshRejected(credential, connectionID: connectionID)
                return load(connectionID: connectionID).flatMap(unexpired)
            } catch {
                log.log("Refresh failed; using the stored credential while it lasts")
                return load(connectionID: connectionID).flatMap(unexpired)
            }
        }
        refreshes[connectionID] = task
        defer { refreshes.removeValue(forKey: connectionID) }
        return await task.value
    }

    private static func unexpired(_ credential: ClaudeOAuth.Credential) -> ClaudeOAuth.Credential? {
        credential.isExpired ? nil : credential
    }

    /// Records that the server refused `credential`'s refresh token, unless a
    /// new sign-in has replaced it in the meantime.
    private static func markRefreshRejected(_ credential: ClaudeOAuth.Credential, connectionID: UUID) {
        guard var stored = load(connectionID: connectionID),
              stored.refreshToken == credential.refreshToken else { return }
        stored.refreshRejectedAt = Date()
        save(stored, connectionID: connectionID)
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
        if credential.needsSignIn {
            parts.append(credential.refreshRejectedAt != nil
                         ? "⚠︎ signed out by Claude — sign in again"
                         : "⚠︎ expired — sign in again")
        } else if let expiresAt = credential.expiresAt {
            let relative = expiresAt.formatted(Date.RelativeFormatStyle(presentation: .named))
            if credential.isLongLived {
                parts.append("long-lived, expires \(expiresAt.formatted(.dateTime.month().day().year()))")
            } else if !credential.canRefresh {
                parts.append("expires \(relative)")
            } else if credential.isFresh() {
                parts.append("refreshes automatically, expires \(relative)")
            } else {
                // Expired access tokens are normal between launches; the next
                // launch mints a new one.
                parts.append("renews at next launch")
            }
        }
        if !credential.needsSignIn, let refreshEnd = credential.refreshTokenExpiresAt {
            parts.append("sign in again by \(refreshEnd.formatted(.dateTime.month().day()))")
        }
        return parts.joined(separator: " · ")
    }
}
