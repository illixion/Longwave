import XCTest
@testable import Longwave

/// The curved Native desktop's geometry: curvature that grows with width at a
/// fixed radius, and mapping a hit on the mesh back to the flat picture.
final class NativeScreenCurveTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 50, width: 1600, height: 900)
    private let metersPerPoint = 0.001

    func testCurvatureGrowsWithWidthAtAFixedRadius() {
        let narrow = NativeScreenCurve(contentRect: CGRect(x: 0, y: 0, width: 800, height: 450), radius: 2000)
        let wide = NativeScreenCurve(contentRect: CGRect(x: 0, y: 0, width: 2400, height: 1350), radius: 2000)
        XCTAssertLessThan(narrow.halfAngle, wide.halfAngle)
        XCTAssertLessThan(narrow.sagitta, wide.sagitta)
    }

    /// A point on the curve at a known angle and height, in the mesh's space.
    private func meshPoint(_ curve: NativeScreenCurve, u: Double, v: Double) -> SIMD3<Float> {
        let r = curve.radius * metersPerPoint
        let theta = (u - 0.5) * 2 * curve.halfAngle
        let y = (0.5 - v) * rect.height * metersPerPoint
        return [Float(r * sin(theta)), Float(y), Float(r * (1 - cos(theta)))]
    }

    func testMeshHitsMapToTheFlatPicture() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        for (u, v) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (0.2, 0.8), (0.9, 0.1)] {
            let flat = curve.flatPoint(meshLocal: meshPoint(curve, u: u, v: v), metersPerPoint: metersPerPoint)
            XCTAssertEqual(flat.x, rect.minX + u * rect.width, accuracy: 0.05)
            XCTAssertEqual(flat.y, rect.minY + v * rect.height, accuracy: 0.05)
        }
    }

    func testSurfacePointLiesOnTheCurve() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        for u in stride(from: 0.0, through: 1.0, by: 0.25) {
            let surface = curve.surfacePoint(forFlatPoint: CGPoint(x: rect.minX + u * rect.width, y: 300))
            let dx = surface.point.x - rect.midX
            let dz = curve.radius - surface.depth
            XCTAssertEqual((dx * dx + dz * dz).squareRoot(), curve.radius, accuracy: 1e-6)
        }
    }

    func testPlaneHoverAtTheCentreIsTheCentre() {
        let curve = NativeScreenCurve(contentRect: rect, radius: 1200)
        let flat = curve.flatPoint(forPlanePoint: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(flat.x, rect.midX, accuracy: 1e-9)
        XCTAssertEqual(flat.y, rect.midY, accuracy: 1e-9)
    }

    func testFittedRectLetterboxes() {
        let fitted = NativeScreenCurve.fittedRect(stream: CGSize(width: 3440, height: 1440), in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fitted.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(fitted.midY, 500, accuracy: 1e-6)
    }
}
