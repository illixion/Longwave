import AVFoundation
import os
#if os(visionOS)
import AudioToolbox
#endif

/// Routes each engine independently. Session-wide spatial settings cannot
/// distinguish simultaneous desktop and audio windows.
nonisolated final class AudioWindowRouting: @unchecked Sendable {
    #if os(visionOS)
    private struct State {
        var sceneIdentifier: String?
        var spatialization: Bool?
        var applyExperience: (@Sendable (any SpatialAudioExperience) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func setSceneIdentifier(_ identifier: String?) {
        state.withLock { value in
            value.sceneIdentifier = identifier
            Self.apply(value)
        }
    }

    func setSpatialization(_ enabled: Bool?) {
        state.withLock { value in
            value.spatialization = enabled
            Self.apply(value)
        }
    }

    func bind(_ output: AVAudioOutputNode) {
        bind { [weak output] experience in
            output?.intendedSpatialExperience = experience
        }
    }

    /// Replaces the output sink on engine rebuild, applying the latest policy.
    func bind(_ applyExperience: @escaping @Sendable (any SpatialAudioExperience) -> Void) {
        state.withLock { value in
            value.applyExperience = applyExperience
            Self.apply(value)
        }
    }

    private static func apply(_ value: State) {
        guard let apply = value.applyExperience else { return }
        if value.spatialization == false {
            apply(BypassedSpatialAudio.bypassed)
        } else if let identifier = value.sceneIdentifier {
            apply(HeadTrackedSpatialAudio.headTracked(.scene(identifier: identifier), soundStageSize: .automatic))
        } else if value.spatialization == true {
            apply(HeadTrackedSpatialAudio.headTracked(.automatic, soundStageSize: .automatic))
        } else {
            apply(AutomaticSpatialAudio.automatic)
        }
    }
    #else
    func setSceneIdentifier(_ identifier: String?) {}
    func setSpatialization(_ enabled: Bool?) {}
    func bind(_ output: AVAudioOutputNode) {}
    #endif
}
