#if os(visionOS)
import Foundation
import AVFoundation
import CoreMedia

/// Reconstructs the exact alpha-bearing HEVC format sent by the Mac and feeds
/// compressed samples to AVSampleBufferDisplayLayer for hardware decoding.
final class MacNativeVideoRenderer {
    var onFormat: (@Sendable (CGSize) -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    var onError: (@Sendable (String) -> Void)?

    let displayLayer: AVSampleBufferDisplayLayer

    private var formatDescription: CMVideoFormatDescription?
    private var hasDisplayedFrame = false

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func setFormatDescription(_ data: Data) {
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
        guard status == noErr, let description else {
            onError?("Could not reconstruct the HEVC-alpha format (\(status)).")
            return
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let containsAlpha = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
        ) as? Bool ?? false
        guard subtype == kCMVideoCodecType_HEVC, containsAlpha else {
            onError?("The Mac sent HEVC without its alpha format metadata.")
            return
        }

        formatDescription = description
        hasDisplayedFrame = false
        displayLayer.sampleBufferRenderer.flush()
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        onFormat?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    func enqueue(_ frame: MacNativeStreamProtocol.VideoFrame) {
        guard let formatDescription else { return }
        let sampleBufferRenderer = displayLayer.sampleBufferRenderer
        if sampleBufferRenderer.status == .failed {
            let message = sampleBufferRenderer.error?.localizedDescription
                ?? "unknown display-layer error"
            sampleBufferRenderer.flush()
            onError?("HEVC-alpha display failed: \(message)")
            return
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
        guard status == noErr, let blockBuffer else { return }
        status = frame.data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: frame.data.count
            )
        }
        guard status == noErr else { return }

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
        guard status == noErr, let sampleBuffer else { return }

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

        sampleBufferRenderer.enqueue(sampleBuffer)
        if !hasDisplayedFrame {
            hasDisplayedFrame = true
            onFirstFrame?()
        }
    }

    func reset() {
        formatDescription = nil
        hasDisplayedFrame = false
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
    }
}
#endif
