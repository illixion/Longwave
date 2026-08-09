import XCTest
@testable import Longwave

/// `LocalNetwork.inferWindowsHotspotHost(from:)` — the pure subnet check behind the
/// connection-form auto-prefill. Windows ICS pins its shared net to 192.168.137.0/24 with
/// the host at 192.168.137.1, so a device holding a 192.168.137.x lease infers that gateway.
final class LocalNetworkTests: XCTestCase {

    func testInfersGatewayFromIcsClientAddress() {
        XCTAssertEqual(LocalNetwork.inferWindowsHotspotHost(from: ["192.168.137.45"]),
                       "192.168.137.1")
    }

    func testMixedInterfacesStillDetectsIcs() {
        // Ethernet + hotspot lease simultaneously (e.g. the host's own view, or a multihomed client).
        XCTAssertEqual(LocalNetwork.inferWindowsHotspotHost(from: ["172.20.48.142", "192.168.137.207"]),
                       "192.168.137.1")
    }

    func testGatewayAddressItselfDoesNotInfer() {
        // 192.168.137.1 is the host/gateway, not a client lease — don't point a connection at "self".
        XCTAssertNil(LocalNetwork.inferWindowsHotspotHost(from: ["192.168.137.1"]))
    }

    func testNonIcsSubnetsReturnNil() {
        XCTAssertNil(LocalNetwork.inferWindowsHotspotHost(from: ["10.0.0.5", "192.168.1.10", "192.168.0.1"]))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(LocalNetwork.inferWindowsHotspotHost(from: []))
    }

    func testSimilarButDifferentSubnetIsIgnored() {
        // 192.168.13x prefixes that aren't exactly 192.168.137. must not match.
        XCTAssertNil(LocalNetwork.inferWindowsHotspotHost(from: ["192.168.13.7", "192.168.1.137"]))
    }
}
