import StreamWire
import XCTest

final class PCVRControlTests: XCTestCase {
    func testDisplayRateGolden() throws {
        let rate = PCVRDisplayRate(refreshMillihertz: 90_000, supportedMillihertz: [90_000, 96_000, 100_000])
        let bytes = hex("905f0100", "03", "905f0100", "00770100", "a0860100")
        XCTAssertEqual(try rate.encoded(), bytes)
        XCTAssertEqual(try PCVRDisplayRate(decoding: bytes), rate)
    }

    func testDisplayRateFromHertzRoundsAndSorts() {
        let rate = PCVRDisplayRate(hertz: 89.9999, supported: [100, 90])
        XCTAssertEqual(rate.refreshMillihertz, 90_000)
        XCTAssertEqual(rate.supportedMillihertz, [90_000, 100_000])
        XCTAssertEqual(PCVRDisplayRate(hertz: .nan).refreshMillihertz, 0)
    }

    func testDisplayRateRejectsTooManyRates() {
        var bytes = hex("905f0100")
        bytes.append(UInt8(PCVRDisplayRate.maxSupported + 1))
        bytes += [UInt8](repeating: 0, count: 4 * (PCVRDisplayRate.maxSupported + 1))
        XCTAssertThrowsError(try PCVRDisplayRate(decoding: bytes))
    }

    func testPreferencesGolden() throws {
        let prefs = PCVRPreferences(renderEye: PixelSize(width: 4400, height: 3536),
                                    maxStreamMillihertz: 60_000, minStreamMillihertz: 45_000)
        let bytes = hex("3011", "d00d", "60ea0000", "c8af0000")
        XCTAssertEqual(try prefs.encoded(), bytes)
        XCTAssertEqual(try PCVRPreferences(decoding: bytes), prefs)
        XCTAssertTrue(prefs.asksForRenderEye)
    }

    func testPreferencesCanLeaveTheSizeToThePC() throws {
        let prefs = PCVRPreferences(renderEye: PixelSize(width: 0, height: 0), maxStreamMillihertz: 0, minStreamMillihertz: 0)
        XCTAssertFalse(try PCVRPreferences(decoding: try prefs.encoded()).asksForRenderEye)
    }

    func testPreferencesRejectBadValues() {
        XCTAssertThrowsError(try PCVRPreferences(renderEye: PixelSize(width: 100, height: 100),
                                                 maxStreamMillihertz: 0, minStreamMillihertz: 0).encoded())
        XCTAssertThrowsError(try PCVRPreferences(renderEye: PixelSize(width: 4400, height: 0),
                                                 maxStreamMillihertz: 0, minStreamMillihertz: 0).encoded())
        XCTAssertThrowsError(try PCVRPreferences(renderEye: PixelSize(width: 0, height: 0),
                                                 maxStreamMillihertz: 45_000, minStreamMillihertz: 60_000).encoded())
        XCTAssertThrowsError(try PCVRPreferences(decoding: hex("6500", "6500", "00000000", "00000000")))
    }

    func testSessionStateGolden() throws {
        let state = PCVRSessionState(renderEye: PixelSize(width: 4400, height: 3536), streamMillihertz: 90_000,
                                     producer: .title, flags: [.rateLimitedByHost])
        let bytes = hex("3011", "d00d", "905f0100", "02", "01")
        XCTAssertEqual(try state.encoded(), bytes)
        XCTAssertEqual(try PCVRSessionState(decoding: bytes), state)
    }

    func testInputBridgeSideDataRoundTripsOpaque() throws {
        let blob = (0..<226).map { UInt8(truncatingIfNeeded: $0) }
        let side = SideData(inputBridge: blob)
        var writer = WireWriter()
        try side.encodeItems(to: &writer)
        XCTAssertEqual(writer.bytes.count, side.encodedItemsLength)
        XCTAssertEqual(Array(writer.bytes.prefix(3)), hex("04 e200"))
        var reader = WireReader(writer.bytes)
        let decoded = try SideData(items: &reader)
        XCTAssertEqual(decoded.inputBridge, blob)
        XCTAssertTrue(decoded.presentTypes.contains(.inputBridge))
    }

    func testInputBridgeRejectsOversize() {
        XCTAssertThrowsError(try SideData(inputBridge: [UInt8](repeating: 1, count: SideData.maxInputBridge + 1)).validate())
        XCTAssertThrowsError(try SideData(inputBridge: []).validate())
    }
}
