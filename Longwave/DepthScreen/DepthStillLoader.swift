#if os(visionOS)
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// How a still depth image's grey levels relate to distance.
nonisolated enum DepthStillEncoding: String, Codable, Sendable {
    /// Normalised inverse depth, white = near: the wire encoding (§4.8).
    case inverse
    /// Linear distance between the near and far planes, black = near — what
    /// ReShade's DisplayDepth shows and most "depth pass" exports hold.
    case linear
}

/// The optional JSON beside a still pair: `{"near": 0.1, "far": 1000,
/// "convergence": 3, "encoding": "linear", "reversed": false}`. Every key is
/// optional.
nonisolated struct DepthStillSidecar: Codable, Equatable, Sendable {
    var near: Float?
    var far: Float?
    var convergence: Float?
    var encoding: DepthStillEncoding?
    /// Grey levels run the other way (white = far for inverse, white = near
    /// for linear), as a reversed-Z buffer dumped raw does.
    var reversed: Bool?

    var range: DepthScreenRange {
        DepthScreenRange(near: near ?? 0.1, far: far ?? .infinity, convergence: convergence)
    }
}

/// Grey levels (0…1) to the normalised inverse depth the renderer reads.
nonisolated enum DepthStillConversion {
    static func inverseDepth(samples: [Float], encoding: DepthStillEncoding, reversed: Bool, range: DepthScreenRange) -> [Float] {
        samples.map { raw in
            let sample = reversed ? 1 - raw : raw
            switch encoding {
            case .inverse:
                return min(max(sample, 0), 1)
            case .linear:
                guard range.far.isFinite else { return min(max(1 - sample, 0), 1) }
                let distance = range.near + min(max(sample, 0), 1) * (range.far - range.near)
                return range.normalized(distance: distance)
            }
        }
    }
}

/// Loads a still picture and its depth map from disk, so real captures (a
/// game through ReShade on the PC) can be looked at on the depth screen before
/// any host streams depth. Pick the files together: the image whose name
/// contains "depth" is the depth map, any `.json` is the sidecar, the other
/// image is the picture. A 16-bit greyscale PNG keeps the most depth
/// precision; 8-bit works.
nonisolated enum DepthStillLoader {
    struct Still: @unchecked Sendable {
        let colour: CVPixelBuffer
        /// `OneComponent32Float`, normalised inverse depth.
        let depth: CVPixelBuffer
        let range: DepthScreenRange
    }

    enum LoadError: LocalizedError {
        case missingFiles
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missingFiles: "Pick a picture and a depth image (its name containing \u{201C}depth\u{201D})."
            case .unreadable(let name): "Couldn\u{2019}t read \(name)."
            }
        }
    }

    /// Sorts picked files into picture, depth and sidecar.
    static func classify(_ urls: [URL]) -> (colour: URL, depth: URL, sidecar: URL?)? {
        let sidecar = urls.first { $0.pathExtension.lowercased() == "json" }
        let images = urls.filter { $0.pathExtension.lowercased() != "json" }
        guard let depth = images.first(where: { $0.lastPathComponent.lowercased().contains("depth") }),
              let colour = images.first(where: { $0 != depth }) else { return nil }
        return (colour, depth, sidecar)
    }

    static func load(_ urls: [URL]) throws -> Still {
        guard let files = classify(urls) else { throw LoadError.missingFiles }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        var sidecar = DepthStillSidecar()
        if let url = files.sidecar {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DepthStillSidecar.self, from: data) else {
                throw LoadError.unreadable(url.lastPathComponent)
            }
            sidecar = decoded
        }
        guard let colourImage = image(at: files.colour) else { throw LoadError.unreadable(files.colour.lastPathComponent) }
        guard let depthImage = image(at: files.depth),
              let grey = greyLevels(depthImage) else { throw LoadError.unreadable(files.depth.lastPathComponent) }
        let range = sidecar.range
        let values = DepthStillConversion.inverseDepth(
            samples: grey.values,
            encoding: sidecar.encoding ?? .inverse,
            reversed: sidecar.reversed ?? false,
            range: range
        )
        guard let colour = bgraBuffer(colourImage),
              let depth = floatBuffer(values, width: grey.width, height: grey.height) else {
            throw LoadError.unreadable(files.colour.lastPathComponent)
        }
        return Still(colour: colour, depth: depth, range: range)
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The image's luminance at 16 bits, 0…1.
    private static func greyLevels(_ image: CGImage) -> (values: [Float], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt16](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (pixels.map { Float($0) / 65535 }, width, height)
    }

    private static func bgraBuffer(_ image: CGImage) -> CVPixelBuffer? {
        guard let buffer = makeBuffer(kCVPixelFormatType_32BGRA, image.width, image.height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func floatBuffer(_ values: [Float], width: Int, height: Int) -> CVPixelBuffer? {
        guard let buffer = makeBuffer(kCVPixelFormatType_OneComponent32Float, width, height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        values.withUnsafeBufferPointer { source in
            for row in 0..<height {
                base.advanced(by: row * rowBytes)
                    .copyMemory(from: source.baseAddress! + row * width, byteCount: width * 4)
            }
        }
        return buffer
    }

    private static func makeBuffer(_ format: OSType, _ width: Int, _ height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
        return buffer
    }
}
#endif
