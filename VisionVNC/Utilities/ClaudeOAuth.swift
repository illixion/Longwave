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

        /// One year, the expiry `setup-token` asks for. Sent on the exchange as
        /// an opportunistic request — see `Credential.isLongLived`.
        static let longLivedExpirySeconds = 31_536_000
    }

    private static let log = Logger(subsystem: "com.illixion.VisionVNC", category: "ClaudeOAuth")

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

    /// Exchanges an authorization code for a credential.
    ///
    /// `requestLongLived` opportunistically asks for a one-year token (what
    /// `setup-token` requests). The two knobs are independent in the client, but
    /// the server appears to couple them — the CLI's own copy states that
    /// long-lived tokens "are limited to inference-only for security reasons".
    /// So this asks for both and **believes the response**: if the granted scopes
    /// come back narrowed, the caller keeps the refresh token and refreshes per
    /// launch instead. Never assume the request shape determines what you got.
    static func exchange(code: String, pkce: PKCE,
                         returnedState: String?,
                         useManualRedirect: Bool = false,
                         requestLongLived: Bool = false) async throws -> Credential {
        if let returnedState, returnedState != pkce.state {
            throw FlowError.stateMismatch
        }
        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": useManualRedirect ? Constants.manualRedirectURI : Constants.redirectURI,
            "client_id": Constants.clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ]
        if requestLongLived { body["expires_in"] = Constants.longLivedExpirySeconds }
        let credential = try await postToken(body)
        log.line("Exchange granted scopes=\(credential.scopes.joined(separator: ",")) longLived=\(credential.isLongLived)")
        return credential
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
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Constants.clientID,
            "scope": Constants.fullScopes.joined(separator: " "),
        ]
        var refreshed = try await postToken(body)
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        log.line("Refreshed; scopes=\(refreshed.scopes.joined(separator: ","))")
        return refreshed
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
