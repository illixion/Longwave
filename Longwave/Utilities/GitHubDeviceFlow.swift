import Foundation
import os

/// Runs GitHub's OAuth **device-authorization flow** on this device to mint a
/// token for the GitHub Copilot CLI, so we never have to read it back out of the
/// Mac's keychain (unreachable over SSH — the same wall that forces Claude's
/// `setup-token`). The captured `access_token` is stored on the Vision Pro and
/// injected into each managed session as `COPILOT_GITHUB_TOKEN` — Copilot reads
/// that env var ahead of any stored credential, so nothing touches the Mac.
///
/// Copilot CLI is a **public** GitHub App client (no client secret), so the flow
/// runs entirely from the headset against `github.com`. The client id, scope and
/// endpoints below were taken from the installed `@github/copilot` package; the
/// minted token is "an OAuth token from the GitHub Copilot CLI app", which
/// Copilot documents as supported.
enum GitHubDeviceFlow {

    // Public client constants (not secrets) — see `copilot login`'s device flow.
    static let clientID = "Ov23ctDVkRmgkPke0Mmm"
    static let scope = "read:user,read:org,repo,gist"
    private static let host = "https://github.com"
    private static let deviceCodePath = "/login/device/code"
    private static let tokenPath = "/login/oauth/access_token"

    private static let log = Logger(subsystem: "com.illixion.Longwave", category: "GitHubDeviceFlow")

    /// The user-facing step of the flow: show `userCode`, send them to
    /// `verificationURI`, then poll with `deviceCode`.
    struct DeviceCode: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let interval: Int
        let expiresIn: Int
    }

    enum FlowError: LocalizedError {
        case http(Int)
        case malformedResponse
        case authorizationDeclined
        case expired
        case server(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): "GitHub returned HTTP \(code)."
            case .malformedResponse: "Unexpected response from GitHub."
            case .authorizationDeclined: "Authorization was declined."
            case .expired: "The code expired before you authorized. Try again."
            case .server(let msg): msg
            }
        }
    }

    /// Step 1 — request a device + user code.
    static func requestCode() async throws -> DeviceCode {
        let json = try await postForm(path: deviceCodePath, fields: [
            "client_id": clientID,
            "scope": scope,
        ])
        guard let device = json["device_code"] as? String,
              let user = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else {
            throw FlowError.malformedResponse
        }
        let interval = (json["interval"] as? Int) ?? 5
        let expires = (json["expires_in"] as? Int) ?? 900
        log.line("Device code issued; user_code shown, polling every \(interval)s")
        return DeviceCode(deviceCode: device, userCode: user,
                          verificationURI: uri, interval: interval, expiresIn: expires)
    }

    /// Step 2 — poll until the user authorizes (or the code expires). Honors the
    /// `slow_down` backoff and `authorization_pending` per the device-flow spec.
    /// Cancellation-aware: stop the enclosing `Task` to abort. Returns the
    /// `access_token`.
    static func pollForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            try Task.checkCancellation()
            let json = try await postForm(path: tokenPath, fields: [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String, !token.isEmpty {
                log.line("Device flow authorized; token captured")
                return token
            }
            switch json["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                // Spec: back off. Use the server's new interval if given, else +5s.
                interval = (json["interval"] as? Int) ?? (interval + 5)
                continue
            case "expired_token":
                throw FlowError.expired
            case "access_denied":
                throw FlowError.authorizationDeclined
            case .some(let other):
                throw FlowError.server((json["error_description"] as? String) ?? other)
            case nil:
                throw FlowError.malformedResponse
            }
        }
        throw FlowError.expired
    }

    // MARK: - Transport

    private static func postForm(path: String, fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: host + path)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        var comps = URLComponents()
        comps.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The token endpoint reports pending/slow_down as 4xx with a JSON
            // `error`; surface that body rather than the bare status when present.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["error"] != nil {
                return obj
            }
            throw FlowError.http(http.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowError.malformedResponse
        }
        return obj
    }
}
