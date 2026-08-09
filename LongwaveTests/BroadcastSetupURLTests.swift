import XCTest
@testable import Longwave

final class BroadcastSetupURLTests: XCTestCase {

    private let fingerprint = String(repeating: "ab", count: 32)   // 64 hex chars

    func testRoundTrip() {
        let setup = BroadcastSetup(host: "100.69.196.5", port: 8322,
                                   streamPath: "visionpro", viewStreamPath: "visionpro-view",
                                   username: "visionpro", password: "s3cret+/=",
                                   certFingerprintHex: fingerprint)
        guard let url = BroadcastSetupURL.make(setup) else { return XCTFail("make returned nil") }
        XCTAssertEqual(url.scheme, "longwave")
        let parsed = BroadcastSetupURL.parse(from: url)
        XCTAssertEqual(parsed, setup)
    }

    func testDefaultsWithoutOptionalFields() {
        let url = URL(string: "longwave://x-callback-url/setBroadcastServer?host=mac.local&pass=pw")!
        let parsed = BroadcastSetupURL.parse(from: url)
        XCTAssertEqual(parsed?.host, "mac.local")
        XCTAssertEqual(parsed?.port, 8554, "no fingerprint → plain RTSP default port")
        XCTAssertEqual(parsed?.streamPath, "visionpro")
        XCTAssertEqual(parsed?.viewStreamPath, "visionpro-view")
        XCTAssertNil(parsed?.certFingerprintHex)
    }

    func testFingerprintImpliesTLSPort() {
        let url = URL(string: "longwave://x-callback-url/setBroadcastServer?host=h&pass=p&fp=\(fingerprint)")!
        XCTAssertEqual(BroadcastSetupURL.parse(from: url)?.port, 8322)
    }

    func testMalformedFingerprintRejected() {
        let url = URL(string: "longwave://x-callback-url/setBroadcastServer?host=h&pass=p&fp=nothex")!
        let parsed = BroadcastSetupURL.parse(from: url)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.certFingerprintHex, "garbage fingerprint must not be pinned")
    }

    func testRejectsMissingHostOrPassword() {
        XCTAssertNil(BroadcastSetupURL.parse(from: URL(string: "longwave://x-callback-url/setBroadcastServer?pass=p")!))
        XCTAssertNil(BroadcastSetupURL.parse(from: URL(string: "longwave://x-callback-url/setBroadcastServer?host=h")!))
    }

    func testRejectsOtherActions() {
        XCTAssertNil(BroadcastSetupURL.parse(from: URL(string: "longwave://x-callback-url/setAudioToken?token=t")!))
    }

    func testHexDecoding() {
        XCTAssertEqual(BroadcastShared.dataFromHex("00ff10"), Data([0x00, 0xFF, 0x10]))
        XCTAssertNil(BroadcastShared.dataFromHex("0g"))
        XCTAssertNil(BroadcastShared.dataFromHex("abc"))
        XCTAssertNil(BroadcastShared.dataFromHex(""))
    }
}
