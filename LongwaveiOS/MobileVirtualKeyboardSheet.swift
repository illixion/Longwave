import SwiftUI

/// Fits the shared on-screen keyboard into a phone-width sheet.
///
/// `VirtualKeyboardView` is a fixed-metric US ANSI grid — a main block plus a nav
/// cluster, several hundred points wide at its non-visionOS 36 pt unit. That is
/// fine in a visionOS window and on an iPad, and far too wide for a portrait
/// iPhone, where it would simply be clipped at both edges: the left-hand keys and
/// the whole nav cluster unreachable.
///
/// Scaling to fit is preferred over dropping keys, because every cap on that grid
/// is there to send something a remote desktop needs and cannot be typed any
/// other way (F-keys, Esc, the arrow cluster). But scaling has a floor: below
/// roughly 0.7 the caps stop being reliably tappable, so past that point the
/// keyboard keeps a usable size and scrolls horizontally instead. In practice
/// portrait scrolls a little and landscape fits outright.
struct MobileVirtualKeyboardSheet: View {
    let sink: any VirtualKeyboardSink

    /// Smallest scale that still leaves the caps comfortably hittable.
    private let minimumScale: CGFloat = 0.7
    private static let margin: CGFloat = 12

    @State private var intrinsic: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - 2 * Self.margin
            let fit = intrinsic.width > 0 ? available / intrinsic.width : 1
            // Never upscale past natural size; never shrink below the floor.
            let scale = min(1, max(fit, minimumScale))
            let scaled = CGSize(
                width: intrinsic.width * scale,
                height: intrinsic.height * scale
            )

            Group {
                if scaled.width > available + 0.5 {
                    ScrollView(.horizontal) {
                        keyboard(scale: scale, scaled: scaled)
                    }
                    .scrollIndicators(.visible)
                } else {
                    keyboard(scale: scale, scaled: scaled)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Self.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// `scaleEffect` is a render-time transform that leaves layout size alone, so
    /// the explicit frame restates the scaled size for the scroll view to measure
    /// — anchored and aligned to the same corner, or the two disagree and the grid
    /// drifts out from under its own touch targets.
    private func keyboard(scale: CGFloat, scaled: CGSize) -> some View {
        VirtualKeyboardView(sink: sink)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                intrinsic = size
            }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: scaled.width, height: scaled.height, alignment: .topLeading)
    }
}
