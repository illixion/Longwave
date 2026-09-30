import DebugTrace
import Foundation

/// Runs the OpenAI Codex CLI's own **ChatGPT device-code sign-in** on this
/// device, so a headset can sign a host's Codex sessions in without a browser on
/// the Mac and without the refresh token ever leaving the headset.
///
/// **Unsupported surface.** OpenAI documents `codex login` (browser and
/// `--device-auth`), not these endpoints. Everything in `Constants` was read out
/// of the open-source CLI (`openai/codex`, `codex-rs/login/src/`:
/// `device_code_auth.rs`, `server.rs`, `oauth/client.rs`,
/// `auth/manager.rs`, `auth/revoke.rs`, `token_data.rs`) at 0.159 — re-check
/// those files when a CLI release breaks sign-in. The client is public (no
/// secret) and the credential belongs to the signed-in user's own plan.
///
/// What the source establishes, and why this file looks the way it does:
///
/// - **Device flow is OpenAI's own, not RFC 8628.** `POST {issuer}/api/accounts/
///   deviceauth/usercode` with JSON `{client_id}` returns `device_auth_id`,
///   `user_code` (also spelled `usercode`) and `interval` **as a string**. The
///   user enters the code at `{issuer}/codex/device`. Polling
///   `POST …/deviceauth/token` with JSON `{device_auth_id, user_code}` answers
///   403/404 while pending and, once approved, returns an *authorization code
///   plus the PKCE pair the server generated* (`authorization_code`,
///   `code_challenge`, `code_verifier`). The CLI gives up after 15 minutes.
/// - That code is then exchanged like any PKCE code at `{issuer}/oauth/token`,
///   **form-encoded**, with `redirect_uri = {issuer}/deviceauth/callback`,
///   returning `id_token`, `access_token`, `refresh_token`.
/// - **Refresh is JSON** (`grant_type=refresh_token`, `client_id`,
///   `refresh_token`) at the same endpoint, and **refresh tokens rotate**: the
///   server reports reuse as `refresh_token_reused`, a permanent failure. So a
///   refresh token can have exactly one owner — this device — which is the other
///   reason it is never sent to a host: a host-side refresh would silently kill
///   the headset's copy, and vice versa.
/// - Lifetimes observed on a real login: access token 240 h, id token 1 h. The
///   id token is only *parsed* for claims (account id, plan, email), never
///   checked for expiry, so an hour-old one in `auth.json` is fine.
/// - **`CODEX_ACCESS_TOKEN` cannot carry this credential.** The CLI reads that
///   variable as a *personal access token* (`at-…`, hydrated via
///   `/v1/user-auth-credential/whoami`) or else as an *Agent Identity JWT*; a
///   ChatGPT OAuth access token is neither and fails to load. That variable
///   stays available for the paste path (a PAT). ChatGPT credentials reach the
///   CLI only through `$CODEX_HOME/auth.json` (the default `file` store), so a
///   session gets one written for it — see `sessionSetup`.
/// - The CLI refreshes proactively only when the access token's JWT `exp` is
///   within 5 minutes (else when `last_refresh` is over 8 days old). With a
///   fresh token and an empty `refresh_token` it therefore never tries during a
///   session's life; if it did, the empty token fails permanently and the fix
///   is relaunching, which mints a new token here.
enum CodexOAuth {

    // MARK: - Wire constants

    enum Constants {
        /// The Codex CLI's public OAuth client (`auth::CLIENT_ID`).
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let issuer = "https://auth.openai.com"
        static let userCodeURL = "\(issuer)/api/accounts/deviceauth/usercode"
        static let pollURL = "\(issuer)/api/accounts/deviceauth/token"
        /// Shown to the user; the page asks for the one-time code.
        static let verificationURL = "\(issuer)/codex/device"
        static let deviceRedirectURI = "\(issuer)/deviceauth/callback"
        static let tokenURL = "\(issuer)/oauth/token"
        static let revokeURL = "\(issuer)/oauth/revoke"
        /// The CLI's own device-flow deadline.
        static let deviceFlowTimeout: TimeInterval = 15 * 60

        /// Paste-path env var: a personal access token (`at-…`).
        static let accessTokenEnvName = "CODEX_ACCESS_TOKEN"
        /// Carries `auth.json` across the stdin channel to the create step, which
        /// writes it and unsets the variable before tmux ever sees it.
        static let authJSONEnvName = "LONGWAVE_CODEX_AUTH_JSON"
        /// Where sessions keep Codex state. Deliberately not `~/.codex`: writing
        /// our `auth.json` there would overwrite the host user's own Codex login
        /// (and discard *their* refresh token).
        static let sessionHomeDirectory = ".codex-longwave"
        /// Shared from `~/.codex` into the session home, so a session gets the
        /// user's config, instructions and skills without their credentials.
        static let sharedHomeEntries = ["config.toml", "AGENTS.md", "skills", "prompts", "rules"]
    }

    private static let log = DebugLogger(subsystem: "pro.longwave", category: "CodexOAuth")

    // MARK: - Credential

    /// A signed-in ChatGPT credential, persisted as JSON only in this device's
    /// keychain. Sessions receive the access and id tokens, never the refresh
    /// token.
    struct Credential: Codable, Sendable, Equatable {
        var accessToken: String
        var idToken: String
        var refreshToken: String?
        /// From the access token's JWT `exp`. nil when it can't be read.
        var expiresAt: Date?
        /// `chatgpt_account_id` from the id token — `auth.json` carries it.
        var accountID: String?
        var email: String?
        var planType: String?

        /// Usable with `margin` to spare. The default is a day rather than
        /// minutes: the CLI starts trying (and, with no refresh token, failing)
        /// to refresh five minutes before expiry, so a session should start with
        /// far more than that left.
        func isFresh(margin: TimeInterval = 24 * 60 * 60) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow > margin
        }

        var canRefresh: Bool { !(refreshToken ?? "").isEmpty }

        /// The `auth.json` a session's Codex reads, in the CLI's `AuthDotJson`
        /// shape. `refresh_token` is empty on purpose (the field is required by
        /// the CLI's `TokenData`, but empty is accepted).
        func authJSON(now: Date = Date()) -> String {
            var tokens: [String: Any] = [
                "id_token": idToken,
                "access_token": accessToken,
                "refresh_token": "",
            ]
            tokens["account_id"] = accountID ?? NSNull()
            let object: [String: Any] = [
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": NSNull(),
                "tokens": tokens,
                "last_refresh": ISO8601DateFormatter().string(from: now),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }

        /// What a managed session's environment gets: `auth.json` for the create
        /// step to write. Never the refresh token (see the type comment).
        func sessionEnvironment(now: Date = Date()) -> [(name: String, value: String)] {
            [(Constants.authJSONEnvName, authJSON(now: now))]
        }

        /// Fills account fields from the id token's claims.
        mutating func applyClaims() {
            let claims = CodexOAuth.claims(ofJWT: idToken)
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            accountID = (auth?["chatgpt_account_id"] as? String) ?? accountID
            planType = (auth?["chatgpt_plan_type"] as? String) ?? planType
            email = (claims["email"] as? String) ?? email
            if let exp = CodexOAuth.claims(ofJWT: accessToken)["exp"] as? NSNumber {
                expiresAt = Date(timeIntervalSince1970: exp.doubleValue)
            }
        }
    }

    /// The create-step half of a Codex session signed in with a `Credential`:
    /// writes `auth.json` into the session home and points `CODEX_HOME` at it.
    ///
    /// Runs inside the login shell after the stdin reader exported the
    /// variables. Only builtins (`printf`, `[`, `export`, `unset`) touch the
    /// JSON, so it never appears in an argv; the write is atomic (temp file +
    /// `mv`) under `umask 077`. User config is linked in from `~/.codex` when
    /// absent, never copied, so edits there keep applying.
    static let sessionSetupScript: String = {
        let home = "\"$HOME/\(Constants.sessionHomeDirectory)\""
        let shared = Constants.sharedHomeEntries.joined(separator: " ")
        return "if [ -n \"$\(Constants.authJSONEnvName)\" ]; then "
            + "export CODEX_HOME=\(home); "
            + "(umask 077; mkdir -p \"$CODEX_HOME\" && "
            + "for f in \(shared); do "
            + "[ -e \"$HOME/.codex/$f\" ] && [ ! -e \"$CODEX_HOME/$f\" ] && ln -s \"$HOME/.codex/$f\" \"$CODEX_HOME/$f\"; "
            + "done; "
            + "printf %s \"$\(Constants.authJSONEnvName)\" > \"$CODEX_HOME/auth.json.tmp\" && "
            + "mv -f \"$CODEX_HOME/auth.json.tmp\" \"$CODEX_HOME/auth.json\"); "
            + "fi; unset \(Constants.authJSONEnvName); "
    }()

    /// The session setup to pair with `environment`, or nil when it carries no
    /// OAuth credential (a pasted PAT needs none — `CODEX_ACCESS_TOKEN` is read
    /// straight from the environment). Registering `CODEX_HOME` with tmux when
    /// nothing sets it would *remove* a user-set one from the session, so it's
    /// only exported alongside a credential.
    static func sessionSetup(for environment: [(name: String, value: String)]) -> AgentSessionSetup? {
        guard environment.contains(where: { $0.name == Constants.authJSONEnvName }) else { return nil }
        return AgentSessionSetup(script: sessionSetupScript,
                                 exportedNames: ["CODEX_HOME"],
                                 consumedNames: [Constants.authJSONEnvName])
    }

    // MARK: - Errors

    enum FlowError: LocalizedError {
        case http(Int, String?)
        case malformedResponse
        case expired
        case noRefreshToken

        var errorDescription: String? {
            switch self {
            case .http(let code, let detail):
                if let detail, !detail.isEmpty { return "OpenAI returned HTTP \(code): \(detail)" }
                return "OpenAI returned HTTP \(code)."
            case .malformedResponse:
                return "Unexpected response from OpenAI's sign-in service."
            case .expired:
                return "The code expired before you approved it. Try again."
            case .noRefreshToken:
                return "This credential can't be refreshed — sign in again."
            }
        }
    }

    // MARK: - Step 1: user code

    struct DeviceCode: Sendable, Equatable {
        let deviceAuthID: String
        let userCode: String
        let interval: Int
        var verificationURL: String { Constants.verificationURL }
    }

    static func userCodeBody() -> [String: Any] { ["client_id": Constants.clientID] }

    /// Parses the user-code response. `interval` arrives as a string in the
    /// CLI's own model; a number is accepted too.
    static func parseDeviceCode(_ json: [String: Any]) -> DeviceCode? {
        guard let id = json["device_auth_id"] as? String, !id.isEmpty,
              let code = (json["user_code"] as? String) ?? (json["usercode"] as? String), !code.isEmpty
        else { return nil }
        let interval = (json["interval"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? (json["interval"] as? NSNumber)?.intValue
            ?? 5
        return DeviceCode(deviceAuthID: id, userCode: code, interval: max(1, interval))
    }

    static func requestCode() async throws -> DeviceCode {
        let (status, json) = try await postJSON(Constants.userCodeURL, body: userCodeBody())
        guard (200...299).contains(status) else {
            throw FlowError.http(status, status == 404 ? "Device sign-in isn't enabled for this account." : nil)
        }
        guard let json, let code = parseDeviceCode(json) else { throw FlowError.malformedResponse }
        log.log("Device code issued; polling every \(code.interval)s")
        return code
    }

    // MARK: - Step 2: poll, then exchange

    /// The outcome of one poll: 403/404 mean "not approved yet".
    enum PollResult: Equatable {
        case pending
        case approved(code: String, verifier: String)
        case failed(Int)
    }

    static func pollBody(_ code: DeviceCode) -> [String: Any] {
        ["device_auth_id": code.deviceAuthID, "user_code": code.userCode]
    }

    static func parsePoll(status: Int, json: [String: Any]?) -> PollResult {
        if status == 403 || status == 404 { return .pending }
        guard (200...299).contains(status) else { return .failed(status) }
        guard let code = json?["authorization_code"] as? String, !code.isEmpty,
              let verifier = json?["code_verifier"] as? String, !verifier.isEmpty
        else { return .failed(status) }
        return .approved(code: code, verifier: verifier)
    }

    /// Polls until approved, then exchanges the code. Cancellation-aware: cancel
    /// the enclosing `Task` to stop.
    static func pollForCredential(_ code: DeviceCode) async throws -> Credential {
        let deadline = Date().addingTimeInterval(Constants.deviceFlowTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(code.interval) * 1_000_000_000)
            try Task.checkCancellation()
            let (status, json) = try await postJSON(Constants.pollURL, body: pollBody(code))
            switch parsePoll(status: status, json: json) {
            case .pending:
                continue
            case .failed(let status):
                throw FlowError.http(status, nil)
            case .approved(let authCode, let verifier):
                var credential = try await postToken(form: authorizationCodeBody(code: authCode, verifier: verifier))
                credential.applyClaims()
                log.log("Device sign-in approved; plan=\(credential.planType ?? "unknown", privacy: .public)")
                return credential
            }
        }
        throw FlowError.expired
    }

    /// Form-encoded, exactly as the CLI sends it.
    static func authorizationCodeBody(code: String, verifier: String) -> [String: String] {
        [
            "grant_type": "authorization_code",
            "client_id": Constants.clientID,
            "code": code,
            "redirect_uri": Constants.deviceRedirectURI,
            "code_verifier": verifier,
        ]
    }

    // MARK: - Step 3: refresh

    /// JSON, unlike the code exchange — again matching the CLI.
    static func refreshBody(refreshToken: String) -> [String: Any] {
        [
            "grant_type": "refresh_token",
            "client_id": Constants.clientID,
            "refresh_token": refreshToken,
        ]
    }

    /// Refreshes and returns the **rotated** credential; the caller must persist
    /// it before anything else uses the old refresh token, which is now spent.
    /// Fields the response omits carry over, as the CLI does.
    static func refresh(_ credential: Credential) async throws -> Credential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw FlowError.noRefreshToken
        }
        let (status, json) = try await postJSON(Constants.tokenURL, body: refreshBody(refreshToken: refreshToken))
        guard (200...299).contains(status), let json else {
            log.log("Refresh failed status=\(status)")
            throw FlowError.http(status, errorDetail(json))
        }
        var refreshed = credential
        guard let access = json["access_token"] as? String, !access.isEmpty else { throw FlowError.malformedResponse }
        refreshed.accessToken = access
        if let id = json["id_token"] as? String, !id.isEmpty { refreshed.idToken = id }
        if let rotated = json["refresh_token"] as? String, !rotated.isEmpty { refreshed.refreshToken = rotated }
        refreshed.applyClaims()
        log.log("Refreshed Codex credential")
        return refreshed
    }

    /// Best-effort revocation of the refresh token. Silent on failure — the
    /// local secret is deleted either way.
    static func revoke(_ credential: Credential) async {
        guard let token = credential.refreshToken, !token.isEmpty else { return }
        _ = try? await postJSON(Constants.revokeURL, body: [
            "token": token,
            "token_type_hint": "refresh_token",
            "client_id": Constants.clientID,
        ], timeout: 10)
    }

    // MARK: - JWT claims

    /// Decodes a JWT's payload without verifying it — only used to read claims
    /// out of tokens this device just received over TLS from the issuer.
    static func claims(ofJWT jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: - Transport

    private static func errorDetail(_ json: [String: Any]?) -> String? {
        if let error = json?["error"] as? [String: Any] {
            return (error["message"] as? String) ?? (error["code"] as? String)
        }
        return (json?["error_description"] as? String) ?? (json?["error"] as? String)
    }

    /// Returns the status and parsed body; never logs a body, which on success
    /// would carry tokens.
    private static func postJSON(_ url: String, body: [String: Any],
                                 timeout: TimeInterval = 30) async throws -> (Int, [String: Any]?) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FlowError.malformedResponse }
        return (http.statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func postToken(form: [String: String]) async throws -> Credential {
        var req = URLRequest(url: URL(string: Constants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = formEncoded(form).data(using: .utf8)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FlowError.malformedResponse }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(http.statusCode) else {
            log.log("Code exchange failed status=\(http.statusCode)")
            throw FlowError.http(http.statusCode, errorDetail(json))
        }
        guard let json,
              let access = json["access_token"] as? String, !access.isEmpty,
              let id = json["id_token"] as? String, !id.isEmpty
        else { throw FlowError.malformedResponse }
        return Credential(accessToken: access, idToken: id,
                          refreshToken: json["refresh_token"] as? String)
    }

    /// `application/x-www-form-urlencoded`, strict: only unreserved characters
    /// pass through (`URLQueryItem` leaves `+` and `&`-adjacent characters that a
    /// form decoder would misread).
    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
