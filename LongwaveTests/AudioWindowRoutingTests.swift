import XCTest
import AVFoundation
import AudioToolbox
import os
@testable import Longwave

@MainActor
final class AudioWindowRoutingTests: XCTestCase {
    private final class Output: @unchecked Sendable {
        let experience = OSAllocatedUnfairLock<(any SpatialAudioExperience)?>(initialState: nil)
        nonisolated func receive(_ value: any SpatialAudioExperience) { experience.withLock { $0 = value } }
        var current: (any SpatialAudioExperience)? { experience.withLock { $0 } }
    }

    func testConcurrentOutputsKeepIndependentWindowsAndSpatialModes() {
        let first = AudioWindowRouting()
        let second = AudioWindowRouting()
        let firstEngine = Output()
        let secondEngine = Output()
        first.setSceneIdentifier("desktop")
        second.setSceneIdentifier("audio")
        first.bind(firstEngine.receive)
        second.bind(secondEngine.receive)
        XCTAssertEqual((firstEngine.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "desktop"))
        XCTAssertEqual((secondEngine.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "audio"))
        first.setSpatialization(false)
        XCTAssertTrue(firstEngine.current is BypassedSpatialAudio)
        XCTAssertEqual((secondEngine.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "audio"))
        first.setSpatialization(nil)
        XCTAssertEqual((firstEngine.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "desktop"))
    }

    func testLateSceneAndEngineRebuildKeepTheAnchor() {
        let routing = AudioWindowRouting()
        let original = Output()
        routing.bind(original.receive)
        routing.setSceneIdentifier("restored-window")
        XCTAssertEqual((original.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "restored-window"))
        let rebuilt = Output()
        routing.bind(rebuilt.receive)
        XCTAssertEqual((rebuilt.current as? HeadTrackedSpatialAudio)?.anchoringStrategy, .scene(identifier: "restored-window"))
    }

    func testPopOutOwnsAudioUntilItClosesAndTransientReappearRestoresScene() {
        let manager = AudioStreamManager(scope: "audio-routing-test")
        manager.setPresenterScene("desktop", presenter: "native-stream")
        manager.presenterAppeared("native-stream")
        XCTAssertEqual(manager.audioSceneIdentifier, "desktop")
        manager.setPresenterScene("pop-out", presenter: "audio-window")
        manager.presenterAppeared("audio-window")
        XCTAssertEqual(manager.audioSceneIdentifier, "pop-out")
        // A desktop view updating while the pop-out exists must not steal it.
        manager.setPresenterScene("desktop", presenter: "native-stream")
        XCTAssertEqual(manager.audioSceneIdentifier, "pop-out")
        manager.windowDisappeared(presenter: "audio-window")
        XCTAssertEqual(manager.audioSceneIdentifier, "desktop")
        manager.presenterAppeared("audio-window")
        XCTAssertEqual(manager.audioSceneIdentifier, "pop-out")
    }
}
