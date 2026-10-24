import StreamWire
import XCTest

final class HelloTests: XCTestCase {
    static let hello = ClientHello(capabilities: CapabilitySet([.h264, .nack, .audioOpus, .gamepad]), platform: .visionOS,
                                   maxUDPPayload: 1_452, intent: [.screen, .audio],
                                   deviceName: "Vision Pro", software: "Longwave 1.4")

    // Worked by hand: minor 0; capabilities h264 (5), nack (8), audioOpus (9),
    // gamepad (13) as 2 bytes 0x20 0x23; visionOS 1; 1452 = 0x05AC little-endian;
    // intent screen|audio = 3; then the two items.
    static let helloBytes = hex("""
        00 02 2023 01 ac05 03
        01 0a00 566973696f6e2050726f
        02 0c00 4c6f6e67776176652031 2e34
        """)

    static let ack = HostHelloAck(answering: hello, hostCapabilities: CapabilitySet([.h264, .nack, .gamepad, .hevc422]),
                                  platform: .macOS, keyCodeSpace: .macVirtual, grants: [.screen, .audio, .input],
                                  maxUDPPayload: 1_472, hostName: "studio")

    // Negotiated: h264, nack, gamepad (0x20 0x21); macOS 3; macVirtual 0;
    // grants 7; 1452 (the client's, the smaller); hostName.
    static let ackBytes = hex("""
        00 02 2021 03 00 0700 ac05
        01 0600 73747564696f
        """)

    func testHelloGoldenBytes() throws {
        XCTAssertEqual(hexString(try Self.hello.encoded()), hexString(Self.helloBytes))
        XCTAssertEqual(try ClientHello(decoding: Self.helloBytes), Self.hello)
    }

    func testAckGoldenBytesAndNegotiation() throws {
        XCTAssertEqual(Self.ack.capabilities, CapabilitySet([.h264, .nack, .gamepad]))
        XCTAssertEqual(Self.ack.maxUDPPayload, 1_452)
        XCTAssertFalse(Self.ack.refused)
        XCTAssertEqual(hexString(try Self.ack.encoded()), hexString(Self.ackBytes))
        XCTAssertEqual(try HostHelloAck(decoding: Self.ackBytes), Self.ack)
    }

    func testMinimalHelloIsSixBytes() throws {
        let bare = ClientHello(capabilities: CapabilitySet(), platform: .iOS)
        XCTAssertEqual(hexString(try bare.encoded()), "000002b00403")
        XCTAssertEqual(try ClientHello(decoding: try bare.encoded()), bare)
    }

    func testLaterRevisionsDecode() throws {
        // An unknown item, an unknown platform, intent bit and grant bit, and a
        // higher minor all decode; the unknown item is dropped, the bits kept.
        var bytes = Self.helloBytes
        bytes[0] = 1
        bytes[4] = 0x2A
        bytes[7] |= 0x80
        bytes += hex("09 0300 aabbcc")
        let hello = try ClientHello(decoding: bytes)
        XCTAssertEqual(hello.minor, 1)
        XCTAssertEqual(hello.platform.description, "platform(42)")
        XCTAssertTrue(hello.intent.contains(.screen))
        XCTAssertEqual(hello.intent.rawValue & 0x80, 0x80)
        XCTAssertEqual(hello.deviceName, "Vision Pro")

        var ack = Self.ackBytes
        ack[6] |= 0x40
        let decoded = try HostHelloAck(decoding: ack + hex("07 0000"))
        XCTAssertEqual(decoded.grants.rawValue, 0x47)
    }

    func testMalformedPayloadsAreRejected() {
        func rejects(_ bytes: [UInt8], _ label: String, line: UInt = #line) {
            XCTAssertThrowsError(try ClientHello(decoding: bytes), label, line: line)
        }
        let core = hex("00 02 2023 01 ac05 03")
        rejects(core + hex("01 0200 c328"), "invalid UTF-8")
        rejects(core + hex("01 0000"), "empty name")
        rejects(core + [0x01, 65, 0] + [UInt8](repeating: 0x61, count: 65), "65-byte name")
        rejects(core + hex("01 0100 61 01 0100 62"), "name twice")
        rejects(core + hex("01 0500 6162"), "item runs past the end")
        rejects(hex("00 02 2023 01 af04 03"), "datagram under 1200")
        rejects(hex("00 02 2023 01"), "truncated core")
        XCTAssertThrowsError(try HostHelloAck(decoding: hex("00 00 03 02 0700 ac05")), "unknown key code space")
        XCTAssertThrowsError(try ClientHello(capabilities: CapabilitySet(), platform: .iOS, deviceName: "").encoded())
        XCTAssertThrowsError(try ClientHello(capabilities: CapabilitySet(), platform: .iOS, maxUDPPayload: 70_000).encoded())
    }

    func testClientIgnoresCapabilitiesItNeverOffered() {
        var ack = Self.ack
        ack.capabilities.insert(.pcvr)
        ack.capabilities.insert(.sideData)
        XCTAssertEqual(Self.hello.sessionCapabilities(from: ack), CapabilitySet([.h264, .nack, .gamepad]))
    }

    func testRefusalIsAnAckWithNoGrants() {
        let refusal = HostHelloAck(answering: Self.hello, hostCapabilities: .known, platform: .windows,
                                   keyCodeSpace: .hidUsage, grants: [], maxUDPPayload: 1_200)
        XCTAssertTrue(refusal.refused)
        XCTAssertEqual(refusal.maxUDPPayload, 1_200)
    }
}
