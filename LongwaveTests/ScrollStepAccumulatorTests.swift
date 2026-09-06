import XCTest
@testable import Longwave

final class ScrollStepAccumulatorTests: XCTestCase {

    func testTravelBelowOneStepIsCarriedNotDropped() {
        var accumulator = ScrollStepAccumulator(pointsPerStep: 10)

        // Four nudges of 3 points: nothing until the fourth crosses ten.
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 3)).dy, 0)
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 3)).dy, 0)
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 3)).dy, 0)
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 3)).dy, 1)
    }

    func testDirectionIsPreservedAndAxesAreIndependent() {
        var accumulator = ScrollStepAccumulator(pointsPerStep: 10)

        let steps = accumulator.steps(for: CGSize(width: -25, height: 20))
        XCTAssertEqual(steps.dx, -2)
        XCTAssertEqual(steps.dy, 2)

        // The 5 points left over on x survive into the next event.
        XCTAssertEqual(accumulator.steps(for: CGSize(width: -5, height: 0)).dx, -1)
    }

    func testFlickIsCappedPerEvent() {
        var accumulator = ScrollStepAccumulator(pointsPerStep: 10, maxStepsPerEvent: 10)

        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 900)).dy, 10)
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: -900)).dy, -10)
    }

    func testResetDropsPartialTravel() {
        var accumulator = ScrollStepAccumulator(pointsPerStep: 10)

        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 9)).dy, 0)
        accumulator.reset()
        // Without the reset those 9 points plus this 1 would have earned a step.
        XCTAssertEqual(accumulator.steps(for: CGSize(width: 0, height: 1)).dy, 0)
    }
}
