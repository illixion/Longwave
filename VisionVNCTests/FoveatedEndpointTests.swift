import XCTest
@testable import VisionVNC

/// Pure-logic coverage for the foveated (PCVR) connection layer. The endpoint
/// validation and mode/immersion enums are deliberately free of the
/// FOVEATED_ENABLED flag and the device-only framework, so they run in the
/// default test configuration. The wire-format encoder check is gated because
/// the controller-bridge types only exist when the feature is compiled in.
final class FoveatedEndpointTests: XCTestCase {

    // MARK: IPv4 validation

    func testValidIPv4() {
        XCTAssertTrue(FoveatedEndpoint.isValidIPv4("192.168.1.10"))
        XCTAssertTrue(FoveatedEndpoint.isValidIPv4("10.0.0.1"))
        XCTAssertTrue(FoveatedEndpoint.isValidIPv4(" 127.0.0.1 "))  // trimmed
    }

    func testInvalidIPv4() {
        // Network.IPv4Address rejects empty, out-of-range octets, and
        // non-numeric/over-length forms. (Note: it does accept inet_aton-style
        // 3-part shorthand like "192.168.1" → 192.168.0.1, so that is *valid*.)
        XCTAssertFalse(FoveatedEndpoint.isValidIPv4(""))
        XCTAssertFalse(FoveatedEndpoint.isValidIPv4("999.1.1.1"))
        XCTAssertFalse(FoveatedEndpoint.isValidIPv4("256.256.256.256"))
        XCTAssertFalse(FoveatedEndpoint.isValidIPv4("1.2.3.4.5"))
        XCTAssertFalse(FoveatedEndpoint.isValidIPv4("host.local"))
    }

    // MARK: Port validation

    func testPortRange() {
        XCTAssertTrue(FoveatedEndpoint.isValidPort(55000))
        XCTAssertTrue(FoveatedEndpoint.isValidPort(1))
        XCTAssertTrue(FoveatedEndpoint.isValidPort(65535))
        XCTAssertFalse(FoveatedEndpoint.isValidPort(0))
        XCTAssertFalse(FoveatedEndpoint.isValidPort(65536))
        XCTAssertFalse(FoveatedEndpoint.isValidPort(-1))
    }

    // MARK: canConnect by mode

    func testSystemDiscoveredAlwaysConnectable() {
        XCTAssertTrue(FoveatedEndpoint.canConnect(mode: .systemDiscovered, host: "", port: 0))
    }

    func testLocalNeedsValidHostAndPort() {
        XCTAssertTrue(FoveatedEndpoint.canConnect(mode: .local, host: "192.168.1.50", port: 55000))
        XCTAssertFalse(FoveatedEndpoint.canConnect(mode: .local, host: "not-an-ip", port: 55000))
        XCTAssertFalse(FoveatedEndpoint.canConnect(mode: .local, host: "192.168.1.50", port: 0))
    }

    // MARK: Enum round-trips / defaults

    func testConnectionModeRoundTrip() {
        for mode in FoveatedConnectionMode.allCases {
            XCTAssertEqual(FoveatedConnectionMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(FoveatedConnectionMode(rawValue: "bogus"))
    }

    /// The retired `.remote` mode named a server baked into Info.plist, which a
    /// shipping app can't usefully offer. A row that stored it must come back as
    /// Automatic rather than as a mode that no longer exists.
    func testRetiredRemoteModeFallsBackToAutomatic() {
        XCTAssertNil(FoveatedConnectionMode(rawValue: "remote"))
        let connection = SavedConnection(hostname: "", port: 55000, connectionType: .vnc)
        connection.foveatedConnectionModeStorage = "remote"
        XCTAssertEqual(connection.foveatedConnectionMode, .systemDiscovered)
    }

    func testImmersionStyleRoundTrip() {
        for style in FoveatedImmersionStyle.allCases {
            XCTAssertEqual(FoveatedImmersionStyle(rawValue: style.rawValue), style)
        }
        XCTAssertNil(FoveatedImmersionStyle(rawValue: "bogus"))
    }

    // MARK: Controller-bridge wire format (gated — types exist only with the flag)

    #if FOVEATED_ENABLED
    func testInputStateEncodesTo120Bytes() {
        var state = ControllerBridgeInputState()
        state.sequence = 7
        state.flags = [.leftHandTracked, .rightHandTracked, .gyroValid, .controllerPresent]
        state.left.position = SIMD3<Float>(1, 2, 3)
        state.right.gyro = SIMD3<Float>(0.1, 0.2, 0.3)
        state.buttons = [.a, .zr, .dpadUp]
        state.rightTrigger = 1.0
        let data = state.encoded()
        XCTAssertEqual(data.count, 120, "cb_input_state_t must serialize to exactly 120 bytes")
        XCTAssertEqual(data[0], ControllerBridgeProtocol.packetInputState)
        XCTAssertEqual(data[1], ControllerBridgeProtocol.version)
        XCTAssertEqual(data[2], 7)
    }

    func testHapticDecodeRoundTrip() {
        // Build a 14-byte little-endian haptic packet and decode it.
        var data = Data([ControllerBridgeProtocol.packetHaptic, 1])
        for v in [Float(0.25), Float(160), Float(0.8)] {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        let haptic = ControllerBridgeHaptic(data)
        XCTAssertNotNil(haptic)
        XCTAssertEqual(haptic?.controller, 1)
        XCTAssertEqual(haptic?.amplitude ?? 0, 0.8, accuracy: 0.0001)
    }
    #endif
}
