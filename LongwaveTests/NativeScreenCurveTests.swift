import XCTest
@testable import Longwave

/// The curved Native desktop's input remap: a tap on the flat window plane
/// has to land on the pixel the ray from the cylinder axis meets on the curve.
final class NativeScreenCurveTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    func testFlatBelowAMetre() {
        XCTAssertEqual(NativeScreenCurve.automaticHalfAngle(widthMeters: 0.8), 0)
        XCTAssertGreaterThan(NativeScreenCurve.automaticHalfAngle(widthMeters: 2.5), 0)
        XCTAssertEqual(NativeScreenCurve.automaticHalfAngle(widthMeters: 10), 0.5, accuracy: 1e-9)
    }

    func testFlatCurveIsIdentity() {
        let curve = NativeScreenCurve(halfAngle: 0, contentRect: rect)
        XCTAssertFalse(curve.isCurved)
        let point = CGPoint(x: 123, y: 456)
        XCTAssertEqual(curve.texturePoint(forViewPoint: point), point)
    }

    func testCentreAndEdgesMapToThemselves() {
        let curve = NativeScreenCurve(halfAngle: 0.4, contentRect: rect)
        let centre = curve.texturePoint(forViewPoint: CGPoint(x: 800, y: 450))
        XCTAssertEqual(centre.x, 800, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 450, accuracy: 1e-6)
        // The radius is chosen so the window edge's ray meets the screen edge.
        XCTAssertEqual(curve.texturePoint(forViewPoint: CGPoint(x: 0, y: 450)).x, 0, accuracy: 1e-6)
        XCTAssertEqual(curve.texturePoint(forViewPoint: CGPoint(x: 1600, y: 450)).x, 1600, accuracy: 1e-6)
    }

    func testHalfwayOutLandsFurtherAlongTheArc() {
        // atan grows slower than linear, so a plane point halfway to the edge
        // sits more than halfway along the arc's half — i.e. past 1200 px.
        let curve = NativeScreenCurve(halfAngle: 0.4, contentRect: rect)
        let mapped = curve.texturePoint(forViewPoint: CGPoint(x: 1200, y: 450))
        XCTAssertGreaterThan(mapped.x, 1200)
        XCTAssertLessThan(mapped.x, 1600)
    }

    func testVerticalStretchesTowardTheEdges() {
        let curve = NativeScreenCurve(halfAngle: 0.4, contentRect: rect)
        let atCentre = curve.texturePoint(forViewPoint: CGPoint(x: 800, y: 100))
        let atEdge = curve.texturePoint(forViewPoint: CGPoint(x: 1580, y: 100))
        // The curve is shorter than the window, so a point near the top of the
        // plane is at or past the top of the picture, and less so at the edge
        // where the ray meets the curve lower.
        XCTAssertLessThan(atCentre.y, atEdge.y)
        XCTAssertGreaterThanOrEqual(atCentre.y, 0)
    }

    func testFittedRectLetterboxes() {
        let fitted = NativeScreenCurve.fittedRect(stream: CGSize(width: 3440, height: 1440), in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fitted.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(fitted.midY, 500, accuracy: 1e-6)
    }
}
