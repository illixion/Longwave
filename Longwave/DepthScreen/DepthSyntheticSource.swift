#if os(visionOS)
import CoreVideo
import DebugTrace
import Metal
import QuartzCore

/// Mirrors `DepthSyntheticUniforms` in DepthScreenShaders.metal.
private struct DepthSyntheticUniforms {
    var time: Float
    var aspect: Float
    var tanHalfFov: Float
    var near: Float
    var far: Float
    var fullRange: UInt32
}

/// A moving test scene for the depth screen: a corridor with pillars and
/// floating spheres, raymarched on the GPU into the two streams the host will
/// send — a BGRA picture and a 10-bit inverse-depth luma frame at half or
/// quarter its resolution, in the `x420` layout VideoToolbox decodes HEVC
/// Main10 into — stamped with one frame number and fed through the same
/// `DepthScreenFeed` the Native stream will use.
///
/// It can also misbehave the ways a real stream does: depth frames lost
/// (`depthDropRate`), arriving before or after their picture, or marked empty
/// for a cutscene (`emptyDepth`).
@MainActor
final class DepthSyntheticSource {
    struct Configuration: Equatable {
        var width = 1280
        var height = 720
        /// The depth stream's resolution divisor: 2 (half) or 4 (quarter).
        var depthDivisor = 4
        var framesPerSecond = 60.0
        var fullRangeDepth = false
        var verticalFieldOfView: Float = 60
        var near: Float = 0.1
        var far: Float = 60
        /// The game profile's suggested convergence distance.
        var convergence: Float? = 2.5
    }

    var configuration = Configuration() {
        didSet { if configuration != oldValue { pools = nil } }
    }
    /// Marks every depth frame empty, as the host does for a pre-rendered
    /// cutscene.
    var emptyDepth = false
    /// Fraction of depth frames lost on the way.
    var depthDropRate = 0.0
    /// Freezes the scene's clock (the stream keeps running).
    var isPaused = false
    /// The scene's clock, in seconds.
    var sceneTime: Double = 0

    private let feed: DepthScreenFeed
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let colourPipeline: MTLComputePipelineState?
    private let depthPipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?
    private var pools: (colour: CVPixelBufferPool, depth: CVPixelBufferPool)?
    private var loop: Task<Void, Never>?
    private var frameNumber: UInt32 = 0
    private var inFlight = 0

    init(feed: DepthScreenFeed) {
        self.feed = feed
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        let library = device?.makeDefaultLibrary()
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = library?.makeFunction(name: name) else { return nil }
            return try? device?.makeComputePipelineState(function: function)
        }
        colourPipeline = pipeline("depthSyntheticColour")
        depthPipeline = pipeline("depthSyntheticDepth")
        if let device {
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        }
    }

    func start() {
        guard loop == nil else { return }
        AppLog.depthScreen.info("Depth screen: synthetic source \(self.configuration.width)×\(self.configuration.height) at \(self.configuration.framesPerSecond) fps, depth ÷\(self.configuration.depthDivisor)")
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let interval = 1 / max(self.configuration.framesPerSecond, 1)
                if !self.isPaused { self.sceneTime += interval }
                self.renderFrame()
                next = next.advanced(by: .seconds(interval))
                if next < clock.now { next = clock.now }
                try? await clock.sleep(until: next)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func renderFrame() {
        // Skip a tick rather than queue frames behind a slow GPU.
        guard inFlight < 2, let queue, let colourPipeline, let depthPipeline,
              let pools = pools ?? makePools(),
              let colour = makeBuffer(pools.colour), let depth = makeBuffer(pools.depth),
              let colourTexture = writableTexture(colour, format: .bgra8Unorm, plane: 0),
              let depthTexture = writableTexture(depth, format: .r16Unorm, plane: 0),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let config = configuration
        var uniforms = DepthSyntheticUniforms(
            time: Float(sceneTime),
            aspect: Float(config.width) / Float(config.height),
            tanHalfFov: tan(config.verticalFieldOfView * .pi / 360),
            near: config.near,
            far: config.far,
            fullRange: config.fullRangeDepth ? 1 : 0
        )
        for (pipeline, texture) in [(colourPipeline, colourTexture.texture), (depthPipeline, depthTexture.texture)] {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<DepthSyntheticUniforms>.stride, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: texture.width, height: texture.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
            )
        }
        encoder.endEncoding()

        frameNumber &+= 1
        let number = frameNumber
        let range = DepthRange(near: config.near, far: config.far, convergence: config.convergence, isEmpty: emptyDepth)
        let dropDepth = Double.random(in: 0..<1) < depthDropRate
        let depthFirst = Bool.random()
        let encoding: DepthSampleEncoding = config.fullRangeDepth ? .fullRange10 : .videoRange10
        inFlight += 1
        let buffers = SendableBuffers(
            colour: colour,
            depth: depth,
            keepAlive: [colourTexture.keepAlive, depthTexture.keepAlive]
        )
        commandBuffer.addCompletedHandler { [weak self] _ in
            let source = self
            Task { @MainActor in
                guard let self = source else { return }
                _ = buffers.keepAlive
                self.inFlight -= 1
                // The two streams decode independently, so either may land
                // first; the feed has to cope with both.
                if depthFirst, !dropDepth {
                    self.feed.submit(depth: buffers.depth, range: range, frameNumber: number, encoding: encoding)
                }
                self.feed.submit(colour: buffers.colour, frameNumber: number)
                if !depthFirst, !dropDepth {
                    self.feed.submit(depth: buffers.depth, range: range, frameNumber: number, encoding: encoding)
                }
            }
        }
        commandBuffer.commit()
    }

    private func makePools() -> (colour: CVPixelBufferPool, depth: CVPixelBufferPool)? {
        let config = configuration
        func pool(_ format: OSType, _ width: Int, _ height: Int) -> CVPixelBufferPool? {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            return pool
        }
        let depthFormat = config.fullRangeDepth
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        // 4:2:0 wants even dimensions.
        let depthWidth = max(2, config.width / config.depthDivisor) & ~1
        let depthHeight = max(2, config.height / config.depthDivisor) & ~1
        guard let colour = pool(kCVPixelFormatType_32BGRA, config.width, config.height),
              let depth = pool(depthFormat, depthWidth, depthHeight) else {
            AppLog.depthScreen.error("Depth screen: couldn't create synthetic frame pools")
            return nil
        }
        pools = (colour, depth)
        return pools
    }

    private func makeBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func writableTexture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int) -> (texture: MTLTexture, keepAlive: CVMetalTexture)? {
        guard let textureCache else { return nil }
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, attributes, format, width, height, plane, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}

/// Pixel buffers handed from the GPU's completion queue back to the main
/// actor. They are not touched again by anyone until the feed takes them.
private struct SendableBuffers: @unchecked Sendable {
    let colour: CVPixelBuffer
    let depth: CVPixelBuffer
    /// The Metal views the frame was written through, released once the
    /// frame has been handed on.
    let keepAlive: [CVMetalTexture]
}
#endif
