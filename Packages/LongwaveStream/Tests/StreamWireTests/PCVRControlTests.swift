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

    func testPreferencesGoldenAndPresets() throws {
        let prefs = PCVRPreferences(quality: .balanced, frameRate: .cap90)
        let bytes = hex("5203", "905f0100", "02", "03")
        XCTAssertEqual(try prefs.encoded(), bytes)
        let decoded = try PCVRPreferences(decoding: bytes)
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(decoded.quality, .balanced)
        XCTAssertEqual(decoded.frameRate, .cap90)
        XCTAssertEqual(decoded.renderScale, 0.85, accuracy: 1e-9)
        XCTAssertEqual(PCVRPreferences.default.maxStreamMillihertz, 0)
    }

    func testPreferencesRejectAbsurdScale() {
        XCTAssertThrowsError(try PCVRPreferences(renderScalePermille: 50, maxStreamMillihertz: 0).encoded())
        XCTAssertThrowsError(try PCVRPreferences(decoding: hex("0a00", "00000000", "00", "00")))
    }

    func testSessionStateGolden() throws {
        let state = PCVRSessionState(renderEye: PixelSize(width: 4400, height: 3536), streamMillihertz: 90_000,
                                     producer: .title, flags: [.rateLimitedByHost])
        let bytes = hex("3011", "d00d", "905f0100", "02", "01")
        XCTAssertEqual(try state.encoded(), bytes)
        XCTAssertEqual(try PCVRSessionState(decoding: bytes), state)
    }

    func testRenderEyeAtNativeDensityMatchesTheVisionProSize() {
        // The receiver's left eye frustum, radians (2% overscan included in the density).
        let fov = (left: Float(-0.9512), right: Float(0.9512), up: Float(0.8727), down: Float(-0.8727))
        let eye = PCVRProfile.renderEye(fov: fov, scale: 1, nativePixelsPerTangent: PCVRProfile.visionProPixelsPerTangent)
        XCTAssertEqual(Double(eye.width), 5184, accuracy: 120)
        XCTAssertEqual(Double(eye.height), 4460, accuracy: 400)
        XCTAssertEqual(Int(eye.width) % PCVRProfile.wireAlignment, 0)
        let lower = PCVRProfile.renderEye(fov: fov, scale: 0.7, nativePixelsPerTangent: PCVRProfile.visionProPixelsPerTangent)
        XCTAssertLessThan(lower.width, eye.width)
        XCTAssertEqual(Int(lower.height) % PCVRProfile.wireAlignment, 0)
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
