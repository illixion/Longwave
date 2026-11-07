import XCTest
@testable import StreamWire

final class CentreEdgeMappingTests: XCTestCase {
    func testGoldenCoordinatesAndCentrePixelDensity() throws {
        let map = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.5, edgeRatio: 2, centre: 0.5))
        let golden: [(Float, Float)] = [(0, 0), (0.125, 1 / 12), (0.25, 1 / 6),
                                        (0.5, 0.5), (0.75, 5 / 6), (0.875, 11 / 12), (1, 1)]
        for (render, wire) in golden {
            XCTAssertEqual(try XCTUnwrap(map.wireCoordinate(forRender: render)), wire, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(map.renderCoordinate(forWire: wire)), render, accuracy: 1e-6)
        }
        XCTAssertEqual(map.wireScale, 0.75)
        let delta = try XCTUnwrap(map.wireCoordinate(forRender: 0.6)) - XCTUnwrap(map.wireCoordinate(forRender: 0.5))
        XCTAssertEqual(delta * 900, 0.1 * 1200, accuracy: 1e-4)
    }

    func testBoundaryCentresKeepTheWholeCentreRegion() throws {
        let left = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.5, edgeRatio: 2, centre: 0))
        let right = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.5, edgeRatio: 2, centre: 1))
        XCTAssertEqual(left.effectiveCentre, 0.25)
        XCTAssertEqual(right.effectiveCentre, 0.75)
        XCTAssertEqual(try XCTUnwrap(left.wireCoordinate(forRender: 0.5)), 2 / 3, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(right.wireCoordinate(forRender: 0.5)), 1 / 3, accuracy: 1e-6)
        XCTAssertEqual(left.wireScale, right.wireScale)
    }

    func testMapsAreMonotonicAndInvertibleAcrossMovingCentres() throws {
        for size: Float in [0.1, 0.4, 1] {
            for ratio: Float in [1, 2, 8] {
                for centre: Float in [0, 0.2, 0.5, 0.9, 1] {
                    let map = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: size, edgeRatio: ratio, centre: centre))
                    var previous: Float = -1
                    for i in 0...1000 {
                        let render = Float(i) / 1000
                        let wire = try XCTUnwrap(map.wireCoordinate(forRender: render))
                        XCTAssertGreaterThan(wire, previous)
                        XCTAssertEqual(try XCTUnwrap(map.renderCoordinate(forWire: wire)), render, accuracy: 2e-6)
                        if size == 1 || ratio == 1 { XCTAssertEqual(wire, render, accuracy: 1e-6) }
                        previous = wire
                    }
                }
            }
        }
    }

    func testInvalidParametersCoordinatesAndEpochsAreRejected() throws {
        for (size, ratio, centre): (Float, Float, Float) in [(0, 2, 0.5), (1.1, 2, 0.5), (0.5, 0.5, 0.5),
                                                           (0.5, .infinity, 0.5), (0.5, 2, .nan), (0.5, 2, -1)] {
            XCTAssertNil(CentreEdgeAxisMapping(centreSize: size, edgeRatio: ratio, centre: centre))
        }
        XCTAssertNil(CentreEdgeAxisMapping(centreSize: .leastNonzeroMagnitude, edgeRatio: 2, centre: 0.5))
        let axis = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.5, edgeRatio: 2, centre: 0.5))
        for coordinate: Float in [-0.1, 1.1, .nan, .infinity] {
            XCTAssertNil(axis.wireCoordinate(forRender: coordinate))
            XCTAssertNil(axis.renderCoordinate(forWire: coordinate))
        }
        let shape = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.5, edgeRatioX: 3, edgeRatioY: 2)
        let parameters = FoveationParameters(epoch: 7, warp: .centreEdge(shape))
        XCTAssertNil(StereoCentreEdgeMapping(parameters: parameters, frame: FoveationSideData(parameterEpoch: 6)))
        XCTAssertNil(StereoCentreEdgeMapping(parameters: FoveationParameters(epoch: 7, warp: .none),
                                             frame: FoveationSideData(parameterEpoch: 7)))
    }

    /// Encode a synthetic UV ramp on the wire grid, then bilinearly sample it
    /// with the receiver's map. This includes pixel-centre and edge sampling,
    /// rather than only composing two continuous functions.
    func testSyntheticStereoRampReconstruction() throws {
        let shape = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.5, edgeRatioX: 3, edgeRatioY: 2)
        for centre: Float in [0, 0.3, 0.7, 1] {
            let maps = try XCTUnwrap(StereoCentreEdgeMapping(
                parameters: FoveationParameters(epoch: 4, warp: .centreEdge(shape)),
                frame: FoveationSideData(parameterEpoch: 4, leftCentre: NormalizedPoint(x: centre, y: 0.3),
                                         rightCentre: NormalizedPoint(x: 1 - centre, y: 0.7))))
            for map in [maps.left, maps.right] {
                let width = 128, height = 96
                let texture = try (0..<height).flatMap { y in
                    try (0..<width).map { x in
                        try XCTUnwrap(map.renderUV(forWire: NormalizedPoint(x: (Float(x) + 0.5) / Float(width),
                                                                           y: (Float(y) + 0.5) / Float(height))))
                    }
                }
                for y in 0..<80 {
                    for x in 0..<100 {
                        let render = NormalizedPoint(x: (Float(x) + 0.5) / 100, y: (Float(y) + 0.5) / 80)
                        let uv = try XCTUnwrap(map.wireUV(forRender: render))
                        let px = max(0, min(Float(width - 1), uv.x * Float(width) - 0.5))
                        let py = max(0, min(Float(height - 1), uv.y * Float(height) - 0.5))
                        let x0 = Int(px), y0 = Int(py), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                        let tx = px - Float(x0), ty = py - Float(y0)
                        func sample(_ value: (NormalizedPoint) -> Float) -> Float {
                            let top = value(texture[y0 * width + x0]) * (1 - tx) + value(texture[y0 * width + x1]) * tx
                            let bottom = value(texture[y1 * width + x0]) * (1 - tx) + value(texture[y1 * width + x1]) * tx
                            return top * (1 - ty) + bottom * ty
                        }
                        XCTAssertEqual(sample { $0.x }, render.x, accuracy: 0.015)
                        XCTAssertEqual(sample { $0.y }, render.y, accuracy: 0.015)
                    }
                }
            }
        }
    }

    func testGPUConstantsAreTheReferenceIntervalRatioAndLength() throws {
        let map = try XCTUnwrap(CentreEdgeAxisMapping(centreSize: 0.4, edgeRatio: 2.5, centre: 0.1))
        // The centre is pushed inside the image: [0, 0.4], L = 0.4 + 0.6 / 2.5.
        XCTAssertEqual(map.constants.x, 0, accuracy: 1e-7)
        XCTAssertEqual(map.constants.y, 0.4, accuracy: 1e-7)
        XCTAssertEqual(map.constants.z, 2.5)
        XCTAssertEqual(map.constants.w, map.wireScale)
        XCTAssertEqual(map.wireScale, 0.64, accuracy: 1e-6)
    }

    func testWireSizeIsTheRenderSizeTimesTheLengthAligned() throws {
        let render = PixelSize(width: 2400, height: 1920)
        let shape = CentreEdgeWarp(centreSizeX: 0.4, centreSizeY: 0.4, edgeRatioX: 2.5, edgeRatioY: 2.5)
        XCTAssertEqual(shape.wireSize(forRender: render, alignment: 16), PixelSize(width: 1536, height: 1232))
        // The default halves a native-density eye.
        XCTAssertEqual(PCVRProfile.defaultWarp.wireSize(forRender: PixelSize(width: 5184, height: 4160), alignment: 16),
                       PixelSize(width: 2592, height: 2080))
        let identity = CentreEdgeWarp(centreSizeX: 1, centreSizeY: 0.5, edgeRatioX: 2, edgeRatioY: 1)
        XCTAssertEqual(identity.wireSize(forRender: render, alignment: 16), render)
        // Never larger than the render, never below one block.
        XCTAssertEqual(shape.wireSize(forRender: PixelSize(width: 20, height: 8), alignment: 16),
                       PixelSize(width: 16, height: 8))
        XCTAssertNil(PCVRProfile.defaultWarp.wireSize(forRender: PixelSize(width: 0, height: 8), alignment: 16))
        XCTAssertNil(CentreEdgeWarp(centreSizeX: 0, centreSizeY: 1, edgeRatioX: 2, edgeRatioY: 2)
            .wireSize(forRender: render, alignment: 16))
    }
}
