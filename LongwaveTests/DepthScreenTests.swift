import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Longwave

/// The pure half of the depth screen (3D for flat games, NATIVE_V3_PROTOCOL.md
/// §4.8): decoding depth samples, the relief mapping and its comfort bounds,
/// the mesh grid, edge detection, and pairing frames by number.
final class DepthScreenTests: XCTestCase {
    private let gameRange = DepthScreenRange(near: 0.1, far: 1000, convergence: 2.5)

    // MARK: - Decode

    func testInverseDepthRoundTripsThroughDistance() {
        for z: Float in [0.1, 0.5, 2.5, 40, 999] {
            let v = gameRange.normalized(distance: z)
            XCTAssertEqual(gameRange.distance(normalized: v), z, accuracy: z * 1e-4)
        }
        XCTAssertEqual(gameRange.normalized(distance: 0.1), 1, accuracy: 1e-6)
        XCTAssertEqual(gameRange.normalized(distance: 1000), 0, accuracy: 1e-6)
    }

    func testInfiniteFarPlaneDecodesZeroToInfinity() {
        let range = DepthScreenRange(near: 0.1, far: .infinity)
        XCTAssertEqual(range.distance(normalized: 0), .infinity)
        XCTAssertEqual(range.distance(normalized: 0.5), 0.2, accuracy: 1e-6)
        XCTAssertEqual(range.normalized(distance: 1), 0.1, accuracy: 1e-6)
    }

    func testOutOfRangeDistancesClamp() {
        XCTAssertEqual(gameRange.normalized(distance: 0.01), 1)
        XCTAssertEqual(gameRange.normalized(distance: 5000), 0)
    }

    func testTenBitLumaDecodesThroughTheUnorm16View() {
        let video = DepthSampleEncoding.videoRange10
        XCTAssertEqual(video.normalized(sample: DepthSampleEncoding.sample(forCode: 64)), 0, accuracy: 1e-4)
        XCTAssertEqual(video.normalized(sample: DepthSampleEncoding.sample(forCode: 940)), 1, accuracy: 1e-4)
        XCTAssertEqual(video.normalized(sample: DepthSampleEncoding.sample(forCode: 502)), 0.5, accuracy: 1e-3)
        // Codes outside video range (sub-black, super-white) clamp.
        XCTAssertEqual(video.normalized(sample: DepthSampleEncoding.sample(forCode: 10)), 0)
        XCTAssertEqual(video.normalized(sample: DepthSampleEncoding.sample(forCode: 1000)), 1)

        let full = DepthSampleEncoding.fullRange10
        XCTAssertEqual(full.normalized(sample: DepthSampleEncoding.sample(forCode: 0)), 0, accuracy: 1e-4)
        XCTAssertEqual(full.normalized(sample: DepthSampleEncoding.sample(forCode: 1023)), 1, accuracy: 1e-4)
    }

    func testEncodingFollowsThePixelFormat() {
        XCTAssertEqual(DepthSampleEncoding(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), .videoRange10)
        XCTAssertEqual(DepthSampleEncoding(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange), .fullRange10)
        XCTAssertEqual(DepthSampleEncoding(pixelFormat: kCVPixelFormatType_OneComponent32Float), .unitInterval)
        XCTAssertNil(DepthSampleEncoding(pixelFormat: kCVPixelFormatType_32BGRA))
    }

    // MARK: - Relief and comfort

    private func relief(atDistance z: Float, convergence: Float = 2.5, popOut: Float = 0.35) -> Float {
        DepthScreenGeometry.relief(
            normalized: gameRange.normalized(distance: z), range: gameRange,
            convergence: convergence, popOutLimit: popOut
        )
    }

    func testConvergenceDistanceSitsOnTheWindowPlane() {
        XCTAssertEqual(relief(atDistance: 2.5), 0, accuracy: 1e-3)
        XCTAssertEqual(relief(atDistance: 7, convergence: 7), 0, accuracy: 1e-3)
    }

    func testReliefIsLinearInInverseDepthBehindThePlane() {
        // Twice the convergence distance is half way to infinity.
        XCTAssertEqual(relief(atDistance: 5), -0.5, accuracy: 1e-3)
        XCTAssertEqual(relief(atDistance: 10), -0.75, accuracy: 1e-3)
        // The far plane approaches −1 and never passes it.
        XCTAssertGreaterThanOrEqual(relief(atDistance: 1000), -1)
        XCTAssertLessThan(relief(atDistance: 1000), -0.99)
    }

    func testPopOutIsSoftlyLimited() {
        let weapon = relief(atDistance: 0.1)
        XCTAssertGreaterThan(weapon, 0.3)
        XCTAssertLessThanOrEqual(weapon, 0.35)
        XCTAssertGreaterThan(relief(atDistance: 1), relief(atDistance: 2))
        XCTAssertEqual(relief(atDistance: 0.5, popOut: 0), 0)
    }

    func testReliefIsMonotonicInDistance() {
        var previous = Float.infinity
        for z in stride(from: Float(0.1), through: 900, by: 3) {
            let r = relief(atDistance: z)
            XCTAssertLessThanOrEqual(r, previous)
            previous = r
        }
    }

    func testConvergencePrefersOverrideThenProfileThenFallback() {
        var settings = DepthScreenSettings()
        XCTAssertEqual(settings.convergence(for: gameRange), 2.5)
        XCTAssertEqual(settings.convergence(for: DepthScreenRange(near: 0.1, far: 100)), DepthScreenSettings.fallbackConvergence)
        settings.convergenceOverride = 4
        XCTAssertEqual(settings.convergence(for: gameRange), 4)
        settings.convergenceOverride = 0.01
        XCTAssertEqual(settings.convergence(for: gameRange), 0.1, "clamped to the near plane")
    }

    /// The default strength keeps the horizon inside a comfortable disparity
    /// for a typical big screen, and the relief is bounded so the eyes never
    /// diverge, however large the screen.
    func testDefaultStrengthKeepsTheHorizonComfortable() {
        let settings = DepthScreenSettings()
        for (width, viewer) in [(Float(1.6), Float(1.5)), (3, 2.5), (1, 0.8)] {
            let horizon = -settings.strength * width
            let arcmin = DepthScreenGeometry.angularDisparity(relief: horizon, viewerDistance: viewer)
            XCTAssertGreaterThan(arcmin, 0)
            XCTAssertLessThan(arcmin, 70, "\(width) m screen at \(viewer) m")
        }
        // On-screen separation of a point at the horizon stays below the IPD.
        let separation = 0.063 * (settings.strength * 10) / (2 + settings.strength * 10)
        XCTAssertLessThan(separation, 0.063)
    }

    // MARK: - Fade

    /// What the renderer draws for a fade state, with the depth stood in for
    /// by one sample: relief × blend, flat once the depth is gone.
    private func drawnRelief(_ state: (depth: Float?, blend: Float)) -> Float {
        guard let v = state.depth else { return 0 }
        return DepthScreenGeometry.relief(normalized: v, range: gameRange, convergence: 2.5, popOutLimit: 0.35) * state.blend
    }

    /// A cutscene starting: the first frame without depth must stand where the
    /// last frame with depth stood (within one frame's fade step), not jump to
    /// the far plane and creep forward from there.
    func testFadeOutStartsFromTheLastRealRelief() {
        var fade = DepthReliefFade<Float>(duration: 0.35)
        let background = gameRange.normalized(distance: 10)   // relief −0.75
        fade.advance(frameDepth: background, at: 0)
        fade.advance(frameDepth: background, at: 1)
        let last = fade.advance(frameDepth: background, at: 1.016)
        XCTAssertEqual(last.blend, 1)
        let first = fade.advance(frameDepth: nil, at: 1.032)
        let lastRelief = drawnRelief(last)
        XCTAssertEqual(drawnRelief(first), lastRelief, accuracy: abs(lastRelief) * 0.016 / 0.35 + 1e-6)

        // It then eases monotonically onto the window plane and lets go of the
        // old depth.
        var previous = drawnRelief(first)
        var time = 1.032
        while time < 1.5 {
            time += 0.016
            let drawn = drawnRelief(fade.advance(frameDepth: nil, at: time))
            XCTAssertGreaterThanOrEqual(drawn, previous)
            XCTAssertLessThanOrEqual(drawn, 0)
            previous = drawn
        }
        XCTAssertEqual(previous, 0)
        XCTAssertNil(fade.depth)
        XCTAssertTrue(fade.isSettled)
    }

    func testFadeInStartsFlatAndSettlesAtFullRelief() {
        var fade = DepthReliefFade<Float>(duration: 0.35)
        XCTAssertEqual(fade.advance(frameDepth: 0.5, at: 5).blend, 0)
        XCTAssertFalse(fade.isSettled)
        XCTAssertEqual(fade.advance(frameDepth: 0.5, at: 5.175).blend, 0.5, accuracy: 1e-5)
        XCTAssertEqual(fade.advance(frameDepth: 0.5, at: 6).blend, 1)
        XCTAssertTrue(fade.isSettled)
    }

    func testFeatherFlattensTheBorder() {
        XCTAssertEqual(DepthScreenGeometry.feather(0), 0)
        XCTAssertEqual(DepthScreenGeometry.feather(1), 0)
        XCTAssertEqual(DepthScreenGeometry.feather(0.5), 1)
        XCTAssertEqual(DepthScreenGeometry.feather(DepthScreenGeometry.borderFeather), 1, accuracy: 1e-6)
    }

    // MARK: - Grid

    func testGridFollowsTheDepthTextureUpToTheCap() {
        let quarter = DepthMeshGrid(depthWidth: 480, depthHeight: 270, maxColumns: 384)
        XCTAssertEqual(quarter.columns, 384)
        XCTAssertEqual(quarter.rows, 216)
        let small = DepthMeshGrid(depthWidth: 320, depthHeight: 180, maxColumns: 384)
        XCTAssertEqual(small.columns, 320)
        XCTAssertEqual(small.rows, 180)
        XCTAssertEqual(small.cellCount, 319 * 179)
        XCTAssertEqual(small.vertexCount, small.cellCount * 4)
    }

    func testIndicesCoverEachCellWithTwoFrontFacingTriangles() {
        let grid = DepthMeshGrid(columns: 4, rows: 3)
        let indices = grid.indices()
        XCTAssertEqual(indices.count, grid.indexCount)
        XCTAssertEqual(indices.max(), UInt32(grid.vertexCount - 1))
        // Corners TL, TR, BL, BR as the kernel lays them out, seen from +z.
        let corners: [SIMD2<Float>] = [[0, 1], [1, 1], [0, 0], [1, 0]]
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let a = corners[Int(indices[triangle] % 4)]
            let b = corners[Int(indices[triangle + 1] % 4)]
            let c = corners[Int(indices[triangle + 2] % 4)]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            XCTAssertGreaterThan(cross, 0, "counter-clockwise")
            XCTAssertEqual(indices[triangle] / 4, indices[triangle + 2] / 4, "one cell")
        }
    }

    // MARK: - Edges

    func testSteepPlanesAreNotEdgesButOutlinesAre() {
        let cell: Float = 1.6 / 383
        // A corridor wall: relief changes by a few per cent of a cell width.
        XCTAssertFalse(DepthScreenGeometry.isEdge(reliefs: [0, 0.2 * cell, 0, 0.2 * cell], cellWidth: cell, maxSlope: 3))
        // Nearly edge-on, but still a surface.
        XCTAssertFalse(DepthScreenGeometry.isEdge(reliefs: [0, 2.9 * cell, 0, 2.9 * cell], cellWidth: cell, maxSlope: 3))
        // A sphere in front of the far corridor: 10 cm over 4 mm.
        XCTAssertTrue(DepthScreenGeometry.isEdge(reliefs: [-0.25, -0.15, -0.25, -0.15], cellWidth: cell, maxSlope: 3))
        // Lowering the threshold catches gentler steps.
        XCTAssertTrue(DepthScreenGeometry.isEdge(reliefs: [0, 2 * cell, 0, 0], cellWidth: cell, maxSlope: 1.5))
    }

    func testFillMirrorsNearCornersAcrossTheBackground() {
        let cell: Float = 0.004
        // Subject on the left (TL, BL near), background on the right.
        XCTAssertEqual(
            DepthScreenGeometry.fillSources(reliefs: [0, -0.2, 0, -0.2], cellWidth: cell, maxSlope: 3),
            [1, nil, 3, nil]
        )
        // Subject above (TL, TR near): no far horizontal neighbour, so vertical.
        XCTAssertEqual(
            DepthScreenGeometry.fillSources(reliefs: [0, 0, -0.2, -0.2], cellWidth: cell, maxSlope: 3),
            [2, 3, nil, nil]
        )
        // One far corner (BR): TL has neither neighbour far, takes BR.
        XCTAssertEqual(
            DepthScreenGeometry.fillSources(reliefs: [0, 0, 0, -0.2], cellWidth: cell, maxSlope: 3),
            [3, 3, 3, nil]
        )
    }

    // MARK: - Pairing

    private typealias Pairer = DepthFramePairer<String, String>

    func testPictureThenDepthPairsOnTheDepth() {
        var pairer = Pairer()
        XCTAssertTrue(pairer.receive(picture: "p1", frameNumber: 1).isEmpty)
        let pairs = pairer.receive(depth: "d1", frameNumber: 1)
        XCTAssertEqual(pairs.map(\.picture), ["p1"])
        XCTAssertEqual(pairs.first?.depth, "d1")
        XCTAssertEqual(pairs.first?.depthIsStale, false)
        XCTAssertFalse(pairer.isHoldingPicture)
    }

    func testDepthThenPicturePairsOnThePicture() {
        var pairer = Pairer()
        XCTAssertTrue(pairer.receive(depth: "d1", frameNumber: 1).isEmpty)
        let pairs = pairer.receive(picture: "p1", frameNumber: 1)
        XCTAssertEqual(pairs.first?.depth, "d1")
        XCTAssertFalse(pairer.isHoldingPicture)
    }

    func testMissingDepthFallsBackToTheLastGood() {
        var pairer = Pairer()
        _ = pairer.receive(picture: "p1", frameNumber: 1)
        _ = pairer.receive(depth: "d1", frameNumber: 1)
        _ = pairer.receive(picture: "p2", frameNumber: 2)
        let expired = pairer.expire()
        XCTAssertEqual(expired?.picture, "p2")
        XCTAssertEqual(expired?.depth, "d1")
        XCTAssertEqual(expired?.depthIsStale, true)
        // Its depth arriving afterwards is late, but becomes the last good.
        XCTAssertTrue(pairer.receive(depth: "d2", frameNumber: 2).isEmpty)
        _ = pairer.receive(picture: "p3", frameNumber: 3)
        XCTAssertEqual(pairer.expire()?.depth, "d2")
    }

    func testANewerPictureReleasesTheHeldOne() {
        var pairer = Pairer()
        _ = pairer.receive(depth: "d1", frameNumber: 1)
        _ = pairer.receive(picture: "p1", frameNumber: 1)
        _ = pairer.receive(picture: "p2", frameNumber: 2)
        let pairs = pairer.receive(picture: "p3", frameNumber: 3)
        XCTAssertEqual(pairs.map(\.picture), ["p2"])
        XCTAssertEqual(pairs.first?.depth, "d1")
        XCTAssertTrue(pairer.isHoldingPicture)
    }

    func testDepthStopsBeingUsedOnceTooStale() {
        var pairer = Pairer()
        pairer.maxStaleFrames = 5
        _ = pairer.receive(depth: "d1", frameNumber: 1)
        _ = pairer.receive(picture: "p1", frameNumber: 1)
        _ = pairer.receive(picture: "p6", frameNumber: 6)
        XCTAssertEqual(pairer.expire()?.depth, "d1")
        _ = pairer.receive(picture: "p7", frameNumber: 7)
        XCTAssertNil(pairer.expire()?.depth)
    }

    func testPrimaryWithoutAnyDepthIsShownWithNone() {
        var pairer = Pairer()
        _ = pairer.receive(picture: "p1", frameNumber: 1)
        let pair = pairer.expire()
        XCTAssertEqual(pair?.picture, "p1")
        XCTAssertNil(pair?.depth)
    }

    func testFrameNumbersWrap() {
        XCTAssertTrue(Pairer.isBefore(UInt32.max, 0))
        XCTAssertFalse(Pairer.isBefore(0, UInt32.max))
        var pairer = Pairer()
        _ = pairer.receive(depth: "dmax", frameNumber: .max)
        _ = pairer.receive(picture: "pmax", frameNumber: .max)
        _ = pairer.receive(picture: "p0", frameNumber: 0)
        let pair = pairer.expire()
        XCTAssertEqual(pair?.depth, "dmax")
        XCTAssertEqual(pair?.depthIsStale, true)
    }

    // MARK: - Stills

    func testStillConversionHandlesEachEncoding() {
        let range = DepthScreenRange(near: 1, far: 11)
        XCTAssertEqual(DepthStillConversion.inverseDepth(samples: [0.25], encoding: .inverse, reversed: false, range: range), [0.25])
        XCTAssertEqual(DepthStillConversion.inverseDepth(samples: [0.25], encoding: .inverse, reversed: true, range: range), [0.75])
        let linear = DepthStillConversion.inverseDepth(samples: [0, 1, 0.1], encoding: .linear, reversed: false, range: range)
        XCTAssertEqual(linear[0], 1, accuracy: 1e-5)
        XCTAssertEqual(linear[1], 0, accuracy: 1e-5)
        XCTAssertEqual(linear[2], range.normalized(distance: 2), accuracy: 1e-5)
    }

    func testStillFilesAreSortedByName() {
        let urls = ["shot.png", "shot-depth.png", "shot.json"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        let files = DepthStillLoader.classify(urls)
        XCTAssertEqual(files?.colour.lastPathComponent, "shot.png")
        XCTAssertEqual(files?.depth.lastPathComponent, "shot-depth.png")
        XCTAssertEqual(files?.sidecar?.lastPathComponent, "shot.json")
        XCTAssertNil(DepthStillLoader.classify([URL(fileURLWithPath: "/tmp/a.png")]))
    }

    func testStillPairLoadsSixteenBitDepth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let colour = directory.appendingPathComponent("frame.png")
        let depth = directory.appendingPathComponent("frame-depth.png")
        let sidecar = directory.appendingPathComponent("frame.json")
        try writePNG(width: 8, height: 4, bitsPerComponent: 8, components: 4, value: 0x80, to: colour)
        try writePNG(width: 8, height: 4, bitsPerComponent: 16, components: 1, value: 0x4000, to: depth)
        try Data(#"{"near": 0.5, "far": 50, "convergence": 3, "reversed": true}"#.utf8).write(to: sidecar)

        let still = try DepthStillLoader.load([colour, depth, sidecar])
        XCTAssertEqual(still.range, DepthScreenRange(near: 0.5, far: 50, convergence: 3))
        XCTAssertEqual(CVPixelBufferGetWidth(still.colour), 8)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(still.depth), kCVPixelFormatType_OneComponent32Float)
        CVPixelBufferLockBaseAddress(still.depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(still.depth, .readOnly) }
        let first = try XCTUnwrap(CVPixelBufferGetBaseAddress(still.depth)).load(as: Float.self)
        // 0x4000 of 0xFFFF, reversed.
        XCTAssertEqual(first, 1 - Float(0x4000) / 65535, accuracy: 2e-3)
    }

    private func writePNG(width: Int, height: Int, bitsPerComponent: Int, components: Int, value: Int, to url: URL) throws {
        let bytesPerComponent = bitsPerComponent / 8
        var bytes = [UInt8](repeating: 0, count: width * height * components * bytesPerComponent)
        for index in stride(from: 0, to: bytes.count, by: bytesPerComponent) {
            if bytesPerComponent == 2 {
                bytes[index] = UInt8(value >> 8)   // big-endian
                bytes[index + 1] = UInt8(value & 0xFF)
            } else {
                bytes[index] = UInt8(value)
            }
        }
        let space = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = components == 4 ? .noneSkipLast : .none
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerComponent * components, bytesPerRow: width * components * bytesPerComponent,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
