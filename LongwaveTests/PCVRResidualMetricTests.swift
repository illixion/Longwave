import XCTest

final class PCVRResidualMetricTests: XCTestCase {
    func testTruthAndCameraMotionDoNotCountAsTemporalArtifacts() {
        let image: [Float] = [0,0,0, 1,1,1, 0,0,0, 1,1,1]
        let (first, errors) = PCVRResidualMetrics.evaluate(truth: image, actual: image, width: 2,
                                                         classification: [0,0,0,0], previousError: nil)
        let moved = Array(image.reversed())
        let (second, _) = PCVRResidualMetrics.evaluate(truth: moved, actual: moved, width: 2,
                                                      classification: [0,0,0,0], previousError: errors)
        XCTAssertEqual(first.mae, 0)
        XCTAssertNil(first.temporalErrorChange)
        XCTAssertEqual(second.temporalErrorChange, 0)
    }
    func testCorruptionIsSeparatedFromUnseenAndOutsidePixels() {
        let truth = [Float](repeating: 0, count: 12), actual = [Float](repeating: 1, count: 12)
        let (m, _) = PCVRResidualMetrics.evaluate(truth: truth, actual: actual, width: 2,
                                                 classification: [0,0,1,2], previousError: [0,0,0,0])
        XCTAssertEqual(m.mae, 1)
        XCTAssertEqual(m.p95, 1)
        XCTAssertEqual(m.visibleMAE, 1)
        XCTAssertEqual(m.hiddenMAE, 1)
        XCTAssertEqual(m.hiddenFraction, 0.25)
        XCTAssertEqual(m.outsideFraction, 0.25)
        XCTAssertEqual(m.temporalErrorChange, 1)
    }
}
