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
/// Audio flows: process tap → private aggregate device → IOProc block, which
/// converts the tap's Float32 samples to interleaved signed int24 (the wire
/// format, see `PCM24`) directly into a preallocated `AudioFrameRing` slot.
/// A consumer thread owned by the ring then delivers each buffer via
/// `onAudio`. The IOProc itself never allocates — see `AudioFrameRing` for
/// why that matters.
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

    /// Called with interleaved signed int24 PCM (the wire format), converted
    /// from the tap's Float32 samples. Delivered in order on the frame ring's
    /// consumer thread — *not* the Core Audio realtime thread, so the handler
    /// is free to allocate and to talk to the network stack.
    nonisolated(unsafe) var onAudio: (@Sendable (Data) -> Void)?

    /// Nominal IO buffer size requested from the aggregate device. Pinning it
    /// keeps the packet cadence — and therefore the meaning of the receiver's
    /// jitter cushion — stable when other apps renegotiate the output device.
    private static let preferredBufferFrames: UInt32 = 512

    private nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
    private nonisolated(unsafe) var format: AudioStreamBasicDescription?
    /// Preallocated buffers bridging the realtime IOProc to `onAudio`.
    private nonisolated(unsafe) var ring: AudioFrameRing?

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

        // 4. Pin the IO buffer size. Left unset, the aggregate follows
        // whatever the default output device negotiated, so another app
        // asking for a different buffer silently changes our packet cadence —
        // and the receiver sizes its jitter cushion against that cadence.
        // A refusal isn't fatal; read back whatever the device settled on so
        // the ring is still sized correctly.
        var bufferFrames = Self.preferredBufferFrames
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectSetPropertyData(
            aggregateID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &bufferFrames
        ) != noErr {
            var readBack = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(aggregateID, &bufferAddress, 0, nil, &readBack, &bufferFrames) != noErr {
                bufferFrames = Self.preferredBufferFrames
            }
        }

        // 5. IOProc pulling tapped audio
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channelCount = Int(asbd.mChannelsPerFrame)

        // Generous headroom over the nominal buffer size: the device is
        // entitled to hand us a larger buffer than it advertises, and a slot
        // too small to hold one would drop it.
        let slotCapacity = max(Int(bufferFrames) * 4, 4096) * channelCount * AudioStreamProtocol.bytesPerSample
        let ring = AudioFrameRing(slotCapacity: slotCapacity)
        ring.start { [weak self] data in
            self?.onAudio?(data)
        }
        self.ring = ring

        let sampleRate = asbd.mSampleRate
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let ring = self.ring else { return }
            self.process(
                inInputData,
                isNonInterleaved: isNonInterleaved,
                channelCount: channelCount,
                sampleRate: sampleRate,
                ring: ring
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
        // Stop the device first so the IOProc can't publish into a ring that
        // is about to go away, then drain and join the consumer thread.
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

        ring?.stop()
        ring = nil
        format = nil
    }

    /// IOProc body (realtime thread). Applies the silence-suppression
    /// hysteresis, then encodes straight into a ring slot unless we're in the
    /// suppressed (sustained-silence) state. When nothing is playing the
    /// global mixdown is exact digital silence (0.0); those buffers are still
    /// transmitted for `silenceHoldSeconds` so brief gaps stay seamless, then
    /// dropped to save bandwidth (and let the receiver settle into a pause).
    ///
    /// Nothing on this path allocates, takes an uncontended-at-worst lock, or
    /// touches the network — see `AudioFrameRing`.
    private nonisolated func process(
        _ bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int,
        sampleRate: Double,
        ring: AudioFrameRing
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

        ring.write { destination in
            Self.encodePCM(
                from: bufferList,
                isNonInterleaved: isNonInterleaved,
                channelCount: channelCount,
                into: destination
            )
        }
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

    /// Converts an AudioBufferList of Float32 samples into `destination` as
    /// contiguous interleaved signed int24 (the wire format — see `PCM24`),
    /// returning the byte count written, or 0 if it wouldn't fit.
    ///
    /// Writes in place rather than returning `Data`: this runs on the Core
    /// Audio realtime thread, where a `malloc` that blocks costs the whole
    /// buffer. The non-interleaved path likewise interleaves directly into
    /// the destination instead of via a scratch `[Float32]`.
    private nonisolated static func encodePCM(
        from bufferList: UnsafePointer<AudioBufferList>,
        isNonInterleaved: Bool,
        channelCount: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        guard !buffers.isEmpty, channelCount > 0 else { return 0 }
        let stride = AudioStreamProtocol.bytesPerSample

        if !isNonInterleaved || buffers.count == 1 {
            // Already interleaved (the stereo mixdown tap's usual format)
            let buffer = buffers[0]
            guard let base = buffer.mData, buffer.mDataByteSize > 0 else { return 0 }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            guard count * stride <= destination.count else { return 0 }
            let floats = base.assumingMemoryBound(to: Float32.self)
            for i in 0..<count {
                PCM24.write(floats[i], to: destination, at: i * stride)
            }
            return count * stride
        }

        // Non-interleaved: one buffer per channel — interleave as we encode.
        let frameCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
        let byteCount = frameCount * channelCount * stride
        guard byteCount > 0, byteCount <= destination.count else { return 0 }
        // Channels the tap didn't supply stay silent rather than garbage.
        destination.baseAddress.map { _ = memset($0, 0, byteCount) }
        for channel in 0..<min(channelCount, buffers.count) {
            guard let base = buffers[channel].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            for frame in 0..<frameCount {
                PCM24.write(base[frame], to: destination, at: (frame * channelCount + channel) * stride)
            }
        }
        return byteCount
    }

    /// True when every sample is exact digital silence (0.0). Early-exits on
    /// the first non-zero sample, so the common "audio playing" case costs
    /// next to nothing; only a genuinely silent buffer scans in full.
    private nonisolated static func isSilent(_ floats: UnsafeBufferPointer<Float32>) -> Bool {
        for sample in floats where sample != 0 { return false }
        return true
    }
}
