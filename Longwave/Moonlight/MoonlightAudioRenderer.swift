#if MOONLIGHT_ENABLED
import DebugTrace
import Foundation
import os
import AVFoundation
import Opus
import RAVESpatialAudio
@preconcurrency import MoonlightCommonC

/// Decodes Opus audio packets from moonlight-common-c and plays them
/// through AVAudioEngine using an AVAudioPlayerNode — or, for surround with
/// spatial audio on (visionOS), as virtual speakers on a PHASE sound stage
/// (`MoonlightSoundStage`), because the engine path folds surround to stereo
/// before the system spatializer sees it.
class MoonlightAudioRenderer: @unchecked Sendable {

    private nonisolated(unsafe) var decoder: OpaquePointer?    // OpusMSDecoder*
    private nonisolated(unsafe) var channelCount: Int = 0
    private nonisolated(unsafe) var sampleRate: Int = 0
    private nonisolated(unsafe) var samplesPerFrame: Int = 0

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// Jitter cushion queued on the player node before it is told to play,
    /// and again after it runs dry. Starting playback on the first 5 ms Opus
    /// frame — what this used to do — meant any arrival jitter above 5 ms
    /// starved the node, and each starvation is a hard cut to silence and
    /// back: the run of pops at the start of every session, when the link is
    /// at its burstiest. 40 ms matches the native receiver's low-latency
    /// base (`AudioStreamManager`), which rides the same Wi-Fi.
    private nonisolated static let primeSeconds: Double = 0.040
    /// Past this much queued audio the stream is running long (a post-stall
    /// burst well beyond the cushion) and incoming frames are dropped until
    /// it's back in range — game audio must not drift behind the video.
    private nonisolated static let ceilingSeconds: Double = 0.250

    /// Sample frames scheduled on the player node but not yet played back,
    /// with a generation stamp so completion callbacks from buffers flushed
    /// by `stop()` can't decrement the next run's depth. `AVAudioPlayerNode`
    /// has no depth query, and a starved node doesn't stop — it renders
    /// silence and keeps its clock running — so this counter is the only way
    /// to see an underrun. Written from the render thread, hence the lock.
    private struct QueueState: Sendable {
        var frames = 0
        var generation = 0
    }
    private let queueState = OSAllocatedUnfairLock(initialState: QueueState())

    /// True once the cushion filled and the node was told to play. Owned by
    /// moonlight-common-c's audio thread; `start` resets it before that
    /// thread exists.
    private nonisolated(unsafe) var playing = false

    /// Serializes the player's play/pause against `stop()`, and `active` is
    /// what it guards. moonlight-common-c calls `stop()` *before* joining its
    /// audio threads, so a frame in flight can finish priming after the
    /// engine has stopped — and `play()` on a node whose engine isn't running
    /// raises an Objective-C exception rather than failing quietly.
    private let lifecycleLock = NSLock()
    private nonisolated(unsafe) var active = false

    /// When true, audio is decoded but not played (no audio mode).
    nonisolated(unsafe) var muted: Bool = false

    /// Where decoded frames go while the sound stage is up: the stage's
    /// `RAVEChannelFeed`, set and cleared by the main actor, read by the
    /// decode thread per packet. Typed as an existential so the property
    /// needs no macOS 15 availability (the Mac client floor is 14.2).
    ///
    /// Not a closure over `feed.push`: a `@Sendable` closure built through
    /// `Optional.map` and stored here was reabstracted into a thunk that
    /// called itself, overflowing the decode thread's stack on the first
    /// packet (SIGBUS, 2026-10-04).
    private let stageFeed = OSAllocatedUnfairLock<(any AnyObject & Sendable)?>(initialState: nil)
    /// Whether the last packet went to the stage. Decode-thread owned, like
    /// `playing`: the hand-over between paths happens on that thread.
    private nonisolated(unsafe) var routedToStage = false
    /// Whether the sound stage should be up. Requests only set it; the main
    /// actor reconciles to the latest value, so a burst of toggles can't
    /// leave a stale build or teardown behind.
    private let wantsStage = OSAllocatedUnfairLock(initialState: false)
    /// The `MoonlightSoundStage` while one is up (typed `AnyObject` for the
    /// same availability reason as `stageFeed`). Main actor.
    private var soundStage: AnyObject?
    /// Told when the sound stage comes up or goes down (main actor), so the
    /// stream UI can offer Recenter.
    var onSoundStageChange: ((Bool) -> Void)?

    /// Whether decoded game audio is spatialized (head-tracked) at the
    /// session level, or bypassed (flat passthrough of the stream's own
    /// stereo/surround mix — the default). Set before `setup` runs and
    /// flippable live afterward via `setSpatialAudioEnabled`.
    nonisolated(unsafe) var spatialAudioEnabled: Bool = false

    nonisolated init() {}

    nonisolated func setup(audioConfig: Int32, opusConfig: UnsafeMutablePointer<OPUS_MULTISTREAM_CONFIGURATION>) -> Int32 {
        let config = opusConfig.pointee
        channelCount = Int(config.channelCount)
        sampleRate = Int(config.sampleRate)
        samplesPerFrame = Int(config.samplesPerFrame)

        // Create Opus multistream decoder
        var error: Int32 = 0
        let mapping = withUnsafePointer(to: config.mapping) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: channelCount) { mappingPtr in
                Array(UnsafeBufferPointer(start: mappingPtr, count: channelCount))
            }
        }

        decoder = mapping.withUnsafeBufferPointer { mappingBuf in
            opus_multistream_decoder_create(
                Int32(sampleRate),
                Int32(channelCount),
                config.streams,
                config.coupledStreams,
                mappingBuf.baseAddress!,
                &error
            )
        }

        guard error == OPUS_OK, decoder != nil else {
            AppLog.moonlightAudio.log("Failed to create Opus decoder: \(error)")
            return -1
        }

        // Skip AVAudioEngine setup when muted — avoids activating the audio session
        // which would pause other media (music, podcasts, etc.)
        guard !muted else { return 0 }

        #if canImport(UIKit)
        configureAudioSession()
        #endif

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        guard let format = Self.makeFormat(sampleRate: sampleRate, channelCount: channelCount) else {
            AppLog.moonlightAudio.log("Failed to create audio format for \(self.channelCount, privacy: .public) channels")
            return -1
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        audioEngine = engine
        playerNode = player
        audioFormat = format

        return 0
    }

    /// Interleaved Int16 PCM in the host's channel order. The plain
    /// `channels:` initializer returns nil above two channels, so surround
    /// needs an explicit layout. GameStream sends Windows (WAVEFORMATEXTENSIBLE)
    /// order: FL FR FC LFE BL BR for 5.1, plus SL SR for 7.1.
    private nonisolated static func makeFormat(sampleRate: Int, channelCount: Int) -> AVAudioFormat? {
        let tag: AudioChannelLayoutTag
        switch channelCount {
        case 1, 2:
            return AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channelCount),
                interleaved: true
            )
        case 6: tag = kAudioChannelLayoutTag_WAVE_5_1_A  // L R C LFE Ls Rs
        case 8: tag = kAudioChannelLayoutTag_WAVE_7_1    // L R C LFE Rls Rrs Ls Rs
        default: return nil
        }
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            interleaved: true,
            channelLayout: layout
        )
    }

    /// Starts the engine but not the player: `decodeAndPlaySample` releases
    /// it once the jitter cushion has filled.
    nonisolated func start() {
        guard !muted else { return }
        playing = false
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        do {
            try audioEngine?.start()
            active = true
        } catch {
            AppLog.moonlightAudio.log("Failed to start audio engine: \(error)")
        }
        requestSoundStage(spatialAudioEnabled)
    }

    nonisolated func stop() {
        requestSoundStage(false)
        lifecycleLock.lock()
        active = false
        playerNode?.stop()
        audioEngine?.stop()
        lifecycleLock.unlock()
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }
    }

    nonisolated func cleanup() {
        requestSoundStage(false)
        playerNode?.stop()
        audioEngine?.stop()

        if let engine = audioEngine, let player = playerNode {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }

        if let decoder = decoder {
            opus_multistream_decoder_destroy(decoder)
        }
        decoder = nil
        audioEngine = nil
        playerNode = nil
        audioFormat = nil
    }

    #if canImport(UIKit)
    /// Mixable playback session so a game stream coexists with other audio;
    /// spatial experience follows `spatialAudioEnabled`.
    private nonisolated func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // visionOS-only API (marked unavailable on iOS even though iOS has
            // spatial audio — see the Spatial Audio note in CLAUDE.md).
            #if os(visionOS)
            try session.setIntendedSpatialExperience(
                spatialAudioEnabled ? .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic) : .bypassed
            )
            #endif
            try session.setActive(true)
        } catch {
            AppLog.moonlightAudio.log("Failed to configure audio session: \(error)")
        }
    }
    #endif

    /// Switches the session between head-tracked spatial rendering and flat
    /// bypass live — safe to call whether or not the engine is currently
    /// running (e.g. while muted, before any session has been configured).
    nonisolated func setSpatialAudioEnabled(_ enabled: Bool) {
        spatialAudioEnabled = enabled
        guard !muted else { return }
        // Only once the engine runs: before that, `start()` makes the request.
        lifecycleLock.lock()
        let running = active
        lifecycleLock.unlock()
        if running { requestSoundStage(enabled) }
        #if os(visionOS)
        do {
            try AVAudioSession.sharedInstance().setIntendedSpatialExperience(
                enabled ? .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic) : .bypassed
            )
        } catch {
            AppLog.moonlightAudio.log("Failed to update spatial audio experience: \(error)")
        }
        #endif
    }

    // MARK: - Sound stage

    /// Brings the sound stage up or down on the main actor. Until the hop
    /// lands, packets keep going wherever they went (the stage keeps playing
    /// until it is torn down, which is what clears the sink).
    private nonisolated func requestSoundStage(_ on: Bool) {
        let wanted = on && !muted && MoonlightSoundStagePolicy.wants(channelCount: channelCount)
        wantsStage.withLock { $0 = wanted }
        AppLog.moonlightAudio.notice("Sound stage \(wanted ? "wanted" : "not wanted", privacy: .public): spatial=\(on, privacy: .public) muted=\(self.muted, privacy: .public) channels=\(self.channelCount, privacy: .public)")
        // Strong on purpose: a teardown must still run if this was the
        // renderer's last request before the manager let go of it.
        Task { @MainActor in
            self.reconcileSoundStage()
        }
    }

    private func reconcileSoundStage() {
        if wantsStage.withLock({ $0 }) {
            guard soundStage == nil else { return }
            guard #available(macOS 15.0, *) else { return }
            let slot = stageFeed
            let stage = MoonlightSoundStage(channelCount: channelCount, sampleRate: Double(sampleRate)) { feed in
                slot.withLock { $0 = feed }
            }
            guard let stage, stage.start() else { return }
            soundStage = stage
            onSoundStageChange?(true)
        } else {
            guard let stage = soundStage else { return }
            if #available(macOS 15.0, *) { (stage as? MoonlightSoundStage)?.stop() }
            soundStage = nil
            onSoundStageChange?(false)
        }
    }

    /// Makes the way the wearer faces now the front of the virtual speakers.
    /// A no-op unless the sound stage is up.
    func recenterSoundStage() {
        guard #available(macOS 15.0, *) else { return }
        (soundStage as? MoonlightSoundStage)?.recenter()
    }

    var isSoundStageActive: Bool { soundStage != nil }

    /// Leaving the flat path for the stage: drop what the player node still
    /// has queued so the two paths never play at once, and leave it ready to
    /// prime afresh if the stage goes away again.
    private nonisolated func flushFlatPath() {
        lifecycleLock.lock()
        if active { playerNode?.stop() }
        lifecycleLock.unlock()
        queueState.withLock { state in
            state.frames = 0
            state.generation &+= 1
        }
        playing = false
    }

    /// Decode and play an Opus packet. Called from a background thread.
    ///
    /// `data` is nil when moonlight-common-c lost the packet: decoding nil
    /// runs libopus's packet-loss concealment, which synthesizes a frame
    /// that continues the waveform. Dropping it instead, as this used to,
    /// left a 5 ms hole in the queue — a starvation, and so a click, per
    /// lost packet.
    nonisolated func decodeAndPlaySample(_ data: UnsafeMutablePointer<CChar>?, length: Int32) {
        guard !muted else { return }
        guard let decoder = decoder else { return }

        // Decode Opus to interleaved PCM Int16
        let maxSamples = samplesPerFrame * channelCount
        var pcmBuffer = [Int16](repeating: 0, count: maxSamples)

        let decodedSamples = pcmBuffer.withUnsafeMutableBufferPointer { pcmPtr in
            opus_multistream_decode(
                decoder,
                data.map { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) },
                data == nil ? 0 : length,
                pcmPtr.baseAddress!,
                Int32(samplesPerFrame),
                0  // no FEC
            )
        }

        guard decodedSamples > 0 else { return }

        // Surround on the sound stage. Same frames, PLC included, and the
        // feed keeps the same 40 ms cushion and re-primes the same way.
        if #available(macOS 15.0, *), let object = stageFeed.withLock({ $0 }) {
            let feed = unsafeDowncast(object, to: RAVEChannelFeed.self)
            if !routedToStage {
                flushFlatPath()
                routedToStage = true
            }
            pcmBuffer.withUnsafeBufferPointer { feed.push(interleaved: $0.baseAddress!, frames: Int(decodedSamples)) }
            return
        }
        // Back from the stage: the flat path was flushed on the way out and
        // primes a fresh cushion from here.
        routedToStage = false

        guard let playerNode = playerNode, let format = audioFormat else { return }

        // Create AVAudioPCMBuffer and copy interleaved data
        let frameCount = AVAudioFrameCount(decodedSamples)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        audioBuffer.frameLength = frameCount

        // Copy interleaved Int16 samples directly
        let byteCount = Int(decodedSamples) * channelCount * MemoryLayout<Int16>.size
        guard let channelData = audioBuffer.int16ChannelData else { return }
        memcpy(channelData[0], &pcmBuffer, byteCount)

        let rate = Double(sampleRate)
        let scheduled = Int(frameCount)
        let (depth, generation) = queueState.withLock { ($0.frames, $0.generation) }

        if depth > Int(Self.ceilingSeconds * rate) { return }

        // Ran dry: re-enter the prebuffer state. The node is already
        // rendering silence, so pausing it here is silence-to-silence and
        // inaudible, and the frames scheduled from now on accumulate into a
        // fresh cushion instead of trickling out one jittery frame at a time.
        if playing, depth == 0 {
            lifecycleLock.lock()
            if active { playerNode.pause() }
            lifecycleLock.unlock()
            playing = false
        }

        queueState.withLock { $0.frames += scheduled }
        playerNode.scheduleBuffer(audioBuffer, completionCallbackType: .dataPlayedBack) { [queueState] _ in
            queueState.withLock { state in
                guard state.generation == generation else { return }
                state.frames -= scheduled
            }
        }

        if !playing, depth + scheduled >= Int(Self.primeSeconds * rate) {
            lifecycleLock.lock()
            if active {
                playerNode.play()
                playing = true
            }
            lifecycleLock.unlock()
        }
    }
}
#endif
