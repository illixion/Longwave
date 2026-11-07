import Metal
import StreamWire
import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
/// `PCVREyeMeshBuilder` on the GPU against a CPU reference: where each vertex
/// lands in world space (on the frustum at `distance`, or pushed out to the
/// depth map), and where it reads the (foveated) frame.
final class PCVREyeMeshTests: XCTestCase {
    static let shape = CentreEdgeWarp(centreSizeX: 0.3, centreSizeY: 0.3, edgeRatioX: 3.5, edgeRatioY: 3.5)
    static let renderEye = PixelSize(width: 400, height: 320)
    static let fov = PCVRFieldOfView(tangentLeft: -1.7666, tangentRight: 1.02, tangentUp: 1.02, tangentDown: -1.2158)

    private var device: (any MTLDevice)!
    private var queue: (any MTLCommandQueue)!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func frame(wire: PixelSize, foveation: PCVRFoveation?, pose: PCVRPose) throws -> PCVRDecodedFrame {
        let eyes = PCVRStereo(left: PCVREyeView(pose: pose, fieldOfView: Self.fov),
                              right: PCVREyeView(pose: pose * PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                                       position: [0.064, 0, 0]),
                                                 fieldOfView: PCVRFieldOfView(tangentLeft: -1.02, tangentRight: 1.7666,
                                                                              tangentUp: 1.02, tangentDown: -1.2158)))
        return PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1,
                                texture: try texture(.bgra8Unorm, width: 2 * Int(wire.width), height: Int(wire.height)),
                                renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0, eyes: eyes),
                                foveation: foveation, arrivalTime: 0)
    }

    private func run(_ eye: PCVREyeMeshBuilder.Eye, eyeIndex: Int, depth: PCVRDepthMap?,
                     grid: PCVREyeMesh.Grid) throws -> [Float] {
        let builder = try PCVREyeMeshBuilder(device: device)
        let buffer = try XCTUnwrap(device.makeBuffer(length: grid.vertexCount * PCVREyeMesh.vertexStride,
                                                     options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try builder.encode(eye, eyeIndex: eyeIndex, depth: depth, grid: grid, into: buffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        let floats = buffer.contents().bindMemory(to: Float.self, capacity: grid.vertexCount * 5)
        return Array(UnsafeBufferPointer(start: floats, count: grid.vertexCount * 5))
    }

    private static let centres: [NormalizedPoint] = [
        .centre, NormalizedPoint(x: 0.1, y: 0.8), NormalizedPoint(x: 0, y: 1), NormalizedPoint(x: 0.62, y: 0.41),
    ]

    func testAxisPutsALineOnEveryBreakpointAndSharesCellsByWireLength() throws {
        for centre in Self.centres {
            let map = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.3, edgeRatio: 3.5, centre: centre.x))
            for (start, end) in [(Float(0), Float(1)), (0.2, 0.9), (0.5, 0.55)] {
                let axis = PCVREyeMesh.axis(from: start, to: end, map: map, cells: 64)
                XCTAssertEqual(axis.cells[0], 0)
                XCTAssertEqual(axis.cells[3], 64)
                XCTAssertEqual(axis.ends[0], start)
                XCTAssertEqual(axis.ends[3], end)
                let breakpoints = [map.constants.x, map.constants.y].map { min(max($0, start), end) }
                XCTAssertEqual(axis.ends[1], breakpoints[0])
                XCTAssertEqual(axis.ends[2], breakpoints[1])
                for k in 0..<3 {
                    let length = axis.ends[k + 1] - axis.ends[k]
                    // A segment with any length gets a cell; an empty one none.
                    XCTAssertEqual(axis.cells[k + 1] - axis.cells[k] > 0, length > 1e-6, "segment \(k) \(axis)")
                    // Its first and last lines are its ends.
                    XCTAssertEqual(axis.coordinate(Int(axis.cells[k])), axis.ends[k], accuracy: 1e-6)
                    XCTAssertEqual(axis.coordinate(Int(axis.cells[k + 1])), axis.ends[k + 1], accuracy: 1e-6)
                }
                for i in 1...64 { XCTAssertGreaterThanOrEqual(axis.coordinate(i), axis.coordinate(i - 1)) }
            }
            // Over the whole eye, the full-density centre (0.3 of the render
            // width, 0.6 of the wire) gets about 60% of the cells.
            let whole = PCVREyeMesh.axis(from: 0, to: 1, map: map, cells: 100)
            if whole.ends[1] > 0, whole.ends[2] < 1 {
                XCTAssertEqual(whole.cells[2] - whole.cells[1], 60, accuracy: 2)
            }
        }
        // No map: one even segment.
        let plain = PCVREyeMesh.axis(from: 0, to: 1, map: nil, cells: 10)
        XCTAssertEqual(plain.cells, SIMD4(0, 0, 10, 10))
        XCTAssertEqual(plain.coordinate(5), 0.5, accuracy: 1e-6)
    }

    /// Without depth every vertex is on the render frustum at `distance`, seen
    /// from the eye's world pose, and reads the wire image where the map says.
    func testVerticesSitOnTheFrustumAndReadThroughTheMap() throws {
        let wire = try XCTUnwrap(Self.shape.wireSize(forRender: Self.renderEye, alignment: 16))
        let parameters = FoveationParameters(epoch: 2, warp: .centreEdge(Self.shape))
        let pose = PCVRPose(rotation: simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.1))),
                            position: [0.3, 1.6, -0.2])
        let grid = PCVREyeMesh.Grid(columns: 40, rows: 32)
        for centre in Self.centres {
            let foveation = try XCTUnwrap(PCVRFoveation(
                parameters: parameters,
                frame: FoveationSideData(parameterEpoch: 2, leftCentre: centre, rightCentre: NormalizedPoint(x: 0.4, y: 0.6)),
                renderEye: Self.renderEye))
            let decoded = try frame(wire: wire, foveation: foveation, pose: pose)
            for eyeIndex in 0..<2 {
                for flipV in [true, false] {
                    let eye = PCVREyeMeshBuilder.Eye(frame: decoded, eye: eyeIndex, grid: grid, distance: 50, flipV: flipV)
                    let out = try run(eye, eyeIndex: eyeIndex, depth: nil, grid: grid)
                    let view = decoded.renderPose.eyes[eyeIndex]
                    let map = eyeIndex == 0 ? foveation.mapping.left : foveation.mapping.right
                    let t = view.fieldOfView.tangents
                    let texture = decoded.texture
                    let half: Float = eyeIndex == 0 ? 0 : 0.5
                    var worstPosition: Float = 0, worstUV: Float = 0
                    for j in 0...grid.rows {
                        for i in 0...grid.columns {
                            let ru = eye.columns.coordinate(i), rv = eye.rows.coordinate(j)
                            let local = SIMD3(t.x + ru * (t.y - t.x), t.z - rv * (t.z - t.w), -1) * 50
                            let world = view.pose.transformPoint(local)
                            let wireUV = try XCTUnwrap(map.wireUV(forRender: NormalizedPoint(x: ru, y: rv)))
                            let u = min(max(half + 0.5 * wireUV.x, half + 0.5 / Float(texture.width)),
                                        half + 0.5 - 0.5 / Float(texture.width))
                            var v = min(max(wireUV.y, 0.5 / Float(texture.height)), 1 - 0.5 / Float(texture.height))
                            if !flipV { v = 1 - v }
                            let k = (j * (grid.columns + 1) + i) * 5
                            worstPosition = max(worstPosition, simd_distance(SIMD3(out[k], out[k + 1], out[k + 2]), world))
                            worstUV = max(worstUV, abs(out[k + 3] - u) * Float(texture.width),
                                          abs(out[k + 4] - v) * Float(texture.height))
                        }
                    }
                    // Millimetres at 50 m: float rounding, nothing more.
                    XCTAssertLessThan(worstPosition, 0.005, "eye \(eyeIndex) centre \(centre)")
                    XCTAssertLessThan(worstUV, 0.01, "wire texels, eye \(eyeIndex) centre \(centre)")
                }
            }
        }
    }

    /// With depth, each vertex moves along its ray to the nearest depth around
    /// it; values at or past the far end stay at `distance`.
    func testDepthPushesVerticesToTheNearestSceneDepthAroundThem() throws {
        let decoded = try frame(wire: Self.renderEye, foveation: nil, pose: .identity)
        // Both eyes side by side, 32x16 each. Left eye: 2 m everywhere except a
        // 0.5 m block in columns 8..<16, rows 4..<12. Right eye: 0 (infinitely far).
        let width = 32, height = 16
        let map = PCVRDepthMap(texture: try texture(.r8Unorm, width: 2 * width, height: height), near: 0.25, far: .infinity)
        func value(atDepth z: Float) -> UInt8 { UInt8((0.25 / z * 255).rounded()) }
        var pixels = [UInt8](repeating: 0, count: 2 * width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * 2 * width + x] = (8..<16).contains(x) && (4..<12).contains(y) ? value(atDepth: 0.5) : value(atDepth: 2)
            }
        }
        pixels.withUnsafeBytes {
            map.texture.replace(region: MTLRegionMake2D(0, 0, 2 * width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 2 * width)
        }
        let grid = PCVREyeMesh.Grid(columns: 32, rows: 16)
        for eyeIndex in 0..<2 {
            let eye = PCVREyeMeshBuilder.Eye(frame: decoded, eye: eyeIndex, grid: grid, distance: 50, flipV: true)
            let out = try run(eye, eyeIndex: eyeIndex, depth: map, grid: grid)
            let origin = decoded.renderPose.eyes[eyeIndex].pose.position
            for j in 0...grid.rows {
                for i in 0...grid.columns {
                    let k = (j * (grid.columns + 1) + i) * 5
                    let z = origin.z - out[k + 2]  // planar depth along -z
                    if eyeIndex == 1 {
                        XCTAssertEqual(z, 50, accuracy: 1e-3, "far stays at distance")
                        continue
                    }
                    // Vertex (i, j) sits on texel corner (i, j); it reads the
                    // four texels around it, i-1...i, so it is near when any
                    // of them is in the block.
                    let ru = eye.columns.coordinate(i), rv = eye.rows.coordinate(j)
                    let touchesBlock = (i - 1...i).contains { (8..<16).contains($0) }
                        && (j - 1...j).contains { (4..<12).contains($0) }
                    let expected = map.depth(atValue: Float(value(atDepth: touchesBlock ? 0.5 : 2)) / 255)
                    XCTAssertEqual(z, expected, accuracy: 1e-3, "vertex \(i),\(j)")
                    // On its own ray: the tangent is unchanged by depth.
                    let t = decoded.renderPose.eyes[0].fieldOfView.tangents
                    XCTAssertEqual((out[k] - origin.x) / z, t.x + ru * (t.y - t.x), accuracy: 1e-4)
                }
            }
        }
    }

    func testGridIndicesCoverEveryCellFacingTheEye() {
        let grid = PCVREyeMesh.Grid(columns: 4, rows: 3)
        let indices = grid.indices
        XCTAssertEqual(indices.count, 4 * 3 * 6)
        XCTAssertEqual(Set(indices).count, grid.vertexCount)
        // First cell: bottom-left, bottom-right, top-right (counter-clockwise seen from the eye with row 0 on top).
        XCTAssertEqual(Array(indices.prefix(6)), [5, 6, 1, 5, 1, 0])
    }
}
#endif
