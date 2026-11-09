#if FOVEATED_ENABLED
import Foundation
import Metal
import simd

/// Per-pixel reprojection of a decoded frame by its depth map, from the eye
/// poses it was rendered at to the poses it will be shown at: positional
/// timewarp, done on the headset once per display frame.
///
/// **Why.** A mesh displaced by depth (`PCVREyeMesh`) gets parallax right
/// inside a surface but stretches every cell that spans a depth edge, since
/// one triangle must join the near side to the far: the wider the eye has
/// moved from the render pose, the wider the smear, and the band is as wide
/// as a cell whatever the depth resolution. Warping every pixel instead moves
/// the near side and the far side each by its own parallax, and what the move
/// uncovers is filled from the far side rather than stretched.
///
/// **How.** For each output pixel (per eye, at the frame's wire size, through
/// its foveation map, so the picture is still packed around the gaze) the
/// kernel takes the pixel's ray from the target eye and marches it through
/// the source eye's depth map, from half the stream's near depth to infinity
/// in equal steps of inverse distance (which is nearly equal steps across the
/// depth picture), about one depth texel each, until the ray passes behind the
/// scene surface; the crossing is refined by three secant steps and the frame is
/// read there. Pure rotation needs one step. Depth is interpolated between
/// texels except across an edge (a jump of `edgeCodes` of the 8-bit picture),
/// where the nearer texel's value stands as a step, as in the mesh kernel.
///
/// **Edges.** The march tells a surface from a silhouette by that jump. A ray
/// that passes behind a nearer surface's silhouette (the depth jumps up as the
/// ray goes behind) has not hit it: it carries on in the surface's shadow.
/// Coming out the far side onto a farther surface it is either in front of
/// that surface again, and marches on to hit it, or already behind it: then
/// the point it really hits was hidden from the source eye, and the pixel is
/// filled with the farther surface's colour beside the edge, drawn across the
/// uncovered strip. A ray that never crosses cleanly (the sky, or behind
/// something to the end) takes the far end: rotation only, at infinity.
///
/// **Cost.** The march runs at a quarter of the output's resolution per axis
/// into a warp map (per texel, the hit's displacement in render UV and its
/// inverse depth), and the full-resolution pass interpolates the map where
/// its four texels around a pixel agree in depth, marching itself only where
/// they don't: the few per cent of pixels within a map texel of a depth edge,
/// where interpolation would smear the near side into the far. (Marching every
/// pixel took 5 ms of GPU a tick on the headset, 2026-11-07, half the tick.)
///
/// **Output.** `encode` writes the warped picture for both eyes side by side
/// and, when asked, the warped depth at the depth map's size, encoded like the
/// source (`PCVRDepthMap` with the same near and far): a mesh placed at the
/// target pose can then be displaced by it, so whatever the system's own
/// reprojection still has to bridge (the target pose is a prediction) is
/// bridged with depth, over a shift a few times smaller than the one warped.
///
/// Thread-safety: one thread at a time (the presenter's frame loop).
nonisolated final class PCVRDepthWarper: @unchecked Sendable {
    /// Mirrors `PCVRDepthWarpUniforms`.
    private struct Uniforms {
        var rotation: simd_float3x3
        var translation: SIMD4<Float>
        var sourceTangents: SIMD4<Float>
        var targetTangents: SIMD4<Float>
        var wireX: SIMD4<Float>
        var wireY: SIMD4<Float>
        var sourceRect: SIMD4<Float>
        var sourceBounds: SIMD4<Float>
        var depthRect: SIMD4<Float>
        var depthTexels: SIMD4<Float>
        var depthDecode: SIMD4<Float>
        var depthSize: SIMD2<Float>
        var mapRect: SIMD4<Float>
        var mapBounds: SIMD4<Float>
        var mapSize: SIMD2<Float>
        var outputSize: SIMD2<Float>
        var outputOrigin: SIMD2<UInt32>
        var nearInverse: Float
        var planeInverse: Float
        var stepTexels: Float
        var edge: Float
        var maxSteps: UInt32
        var flags: UInt32
    }

    /// Codes of an 8-bit depth picture between neighbouring texels that make
    /// an edge rather than a slope (`PCVREyeMeshBuilder` uses the same).
    static let edgeCodes: Float = 4

    let device: any MTLDevice
    private let mapPipeline: any MTLComputePipelineState
    private let colourPipeline: any MTLComputePipelineState
    private let depthPipeline: any MTLComputePipelineState
    private let library: any MTLLibrary
    /// Depth always written, never tested: each pixel is drawn once. Without
    /// a state Metal leaves depth writes off, and the views' depth stays clear.
    private let depthWrite: any MTLDepthStencilState
    /// Display-view pipelines by attachment formats (`encode(frame:depth:views:...)`).
    private var displayPipelines: [DisplayPipelineKey: any MTLRenderPipelineState] = [:]
    /// The warp map for display views, remade when their size changes.
    private var displayMap: (any MTLTexture)?

    private struct DisplayPipelineKey: Hashable {
        var color: MTLPixelFormat
        var depth: MTLPixelFormat
        var sampleCount: Int
    }

    /// Mirrors `PCVRDepthWarpView`: what one display view's draw needs beyond its eye's uniforms.
    private struct ViewUniforms {
        var projection: simd_float4x4
        /// x: which of the two uniforms (and warp-map halves) the view uses.
        var index: SIMD4<UInt32>
    }
    private let sampler: any MTLSamplerState
    private let noDepth: any MTLTexture
    /// The warp map, remade when the output size changes.
    private var map: (any MTLTexture)?
    /// Output pixels per warp-map texel, each axis.
    static let mapScale = 4

    /// The most steps a ray is marched: bounds the cost of a large shift. At
    /// one depth texel a step, 32 cover a 12-degree shift of near content.
    var maxSteps = 32
    /// The march's step across the depth picture, in texels.
    var stepTexels: Float = 1
    /// Diagnostics: draw the pixels the warp fills in (their true content was
    /// hidden from the source eye) in magenta.
    var tintsFills = false
    /// Fill what a view's own eye could not see from the frame's other eye
    /// where that eye saw it (tinted cyan with `tintsFills`).
    var fillsFromOtherEye = true
    /// What no view saw takes the far surface's colour from a depth texel
    /// and two pixels off the silhouette (`pcvrDepthWarpHoleColour`), rather
    /// than at it, where the near object's rim bleeds in.
    var fillsOffTheEdge = true
    /// How a pixel that shows what its eye saw reads the picture. Fills stay
    /// bilinear whatever this says: they are a smudge on purpose.
    enum Resampling: String, CaseIterable, Sendable {
        case bilinear
        /// `pcvrSampleCatmullRom`, as is.
        case catmullRom = "catmull-rom"
        /// Catmull-Rom kept within the four nearest texels: no overshoot halo.
        case catmullRomDeRinged = "catmull-rom-dering"
    }
    /// Bilinear. De-ringed Catmull-Rom took 17% of the warp's error off the
    /// circle at the gaze and 12% of its frame-to-frame change on the residual
    /// harness's host-matched fixture (docs/PCVR_RESIDUAL_HARNESS.md,
    /// 2026-11-09), but on the headset, with a matching RealityKit read, the
    /// wearer saw no difference and the headset went to serious thermal state
    /// quickly. Kept selectable for A/B runs; the harness numbers alone are not
    /// a reason to turn it on.
    var resampling: Resampling = .bilinear

    /// The depth-map width (one eye) the march's steps are counted in: the
    /// stream's eighth-size depth of a 5184-wide eye, where `stepTexels`,
    /// `maxSteps` and the fill march were tuned. A finer map takes
    /// proportionally longer steps (`depthDetail`), so a march covers the same
    /// angle in as many samples; counted in its own texels, a quarter-size
    /// map reached a quarter as far and truncated the shifts of near content.
    static let referenceDepthEyeWidth: Float = 648

    /// A depth map's texels per reference texel, at least 1.
    static func depthDetail(_ depth: any MTLTexture) -> Float {
        max(1, Float(depth.width / 2) / referenceDepthEyeWidth)
    }

    /// An earlier frame and its depth, for filling what the frame being
    /// warped did not see (`encode(frame:...fills:)`).
    struct FillSource {
        var frame: PCVRDecodedFrame
        var depth: PCVRDepthMap
    }
    /// Views tried per output eye for a pixel its own source could not see,
    /// best first.
    static let fillSlots = 2
    /// Earlier frames bound per encode, at most.
    static let fillFrames = 4
    /// A fill view's age counts against it as this many metres per second
    /// of render-time difference: of two views about as close to the eye,
    /// the newer one, since anything moving in the scene has moved since.
    static let fillAgePenalty: Float = 0.1
    /// A fill view's score, in metres, when it sees none of what the eye's
    /// move uncovered (`fillPlan`): more than the other eye's distance, so a
    /// view that sees round the near object beats a nearer one that doesn't.
    static let fillCoveragePenalty: Float = 0.12
    /// The fill views' march, coarser than the main one: on a hard shake the
    /// strips are a tenth of the picture or more, and two full marches for
    /// each of their pixels took the warp past 20 ms, a skipped refresh in
    /// ten at 60 Hz (headset, 2026-11-08).
    var fillMaxSteps = 16
    var fillStepTexels: Float = 2
    /// The most of the eye's move since the frame was rendered that is
    /// corrected per pixel by depth, metres; the rest is corrected for the
    /// plane at the warp's `planeDistance` (`uniforms`). Per-pixel depth gets
    /// near against far right, but every centimetre of the prediction's miss
    /// uncovers a strip beside every near edge (a trail on head shakes,
    /// 60-125 ms spans); a plane opens no holes but leaves everything off its
    /// depth swimming by the rest. Infinity: all by depth.
    var depthShiftLimit: Float {
        get { Self.depthShiftLimitNow }
        set { Self.depthShiftLimitNow = newValue }
    }
    nonisolated(unsafe) static var depthShiftLimitNow: Float = .infinity

    init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        self.library = library
        guard let depthWrite = PCVRReceiver.makeDepthWriteState(device: device) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp depth state")
        }
        self.depthWrite = depthWrite
        guard let map = library.makeFunction(name: "pcvrDepthWarpMap"),
              let colour = library.makeFunction(name: "pcvrDepthWarpColour"),
              let depth = library.makeFunction(name: "pcvrDepthWarpDepth") else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp kernels")
        }
        mapPipeline = try device.makeComputePipelineState(function: map)
        colourPipeline = try device.makeComputePipelineState(function: colour)
        depthPipeline = try device.makeComputePipelineState(function: depth)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp sampler")
        }
        self.sampler = sampler
        let empty = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        empty.usage = .shaderRead
        guard let noDepth = device.makeTexture(descriptor: empty) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp placeholder depth")
        }
        self.noDepth = noDepth
    }

    /// Warps `frame` to the eyes at `targets` (world-from-eye, left then
    /// right, with the frame's own frusta), writing both eyes side by side
    /// into `colour` (any size; the frame's wire size keeps its detail) and,
    /// when given, the warped depth into `warpedDepth` (a float texture, both
    /// eyes side by side; the source depth's size is natural). Without `depth`
    /// the whole picture is taken to lie `planeDistance` metres ahead of the
    /// source eye and `warpedDepth` is left alone.
    ///
    /// **Fills.** A pixel whose true point the frame's eye could not see (the
    /// strip a move uncovers beside a near object, or past the frame's edge
    /// after a turn) is the prediction's error made visible: the frame was
    /// rendered from where the eye was predicted to be, 60-125 ms ahead, and
    /// on a head shake that misses by centimetres. It is taken, where one of
    /// them saw it, from the view rendered nearest to where the eye is now:
    /// the frame's other eye (what a sideways move uncovers is what the eye on
    /// that side sees past the object), or one of `fills`, earlier frames,
    /// which on a back-and-forth shake were rendered from the far side of the
    /// swing. `fillSlots` views per eye, by distance to the eye plus
    /// `fillAgePenalty`. Only the pixels that need it march again: the cost
    /// is a few per cent of a warp. Tinted with `tintsFills`: cyan from the
    /// other eye, yellow from an earlier frame, magenta where none saw it.
    func encode(frame: PCVRDecodedFrame, depth: PCVRDepthMap?, targets: PCVRStereo<PCVRPose>, planeDistance: Float,
                into colour: any MTLTexture, warpedDepth: (any MTLTexture)? = nil, fills: [FillSource] = [],
                commandBuffer: any MTLCommandBuffer) throws {
        let depthTexture = depth?.texture ?? noDepth
        let map = try warpMap(for: colour)
        let eyeWidth = colour.width / 2
        let outputSize = SIMD2(Float(eyeWidth), Float(colour.height))
        var uniforms = (0..<2).map { eye in
            self.uniforms(frame: frame, eye: eye, depth: depth, target: targets[eye],
                          targetTangents: frame.renderPose.eyes[eye].fieldOfView.tangents, planeDistance: planeDistance,
                          outputSize: outputSize,
                          outputOrigin: SIMD2(UInt32(eye * eyeWidth), 0), map: map, mapSlot: eye, flags: 0)
        }
        // Fill views per eye: uniforms 2 + fillSlots * eye + slot, each naming
        // its source in the fill texture arrays (0: this frame).
        var sources: [FillSource] = depth.map { [FillSource(frame: frame, depth: $0)] } ?? []
        let plan = depth == nil ? [[], []] : Self.fillPlan(frame: frame, targets: targets, fills: fills,
                                                           otherEye: fillsFromOtherEye)
        for eye in 0..<2 {
            for slot in 0..<Self.fillSlots {
                var index: Int?
                var view: FillView?
                if slot < plan[eye].count, let depth {
                    let chosen = plan[eye][slot]
                    let source = chosen.fill.map { fills[$0] } ?? FillSource(frame: frame, depth: depth)
                    if let existing = sources.firstIndex(where: { $0.frame === source.frame }) {
                        index = existing
                    } else if sources.count <= Self.fillFrames {
                        index = sources.count
                        sources.append(source)
                    }
                    view = chosen
                }
                guard let index, let view else {
                    var unused = uniforms[eye]
                    unused.flags = 0
                    uniforms.append(unused)
                    continue
                }
                let source = sources[index]
                var fill = self.uniforms(
                    frame: source.frame, eye: view.eye, depth: source.depth, target: targets[eye],
                    targetTangents: frame.renderPose.eyes[eye].fieldOfView.tangents, planeDistance: planeDistance,
                    outputSize: outputSize, outputOrigin: SIMD2(UInt32(eye * eyeWidth), 0), map: map, mapSlot: eye,
                    flags: 32 | UInt32(index) << 8)
                fill.maxSteps = UInt32(max(fillMaxSteps, 1))
                fill.stepTexels = max(fillStepTexels, 0.25) * Self.depthDetail(source.depth.texture)
                uniforms.append(fill)
                uniforms[eye].flags |= 8
            }
        }
        let length = MemoryLayout<Uniforms>.stride * uniforms.count
        // A serial encoder: each dispatch sees the one before it complete.
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp encoder")
        }
        encoder.label = "PCVR depth warp"
        encoder.setBytes(&uniforms, length: length, index: 0)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(depthTexture, index: 1)
        encoder.setTexture(colour, index: 2)
        encoder.setTexture(map, index: 3)
        let slots = Self.fillFrames + 1
        let fillColours: [(any MTLTexture)?] = (0..<slots).map { $0 < sources.count ? sources[$0].frame.texture : noDepth }
        let fillDepths: [(any MTLTexture)?] = (0..<slots).map { $0 < sources.count ? sources[$0].depth.texture : noDepth }
        encoder.setTextures(fillColours, range: 4..<(4 + slots))
        encoder.setTextures(fillDepths, range: (4 + slots)..<(4 + 2 * slots))
        encoder.setSamplerState(sampler, index: 0)
        encoder.setComputePipelineState(mapPipeline)
        encoder.dispatchThreads(MTLSize(width: map.width, height: map.height, depth: 1),
                                threadsPerThreadgroup: Self.threadgroup(mapPipeline))
        encoder.setComputePipelineState(colourPipeline)
        encoder.dispatchThreads(MTLSize(width: colour.width, height: colour.height, depth: 1),
                                threadsPerThreadgroup: Self.threadgroup(colourPipeline))
        if let warpedDepth, depth != nil {
            encoder.setComputePipelineState(depthPipeline)
            encoder.setTexture(warpedDepth, index: 2)
            encoder.dispatchThreads(MTLSize(width: warpedDepth.width, height: warpedDepth.height, depth: 1),
                                    threadsPerThreadgroup: Self.threadgroup(depthPipeline))
        }
        encoder.endEncoding()
    }

    /// Warps `frame` straight into a presenter's display views, as a render
    /// pass per view (through its rasterization rate map, if it has one):
    /// each view's pixel rays come from the view's own eye pose and frustum
    /// (`PCVRReceiverTarget.display`), so the picture is resampled once, at
    /// the display's own pixels, and each pixel's depth is written through
    /// `displayProjection`, for a system compositor that reprojects again by
    /// depth (CompositorServices). Pixels whose ray leaves the rendered
    /// frustum take its edge. With no frame, clears the views to black.
    ///
    /// The warp map is laid out per display view (left, right) at a quarter
    /// of the view's logical size; a single view (the simulator's, a capture)
    /// uses its first half.
    func encode(frame: PCVRDecodedFrame?, depth: PCVRDepthMap?, views targets: [PCVRReceiverTarget],
                planeDistance: Float, commandBuffer: any MTLCommandBuffer) throws {
        guard let frame, let first = targets.first else {
            try PCVRReceiver.encodeClear(targets: targets, commandBuffer: commandBuffer)
            return
        }
        let depthTexture = depth?.texture ?? noDepth
        let logical = Self.logicalSize(first)
        let map = try displayMap(width: logical.width, height: logical.height)
        var uniforms = (0..<2).map { slot in
            let target = targets[min(slot, targets.count - 1)]
            let size = Self.logicalSize(target)
            return self.uniforms(frame: frame, eye: target.eye, depth: depth, target: target.display.pose,
                                 targetTangents: target.display.fieldOfView.tangents, planeDistance: planeDistance,
                                 outputSize: SIMD2(Float(size.width), Float(size.height)), outputOrigin: .zero,
                                 map: map, mapSlot: slot, flags: 4)
        }
        // Each view's ray through the frame's other eye, for what its own eye
        // could not see (`fillsFromOtherEye`): slots 2 and 3.
        var fragmentUniforms = uniforms
        for slot in 0..<2 {
            let target = targets[min(slot, targets.count - 1)]
            let size = Self.logicalSize(target)
            fragmentUniforms.append(self.uniforms(
                frame: frame, eye: 1 - min(target.eye, 1), depth: depth, target: target.display.pose,
                targetTangents: target.display.fieldOfView.tangents, planeDistance: planeDistance,
                outputSize: SIMD2(Float(size.width), Float(size.height)), outputOrigin: .zero,
                map: map, mapSlot: slot, flags: 4))
        }
        if fillsFromOtherEye && depth != nil {
            for slot in 0..<2 { fragmentUniforms[slot].flags |= 8 }
        }
        let length = MemoryLayout<Uniforms>.stride * 2
        guard let compute = commandBuffer.makeComputeCommandEncoder() else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp encoder")
        }
        compute.label = "PCVR depth warp map"
        compute.setBytes(&uniforms, length: length, index: 0)
        compute.setTexture(depthTexture, index: 1)
        compute.setTexture(map, index: 3)
        compute.setSamplerState(sampler, index: 0)
        compute.setComputePipelineState(mapPipeline)
        compute.dispatchThreads(MTLSize(width: map.width, height: map.height, depth: 1),
                                threadsPerThreadgroup: Self.threadgroup(mapPipeline))
        compute.endEncoding()

        var slot = 0
        for group in PCVRReceiver.passGroups(targets) {
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: PCVRReceiver.passDescriptor(group[0])) else {
                throw PCVRReceiverError.resourceCreationFailed("depth warp render encoder")
            }
            encoder.label = "PCVR depth warp"
            encoder.setRenderPipelineState(try displayPipeline(for: group[0]))
            if group[0].depthTexture != nil { encoder.setDepthStencilState(depthWrite) }
            encoder.setFragmentBytes(&fragmentUniforms, length: MemoryLayout<Uniforms>.stride * 4, index: 0)
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.setFragmentTexture(depthTexture, index: 1)
            encoder.setFragmentTexture(map, index: 3)
            encoder.setFragmentSamplerState(sampler, index: 0)
            for target in group {
                var view = ViewUniforms(projection: target.displayProjection, index: SIMD4(UInt32(min(slot, 1)), 0, 0, 0))
                encoder.setViewport(target.viewport)
                encoder.setFragmentBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                slot += 1
            }
            encoder.endEncoding()
        }
    }

    /// One view a pixel can be filled from: `fill` indexes the earlier
    /// frames (nil: the frame being warped), `eye` is that frame's eye.
    struct FillView: Equatable {
        var fill: Int?
        var eye: Int
        var score: Float
    }

    /// Per output eye, the best `fillSlots` views to fill from: the frame's
    /// other eye (with `otherEye`) and both eyes of every earlier frame in
    /// the same space epoch, nearest to that eye's target first, a view's
    /// age against it (`fillAgePenalty`). Pure, for the tests.
    static func fillPlan(frame: PCVRDecodedFrame, targets: PCVRStereo<PCVRPose>, fills: [FillSource],
                         otherEye: Bool) -> [[FillView]] {
        (0..<2).map { eye in
            let target = targets[eye].position
            // What the move from the frame's own eye to the target uncovers is
            // seen by a view on the target's side of that eye: one at or past
            // the target along the move sees all of it, one beside or behind
            // the frame's eye sees the same shadow. Nearness alone picked
            // earlier frames of the same eye (rendered a few mm away, blind
            // to the same strip) over the other eye, the view that sees round
            // the near object when the eye moved toward it.
            let origin = frame.renderPose.eyes[eye].pose.position
            let move = target - origin, reach = simd_length(move)
            var views: [FillView] = []
            func score(_ source: PCVRDecodedFrame, _ sourceEye: Int) -> Float {
                let age = Float(abs(frame.renderPose.displayTime - source.renderPose.displayTime))
                let position = source.renderPose.eyes[sourceEye].pose.position
                let coverage = reach > 0.002 ? min(max(simd_dot(position - origin, move) / (reach * reach), 0), 1) : 1
                return simd_distance(position, target) + age * fillAgePenalty + (1 - coverage) * fillCoveragePenalty
            }
            if otherEye { views.append(FillView(fill: nil, eye: 1 - eye, score: score(frame, 1 - eye))) }
            for (index, fill) in fills.enumerated()
            where fill.frame !== frame && fill.frame.renderPose.spaceEpoch == frame.renderPose.spaceEpoch {
                for sourceEye in 0..<2 {
                    views.append(FillView(fill: index, eye: sourceEye, score: score(fill.frame, sourceEye)))
                }
            }
            return Array(views.sorted { $0.score < $1.score }.prefix(fillSlots))
        }
    }

    /// A view's size in logical (unfoveated) pixels: its rate map's screen
    /// size when it has one, else its viewport.
    private static func logicalSize(_ target: PCVRReceiverTarget) -> (width: Int, height: Int) {
        if let map = target.rasterizationRateMap {
            let size = map.screenSize
            if size.width > 0, size.height > 0 { return (size.width, size.height) }
        }
        return (max(Int(target.viewport.width), 1), max(Int(target.viewport.height), 1))
    }

    private func displayMap(width: Int, height: Int) throws -> any MTLTexture {
        let mapWidth = 2 * ((width + Self.mapScale - 1) / Self.mapScale)
        let mapHeight = (height + Self.mapScale - 1) / Self.mapScale
        if let displayMap, displayMap.width == mapWidth, displayMap.height == mapHeight { return displayMap }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: mapWidth,
                                                                  height: mapHeight, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("display depth warp map")
        }
        made.label = "PCVR display depth warp map"
        displayMap = made
        return made
    }

    private func displayPipeline(for target: PCVRReceiverTarget) throws -> any MTLRenderPipelineState {
        let key = DisplayPipelineKey(color: target.colorTexture.pixelFormat,
                                     depth: target.depthTexture?.pixelFormat ?? .invalid,
                                     sampleCount: target.colorTexture.sampleCount)
        if let cached = displayPipelines[key] { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "PCVR depth warp"
        descriptor.vertexFunction = library.makeFunction(name: "pcvrDepthWarpVertex")
        descriptor.fragmentFunction = library.makeFunction(
            name: key.depth == .invalid ? "pcvrDepthWarpDisplayColour" : "pcvrDepthWarpDisplay")
        descriptor.colorAttachments[0].pixelFormat = key.color
        descriptor.depthAttachmentPixelFormat = key.depth
        descriptor.rasterSampleCount = key.sampleCount
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        displayPipelines[key] = state
        return state
    }

    /// The warp map for an output: a quarter of its size per axis, per eye.
    private func warpMap(for colour: any MTLTexture) throws -> any MTLTexture {
        let width = 2 * ((colour.width / 2 + Self.mapScale - 1) / Self.mapScale)
        let height = (colour.height + Self.mapScale - 1) / Self.mapScale
        if let map, map.width == width, map.height == height { return map }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            throw PCVRReceiverError.resourceCreationFailed("depth warp map")
        }
        made.label = "PCVR depth warp map"
        map = made
        return made
    }

    private static func threadgroup(_ pipeline: any MTLComputePipelineState) -> MTLSize {
        let width = min(pipeline.threadExecutionWidth, 16)
        return MTLSize(width: width, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, 16)), depth: 1)
    }

    private func uniforms(frame: PCVRDecodedFrame, eye: Int, depth: PCVRDepthMap?, target: PCVRPose,
                          targetTangents: SIMD4<Float>, planeDistance: Float, outputSize: SIMD2<Float>,
                          outputOrigin: SIMD2<UInt32>, map: any MTLTexture, mapSlot: Int, flags: UInt32) -> Uniforms {
        let source = frame.renderPose.eyes[eye]
        let sourceFromTarget = source.pose.inverse * target
        let wire = frame.wireConstants(eye: eye)
        let depthTexture = depth?.texture ?? noDepth
        let decode = depth?.decode ?? .zero
        let plane = max(planeDistance, 0.01)
        // The translation corrected per pixel by depth is at most
        // `depthShiftLimit`; the rest is corrected for the plane at
        // `planeDistance` (the gaze's depth), which opens no holes. Each
        // output ray from the target is aimed at where it meets that plane,
        // from the nearer origin: origin t - e, direction R d + e / plane, the
        // excess e folded into the matrix's third column since d.z is -1.
        var rotation = simd_float3x3(sourceFromTarget.rotation)
        var translation = sourceFromTarget.position
        let shift = simd_length(translation)
        if depth != nil, shift > depthShiftLimit {
            let excess = translation * (1 - depthShiftLimit / shift)
            translation -= excess
            rotation.columns.2 -= excess / plane
        }
        let detail = depth.map { Self.depthDetail($0.texture) } ?? 1
        return Uniforms(
            rotation: rotation,
            translation: SIMD4(translation, 0),
            sourceTangents: source.fieldOfView.tangents,
            targetTangents: targetTangents,
            wireX: wire.x, wireY: wire.y,
            sourceRect: PCVRReceiver.eyeRect(eye: eye, texture: frame.texture),
            sourceBounds: PCVRReceiver.eyeBounds(eye: eye, texture: frame.texture),
            depthRect: PCVRReceiver.eyeRect(eye: eye, texture: depthTexture),
            depthTexels: PCVREyeMeshBuilder.eyeTexels(eye: eye, texture: depthTexture),
            depthDecode: decode,
            depthSize: SIMD2(Float(depthTexture.width), Float(depthTexture.height)),
            mapRect: PCVRReceiver.eyeRect(eye: mapSlot, texture: map),
            mapBounds: PCVRReceiver.eyeBounds(eye: mapSlot, texture: map),
            mapSize: SIMD2(Float(map.width / 2), Float(map.height)),
            outputSize: outputSize,
            outputOrigin: outputOrigin,
            // The march starts at half the nearest depth there can be, so its
            // first sample is in front of everything.
            nearInverse: depth.map { 2 / max($0.near, 0.01) } ?? 2 / plane,
            planeInverse: 1 / plane,
            stepTexels: max(stepTexels, 0.25) * detail,
            edge: depth != nil ? Self.edgeCodes / 255 * abs(decode.x * decode.w) : 0,
            maxSteps: UInt32(max(maxSteps, 1)),
            flags: flags | (depth != nil ? 1 : 0) | (tintsFills ? 2 : 0) | (fillsOffTheEdge ? 64 : 0) | (resampling == .bilinear ? 0 : 128) | (resampling == .catmullRomDeRinged ? 2048 : 0))
    }

    /// Computed, not stored: a live patch (`inject`) can change a computed
    /// property, and a warper made after it compiles the new source.
    static var shaderSource: String { """
    #include <metal_stdlib>
    using namespace metal;
    \(PCVRFoveationShader.source)

    struct PCVRDepthWarpUniforms {
        float3x3 rotation;      // source eye <- target eye
        float4 translation;     // the target eye's origin in source eye space
        float4 sourceTangents;  // left, right, up, down (left and down negative)
        float4 targetTangents;
        float4 wireX;           // the frame's centre/edge map for this eye
        float4 wireY;
        float4 sourceRect;      // this eye's half of the frame texture, and its clamp
        float4 sourceBounds;
        float4 depthRect;       // this eye's half of the depth map, its texel range and decode
        float4 depthTexels;
        float4 depthDecode;
        float2 depthSize;
        float4 mapRect;         // this eye's half of the warp map, its clamp and its texels
        float4 mapBounds;
        float2 mapSize;
        float2 outputSize;      // this eye's output pixels and where they start
        uint2 outputOrigin;
        float nearInverse;      // where the march starts, as inverse distance along the ray
        float planeInverse;     // the scene's inverse depth everywhere, without a depth map
        float stepTexels;
        float edge;             // an inverse-depth jump this large between texels is an edge
        uint maxSteps;
        uint flags;             // 1: a depth map; 2: tint filled pixels; 4: the output is the target's own
                                // render UV (a display view), not packed by the frame's foveation map;
                                // 8: fill from the other eye (display views, uniforms 2 and 3), or
                                // from the fill views (the compute colour pass, uniforms 2 + 2 * eye + slot);
                                // 32: a fill view in use, its source in bits 8-10 of the fill arrays;
                                // 64: an unseen pixel's colour from off the silhouette (`fillsOffTheEdge`);
                                // 128: seen pixels read with Catmull-Rom (`resampling`), 2048: de-ringed (bit 11; bits 8-10 are the fill index)
    };

    struct PCVRDepthWarpHit {
        float2 uv;     // source render UV
        float w;       // inverse depth there, in the source eye
        float filled;  // 1 where the ray's true point was hidden and the far side fills in
    };

    // The scene's inverse depth at a source render UV: five bilinear taps, at
    // the point and two texels each way, averaged where they agree (a tent
    // about five texels wide: an 8-bit depth picture holds a slanted surface
    // as terraces a code apart, and under a few centimetres of shift each
    // terrace moved a pixel more than the next, a shimmer over text and
    // grids on every head movement, headset 2026-11-07), else the texel
    // under the point, so an edge stays a step at the texel boundary
    // (PCVREyeMeshBuilder takes the nearest depth of the four around a vertex
    // instead, which here would grow every near shape by a texel and drag a
    // rim of background with it).
    static float pcvrDepthWarpScene(float2 renderUV, constant PCVRDepthWarpUniforms &u,
                                    texture2d<float, access::sample> depth, sampler linear) {
        if (!(u.flags & 1u)) return u.planeInverse;
        float2 position = (u.depthRect.xy + saturate(renderUV) * u.depthRect.zw) * u.depthSize - 0.5;
        float2 low = u.depthTexels.xy, high = u.depthTexels.zw;
        const float2 offsets[5] = {float2(0, 0), float2(-2, 0), float2(2, 0), float2(0, -2), float2(0, 2)};
        float w[5];
        float nearest = -1e30, farthest = 1e30;
        for (int k = 0; k < 5; k++) {
            float2 p = clamp(position + offsets[k], low, high);
            float value = saturate(depth.sample(linear, (p + 0.5) / u.depthSize).r * u.depthDecode.x + u.depthDecode.y);
            w[k] = u.depthDecode.z + value * u.depthDecode.w;
            nearest = max(nearest, w[k]);
            farthest = min(farthest, w[k]);
        }
        if (nearest - farthest <= u.edge) return (2 * w[0] + w[1] + w[2] + w[3] + w[4]) / 6;
        uint2 q = uint2(clamp(round(position), low, high));
        float value = saturate(depth.read(q).r * u.depthDecode.x + u.depthDecode.y);
        return u.depthDecode.z + value * u.depthDecode.w;
    }

    // The target ray at inverse distance `lambda` (1/s along it): where that
    // point is in the source image (render UV) and its inverse depth in the
    // source eye. The point t + s D, scaled by 1/s, is D + t lambda; its
    // source depth over s is -(D + t lambda).z.
    static void pcvrDepthWarpRay(float3 D, float3 t, float lambda, float4 st, thread float2 &uv, thread float &rho) {
        float3 p = D + t * lambda;
        float z = max(-p.z, 1e-6);
        float2 tangent = p.xy / z;
        uv = float2((tangent.x - st.x) / (st.y - st.x), (st.z - tangent.y) / (st.z - st.w));
        rho = lambda / z;
    }

    static PCVRDepthWarpHit pcvrDepthWarpMarch(float2 targetRenderUV, constant PCVRDepthWarpUniforms &u,
                                               texture2d<float, access::sample> depth, sampler linear) {
        float4 tt = u.targetTangents;
        float3 d = float3(tt.x + targetRenderUV.x * (tt.y - tt.x), tt.z - targetRenderUV.y * (tt.z - tt.w), -1);
        float3 D = u.rotation * d;
        float3 t = u.translation.xyz;
        float lambdaMax = u.nearInverse;
        float2 uvNear, uvFar;
        float rhoNear, rhoFar;
        pcvrDepthWarpRay(D, t, lambdaMax, u.sourceTangents, uvNear, rhoNear);
        pcvrDepthWarpRay(D, t, 0, u.sourceTangents, uvFar, rhoFar);
        // About a depth texel a step along the ray's track across the picture,
        // and at least four: a ray near the axis of a forward or backward move
        // barely crosses the picture, but its inverse depth is not linear in
        // lambda there, and one step's two secants landed far off (a wrong
        // depth for the compositor, 2026-11-08). One step without a depth
        // map and without motion along the ray, where the secant is exact.
        uint n = 1;
        if (u.flags & 1u) {
            float2 track = (uvFar - uvNear) * u.depthRect.zw * u.depthSize;
            n = clamp(uint(ceil(length(track) / u.stepTexels)), min(4u, u.maxSteps), u.maxSteps);
        }
        float2 previousUV = uvNear;
        float previousW = pcvrDepthWarpScene(uvNear, u, depth, linear);
        float previousLambda = lambdaMax, previousF = rhoNear - previousW;
        // In a nearer surface's shadow, and the last thing seen before it: the
        // farther surface beside its edge, which fills what it uncovered.
        bool behind = previousF < 0;
        PCVRDepthWarpHit entry = {uvNear, previousW};
        for (uint k = 1; k <= n; k++) {
            float lambda = lambdaMax * (1 - float(k) / float(n));
            float2 uv;
            float rho;
            pcvrDepthWarpRay(D, t, lambda, u.sourceTangents, uv, rho);
            float w = pcvrDepthWarpScene(uv, u, depth, linear);
            float f = rho - w;
            if (!behind) {
                if (f < 0) {
                    bool slipped = false;
                    if (w - previousW > u.edge) {
                        // A nearer surface has come under the ray. Into its
                        // face, or behind its silhouette? Where the ray reaches
                        // that surface's depth within this step: on the surface
                        // it is a hit, past the edge the ray slipped behind.
                        float rhoPrevious = previousF + previousW;
                        float a = (rhoPrevious - w) / (rhoPrevious - rho);
                        if (a >= 0 && a <= 1) {
                            float lm = mix(previousLambda, lambda, a);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            if (abs(pcvrDepthWarpScene(uvm, u, depth, linear) - w) <= u.edge) return PCVRDepthWarpHit{uvm, rhom};
                        }
                        // Behind it. The step may be several texels: bisect
                        // for the far side's last sample before the edge, so
                        // what fills the uncovered strip is the far surface
                        // right beside the silhouette, not up to a step away
                        // (a staircase along every slanted edge, headset
                        // 2026-11-07).
                        float lo = previousLambda, hi = lambda;
                        float2 edgeUV = previousUV;
                        float edgeW = previousW;
                        for (int pass = 0; pass < 3; pass++) {
                            float lm = 0.5 * (lo + hi);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            float wm = pcvrDepthWarpScene(uvm, u, depth, linear);
                            if (wm - previousW > u.edge) { hi = lm; } else { lo = lm; edgeUV = uvm; edgeW = wm; }
                        }
                        entry = PCVRDepthWarpHit{edgeUV, edgeW};
                        behind = true;
                        slipped = true;
                    } else if (previousW - w > u.edge) {
                        // Off a nearer surface onto a farther one within this
                        // step, and behind the farther one by the sample. Not
                        // a crossing between the two: the ray hit the nearer
                        // surface's face before its edge, or cleared it and
                        // then either hit the farther surface or found that
                        // hidden. Bisect for the edge to tell them apart; a
                        // secant across the two surfaces smeared the nearer
                        // one's edge over the farther (headset, 2026-11-07).
                        float nearLambda = previousLambda, farLambda = lambda;
                        float2 nearUV = previousUV, farUV = uv;
                        float nearW = previousW, farW = w;
                        float nearRho = previousF + previousW, farRho = rho;
                        for (int pass = 0; pass < 3; pass++) {
                            float lm = 0.5 * (nearLambda + farLambda);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            float wm = pcvrDepthWarpScene(uvm, u, depth, linear);
                            if (previousW - wm > u.edge) { farLambda = lm; farUV = uvm; farW = wm; farRho = rhom; }
                            else { nearLambda = lm; nearUV = uvm; nearW = wm; nearRho = rhom; }
                        }
                        float nearF = nearRho - nearW;
                        if (nearF < 0) {
                            // Behind the nearer surface at its edge: into its face before it.
                            float a = previousF / (previousF - nearF);
                            float lh = mix(previousLambda, nearLambda, a);
                            PCVRDepthWarpHit hit = {float2(0), 0, 0};
                            pcvrDepthWarpRay(D, t, lh, u.sourceTangents, hit.uv, hit.w);
                            return hit;
                        }
                        float farF = farRho - farW;
                        // Past the edge and already behind the farther surface:
                        // its point is hidden. It fills from beside the edge.
                        if (farF < 0) return PCVRDepthWarpHit{farUV, farW, 1};
                        // Cleared the nearer surface in front of the farther
                        // one: the crossing is between the edge and this sample.
                        previousUV = farUV;
                        previousW = farW;
                        previousLambda = farLambda;
                        previousF = farF;
                    }
                    if (!slipped) {
                        // Through the surface: the crossing by the secant, three times.
                        for (int pass = 0; pass < 3; pass++) {
                            float a = previousF / (previousF - f);
                            float lm = mix(previousLambda, lambda, a);
                            float2 uvm;
                            float rhom;
                            pcvrDepthWarpRay(D, t, lm, u.sourceTangents, uvm, rhom);
                            float fm = rhom - pcvrDepthWarpScene(uvm, u, depth, linear);
                            if (pass == 2) return PCVRDepthWarpHit{uvm, rhom};
                            if (fm > 0) { previousLambda = lm; previousF = fm; } else { lambda = lm; f = fm; }
                        }
                    }
                }
            } else if (f >= 0 && (previousW - w > u.edge || w == 0)) {
                // Off the nearer surface's far edge and in front of what lies
                // farther (or at the sky, at infinity, which it can only be
                // level with). Only off an edge: a texel of codec noise inside
                // the nearer surface, read as farther, let the ray out, and the
                // next texel took it back behind with that noise as its entry,
                // so the uncovered strip beside the whiteboard filled with the
                // whiteboard's own text (headset, 2026-11-07).
                behind = false;
            } else if (f < 0 && previousW - w > u.edge) {
                // Off the silhouette onto a farther surface and already behind
                // it: the point the ray hits was hidden from the source eye.
                return PCVRDepthWarpHit{entry.uv, entry.w, 1};
            }
            previousUV = uv;
            previousW = w;
            previousLambda = lambda;
            previousF = f;
        }
        // Still in a shadow at infinity: the hit was hidden. Else the far end:
        // rotation only, the sky.
        return behind ? PCVRDepthWarpHit{entry.uv, entry.w, 1} : PCVRDepthWarpHit{previousUV, previousW, 0};
    }

    // Pass one, the warp map at a quarter of the output per axis: per texel,
    // how far the hit's render UV is from the texel's own (a displacement,
    // smooth across a surface however the foveation map bends under it) and
    // the hit's inverse depth.
    kernel void pcvrDepthWarpMap(texture2d<float, access::sample> depth [[texture(1)]],
                                 texture2d<float, access::write> map [[texture(3)]],
                                 constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                 sampler linear [[sampler(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        uint eyeWidth = map.get_width() / 2;
        uint eye = gid.x >= eyeWidth ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        float2 wire = (float2(gid.x - eye * eyeWidth, gid.y) + 0.5) / u.mapSize;
        float2 render = (u.flags & 4u) ? wire : pcvrRenderUV(wire, u.wireX, u.wireY);
        PCVRDepthWarpHit hit = pcvrDepthWarpMarch(render, u, depth, linear);
        map.write(float4(hit.uv - render, hit.w, hit.filled), gid);
    }

    // The hit for an output pixel at `wire` (its UV in the output, which is
    // where the warp map has it) whose target render UV is `render`: the map
    // interpolated where its four texels around the pixel agree in depth, the
    // march itself where they don't (a depth edge, where interpolating would
    // smear near into far).
    static PCVRDepthWarpHit pcvrDepthWarpLookup(float2 wire, float2 render, constant PCVRDepthWarpUniforms &u,
                                                texture2d<float, access::sample> depth,
                                                texture2d<float, access::sample> map, sampler linear) {
        float2 at = pcvrEyeTexel(wire, u.mapRect, u.mapBounds);
        float4 w4 = map.gather(linear, at, int2(0), component::z);
        float spread = max(max(w4.x, w4.y), max(w4.z, w4.w)) - min(min(w4.x, w4.y), min(w4.z, w4.w));
        if (spread > u.edge) return pcvrDepthWarpMarch(render, u, depth, linear);
        // The rim of a hidden strip, where some of the four were hidden and
        // some seen: marched per pixel, or the strip's outline steps by map
        // texels (four pixels; a staircase along the strip, headset 2026-11-08).
        float4 hidden = map.gather(linear, at, int2(0), component::w);
        if (max(max(hidden.x, hidden.y), max(hidden.z, hidden.w)) > 0.5
            && min(min(hidden.x, hidden.y), min(hidden.z, hidden.w)) < 0.5) {
            return pcvrDepthWarpMarch(render, u, depth, linear);
        }
        float4 m = map.sample(linear, at);
        return PCVRDepthWarpHit{render + m.xy, m.z, m.w};
    }

    // What a pixel no view saw shows: the farther surface beside the edge,
    // as the march found it, averaged over five taps along the edge (across
    // the ray's track), three depth texels apart. A single tap there, its
    // spot a little different for every pixel, drew the strip as a comb of
    // streaks of whatever texture the far surface had (the wall's grid under
    // the whiteboard on a vertical shake, headset 2026-11-08); a blend along
    // the edge reads as a smudge of the right colour. Only taps on that
    // farther surface count (its depth within an edge of the hit's): a tap on
    // the near object's rim put dark blobs of the whiteboard's frame into the
    // wall under it (headset, 2026-11-08).
    static float3 pcvrDepthWarpHoleColour(float2 render, PCVRDepthWarpHit hit, constant PCVRDepthWarpUniforms &u,
                                          texture2d<float, access::sample> source,
                                          texture2d<float, access::sample> depth, sampler linear) {
        float4 tt = u.targetTangents;
        float3 d = float3(tt.x + render.x * (tt.y - tt.x), tt.z - render.y * (tt.z - tt.w), -1);
        float3 D = u.rotation * d;
        float2 uvNear, uvFar;
        float rhoNear, rhoFar;
        pcvrDepthWarpRay(D, u.translation.xyz, u.nearInverse, u.sourceTangents, uvNear, rhoNear);
        pcvrDepthWarpRay(D, u.translation.xyz, 0, u.sourceTangents, uvFar, rhoFar);
        float2 texel = 1.0 / max(u.depthRect.zw * u.depthSize, float2(1));
        float2 track = (uvFar - uvNear) / texel;
        float2 along = length(track) > 1e-3 ? normalize(track) : float2(1, 0);
        float2 across = float2(-along.y, along.x) * texel * 1.5;
        // Off the silhouette onto the far surface, back along the ray's track:
        // a depth texel (the depth's edge can sit a texel out from the
        // picture's, the host takes each texel's nearest depth) and two
        // colour pixels (the picture's edge is antialiased). At the edge
        // itself the taps read the near object's rim, and the strip under a
        // board on a vertical move filled with its dark frame, 0.3 off the
        // wall it hid (PCVRWarpBenchTests, 2026-11-08).
        float2 pixel = float2(u.wireX.w, u.wireY.w) / max(u.sourceRect.zw * float2(source.get_width(), source.get_height()), float2(1));
        float2 back = (u.flags & 64u) ? -normalize(along * texel) * (max(texel.x, texel.y) + 2 * max(pixel.x, pixel.y)) : float2(0);
        float3 sum = float3(0);
        float count = 0;
        for (int k = -2; k <= 2; k++) {
            float2 p = saturate(hit.uv + back + across * float(k));
            if (abs(pcvrDepthWarpScene(p, u, depth, linear) - hit.w) > u.edge) continue;
            sum += source.sample(linear, pcvrEyeTexel(pcvrWireUV(p, u.wireX, u.wireY), u.sourceRect, u.sourceBounds)).rgb;
            count += 1;
        }
        // Nothing on the far surface back there (a sliver between two near
        // shapes): the far side at the edge, as before.
        if (count == 0) return source.sample(linear, pcvrEyeTexel(pcvrWireUV(saturate(hit.uv), u.wireX, u.wireY), u.sourceRect, u.sourceBounds)).rgb;
        return sum / count;
    }

    // Pass two, every output pixel (`pcvrDepthWarpLookup`). A pixel its own
    // eye could not see, or whose ray left that eye's frame, tries the fill
    // views in turn (the encoder's "Fills"): the first that saw it inside
    // its frame gives its colour.
    #define PCVR_FILL_FRAMES \(PCVRDepthWarper.fillFrames + 1)
    kernel void pcvrDepthWarpColour(texture2d<float, access::sample> source [[texture(0)]],
                                    texture2d<float, access::sample> depth [[texture(1)]],
                                    texture2d<float, access::write> output [[texture(2)]],
                                    texture2d<float, access::sample> map [[texture(3)]],
                                    array<texture2d<float, access::sample>, PCVR_FILL_FRAMES> fillColour [[texture(4)]],
                                    array<texture2d<float, access::sample>, PCVR_FILL_FRAMES> fillDepth [[texture(9)]],
                                    constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                    sampler linear [[sampler(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        uint eye = gid.x >= eyes[1].outputOrigin.x ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        uint2 local = gid - u.outputOrigin;
        if (local.x >= uint(u.outputSize.x) || local.y >= uint(u.outputSize.y)) return;
        float2 wire = (float2(local) + 0.5) / u.outputSize;
        float2 render = pcvrRenderUV(wire, u.wireX, u.wireY);
        PCVRDepthWarpHit hit = pcvrDepthWarpLookup(wire, render, u, depth, map, linear);
        bool outside = any(hit.uv < 0.0) || any(hit.uv > 1.0);
        if ((hit.filled > 0.5 || outside) && (u.flags & 8u)) {
            for (uint slot = 0; slot < 2; slot++) {
                constant PCVRDepthWarpUniforms &o = eyes[2 + 2 * eye + slot];
                if (!(o.flags & 32u)) break;
                uint index = min((o.flags >> 8) & 7u, uint(PCVR_FILL_FRAMES - 1));
                PCVRDepthWarpHit other = pcvrDepthWarpMarch(render, o, fillDepth[index], linear);
                if (other.filled > 0.5 || any(other.uv < 0.0) || any(other.uv > 1.0)) continue;
                if (u.flags & 2u) {
                    output.write(index == 0 ? float4(0, 1, 1, 1) : float4(1, 1, 0, 1), gid);
                    return;
                }
                float2 uv = pcvrEyeTexel(pcvrWireUV(other.uv, o.wireX, o.wireY), o.sourceRect, o.sourceBounds);
                output.write(float4(fillColour[index].sample(linear, uv).rgb, 1), gid);
                return;
            }
        }
        // Diagnostics: the filled pixels in magenta, to see where the picture
        // is made up rather than seen.
        if ((u.flags & 2u) && hit.filled > 0.5) {
            output.write(float4(1, 0, 1, 1), gid);
            return;
        }
        if (hit.filled > 0.5 && (u.flags & 1u)) {
            output.write(float4(pcvrDepthWarpHoleColour(render, hit, u, source, depth, linear), 1), gid);
            return;
        }
        float2 uv = pcvrEyeTexel(pcvrWireUV(saturate(hit.uv), u.wireX, u.wireY), u.sourceRect, u.sourceBounds);
        float3 colour = (u.flags & 128u) ? pcvrSampleCatmullRom(source, linear, uv, u.sourceBounds, u.flags & 2048u).rgb
                                         : source.sample(linear, uv).rgb;
        output.write(float4(colour, 1), gid);
    }

    // The warped depth, at the output's size, encoded as the source map is.
    kernel void pcvrDepthWarpDepth(texture2d<float, access::sample> depth [[texture(1)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                   sampler linear [[sampler(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        uint eyeWidth = output.get_width() / 2;
        uint eye = gid.x >= eyeWidth ? 1 : 0;
        constant PCVRDepthWarpUniforms &u = eyes[eye];
        float2 render = (float2(gid.x - eye * eyeWidth, gid.y) + 0.5) / float2(eyeWidth, output.get_height());
        PCVRDepthWarpHit hit = pcvrDepthWarpMarch(render, u, depth, linear);
        float value = u.depthDecode.w > 0 ? (hit.w - u.depthDecode.z) / u.depthDecode.w : 0;
        output.write(float4(saturate(value), 0, 0, 1), gid);
    }

    // Display views (a CompositorServices drawable): pass two as a fragment
    // shader over each view, writing colour and the hit's depth.
    #define PCVR_FAR_DEPTH 1e-6
    struct PCVRDepthWarpView {
        float4x4 projection;  // clip from the display eye, in the presenter's depth convention
        uint4 index;          // x: which uniforms and warp-map half
    };

    struct PCVRDepthWarpFullScreen {
        float4 position [[position]];
        float2 ndc;
    };

    vertex PCVRDepthWarpFullScreen pcvrDepthWarpVertex(uint vid [[vertex_id]]) {
        // One triangle covering the viewport; NDC +Y up. The NDC is
        // interpolated in logical space, so a rate map leaves it exact.
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        PCVRDepthWarpFullScreen out;
        out.position = float4(p, 0.0, 1.0);
        out.ndc = p;
        return out;
    }

    struct PCVRDepthWarpDisplayOut {
        float4 color [[color(0)]];
        float depth [[depth(any)]];
    };

    // Clip depth of a hit seen from the source eye of `u`, in the display eye.
    // Never depth 0 (reverse Z: at infinity) or beyond the far plane: the
    // visionOS compositor clips those pixels when it reprojects and shows
    // them black, as Oneiros found for its sky (2026-08-27); the sky here
    // went black the same way (2026-11-08). A hair inside the far plane
    // instead.
    static float pcvrDepthWarpClipDepth(PCVRDepthWarpHit hit, constant PCVRDepthWarpUniforms &u, float4x4 projection) {
        if (hit.w <= 1e-6) return PCVR_FAR_DEPTH;
        float4 st = u.sourceTangents;
        float2 tangent = float2(st.x + hit.uv.x * (st.y - st.x), st.z - hit.uv.y * (st.z - st.w));
        float3 inSource = float3(tangent, -1) / hit.w;
        float3 inDisplay = transpose(u.rotation) * (inSource - u.translation.xyz);
        float4 clip = projection * float4(inDisplay, 1);
        return clip.w > 1e-6 ? clamp(clip.z / clip.w, PCVR_FAR_DEPTH, 1.0) : PCVR_FAR_DEPTH;
    }

    static float3 pcvrDepthWarpSample(PCVRDepthWarpHit hit, constant PCVRDepthWarpUniforms &u,
                                      texture2d<float, access::sample> source, sampler linear) {
        float2 uv = pcvrEyeTexel(pcvrWireUV(saturate(hit.uv), u.wireX, u.wireY), u.sourceRect, u.sourceBounds);
        if (u.flags & 128u) return pcvrSampleCatmullRom(source, linear, uv, u.sourceBounds, u.flags & 2048u).rgb;
        return source.sample(linear, uv).rgb;
    }

    static PCVRDepthWarpDisplayOut pcvrDepthWarpDisplayPixel(float2 ndc, constant PCVRDepthWarpUniforms *eyes,
                                                             constant PCVRDepthWarpView &v,
                                                             texture2d<float, access::sample> source,
                                                             texture2d<float, access::sample> depth,
                                                             texture2d<float, access::sample> map, sampler linear) {
        constant PCVRDepthWarpUniforms &u = eyes[v.index.x];
        float2 target = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        PCVRDepthWarpHit hit = pcvrDepthWarpLookup(target, target, u, depth, map, linear);
        PCVRDepthWarpDisplayOut out;
        if (hit.filled > 0.5 && (u.flags & 8u)) {
            // Hidden from this eye's render view: the other eye, 6 cm to the
            // side, often saw it (what a sideways move uncovers beside a near
            // object is what the eye on that side sees past it). Its own hit,
            // if it saw one inside its frame, is the true content.
            constant PCVRDepthWarpUniforms &o = eyes[2 + v.index.x];
            PCVRDepthWarpHit other = pcvrDepthWarpMarch(target, o, depth, linear);
            bool inside = all(other.uv >= 0.0) && all(other.uv <= 1.0);
            if (other.filled < 0.5 && inside) {
                out.color = (u.flags & 2u) ? float4(0, 1, 1, 1) : float4(pcvrDepthWarpSample(other, o, source, linear), 1);
                out.depth = pcvrDepthWarpClipDepth(other, o, v.projection);
                return out;
            }
        }
        if ((u.flags & 2u) && hit.filled > 0.5) {
            out.color = float4(1, 0, 1, 1);
        } else {
            out.color = float4(pcvrDepthWarpSample(hit, u, source, linear), 1);
        }
        out.depth = pcvrDepthWarpClipDepth(hit, u, v.projection);
        return out;
    }

    fragment PCVRDepthWarpDisplayOut pcvrDepthWarpDisplay(PCVRDepthWarpFullScreen in [[stage_in]],
                                                          constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                                          constant PCVRDepthWarpView &v [[buffer(1)]],
                                                          texture2d<float, access::sample> source [[texture(0)]],
                                                          texture2d<float, access::sample> depth [[texture(1)]],
                                                          texture2d<float, access::sample> map [[texture(3)]],
                                                          sampler linear [[sampler(0)]]) {
        return pcvrDepthWarpDisplayPixel(in.ndc, eyes, v, source, depth, map, linear);
    }

    fragment float4 pcvrDepthWarpDisplayColour(PCVRDepthWarpFullScreen in [[stage_in]],
                                               constant PCVRDepthWarpUniforms *eyes [[buffer(0)]],
                                               constant PCVRDepthWarpView &v [[buffer(1)]],
                                               texture2d<float, access::sample> source [[texture(0)]],
                                               texture2d<float, access::sample> depth [[texture(1)]],
                                               texture2d<float, access::sample> map [[texture(3)]],
                                               sampler linear [[sampler(0)]]) {
        return pcvrDepthWarpDisplayPixel(in.ndc, eyes, v, source, depth, map, linear).color;
    }
    """ }
}
#endif
