#if canImport(UIKit)
import AVFoundation
import DebugTrace
import Foundation

/// Captures this device's microphone and hands it on as `microphone` frames,
/// for the Companion to play into a virtual input device on the Mac.
///
/// Capture uses an `AVAudioSinkNode` on the input, so audio leaves at the
/// device's IO cadence (a few milliseconds) rather than the ~100 ms chunks an
/// input tap delivers. The sink runs on the realtime thread, where nothing
/// may allocate, so it writes int24 straight into an `AudioFrameRing` slot;
/// the ring's own thread cuts it into datagram-sized packets.
///
/// No voice processing: the session stays `.playAndRecord` with
/// `.mixWithOthers`, so the microphone coexists with a call in another app,
/// and it is the far end's echo cancellation (ChatGPT's, Meet's) that copes
/// with the Mac's audio coming back through the headset's speakers.
nonisolated final class MicrophoneUplink: @unchecked Sendable {
    enum StartError: LocalizedError {
        case noInput
        case session

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone is available."
            case .session: "The microphone could not be opened."
            }
        }
    }

    private let send: @Sendable (Data) -> Void
    private let engine = AVAudioEngine()
    private var ring: AudioFrameRing?
    private var running = false
    /// Realtime thread only: the capture index of the next sample frame, and
    /// whether the next packet starts a run.
    private var nextIndex: UInt64 = 0
    private var resumedPending = true
    private var configurationObserver: NSObjectProtocol?

    /// - Parameter send: receives each finished frame, on the ring's thread.
    init(send: @escaping @Sendable (Data) -> Void) {
        self.send = send
    }

    func start() throws {
        guard !running else { return }
        guard AudioSessionCoordinator.shared.beginRecording(self) else {
            throw StartError.session
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            AudioSessionCoordinator.shared.endRecording(self)
            throw StartError.noInput
        }
        let sampleRate = format.sampleRate

        // Header (index + flag) ahead of up to 8192 mono int24 frames, far
        // above any IO buffer the device hands out.
        let maxFrames = 8192
        let ring = AudioFrameRing(slotCount: 32, slotCapacity: 9 + maxFrames * AudioStreamProtocol.bytesPerSample, name: "MicrophoneRing")
        let send = self.send
        ring.start { slot in
            Self.packetize(slot, sampleRate: sampleRate, send: send)
        }
        self.ring = ring

        nextIndex = 0
        resumedPending = true
        let sink = AVAudioSinkNode { [unowned self] _, frameCount, bufferList -> OSStatus in
            capture(bufferList, frameCount: Int(frameCount), maxFrames: maxFrames, ring: ring)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        do {
            try engine.start()
        } catch {
            engine.detach(sink)
            ring.stop()
            self.ring = nil
            AudioSessionCoordinator.shared.endRecording(self)
            throw error
        }
        running = true
        // A route or format change stops the engine; start it again in the
        // new format rather than going quietly deaf.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.running else { return }
            AppLog.audioStream.log("Microphone input changed; restarting capture")
            self.stop()
            do {
                try self.start()
            } catch {
                AppLog.audioStream.log("Microphone restart failed: \(error.localizedDescription)")
            }
        }
        AppLog.audioStream.log("Microphone to Mac started: \(Int(sampleRate)) Hz, \(format.channelCount) input channel(s)")
    }

    func stop() {
        guard running else { return }
        running = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.stop()
        for node in engine.attachedNodes where node is AVAudioSinkNode {
            engine.detach(node)
        }
        ring?.stop()
        ring = nil
        AudioSessionCoordinator.shared.endRecording(self)
        AppLog.audioStream.log("Microphone to Mac stopped")
    }

    // MARK: - Realtime thread

    /// Writes the first input channel as int24 into a ring slot: an 8-byte
    /// sample index and a flags byte, then the samples. One channel because a
    /// voice needs no more, and the first channel is the one the system has
    /// already processed into a usable microphone signal.
    private func capture(
        _ bufferList: UnsafePointer<AudioBufferList>,
        frameCount: Int,
        maxFrames: Int,
        ring: AudioFrameRing
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, let data = first.mData, frameCount > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        // Non-interleaved float is the engine's native input format; if this
        // buffer is interleaved, the first channel is every `stride`th sample.
        let stride = buffers.count == 1 ? max(1, Int(first.mNumberChannels)) : 1
        let frames = min(frameCount, maxFrames)
        let index = nextIndex
        let flags: PCMStamp.Flags = resumedPending ? .resumed : []
        let published = ring.write { destination in
            PCMStamp(sampleIndex: index, flags: flags).write(to: destination)
            var stats = PCM24.EncodeStats()
            for i in 0..<frames {
                PCM24.write(samples[i * stride], to: destination, at: PCMStamp.size + i * 3, stats: &stats)
            }
            return PCMStamp.size + frames * 3
        }
        nextIndex = index + UInt64(frameCount)
        // A dropped slot leaves a hole the Mac fills with silence; the next
        // packet carries the index past it, so it needs no flag.
        if published { resumedPending = false }
    }

    // MARK: - Ring thread

    private static func packetize(_ slot: Data, sampleRate: Double, send: @Sendable (Data) -> Void) {
        guard let stamp = PCMStamp(parsing: slot) else { return }
        let samples = slot.dropFirst(PCMStamp.size)
        let bytesPerFrame = AudioStreamProtocol.bytesPerSample
        let chunk = MicrophonePacket.maxFramesPerPacket * bytesPerFrame
        var offset = samples.startIndex
        while offset < samples.endIndex {
            let end = min(offset + chunk, samples.endIndex)
            let framesBefore = (offset - samples.startIndex) / bytesPerFrame
            let packet = MicrophonePacket(
                stamp: PCMStamp(
                    sampleIndex: stamp.sampleIndex + UInt64(framesBefore),
                    flags: framesBefore == 0 ? stamp.flags : []
                ),
                sampleRate: sampleRate,
                channelCount: 1,
                samples: Data(samples[offset..<end])
            )
            send(packet.encodedFrame())
            offset = end
        }
    }
}
#endif
