#if os(visionOS)
import CoreVideo
import DebugTrace
import Metal

/// Depth for a frame that has none of its own (a cutscene, a game not started
/// through Longwave, the Mac desktop). The Depth Anything route (Vergence's
/// `CoreMLDepthProvider`, which already returns normalised inverse depth with
/// near = 1) is the planned implementation; until then the feed shows such
/// frames flat.
@MainActor
protocol DepthScreenEstimator: AnyObject {
    /// Depth for `colour`, or nil when none is ready yet. Called once per
    /// frame without depth, so it must not block on inference.
    func estimateDepth(for colour: CVPixelBuffer) -> DepthScreenDepth?
}

/// The seam the Native stream window will feed: decoded pictures and decoded
/// depth frames, each with its `frameNumber`, in whatever order they arrive.
/// Pairs them (`DepthFramePairer`), falls back to the last good depth, asks
/// the estimator when there is none, and hands each result to `onFrame`.
///
/// Main-actor: decoder callbacks hop here before submitting, as the curved
/// desktop's frame surface does.
@MainActor
final class DepthScreenFeed {
    var onFrame: ((DepthScreenFrame) -> Void)?
    var estimator: DepthScreenEstimator?
    /// How long a picture waits for its depth before it is shown with the last
    /// good one. A few milliseconds: both halves decode on the same frame
    /// clock, so a depth frame later than this is lost or badly delayed, and
    /// holding the picture longer only adds latency to every frame.
    var depthWait: Duration = .milliseconds(6)

    private var pairer = DepthFramePairer<CVPixelBuffer, DepthScreenDepth>()
    private var textureCache: CVMetalTextureCache?
    private var expiry: Task<Void, Never>?
    private var unreadableFormatLogged = false

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        }
    }

    /// A decoded picture (BGRA).
    func submit(colour: CVPixelBuffer, frameNumber: UInt32) {
        deliver(pairer.receive(picture: colour, frameNumber: frameNumber))
        scheduleExpiry()
    }

    /// A decoded depth frame with its `depthRange` side data. The sample
    /// encoding follows from the pixel format unless given.
    func submit(depth pixelBuffer: CVPixelBuffer, range: DepthScreenRange, frameNumber: UInt32, encoding: DepthSampleEncoding? = nil) {
        guard let depth = makeDepth(pixelBuffer, range: range, encoding: encoding) else { return }
        deliver(pairer.receive(depth: depth, frameNumber: frameNumber))
    }

    /// Drops everything held, for a stream restart.
    func reset() {
        expiry?.cancel()
        expiry = nil
        pairer.reset()
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard pairer.isHoldingPicture else {
            expiry = nil
            return
        }
        let wait = depthWait
        expiry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled else { return }
            if let pair = self.pairer.expire() { self.deliver([pair]) }
        }
    }

    private func deliver(_ pairs: [DepthFramePairer<CVPixelBuffer, DepthScreenDepth>.Pair]) {
        // Only the newest is worth drawing; an older one released in the same
        // breath would be replaced before it reached the display.
        guard let pair = pairs.last else { return }
        if !pairer.isHoldingPicture {
            expiry?.cancel()
            expiry = nil
        }
        var depth = pair.depth
        var source: DepthScreenDepthSource = depth == nil ? .none : (pair.depthIsStale ? .stale : .stream)
        if depth == nil || depth?.range.isEmpty == true, let estimated = estimator?.estimateDepth(for: pair.picture) {
            depth = estimated
            source = .estimated
        }
        onFrame?(DepthScreenFrame(frameNumber: pair.frameNumber, colour: pair.picture, depth: depth, source: source))
    }

    private func makeDepth(_ pixelBuffer: CVPixelBuffer, range: DepthScreenRange, encoding: DepthSampleEncoding?) -> DepthScreenDepth? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let textureCache, let pixelFormat = Self.metalFormat(for: format),
              let encoding = encoding ?? DepthSampleEncoding(pixelFormat: format) else {
            if !unreadableFormatLogged {
                unreadableFormatLogged = true
                AppLog.depthScreen.error("Depth screen: unreadable depth format \(format)")
            }
            return nil
        }
        // Luma is plane 0 of the biplanar formats; the flat chroma is ignored.
        let plane = CVPixelBufferIsPlanar(pixelBuffer) ? 0 : -1
        let width = plane >= 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = plane >= 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, pixelFormat, width, height, max(plane, 0), &cvTexture
        )
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return DepthScreenDepth(texture: texture, encoding: encoding, range: range, keepAlive: cvTexture)
    }

    static func metalFormat(for pixelFormat: OSType) -> MTLPixelFormat? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_OneComponent16:
            return .r16Unorm
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32: return .r32Float
        case kCVPixelFormatType_OneComponent16Half: return .r16Float
        case kCVPixelFormatType_OneComponent8: return .r8Unorm
        default: return nil
        }
    }
}
#endif
