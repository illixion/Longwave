import SwiftUI

// MARK: - Glass

extension View {
    /// visionOS glass background; the iOS Liquid Glass equivalent on iPhone and
    /// iPad; a no-op on macOS, where the window supplies its own background and
    /// `glassBackgroundEffect` doesn't exist.
    ///
    /// `AudioStreamView` and `AudioPlayerPanel` are shared with the macOS app, so
    /// anything visionOS-only in them has to be spelled this way rather than
    /// wrapped in `#if os(visionOS)` like `NativeStreamView` is.
    ///
    /// iOS has the material but not the spelling: `glassBackgroundEffect()` is
    /// visionOS-only, while iOS 26 exposes the same thing as `glassEffect(in:)`.
    /// The corner radius restates what visionOS's default panel shape gives you.
    @ViewBuilder
    func platformGlassBackground() -> some View {
        #if os(visionOS)
        glassBackgroundEffect()
        #elseif os(iOS)
        glassEffect(in: .rect(cornerRadius: 20))
        #else
        self
        #endif
    }
}
