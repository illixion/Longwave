// The depth pass (lw_depth_*) against scenes of known depth. Needs a GPU, so
// it runs on the Windows host.
import CStreamWin
@testable import StreamHostWindows
import XCTest

final class DepthPassTests: XCTestCase {
    override class func setUp() {
        try? StreamHostRuntime.initialize()
    }

    // Mirrored asymmetric frusta, wider toward the temple, as on a headset.
    static let left = SIMD4<Float>(-1.0, 0.6, 0.8, -0.8)
    static let right = SIMD4<Float>(-0.6, 1.0, 0.8, -0.8)
    static let baseline: Float = 0.064

    /// Value noise on a world plane: blocks of `cell` metres, each a random grey.
    private static func noise(_ x: Float, _ y: Float, cell: Float, seed: UInt32) -> UInt8 {
        var h = UInt32(bitPattern: Int32(floor(x / cell))) &* 73_856_093 ^ UInt32(bitPattern: Int32(floor(y / cell))) &* 19_349_663
        h ^= seed &* 83_492_791
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return UInt8(truncatingIfNeeded: h >> 24)
    }

    /// Both eyes of a scene: a textured wall at `far` metres and a textured
    /// square, 0.2 m across, straight ahead at `near` metres.
    private func stereoScene(device: GraphicsDevice, eye: Int, far: Float, near: Float) throws -> GraphicsTexture {
        var pixels = [UInt8](repeating: 0, count: 2 * eye * eye * 4)
        for e in 0..<2 {
            let t = e == 0 ? Self.left : Self.right
            let origin = (e == 0 ? -0.5 : 0.5) * Self.baseline
            for y in 0..<eye {
                for x in 0..<eye {
                    let tx = t.x + (Float(x) + 0.5) / Float(eye) * (t.y - t.x)
                    let ty = t.z - (Float(y) + 0.5) / Float(eye) * (t.z - t.w)
                    var grey: UInt8
                    let fx = origin + tx * near, fy = ty * near
                    if abs(fx) <= 0.1, abs(fy) <= 0.1 {
                        grey = Self.noise(fx, fy, cell: 0.008, seed: 1)
                    } else {
                        grey = Self.noise(origin + tx * far, ty * far, cell: 0.06, seed: 2)
                    }
                    let i = (y * 2 * eye + e * eye + x) * 4
                    (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (grey, grey, grey, 255)
                }
            }
        }
        return try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * eye, height: eye, format: .bgra8, pixels: $0)
        }
    }

    func testStereoFindsTheDepthOfANearSquareAndTheWallBehindIt() throws {
        let device = try GraphicsDevice(for: nil)
        let pass = try DepthPass(device: device)
        let sourceEye = 512, depthEye = 64, maxDisparity = 32
        let source = try stereoScene(device: device, eye: sourceEye, far: 4, near: 0.5)
        let destination = try GraphicsTexture(device: device, width: 2 * depthEye, height: depthEye, format: .bgra8)
        let near = DepthPass.stereoNear(baseline: Self.baseline, maxDisparity: maxDisparity, leftTangents: Self.left,
                                        depthEyeWidth: depthEye)
        XCTAssertEqual(near, 0.08, accuracy: 1e-4)
        try pass.apply(source: source, kind: .stereo(baseline: Self.baseline, maxDisparity: maxDisparity),
                       sourceEye: (sourceEye, sourceEye), destination: destination, depthEye: (depthEye, depthEye),
                       tangents: (Self.left, Self.right), near: near)
        let out = try destination.read()

        for e in 0..<2 {
            let t = e == 0 ? Self.left : Self.right
            let origin = (e == 0 ? -0.5 : 0.5) * Self.baseline
            var squareValues: [Float] = [], wallValues: [Float] = []
            for y in 0..<depthEye {
                for x in 0..<depthEye {
                    let tx = t.x + (Float(x) + 0.5) / Float(depthEye) * (t.y - t.x)
                    let ty = t.z - (Float(y) + 0.5) / Float(depthEye) * (t.z - t.w)
                    let fx = origin + tx * 0.5, fy = ty * 0.5
                    let value = Float(out[(y * 2 * depthEye + e * depthEye + x) * 4])
                    // Well inside the square, or well clear of it (and of the
                    // frustum's edges, where only one eye sees).
                    if abs(fx) < 0.06, abs(fy) < 0.06 {
                        squareValues.append(value)
                    } else if abs(fx) > 0.16 || abs(fy) > 0.16, abs(tx) < 0.5, abs(ty) < 0.6 {
                        wallValues.append(value)
                    }
                }
            }
            func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
            // 0.08 / 0.5 = 0.16 -> 40.8; 0.08 / 4 = 0.02 -> 5.1.
            XCTAssertGreaterThan(squareValues.count, 50)
            XCTAssertEqual(median(squareValues), 40.8, accuracy: 2, "eye \(e) square")
            let squareGood = squareValues.filter { abs($0 - 40.8) <= 4 }.count
            XCTAssertGreaterThan(Float(squareGood) / Float(squareValues.count), 0.9, "eye \(e) square spread \(squareValues)")
            XCTAssertGreaterThan(wallValues.count, 200)
            XCTAssertEqual(median(wallValues), 5.1, accuracy: 2, "eye \(e) wall")
            let wallGood = wallValues.filter { $0 <= 12 }.count
            XCTAssertGreaterThan(Float(wallGood) / Float(wallValues.count), 0.9, "eye \(e) wall: \(wallGood) of \(wallValues.count)")
        }
    }

    func testLinearTakesTheNearestDepthUnderEachTexel() throws {
        let device = try GraphicsDevice(for: nil)
        let pass = try DepthPass(device: device)
        // 64x32 per eye in, 16x8 per eye out: 4x4 source texels each.
        let w = 64, h = 32
        var metres = [Float](repeating: 0, count: 2 * w * h)
        for y in 0..<h {
            for x in 0..<w {
                metres[y * 2 * w + x] = 2
                if x == 13, y == 9 { metres[y * 2 * w + x] = 0.5 } // one near texel in output texel (3, 2)
                metres[y * 2 * w + w + x] = 0 // right eye: nothing there
            }
        }
        let source = try metres.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * w, height: h, format: .r32Float, pixels: $0)
        }
        let destination = try GraphicsTexture(device: device, width: 32, height: 8, format: .bgra8)
        try pass.apply(source: source, kind: .linear, sourceEye: (w, h), destination: destination, depthEye: (16, 8),
                       tangents: (Self.left, Self.right), near: 0.25)
        let out = try destination.read()
        for y in 0..<8 {
            for x in 0..<32 {
                let value = out[(y * 32 + x) * 4]
                let expected: UInt8 = x >= 16 ? 0 : (x == 3 && y == 2 ? 128 : 32) // 0.25/0.5, 0.25/2, far
                XCTAssertEqual(Float(value), Float(expected), accuracy: 1, "texel \(x),\(y)")
            }
        }
    }

    /// At production size the estimate must cost a small part of a 90 Hz frame.
    func testStereoAtNativeDensityIsCheap() throws {
        let device = try GraphicsDevice(for: nil)
        let pass = try DepthPass(device: device)
        // The host's sizes: depth at 1/16 of the render eye, disparities down to about 0.15 m.
        let sourceEye = (width: 5184, height: 4160), depthEye = (width: 324, height: 260)
        var pixels = [UInt8](repeating: 0, count: 2 * sourceEye.width * sourceEye.height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let v = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 24)
            (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (v, v, v, 255)
        }
        let source = try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: 2 * sourceEye.width, height: sourceEye.height, format: .bgra8, pixels: $0)
        }
        let destination = try GraphicsTexture(device: device, width: 2 * depthEye.width, height: depthEye.height, format: .bgra8)
        let left = SIMD4<Float>(-1.767, 1.02, 1.02, -1.216), right = SIMD4<Float>(-1.02, 1.767, 1.02, -1.216)
        let near = DepthPass.stereoNear(baseline: 0.0668, maxDisparity: 52, leftTangents: left, depthEyeWidth: depthEye.width)
        func run() throws {
            try pass.apply(source: source, kind: .stereo(baseline: 0.0668, maxDisparity: 52), sourceEye: sourceEye,
                           destination: destination, depthEye: depthEye, tangents: (left, right), near: near)
        }
        try run()
        _ = try destination.read()
        // GPU time, measured on the GPU: a burst of small jobs from a test runs at
        // idle clocks and says little about wall time under a game's load.
        // Three seconds of back-to-back work first, so the clocks leave idle.
        var samples: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            try run()
            if let ms = pass.gpuMilliseconds { samples.append(ms) }
        }
        _ = try destination.read()
        if let ms = pass.gpuMilliseconds { samples.append(ms) }
        let milliseconds = try XCTUnwrap(samples.suffix(20).sorted().dropLast(5).last)
        let passes = pass.passMilliseconds
        print(String(format: "depth estimate at 2x%dx%d -> 2x%dx%d: %.2f ms on the GPU (median-ish of %d; near %.3f m); last: luma %.2f, match %.2f, output %.2f",
                     sourceEye.width, sourceEye.height, depthEye.width, depthEye.height, milliseconds, samples.count, near,
                     passes.luma, passes.match, passes.output))
        XCTAssertLessThan(milliseconds, 1.5)
    }
}
