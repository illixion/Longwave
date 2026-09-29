import DebugTrace
import Foundation
import AVFAudio
import CoreMedia

/// Mic → Opus via Apple's native AudioToolbox Opus codec
/// (`kAudioFormatOpus` through `AVAudioConverter`) — deliberately not the
/// vendored libopus, which is stubbed out in CI/release builds. The
/// converter also handles any capture-rate → 48 kHz resample.
/// Runs on the mic tap's render thread.
final class BroadcastAudioEncoder: @unchecked Sendable {

    /// One 20 ms Opus frame and its running RTP timestamp (48 kHz clock,
    /// 960 samples per frame). Fires on the capture callback thread.
    nonisolated(unsafe) var onEncodedFrame: ((_ frame: Data, _ timestamp48k: UInt32) -> Void)?
    /// Native Opus encode unavailable or failed — the manager downgrades
    /// the broadcast to video-only.
    nonisolated(unsafe) var onError: ((String) -> Void)?

    static let samplesPerFrame: UInt32 = 960   // 20 ms @ 48 kHz

    private let channels: UInt32
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var pendingBuffers: [AVAudioPCMBuffer] = []
    private nonisolated(unsafe) var nextTimestamp: UInt32 = UInt32.random(in: 0...0x7FFFFFFF)
    private nonisolated(unsafe) var failed = false

    nonisolated init(channels: Int) {
        self.channels = UInt32(max(1, min(2, channels)))
    }

    nonisolated func encode(_ pcm: AVAudioPCMBuffer) {
        guard !failed, pcm.frameLength > 0 else { return }
        if converter == nil {
            createConverter(inputFormat: pcm.format)
        }
        guard let converter, let outputFormat else { return }

        pendingBuffers.append(pcm)
        while true {
            let packet = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1,
                                                 maximumPacketSize: 1500)
            var conversionError: NSError?
            let status = converter.convert(to: packet, error: &conversionError) { [self] _, outStatus in
                if pendingBuffers.isEmpty {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return pendingBuffers.removeFirst()
            }
            if let conversionError {
                failOnce("Opus conversion failed: \(conversionError.localizedDescription)")
                return
            }
            guard status == .haveData, packet.byteLength > 0 else { break }
            let frame = Data(bytes: packet.data, count: Int(packet.byteLength))
            onEncodedFrame?(frame, nextTimestamp)
            nextTimestamp &+= Self.samplesPerFrame
        }
    }

    private nonisolated func createConverter(inputFormat: AVAudioFormat) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: Self.samplesPerFrame, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &description),
              let newConverter = AVAudioConverter(from: inputFormat, to: opusFormat) else {
            failOnce("Native Opus encoding unavailable on this OS")
            return
        }
        newConverter.bitRate = 96_000
        converter = newConverter
        outputFormat = opusFormat
        broadcastLogger.log("🎙️ Opus encoder ready: \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch → 48 kHz \(channels)ch")
    }

    /// CMSampleBuffer entry point — used by the broadcast extension, whose
    /// ReplayKit mic feed arrives as sample buffers rather than PCM buffers.
    nonisolated func encode(sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        encode(pcm)
    }

    private nonisolated static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    private nonisolated func failOnce(_ message: String) {
        guard !failed else { return }
        failed = true
        onError?(message)
    }
}
