#if FOVEATED_ENABLED
import Foundation
import Metal
import simd
import StreamWire

/// One eye of a decoded frame as a mesh, for a presenter whose renderer
/// projects world geometry itself (RealityKit): the vertices sit in world space
/// on the eye's render frustum, where the frame was rendered from, and their
/// texture coordinates read the decoded (possibly foveated) frame.
///
/// - **Depth.** With a depth map each vertex is pushed out along its ray to the
///   scene depth there, so the renderer gets parallax right as the head moves
///   away from the pose the frame was rendered at: near objects hold still when
///   prediction was off, and when a frame is shown twice. Without one every
///   vertex sits at `distance`, and only rotation is corrected.
/// - **Foveation.** The host's centre/edge map is linear within each of its
///   three regions per axis, so the grid puts a vertex line on each region
///   boundary (`axis(from:to:map:cells:)`); interpolation between vertices then
///   reproduces the map exactly. Cells are shared out by wire length, so the
///   full-density centre gets the most of them.
/// - **Timing.** `PCVREyeMeshBuilder` writes the vertices on the GPU into the
///   buffer RealityKit's `LowLevelMesh.replace(bufferIndex:using:)` hands out,
///   in the same command buffer that copies the frame into the
///   `LowLevelTexture`. RealityKit switches to both when that command buffer
///   completes, so geometry and picture change on the same rendered frame. The
///   presenter's entities never move: everything per frame is in the vertices.
///   (Before, the texture changed when its copy completed while the entity
///   pose and texture coordinates changed at once on the CPU: for a frame or so
///   the picture was drawn at the next frame's pose and through its foveation
///   map, seen as flicker when the gaze moved and a jolt on fast turns.)
nonisolated enum PCVREyeMesh {
    /// Vertices are `position` (float3) then `uv0` (float2), packed.
    static let vertexStride = 20

    /// The grid's size in cells; vertices are one more each way.
    struct Grid: Equatable, Sendable {
        var columns: Int
        var rows: Int

        init(columns: Int, rows: Int) {
            self.columns = max(columns, 3)
            self.rows = max(rows, 3)
        }

        var vertexCount: Int { (columns + 1) * (rows + 1) }

        /// The cells inside the frustum when the outermost ring is a skirt.
        var inner: Grid { Grid(columns: columns - 2, rows: rows - 2) }

        /// Two triangles per cell, row 0 at the top, wound to face the eye.
        var indices: [UInt32] {
            var result: [UInt32] = []
            result.reserveCapacity(columns * rows * 6)
            let stride = UInt32(columns + 1)
            for j in 0..<UInt32(rows) {
                for i in 0..<UInt32(columns) {
                    let topLeft = j * stride + i, topRight = topLeft + 1
                    let bottomLeft = topLeft + stride, bottomRight = bottomLeft + 1
                    result += [bottomLeft, bottomRight, topRight, bottomLeft, topRight, topLeft]
                }
            }
            return result
        }
    }

    /// Where one axis's vertex lines go: three segments in render coordinates
    /// (`ends`, start to end, the foveation map's breakpoints between) and the
    /// cumulative cell count at each end (`cells`, 0 to the grid's size).
    /// Within a segment lines are evenly spaced; an empty segment has no cells.
    struct Axis: Equatable, Sendable {
        var ends: SIMD4<Float>
        var cells: SIMD4<Float>

        /// Line `index`'s render coordinate (the kernel's `pcvrGridCoordinate`).
        func coordinate(_ index: Int) -> Float {
            let x = Float(index)
            for k in 0..<3 where x <= cells[k + 1] || k == 2 {
                let span = cells[k + 1] - cells[k]
                return span > 0 ? ends[k] + (x - cells[k]) / span * (ends[k + 1] - ends[k]) : ends[k]
            }
            return ends[3]
        }
    }

    /// One axis from render coordinate `start` to `end` (0...1, top-left
    /// origin), over `cells` cells, with a line on each of `map`'s breakpoints
    /// inside the range. Cells go to the segments in proportion to how much of
    /// the wire image they cover, at least one to any segment that isn't empty.
    /// How an axis's cells are shared between its segments.
    enum Share: Sendable {
        /// By wire length: most cells in the full-density centre, where the
        /// picture has most detail. Enough for a flat or plane-placed picture.
        case wire
        /// By render length (angle, near enough): every part of the view gets
        /// cells of the same size, for a mesh displaced by depth, whose depth
        /// edges are as sharp in the periphery as in the centre.
        case render
    }

    static func axis(from start: Float, to end: Float, map: CentreEdgeAxisMapping?, cells: Int,
                     share: Share = .wire) -> Axis {
        let start = min(max(start, 0), 1), end = min(max(end, start), 1)
        let constants = map?.constants ?? PCVRFoveation.identity
        let ends = [start, min(max(constants.x, start), end), min(max(constants.y, start), end), end]
        let wire = ends.map { map?.wireCoordinate(forRender: $0) ?? $0 }
        let positive = (0..<3).filter { ends[$0 + 1] - ends[$0] > 1e-6 }
        var counts = [0, 0, 0]
        if !positive.isEmpty {
            let total = max(cells, positive.count)
            let measure = share == .wire ? wire : ends
            let lengths = positive.map { max(measure[$0 + 1] - measure[$0], 0) }
            let sum = lengths.reduce(0, +)
            for (n, k) in positive.enumerated() {
                let share = sum > 0 ? lengths[n] / sum : 1 / Float(positive.count)
                counts[k] = max(1, Int((Float(total) * share).rounded()))
            }
            // Rounding can miss the total by a cell or two: settle it on the
            // largest segment, never taking one below a cell.
            while counts.reduce(0, +) != total {
                let largest = positive.max { counts[$0] < counts[$1] }!
                if counts.reduce(0, +) < total {
                    counts[largest] += 1
                } else if counts[largest] > 1 {
                    counts[largest] -= 1
                } else {
                    break
                }
            }
        }
        let cumulative = [0, counts[0], counts[0] + counts[1], counts[0] + counts[1] + counts[2]].map(Float.init)
        return Axis(ends: SIMD4(ends[0], ends[1], ends[2], ends[3]),
                    cells: SIMD4(cumulative[0], cumulative[1], cumulative[2], cumulative[3]))
    }
}

/// A depth map that goes with a decoded frame: both eyes side by side like the
/// frame, but unwarped (render UVs address it directly) and usually much
/// smaller. The value in its red channel is inverse depth (NATIVE_V3_PROTOCOL.md
/// §4.8 kind 1): 1 at `near`, 0 at `far`, which may be infinite.
nonisolated struct PCVRDepthMap: @unchecked Sendable {
    let texture: any MTLTexture
    let near: Float
    let far: Float
    /// `raw * valueScale + valueOffset` is the encoded value: a decoder's
    /// limited-range luma has its 16...235 stretched back to 0...1.
    var valueScale: Float = 1
    var valueOffset: Float = 0

    /// The kernel's `depthDecode`: value scale and offset, 1/far, 1/near - 1/far.
    var decode: SIMD4<Float> {
        let inverseFar: Float = far.isFinite ? 1 / far : 0
        return SIMD4(valueScale, valueOffset, inverseFar, 1 / near - inverseFar)
    }

    /// Depth at an encoded value, in metres (infinity at 0 with an infinite far).
    func depth(atValue value: Float) -> Float {
        let d = decode
        return 1 / (d.z + min(max(value, 0), 1) * d.w)
    }
}

/// Writes `PCVREyeMesh` vertices on the GPU.
///
/// Thread-safety: one thread at a time (the presenter's frame loop).
nonisolated final class PCVREyeMeshBuilder: @unchecked Sendable {
    /// One eye's placement and sampling for one frame.
    struct Eye: Equatable, Sendable {
        /// The eye's render pose, in the mesh's own space.
        var meshFromEye: simd_float4x4
        /// The eye's render frustum: tangents left, right, up, down (left and down negative).
        var tangents: SIMD4<Float>
        var columns: PCVREyeMesh.Axis
        var rows: PCVREyeMesh.Axis
        /// The frame's centre/edge constants for this eye (identity when unwarped).
        var wireX: SIMD4<Float> = PCVRFoveation.identity
        var wireY: SIMD4<Float> = PCVRFoveation.identity
        /// This eye's place in the frame texture (u, v origin, u, v scale) and
        /// the clamp that keeps taps half a texel inside it.
        var textureRect: SIMD4<Float>
        var textureBounds: SIMD4<Float>
        /// Where vertices sit without depth, and the farthest they go with it.
        var distance: Float
        /// Texture v runs top-down (true) or bottom-up.
        var flipV: Bool
        /// How far past the frustum, in render units per axis (fractions of its
        /// width and height), the grid's outermost lines go, reading the edge
        /// texels: the picture smeared outward, so a head turn faster than the
        /// prediction shows a stretched edge instead of the room. Zero for
        /// none; then `columns` and `rows` cover the frustum with every cell.
        /// With a skirt they cover it with all but the outermost ring, so
        /// build them for two cells fewer (`PCVREyeMesh.Grid.inner`).
        var skirt: SIMD2<Float> = .zero
    }

    /// Mirrors `PCVREyeMeshUniforms`.
    private struct Uniforms {
        var meshFromEye: simd_float4x4
        var tangents: SIMD4<Float>
        var columnEnds: SIMD4<Float>
        var columnCells: SIMD4<Float>
        var rowEnds: SIMD4<Float>
        var rowCells: SIMD4<Float>
        var wireX: SIMD4<Float>
        var wireY: SIMD4<Float>
        var textureRect: SIMD4<Float>
        var textureBounds: SIMD4<Float>
        var depthRect: SIMD4<Float>
        var depthTexels: SIMD4<Float>
        var depthDecode: SIMD4<Float>
        var depthSize: SIMD2<Float>
        var distance: Float
        var flags: UInt32
        var columns: UInt32
        var rows: UInt32
        var skirt: SIMD2<Float>
    }

    let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let noDepth: any MTLTexture

    init(device: any MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let function = library.makeFunction(name: "pcvrEyeMesh") else {
            throw PCVRReceiverError.resourceCreationFailed("eye mesh kernel")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        let empty = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        empty.usage = .shaderRead
        guard let noDepth = device.makeTexture(descriptor: empty) else {
            throw PCVRReceiverError.resourceCreationFailed("eye mesh placeholder depth")
        }
        self.noDepth = noDepth
    }

    /// Encodes `eye`'s vertices into `buffer` (at least `grid.vertexCount` x 20
    /// bytes), displaced by `depth` (eye `eyeIndex` of it) when given.
    func encode(_ eye: Eye, eyeIndex: Int, depth: PCVRDepthMap?, grid: PCVREyeMesh.Grid,
                into buffer: any MTLBuffer, commandBuffer: any MTLCommandBuffer) throws {
        guard buffer.length >= grid.vertexCount * PCVREyeMesh.vertexStride else {
            throw PCVRReceiverError.resourceCreationFailed("eye mesh buffer too small")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PCVRReceiverError.resourceCreationFailed("eye mesh encoder")
        }
        encoder.label = "PCVR eye mesh"
        let depthTexture = depth?.texture ?? noDepth
        var uniforms = Uniforms(
            meshFromEye: eye.meshFromEye, tangents: eye.tangents,
            columnEnds: eye.columns.ends, columnCells: eye.columns.cells,
            rowEnds: eye.rows.ends, rowCells: eye.rows.cells,
            wireX: eye.wireX, wireY: eye.wireY,
            textureRect: eye.textureRect, textureBounds: eye.textureBounds,
            depthRect: PCVRReceiver.eyeRect(eye: eyeIndex, texture: depthTexture),
            depthTexels: Self.eyeTexels(eye: eyeIndex, texture: depthTexture),
            depthDecode: depth?.decode ?? .zero,
            depthSize: SIMD2(Float(depthTexture.width), Float(depthTexture.height)),
            distance: eye.distance,
            flags: (eye.flipV ? 1 : 0) | (depth != nil ? 2 : 0) | (eye.skirt != .zero ? 4 : 0),
            columns: UInt32(grid.columns), rows: UInt32(grid.rows), skirt: eye.skirt)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setTexture(depthTexture, index: 0)
        let width = min(pipeline.threadExecutionWidth, 32)
        let threads = MTLSize(width: width, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, 8)), depth: 1)
        let total = MTLSize(width: grid.columns + 1, height: grid.rows + 1, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (total.width + threads.width - 1) / threads.width,
                    height: (total.height + threads.height - 1) / threads.height, depth: 1),
            threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }

    /// One eye's texels of a side-by-side texture, inclusive: first x, y, last x, y.
    static func eyeTexels(eye: Int, texture: any MTLTexture) -> SIMD4<Float> {
        let width = texture.width / 2
        return SIMD4(Float(eye * width), 0, Float(eye * width + width - 1), Float(texture.height - 1))
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    \(PCVRFoveationShader.source)

    struct PCVREyeMeshUniforms {
        float4x4 meshFromEye;
        float4 tangents;
        float4 columnEnds;
        float4 columnCells;
        float4 rowEnds;
        float4 rowCells;
        float4 wireX;
        float4 wireY;
        float4 textureRect;
        float4 textureBounds;
        float4 depthRect;
        float4 depthTexels;
        float4 depthDecode;
        float2 depthSize;
        float distance;
        uint flags;
        uint columns;
        uint rows;
        float2 skirt;
    };


    struct PCVRMeshVertex {
        packed_float3 position;
        packed_float2 uv;
    };

    // PCVREyeMesh.Axis.coordinate: line i's render coordinate.
    static float pcvrGridCoordinate(uint i, float4 ends, float4 cells) {
        float x = float(i);
        for (int k = 0; k < 3; k++) {
            if (x <= cells[k + 1] || k == 2) {
                float span = cells[k + 1] - cells[k];
                return span > 0 ? ends[k] + (x - cells[k]) / span * (ends[k + 1] - ends[k]) : ends[k];
            }
        }
        return ends[3];
    }

    // One axis's line: inside the frustum from the axis, or with a skirt the
    // outermost two lines past it (the axis then covers lines 1...n-1).
    static float pcvrSkirtedCoordinate(uint i, uint n, bool skirted, float skirt, float4 ends, float4 cells) {
        if (!skirted) return pcvrGridCoordinate(i, ends, cells);
        if (i == 0) return -skirt;
        if (i == n) return 1 + skirt;
        return pcvrGridCoordinate(i - 1, ends, cells);
    }

    kernel void pcvrEyeMesh(device PCVRMeshVertex *vertices [[buffer(0)]],
                            constant PCVREyeMeshUniforms &u [[buffer(1)]],
                            texture2d<float, access::read> depth [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x > u.columns || gid.y > u.rows) return;
        bool skirted = (u.flags & 4u) != 0;
        float2 render = float2(pcvrSkirtedCoordinate(gid.x, u.columns, skirted, u.skirt.x, u.columnEnds, u.columnCells),
                               pcvrSkirtedCoordinate(gid.y, u.rows, skirted, u.skirt.y, u.rowEnds, u.rowCells));
        float2 tangent = float2(u.tangents.x + render.x * (u.tangents.y - u.tangents.x),
                                u.tangents.z - render.y * (u.tangents.z - u.tangents.w));
        float z = u.distance;
        if (u.flags & 2u) {
            // The nearest of the four depth texels around the vertex: a near
            // object's silhouette takes the vertices it touches, so its edge
            // moves with it instead of being torn into the background behind
            // it. Only those four: any wider, and one wrong near value drags
            // more of the picture at the viewer (the 4x4 of the first cut,
            // headset 2026-11-07, warped visibly).
            float nearest = 0;
            int2 base = int2(floor((u.depthRect.xy + render * u.depthRect.zw) * u.depthSize - 0.5));
            int2 low = int2(u.depthTexels.xy), high = int2(u.depthTexels.zw);
            for (int dy = 0; dy <= 1; dy++) {
                for (int dx = 0; dx <= 1; dx++) {
                    uint2 p = uint2(clamp(base + int2(dx, dy), low, high));
                    float value = saturate(depth.read(p).r * u.depthDecode.x + u.depthDecode.y);
                    nearest = max(nearest, u.depthDecode.z + value * u.depthDecode.w);
                }
            }
            if (nearest * u.distance > 1) z = 1 / nearest;
        }
        float4 position = u.meshFromEye * float4(tangent * z, -z, 1);
        float2 wire = pcvrWireUV(render, u.wireX, u.wireY);
        float2 uv = pcvrEyeTexel(wire, u.textureRect, u.textureBounds);
        if (!(u.flags & 1u)) uv.y = 1 - uv.y;
        uint index = gid.y * (u.columns + 1) + gid.x;
        vertices[index].position = packed_float3(position.xyz);
        vertices[index].uv = packed_float2(uv);
    }
    """
}

extension PCVREyeMeshBuilder.Eye {
    /// Eye `eye` of `frame`: its render pose and frustum, its foveation map,
    /// and its half of the frame texture (the other half when `swapped`).
    /// `window` (signed tangents, inside the frustum) is how much of the
    /// frustum to cover; `meshFromWorld` places the mesh's own space.
    /// `skirt`: how far past each frustum edge to smear the picture, in
    /// tangent (0 for none; `grid` then keeps its outermost ring for it).
    init(frame: PCVRDecodedFrame, eye: Int, window: SIMD4<Float>? = nil, grid: PCVREyeMesh.Grid,
         meshFromWorld: simd_float4x4 = matrix_identity_float4x4, distance: Float, flipV: Bool, swapped: Bool = false,
         skirt: Float = 0, share: PCVREyeMesh.Share = .wire) {
        let view = frame.renderPose.eyes[eye]
        let t = view.fieldOfView.tangents
        let w = window ?? t
        let width = t.y - t.x, height = t.z - t.w
        let maps = frame.foveation.map { eye == 0 ? $0.mapping.left : $0.mapping.right }
        let wire = frame.wireConstants(eye: eye)
        let texture = frame.texture
        let half: Float = (eye == 0) != swapped ? 0 : 0.5
        let halfU = 0.5 / Float(texture.width), halfV = 0.5 / Float(texture.height)
        let cells = skirt > 0 ? grid.inner : grid
        self.init(meshFromEye: meshFromWorld * view.pose.matrix, tangents: t,
                  columns: PCVREyeMesh.axis(from: (w.x - t.x) / width, to: (w.y - t.x) / width,
                                            map: maps?.x, cells: cells.columns, share: share),
                  rows: PCVREyeMesh.axis(from: (t.z - w.z) / height, to: (t.z - w.w) / height,
                                         map: maps?.y, cells: cells.rows, share: share),
                  wireX: wire.x, wireY: wire.y,
                  textureRect: SIMD4(half, 0, 0.5, 1),
                  textureBounds: SIMD4(half + halfU, halfV, half + 0.5 - halfU, 1 - halfV),
                  distance: distance, flipV: flipV,
                  skirt: skirt > 0 ? SIMD2(skirt / width, skirt / height) : .zero)
    }
}
#endif
