//  FoveatedImmersionStyle+SwiftUI.swift
//
//  Bridges the persisted, framework-free `FoveatedImmersionStyle` to SwiftUI's
//  `ImmersionStyle`. It lives apart from the model so `SavedConnection` stays
//  testable with the feature flag off, and apart from the app so the mapping is
//  stated once for both the scene and the PCVR tab's picker.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI

extension FoveatedImmersionStyle {
    /// The SwiftUI style the immersive space opens in. Existential, because that
    /// is what `immersionStyle(selection:in:)` binds to.
    var systemStyle: any ImmersionStyle {
        switch self {
        case .mixed: .mixed
        case .progressive: .progressive
        }
    }

    /// The reverse, for the binding's setter. `ImmersionStyle` conformers are
    /// opaque system types with no case to switch on, so identity is established
    /// by type — which is exactly as much as the API promises. Anything else,
    /// `.full` included, yields nil rather than a guess: the scene only ever
    /// offers these two, and a style we did not ask for is not one to record.
    init?(systemStyle: any ImmersionStyle) {
        switch systemStyle {
        case is ProgressiveImmersionStyle: self = .progressive
        case is MixedImmersionStyle: self = .mixed
        default: return nil
        }
    }
}
#endif
