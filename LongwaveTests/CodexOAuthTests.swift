import XCTest
@testable import Longwave

/// The offline half of Codex's ChatGPT device sign-in: request bodies, response
/// parsing for every poll outcome, the credential's claims and freshness, and the
/// `auth.json` a session receives. No network — every wire call needs a real
/// ChatGPT account.
@MainActor
final class CodexOAuthTests: XCTestCase {

    /// An unsigned JWT carrying `claims` — enough for code that only reads them.
    static func jwt(_ claims: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "none"]))
        let payload = b64url(try! JSONSerialization.data(withJSONObject: claims))
        return "\(header).\(payload).sig"
    }

    static func credential(expiresIn: TimeInterval = 10 * 24 * 3600,
                           refresh: String? = "rt-secret") -> CodexOAuth.Credential {
        var c = CodexOAuth.Credential(
            accessToken: jwt(["exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970]),
            idToken: jwt([
                "email": "someone@example.com",
                "https://api.openai.com/auth": ["chatgpt_account_id": "acct-123", "chatgpt_plan_type": "pro"],
            ]),
            refreshToken: refresh)
        c.applyClaims()
        return c
    }

    // MARK: - Device code

    func testUserCodeBodyIsJustTheClientID() {
        XCTAssertEqual(CodexOAuth.userCodeBody() as? [String: String],
                       ["client_id": "app_EMoamEEZ73f0CkXaXp7hrann"])
    }

    func testParseDeviceCodeAcceptsStringIntervalAndBothCodeSpellings() {
        let a = CodexOAuth.parseDeviceCode(["device_auth_id": "d1", "user_code": "ABCD-1234", "interval": "7"])
        XCTAssertEqual(a, CodexOAuth.DeviceCode(deviceAuthID: "d1", userCode: "ABCD-1234", interval: 7))
        let b = CodexOAuth.parseDeviceCode(["device_auth_id": "d2", "usercode": "WXYZ", "interval": 3])
        XCTAssertEqual(b?.userCode, "WXYZ")
        XCTAssertEqual(b?.interval, 3)
        XCTAssertEqual(CodexOAuth.parseDeviceCode(["device_auth_id": "d3", "user_code": "Q"])?.interval, 5,
                       "missing interval falls back to 5 s")
        XCTAssertNil(CodexOAuth.parseDeviceCode(["user_code": "no-id"]))
        XCTAssertEqual(a?.verificationURL, "https://auth.openai.com/codex/device")
    }

    func testPollBodyAndOutcomes() {
        let code = CodexOAuth.DeviceCode(deviceAuthID: "d1", userCode: "ABCD", interval: 5)
        XCTAssertEqual(CodexOAuth.pollBody(code) as? [String: String],
                       ["device_auth_id": "d1", "user_code": "ABCD"])
        XCTAssertEqual(CodexOAuth.parsePoll(status: 403, json: nil), .pending)
        XCTAssertEqual(CodexOAuth.parsePoll(status: 404, json: ["error": "x"]), .pending)
        XCTAssertEqual(CodexOAuth.parsePoll(status: 200, json: [
            "authorization_code": "ac", "code_challenge": "ch", "code_verifier": "cv",
        ]), .approved(code: "ac", verifier: "cv"))
        XCTAssertEqual(CodexOAuth.parsePoll(status: 200, json: ["authorization_code": "ac"]), .failed(200),
                       "a success without the verifier can't be exchanged")
        XCTAssertEqual(CodexOAuth.parsePoll(status: 500, json: nil), .failed(500))
    }

    // MARK: - Token grants

    func testAuthorizationCodeExchangeIsFormEncodedWithDeviceRedirect() {
        let body = CodexOAuth.authorizationCodeBody(code: "a+b/c", verifier: "v&w")
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["redirect_uri"], "https://auth.openai.com/deviceauth/callback")
        XCTAssertEqual(body["client_id"], CodexOAuth.Constants.clientID)
        let form = CodexOAuth.formEncoded(body)
        XCTAssertTrue(form.contains("code=a%2Bb%2Fc"), "a literal + would decode as a space")
        XCTAssertTrue(form.contains("code_verifier=v%26w"))
    }

    func testRefreshBodyCarriesOnlyTheGrant() {
        let body = CodexOAuth.refreshBody(refreshToken: "rt")
        XCTAssertEqual(body as? [String: String], [
            "grant_type": "refresh_token",
            "client_id": CodexOAuth.Constants.clientID,
            "refresh_token": "rt",
        ])
    }

    // MARK: - Credential

    func testClaimsFillAccountPlanEmailAndExpiry() {
        let c = Self.credential()
        XCTAssertEqual(c.accountID, "acct-123")
        XCTAssertEqual(c.planType, "pro")
        XCTAssertEqual(c.email, "someone@example.com")
        let expiresAt = try? XCTUnwrap(c.expiresAt)
        XCTAssertEqual(expiresAt?.timeIntervalSinceNow ?? 0, 10 * 24 * 3600, accuracy: 5)
    }

    func testFreshnessKeepsADayOfHeadroom() {
        XCTAssertTrue(Self.credential(expiresIn: 3 * 24 * 3600).isFresh())
        XCTAssertFalse(Self.credential(expiresIn: 12 * 3600).isFresh(),
                       "half a day left is renewed at launch, not handed to a session")
        XCTAssertTrue(Self.credential(refresh: "rt").canRefresh)
        XCTAssertFalse(Self.credential(refresh: nil).canRefresh)
    }

    func testCredentialRoundTripsThroughJSON() throws {
        let c = Self.credential()
        let decoded = try JSONDecoder().decode(CodexOAuth.Credential.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded, c)
    }

    /// The refresh token must never leave the device: it rotates on use, so a
    /// host-side copy would sign this device out on its first refresh.
    func testSessionEnvironmentNeverCarriesTheRefreshToken() throws {
        let c = Self.credential(refresh: "rt-secret")
        let env = c.sessionEnvironment()
        XCTAssertEqual(env.map(\.name), [CodexOAuth.Constants.authJSONEnvName])
        for (_, value) in env { XCTAssertFalse(value.contains("rt-secret")) }

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(env[0].value.utf8)) as? [String: Any])
        XCTAssertEqual(json["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(json["OPENAI_API_KEY"] is NSNull)
        XCTAssertNotNil(json["last_refresh"] as? String)
        let tokens = try XCTUnwrap(json["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, c.accessToken)
        XCTAssertEqual(tokens["id_token"] as? String, c.idToken)
        XCTAssertEqual(tokens["refresh_token"] as? String, "", "required by the CLI's TokenData, but empty")
        XCTAssertEqual(tokens["account_id"] as? String, "acct-123")
    }

    // MARK: - Session setup

    func testSessionSetupOnlyForACredentialAndConsumesTheJSON() throws {
        XCTAssertNil(CodexOAuth.sessionSetup(for: [(name: "CODEX_ACCESS_TOKEN", value: "at-x")]),
                     "a pasted PAT is read straight from the environment")
        let setup = try XCTUnwrap(CodexOAuth.sessionSetup(for: Self.credential().sessionEnvironment()))
        XCTAssertEqual(setup.consumedNames, [CodexOAuth.Constants.authJSONEnvName])
        XCTAssertEqual(setup.exportedNames, ["CODEX_HOME"])
        XCTAssertTrue(setup.script.contains("unset \(CodexOAuth.Constants.authJSONEnvName)"))
        XCTAssertTrue(setup.script.contains(".codex-longwave"))
        XCTAssertFalse(setup.script.contains("\"$HOME/.codex\"/auth"), "never touches the user's own login")
        XCTAssertTrue(setup.script.contains("umask 077"))
    }

    func testJWTClaimsToleratesGarbage() {
        XCTAssertTrue(CodexOAuth.claims(ofJWT: "not-a-jwt").isEmpty)
        XCTAssertTrue(CodexOAuth.claims(ofJWT: "a.%%%.c").isEmpty)
        XCTAssertEqual(CodexOAuth.claims(ofJWT: Self.jwt(["k": "v"]))["k"] as? String, "v")
    }
}
