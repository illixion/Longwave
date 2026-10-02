import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

/// Decodes the desktop stream to BGRA IOSurfaces itself, for presentations
/// an `AVSampleBufferDisplayLayer` can't do — the curved desktop, which shows
/// one decoded frame across many angled strips (`NativeCurvedScreenView`).
///
/// Decoding is synchronous on the stream client's receive queue, so a frame
/// is on its way to the screen the moment it has arrived.
nonisolated final class MacNativeSurfaceDecoder: @unchecked Sendable {
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?

    /// Only ever called from `MacNativeVideoRenderer`, under its lock.
    func decode(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        if let session, let format,
           !CMFormatDescriptionEqual(format, otherFormatDescription: description),
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            invalidate()
        }
        if session == nil {
            createSession(description)
        }
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onFrame?(imageBuffer)
        }
        if status == kVTInvalidSessionErr {
            // The media server reset it (e.g. after the app was backgrounded);
            // the next key frame rebuilds it.
            invalidate()
        } else if status != noErr {
            onError?("Desktop decode failed (\(status)).")
        }
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    private func createSession(_ description: CMFormatDescription) {
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
            onError?("Could not start the desktop decoder (\(status)).")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = description
    }
}

/// The newest decoded desktop frame, shown by every layer attached to it —
/// one per strip of the curved desktop, each cropped to its slice with
/// `contentsRect`. They share the one IOSurface, so a strip costs a layer,
/// not a copy.
///
/// A frame lands from the decoder's thread; the hop to the main thread is
/// coalesced, so a backlog of frames never builds up behind it — only the
/// newest is ever shown.
final class MacNativeFrameSurface {
    private let lock = NSLock()
    private nonisolated(unsafe) var pending: CVPixelBuffer?
    private nonisolated(unsafe) var presentScheduled = false
    /// Kept so a strip attached mid-stream shows the current frame at once,
    /// and so the surface it shows stays alive while it is on screen.
    private var current: CVPixelBuffer?
    private let layers = NSHashTable<CALayer>.weakObjects()

    func attach(_ layer: CALayer) {
        layers.add(layer)
        if let current { show(current, on: layer) }
    }

    func detach(_ layer: CALayer) {
        layers.remove(layer)
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers.allObjects {
                show(frame, on: layer)
            }
            CATransaction.commit()
        }
    }

    func clear() {
        current = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.allObjects {
            layer.contents = nil
        }
        CATransaction.commit()
    }

    private func show(_ frame: CVPixelBuffer, on layer: CALayer) {
        // An IOSurface is a valid layer contents object, and the decoder's
        // pool hands out a different one for every frame still in use, so
        // each assignment is a real change Core Animation will redraw.
        guard let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        layer.contents = surface
    }
}
