import XCTest
@testable import Longwave

/// The Apple Watch's HTTP lane: request authentication, response sealing,
/// and the viewport / still encodings both ends share.
final class WatchLinkProtocolTests: XCTestCase {
    typealias P = WatchLinkProtocol

    private let key = P.key(token: "test-token")
    private let target = "/v1/still?x=0.0000&y=0.0000&w=1.0000&h=1.0000&pw=396&ph=484&q=60&after=0"

    func testAuthorizationRoundTripsThroughItsHeader() throws {
        let authorization = P.authorize(method: "GET", target: target, key: key)
        let parsed = try XCTUnwrap(P.Authorization(headerValue: authorization.headerValue))
        XCTAssertEqual(parsed, authorization)
        XCTAssertTrue(P.verify(parsed, method: "GET", target: target, key: key))
    }

    func testVerifyRejectsAnotherTokenTargetOrMethod() {
        let authorization = P.authorize(method: "GET", target: target, key: key)
        XCTAssertFalse(P.verify(authorization, method: "GET", target: target, key: P.key(token: "other")))
        XCTAssertFalse(P.verify(authorization, method: "GET", target: target + "1", key: key))
        XCTAssertFalse(P.verify(authorization, method: "POST", target: target, key: key))
    }

    func testVerifyRejectsAStaleClock() {
        let then = Date(timeIntervalSince1970: 1_000_000)
        let authorization = P.authorize(method: "GET", target: target, key: key, now: then)
        XCTAssertTrue(P.verify(authorization, method: "GET", target: target, key: key, now: then.addingTimeInterval(29)))
        XCTAssertFalse(P.verify(authorization, method: "GET", target: target, key: key, now: then.addingTimeInterval(31)))
    }

    func testMalformedHeadersDoNotParse() {
        XCTAssertNil(P.Authorization(headerValue: "Bearer abc"))
        XCTAssertNil(P.Authorization(headerValue: "LW1 notanumber.nonce.mac"))
        XCTAssertNil(P.Authorization(headerValue: "LW1 123.nonce"))
    }

    func testSealedBodyOpensOnlyForItsOwnRequest() {
        let body = Data("picture".utf8)
        let sealed = try! XCTUnwrap(P.seal(body, nonce: "a", key: key))
        XCTAssertEqual(P.open(sealed, nonce: "a", key: key), body)
        XCTAssertNil(P.open(sealed, nonce: "b", key: key))
        XCTAssertNil(P.open(sealed, nonce: "a", key: P.key(token: "other")))
    }

    func testViewportRoundTripsThroughQueryItems() throws {
        let viewport = P.Viewport(x: 0.25, y: 0.5, width: 0.5, height: 0.25, pixelWidth: 410, pixelHeight: 502, quality: 70)
        let query = Dictionary(uniqueKeysWithValues: viewport.queryItems.map { ($0.name, $0.value!) })
        XCTAssertEqual(try XCTUnwrap(P.Viewport(query: query)), viewport)
    }

    func testViewportRejectsOutOfRangeValues() {
        var query = Dictionary(uniqueKeysWithValues: P.Viewport().queryItems.map { ($0.name, $0.value!) })
        query["pw"] = "5000"
        XCTAssertNil(P.Viewport(query: query))
        query["pw"] = "396"
        query["w"] = "0"
        XCTAssertNil(P.Viewport(query: query))
    }

    func testStillRoundTrips() throws {
        let still = P.Still(sequence: 0x0102_0304_0506_0708, sourceWidth: 3024, sourceHeight: 1964, jpeg: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(try XCTUnwrap(P.Still(decoding: still.encoded())), still)
    }

    func testFullViewportMapsToTheWholeStillRegion() {
        let still = P.Viewport().stillViewport
        XCTAssertEqual(still.x, 0)
        XCTAssertEqual(still.width, .max)
        XCTAssertEqual(still.height, .max)
    }
}
