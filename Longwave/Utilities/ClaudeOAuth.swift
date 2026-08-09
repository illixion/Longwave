import CryptoKit
import Foundation
import os

/// Runs Claude Code's own OAuth **authorization-code + PKCE** flow on this
/// device, so a Vision Pro can mint its own `CLAUDE_CODE_OAUTH_TOKEN` without a
/// Mac in the loop.
///
/// Why this exists rather than `claude setup-token`: that command is deliberately
/// scope-limited. The CLI passes `inferenceOnly` for it, which reduces the
/// request to `user:inference` alone — enough to run the model, but not to read
/// the account profile. Without `user:profile` the agent can't see which models
/// the subscription is entitled to, so a session can't tell that Fable is
/// available to it. This flow requests the full session scope set instead
/// (`fullScopes`), which is what an interactive `claude /login` asks for.
///
/// **Unsupported surface.** Anthropic documents `setup-token` and `/login`, not
/// this. Every constant below was read out of the installed `claude` binary
/// (2.1.222, `CLIENT_ID`/`TOKEN_URL`/scope arrays) rather than a public spec, so
/// an upstream change can move them without warning — `ClaudeOAuthConstants`
/// keeps them in one block for exactly that reason, and `ProjectsView`'s login
/// sheet reports the scopes the server actually granted so a silent downgrade is
/// visible rather than mysterious. The client is public (no secret), and the
/// credential minted belongs to the signed-in user's own subscription.
enum ClaudeOAuth {

    // MARK: - Wire constants

    /// Everything version-sensitive, in one place. Re-extract from a newer
    /// `claude` binary with:
    /// `strings -n 6 <binary> | grep -oE '.{600}CLIENT_ID:"[0-9a-f-]{36}".{500}'`
    enum Constants {
        /// Claude Code's public OAuth client (no secret — PKCE is the proof).
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        /// Subscription (claude.ai) authorize endpoint — the one `/login` uses
        /// for Pro/Max accounts. The console endpoint
        /// (`platform.claude.com/oauth/authorize`) is for API-credit accounts.
        static let authorizeURL = "https://claude.com/cai/oauth/authorize"
        static let tokenURL = "https://platform.claude.com/v1/oauth/token"
        static let revokeURL = "https://platform.claude.com/v1/oauth/token/revoke"
        /// Redirect the CLI registers for its loopback listener. Nothing listens
        /// on this port here — the in-app browser's navigation to it is
        /// intercepted before the request is ever made (see `authCode(from:)`).
        static let callbackPort = 3118
        static var redirectURI: String { "http://localhost:\(callbackPort)/callback" }
        /// Paste-code fallback redirect, for hosts where the loopback URL can't
        /// be intercepted. Renders the code on a page instead of in the URL.
        static let manualRedirectURI = "https://platform.claude.com/oauth/code/callback"

        /// Account profile, which is where the subscription tier comes from.
        /// `/login` fetches this right after its exchange and persists it beside
        /// the token; an env-var session has no persisted profile, so this app has
        /// to fetch it too and pass the result through.
        static let profileURL = "https://api.anthropic.com/api/oauth/profile"

        /// `organization.organization_type` → the CLI's own `subscriptionType`
        /// vocabulary, mirroring its internal map. An unrecognized type means no
        /// tier, which the CLI renders as the "Claude API" fallback.
        static let subscriptionTypesByOrgType = [
            "claude_max": "max",
            "claude_pro": "pro",
            "claude_enterprise": "enterprise",
            "claude_team": "team",
        ]

        // Env vars the CLI reads when authenticating from the environment. The
        // token alone is not enough — see `Credential.sessionEnvironment`.
        static let tokenEnvName = "CLAUDE_CODE_OAUTH_TOKEN"
        static let scopesEnvName = "CLAUDE_CODE_OAUTH_SCOPES"
        static let subscriptionTypeEnvName = "CLAUDE_CODE_SUBSCRIPTION_TYPE"
        static let rateLimitTierEnvName = "CLAUDE_CODE_RATE_LIMIT_TIER"
        static let refreshTokenEnvName = "CLAUDE_CODE_OAUTH_REFRESH_TOKEN"

        /// The full managed-session scope set, matching the CLI's own `Hat`
        /// array — what `/login` grants and what the CLI re-requests on every
        /// refresh. `org:create_api_key` is deliberately **not** requested: the
        /// CLI includes it so `/login` can mint console API keys, which this app
        /// never does, and a token that can create API keys is a bigger secret
        /// than one that can't.
        static let fullScopes = [
            "user:profile",
            "user:inference",
            "user:sessions:claude_code",
            "user:mcp_servers",
            "user:file_upload",
        ]

        // No custom expiry constant on purpose. `setup-token` asks the server for
        // a one-year token, and the client will happily send `expires_in` on any
        // exchange — but with this scope set the server **rejects the request
        // outright**:
        //
        //     HTTP 400: custom expires_in not allowed for scope user:mcp_servers
        //
        // So a custom duration isn't merely downgraded, it fails sign-in, and the
        // restriction is attached to specific scopes rather than to token
        // lifetime in general. Full-scope tokens therefore take the server's
        // default (~8h) and are refreshed instead. Don't reintroduce `expires_in`
        // here without dropping scopes — `ClaudeOAuthTests` guards it.
    }

    private static let log = Logger(subsystem: "pro.longwave", category: "ClaudeOAuth")

    // MARK: - Credential

    /// A minted credential. Persisted (as JSON) only in the Vision Pro keychain;
    /// the access token is what gets injected into a session as
    /// `CLAUDE_CODE_OAUTH_TOKEN`, and the refresh token never leaves the device.
    struct Credential: Codable, Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        /// Absolute expiry of `accessToken`. nil → the server didn't say, treat
        /// as unknown-but-usable and let a 401 drive re-auth.
        var expiresAt: Date?
        /// Scopes the **server** granted, which can be narrower than requested.
        var scopes: [String]

        // Profile fields, fetched separately from the token. All optional: a
        // failed profile fetch must never block a sign-in that otherwise worked.

        /// `max` / `pro` / `team` / `enterprise`. Without this the CLI shows the
        /// plan as "Claude API" and treats the session as having no subscription.
        var subscriptionType: String?
        var rateLimitTier: String?
        /// Shown in the login sheet so the user can confirm which account signed in.
        var accountEmail: String?

        /// Whether the granted set covers everything a managed session needs.
        var hasFullScopes: Bool {
            Set(Constants.fullScopes).isSubset(of: Set(scopes))
        }

        /// Whether `user:profile` was granted — the scope that lets the agent
        /// read the account's model entitlements.
        var hasProfileScope: Bool { scopes.contains("user:profile") }

        /// A token good for months rather than hours, i.e. the server honored a
        /// long-lived request. When false the credential must be refreshed
        /// before each launch.
        var isLongLived: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow > 30 * 24 * 60 * 60
        }

        /// Usable right now, with `margin` of headroom so a session isn't handed
        /// a token that dies mid-startup.
        func isFresh(margin: TimeInterval = 10 * 60) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > margin
        }

        var canRefresh: Bool { !(refreshToken ?? "").isEmpty }

        /// Everything a managed session needs in its environment, the access
        /// token included.
        ///
        /// Passing the token alone is **not** sufficient, which is the whole
        /// reason this exists. When the CLI authenticates from the environment it
        /// builds its credential as `scopes: CGp()`, and `CGp` defaults to
        /// `["user:inference"]` — it has no way to introspect the token, so a
        /// full-scope token is still treated as inference-only unless
        /// `CLAUDE_CODE_OAUTH_SCOPES` says otherwise. Likewise `subscriptionType`
        /// comes only from `CLAUDE_CODE_SUBSCRIPTION_TYPE`; absent it the CLI
        /// resolves no tier, prints the plan as "Claude API", and gates
        /// plan-dependent models behind separately-purchased usage credits.
        ///
        /// `includeRefreshToken` hands the CLI the refresh token so it manages
        /// renewal itself and a session stops being bounded by one token's life.
        /// Off by default deliberately: the access token expires in ~8h, which is
        /// a useful blast radius if anything on the host can read a process's
        /// environment, and a refresh token has no such bound.
        func sessionEnvironment(includeRefreshToken: Bool = false) -> [(name: String, value: String)] {
            var env: [(name: String, value: String)] = [
                (Constants.tokenEnvName, accessToken),
                // Report what the server actually granted, not what was asked for.
                (Constants.scopesEnvName, scopes.joined(separator: " ")),
            ]
            if let subscriptionType, !subscriptionType.isEmpty {
                env.append((Constants.subscriptionTypeEnvName, subscriptionType))
            }
            if let rateLimitTier, !rateLimitTier.isEmpty {
                env.append((Constants.rateLimitTierEnvName, rateLimitTier))
            }
            // The CLI rejects a refresh token that arrives without scopes; those
            // are always set above, so the pairing is satisfied by construction.
            if includeRefreshToken, let refreshToken, !refreshToken.isEmpty {
                env.append((Constants.refreshTokenEnvName, refreshToken))
            }
            return env
        }

        /// Folds a fetched profile in, leaving existing values alone where the
        /// profile came back empty.
        mutating func apply(_ profile: Profile) {
            subscriptionType = profile.subscriptionType ?? subscriptionType
            rateLimitTier = profile.rateLimitTier ?? rateLimitTier
            accountEmail = profile.accountEmail ?? accountEmail
        }
    }

    /// The account details behind a token — separate from the token itself, and
    /// fetched separately.
    struct Profile: Sendable, Equatable {
        var subscriptionType: String?
        var rateLimitTier: String?
        var accountEmail: String?
    }

    enum FlowError: LocalizedError {
        case http(Int, String?)
        case malformedResponse
        case stateMismatch
        case noRefreshToken
        case cancelled

        var errorDescription: String? {
            switch self {
            case .http(let code, let detail):
                if let detail, !detail.isEmpty { return "Claude returned HTTP \(code): \(detail)" }
                return "Claude returned HTTP \(code)."
            case .malformedResponse:
                return "Unexpected response from Claude's token endpoint."
            case .stateMismatch:
                return "The sign-in response didn't match this request. Try again."
            case .noRefreshToken:
                return "This credential can't be refreshed — sign in again."
            case .cancelled:
                return "Sign-in was cancelled."
            }
        }
    }

    // MARK: - PKCE

    /// A PKCE verifier/challenge pair plus the CSRF `state`. The verifier never
    /// leaves the device and is never sent to the authorize endpoint, which is
    /// why a `/login` URL scraped from a terminal can't be completed here — only
    /// the process that generated the verifier can finish the exchange.
    struct PKCE: Sendable {
        let verifier: String
        let challenge: String
        let state: String

        init() {
            verifier = Self.randomURLSafe()
            challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            state = Self.randomURLSafe()
        }

        private static func randomURLSafe(byteCount: Int = 32) -> String {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
            return Data(bytes).base64URLEncoded
        }
    }

    // MARK: - Step 1: the authorize URL

    /// Builds the URL the in-app browser loads. Parameter set and order mirror
    /// the CLI's own builder.
    static func authorizeURL(pkce: PKCE, useManualRedirect: Bool = false) -> URL {
        var comps = URLComponents(string: Constants.authorizeURL)!
        comps.queryItems = [
            // The CLI always sends this; the authorize page uses it to render
            // the paste-code affordance.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Constants.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri",
                         value: useManualRedirect ? Constants.manualRedirectURI : Constants.redirectURI),
            URLQueryItem(name: "scope", value: Constants.fullScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return comps.url!
    }

    /// Pulls `(code, state)` out of a redirect the browser is *about* to follow.
    /// Returns nil for any other navigation, so the caller can use this as the
    /// "is this the end of the flow?" test in a navigation delegate.
    static func authCode(from url: URL) -> (code: String, state: String?)? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let isLoopback = (comps.host == "localhost" || comps.host == "127.0.0.1")
            && comps.path == "/callback"
        let isManual = url.absoluteString.hasPrefix(Constants.manualRedirectURI)
        guard isLoopback || isManual else { return nil }
        guard let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    /// Normalizes a hand-pasted code. The paste-code page can render it as
    /// `code#state`; accept either form.
    static func splitPastedCode(_ raw: String) -> (code: String, state: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else { return (trimmed, nil) }
        return (String(trimmed[..<hash]), String(trimmed[trimmed.index(after: hash)...]))
    }

    // MARK: - Step 2: exchange

    /// The authorization-code exchange body. Extracted so a test can assert what
    /// is (and isn't) on the wire — notably that no `expires_in` is present.
    static func authorizationCodeBody(code: String, pkce: PKCE,
                                      useManualRedirect: Bool = false) -> [String: Any] {
        [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": useManualRedirect ? Constants.manualRedirectURI : Constants.redirectURI,
            "client_id": Constants.clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ]
    }

    /// Exchanges an authorization code for a credential, taking the server's
    /// default token lifetime.
    ///
    /// No custom `expires_in` is requested: asking for one is rejected outright
    /// with `custom expires_in not allowed for scope user:mcp_servers` (400), so
    /// there is no version of this flow that yields both full scopes and a
    /// long-lived token. The credential is short-lived by design and renewed
    /// before each launch instead.
    ///
    /// The granted scopes still come from the **response**, not the request — the
    /// server is free to narrow them, and the login sheet surfaces what it
    /// actually returned.
    static func exchange(code: String, pkce: PKCE,
                         returnedState: String?,
                         useManualRedirect: Bool = false) async throws -> Credential {
        if let returnedState, returnedState != pkce.state {
            throw FlowError.stateMismatch
        }
        var credential = try await postToken(
            authorizationCodeBody(code: code, pkce: pkce, useManualRedirect: useManualRedirect)
        )
        credential.apply(await fetchProfile(accessToken: credential.accessToken))
        log.line("Exchange granted scopes=\(credential.scopes.joined(separator: ",")) "
                 + "plan=\(credential.subscriptionType ?? "unknown")")
        return credential
    }

    /// Reads the account profile so the subscription tier can be passed to a
    /// session. Mirrors what `/login` does immediately after its own exchange.
    ///
    /// Non-throwing: a profile that can't be read yields an empty one. Sign-in
    /// still succeeds and inference still works — the session just falls back to
    /// the CLI's no-tier behaviour, which the login sheet surfaces rather than
    /// hiding.
    static func fetchProfile(accessToken: String) async -> Profile {
        var req = URLRequest(url: URL(string: Constants.profileURL)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.line("Profile fetch failed; session will report no subscription tier")
            return Profile()
        }
        let organization = json["organization"] as? [String: Any]
        let orgType = organization?["organization_type"] as? String
        let account = json["account"] as? [String: Any]
        return Profile(
            subscriptionType: orgType.flatMap { Constants.subscriptionTypesByOrgType[$0] },
            // The payload has been seen with the tier both nested under
            // `organization` and flattened; accept either rather than guess.
            rateLimitTier: (organization?["rate_limit_tier"] as? String)
                ?? (json["organization_rate_limit_tier"] as? String),
            accountEmail: (account?["email_address"] as? String)
                ?? (json["account_email"] as? String)
        )
    }

    // MARK: - Step 3: refresh

    /// Refreshes `credential`, explicitly re-requesting the full scope set.
    ///
    /// The explicit `scope` matters: refreshing without it has been observed to
    /// return a token that silently lost `user:profile`, which then fails calls
    /// with "OAuth token does not meet scope requirement user:profile". The
    /// current CLI sends the same list for the same reason.
    ///
    /// A refresh response that omits `refresh_token` keeps the existing one
    /// (the CLI does this too — not every server rotates on use).
    static func refresh(_ credential: Credential) async throws -> Credential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw FlowError.noRefreshToken
        }
        var refreshed = try await postToken(refreshBody(refreshToken: refreshToken))
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        // Carry the profile across rather than re-fetching on every launch — the
        // tier doesn't change token-to-token, and a refresh sits directly in front
        // of a session start where an extra round-trip is felt.
        refreshed.subscriptionType = credential.subscriptionType
        refreshed.rateLimitTier = credential.rateLimitTier
        refreshed.accountEmail = credential.accountEmail
        // Unless it was never learned, in which case try again now.
        if refreshed.subscriptionType == nil {
            refreshed.apply(await fetchProfile(accessToken: refreshed.accessToken))
        }
        log.line("Refreshed; scopes=\(refreshed.scopes.joined(separator: ","))")
        return refreshed
    }

    /// The refresh body. Extracted alongside `authorizationCodeBody` so both
    /// grants can be asserted on: the full `scope` must be present, and
    /// `expires_in` must not be.
    static func refreshBody(refreshToken: String) -> [String: Any] {
        [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Constants.clientID,
            "scope": Constants.fullScopes.joined(separator: " "),
        ]
    }

    /// Best-effort revocation, so removing a token from the app also invalidates
    /// it server-side rather than leaving a live credential in the wild. Silent
    /// on failure — the local secret is deleted either way.
    static func revoke(_ credential: Credential) async {
        guard let token = credential.refreshToken, !token.isEmpty else { return }
        var req = URLRequest(url: URL(string: Constants.revokeURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "token_type_hint": "refresh_token",
            "client_id": Constants.clientID,
        ])
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Transport

    /// POSTs a **JSON** body to the token endpoint. Note this endpoint is JSON,
    /// not the form encoding most OAuth servers take — a form body is rejected.
    private static func postToken(_ body: [String: Any]) async throws -> Credential {
        var req = URLRequest(url: URL(string: Constants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FlowError.malformedResponse }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(http.statusCode) else {
            // Surface the server's own message; never log the body, which on a
            // success path would carry the token itself.
            let detail = (json?["error_description"] as? String)
                ?? (json?["error"] as? String)
            log.line("Token endpoint failed status=\(http.statusCode)")
            throw FlowError.http(http.statusCode, detail)
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else {
            throw FlowError.malformedResponse
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let scopeString = (json["scope"] as? String) ?? ""
        let scopes = scopeString.split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        return Credential(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            // An empty `scope` in the response means "what you asked for".
            scopes: scopes.isEmpty ? Constants.fullScopes : scopes
        )
    }
}

// MARK: - base64url

private extension Data {
    /// RFC 7636 base64url: unpadded, URL-safe alphabet.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
