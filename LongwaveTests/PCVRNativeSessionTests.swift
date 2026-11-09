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
        session.frameRate = .cap90
        XCTAssertEqual(session.preferences, PCVRPreferences(quality: .balanced, frameRate: .cap90))
        let reloaded = PCVRNativeSession()
        XCTAssertEqual(reloaded.quality, .balanced)
        XCTAssertEqual(reloaded.frameRate, .cap90)
        XCTAssertFalse(reloaded.isActive)
    }

    func testWithoutAPluginTheShellPresents() {
        XCTAssertNil(NSClassFromString(PCVRNativePresenters.presenterPluginClassName))
    }
}
#endif
