import AppKit

/// Artwork normalisation shared by both now-playing sources.
///
/// Sources hand us wildly different images — Music.app's AppleScript artwork is
/// whatever the file embeds, MediaRemote hands out 800×800 and occasionally PNG
/// rather than JPEG — so everything is re-encoded to one predictable form
/// before it goes on the wire.
/// `nonisolated` so the MediaRemote bridge can re-encode artwork on its parse
/// queue instead of hitching the main thread on every track change.
nonisolated enum NowPlayingArtwork {

    /// Longest side of the artwork sent to the headset, in pixels.
    static let maxDimension: CGFloat = 600
    static let jpegQuality: CGFloat = 0.8

    /// Scales `data` down to `maxDimension` and re-encodes it as JPEG.
    /// Returns nil if the bytes aren't a decodable image.
    static func scaledJPEG(from data: Data) -> Data? {
        guard !data.isEmpty, let image = NSImage(data: data) else { return nil }
        return scaledJPEG(from: image)
    }

    static func scaledJPEG(from image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
