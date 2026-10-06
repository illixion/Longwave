import CoreImage
import CoreVideo
import Foundation

/// Crops a captured desktop frame to a still viewer's viewport, scales it to
/// the viewer's pixel size and JPEG-encodes it. Cropping happens *before*
/// scaling, so a zoomed-in watch gets real detail instead of enlarged pixels.
nonisolated final class MacNativeStillEncoder: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `nil` when the viewport is degenerate or the encode fails.
    func encode(
        _ buffer: CVPixelBuffer,
        viewport: MacNativeStreamProtocol.StillViewport
    ) -> Data? {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        guard width > 0, height > 0,
              viewport.width > 0, viewport.height > 0,
              viewport.outputWidth > 0, viewport.outputHeight > 0 else { return nil }

        let full = CGFloat(UInt16.max)
        // Normalized coordinates are top-left origin; Core Image's is bottom-left.
        let cropWidth = max(1, width * CGFloat(viewport.width) / full)
        let cropHeight = max(1, height * CGFloat(viewport.height) / full)
        let cropX = min(width - cropWidth, width * CGFloat(viewport.x) / full)
        let cropTop = min(height - cropHeight, height * CGFloat(viewport.y) / full)
        let crop = CGRect(x: cropX, y: height - cropTop - cropHeight, width: cropWidth, height: cropHeight)

        let scale = min(
            CGFloat(viewport.outputWidth) / cropWidth,
            CGFloat(viewport.outputHeight) / cropHeight
        )
        let image = CIImage(cvPixelBuffer: buffer)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: min(1, scale),
                kCIInputAspectRatioKey: 1,
            ])
        let quality = CGFloat(max(1, min(100, Int(viewport.quality)))) / 100
        return context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
