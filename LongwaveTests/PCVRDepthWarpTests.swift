import Metal
import StreamWire
import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
/// `PCVRDepthWarper` on the GPU against the closed forms it must agree with: a
/// rotation is the rotation homography, a flat scene the plane homography,
/// and a near shape over a far one uncovers the far one, filled, not smeared.
final class PCVRDepthWarpTests: XCTestCase {
    static let fov = PCVRFieldOfView(tangentLeft: -1.7666, tangentRight: 1.02, tangentUp: 1.02, tangentDown: -1.2158)
    /// One eye of the colour picture; the depth map is 8 times coarser.
    static let eyeWidth = 512, eyeHeight = 256
    static let depthWidth = 64, depthHeight = 32

    private var device: (any MTLDevice)!
    private var queue: (any MTLCommandQueue)!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int, write: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = write ? [.shaderRead, .shaderWrite] : .shaderRead
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Both eyes side by side, each pixel's red and green its own eye-local UV
    /// (at its centre), so a bilinear tap anywhere reads back the UV it took.
    private func gradientFrame(foveation: PCVRFoveation?, pose: PCVRPose) throws -> PCVRDecodedFrame {
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = Float16((Float(x % Self.eyeWidth) + 0.5) / Float(Self.eyeWidth))
                pixels[i + 1] = Float16((Float(y) + 0.5) / Float(height))
                pixels[i + 2] = Float16(x >= Self.eyeWidth ? 1 : 0)
                pixels[i + 3] = 1
            }
        }
        pixels.withUnsafeBytes {
            colour.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                           bytesPerRow: width * 8)
        }
        let right = pose * PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.064, 0, 0])
        let eyes = PCVRStereo(left: PCVREyeView(pose: pose, fieldOfView: Self.fov),
                              right: PCVREyeView(pose: right, fieldOfView: Self.fov))
        return PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1, texture: colour,
                                renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0, eyes: eyes),
                                foveation: foveation, arrivalTime: 0)
    }

    /// An 8-bit inverse-depth map (near 0.25 m, far infinite) from a depth per
    /// left-eye texel; the right eye is flat at the first texel's depth.
    private func depthMap(_ depth: (Int, Int) -> Float) throws -> PCVRDepthMap {
        let width = Self.depthWidth, height = Self.depthHeight
        let map = PCVRDepthMap(texture: try texture(.r8Unorm, width: 2 * width, height: height), near: 0.25, far: .infinity)
        var pixels = [UInt8](repeating: 0, count: 2 * width * height)
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let z = x < width ? depth(x, y) : depth(0, 0)
                pixels[y * 2 * width + x] = UInt8((0.25 / z * 255).rounded())
            }
        }
        pixels.withUnsafeBytes {
            map.texture.replace(region: MTLRegionMake2D(0, 0, 2 * width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 2 * width)
        }
        return map
    }

    private struct Output {
        var colour: [Float16]
        var depth: [Float16]
        let width = 2 * PCVRDepthWarpTests.eyeWidth
        /// The source UV the output pixel read (its red and green).
        func sourceUV(eye: Int, x: Int, y: Int) -> SIMD2<Float> {
            let i = (y * width + eye * PCVRDepthWarpTests.eyeWidth + x) * 4
            return SIMD2(Float(colour[i]), Float(colour[i + 1]))
        }
        func warpedDepth(eye: Int, x: Int, y: Int) -> Float {
            let value = Float(depth[y * 2 * PCVRDepthWarpTests.depthWidth + eye * PCVRDepthWarpTests.depthWidth + x])
            return value > 0 ? 0.25 / value : .infinity
        }
    }

    private func warp(_ frame: PCVRDecodedFrame, depth: PCVRDepthMap?, targets: PCVRStereo<PCVRPose>,
                      planeDistance: Float = 2) throws -> Output {
        let warper = try PCVRDepthWarper(device: device)
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height, write: true)
        let warped = try texture(.r16Float, width: 2 * Self.depthWidth, height: Self.depthHeight, write: true)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, targets: targets, planeDistance: planeDistance, into: colour,
                          warpedDepth: warped, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            colour.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var depths = [Float16](repeating: 0, count: 2 * Self.depthWidth * Self.depthHeight)
        depths.withUnsafeMutableBytes {
            warped.getBytes($0.baseAddress!, bytesPerRow: 2 * Self.depthWidth * 2,
                            from: MTLRegionMake2D(0, 0, 2 * Self.depthWidth, Self.depthHeight), mipmapLevel: 0)
        }
        return Output(colour: pixels, depth: depths)
    }

    /// Where a homography says the output pixel reads the source, as a render UV.
    private func expectedUV(x: Int, y: Int, through homography: simd_float3x3) -> SIMD2<Float>? {
        let u = (Float(x) + 0.5) / Float(Self.eyeWidth), v = (Float(y) + 0.5) / Float(Self.eyeHeight)
        guard let ndc = PCVRReprojection.sourceNDC(forDisplayNDC: SIMD2(2 * u - 1, 1 - 2 * v), through: homography) else {
            return nil
        }
        return SIMD2((ndc.x + 1) / 2, (1 - ndc.y) / 2)
    }

    /// Checks every eighth pixel whose expected source UV is well inside the
    /// picture against `homography`, to within `texels` colour texels.
    private func assertMatches(_ out: Output, eye: Int, homography: simd_float3x3, texels: Float,
                               file: StaticString = #filePath, line: UInt = #line) {
        var worst: Float = 0, checked = 0
        for y in stride(from: 3, to: Self.eyeHeight, by: 8) {
            for x in stride(from: 3, to: Self.eyeWidth, by: 8) {
                guard let expected = expectedUV(x: x, y: y, through: homography),
                      expected.x > 0.03, expected.x < 0.97, expected.y > 0.03, expected.y < 0.97 else { continue }
                let got = out.sourceUV(eye: eye, x: x, y: y)
                worst = max(worst, abs(got.x - expected.x) * Float(Self.eyeWidth), abs(got.y - expected.y) * Float(Self.eyeHeight))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 500, file: file, line: line)
        XCTAssertLessThan(worst, texels, "eye \(eye): worst error in texels", file: file, line: line)
    }

    func testARotationIsTheRotationHomography() throws {
        let pose = PCVRPose(rotation: simd_quatf(angle: 0.3, axis: [0, 1, 0]), position: [0.2, 1.5, -0.4])
        let frame = try gradientFrame(foveation: nil, pose: pose)
        let depth = try depthMap { _, _ in 2 }
        let turn = PCVRPose(rotation: simd_quatf(angle: 0.05, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.1))), position: .zero)
        let targets = frame.renderPose.eyes.map { $0.pose * turn }
        let out = try warp(frame, depth: depth, targets: targets)
        for eye in 0..<2 {
            let render = frame.renderPose.eyes[eye]
            let display = PCVREyeView(pose: targets[eye], fieldOfView: Self.fov)
            assertMatches(out, eye: eye, homography: PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .rotation),
                          texels: 0.6)
        }
        // The warped depth is the scene's, wherever the ray lands.
        for y in 0..<Self.depthHeight { XCTAssertEqual(out.warpedDepth(eye: 0, x: 10, y: y), 2, accuracy: 0.02) }
    }

    func testAFlatSceneIsThePlaneHomographyWithAndWithoutADepthMap() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { _, _ in 2 }
        let move = PCVRPose(rotation: simd_quatf(angle: -0.02, axis: [1, 0, 0]), position: [0.02, -0.01, 0.005])
        let targets = frame.renderPose.eyes.map { $0.pose * move }
        for map in [depth, nil] {
            let out = try warp(frame, depth: map, targets: targets, planeDistance: 2)
            for eye in 0..<2 {
                let render = frame.renderPose.eyes[eye]
                let display = PCVREyeView(pose: targets[eye], fieldOfView: Self.fov)
                let h = PCVRReprojection.sourceFromDisplay(render: render, display: display,
                                                           mode: .rotationAndTranslation(planeDistance: 2))
                assertMatches(out, eye: eye, homography: h, texels: 0.6)
            }
        }
    }

    /// Through a foveation map, standing still, every output pixel reads its
    /// own wire position: the shader's inverse map undoes its forward map.
    func testStandingStillThroughTheFoveationMapIsTheIdentity() throws {
        let shape = CentreEdgeWarp(centreSizeX: 0.3, centreSizeY: 0.3, edgeRatioX: 3.5, edgeRatioY: 3.5)
        let parameters = FoveationParameters(epoch: 2, warp: .centreEdge(shape))
        let foveation = try XCTUnwrap(PCVRFoveation(
            parameters: parameters,
            frame: FoveationSideData(parameterEpoch: 2, leftCentre: NormalizedPoint(x: 0.62, y: 0.41),
                                     rightCentre: NormalizedPoint(x: 0.1, y: 0.8)),
            renderEye: PixelSize(width: 1600, height: 1200)))
        let frame = try gradientFrame(foveation: foveation, pose: .identity)
        let out = try warp(frame, depth: nil, targets: frame.renderPose.eyes.map(\.pose))
        var worst: Float = 0
        for eye in 0..<2 {
            for y in stride(from: 1, to: Self.eyeHeight - 1, by: 5) {
                for x in stride(from: 1, to: Self.eyeWidth - 1, by: 5) {
                    let got = out.sourceUV(eye: eye, x: x, y: y)
                    worst = max(worst, abs(got.x * Float(Self.eyeWidth) - Float(x) - 0.5),
                                abs(got.y * Float(Self.eyeHeight) - Float(y) - 0.5))
                }
            }
        }
        XCTAssertLessThan(worst, 0.1, "wire texels")
    }

    /// Left eye: a block at 0.5 m over a background at 2 m, the eye moved
    /// 10 cm to the right. The block and the background each shift by their
    /// own parallax; the strip the block uncovers shows the background from
    /// beside its edge, at the background's depth, and nothing in between.
    func testANearShapeUncoversTheBackgroundInsteadOfStretchingIt() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        // Texels 16..<32 of 64 across (render u 0.25..<0.5), rows 8..<24 of 32 (v 0.25..<0.75).
        let depth = try depthMap { x, y in (16..<32).contains(x) && (8..<24).contains(y) ? 0.5 : 2 }
        let shift: Float = 0.1
        let targets = frame.renderPose.eyes.map { $0.pose * PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                                     position: [shift, 0, 0]) }
        let out = try warp(frame, depth: depth, targets: targets)
        let t = Self.fov.tangents, width = t.y - t.x
        let nearShift = shift / 0.5 / width, farShift = shift / 2 / width   // render u
        // In the target view the block spans u 0.25-nearShift ..< 0.5-nearShift;
        // the background right of it is visible from the source only from
        // u + farShift >= 0.5.
        let blockStart = 0.25 - nearShift, blockEnd = 0.5 - nearShift, uncoveredEnd = 0.5 - farShift
        let margin = 1.2 / Float(Self.depthWidth)   // a depth texel either side of each edge
        let texel = 1 / Float(Self.eyeWidth)
        var fg = 0, bg = 0, filled = 0
        for y in stride(from: 70, to: 186, by: 4) {   // v 0.27...0.73, inside the block's rows
            let v = (Float(y) + 0.5) / Float(Self.eyeHeight)
            for x in stride(from: 2, to: Self.eyeWidth - 2, by: 3) {
                let u = (Float(x) + 0.5) / Float(Self.eyeWidth)
                let got = out.sourceUV(eye: 0, x: x, y: y)
                XCTAssertEqual(got.y, v, accuracy: 1.5 * texel, "row \(y) column \(x)")
                if u > blockStart + margin, u < blockEnd - margin {
                    XCTAssertEqual(got.x, u + nearShift, accuracy: 1.5 * texel, "block at \(x),\(y)")
                    fg += 1
                } else if u > blockEnd + margin, u < uncoveredEnd - margin {
                    // Filled from the background just right of the block's edge.
                    XCTAssertGreaterThan(got.x, 0.5 - texel, "uncovered at \(x),\(y)")
                    XCTAssertLessThan(got.x, 0.5 + 2 * margin, "uncovered at \(x),\(y)")
                    filled += 1
                } else if (u > 0.03 && u < blockStart - margin) || (u > uncoveredEnd + margin && u + farShift < 0.97) {
                    XCTAssertEqual(got.x, u + farShift, accuracy: 1.5 * texel, "background at \(x),\(y)")
                    bg += 1
                }
            }
        }
        XCTAssertGreaterThan(fg, 500)
        XCTAssertGreaterThan(filled, 50)   // a strip 9 pixels wide, every third column, 29 rows
        XCTAssertGreaterThan(bg, 500)
        // The warped depth: near across the block, far elsewhere, the strip included.
        try checkWarpedDepth(out, blockStart: blockStart, blockEnd: blockEnd, margin: margin, near: 0.5, far: 2)
    }

    private func checkWarpedDepth(_ out: Output, blockStart: Float, blockEnd: Float, margin: Float, near: Float,
                                  far: Float) throws {
        for x in 0..<Self.depthWidth {
            let u = (Float(x) + 0.5) / Float(Self.depthWidth)
            let z = out.warpedDepth(eye: 0, x: x, y: 16)
            if u > blockStart + margin, u < blockEnd - margin {
                XCTAssertEqual(z, near, accuracy: 0.01 * near, "block depth at texel \(x)")
            } else if abs(u - blockStart) > margin, abs(u - blockEnd) > margin {
                XCTAssertEqual(z, far, accuracy: 0.03 * far, "background depth at texel \(x)")
            }
        }
    }

    /// A block at 0.5 m just in front of a background at 0.55 m, the eye
    /// moved 10 cm right: rays that reach the block's depth before its edge
    /// hit its face and show it; rays that clear it show the background where
    /// they hit it. A secant across the two surfaces put the block's edge
    /// pixels over the background instead.
    func testARayGrazingANearEdgeHitsItsFaceOrClearsIt() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { x, y in (16..<32).contains(x) && (8..<24).contains(y) ? 0.5 : 0.55 }
        let shift: Float = 0.1
        let targets = frame.renderPose.eyes.map { $0.pose * PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                                     position: [shift, 0, 0]) }
        let out = try warp(frame, depth: depth, targets: targets)
        let t = Self.fov.tangents, width = t.y - t.x
        let nearShift = shift / 0.5 / width, farShift = shift / 0.55 / width
        let blockStart = 0.25 - nearShift, blockEnd = 0.5 - nearShift, uncoveredEnd = 0.5 - farShift
        let margin = 1.2 / Float(Self.depthWidth)
        let texel = 1 / Float(Self.eyeWidth)
        var fg = 0, bg = 0
        for y in stride(from: 70, to: 186, by: 4) {
            let v = (Float(y) + 0.5) / Float(Self.eyeHeight)
            for x in stride(from: 2, to: Self.eyeWidth - 2, by: 3) {
                let u = (Float(x) + 0.5) / Float(Self.eyeWidth)
                let got = out.sourceUV(eye: 0, x: x, y: y)
                XCTAssertEqual(got.y, v, accuracy: 1.5 * texel, "row \(y) column \(x)")
                if u > blockStart + margin, u < blockEnd - margin {
                    XCTAssertEqual(got.x, u + nearShift, accuracy: 1.5 * texel, "block at \(x),\(y)")
                    fg += 1
                } else if (u > 0.03 && u < blockStart - margin) || (u > uncoveredEnd + margin && u + farShift < 0.97) {
                    XCTAssertEqual(got.x, u + farShift, accuracy: 1.5 * texel, "background at \(x),\(y)")
                    bg += 1
                }
            }
        }
        XCTAssertGreaterThan(fg, 500)
        XCTAssertGreaterThan(bg, 500)
        try checkWarpedDepth(out, blockStart: blockStart, blockEnd: blockEnd, margin: margin, near: 0.5, far: 0.55)
    }

    /// Straight into display views (CompositorServices' path): each view's
    /// rays from its own pose and narrower frustum read the plane homography's
    /// texel, and each pixel's depth is the plane's, through the view's
    /// reverse-Z projection.
    func testDisplayViewsGetThePlaneHomographyAndItsDepth() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { _, _ in 2 }
        // Back 10 cm and aside 2 cm: every point of the plane 2 m ahead of the
        // render eye is 2.1 m ahead of the display eye.
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.02, 0, 0.1])
        let displayFOV = PCVRFieldOfView(tangentLeft: -1.5, tangentRight: 0.9, tangentUp: 0.9, tangentDown: -1.0)
        let near: Float = 0.1
        // Reverse Z, infinite far: depth = near / distance ahead.
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        let width = Self.eyeWidth, height = Self.eyeHeight
        var colours: [any MTLTexture] = [], depths: [any MTLTexture] = []
        var targets: [PCVRReceiverTarget] = []
        for eye in 0..<2 {
            let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                            height: height, mipmapped: false)
            colourDescriptor.usage = [.renderTarget, .shaderRead]
            colourDescriptor.storageMode = .shared
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width,
                                                                           height: height, mipmapped: false)
            depthDescriptor.usage = .renderTarget
            depthDescriptor.storageMode = .private
            let colour = try XCTUnwrap(device.makeTexture(descriptor: colourDescriptor))
            let depthTexture = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
            colours.append(colour)
            depths.append(depthTexture)
            targets.append(PCVRReceiverTarget(
                eye: eye, colorTexture: colour, depthTexture: depthTexture, depthClearValue: 0,
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1),
                display: PCVREyeView(pose: frame.renderPose.eyes[eye].pose * move, fieldOfView: displayFOV),
                displayProjection: projection))
        }
        let warper = try PCVRDepthWarper(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, views: targets, planeDistance: 2, commandBuffer: commandBuffer)
        let readback = try XCTUnwrap(device.makeBuffer(length: 2 * width * height * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        for eye in 0..<2 {
            blit.copy(from: depths[eye], sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback,
                      destinationOffset: eye * width * height * 4, destinationBytesPerRow: width * 4,
                      destinationBytesPerImage: width * height * 4)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        let depthValues = readback.contents().bindMemory(to: Float.self, capacity: 2 * width * height)
        for eye in 0..<2 {
            var pixels = [Float16](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                colours[eye].getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height),
                                      mipmapLevel: 0)
            }
            let h = PCVRReprojection.sourceFromDisplay(render: frame.renderPose.eyes[eye], display: targets[eye].display,
                                                       mode: .rotationAndTranslation(planeDistance: 2))
            var worst: Float = 0, worstDepth: Float = 0, checked = 0
            for y in stride(from: 3, to: height, by: 8) {
                for x in stride(from: 3, to: width, by: 8) {
                    guard let expected = expectedUV(x: x, y: y, through: h),
                          expected.x > 0.03, expected.x < 0.97, expected.y > 0.03, expected.y < 0.97 else { continue }
                    let i = (y * width + x) * 4
                    let got = SIMD2(Float(pixels[i]), Float(pixels[i + 1]))
                    worst = max(worst, abs(got.x - expected.x) * Float(width), abs(got.y - expected.y) * Float(height))
                    worstDepth = max(worstDepth, abs(depthValues[eye * width * height + y * width + x] - near / 2.1))
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 500)
            XCTAssertLessThan(worst, 0.6, "eye \(eye): worst error in texels")
            XCTAssertLessThan(worstDepth, near / 2.1 * 0.01, "eye \(eye): worst depth error")
        }
    }
}
#endif
