// The GPU foveation warp (lw_warp_*) against StreamWire's CPU reference
// (CentreEdgeMapping). Needs a GPU, so it runs on the Windows host.
import CStreamWin
@testable import StreamHostWindows
import StreamWire
import XCTest

final class FoveationWarpTests: XCTestCase {
    override class func setUp() {
        try? StreamHostRuntime.initialize()
    }

    static let shape = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.5, edgeRatioX: 2.5, edgeRatioY: 2)

    private static func eye(_ map: CentreEdgeMapping) -> FoveationWarpPass.Eye {
        FoveationWarpPass.Eye(x: map.x.constants, y: map.y.constants)
    }

    /// A float source whose every pixel holds its own eye-local render UV
    /// (pixel centre) in R and G and its eye in B. A bilinear tap of it reads
    /// back the UV it was taken at, and symmetric taps average to their centre,
    /// so each wire pixel's output is the render UV the warp sampled there.
    private func rampSource(device: GraphicsDevice, width: Int, height: Int) throws -> GraphicsTexture {
        var pixels = [Float](repeating: 0, count: 2 * width * height * 4)
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let i = (y * 2 * width + x) * 4
                pixels[i] = (Float(x % width) + 0.5) / Float(width)
                pixels[i + 1] = (Float(y) + 0.5) / Float(height)
                pixels[i + 2] = Float(x / width)
                pixels[i + 3] = 1
            }
        }
        return try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * width, height: height, format: .rgba32Float, pixels: $0)
        }
    }

    func testWarpSamplesWhereTheReferenceMapSays() throws {
        let device = try GraphicsDevice(for: nil)
        let warp = try FoveationWarpPass(device: device)
        let render = PixelSize(width: 400, height: 320)
        let wire = try XCTUnwrap(Self.shape.wireSize(forRender: render, alignment: 16))
        let (rw, rh, ww, wh) = (Int(render.width), Int(render.height), Int(wire.width), Int(wire.height))
        let source = try rampSource(device: device, width: rw, height: rh)
        let destination = try GraphicsTexture(device: device, width: 2 * ww, height: wh, format: .rgba32Float)
        let parameters = FoveationParameters(epoch: 3, warp: .centreEdge(Self.shape))

        let centres: [(NormalizedPoint, NormalizedPoint)] = [
            (.centre, .centre),
            (NormalizedPoint(x: 0.1, y: 0.8), NormalizedPoint(x: 0.9, y: 0.2)),
            (NormalizedPoint(x: 0, y: 1), NormalizedPoint(x: 1, y: 0)),
            (NormalizedPoint(x: 0.62, y: 0.41), NormalizedPoint(x: 0.38, y: 0.43)),
        ]
        for (leftCentre, rightCentre) in centres {
            let side = FoveationSideData(parameterEpoch: 3, leftCentre: leftCentre, rightCentre: rightCentre)
            let maps = try XCTUnwrap(StereoCentreEdgeMapping(parameters: parameters, frame: side))
            try warp.apply(source: source, renderEye: (rw, rh), destination: destination, wireEye: (ww, wh),
                           left: Self.eye(maps.left), right: Self.eye(maps.right))
            let output = try destination.read().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            var interiorError: Float = 0, worst: Float = 0
            for y in 0..<wh {
                for x in 0..<(2 * ww) {
                    let eye = x / ww
                    let map = eye == 0 ? maps.left : maps.right
                    let wireUV = NormalizedPoint(x: (Float(x % ww) + 0.5) / Float(ww), y: (Float(y) + 0.5) / Float(wh))
                    let expected = try XCTUnwrap(map.renderUV(forWire: wireUV))
                    let i = (y * 2 * ww + x) * 4
                    // Never a value from the other eye: taps stay inside their own.
                    XCTAssertEqual(output[i + 2], Float(eye), "seam bleed at \(x),\(y)")
                    let error = max(abs(output[i] - expected.x) * Float(rw), abs(output[i + 1] - expected.y) * Float(rh))
                    worst = max(worst, error)
                    // Within a footprint of the eye's border the taps are clamped
                    // half a texel in, so the reference's unclamped UV is a little
                    // off there by design; elsewhere they must agree to the filter's
                    // sub-texel precision.
                    let margin: Float = 3
                    let rx = expected.x * Float(rw), ry = expected.y * Float(rh)
                    if rx > margin, rx < Float(rw) - margin, ry > margin, ry < Float(rh) - margin {
                        interiorError = max(interiorError, error)
                    }
                }
            }
            XCTAssertLessThan(interiorError, 0.02, "interior error in render texels, centres \(leftCentre) \(rightCentre)")
            XCTAssertLessThan(worst, 1.5, "border error in render texels, centres \(leftCentre) \(rightCentre)")
        }
    }

    /// The format the host encodes: an identity map (centre size 1) copies
    /// BGRA8 exactly, and a compressed one keeps a flat eye flat.
    func testBGRA8IdentityCopiesAndFlatEyesStayFlat() throws {
        let device = try GraphicsDevice(for: nil)
        let warp = try FoveationWarpPass(device: device)
        let width = 64, height = 48
        var pixels = [UInt8](repeating: 0, count: 2 * width * height * 4)
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let i = (y * 2 * width + x) * 4
                pixels[i] = UInt8((x * 7 + y * 3) & 0xFF)
                pixels[i + 1] = UInt8((x * 13) & 0xFF)
                pixels[i + 2] = UInt8((y * 5) & 0xFF)
                pixels[i + 3] = 255
            }
        }
        let source = try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * width, height: height, format: .bgra8, pixels: $0)
        }
        let identity = CentreEdgeWarp(centreSizeX: 1, centreSizeY: 1, edgeRatioX: 1, edgeRatioY: 1)
        let maps = try XCTUnwrap(StereoCentreEdgeMapping(parameters: FoveationParameters(epoch: 1, warp: .centreEdge(identity)),
                                                         frame: FoveationSideData(parameterEpoch: 1)))
        let copy = try GraphicsTexture(device: device, width: 2 * width, height: height, format: .bgra8)
        try warp.apply(source: source, renderEye: (width, height), destination: copy, wireEye: (width, height),
                       left: Self.eye(maps.left), right: Self.eye(maps.right))
        XCTAssertEqual(try copy.read(), pixels)

        // Left eye flat grey, right eye flat red, through the default warp.
        for y in 0..<height {
            for x in 0..<(2 * width) {
                let i = (y * 2 * width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2]) = x < width ? (128, 128, 128) : (0, 0, 255)
            }
        }
        let flat = try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * width, height: height, format: .bgra8, pixels: $0)
        }
        let wire = try XCTUnwrap(PCVRProfile.defaultWarp.wireSize(forRender: PixelSize(width: UInt16(width), height: UInt16(height)),
                                                                  alignment: 16))
        let warped = try GraphicsTexture(device: device, width: 2 * Int(wire.width), height: Int(wire.height), format: .bgra8)
        let packed = try XCTUnwrap(StereoCentreEdgeMapping(
            parameters: FoveationParameters(epoch: 2, warp: .centreEdge(PCVRProfile.defaultWarp)),
            frame: FoveationSideData(parameterEpoch: 2, leftCentre: NormalizedPoint(x: 0.2, y: 0.7))))
        try warp.apply(source: flat, renderEye: (width, height), destination: warped,
                       wireEye: (Int(wire.width), Int(wire.height)), left: Self.eye(packed.left), right: Self.eye(packed.right))
        let out = try warped.read()
        for y in 0..<Int(wire.height) {
            for x in 0..<(2 * Int(wire.width)) {
                let i = (y * 2 * Int(wire.width) + x) * 4
                let expected: [UInt8] = x < Int(wire.width) ? [128, 128, 128, 255] : [0, 0, 255, 255]
                XCTAssertEqual(Array(out[i..<(i + 4)]), expected, "pixel \(x),\(y)")
            }
        }
    }

    func testRejectsConstantsOutsideTheReferenceRanges() throws {
        let device = try GraphicsDevice(for: nil)
        let warp = try FoveationWarpPass(device: device)
        let texture = try GraphicsTexture(device: device, width: 32, height: 16, format: .bgra8)
        let good = FoveationWarpPass.Eye(x: SIMD4(0.3, 0.7, 2, 0.56), y: SIMD4(0.3, 0.7, 2, 0.56))
        for bad in [SIMD4<Float>(0.7, 0.3, 2, 0.56), SIMD4(0.3, 0.7, 0.5, 0.56), SIMD4(0.3, 0.7, 2, 0), SIMD4(-0.1, 0.7, 2, 0.5)] {
            XCTAssertThrowsError(try warp.apply(source: texture, renderEye: (16, 16), destination: texture, wireEye: (16, 16),
                                                left: FoveationWarpPass.Eye(x: bad, y: good.y), right: good))
        }
        // A destination too small for two wire eyes.
        XCTAssertThrowsError(try warp.apply(source: texture, renderEye: (16, 16), destination: texture, wireEye: (17, 16),
                                            left: good, right: good))
    }
}
