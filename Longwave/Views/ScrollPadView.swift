import SwiftUI
import Combine

/// A two-axis scroll "joystick" built from a vertical and a horizontal slider.
/// Each slider springs back to center when released; while it's held off-center
/// the pad emits periodic scroll ticks (step count proportional to how far it's
/// pushed) via the callbacks. It lives in the keyboard windows so gaze users —
/// who have no mouse wheel and no good scroll gesture — can still scroll.
struct ScrollPadView: View {
    /// Positive = scroll up; magnitude is the step count for this tick.
    var onVerticalTick: (Int) -> Void
    /// Positive = scroll right; magnitude is the step count for this tick.
    /// Omitted where there is no horizontal axis to scroll (a terminal), which
    /// also drops the slider — an inert control is worse than no control.
    var onHorizontalTick: ((Int) -> Void)?

    @State private var vValue: Double = 0
    @State private var hValue: Double = 0
    @State private var ticker = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    private let deadzone = 0.08
    private let maxSteps = 6.0

    var body: some View {
        VStack(spacing: 12) {
            Label("Scroll", systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 32) {
                VStack(spacing: 6) {
                    Slider(value: $vValue, in: -1...1) { editing in
                        if !editing { vValue = 0 }
                    }
                    .rotationEffect(.degrees(-90))
                    .frame(width: 180)
                    .frame(width: 44, height: 196)
                    Text("Vertical").font(.caption2).foregroundStyle(.secondary)
                }

                if onHorizontalTick != nil {
                    VStack(spacing: 6) {
                        Slider(value: $hValue, in: -1...1) { editing in
                            if !editing { hValue = 0 }
                        }
                        .frame(width: 196)
                        Text("Horizontal").font(.caption2).foregroundStyle(.secondary)
                        Spacer().frame(height: 14)
                    }
                }
            }
        }
        .onReceive(ticker) { _ in
            emit(vValue, onVerticalTick)
            if let onHorizontalTick { emit(hValue, onHorizontalTick) }
        }
        .onDisappear {
            vValue = 0
            hValue = 0
        }
    }

    private func emit(_ value: Double, _ send: (Int) -> Void) {
        guard abs(value) > deadzone else { return }
        let steps = Int((value * maxSteps).rounded())
        if steps != 0 { send(steps) }
    }
}
