import SwiftUI

/// A plus-shaped scroll control: four arms around a hub, one per direction.
/// Press an arm for a line, hold it to keep scrolling — faster the longer it's
/// held. It lives beside the key grid in the keyboard windows so gaze users —
/// who have no wheel, and for whom a two-hand pinch-drag isn't always practical
/// — can still scroll.
///
/// It replaces a pair of spring-back sliders, which read as a mixing desk
/// rather than a scroller, sat under the keyboard in a band of empty space, and
/// needed a *drag* to do anything: the arms are plain press targets, which is
/// both a bigger gaze target and one gesture simpler.
struct ScrollPadView: View {
    /// Positive = scroll up; magnitude is the step count for this tick.
    var onVerticalTick: (Int) -> Void
    /// Positive = scroll right; magnitude is the step count for this tick.
    /// Omitted where there is no horizontal axis to scroll (a terminal), which
    /// also drops those arms — an inert control is worse than no control.
    var onHorizontalTick: ((Int) -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Label("Scroll", systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    spacer
                    ScrollArm(systemImage: "chevron.up") { onVerticalTick($0) }
                    spacer
                }
                GridRow {
                    if let onHorizontalTick {
                        ScrollArm(systemImage: "chevron.left") { onHorizontalTick(-$0) }
                    } else {
                        spacer
                    }

                    hub

                    if let onHorizontalTick {
                        ScrollArm(systemImage: "chevron.right") { onHorizontalTick($0) }
                    } else {
                        spacer
                    }
                }
                GridRow {
                    spacer
                    ScrollArm(systemImage: "chevron.down") { onVerticalTick(-$0) }
                    spacer
                }
            }
        }
    }

    private var spacer: some View {
        Color.clear.frame(width: ScrollArm.side, height: ScrollArm.side)
    }

    /// Inert centre — it gives the plus its shape and marks where the arms
    /// point from.
    private var hub: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: 10, height: 10)
            .frame(width: ScrollArm.side, height: ScrollArm.side)
    }
}

/// One arm of the plus: a press target that ticks once immediately and then
/// repeats while it's held.
private struct ScrollArm: View {
    let systemImage: String
    /// Called with a positive step count; the arm's owner applies the sign.
    let onTick: (Int) -> Void

    static let side: CGFloat = 64

    /// Key-repeat cadence: one tick on press, a pause to prove it's a hold,
    /// then a steady stream that speeds up the longer the hold lasts.
    private static let repeatDelay: Duration = .milliseconds(350)
    private static let repeatInterval: Duration = .milliseconds(60)
    private static let maxSteps = 6

    @State private var isPressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isPressed ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.fill.tertiary))
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .armHoverEffect()
            // A Button fires on release, which is exactly the wrong moment for
            // something that has to repeat while held. `minimumDistance: 0`
            // reports the press itself.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press() }
                    .onEnded { _ in lift() }
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .onDisappear(perform: lift)
    }

    private var accessibilityLabel: String {
        switch systemImage {
        case "chevron.up": "Scroll up"
        case "chevron.down": "Scroll down"
        case "chevron.left": "Scroll left"
        default: "Scroll right"
        }
    }

    private func press() {
        guard !isPressed else { return }
        isPressed = true
        onTick(1)

        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: Self.repeatDelay)
            var held = Duration.zero
            while !Task.isCancelled {
                held += Self.repeatInterval
                // Ramps to `maxSteps` over a couple of seconds of holding, so a
                // long page takes a hold rather than a hundred presses.
                let steps = min(Self.maxSteps, 1 + Int(held.components.seconds * 2))
                onTick(steps)
                try? await Task.sleep(for: Self.repeatInterval)
            }
        }
    }

    private func lift() {
        repeatTask?.cancel()
        repeatTask = nil
        isPressed = false
    }
}

private extension View {
    /// The gaze/pointer highlight that tells you an arm is a target. visionOS
    /// and iOS have it; macOS has no equivalent, and this file compiles there
    /// too (the VNC and Native keyboards are shared).
    @ViewBuilder
    func armHoverEffect() -> some View {
        #if os(macOS)
        self
        #else
        self.hoverEffect()
        #endif
    }
}

#Preview {
    ScrollPadView(
        onVerticalTick: { print("v \($0)") },
        onHorizontalTick: { print("h \($0)") }
    )
    .padding(40)
}
