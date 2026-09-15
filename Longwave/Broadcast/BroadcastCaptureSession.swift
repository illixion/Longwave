import Foundation
import AVFoundation

// Camera capture for the broadcast pipeline is `RAVEPersonaCamera` from
// RAVESDK's `RAVECamera` — the class that used to live here, lifted out once
// Raven needed the same raw AVCapture frame (WebKit's `getUserMedia` reframes
// the sensor and never offers the native 1920×1080). What stays app-side is
// the microphone: visionOS has no `AVCaptureAudioDataOutput`, so the mic is
// tapped from `AVAudioEngine`, and the audio-session choices below are
// Longwave's own.

/// Mic capture via an AVAudioEngine input tap (visionOS has no
/// `AVCaptureAudioDataOutput`). Emits PCM buffers on the engine's render
/// thread. Uses a mixable play-and-record session so it can coexist with
/// the audio-stream receiver, though running both at once is untested.
final class BroadcastMicCapture: @unchecked Sendable {

    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private nonisolated(unsafe) var engine: AVAudioEngine?

    nonisolated func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try audioSession.setActive(true)
        // .playAndRecord's own default spatial experience is head-tracked
        // (built for calls), which silently re-spatializes whatever else is
        // playing through this process's one shared session — notably the
        // native audio streamer, whose bypass/on-off choice this category
        // switch just stomped. Broadcasting a mic has no reason to want
        // that; AudioStreamManager reclaims its own preference right after
        // via the resulting category-change notification, but default to
        // the non-surprising state ourselves too.
        try? audioSession.setIntendedSpatialExperience(.bypassed)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        AppLog.broadcast.line("🎙️ Mic capture started: \(format.sampleRate) Hz \(format.channelCount)ch")
    }

    nonisolated func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
