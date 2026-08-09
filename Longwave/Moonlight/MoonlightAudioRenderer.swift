#if MOONLIGHT_ENABLED
import Foundation
import os
import AVFoundation
import Opus
@preconcurrency import MoonlightCommonC

/// Decodes Opus audio packets from moonlight-common-c and plays them
/// through AVAudioEngine using an AVAudioPlayerNode.
class MoonlightAudioRenderer: @unchecked Sendable {

    private nonisolated(unsafe) var decoder: OpaquePointer?    // OpusMSDecoder*
    private nonisolated(unsafe) var channelCount: Int = 0
    private nonisolated(unsafe) var sampleRate: Int = 0
    private nonisolated(unsafe) var samplesPerFrame: Int = 0

    private nonisolated(unsafe) var audioEngine: AVAudioEngine?
    private nonisolated(unsafe) var playerNode: AVAudioPlayerNode?
    private nonisolated(unsafe) var audioFormat: AVAudioFormat?

    /// When true, audio is decoded but not played (no audio mode).
    nonisolated(unsafe) var muted: Bool = false

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
            AppLog.moonlightAudio.line("Failed to create Opus decoder: \(error)")
            return -1
        }

        // Skip AVAudioEngine setup when muted — avoids activating the audio session
        // which would pause other media (music, podcasts, etc.)
        guard !muted else { return 0 }

        // Set up AVAudioEngine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: true
        ) else {
            AppLog.moonlightAudio.line("Failed to create audio format")
            return -1
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        audioEngine = engine
        playerNode = player
        audioFormat = format

        return 0
    }

    nonisolated func start() {
        guard !muted else { return }
        do {
            try audioEngine?.start()
            playerNode?.play()
        } catch {
            AppLog.moonlightAudio.line("Failed to start audio engine: \(error)")
        }
    }

    nonisolated func stop() {
        playerNode?.stop()
        audioEngine?.stop()
    }

    nonisolated func cleanup() {
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

    /// Decode and play an Opus packet. Called from a background thread.
    nonisolated func decodeAndPlaySample(_ data: UnsafeMutablePointer<CChar>, length: Int32) {
        guard !muted else { return }
        guard let decoder = decoder,
              let playerNode = playerNode,
              let format = audioFormat else { return }

        // Decode Opus to interleaved PCM Int16
        let maxSamples = samplesPerFrame * channelCount
        var pcmBuffer = [Int16](repeating: 0, count: maxSamples)

        let decodedSamples = pcmBuffer.withUnsafeMutableBufferPointer { pcmPtr in
            opus_multistream_decode(
                decoder,
                UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self),
                length,
                pcmPtr.baseAddress!,
                Int32(samplesPerFrame),
                0  // no FEC
            )
        }

        guard decodedSamples > 0 else { return }

        // Create AVAudioPCMBuffer and copy interleaved data
        let frameCount = AVAudioFrameCount(decodedSamples)
        guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        audioBuffer.frameLength = frameCount

        // Copy interleaved Int16 samples directly
        let byteCount = Int(decodedSamples) * channelCount * MemoryLayout<Int16>.size
        guard let channelData = audioBuffer.int16ChannelData else { return }
        memcpy(channelData[0], &pcmBuffer, byteCount)

        playerNode.scheduleBuffer(audioBuffer)
    }
}
#endif
