import SwiftUI

/// The floating capsule of controls at the bottom of every mobile stream —
/// VNC, Native desktop and Moonlight all use it, so its touch behaviour is
/// defined once.
///
/// Two things matter here, both learned from missed taps. Every button gets a
/// finger-sized hit target (`MobileChromeButtonStyle`) rather than the bare
/// glyph, which at `.title3` is barely 20 points. And the capsule itself
/// swallows any tap that lands between buttons: the view under it is the
/// `MobilePointerSurface`, where a near miss becomes a click on the remote and
/// a double near miss toggles the zoom.
struct MobileChromeBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .buttonStyle(MobileChromeButtonStyle())
        .font(.title3)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(in: .capsule)
        .contentShape(.capsule)
        // Deliberately empty: claims the tap so it never reaches the pointer
        // surface below. Buttons inside still win over this gesture.
        .onTapGesture {}
    }
}

/// A borderless glyph button with an Apple-HIG 44-point minimum hit target.
///
/// Keeps the default look (tinted glyph, dimmed when disabled, pressed
/// feedback) — only the touchable area changes. `contentShape` is what makes
/// the transparent margin around the glyph count as the button.
struct MobileChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            .opacity(isEnabled ? (configuration.isPressed ? 0.4 : 1) : 0.35)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
