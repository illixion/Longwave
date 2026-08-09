import Foundation
import CoreAudio
import AudioToolbox

/// Captures system-wide audio output via a Core Audio process tap
/// (macOS 14.2+) — no virtual audio driver (BlackHole etc.) required.
///
/// When `muteSystemOutput` is enabled, the tap is created with
/// `.muted` behavior: the Mac's (or Vision Pro Sidecar's) physical output
/// is silenced while the tap keeps receiving the rendered audio, so the
/// only audible copy is the one streamed to the receiver.
///
/// Audio flows: process tap → private aggregate device → IOProc block,
/// which converts the tap's interleaved Float32 to interleaved signed int24
/// (the wire format, see `PCM24`) and delivers it via `onAudio` on a
/// realtime Core Audio thread.
final class SystemAudioTap: @unchecked Sendable {

    struct StreamFormat: Sendable {
        let sampleRate: Double
        let channelCount: Int
    }

    enum TapError: LocalizedError {
        case osStatus(String, OSStatus)
        case badFormat

        var errorDescription: String? {
            switch self {
            case .osStatus(let stage, let status):
                "\(stage) failed (OSStatus \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .badFormat:
                "The system audio tap reported an unusable stream format."
            }
        }
    }

    /// Called on a Core Audio realtime thread with interleaved signed int24
    /// PCM (the wire format), converted from the tap's Float32 samples.
    nonisolated(unsafe) var onAudio: (@Sendable (Data) -> Void)?

    private nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) var format: AudioStreamBasicDescription?

    /// Silence-suppression hysteresis (IOProc thread only). The stream is kept
    /// "warm" — silent PCM is still transmitted — for this long after audio
    /// goes quiet, so short musical gaps (track switches, crossfades) play
    /// through seamlessly without the receiver's jitter buffer draining and
    /// popping on resume. Only sustained silence past the hold is suppressed,
    /// which is where the bandwidth (and the receiver-side pause) is won.
    private static let silenceHoldSeconds: Double = 10
    private nonisolated(unsafe) var silentFrames = 0
    private nonisolated(unsafe) var suppressingSilence = false

    nonisolated init() {}

    /// Creates the tap + aggregate device and starts IO.
    /// Returns the capture format so the caller can build the stream header.
    nonisolated func start(muteSystemOutput: Bool) throws -> StreamFormat {
        stop()
        silentFrames = 0
        suppressingSilence = false

        // 1. System-wide stereo mixdown tap of all processes
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Longwave Audio Tap"
        description.isPrivate = true
        description.muteBehavior = muteSystemOutput ? .muted : .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw TapError.osStatus("Creating process tap", status) }
        tapID = newTapID

        // 2. Read the tap's stream format
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Reading tap format", status)
        }
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            stop()
            throw TapError.badFormat
        }
        format = asbd

        // 3. Private aggregate device hosting the tap
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Longwave Companion",
            kAudioAggregateDeviceUIDKey: "pro.longwave.companion.aggregate",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Creating aggregate device", status)
        }
        aggregateID = newAggregateID

        // 4. IOProc pulling tapped audio
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channelCount = Int(asbd.mChannelsPerFrame)

        let sampleRate = asbd.mSampleRate
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let onAudio = self.onAudio else { return }
            self.process(
                inInputData,
                isNonInterleaved: isNonInterleaved,
                channelCount: channelCount,
                sampleRate: sampleRate,
                onAudio: onAudio
            )
        }
        guard status == noErr, ioProcID != nil else {
            stop()
            throw TapError.osStatus("Creating IO proc", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw TapError.osStatus("Starting audio device", status)
        }

        return StreamFormat(sampleRate: asbd.mSampleRate, channelCount: channelCount)
    }

    nonisolated func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        format = nil
    }

    /// IOProc body (realtime thread). Applies the silence-suppression
    /// hysteresis, then encodes and delivers the buffer unless we're in the
    /// suppressed (sustained-silence) state. When nothing is playing the
    /// global mixdown is exact digital silence (0.0); those buffers are still
    /// transmitted for `silenceHoldSeconds` so brief gaps stay seamless, then
    /// dropped to save bandwidth (and let the receiver settle into a pause).
    private nonisolated func process(
        _ bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int,
        sampleRate: Double,
        onAudio: (@Sendable (Data) -> Void)
    ) {
        let (silent, frames) = Self.inspect(
            bufferList, isNonInterleaved: isNonInterleaved, channelCount: channelCount
        )
        if silent {
            if !suppressingSilence {
                silentFrames += frames
                if Double(silentFrames) >= sampleRate * Self.silenceHoldSeconds {
                    suppressingSilence = true
                }
            }
        } else {
            silentFrames = 0
            suppressingSilence = false
        }
        guard !suppressingSilence else { return }

        let payload = Self.extractPCM(
            from: bufferList, isNonInterleaved: isNonInterleaved, channelCount: channelCount
        )
        if !payload.isEmpty { onAudio(payload) }
    }

    /// Cheaply reports whether a buffer is exact digital silence and how many
    /// sample-frames it carries — without encoding it (so a sustained-silence
    /// stream costs only the scan). Silence detection early-exits on the first
    /// non-zero sample, so active audio is effectively free.
    private nonisolated static func inspect(
        _ bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int
    ) -> (silent: Bool, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard !buffers.isEmpty else { return (true, 0) }

        if !isNonInterleaved || buffers.count == 1 {
            let buffer = buffers[0]
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { return (true, 0) }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let floats = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float32.self), count: count
            )
            let frames = channelCount > 0 ? count / channelCount : count
            return (isSilent(floats), frames)
        }

        // Non-interleaved: one buffer per channel.
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
        for channel in 0..<min(channelCount, buffers.count) {
            guard let base = buffers[channel].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            if !isSilent(UnsafeBufferPointer(start: base, count: frames)) {
                return (false, frames)
            }
        }
        return (true, frames)
    }

    /// Converts an AudioBufferList of Float32 samples into a contiguous
    /// interleaved signed int24 blob (the wire format — see `PCM24`).
    private nonisolated static func extractPCM(
        from bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int
    ) -> Data {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard !buffers.isEmpty else { return Data() }

        if !isNonInterleaved || buffers.count == 1 {
            // Already interleaved (the stereo mixdown tap's usual format)
            let buffer = buffers[0]
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { return Data() }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let floats = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Float32.self),
                count: count
            )
            return PCM24.encode(floats)
        }

        // Non-interleaved: one buffer per channel — interleave manually
        let frameBytes = Int(buffers[0].mDataByteSize)
        let frameCount = frameBytes / MemoryLayout<Float32>.size
        var interleaved = [Float32](repeating: 0, count: frameCount * channelCount)
        for channel in 0..<min(channelCount, buffers.count) {
            guard let base = buffers[channel].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for frame in 0..<frameCount {
                interleaved[frame * channelCount + channel] = base[frame]
            }
        }
        return interleaved.withUnsafeBufferPointer { PCM24.encode($0) }
    }

    /// True when every sample is exact digital silence (0.0). Early-exits on
    /// the first non-zero sample, so the common "audio playing" case costs
    /// next to nothing; only a genuinely silent buffer scans in full.
    private nonisolated static func isSilent(_ floats: UnsafeBufferPointer<Float32>) -> Bool {
        for sample in floats where sample != 0 { return false }
        return true
    }
}
