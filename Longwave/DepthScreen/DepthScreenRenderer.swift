#if os(visionOS)
import CoreVideo
import DebugTrace
import Metal
import QuartzCore
import RealityKit
import UIKit

extension AppLog {
    static let depthScreen = DebugLogger(subsystem: subsystem, category: "DepthScreen")
}

/// A frame's depth, ready for the GPU.
struct DepthScreenDepth {
    let texture: MTLTexture
    let encoding: DepthSampleEncoding
    let range: DepthRange
    /// Keeps a decoder surface alive while its texture is in use.
    let keepAlive: AnyObject?

    var width: Int { texture.width }
    var height: Int { texture.height }
}

/// One picture and its depth, paired by frame number.
struct DepthScreenFrame {
    let frameNumber: UInt32
    /// BGRA, IOSurface-backed, as `MacNativeSurfaceDecoder` produces.
    let colour: CVPixelBuffer
    let depth: DepthScreenDepth?
    let source: DepthScreenDepthSource
}

/// Where the depth on screen came from.
enum DepthScreenDepthSource: String, Sendable {
    /// The frame's own depth.
    case stream
    /// The last good depth, the frame's own being late or lost.
    case stale
    /// Estimated on the headset (a later task; see `DepthScreenEstimator`).
    case estimated
    /// None: shown flat.
    case none
}

/// Rolling numbers for the lab and the log.
struct DepthScreenStats: Equatable {
    var grid = DepthMeshGrid(columns: 2, rows: 2)
    /// Main-thread time to encode one update (colour copy + mesh kernel), ms.
    var encodeMilliseconds: Double = 0
    /// GPU time of the mesh kernel, ms.
    var gpuMilliseconds: Double = 0
    var framesShown = 0
    var source: DepthScreenDepthSource = .none
}

/// Mirrors `DepthScreenMeshUniforms` in DepthScreenShaders.metal.
private struct DepthScreenMeshUniforms {
    var columns: UInt32
    var rows: UInt32
    var width: Float
    var height: Float
    var reliefScale: Float
    var popOutLimit: Float
    var inverseScale: Float
    var inverseBias: Float
    var convergence: Float
    var valueScale: Float
    var valueBias: Float
    var maxSlope: Float
    var edgeMode: UInt32
    var borderFeather: Float
}

/// Draws a flat game's picture as a 3D screen: a grid mesh displaced by the
/// frame's depth and textured with the picture, which RealityKit renders for
/// each eye itself, so stereo is correct and head motion gives parallax.
///
/// Everything per frame stays on the GPU. The picture is blitted into a
/// mipmapped `LowLevelTexture` (`MacNativeCurvedTexture`, shared with the
/// curved desktop); a compute kernel reads the depth texture and writes the
/// vertices straight into a `LowLevelMesh` buffer. The index buffer never
/// changes. A shader-graph material whose geometry modifier samples the depth
/// texture could displace a static plane without the vertex writes, but it
/// has to be authored as a Reality Composer Pro asset, sees one vertex at a
/// time, and so can't decide per cell whether it spans an outline and re-
/// texture or collapse it; the kernel can, for well under a millisecond.
@MainActor
final class DepthScreenRenderer {
    let entity = Entity()

    var settings = DepthScreenSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.maxColumns != oldValue.maxColumns { builtGrid = nil }
            refresh()
        }
    }

    /// The picture's width in metres; its height follows the picture's aspect.
    var screenWidth: Float = 1 {
        didSet { if screenWidth != oldValue { refresh() } }
    }

    private(set) var stats = DepthScreenStats()
    var onStats: ((DepthScreenStats) -> Void)?

    /// How long relief takes to grow in or flatten out when depth comes or
    /// goes (a cutscene starting), rather than the scene snapping flat.
    static let reliefFade: CFTimeInterval = 0.35

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let meshPipeline: MTLComputePipelineState?
    private let colour = MacNativeCurvedTexture()
    private var mesh: LowLevelMesh?
    private var builtGrid: DepthMeshGrid?
    private var lastFrame: DepthScreenFrame?
    private var materialApplied = false
    /// 0 flat, 1 full relief; eased toward whether the frame has depth.
    private var reliefBlend: Float = 0
    private var lastBlendTime: CFTimeInterval?
    private var fadeTask: Task<Void, Never>?
    /// A 1×1 texture bound when a frame has no depth.
    private lazy var flatDepth: MTLTexture? = makeFlatDepth()
    private var gpuSamples: [Double] = []
    private var encodeSamples: [Double] = []

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        if let function = device?.makeDefaultLibrary()?.makeFunction(name: "depthScreenMesh") {
            meshPipeline = try? device?.makeComputePipelineState(function: function)
        } else {
            meshPipeline = nil
        }
        if meshPipeline == nil {
            AppLog.depthScreen.error("Depth screen: mesh kernel unavailable")
        }
    }

    /// Shows a frame: its picture, and its relief if it has depth.
    func show(_ frame: DepthScreenFrame) {
        let start = CACurrentMediaTime()
        if colour.update(frame.colour) || !materialApplied { applyMaterial() }
        if frame.source != lastFrame?.source {
            AppLog.depthScreen.info("Depth screen: depth source \(frame.source.rawValue, privacy: .public)")
        }
        lastFrame = frame
        updateMesh()
        noteEncode(CACurrentMediaTime() - start)
    }

    /// Redraws the last frame's relief, after a setting changed.
    func refresh() {
        guard lastFrame != nil else { return }
        updateMesh()
    }

    func stop() {
        fadeTask?.cancel()
        fadeTask = nil
    }

    // MARK: - Mesh

    private func updateMesh() {
        guard let frame = lastFrame, let queue, let meshPipeline else { return }
        let depth = frame.depth.flatMap { $0.range.isEmpty ? nil : $0 }
        advanceBlend(toward: depth == nil ? 0 : 1)

        let pictureAspect = Float(CVPixelBufferGetHeight(frame.colour)) / Float(max(CVPixelBufferGetWidth(frame.colour), 1))
        let grid = depth.map {
            DepthMeshGrid(depthWidth: $0.width, depthHeight: $0.height, maxColumns: settings.maxColumns)
        } ?? builtGrid ?? DepthMeshGrid(columns: 64, rows: max(2, Int(64 * pictureAspect)))
        guard let mesh = meshFor(grid), let depthTexture = depth?.texture ?? flatDepth,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let range = depth?.range ?? DepthRange.empty
        let (valueScale, valueBias) = (depth?.encoding ?? .unitInterval).scaleBias
        var uniforms = DepthScreenMeshUniforms(
            columns: UInt32(grid.columns),
            rows: UInt32(grid.rows),
            width: screenWidth,
            height: screenWidth * pictureAspect,
            reliefScale: settings.strength * screenWidth * reliefBlend,
            popOutLimit: settings.popOutLimit,
            inverseScale: range.inverseScale,
            inverseBias: range.inverseBias,
            convergence: settings.convergence(for: range),
            valueScale: valueScale,
            valueBias: valueBias,
            maxSlope: settings.maxSlope,
            edgeMode: settings.edgeMode.shaderValue,
            borderFeather: DepthScreenGeometry.borderFeather
        )
        let vertices = mesh.replace(bufferIndex: 0, using: commandBuffer)
        encoder.setComputePipelineState(meshPipeline)
        encoder.setTexture(depthTexture, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<DepthScreenMeshUniforms>.stride, index: 0)
        encoder.setBuffer(vertices, offset: 0, index: 1)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(
            MTLSize(width: grid.columns - 1, height: grid.rows - 1, depth: 1),
            threadsPerThreadgroup: threads
        )
        encoder.endEncoding()
        let keepAlive = depth?.keepAlive
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = keepAlive
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            let renderer = self
            Task { @MainActor in renderer?.noteGPU(milliseconds) }
        }
        commandBuffer.commit()

        let halfWidth = screenWidth / 2
        let halfHeight = uniforms.height / 2
        let reach = settings.strength * screenWidth
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: grid.indexCount,
                topology: .triangle,
                bounds: BoundingBox(
                    min: [-halfWidth, -halfHeight, -reach],
                    max: [halfWidth, halfHeight, reach * max(settings.popOutLimit, 0)]
                )
            )
        ])
        stats.source = depth == nil ? .none : frame.source
    }

    /// The mesh for `grid`, rebuilt (with its static index buffer) when the
    /// grid changes.
    private func meshFor(_ grid: DepthMeshGrid) -> LowLevelMesh? {
        if let mesh, builtGrid == grid { return mesh }
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = grid.vertexCount
        descriptor.indexCapacity = grid.indexCount
        descriptor.vertexAttributes = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, offset: 0),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, offset: 12),
        ]
        descriptor.vertexLayouts = [LowLevelMesh.Layout(bufferIndex: 0, bufferStride: 20)]
        descriptor.indexType = .uint32
        guard let mesh = try? LowLevelMesh(descriptor: descriptor),
              let resource = try? MeshResource(from: mesh) else {
            AppLog.depthScreen.error("Depth screen: couldn't build a \(grid.columns)×\(grid.rows) mesh")
            return nil
        }
        let indices = grid.indices()
        mesh.replaceUnsafeMutableIndices { buffer in
            indices.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        if entity.components[ModelComponent.self] == nil {
            entity.components.set(ModelComponent(mesh: resource, materials: []))
            materialApplied = false
        } else {
            entity.components[ModelComponent.self]?.mesh = resource
        }
        if materialApplied == false { applyMaterial() }
        self.mesh = mesh
        builtGrid = grid
        stats.grid = grid
        AppLog.depthScreen.info("Depth screen: mesh \(grid.columns)×\(grid.rows), \(grid.vertexCount) vertices")
        return mesh
    }

    private func applyMaterial() {
        guard let resource = colour.resource, entity.components[ModelComponent.self] != nil else { return }
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.maxAnisotropy = 8
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(resource, sampler: .init(sampler)))
        // Edge cells stand nearly edge-on and turn their backs to one eye or
        // the other as the head moves; culled, they'd flicker open like holes.
        material.faceCulling = .none
        entity.components[ModelComponent.self]?.materials = [material]
        materialApplied = true
    }

    private func makeFlatDepth() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = device?.makeTexture(descriptor: descriptor)
        var value: Float = 0
        texture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &value, bytesPerRow: 4)
        return texture
    }

    // MARK: - Fade

    private func advanceBlend(toward target: Float) {
        let now = CACurrentMediaTime()
        let elapsed = lastBlendTime.map { now - $0 } ?? Self.reliefFade
        lastBlendTime = now
        let step = Float(min(elapsed / Self.reliefFade, 1))
        reliefBlend = target > reliefBlend ? min(reliefBlend + step, target) : max(reliefBlend - step, target)
        // A still picture or a stalled stream sends no more frames to carry
        // the fade along, so finish it on a timer.
        if reliefBlend != target, fadeTask == nil {
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                // Cleared first: the refresh schedules the next step if the
                // fade still isn't done.
                self.fadeTask = nil
                self.refresh()
            }
        }
    }

    // MARK: - Stats

    private func noteEncode(_ seconds: CFTimeInterval) {
        stats.framesShown += 1
        encodeSamples.append(seconds * 1000)
        if encodeSamples.count > 120 { encodeSamples.removeFirst() }
        stats.encodeMilliseconds = encodeSamples.reduce(0, +) / Double(encodeSamples.count)
        if stats.framesShown % 600 == 0 {
            AppLog.depthScreen.info("Depth screen: \(self.stats.grid.columns)×\(self.stats.grid.rows), encode \(self.stats.encodeMilliseconds, format: .fixed(precision: 2)) ms, GPU \(self.stats.gpuMilliseconds, format: .fixed(precision: 2)) ms")
        }
        onStats?(stats)
    }

    private func noteGPU(_ milliseconds: Double) {
        guard milliseconds > 0 else { return }
        gpuSamples.append(milliseconds)
        if gpuSamples.count > 120 { gpuSamples.removeFirst() }
        stats.gpuMilliseconds = gpuSamples.reduce(0, +) / Double(gpuSamples.count)
    }
}
#endif
