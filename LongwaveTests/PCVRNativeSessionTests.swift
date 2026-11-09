import StreamWire
import XCTest
@testable import Longwave

#if FOVEATED_ENABLED
final class PCVRNativeSessionTests: XCTestCase {
    func testDisplayRateSnapsPoseRatesToHeadsetRates() {
        XCTAssertEqual(PCVRDisplayRateEstimator.display(forPosesPerSecond: 89.6), 90)
        XCTAssertEqual(PCVRDisplayRateEstimator.display(forPosesPerSecond: 95.2), 96)
        XCTAssertEqual(PCVRDisplayRateEstimator.display(forPosesPerSecond: 119.99), 120)
        XCTAssertNil(PCVRDisplayRateEstimator.display(forPosesPerSecond: 80))
        XCTAssertNil(PCVRDisplayRateEstimator.display(forPosesPerSecond: 0))
    }

    @MainActor
    func testPresetsPersistAndFormPreferences() {
        let defaults = UserDefaults.standard
        let quality = defaults.object(forKey: PCVRNativeSession.qualityKey)
        let frameRate = defaults.object(forKey: PCVRNativeSession.frameRateKey)
        defer {
            defaults.set(quality, forKey: PCVRNativeSession.qualityKey)
            defaults.set(frameRate, forKey: PCVRNativeSession.frameRateKey)
        }
        let session = PCVRNativeSession()
        session.quality = .balanced
        session.frameRate = .halfDisplay
        XCTAssertEqual(session.preferences.renderEye, PCVRPlatformProfile.renderEye(scale: 0.85))
        XCTAssertEqual(session.preferences.minStreamMillihertz, 45_000)
        let reloaded = PCVRNativeSession()
        XCTAssertEqual(reloaded.quality, .balanced)
        XCTAssertEqual(reloaded.frameRate, .halfDisplay)
        XCTAssertFalse(reloaded.isActive)
    }

    func testPlatformPresetsAreEvenAndFloored() {
        XCTAssertEqual(PCVRPlatformProfile.renderEye(scale: 1), PixelSize(width: 5184, height: 4160))
        let balanced = PCVRPlatformProfile.renderEye(scale: 0.85)
        XCTAssertEqual(Int(balanced.width) % 16, 0)
        XCTAssertEqual(Int(balanced.height) % 16, 0)
        XCTAssertEqual(PCVRFrameRatePreset.halfDisplay.capMillihertz(displayHertz: 120), 60_000)
        XCTAssertEqual(PCVRFrameRatePreset.halfDisplay.capMillihertz(displayHertz: 96), 48_000)
        XCTAssertEqual(PCVRFrameRatePreset.halfDisplay.capMillihertz(displayHertz: 72), 45_000)
        XCTAssertEqual(PCVRFrameRatePreset.halfDisplay.capMillihertz(displayHertz: nil), 0)
        XCTAssertEqual(PCVRFrameRatePreset.matchDisplay.capMillihertz(displayHertz: 120), 0)
    }

    func testWithoutAPluginTheShellPresents() {
        XCTAssertNil(NSClassFromString(PCVRNativePresenters.presenterPluginClassName))
    }
}
#endif
