import XCTest
@testable import Longwave

/// The offline half of the Claude OAuth flow: authorize-URL construction, the
/// redirect interception that ends the flow, PKCE derivation, and the credential
/// predicates that decide whether a token needs refreshing before a launch.
///
/// Deliberately no network: the exchange and refresh calls hit Anthropic's live
/// token endpoint and would need a real account, so what's covered here is
/// everything that can be wrong without leaving the device.
@MainActor
final class ClaudeOAuthTests: XCTestCase {

    // MARK: - Authorize URL

    private func queryItems(_ url: URL) -> [String: String] {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues:
            (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testAuthorizeURLCarriesPKCEAndFullScopes() {
        let pkce = ClaudeOAuth.PKCE()
        let url = ClaudeOAuth.authorizeURL(pkce: pkce)
        let q = queryItems(url)

        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(url.path, "/cai/oauth/authorize")
        XCTAssertEqual(q["client_id"], ClaudeOAuth.Constants.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code"], "true")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], pkce.challenge)
        XCTAssertEqual(q["state"], pkce.state)
        XCTAssertEqual(q["redirect_uri"], "http://localhost:3118/callback")
    }

    /// The whole reason this flow exists instead of `setup-token`: it must ask
    /// for `user:profile`, not just inference.
    func testAuthorizeURLRequestsProfileScope() {
        let q = queryItems(ClaudeOAuth.authorizeURL(pkce: ClaudeOAuth.PKCE()))
        let scopes = Set((q["scope"] ?? "").split(separator: " ").map(String.init))
        XCTAssertTrue(scopes.contains("user:profile"))
        XCTAssertTrue(scopes.contains("user:inference"))
        XCTAssertTrue(scopes.contains("user:sessions:claude_code"))
        XCTAssertTrue(scopes.contains("user:mcp_servers"))
        XCTAssertTrue(scopes.contains("user:file_upload"))
    }

    /// `org:create_api_key` is in the CLI's set but not requested here — a token
    /// that can mint console API keys is a bigger secret than this app needs.
    func testAuthorizeURLOmitsAPIKeyScope() {
        let q = queryItems(ClaudeOAuth.authorizeURL(pkce: ClaudeOAuth.PKCE()))
        XCTAssertFalse((q["scope"] ?? "").contains("org:create_api_key"))
    }

    func testManualRedirectSwapsRedirectURI() {
        let url = ClaudeOAuth.authorizeURL(pkce: ClaudeOAuth.PKCE(), useManualRedirect: true)
        XCTAssertEqual(queryItems(url)["redirect_uri"],
                       "https://platform.claude.com/oauth/code/callback")
    }

    // MARK: - PKCE

    func testPKCEChallengeIsURLSafeAndDistinctFromVerifier() {
        let pkce = ClaudeOAuth.PKCE()
        XCTAssertNotEqual(pkce.challenge, pkce.verifier, "S256 must hash, not echo")
        for value in [pkce.challenge, pkce.verifier, pkce.state] {
            XCTAssertFalse(value.isEmpty)
            XCTAssertFalse(value.contains("+"))
            XCTAssertFalse(value.contains("/"))
            XCTAssertFalse(value.contains("="), "base64url is unpadded")
        }
    }

    func testPKCEPairsAreUnique() {
        XCTAssertNotEqual(ClaudeOAuth.PKCE().verifier, ClaudeOAuth.PKCE().verifier)
        XCTAssertNotEqual(ClaudeOAuth.PKCE().state, ClaudeOAuth.PKCE().state)
    }

    // MARK: - Redirect interception

    func testInterceptsLoopbackCallback() {
        let url = URL(string: "http://localhost:3118/callback?code=abc123&state=xyz")!
        let hit = ClaudeOAuth.authCode(from: url)
        XCTAssertEqual(hit?.code, "abc123")
        XCTAssertEqual(hit?.state, "xyz")
    }

    func testInterceptsLoopbackOnAnyPortAndNumericHost() {
        // The port is only a default; a redirect that comes back on another one
        // is still the end of the flow.
        XCTAssertEqual(ClaudeOAuth.authCode(from: URL(string: "http://localhost:9999/callback?code=a")!)?.code, "a")
        XCTAssertEqual(ClaudeOAuth.authCode(from: URL(string: "http://127.0.0.1:3118/callback?code=b")!)?.code, "b")
    }

    func testInterceptsManualCallbackWithCode() {
        let url = URL(string: "https://platform.claude.com/oauth/code/callback?code=m1&state=s1")!
        XCTAssertEqual(ClaudeOAuth.authCode(from: url)?.code, "m1")
    }

    /// Every page *before* the redirect must be allowed through, or the consent
    /// flow can't be completed.
    func testIgnoresNonCallbackNavigation() {
        for raw in [
            "https://claude.com/cai/oauth/authorize?client_id=x&code=true",
            "https://claude.ai/login",
            "https://accounts.google.com/o/oauth2/auth?client_id=x",
            "http://localhost:3118/other?code=nope",
        ] {
            XCTAssertNil(ClaudeOAuth.authCode(from: URL(string: raw)!),
                         "should not intercept \(raw)")
        }
    }

    func testIgnoresCallbackWithoutCode() {
        XCTAssertNil(ClaudeOAuth.authCode(from: URL(string: "http://localhost:3118/callback")!))
        XCTAssertNil(ClaudeOAuth.authCode(from: URL(string: "http://localhost:3118/callback?code=")!))
        // A denial comes back on the same path with an error instead of a code.
        XCTAssertNil(ClaudeOAuth.authCode(from: URL(string: "http://localhost:3118/callback?error=access_denied")!))
    }

    func testSplitPastedCode() {
        XCTAssertEqual(ClaudeOAuth.splitPastedCode("code123#state456").code, "code123")
        XCTAssertEqual(ClaudeOAuth.splitPastedCode("code123#state456").state, "state456")
        XCTAssertEqual(ClaudeOAuth.splitPastedCode("  bare  ").code, "bare")
        XCTAssertNil(ClaudeOAuth.splitPastedCode("bare").state)
    }

    // MARK: - Token request bodies

    /// Regression guard for a real 400. Sending a custom `expires_in` — which is
    /// what `setup-token` does to get its one-year token — is refused outright
    /// with `custom expires_in not allowed for scope user:mcp_servers`, so asking
    /// for one doesn't downgrade the token, it breaks sign-in entirely.
    func testExchangeNeverRequestsACustomExpiry() {
        let body = ClaudeOAuth.authorizationCodeBody(code: "c", pkce: ClaudeOAuth.PKCE())
        XCTAssertNil(body["expires_in"])
    }

    func testRefreshNeverRequestsACustomExpiry() {
        XCTAssertNil(ClaudeOAuth.refreshBody(refreshToken: "rt")["expires_in"])
    }

    func testExchangeBodyCarriesPKCEVerifierAndRedirect() {
        let pkce = ClaudeOAuth.PKCE()
        let body = ClaudeOAuth.authorizationCodeBody(code: "the-code", pkce: pkce)
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["code"] as? String, "the-code")
        XCTAssertEqual(body["code_verifier"] as? String, pkce.verifier)
        XCTAssertEqual(body["state"] as? String, pkce.state)
        XCTAssertEqual(body["client_id"] as? String, ClaudeOAuth.Constants.clientID)
        // Must match the redirect the code was issued for, or the exchange 400s.
        XCTAssertEqual(body["redirect_uri"] as? String, "http://localhost:3118/callback")
    }

    func testExchangeBodyHonoursManualRedirect() {
        let body = ClaudeOAuth.authorizationCodeBody(
            code: "c", pkce: ClaudeOAuth.PKCE(), useManualRedirect: true)
        XCTAssertEqual(body["redirect_uri"] as? String,
                       "https://platform.claude.com/oauth/code/callback")
    }

    /// Refreshing without an explicit `scope` has been observed to return a token
    /// that silently lost `user:profile`.
    func testRefreshBodyReRequestsTheFullScopeSet() {
        let body = ClaudeOAuth.refreshBody(refreshToken: "rt")
        XCTAssertEqual(body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(body["refresh_token"] as? String, "rt")
        let scopes = Set((body["scope"] as? String ?? "").split(separator: " ").map(String.init))
        XCTAssertEqual(scopes, Set(ClaudeOAuth.Constants.fullScopes))
    }

    // MARK: - Credential predicates

    private func credential(scopes: [String] = ClaudeOAuth.Constants.fullScopes,
                            expiresIn: TimeInterval? = 28_800,
                            refresh: String? = "rt") -> ClaudeOAuth.Credential {
        ClaudeOAuth.Credential(
            accessToken: "at",
            refreshToken: refresh,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            scopes: scopes
        )
    }

    func testFullScopeDetection() {
        XCTAssertTrue(credential().hasFullScopes)
        XCTAssertTrue(credential().hasProfileScope)
        // What a setup-token-style grant looks like.
        let inferenceOnly = credential(scopes: ["user:inference"])
        XCTAssertFalse(inferenceOnly.hasFullScopes)
        XCTAssertFalse(inferenceOnly.hasProfileScope)
    }

    /// A grant that keeps profile but drops another scope is still incomplete —
    /// `hasFullScopes` must not be satisfied by profile alone.
    func testPartialScopeIsNotFullScope() {
        let partial = credential(scopes: ["user:profile", "user:inference"])
        XCTAssertTrue(partial.hasProfileScope)
        XCTAssertFalse(partial.hasFullScopes)
    }

    func testFreshnessMargin() {
        XCTAssertTrue(credential(expiresIn: 28_800).isFresh())
        // Inside the refresh margin: about to die, so treat as stale.
        XCTAssertFalse(credential(expiresIn: 60).isFresh())
        XCTAssertFalse(credential(expiresIn: -1).isFresh())
        // No stated expiry → usable; a 401 is what discovers otherwise.
        XCTAssertTrue(credential(expiresIn: nil).isFresh())
    }

    func testLongLivedDetection() {
        XCTAssertFalse(credential(expiresIn: 28_800).isLongLived, "8h is the refreshing kind")
        XCTAssertTrue(credential(expiresIn: 31_536_000).isLongLived, "a year is not")
        XCTAssertFalse(credential(expiresIn: nil).isLongLived)
    }

    func testCanRefresh() {
        XCTAssertTrue(credential().canRefresh)
        XCTAssertFalse(credential(refresh: nil).canRefresh)
        XCTAssertFalse(credential(refresh: "").canRefresh)
    }

    func testCredentialRoundTripsThroughJSON() {
        // The bundle is persisted as JSON in the keychain, so Codable fidelity is
        // what keeps a stored credential usable across launches.
        let original = credential()
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(ClaudeOAuth.Credential.self, from: data)
        XCTAssertEqual(decoded.accessToken, original.accessToken)
        XCTAssertEqual(decoded.refreshToken, original.refreshToken)
        XCTAssertEqual(decoded.scopes, original.scopes)
        XCTAssertTrue(decoded.hasFullScopes)
    }
}
