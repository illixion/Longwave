import DebugTrace
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Decodes the desktop stream to BGRA IOSurfaces itself, for presentations
/// an `AVSampleBufferDisplayLayer` can't do — the curved desktop, which draws
/// each frame into its own mipmapped texture (`MacNativeCurvedTexture`).
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

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
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

    private func createSession(_ description: CMFormatDescription) -> Bool {
        let destination: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
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
