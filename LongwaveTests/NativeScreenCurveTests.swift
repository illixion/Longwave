import XCTest
@testable import Longwave

/// The curved Native desktop's geometry: strips that tile the picture, lie
/// on the circle, and map a point in a strip back to the flat picture.
final class NativeScreenCurveTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 50, width: 1600, height: 900)

    func testCurvatureGrowsWithWidthAtAFixedRadius() {
        let narrow = NativeScreenCurve(contentRect: CGRect(x: 0, y: 0, width: 800, height: 450), radius: 2000)
        let wide = NativeScreenCurve(contentRect: CGRect(x: 0, y: 0, width: 2400, height: 1350), radius: 2000)
        XCTAssertLessThan(narrow.halfAngle, wide.halfAngle)
        XCTAssertLessThan(narrow.stripCount, wide.stripCount)
    }

    func testStripsTileThePictureAndLieOnTheCircle() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        let strips = curve.strips
        XCTAssertEqual(strips.count, curve.stripCount)
        let pad = NativeScreenCurve.stripOverlap / rect.width
        XCTAssertEqual(strips.first?.u.lowerBound ?? -1, -pad, accuracy: 1e-9)
        XCTAssertEqual(strips.last?.u.upperBound ?? -1, 1 + pad, accuracy: 1e-9)
        for (left, right) in zip(strips, strips.dropFirst()) {
            // Neighbours overlap by the pad on each side, showing the same pixels.
            XCTAssertEqual(left.u.upperBound - right.u.lowerBound, 2 * pad, accuracy: 1e-9)
        }
        for strip in strips {
            // Distance from the circle's centre, which sits `radius` in front
            // of the picture's centre line.
            let dx = strip.center.x - rect.midX
            let dz = curve.radius - strip.depth
            XCTAssertEqual((dx * dx + dz * dz).squareRoot(), curve.radius, accuracy: 1e-6)
        }
        // Symmetric: the middle faces straight ahead.
        XCTAssertEqual(strips.first!.angle, -strips.last!.angle, accuracy: 1e-9)
    }

    func testFlatPointInAStripMapsBackToItsSlice() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        let strip = curve.strips[3]
        let start = curve.flatPoint(inStrip: strip, local: CGPoint(x: 0, y: 0))
        let end = curve.flatPoint(inStrip: strip, local: CGPoint(x: strip.size.width, y: 900))
        XCTAssertEqual(start.x, rect.minX + strip.u.lowerBound * rect.width, accuracy: 1e-9)
        XCTAssertEqual(end.x, rect.minX + strip.u.upperBound * rect.width, accuracy: 1e-9)
        XCTAssertEqual(start.y, rect.minY, accuracy: 1e-9)
        XCTAssertEqual(end.y, rect.maxY, accuracy: 1e-9)
    }

    func testSurfacePointFollowsTheStrips() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        for strip in curve.strips {
            let flat = CGPoint(x: rect.minX + (strip.u.lowerBound + strip.u.upperBound) / 2 * rect.width, y: 300)
            // (the slice's midpoint is unchanged by the symmetric overlap)
            let surface = curve.surfacePoint(forFlatPoint: flat)
            XCTAssertEqual(surface.point.x, strip.center.x, accuracy: 1e-6)
            XCTAssertEqual(surface.depth, strip.depth, accuracy: 1e-6)
        }
    }

    func testFittedRectLetterboxes() {
        let fitted = NativeScreenCurve.fittedRect(stream: CGSize(width: 3440, height: 1440), in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fitted.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(fitted.midY, 500, accuracy: 1e-6)
    }
}
