import XCTest
@testable import Longwave

#if FOVEATED_ENABLED
/// `PCVRWarpBudget`, the depth warp's GPU budget: a pure step per stats
/// window, so its whole behaviour is checked here without a headset.
final class PCVRWarpBudgetTests: XCTestCase {
    private let configuration = PCVRWarpBudget.Configuration()
    /// 120 Hz: a budget of 6.67 ms at the default share of 0.8, and a raise under 5.67.
    private let period = 1.0 / 120

    private func run(_ budget: PCVRWarpBudget, gpuMs: [Double], period: Double? = nil) -> PCVRWarpBudget {
        gpuMs.reduce(budget) { $0.observing(gpuTime: $1 / 1000, period: period ?? self.period, configuration: configuration) }
    }

    func testStartsAtFullAndStaysThereUnderBudget() {
        let budget = run(PCVRWarpBudget(), gpuMs: Array(repeating: 5.3, count: 40))
        XCTAssertEqual(budget.tier, .full)
    }

    /// The headset's numbers (2026-11-16): 9.1-9.8 ms in the game cannot hold
    /// an 8.3 ms period, so the tier goes down a window at a time to the lowest.
    func testLowersATierPerWindowOverBudget() {
        var budget = run(PCVRWarpBudget(), gpuMs: [9.4])
        XCTAssertEqual(budget.tier, .reduced)
        budget = run(budget, gpuMs: [8.0])
        XCTAssertEqual(budget.tier, .minimal)
        budget = run(budget, gpuMs: [7.5, 7.5, 7.5])
        XCTAssertEqual(budget.tier, .minimal, "nothing below the lowest tier")
    }

    func testTheBudgetFollowsTheDisplayPeriod() {
        // 9.4 ms is over 0.8 of a 120 Hz period and of a 90 Hz one (8.9 ms), under it at 60 Hz (13.3 ms).
        XCTAssertEqual(run(PCVRWarpBudget(), gpuMs: [9.4], period: 1.0 / 90).tier, .reduced)
        XCTAssertEqual(run(PCVRWarpBudget(), gpuMs: [9.4], period: 1.0 / 60).tier, .full)
        XCTAssertEqual(PCVRWarpBudget.allowance(period: 1.0 / 90, configuration: configuration) * 1000, 8.889, accuracy: 0.001)
    }

    func testRaisesOnlyAfterTheHoldUnderTheRaiseThreshold() {
        let lowered = run(PCVRWarpBudget(), gpuMs: [9.4])
        // Between the raise threshold (5.67 ms) and the budget: stays.
        XCTAssertEqual(run(lowered, gpuMs: Array(repeating: 6.0, count: 30)).tier, .reduced)
        // Under it, but not for the whole hold: stays; a window in between starts the count again.
        XCTAssertEqual(run(lowered, gpuMs: [5.0, 5.0, 5.0]).tier, .reduced)
        XCTAssertEqual(run(lowered, gpuMs: [5.0, 5.0, 5.0, 6.0, 5.0, 5.0, 5.0]).tier, .reduced)
        XCTAssertEqual(run(lowered, gpuMs: [5.0, 5.0, 5.0, 5.0]).tier, .full)
    }

    /// A scene between two tiers: each raise that is taken straight back
    /// doubles the wait before the next, so the tier does not pump.
    func testARaiseTakenBackDoublesTheHold() {
        var budget = run(PCVRWarpBudget(), gpuMs: [9.4])
        var raises: [Int] = []
        var window = 0
        for _ in 0..<200 {
            let before = budget.tier
            // Cheap at the lower tier, over budget at full.
            budget = run(budget, gpuMs: [budget.tier == .full ? 7.5 : 5.0])
            window += 1
            if budget.tier < before { raises.append(window) }
        }
        XCTAssertGreaterThanOrEqual(raises.count, 4)
        let gaps = zip(raises, raises.dropFirst()).map { $1 - $0 }
        for (earlier, later) in zip(gaps, gaps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier, "raises come no closer together: \(gaps)")
        }
        XCTAssertGreaterThan(gaps.last ?? 0, 2 * configuration.hold, "the hold has grown: \(gaps)")
        XCTAssertLessThanOrEqual(gaps.max() ?? 0, configuration.maximumHold + 1)
    }

    /// A raise that holds through its probation puts the hold back, and a
    /// later overrun is the scene's, not the raise's.
    func testARaiseThatHoldsResetsTheHold() {
        var budget = run(PCVRWarpBudget(), gpuMs: [9.4, 5, 5, 5, 5, 7.5])   // raised, straight back: hold 8
        XCTAssertEqual(budget.tier, .reduced)
        budget = run(budget, gpuMs: Array(repeating: 5.0, count: 7))
        XCTAssertEqual(budget.tier, .reduced, "seven windows are not the doubled hold")
        budget = run(budget, gpuMs: [5.0])
        XCTAssertEqual(budget.tier, .full)
        budget = run(budget, gpuMs: Array(repeating: 5.0, count: configuration.probeWindows) + [9.4])
        XCTAssertEqual(budget.tier, .reduced)
        XCTAssertEqual(run(budget, gpuMs: Array(repeating: 5.0, count: configuration.hold)).tier, .full,
                       "the usual hold again")
    }

    func testAWindowWithoutAMeasurementChangesNothing() {
        let budget = run(PCVRWarpBudget(), gpuMs: [9.4, 5, 5])
        XCTAssertEqual(budget.observing(gpuTime: nil, period: period), budget)
        XCTAssertEqual(budget.observing(gpuTime: 0.005, period: nil), budget)
        XCTAssertEqual(budget.observing(gpuTime: 0, period: period), budget)
    }

    func testATierOnlyEverLimitsTheMarch() {
        let defaults = PCVRWarpMarch(maxSteps: 32, stepTexels: 2, fillsFromOtherEye: true)
        XCTAssertEqual(PCVRWarpTier.full.limiting(defaults), defaults)
        XCTAssertEqual(PCVRWarpTier.reduced.limiting(defaults), PCVRWarpMarch(maxSteps: 20, stepTexels: 3, fillsFromOtherEye: true))
        XCTAssertEqual(PCVRWarpTier.minimal.limiting(defaults), PCVRWarpMarch(maxSteps: 12, stepTexels: 4, fillsFromOtherEye: false))
        // Settings already below a tier stand.
        let low = PCVRWarpMarch(maxSteps: 8, stepTexels: 6, fillsFromOtherEye: false)
        for tier in PCVRWarpTier.allCases { XCTAssertEqual(tier.limiting(low), low) }
    }

    func testTierNames() {
        for tier in PCVRWarpTier.allCases {
            XCTAssertEqual(PCVRWarpTier(name: tier.name), tier)
            XCTAssertEqual(PCVRWarpTier(name: "\(tier.rawValue)"), tier)
        }
        XCTAssertNil(PCVRWarpTier(name: "auto"))
        XCTAssertEqual(PCVRWarpTier.full.higher, .full)
        XCTAssertEqual(PCVRWarpTier.minimal.lower, .minimal)
    }
}
#endif
