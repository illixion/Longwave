import DebugTrace
import Foundation
import AVFoundation
import CoreMedia
#if canImport(UIKit)
import UIKit
#endif

/// Reconstructs the exact alpha-bearing HEVC format sent by the Mac and feeds
/// compressed samples to the display layer for hardware decoding — or, for
/// the curved desktop, to a `MacNativeSurfaceDecoder` whose frames many
/// angled strips share.
///
/// Fed straight from the stream client's receive queue rather than hopping
/// to the main thread per frame: the main thread is also running the
/// pointer's hover and drag handlers, and every frame queued behind them was
/// up to a display refresh of extra latency. Nothing here touches UI, and the
/// lock keeps a decoder swap (main thread) from interleaving with an enqueue.
nonisolated final class MacNativeVideoRenderer: @unchecked Sendable {
    var onFormat: (@Sendable (CGSize) -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    var onError: (@Sendable (String) -> Void)?
    /// The decoder changed, so the next frames are useless until a key frame —
    /// the owner asks the host for one instead of waiting out the interval.
    var onKeyFrameNeeded: (@Sendable () -> Void)?

    let displayLayer: AVSampleBufferDisplayLayer

    private let lock = NSLock()
    private let sink: AVSampleBufferVideoRenderer
    /// When set, frames decode here instead of in the display layer.
    private var surfaceDecoder: MacNativeSurfaceDecoder?
    private var formatDescription: CMVideoFormatDescription?
    private var hasDisplayedFrame = false
    /// Set when the decoder changes: a fresh one can't use delta frames
    /// predicted from pictures it never saw.
    private var awaitingKeyFrame = false

    // MARK: Decoder loss
    //
    // visionOS takes video decoding away from an app while another app's
    // immersive space is open: the display layer's renderer goes `.failed`
    // with `requiresFlushToResumeDecoding`, a `VTDecompressionSession`
    // answers `kVTInvalidSessionErr`. Either way the decoder has to be reset
    // and then fed a key frame — and the host encodes key frames only when
    // asked (`MacHEVCEncoder`'s interval is an hour), so not asking left the
    // picture frozen on its last frame for good.

    /// Uptime of the last flush-and-ask, so a decoder that is still not
    /// allowed to run is retried about once a second, not on every frame.
    private var lastRecoveryNanos: UInt64 = 0
    private static let recoveryIntervalNanos: UInt64 = 1_000_000_000
    /// The app is in the background: decoding isn't permitted, so a loss is
    /// only noted, and recovered when the app comes back.
    private var appInBackground = false
    /// A loss noted while recovery was deferred (background or rate limit).
    private var decoderLossPending = false
    /// One of the app's scenes went to the background since the last
    /// recovery check; the surface decoder may have been reset silently.
    private var interruptedSinceRecovery = false
    /// `.failed` without `requiresFlushToResumeDecoding` — something other
    /// than lost resources, such as a stream this decoder can't take.
    /// Retried a few times, then reported as before.
    private var unexplainedFailures = 0
    private static let unexplainedFailuresBeforeError = 3
    private var observers: [NSObjectProtocol] = []

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        self.sink = displayLayer.sampleBufferRenderer
        observeDecoderAvailability()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observeDecoderAvailability() {
        let center = NotificationCenter.default
        // A stream that is idle — a static desktop sends nothing — would
        // never reach the check in `enqueue`, so react to the change itself.
        observers.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: sink,
            queue: nil
        ) { [weak self] _ in
            // Posted from inside `flush`/`enqueue`, which run under `lock`:
            // take it on another thread rather than deadlock.
            DispatchQueue.global(qos: .userInitiated).async {
                self?.decoderAvailabilityChanged()
            }
        })
        #if canImport(UIKit)
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.enteredBackground(appWide: true)
        })
        observers.append(center.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.enteredBackground(appWide: false)
        })
        for name in [
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
            UIScene.willEnterForegroundNotification,
            UIScene.didActivateNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.resumeAfterInterruption()
            })
        }
        #endif
    }

    private func enteredBackground(appWide: Bool) {
        lock.lock()
        if appWide { appInBackground = true }
        interruptedSinceRecovery = true
        lock.unlock()
    }

    private func decoderAvailabilityChanged() {
        lock.lock()
        let requested = sink.requiresFlushToResumeDecoding
            && recoverDecoderLocked(reason: "decoder needs a flush to resume", force: false)
        lock.unlock()
        if requested { onKeyFrameNeeded?() }
    }

    /// The app (or one of its scenes) is back: reset whatever decoder was
    /// lost while it was away and ask for a key frame now, rather than when
    /// the next frame happens to arrive.
    private func resumeAfterInterruption() {
        lock.lock()
        appInBackground = false
        let interrupted = interruptedSinceRecovery
        let lost = decoderLossPending
            || sink.status == .failed
            || sink.requiresFlushToResumeDecoding
            // A reset VT session says so only on the next decode.
            || (interrupted && surfaceDecoder != nil)
        let requested = lost && recoverDecoderLocked(reason: "app returned", force: true)
        if !lost { interruptedSinceRecovery = false }
        lock.unlock()
        if requested { onKeyFrameNeeded?() }
    }

    /// Resets the active decoder and arms the key-frame gate. Returns whether
    /// the caller should ask the host for a key frame (outside the lock).
    /// Caller holds `lock`.
    private func recoverDecoderLocked(reason: StaticString, force: Bool) -> Bool {
        guard formatDescription != nil else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force
              || (!appInBackground && now &- lastRecoveryNanos >= Self.recoveryIntervalNanos) else {
            decoderLossPending = true
            return false
        }
        lastRecoveryNanos = now
        decoderLossPending = false
        interruptedSinceRecovery = false
        if let surfaceDecoder {
            surfaceDecoder.invalidate()
        } else {
            sink.flush()
        }
        awaitingKeyFrame = true
        AppLog.macNativeVideo.info("Decoder reset (\(reason, privacy: .public)); asking the host for a key frame")
        return true
    }

    /// Routes decoding to `decoder`, or back to the display layer with nil.
    func setSurfaceDecoder(_ decoder: MacNativeSurfaceDecoder?) {
        lock.lock()
        guard decoder !== surfaceDecoder else {
            lock.unlock()
            return
        }
        let previous = surfaceDecoder
        surfaceDecoder = decoder
        awaitingKeyFrame = formatDescription != nil
        let wantsKeyFrame = awaitingKeyFrame
        if wantsKeyFrame { lastRecoveryNanos = DispatchTime.now().uptimeNanoseconds }
        previous?.invalidate()
        lock.unlock()
        if decoder != nil {
            sink.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        if wantsKeyFrame { onKeyFrameNeeded?() }
    }

    func setFormatDescription(
        _ data: Data,
        kind: MacNativeStreamProtocol.FormatKind = .coreMediaImageDescription
    ) {
        let description: CMVideoFormatDescription?
        switch kind {
        case .coreMediaImageDescription:
            description = Self.fromImageDescription(data)
        case .hevcParameterSets:
            description = Self.fromParameterSets(data)
        }
        guard let description else {
            onError?("Could not reconstruct the video format.")
            return
        }
        guard CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC else {
            onError?("The host sent an unsupported video codec.")
            return
        }

        lock.lock()
        formatDescription = description
        hasDisplayedFrame = false
        awaitingKeyFrame = false
        decoderLossPending = false
        unexplainedFailures = 0
        surfaceDecoder?.invalidate()
        let sink = sink
        lock.unlock()
        sink.flush()
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        onFormat?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    /// Exact CoreMedia transport (macOS hosts) — preserves the HEVC-alpha
    /// auxiliary-layer metadata that parameter sets alone can't express.
    private static func fromImageDescription(_ data: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianImageDescriptionData: baseAddress,
                size: data.count,
                stringEncoding: CFStringGetSystemEncoding(),
                flavor: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr else { return nil }
        return description
    }

    /// Annex-B VPS/SPS/PPS concatenation (non-Apple hosts, opaque HEVC).
    private static func fromParameterSets(_ data: Data) -> CMVideoFormatDescription? {
        let parameterSets = annexBNALUnits(data).filter { nal in
            guard let first = nal.first else { return false }
            let nalType = (first >> 1) & 0x3F
            return nalType == 32 || nalType == 33 || nalType == 34 // VPS/SPS/PPS
        }
        guard !parameterSets.isEmpty else { return nil }

        var description: CMVideoFormatDescription?
        // Keep the NAL payloads alive and pinned while CoreMedia reads them.
        let pinned = parameterSets.map { [UInt8]($0) }
        let status = withPinnedPointers(pinned) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr else { return nil }
        return description
    }

    private static func withPinnedPointers(
        _ buffers: [[UInt8]],
        _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus
    ) -> OSStatus {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []

        func pin(_ index: Int) -> OSStatus {
            guard index < buffers.count else {
                return body(pointers, sizes)
            }
            return buffers[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                sizes.append(buffer.count)
                return pin(index + 1)
            }
        }
        return pin(0)
    }

    /// Splits an Annex-B stream on 3- or 4-byte start codes.
    private static func annexBNALUnits(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var index = 0
        var currentStart: Int?
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0,
               (bytes[index + 2] == 1 || (index + 3 < bytes.count && bytes[index + 2] == 0 && bytes[index + 3] == 1)) {
                let prefixLength = bytes[index + 2] == 1 ? 3 : 4
                if let start = currentStart, start < index {
                    units.append(Data(bytes[start..<index]))
                }
                index += prefixLength
                currentStart = index
            } else {
                index += 1
            }
        }
        if let start = currentStart, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }

    func enqueue(_ frame: MacNativeStreamProtocol.VideoFrame) {
        lock.lock()
        let wantsKeyFrame = enqueueLocked(frame)
        lock.unlock()
        if wantsKeyFrame { onKeyFrameNeeded?() }
    }

    /// Returns whether to ask the host for a key frame.
    private func enqueueLocked(_ frame: MacNativeStreamProtocol.VideoFrame) -> Bool {
        guard let formatDescription else { return false }
        let sampleBufferRenderer = sink
        if surfaceDecoder == nil {
            if sampleBufferRenderer.requiresFlushToResumeDecoding {
                return recoverDecoderLocked(reason: "decoder needs a flush to resume", force: false)
            }
            switch sampleBufferRenderer.status {
            case .failed:
                unexplainedFailures += 1
                if unexplainedFailures > Self.unexplainedFailuresBeforeError {
                    let message = sampleBufferRenderer.error?.localizedDescription
                        ?? "unknown display-layer error"
                    sampleBufferRenderer.flush()
                    onError?("HEVC-alpha display failed: \(message)")
                    return false
                }
                return recoverDecoderLocked(reason: "display layer failed", force: false)
            case .rendering:
                unexplainedFailures = 0
            default:
                break
            }
        }
        if decoderLossPending {
            // Deferred by the rate limit; retry once it allows.
            return recoverDecoderLocked(reason: "retrying a lost decoder", force: false)
        }
        if awaitingKeyFrame {
            guard frame.isKeyFrame else {
                // Delta frames still coming a second after asking: the
                // request went missing (or the host predates it). Ask again.
                let now = DispatchTime.now().uptimeNanoseconds
                guard now &- lastRecoveryNanos >= Self.recoveryIntervalNanos else { return false }
                lastRecoveryNanos = now
                return true
            }
            awaitingKeyFrame = false
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return false }
        status = frame.data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.data.count
            )
        }
        guard status == noErr else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: Int64(clamping: frame.timestampNanoseconds),
                timescale: 1_000_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = frame.data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return false }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !frame.isKeyFrame {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        if let surfaceDecoder {
            if surfaceDecoder.decode(sampleBuffer) == .decoderLost {
                return recoverDecoderLocked(reason: "surface decoder lost", force: false)
            }
        } else {
            sampleBufferRenderer.enqueue(sampleBuffer)
        }
        if !hasDisplayedFrame {
            hasDisplayedFrame = true
            onFirstFrame?()
        }
        return false
    }

    func reset() {
        lock.lock()
        formatDescription = nil
        hasDisplayedFrame = false
        awaitingKeyFrame = false
        decoderLossPending = false
        unexplainedFailures = 0
        let sink = sink
        lock.unlock()
        sink.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }
}
