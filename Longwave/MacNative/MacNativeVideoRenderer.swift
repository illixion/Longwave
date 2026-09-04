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

        formatDescription = description
        hasDisplayedFrame = false
        displayLayer.sampleBufferRenderer.flush()
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
