import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Realtime HEVC encoder, with or without an alpha layer. It forwards the exact
/// CoreMedia image description so the receiver reconstructs the format the
/// encoder actually produced — including the alpha-layer metadata of a `muxa`
/// session, which HEVC parameter sets alone cannot express.
///
/// Per-window (Unity-style) streams need alpha: a Mac window is rounded,
/// shadowed and often vibrant, and the visionOS scene composites it over
/// passthrough. The desktop stream does not — it is the whole display, opaque
/// edge to edge — and plain HEVC spends no bits on a constant alpha plane.
final class MacHEVCEncoder: @unchecked Sendable {
    nonisolated(unsafe) var onFormatDescription: (@Sendable (Data) -> Void)?
    nonisolated(unsafe) var onFrame: (@Sendable (Data, Bool, UInt64, UInt64) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    private nonisolated(unsafe) var bitrate: Int
    private let frameRate: Int
    private let preservesAlpha: Bool
    private nonisolated(unsafe) var session: VTCompressionSession?
    private nonisolated(unsafe) var sessionWidth = 0
    private nonisolated(unsafe) var sessionHeight = 0
    private nonisolated(unsafe) var lastFormatDescription: Data?
    private nonisolated(unsafe) var sequence: UInt64 = 0

    nonisolated init(
        bitrate: Int = 24_000_000,
        frameRate: Int = 60,
        preservesAlpha: Bool = true
    ) {
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.preservesAlpha = preservesAlpha
    }

    nonisolated func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        // A compression session has fixed dimensions; a resized source (a
        // per-window stream whose window was resized) needs a fresh session.
        // The new session's format description differs, so the receiver gets
        // a new format frame and flushes before the next key frame arrives.
        if let existing = session, sessionWidth != width || sessionHeight != height {
            VTCompressionSessionCompleteFrames(existing, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(existing)
            session = nil
        }
        if session == nil {
            createSession(width: width, height: height)
        }
        guard let session else { return }

        if preservesAlpha {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferAlphaChannelModeKey,
                kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                .shouldPropagate
            )
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard let self else { return }
            guard status == noErr, let encodedBuffer else {
                self.onError?("HEVC-alpha encode callback failed (\(status))")
                return
            }
            self.emit(encodedBuffer)
        }
        if status != noErr {
            onError?("VTCompressionSessionEncodeFrame failed (\(status))")
        }
    }

    /// Retargets the bitrate for the *next* compression session. A resized
    /// source already forces a new session (see `encode`), so a display that
    /// changes resolution mid-stream picks this up on its next frame rather
    /// than encoding its new pixel count at the old area's budget.
    nonisolated func setBitrate(_ bitrate: Int) {
        self.bitrate = bitrate
    }

    nonisolated func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        lastFormatDescription = nil
        sequence = 0
    }

    private nonisolated func createSession(width: Int, height: Int) {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: preservesAlpha ? kCMVideoCodecType_HEVCWithAlpha : kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            onError?("\(codecName) encoder unavailable (\(status))")
            return
        }

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        VTSessionSetProperty(
            newSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 1.0 as CFNumber
        )
        if preservesAlpha {
            VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_PreserveAlphaChannel, value: kCFBooleanTrue)
            VTSessionSetProperty(
                newSession,
                key: kVTCompressionPropertyKey_AlphaChannelMode,
                value: kVTAlphaChannelMode_PremultipliedAlpha
            )
            VTSessionSetProperty(
                newSession,
                key: kVTCompressionPropertyKey_TargetQualityForAlpha,
                value: 0.75 as CFNumber
            )
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(newSession)
            onError?("\(codecName) encoder preparation failed (\(prepareStatus))")
            return
        }
        session = newSession
        sessionWidth = width
        sessionHeight = height
    }

    private nonisolated var codecName: String {
        preservesAlpha ? "HEVC-with-alpha" : "HEVC"
    }

    private nonisolated func emit(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let frameData = Self.copyData(from: dataBuffer) else {
            return
        }

        if let serialized = Self.serialize(formatDescription),
           serialized != lastFormatDescription {
            lastFormatDescription = serialized
            onFormatDescription?(serialized)
        }

        let isKeyFrame: Bool = {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[CFString: Any]], let first = attachments.first else {
                return true
            }
            return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }()

        sequence &+= 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestamp: UInt64
        if pts.isValid, pts.isNumeric {
            timestamp = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000_000))
        } else {
            timestamp = DispatchTime.now().uptimeNanoseconds
        }
        onFrame?(frameData, isKeyFrame, sequence, timestamp)
    }

    private nonisolated static func serialize(_ description: CMVideoFormatDescription) -> Data? {
        var blockBuffer: CMBlockBuffer?
        let status = CMVideoFormatDescriptionCopyAsBigEndianImageDescriptionBlockBuffer(
            allocator: kCFAllocatorDefault,
            videoFormatDescription: description,
            stringEncoding: CFStringGetSystemEncoding(),
            flavor: nil,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        return copyData(from: blockBuffer)
    }

    private nonisolated static func copyData(from blockBuffer: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        return status == noErr ? data : nil
    }
}
