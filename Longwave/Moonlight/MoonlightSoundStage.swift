#if MOONLIGHT_ENABLED
/*
 Moonlight surround as virtual speakers on a PHASE sound stage

 Why: a 5.1/7.1 stream played through `AVAudioEngine` is folded to stereo
 at the output node before the system's spatializer ever sees it (measured
 on visionOS 27 by Hypnos's spatial audio probe: the output node takes 12
 channels in and sends 2 out), so "Spatial Audio" on a surround stream used
 to mean a head-tracked stereo downmix. Here each channel is its own mono
 source on RAVESDK's `RAVEPhaseStage`, placed at its ITU speaker angle
 (`RAVESpeakerLayout`), with the LFE as a head-locked bed. The decoded
 stream reaches it through `RAVEChannelFeed`, which keeps the channels on
 one host-clock timeline (each PHASE stream runs on its own sample clock).

 Used only for surround with spatial audio on, and only on visionOS:
 - Stereo keeps the flat path. It isn't downmixed, and the system already
   head-tracks it.
 - iOS and macOS have PHASE (macOS 15+), but no spatial toggle in their
   stream UI, and the preference defaults on for surround connections, so
   enabling it there would silently turn a Mac's real 5.1 speakers into a
   binaural render nobody asked for. `MoonlightSoundStagePolicy.isSupported`
   is the one line to change once those clients grow the toggle.
 - Moonlight has no Music mode: its session is always the mixable
   `.playback` + `.mixWithOthers` one and never claims Now Playing, so
   nothing here needs the exclusive session PHASE might not honour.

 Engine: visionOS's `.client` rendering mode (the system audio server
 renders, with its own low-latency head tracking), binaural left to the
 system, reverb off (a game brings its own room). Not yet heard on a
 headset: LambdaVision found in-process PHASE deafening on visionOS 26, so
 the first test should start at low volume.

 Latency: the feed's 40 ms cushion matches the flat path's, and alignment
 adds nothing in steady state. What PHASE's I/O quantum and the client
 rendering hop add is unknown until measured on device (see the commit).

 Rebuilt from scratch on an interruption ending, a media-services reset or
 an output device change, as RAVEFilm's PHASE stage does: PHASE's engine
 does not survive those (tvOS, 2026-09-27).
 */

import AVFAudio
import DebugTrace
import Foundation
import RAVESpatialAudio

/// Which streams take the sound stage. Separate from the stage so it needs
/// no macOS 15 availability (the Mac client's floor is 14.2).
nonisolated enum MoonlightSoundStagePolicy {
    /// Whether this platform renders spatial surround through the stage.
    static var isSupported: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }

    /// Whether a stream of `channelCount` channels goes through the stage
    /// when spatial audio is on.
    static func wants(channelCount: Int) -> Bool {
        guard isSupported, #available(macOS 15.0, *) else { return false }
        return channelCount > 2 && RAVESpeakerLayout(channelCount: channelCount) != nil
    }
}

@available(macOS 15.0, *)
@MainActor
final class MoonlightSoundStage {
    /// Hands the live feed to the decode thread (nil = play flat).
    typealias Publish = @Sendable (RAVEChannelFeed?) -> Void

    private let layout: RAVESpeakerLayout
    private let sampleRate: Double
    private let publish: Publish
    private var stage: RAVEPhaseStage?
    private var feed: RAVEChannelFeed?
    private var observers: [NSObjectProtocol] = []

    init?(channelCount: Int, sampleRate: Double, publish: @escaping Publish) {
        guard MoonlightSoundStagePolicy.wants(channelCount: channelCount),
              let layout = RAVESpeakerLayout(channelCount: channelCount) else { return nil }
        self.layout = layout
        self.sampleRate = sampleRate
        self.publish = publish
    }

    var isRunning: Bool { stage != nil }

    /// Builds and starts the stage, then routes the stream to it. False if
    /// PHASE refused; the stream stays on the flat path.
    @discardableResult
    func start() -> Bool {
        observe()
        return build()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        teardown()
    }

    /// Makes the way the wearer faces now the front of the speaker ring.
    func recenter() {
        stage?.recenter()
    }

    private func build() -> Bool {
        // Defaults sized for a game: 40 ms cushion (the flat path's), 250 ms
        // ceiling, 50 ms re-anchor threshold (RAVEFilm's).
        let feed = RAVEChannelFeed(channelCount: layout.channelCount, sampleRate: sampleRate)
        let stage = RAVEPhaseStage(sampleRate: sampleRate, binaural: false, headTracking: true,
                                   reverbPreset: .none, reverbSend: 0, systemRendering: true)
        do {
            try stage.addSpeakers(layout, feed: feed)
            try stage.start()
        } catch {
            AppLog.moonlightAudio.error("Sound stage failed: \(error.localizedDescription, privacy: .public)")
            stage.stop()
            return false
        }
        self.stage = stage
        self.feed = feed
        publish(feed)
        AppLog.moonlightAudio.info("Sound stage up: \(self.layout.rawValue, privacy: .public) as virtual speakers")
        return true
    }

    private func teardown() {
        publish(nil)
        if let feed {
            // What to read off a device run: underruns and skips are the
            // cushion being too small or too big for the link; drift and
            // re-anchors are PHASE's per-stream clocks wandering.
            let state = feed.state
            AppLog.moonlightAudio.info("Sound stage down: \(state.underruns, privacy: .public) underruns, \(state.skips, privacy: .public) skips, \(feed.aligner.reanchors, privacy: .public) re-anchors, max drift \(feed.aligner.maxDrift, privacy: .public) frames, \(feed.fallbackRenders, privacy: .public) untimed renders")
        }
        stage?.stop()
        stage = nil
        feed = nil
    }

    private func rebuild(_ reason: String) {
        guard stage != nil else { return }
        AppLog.moonlightAudio.info("Rebuilding sound stage: \(reason, privacy: .public)")
        teardown()
        _ = build()
    }

    private func observe() {
        #if !os(macOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.rebuild("interruption ended")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Not on configuration or category changes: starting PHASE
                // can post those itself, which would rebuild in a loop.
                switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
                case .newDeviceAvailable, .oldDeviceUnavailable, .override:
                    self?.rebuild("route changed")
                default:
                    break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild("media services reset") }
        })
        #endif
    }
}
#endif
