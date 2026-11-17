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
    private func gradientFrame(foveation: PCVRFoveation?, pose: PCVRPose,
                               blue: ((Int, Int) -> Float)? = nil) throws -> PCVRDecodedFrame {
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height)
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = Float16((Float(x % Self.eyeWidth) + 0.5) / Float(Self.eyeWidth))
                pixels[i + 1] = Float16((Float(y) + 0.5) / Float(height))
                pixels[i + 2] = Float16(x >= Self.eyeWidth ? 1 : blue?(x, y) ?? 0)
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
                      planeDistance: Float = 2, resampling: PCVRDepthWarper.Resampling? = nil,
                      motion: PCVRMotionShift? = nil, refinesEdges: Bool = false) throws -> Output {
        let warper = try PCVRDepthWarper(device: device)
        warper.refinesEdges = refinesEdges
        if let resampling { warper.resampling = resampling }
        // These scenes' right eyes are flat (`depthMap`), not what that eye saw.
        warper.fillsFromOtherEye = false
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height, write: true)
        let warped = try texture(.r16Float, width: 2 * Self.depthWidth, height: Self.depthHeight, write: true)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, targets: targets, planeDistance: planeDistance, into: colour,
                          warpedDepth: warped, motion: motion, commandBuffer: commandBuffer)
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

    /// Every filter reads a linear ramp back exactly, so the geometry is the
    /// same whichever one the warper uses.
    func testEveryResamplingKeepsTheRotationHomography() throws {
        let pose = PCVRPose(rotation: simd_quatf(angle: 0.3, axis: [0, 1, 0]), position: [0.2, 1.5, -0.4])
        let frame = try gradientFrame(foveation: nil, pose: pose)
        let depth = try depthMap { _, _ in 2 }
        let turn = PCVRPose(rotation: simd_quatf(angle: 0.05, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.1))), position: .zero)
        let targets = frame.renderPose.eyes.map { $0.pose * turn }
        for resampling in PCVRDepthWarper.Resampling.allCases {
            let out = try warp(frame, depth: depth, targets: targets, resampling: resampling)
            let render = frame.renderPose.eyes[0]
            let display = PCVREyeView(pose: targets[0], fieldOfView: Self.fov)
            assertMatches(out, eye: 0, homography: PCVRReprojection.sourceFromDisplay(render: render, display: display, mode: .rotation),
                          texels: 0.6)
        }
    }

    /// One-texel stripes moved by a quarter texel: bilinear averages
    /// neighbouring texels and loses contrast, Catmull-Rom keeps most of it, and
    /// the de-ringed form never leaves the stripes' own range.
    func testCatmullRomKeepsStripesSharperThanBilinear() throws {
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height)
        var pixels = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { for c in 0..<3 { pixels[(y * width + x) * 4 + c] = x % 2 == 0 ? 0.1 : 0.9 } } }
        pixels.withUnsafeBytes {
            colour.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        let striped = try gradientFrame(foveation: nil, pose: .identity)
        let frame = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1, texture: colour, renderPose: striped.renderPose,
                                     foveation: nil, arrivalTime: 0)
        // About a quarter of a texel near the centre of the view.
        let turn = PCVRPose(rotation: simd_quatf(angle: 0.0013, axis: [0, 1, 0]), position: .zero)
        let targets = frame.renderPose.eyes.map { $0.pose * turn }
        func contrast(_ resampling: PCVRDepthWarper.Resampling) throws -> (mean: Float, low: Float, high: Float) {
            let out = try warp(frame, depth: nil, targets: targets, resampling: resampling)
            var swing: Float = 0, low: Float = 1, high: Float = 0, rows = 0
            for y in stride(from: 100, to: 156, by: 4) {
                var lo: Float = 1, hi: Float = 0
                for x in 200..<312 {
                    let v = Float(out.colour[(y * width + x) * 4])
                    lo = min(lo, v); hi = max(hi, v)
                }
                swing += hi - lo; low = min(low, lo); high = max(high, hi); rows += 1
            }
            return (swing / Float(rows), low, high)
        }
        let bilinear = try contrast(.bilinear), sharp = try contrast(.catmullRom), deRinged = try contrast(.catmullRomDeRinged)
        XCTAssertGreaterThan(sharp.mean, bilinear.mean + 0.05)
        XCTAssertGreaterThan(deRinged.mean, bilinear.mean + 0.05)
        XCTAssertGreaterThanOrEqual(deRinged.low, 0.1 - 0.002)
        XCTAssertLessThanOrEqual(deRinged.high, 0.9 + 0.002)
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
    /// Bilinear reads the texel back exactly. Catmull-Rom's nine-tap sum can
    /// land a hair under it and the half-float output then drops one step
    /// (1/2048 of UV here, 0.125 texel on this fixture's ramp): rounding, not
    /// a misplaced read.
    func testStandingStillThroughTheFoveationMapIsTheIdentity() throws {
        let shape = CentreEdgeWarp(centreSizeX: 0.3, centreSizeY: 0.3, edgeRatioX: 3.5, edgeRatioY: 3.5)
        let parameters = FoveationParameters(epoch: 2, warp: .centreEdge(shape))
        let foveation = try XCTUnwrap(PCVRFoveation(
            parameters: parameters,
            frame: FoveationSideData(parameterEpoch: 2, leftCentre: NormalizedPoint(x: 0.62, y: 0.41),
                                     rightCentre: NormalizedPoint(x: 0.1, y: 0.8)),
            renderEye: PixelSize(width: 1600, height: 1200)))
        let frame = try gradientFrame(foveation: foveation, pose: .identity)
        for resampling in PCVRDepthWarper.Resampling.allCases {
            let out = try warp(frame, depth: nil, targets: frame.renderPose.eyes.map(\.pose), resampling: resampling)
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
            let halfStep = Float(Self.eyeHeight) / 2048 + 0.001
            XCTAssertLessThan(worst, resampling == .bilinear ? 0.1 : halfStep, "\(resampling.rawValue): wire texels")
        }
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
                    // Filled from the background beside the block's edge, a
                    // depth texel and two pixels clear of it (at the edge the
                    // pixels can carry the block's rim, `fillsOffTheEdge`).
                    let clear = 1 / Float(Self.depthWidth) + 2 * texel
                    XCTAssertGreaterThan(got.x, 0.5 - texel, "uncovered at \(x),\(y)")
                    XCTAssertLessThan(got.x, 0.5 + 2 * margin + clear, "uncovered at \(x),\(y)")
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

    /// The host takes each depth texel's nearest depth, so a near shape's
    /// depth reaches up to a texel past its outline. Unrefined, the
    /// background in that rim moves with the shape; refined by the colour
    /// (`refinesEdges`), it stays with the background.
    func testRefinedEdgesKeepTheBackgroundRimOffANearShape() throws {
        // The block's colour (blue) from pixel 131 to 252 across and 67 to 188 down:
        // mid-texel at both ends (texels are 8 pixels), so depth texels 16...31
        // and 8...23 are near, each holding three to five pixels of background.
        let inside = { (x: Int, y: Int) -> Bool in (131..<253).contains(x) && (67..<189).contains(y) }
        let frame = try gradientFrame(foveation: nil, pose: .identity, blue: { inside($0, $1) ? 1 : 0 })
        let depth = try depthMap { x, y in (16..<32).contains(x) && (8..<24).contains(y) ? 0.5 : 2 }
        let shift: Float = -0.1   // the eye moves left: the block slides right, over the background beside it
        let targets = frame.renderPose.eyes.map { $0.pose * PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                                     position: [shift, 0, 0]) }
        let t = Self.fov.tangents, width = t.y - t.x
        let nearShift = shift / 0.5 / width, farShift = shift / 2 / width
        let texel = 1 / Float(Self.eyeWidth)
        func dragged(_ out: Output) -> (rim: Int, block: Int) {
            var rim = 0, block = 0
            for y in stride(from: 90, to: 166, by: 2) {
                for x in 2..<(Self.eyeWidth - 2) {
                    let u = (Float(x) + 0.5) / Float(Self.eyeWidth)
                    let got = out.sourceUV(eye: 0, x: x, y: y)
                    let i = (y * out.width + x) * 4
                    let isBlock = Float(out.colour[i + 2]) > 0.5
                    let movedNear = abs(got.x - (u + nearShift)) < 1.5 * texel
                    if movedNear, isBlock { block += 1 }
                    // Background shown where the block's shift put it: the rim, dragged.
                    // Background from the rim (source pixels 128 to 130) shown where the
                    // block's shift put it: dragged. (A fill can land at the block's
                    // shift too, from farther off the edge; not counted.)
                    let sourceColumn = Int(got.x * Float(Self.eyeWidth))
                    if movedNear, !isBlock, (126..<131).contains(sourceColumn) { rim += 1 }
                }
            }
            return (rim, block)
        }
        let plain = dragged(try warp(frame, depth: depth, targets: targets))
        let refined = dragged(try warp(frame, depth: depth, targets: targets, refinesEdges: true))
        XCTAssertGreaterThan(plain.rim, 80, "the unrefined warp should drag the rim (the case under test)")
        XCTAssertLessThan(refined.rim, plain.rim / 10, "refined \(refined.rim) vs plain \(plain.rim)")
        XCTAssertGreaterThan(refined.block, plain.block * 9 / 10, "the block itself still moves as near")
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

    /// What a sideways move uncovers beside a near object is filled from the
    /// other eye, which saw it, rather than smeared from beside the edge.
    func testUncoveredBackgroundIsFilledFromTheOtherEye() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        // A slab 20 cm wide, 0.5 m ahead, over a wall 4 m ahead, seen from
        // each eye (left at x = 0, right at x = 6.4 cm): a depth per texel by
        // casting its ray.
        let width = Self.depthWidth, height = Self.depthHeight
        let map = PCVRDepthMap(texture: try texture(.r8Unorm, width: 2 * width, height: height), near: 0.25, far: .infinity)
        var pixels = [UInt8](repeating: 0, count: 2 * width * height)
        let fov = Self.fov
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let eye = x / width, eyeX: Float = eye == 0 ? 0 : 0.064
                let u = (Float(x % width) + 0.5) / Float(width)
                let tangent = fov.tangents.x + u * (fov.tangents.y - fov.tangents.x)
                let atSlab = eyeX + tangent * 0.5
                let z: Float = abs(atSlab) < 0.1 ? 0.5 : 4
                pixels[y * 2 * width + x] = UInt8((0.25 / z * 255).rounded())
            }
        }
        pixels.withUnsafeBytes {
            map.texture.replace(region: MTLRegionMake2D(0, 0, 2 * width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 2 * width)
        }
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.03, 0, 0])
        func filled(otherEye: Bool) throws -> (magenta: Int, cyan: Int) {
            let warper = try PCVRDepthWarper(device: device)
            warper.tintsFills = true
            warper.fillsFromOtherEye = otherEye
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.eyeWidth,
                                                                      height: Self.eyeHeight, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let colour = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let target = PCVRReceiverTarget(
                eye: 0, colorTexture: colour,
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(Self.eyeWidth), height: Double(Self.eyeHeight),
                                      znear: 0, zfar: 1),
                display: PCVREyeView(pose: frame.renderPose.eyes.left.pose * move, fieldOfView: fov))
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try warper.encode(frame: frame, depth: map, views: [target], planeDistance: 2, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            var out = [Float16](repeating: 0, count: Self.eyeWidth * Self.eyeHeight * 4)
            out.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: Self.eyeWidth * 8,
                                from: MTLRegionMake2D(0, 0, Self.eyeWidth, Self.eyeHeight), mipmapLevel: 0)
            }
            var magenta = 0, cyan = 0
            for p in 0..<(Self.eyeWidth * Self.eyeHeight) {
                let r = out[p * 4], g = out[p * 4 + 1], b = out[p * 4 + 2]
                if r == 1, g == 0, b == 1 { magenta += 1 }
                if r == 0, g == 1, b == 1 { cyan += 1 }
            }
            return (magenta, cyan)
        }
        let alone = try filled(otherEye: false)
        let helped = try filled(otherEye: true)
        // The strip uncovered right of the slab: about 3 cm x (1/0.5 - 1/4)
        // = 0.0525 in tangent, some 9 pixels a row.
        XCTAssertGreaterThan(alone.magenta, 4 * Self.eyeHeight)
        XCTAssertEqual(alone.cyan, 0)
        XCTAssertGreaterThan(helped.cyan, alone.magenta * 3 / 4, "most of the strip from the other eye")
        XCTAssertLessThan(helped.magenta, alone.magenta / 4)
    }
    /// A slab 20 cm wide, 0.5 m ahead, over a wall 4 m ahead, as each eye of
    /// a frame whose left eye is at `leftX` saw it (the right eye 6.4 cm
    /// further right): a depth per texel by casting its ray.
    private func slabDepth(leftX: Float) throws -> PCVRDepthMap {
        let width = Self.depthWidth, height = Self.depthHeight
        let map = PCVRDepthMap(texture: try texture(.r8Unorm, width: 2 * width, height: height), near: 0.25, far: .infinity)
        var pixels = [UInt8](repeating: 0, count: 2 * width * height)
        let t = Self.fov.tangents
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let eyeX = leftX + (x / width == 0 ? 0 : 0.064)
                let u = (Float(x % width) + 0.5) / Float(width)
                let atSlab = eyeX + (t.x + u * (t.y - t.x)) * 0.5
                let z: Float = abs(atSlab) < 0.1 ? 0.5 : 4
                pixels[y * 2 * width + x] = UInt8((0.25 / z * 255).rounded())
            }
        }
        pixels.withUnsafeBytes {
            map.texture.replace(region: MTLRegionMake2D(0, 0, 2 * width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 2 * width)
        }
        return map
    }

    /// The overlay's path (`encode(frame:...into:fills:)`): the strip a move
    /// uncovers beside the slab is filled from the frame's other eye, or, with
    /// that off, from an earlier frame rendered from where the eye is now,
    /// and only magenta where nothing saw it.
    func testTheComputeWarpFillsFromTheOtherEyeAndFromEarlierFrames() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try slabDepth(leftX: 0)
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.03, 0, 0])
        let targets = frame.renderPose.eyes.map { $0.pose * move }
        // An earlier frame, rendered 3 cm to the right: from the target itself.
        let earlierFrame = try gradientFrame(foveation: nil, pose: move)
        let earlier = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 0, texture: earlierFrame.texture,
                                       renderPose: PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: -0.05,
                                                                  eyes: earlierFrame.renderPose.eyes),
                                       arrivalTime: 0)
        let earlierDepth = try slabDepth(leftX: 0.03)
        func tints(otherEye: Bool, fills: [PCVRDepthWarper.FillSource]) throws -> (magenta: Int, cyan: Int, yellow: Int) {
            let warper = try PCVRDepthWarper(device: device)
            warper.tintsFills = true
            warper.fillsFromOtherEye = otherEye
            let width = 2 * Self.eyeWidth, height = Self.eyeHeight
            let colour = try texture(.rgba16Float, width: width, height: height, write: true)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try warper.encode(frame: frame, depth: depth, targets: targets, planeDistance: 2, into: colour, fills: fills,
                              commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            var out = [Float16](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes {
                colour.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            var magenta = 0, cyan = 0, yellow = 0
            // The left eye only: the right eye's strip is the same story mirrored.
            for y in 0..<height {
                for x in 0..<Self.eyeWidth {
                    let i = (y * width + x) * 4
                    let r = out[i], g = out[i + 1], b = out[i + 2]
                    if r == 1, g == 0, b == 1 { magenta += 1 }
                    if r == 0, g == 1, b == 1 { cyan += 1 }
                    if r == 1, g == 1, b == 0 { yellow += 1 }
                }
            }
            return (magenta, cyan, yellow)
        }
        let alone = try tints(otherEye: false, fills: [])
        XCTAssertGreaterThan(alone.magenta, 4 * Self.eyeHeight)
        XCTAssertEqual(alone.cyan + alone.yellow, 0)
        let otherEye = try tints(otherEye: true, fills: [])
        XCTAssertGreaterThan(otherEye.cyan, alone.magenta * 3 / 4, "most of the strip from the other eye")
        XCTAssertLessThan(otherEye.magenta, alone.magenta / 4)
        let history = try tints(otherEye: false, fills: [.init(frame: earlier, depth: earlierDepth)])
        XCTAssertGreaterThan(history.yellow, alone.magenta * 3 / 4, "most of the strip from the earlier frame")
        XCTAssertLessThan(history.magenta, alone.magenta / 4)
        XCTAssertEqual(history.cyan, 0)
    }

    /// The display path (Shell A's) fills like the compute path: the strip a
    /// move uncovers beside the slab from the other eye, or with that off from
    /// an earlier frame rendered from where the eye is now. It used to try the
    /// other eye only, and smeared the rest from beside the edge.
    func testTheDisplayWarpFillsFromTheOtherEyeAndFromEarlierFrames() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try slabDepth(leftX: 0)
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.03, 0, 0])
        let earlierFrame = try gradientFrame(foveation: nil, pose: move)
        let earlier = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 0, texture: earlierFrame.texture,
                                       renderPose: PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: -0.05,
                                                                  eyes: earlierFrame.renderPose.eyes),
                                       arrivalTime: 0)
        let earlierDepth = try slabDepth(leftX: 0.03)
        let near: Float = 0.1
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        let width = Self.eyeWidth, height = Self.eyeHeight
        func tints(otherEye: Bool, fills: [PCVRDepthWarper.FillSource]) throws -> (magenta: Int, cyan: Int, yellow: Int) {
            var colours: [any MTLTexture] = []
            var targets: [PCVRReceiverTarget] = []
            for eye in 0..<2 {
                let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                c.usage = [.renderTarget, .shaderRead]
                c.storageMode = .shared
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
                d.usage = .renderTarget
                d.storageMode = .private
                let colour = try XCTUnwrap(device.makeTexture(descriptor: c))
                colours.append(colour)
                targets.append(PCVRReceiverTarget(
                    eye: eye, colorTexture: colour, depthTexture: try XCTUnwrap(device.makeTexture(descriptor: d)),
                    depthClearValue: 0,
                    viewport: MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1),
                    display: PCVREyeView(pose: frame.renderPose.eyes[eye].pose * move, fieldOfView: Self.fov),
                    displayProjection: projection))
            }
            let warper = try PCVRDepthWarper(device: device)
            warper.tintsFills = true
            warper.fillsFromOtherEye = otherEye
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try warper.encode(frame: frame, depth: depth, views: targets, planeDistance: 2, fills: fills,
                              commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            var out = [Float16](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes {
                colours[0].getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            var magenta = 0, cyan = 0, yellow = 0
            for i in stride(from: 0, to: out.count, by: 4) {
                let r = out[i], g = out[i + 1], b = out[i + 2]
                if r == 1, g == 0, b == 1 { magenta += 1 }
                if r == 0, g == 1, b == 1 { cyan += 1 }
                if r == 1, g == 1, b == 0 { yellow += 1 }
            }
            return (magenta, cyan, yellow)
        }
        let alone = try tints(otherEye: false, fills: [])
        XCTAssertGreaterThan(alone.magenta, 4 * Self.eyeHeight)
        XCTAssertEqual(alone.cyan + alone.yellow, 0)
        let otherEye = try tints(otherEye: true, fills: [])
        XCTAssertGreaterThan(otherEye.cyan, alone.magenta * 3 / 4, "most of the strip from the other eye")
        XCTAssertLessThan(otherEye.magenta, alone.magenta / 4)
        let history = try tints(otherEye: false, fills: [.init(frame: earlier, depth: earlierDepth)])
        XCTAssertGreaterThan(history.yellow, alone.magenta * 3 / 4, "most of the strip from the earlier frame")
        XCTAssertLessThan(history.magenta, alone.magenta / 4)
        XCTAssertEqual(history.cyan, 0)
    }

    /// An earlier frame with both eyes `x` metres right of the identity frame's.
    private func shifted(_ x: Float, time: TimeInterval, epoch: UInt16 = 0) throws -> PCVRDecodedFrame {
        let made = try gradientFrame(foveation: nil, pose: PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                                     position: [x, 0, 0]))
        return PCVRDecodedFrame(streamEpoch: 0, frameNumber: 0, texture: made.texture,
                                renderPose: PCVRRenderPose(poseSequence: 0, spaceEpoch: epoch, displayTime: time,
                                                           eyes: made.renderPose.eyes), arrivalTime: 0)
    }

    /// Fill views go to those that see what the eye's move uncovered: at or
    /// past the target along the move, nearest first, an older one losing a
    /// near tie; one behind the frame's own eye sees none of it. Never from
    /// another space epoch or the frame itself.
    func testFillViewsAreRankedByWhatTheySeeOfTheUncoveredStrip() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try slabDepth(leftX: 0)
        let near = try shifted(0.025, time: -0.05), older = try shifted(0.026, time: -0.2)
        let elsewhere = try shifted(0.03, time: -0.01, epoch: 1)
        let fills = [older, near, elsewhere].map { PCVRDepthWarper.FillSource(frame: $0, depth: depth) }
            + [PCVRDepthWarper.FillSource(frame: frame, depth: depth)]
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.03, 0, 0])
        let plan = PCVRDepthWarper.fillPlan(frame: frame, targets: frame.renderPose.eyes.map { $0.pose * move },
                                            fills: fills, otherEye: true)
        // Left eye 3 cm toward the right one: `near`'s left eye (2.5 cm along,
        // 0.5 cm off) sees five sixths of the strip and leads; the other eye
        // (3.4 cm off, past the target, sees all of it) beats `older` (0.4 cm
        // off, but 150 ms older).
        XCTAssertEqual(plan[0].map(\.fill), [1, nil])
        XCTAssertEqual(plan[0].map(\.eye), [0, 1])
        // Right eye 3 cm away from the left one, which is behind it and sees
        // nothing of the strip: `near`'s right eye, then `older`'s.
        XCTAssertEqual(plan[1].map(\.fill), [1, 0])
        XCTAssertEqual(plan[1].map(\.eye), [1, 1])
    }

    /// With each eye rendered outward of the real one (the overlay's render
    /// margin), the earlier frames were rendered about where this one was,
    /// blind to the strip the move back uncovers: the other eye, though
    /// farther, fills first. By distance alone the earlier frame's own eye
    /// (1.6 cm off) beat it (4.4 cm off).
    func testTheOtherEyeBeatsANearerViewBlindToTheStrip() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try slabDepth(leftX: 0)
        let earlier = try shifted(0.004, time: -0.02)
        let move = PCVRPose(rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), position: [0.02, 0, 0])
        let plan = PCVRDepthWarper.fillPlan(frame: frame, targets: frame.renderPose.eyes.map { $0.pose * move },
                                            fills: [PCVRDepthWarper.FillSource(frame: earlier, depth: depth)],
                                            otherEye: true)
        XCTAssertEqual(plan[0].map(\.fill), [nil, 0])
        XCTAssertEqual(plan[0].map(\.eye), [1, 1])
    }
    /// A pitch past the frame's bottom edge: the band the frame never saw is
    /// filled from an earlier frame rendered from the pitched pose, each
    /// pixel with exactly what that frame showed in its direction (here its
    /// own render UV, since the earlier frame was rendered from the target).
    func testAPitchPastTheEdgeIsFilledFromAnEarlierFrameInPlace() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { _, _ in 2 }
        let pitch = PCVRPose(rotation: simd_quatf(angle: -0.25, axis: [1, 0, 0]), position: .zero)
        let targets = frame.renderPose.eyes.map { $0.pose * pitch }
        let made = try gradientFrame(foveation: nil, pose: pitch)
        let earlier = PCVRDecodedFrame(streamEpoch: 0, frameNumber: 0, texture: made.texture,
                                       renderPose: PCVRRenderPose(poseSequence: 0, spaceEpoch: 0, displayTime: -0.05,
                                                                  eyes: made.renderPose.eyes), arrivalTime: 0)
        let warper = try PCVRDepthWarper(device: device)
        warper.fillsFromOtherEye = false
        let width = 2 * Self.eyeWidth, height = Self.eyeHeight
        let colour = try texture(.rgba16Float, width: width, height: height, write: true)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, targets: targets, planeDistance: 2, into: colour,
                          fills: [.init(frame: earlier, depth: depth)], commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            colour.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let out = Output(colour: pixels, depth: [])
        let texel = 1 / Float(Self.eyeWidth), rowTexel = 1 / Float(Self.eyeHeight)
        var checked = 0, worst: Float = 0
        for eye in 0..<2 {
            // Rows below where the frame's own picture ends (looking down 0.25 rad).
            for y in stride(from: Self.eyeHeight - 30, to: Self.eyeHeight - 2, by: 3) {
                for x in stride(from: 4, to: Self.eyeWidth - 4, by: 7) {
                    let got = out.sourceUV(eye: eye, x: x, y: y)
                    let u = (Float(x) + 0.5) * texel, v = (Float(y) + 0.5) * rowTexel
                    worst = max(worst, abs(got.x - u) / texel, abs(got.y - v) / rowTexel)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 500)
        XCTAssertLessThan(worst, 1.5, "worst fill error in texels")
    }
    /// With no shift corrected by depth, a scene with a near block warps as
    /// the gaze plane's homography, depth or not: rays leave the source eye
    /// itself, so nothing it saw can be uncovered.
    func testWithNoDepthShiftTheWarpIsThePlaneHomographyAndOpensNoHoles() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { x, y in (16..<32).contains(x) && (8..<24).contains(y) ? 0.5 : 2 }
        let move = PCVRPose(rotation: simd_quatf(angle: 0.03, axis: [0, 1, 0]), position: [0.04, 0.01, 0])
        let targets = frame.renderPose.eyes.map { $0.pose * move }
        let saved = PCVRDepthWarper.depthShiftLimitNow
        defer { PCVRDepthWarper.depthShiftLimitNow = saved }
        PCVRDepthWarper.depthShiftLimitNow = 0
        let out = try warp(frame, depth: depth, targets: targets, planeDistance: 2)
        for eye in 0..<2 {
            let display = PCVREyeView(pose: targets[eye], fieldOfView: Self.fov)
            let h = PCVRReprojection.sourceFromDisplay(render: frame.renderPose.eyes[eye], display: display,
                                                       mode: .rotationAndTranslation(planeDistance: 2))
            assertMatches(out, eye: eye, homography: h, texels: 0.6)
        }
    }

    /// A repeat half a frame after the first display reads each pixel from
    /// where its content will have come from: `uv + v / 2` in the left eye,
    /// whose blocks all moved (8, -4) pixels; the right eye's blocks moved not
    /// at all and its picture stays put. The first display moves nothing.
    func testARepeatCarriesTheGamesMotionOnByTheTimeSinceTheFirstDisplay() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        let depth = try depthMap { _, _ in 2 }
        let targets = frame.renderPose.eyes.map(\.pose)
        let columns = Self.eyeWidth / 32, rows = Self.eyeHeight / 32
        var vectors = [Int8](repeating: 0, count: 4 * columns * rows)
        for block in 0..<(columns * rows) {
            vectors[block * 2] = 8
            vectors[block * 2 + 1] = -4
        }
        // The right eye's last block has no motion known: still, as all its others.
        vectors[(2 * columns * rows - 1) * 2] = MotionField.unknown
        let field = MotionField(cellSize: 32, columns: UInt16(columns), rows: UInt16(rows),
                                renderSize: PixelSize(width: UInt16(Self.eyeWidth), height: UInt16(Self.eyeHeight)),
                                interval: 22_222, scale: 1, vectors: vectors)
        let map = try XCTUnwrap(PCVRMotionMap(field: field, device: device))
        XCTAssertEqual(map.knownBlocks, 2 * columns * rows - 1)
        XCTAssertNil(PCVRMotionShift.forDisplay(map: map, sinceFirstShown: 0))
        let repeatShift = try XCTUnwrap(PCVRMotionShift.forDisplay(map: map, sinceFirstShown: 0.011_111))
        XCTAssertEqual(repeatShift.amount, 0.5, accuracy: 0.001)
        let out = try warp(frame, depth: depth, targets: targets, motion: repeatShift)
        var worst: SIMD2<Float> = .zero, checked = 0
        for eye in 0..<2 {
            let shift = eye == 0 ? SIMD2<Float>(4 / Float(Self.eyeWidth), -2 / Float(Self.eyeHeight)) : .zero
            for y in stride(from: 8, to: Self.eyeHeight - 8, by: 5) {
                for x in stride(from: 8, to: Self.eyeWidth - 8, by: 7) {
                    let uv = SIMD2((Float(x) + 0.5) / Float(Self.eyeWidth), (Float(y) + 0.5) / Float(Self.eyeHeight))
                    let error = abs(out.sourceUV(eye: eye, x: x, y: y) - (uv + shift))
                        * SIMD2(Float(Self.eyeWidth), Float(Self.eyeHeight))
                    worst = simd_max(worst, error)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 2000)
        XCTAssertLessThan(worst.x, 0.6, "worst error across, pixels")
        XCTAssertLessThan(worst.y, 0.6, "worst error down, pixels")
        // A full interval later it is capped there, not carried past the next frame's time.
        XCTAssertEqual(PCVRMotionShift.forDisplay(map: map, sinceFirstShown: 0.05)?.amount, 1)
    }

    /// A pixel the host marked as head-locked HUD (the depth picture's Cb off
    /// grey) is shown where the head is now: the display pixel reads the frame
    /// at its own UV, not reprojected through the head's turn like the rest.
    func testTheMarkedHudStaysWithTheHeadWhileTheWorldIsReprojected() throws {
        let frame = try gradientFrame(foveation: nil, pose: .identity)
        var depth = try depthMap { _, _ in 2 }
        // The chroma at half the depth picture: Cb 0.75 over the left eye's left half, grey elsewhere.
        let chromaWidth = Self.depthWidth, chromaHeight = Self.depthHeight / 2 // both eyes: 2 x depthWidth / 2
        let hud = try texture(.rg8Unorm, width: chromaWidth, height: chromaHeight)
        var cbcr = [UInt8](repeating: 128, count: chromaWidth * chromaHeight * 2)
        for y in 0..<chromaHeight {
            for x in 0..<(chromaWidth / 4) { cbcr[(y * chromaWidth + x) * 2] = 191 }
        }
        cbcr.withUnsafeBytes {
            hud.replace(region: MTLRegionMake2D(0, 0, chromaWidth, chromaHeight), mipmapLevel: 0, withBytes: $0.baseAddress!,
                        bytesPerRow: chromaWidth * 2)
        }
        depth.hud = hud
        let turn = PCVRPose(rotation: simd_quatf(angle: 0.05, axis: [0, 1, 0]), position: .zero)
        let near: Float = 0.1
        let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        let width = Self.eyeWidth, height = Self.eyeHeight
        var colours: [any MTLTexture] = [], targets: [PCVRReceiverTarget] = []
        for eye in 0..<2 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let colour = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            colours.append(colour)
            targets.append(PCVRReceiverTarget(
                eye: eye, colorTexture: colour, depthTexture: nil, depthClearValue: 0,
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1),
                display: PCVREyeView(pose: frame.renderPose.eyes[eye].pose * turn, fieldOfView: Self.fov),
                displayProjection: projection))
        }
        let warper = try PCVRDepthWarper(device: device)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, views: targets, planeDistance: 2, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
        for eye in 0..<2 {
            var pixels = [Float16](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                colours[eye].getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height),
                                      mipmapLevel: 0)
            }
            let h = PCVRReprojection.sourceFromDisplay(render: frame.renderPose.eyes[eye], display: targets[eye].display,
                                                       mode: .rotation)
            var lockedChecked = 0, worldChecked = 0, worstLocked: Float = 0, worstWorld: Float = 0
            for y in stride(from: 3, to: height, by: 8) {
                for x in stride(from: 3, to: width, by: 8) {
                    let i = (y * width + x) * 4
                    let got = SIMD2(Float(pixels[i]), Float(pixels[i + 1]))
                    let own = SIMD2((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
                    if eye == 0, own.x < 0.45 {
                        worstLocked = max(worstLocked, abs(got.x - own.x) * Float(width), abs(got.y - own.y) * Float(height))
                        lockedChecked += 1
                    } else if eye == 1 || own.x > 0.55, let expected = expectedUV(x: x, y: y, through: h),
                              expected.x > 0.03, expected.x < 0.97, expected.y > 0.03, expected.y < 0.97 {
                        worstWorld = max(worstWorld, abs(got.x - expected.x) * Float(width), abs(got.y - expected.y) * Float(height))
                        worldChecked += 1
                    }
                }
            }
            if eye == 0 {
                XCTAssertGreaterThan(lockedChecked, 500)
                XCTAssertLessThan(worstLocked, 0.6, "the HUD reads its own UV, texels")
            }
            XCTAssertGreaterThan(worldChecked, 300)
            XCTAssertLessThan(worstWorld, 0.6, "eye \(eye): the world follows the turn, texels")
        }
        // Off, the HUD turns with the world like everything else.
        warper.headLockedHud = false
        let again = try XCTUnwrap(queue.makeCommandBuffer())
        try warper.encode(frame: frame, depth: depth, views: targets, planeDistance: 2, commandBuffer: again)
        again.commit()
        again.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes {
            colours[0].getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let i = (128 * width + 100) * 4
        XCTAssertGreaterThan(abs(Float(pixels[i]) - (100.5 / Float(width))) * Float(width), 5, "the HUD moved with the world")
    }
}
#endif

