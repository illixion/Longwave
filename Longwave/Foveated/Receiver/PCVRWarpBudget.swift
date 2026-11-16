#if FOVEATED_ENABLED
import Foundation

/// How far a depth-warp ray is marched and whether the other eye fills what
/// it uncovers: the three settings of `PCVRDepthWarper` that trade GPU time
/// for how large a head move is corrected per pixel.
nonisolated struct PCVRWarpMarch: Equatable, Sendable {
    var maxSteps: Int
    var stepTexels: Float
    var fillsFromOtherEye: Bool
}

/// The depth warp's quality, lowered by `PCVRWarpBudget` while a display
/// frame's GPU time is over its share of the display period.
///
/// A lower tier never changes how a still or slowly moving head's picture is
/// warped: its march is as long as the eye's move needs, and a short one is
/// the same at every tier. It bounds the worst case instead: fewer, longer
/// steps for a large move (near edges land up to a step off), and at
/// `minimal` the uncovered strips are smudged from beside the edge rather
/// than marched again through the other eye.
nonisolated enum PCVRWarpTier: Int, CaseIterable, Comparable, Sendable {
    /// The settings as given (`PCVRShellDepthWarp`: 32 steps of 2 texels, other-eye fill).
    case full = 0
    case reduced = 1
    /// 12 steps of 4 texels and no other-eye fill: what brought the warp
    /// from 9.1-9.8 ms of GPU a display frame to under 7 in Cyberpunk 2077
    /// (Vision Pro M5, 2026-11-16).
    case minimal = 2

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var name: String {
        switch self {
        case .full: "full"
        case .reduced: "reduced"
        case .minimal: "minimal"
        }
    }

    init?(name: String) {
        guard let tier = Self.allCases.first(where: { $0.name == name }) ?? Int(name).flatMap(Self.init(rawValue:)) else { return nil }
        self = tier
    }

    /// The next tier down in quality (cheaper), or this one at the bottom.
    var lower: Self { Self(rawValue: rawValue + 1) ?? self }
    /// The next tier up in quality, or this one at the top.
    var higher: Self { Self(rawValue: rawValue - 1) ?? self }

    /// `march` held to this tier: never more steps, shorter steps or more
    /// fills than it was given, so a setting already below the tier stands.
    func limiting(_ march: PCVRWarpMarch) -> PCVRWarpMarch {
        switch self {
        case .full:
            march
        case .reduced:
            PCVRWarpMarch(maxSteps: min(march.maxSteps, 20), stepTexels: max(march.stepTexels, 3),
                          fillsFromOtherEye: march.fillsFromOtherEye)
        case .minimal:
            PCVRWarpMarch(maxSteps: min(march.maxSteps, 12), stepTexels: max(march.stepTexels, 4), fillsFromOtherEye: false)
        }
    }
}

/// Keeps the depth warp inside a share of the display period: lowers its tier
/// when a window's GPU time is over the budget, raises it again once the time
/// has stayed well under for a while.
///
/// **Why a share of the measured period.** visionOS picks the display rate
/// itself (120, 90, 60 or 45 Hz) from heat and missed frames. A display
/// frame over the period misses its refresh, the rate drops, and every stage
/// after it is quantised to the longer period: the warp at 9.1-9.8 ms could
/// not hold 120 Hz (8.3 ms) and the display sat at 90 or 45 (Vision Pro M5,
/// 2026-11-16). The budget follows whatever period the loop observes rather
/// than assuming one.
///
/// **Hysteresis.** Lowering is immediate (one window, half a second of
/// frames, over budget). Raising needs `hold` consecutive windows under
/// `raiseFraction` of the budget, since the tier above costs more by an
/// amount only trying it shows; a raise that is taken back within
/// `probeWindows` doubles `hold` (to `maximumHold` at most), so a scene that
/// sits between two tiers settles on the lower one instead of pumping.
///
/// A value type with one pure step, for the tests.
nonisolated struct PCVRWarpBudget: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        /// The share of the display period a display frame's GPU time may take.
        /// Reprojection on one plane, the least this presenter can do, already
        /// took 5.0 ms (0.6 of a 120 Hz period) on the headset, so a share
        /// below that would pin the lowest tier for nothing.
        var share = 0.8
        /// Raise only under this fraction of the budget.
        var raiseFraction = 0.85
        /// Windows under the raise threshold before a raise, at first.
        var hold = 4
        var maximumHold = 120
        /// A lowering this soon after a raise means the raise was wrong.
        var probeWindows = 4
    }

    static let defaultShare = Configuration().share

    private(set) var tier: PCVRWarpTier = .full
    /// Consecutive windows under the raise threshold.
    private(set) var calm = 0
    /// Windows under the raise threshold a raise takes now.
    private(set) var hold: Int?
    /// Windows since the last raise, while that is still on probation.
    private(set) var sinceRaise: Int?

    /// The GPU time allowed, seconds.
    static func allowance(period: Double, configuration: Configuration) -> Double {
        period * configuration.share
    }

    /// One window: its mean GPU time and the display period, both seconds.
    /// A window without a measurement leaves everything as it was.
    func observing(gpuTime: Double?, period: Double?, configuration: Configuration = Configuration()) -> Self {
        guard let gpuTime, let period, gpuTime > 0, period > 0 else { return self }
        var next = self
        let baseHold = max(configuration.hold, 1)
        let hold = next.hold ?? baseHold
        let allowance = Self.allowance(period: period, configuration: configuration)
        if gpuTime > allowance {
            next.calm = 0
            next.sinceRaise = nil
            guard tier != tier.lower else { return next }
            next.tier = tier.lower
            // Straight back down after a raise: wait twice as long before
            // the next try. Otherwise the scene itself got heavier.
            next.hold = sinceRaise != nil ? min(hold * 2, max(configuration.maximumHold, baseHold)) : nil
            return next
        }
        if let since = sinceRaise {
            // The raise held through its probation: the next one waits the
            // usual time again.
            let survived = since + 1 >= configuration.probeWindows
            next.sinceRaise = survived ? nil : since + 1
            if survived { next.hold = nil }
        }
        if gpuTime < allowance * configuration.raiseFraction {
            next.calm += 1
            if next.calm >= (next.hold ?? baseHold), tier != tier.higher {
                next.tier = tier.higher
                next.calm = 0
                next.sinceRaise = 0
            }
        } else {
            next.calm = 0
        }
        return next
    }
}
#endif
