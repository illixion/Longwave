import DebugTrace
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import RAVEMedia

/// Decodes a stream to IOSurfaces itself, for presentations an
/// `AVSampleBufferDisplayLayer` can't do — the curved screen, which draws
/// each frame into its own mipmapped texture (`RAVEFrameTexture`). Used by
/// the Native desktop and by Moonlight.
///
/// An SDR stream decodes to BGRA. An HDR one (PQ or HLG in its format, or
/// `deepColor` set by a stream that knows) decodes to the decoder's own
/// 10-bit YCbCr instead: BGRA would squeeze PQ into 8 bits, which bands, and
/// the texture's converter takes the native frames as they are.
///
/// Decoding is synchronous on the stream client's receive queue, so a frame
/// is on its way to the screen the moment it has arrived.
nonisolated final class MacNativeSurfaceDecoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    enum DecodeResult {
        case decoded
        /// The decoder is gone — visionOS takes video decoding away from an
        /// app while another app's immersive space is open, and a reset
        /// session answers `kVTInvalidSessionErr`. The session has been
        /// dropped; the next one needs a key frame, which the host only
        /// sends when asked.
        case decoderLost
    }

    /// The stream is HDR whatever its format description says (Moonlight's
    /// HEVC description is built from parameter sets, and the host signals
    /// HDR out of band). Takes effect at the next key frame's session.
    var deepColor = false

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    /// Whether `session` was made to output the decoder's native format.
    private var sessionIsNative = false
    /// The decoder's native output turned out to be a format the converter
    /// doesn't take; this stream decodes to BGRA from then on.
    private var nativeOutputRefused = false
    /// Set from the output callback (another thread) when a frame came back
    /// with a decoder-loss status; consumed by the next `decode`.
    private let lossLock = NSLock()
    private var lostInCallback = false

    /// Only ever called from `MacNativeVideoRenderer`, under its lock.
    @discardableResult
    func decode(_ sampleBuffer: CMSampleBuffer) -> DecodeResult {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return .decoded }
        lossLock.lock()
        let lost = lostInCallback
        lostInCallback = false
        lossLock.unlock()
        if lost {
            invalidate()
            return .decoderLost
        }
        if let session, let format,
           !CMFormatDescriptionEqual(format, otherFormatDescription: description),
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            invalidate()
        }
        if session != nil, sessionIsNative != wantsNativeOutput(description) {
            invalidate()
        }
        if session == nil {
            // Creating one fails too while decoding isn't permitted; that is
            // the same loss, retried by the renderer, not a broken stream.
            guard createSession(description) else { return .decoderLost }
        }
        guard let session else { return .decoded }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            if Self.isDecoderLoss(status) {
                self.lossLock.lock()
                self.lostInCallback = true
                self.lossLock.unlock()
                return
            }
            guard status == noErr, let imageBuffer else { return }
            guard RAVEFrameSignal.isSupported(CVPixelBufferGetPixelFormatType(imageBuffer)) else {
                // Start over in BGRA; that needs a key frame, which the
                // loss path asks for.
                AppLog.macNativeVideo.error("Decoder output \(CVPixelBufferGetPixelFormatType(imageBuffer), privacy: .public) can't be drawn; falling back to BGRA")
                self.lossLock.lock()
                self.nativeOutputRefused = true
                self.lostInCallback = true
                self.lossLock.unlock()
                return
            }
            self.onFrame?(imageBuffer)
        }
        if Self.isDecoderLoss(status) {
            invalidate()
            return .decoderLost
        } else if status != noErr {
            onError?("Desktop decode failed (\(status)).")
        }
        return .decoded
    }

    private static func isDecoderLoss(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    /// HDR decodes to the decoder's native format; see the type's comment.
    private func wantsNativeOutput(_ description: CMFormatDescription) -> Bool {
        lossLock.lock()
        let refused = nativeOutputRefused
        lossLock.unlock()
        guard !refused else { return false }
        if deepColor { return true }
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }

    private func createSession(_ description: CMFormatDescription) -> Bool {
        let native = wantsNativeOutput(description)
        var destination: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        if !native {
            destination[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_32BGRA
        }
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: destination as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            AppLog.macNativeVideo.error("Could not start the desktop decoder (\(status, privacy: .public))")
            return false
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = description
        sessionIsNative = native
        return true
    }
}

/// Hands the newest decoded desktop frame to the curved desktop's texture on
/// the main thread (where RealityKit takes texture updates).
///
/// A frame lands from the decoder's thread; the hop to the main thread is
/// coalesced, so a backlog never builds up behind it — only the newest is
/// ever drawn, and a frame that arrives while one is waiting replaces it.
final class MacNativeFrameSurface {
    private let lock = NSLock()
    private nonisolated(unsafe) var pending: CVPixelBuffer?
    private nonisolated(unsafe) var presentScheduled = false
    /// The last frame shown, so a consumer attached mid-stream draws at once.
    private(set) var current: CVPixelBuffer?
    /// Main thread only.
    var onFrame: ((CVPixelBuffer) -> Void)? {
        didSet { if let current { onFrame?(current) } }
    }

    nonisolated func present(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        pending = pixelBuffer
        let schedule = !presentScheduled
        presentScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let frame = pending
            pending = nil
            presentScheduled = false
            lock.unlock()
            guard let frame else { return }
            current = frame
            onFrame?(frame)
        }
    }

    func clear() {
        current = nil
    }
}
