import Metal
import StreamWire
import XCTest
import simd
@testable import Longwave

#if FOVEATED_ENABLED
/// The headset half of the centre/edge pair on the GPU: `PCVRUnwarp` and the
/// receiver's reprojection must read the wire texture exactly where StreamWire's
/// `CentreEdgeMapping.wireUV(forRender:)` says. The host half (the warp) is
/// checked the same way against the same reference on the PC
/// (`StreamHostWindowsTests.FoveationWarpTests`).
final class PCVRFoveationTests: XCTestCase {
    static let shape = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.5, edgeRatioX: 2.5, edgeRatioY: 2)
    static let renderEye = PixelSize(width: 200, height: 160)

    private var device: (any MTLDevice)!
    private var queue: (any MTLCommandQueue)!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    /// A render target the outputs land in (written, never filtered).
    private func texture(width: Int, height: Int, pixels: [Float]? = nil) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        if let pixels {
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width * 16)
            }
        }
        return texture
    }

    private func read(_ texture: any MTLTexture) -> [Float] {
        var pixels = [Float](repeating: 0, count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 16,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return pixels
    }

    /// A wire texture whose texels hold their own eye-local wire UV in R and G
    /// and their eye in B: a bilinear tap reads back the UV it was taken at.
    /// 16-bit unorm: filterable on every Apple GPU (the simulator's can't filter
    /// 32-bit floats) and fine to 1/65535, a few thousandths of a texel here.
    private func wireRamp(_ wire: PixelSize) throws -> any MTLTexture {
        let width = Int(wire.width), height = Int(wire.height)
        var pixels = [UInt16](repeating: 0, count: 2 * width * height * 4)
        func unorm(_ value: Float) -> UInt16 { UInt16((value * 65535).rounded()) }
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let i = (y * 2 * width + x) * 4
                pixels[i] = unorm((Float(x % width) + 0.5) / Float(width))
                pixels[i + 1] = unorm((Float(y) + 0.5) / Float(height))
                pixels[i + 2] = unorm(Float(x / width))
                pixels[i + 3] = 65535
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: 2 * width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 2 * width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 2 * width * 8)
        }
        return texture
    }

    private func frame(wire texture: any MTLTexture, foveation: PCVRFoveation?, fov: PCVRFieldOfView) -> PCVRDecodedFrame {
        let eye = PCVREyeView(pose: .identity, fieldOfView: fov)
        return PCVRDecodedFrame(streamEpoch: 0, frameNumber: 1, texture: texture,
                                renderPose: PCVRRenderPose(poseSequence: 1, spaceEpoch: 0, displayTime: 0,
                                                           eyes: PCVRStereo(left: eye, right: eye)),
                                foveation: foveation, arrivalTime: 0)
    }

    private static let centres: [(NormalizedPoint, NormalizedPoint)] = [
        (.centre, .centre),
        (NormalizedPoint(x: 0.1, y: 0.8), NormalizedPoint(x: 0.9, y: 0.2)),
        (NormalizedPoint(x: 0, y: 1), NormalizedPoint(x: 1, y: 0)),
        (NormalizedPoint(x: 0.62, y: 0.41), NormalizedPoint(x: 0.38, y: 0.43)),
    ]

    /// Checks one eye of a render-size output against the reference: each pixel
    /// must hold the wire UV the reference samples at its centre (clamped to the
    /// eye's half-texel bounds, as the taps are), and its own eye.
    private func assertMatchesReference(_ output: [Float], rowWidth: Int, xOffset: Int, eye: Int,
                                        map: CentreEdgeMapping, wire: PixelSize, file: StaticString = #filePath,
                                        line: UInt = #line) throws {
        let rw = Int(Self.renderEye.width), rh = Int(Self.renderEye.height)
        let ww = Float(wire.width), wh = Float(wire.height)
        var worst: Float = 0
        for y in 0..<rh {
            for x in 0..<rw {
                let render = NormalizedPoint(x: (Float(x) + 0.5) / Float(rw), y: (Float(y) + 0.5) / Float(rh))
                let expected = try XCTUnwrap(map.wireUV(forRender: render))
                let ex = min(max(expected.x, 0.5 / ww), 1 - 0.5 / ww)
                let ey = min(max(expected.y, 0.5 / wh), 1 - 0.5 / wh)
                let i = (y * rowWidth + xOffset + x) * 4
                XCTAssertEqual(output[i + 2], Float(eye), "seam bleed at \(x),\(y)", file: file, line: line)
                worst = max(worst, abs(output[i] - ex) * ww, abs(output[i + 1] - ey) * wh)
            }
        }
        // In wire texels: the ramp's and the filter's precision, nothing more. A
        // one-texel scale error would show as 0.5 at the edges, a wrong map as several.
        XCTAssertLessThan(worst, 0.05, "eye \(eye)", file: file, line: line)
    }

    func testUnwarpReadsWhereTheReferenceMapSays() throws {
        let wire = try XCTUnwrap(Self.shape.wireSize(forRender: Self.renderEye, alignment: 16))
        let source = try wireRamp(wire)
        let rw = Int(Self.renderEye.width), rh = Int(Self.renderEye.height)
        let target = try texture(width: 2 * rw, height: rh)
        let unwarp = try PCVRUnwarp(device: device)
        let parameters = FoveationParameters(epoch: 5, warp: .centreEdge(Self.shape))
        for (left, right) in Self.centres {
            let foveation = try XCTUnwrap(PCVRFoveation(
                parameters: parameters, frame: FoveationSideData(parameterEpoch: 5, leftCentre: left, rightCentre: right),
                renderEye: Self.renderEye))
            let decoded = frame(wire: source, foveation: foveation, fov: PCVRFieldOfView(tangentLeft: -1, tangentRight: 1,
                                                                                         tangentUp: 1, tangentDown: -1))
            XCTAssertEqual(decoded.renderSize.width, 2 * rw)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try unwarp.encode(frame: decoded, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            let output = read(target)
            try assertMatchesReference(output, rowWidth: 2 * rw, xOffset: 0, eye: 0, map: foveation.mapping.left, wire: wire)
            try assertMatchesReference(output, rowWidth: 2 * rw, xOffset: rw, eye: 1, map: foveation.mapping.right, wire: wire)
        }
    }

    /// The reprojection samples through the same map: shown at the pose it was
    /// rendered for, a warped frame reads exactly what the unwarp would.
    func testReceiverSamplesThroughTheMapWhileReprojecting() throws {
        let wire = try XCTUnwrap(Self.shape.wireSize(forRender: Self.renderEye, alignment: 16))
        let source = try wireRamp(wire)
        let rw = Int(Self.renderEye.width), rh = Int(Self.renderEye.height)
        let receiver = try PCVRReceiver(device: device)
        let fov = PCVRFieldOfView(tangentLeft: -1.05, tangentRight: 0.85, tangentUp: 0.95, tangentDown: -1.05)
        let parameters = FoveationParameters(epoch: 9, warp: .centreEdge(Self.shape))
        for (left, right) in Self.centres {
            let foveation = try XCTUnwrap(PCVRFoveation(
                parameters: parameters, frame: FoveationSideData(parameterEpoch: 9, leftCentre: left, rightCentre: right),
                renderEye: Self.renderEye))
            let decoded = frame(wire: source, foveation: foveation, fov: fov)
            let targets = try (0..<2).map { _ in try texture(width: rw, height: rh) }
            let viewport = MTLViewport(originX: 0, originY: 0, width: Double(rw), height: Double(rh), znear: 0, zfar: 1)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try receiver.encode(frame: decoded, targets: (0..<2).map {
                PCVRReceiverTarget(eye: $0, colorTexture: targets[$0], viewport: viewport,
                                   display: PCVREyeView(pose: .identity, fieldOfView: fov))
            }, options: PCVRReceiverOptions(mode: .rotation), commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertEqual(commandBuffer.status, .completed, String(describing: commandBuffer.error))
            try assertMatchesReference(read(targets[0]), rowWidth: rw, xOffset: 0, eye: 0, map: foveation.mapping.left, wire: wire)
            try assertMatchesReference(read(targets[1]), rowWidth: rw, xOffset: 0, eye: 1, map: foveation.mapping.right, wire: wire)
        }
    }

    /// An unwarped frame samples its texture as before: the identity map, each
    /// pixel centre reading its own texel.
    func testUnwarpedFramesUseTheIdentity() throws {
        let source = try wireRamp(Self.renderEye)
        let rw = Int(Self.renderEye.width), rh = Int(Self.renderEye.height)
        let target = try texture(width: 2 * rw, height: rh)
        let decoded = frame(wire: source, foveation: nil, fov: PCVRFieldOfView(tangentLeft: -1, tangentRight: 1,
                                                                             tangentUp: 1, tangentDown: -1))
        XCTAssertEqual(decoded.wireConstants(eye: 1).x, PCVRFoveation.identity)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try PCVRUnwarp(device: device).encode(frame: decoded, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let output = read(target)
        let rw2 = 2 * rw
        for y in 0..<rh {
            for x in 0..<rw2 {
                let i = (y * rw2 + x) * 4
                XCTAssertEqual(output[i], (Float(x % rw) + 0.5) / Float(rw), accuracy: 2e-5)
                XCTAssertEqual(output[i + 1], (Float(y) + 0.5) / Float(rh), accuracy: 2e-5)
                XCTAssertEqual(output[i + 2], Float(x / rw))
            }
        }
    }

    func testFramesFromAnotherEpochOrWithoutAWarpAreRefused() {
        let parameters = FoveationParameters(epoch: 3, warp: .centreEdge(Self.shape))
        XCTAssertNil(PCVRFoveation(parameters: parameters, frame: FoveationSideData(parameterEpoch: 2),
                                   renderEye: Self.renderEye))
        XCTAssertNil(PCVRFoveation(parameters: FoveationParameters(epoch: 3, warp: .none),
                                   frame: FoveationSideData(parameterEpoch: 3), renderEye: Self.renderEye))
        XCTAssertNil(PCVRFoveation(parameters: parameters, frame: FoveationSideData(parameterEpoch: 3),
                                   renderEye: PixelSize(width: 0, height: 10)))
    }
}
#endif
