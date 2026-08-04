#if MOONLIGHT_ENABLED
import SwiftUI
@preconcurrency import MoonlightCommonC

/// The Moonlight keyboard window: our own key grid, plus Ctrl+Alt+Del and the
/// gaze scroll pad.
///
/// Like the VNC one, this replaced a `TextField` whose edits were mirrored to the
/// host. Text can't carry a modifier, so a latched Ctrl was dropped on the way —
/// every cap here sends a real virtual-key event with the modifier mask set.
struct MoonlightKeyboardView: View {
    @AppStorage(ConnectionDefaults.Keys.keyboardScrollPad) private var showsScrollPad = false

    private let sink = MoonlightKeyboardSink()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                VirtualKeyboardView(sink: sink)

                if showsScrollPad {
                    ScrollPadView(
                        onVerticalTick: { steps in
                            LiSendHighResScrollEvent(Int16(clamping: steps * 20))
                        },
                        onHorizontalTick: { steps in
                            LiSendHighResHScrollEvent(Int16(clamping: steps * 20))
                        }
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Moonlight Keyboard")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button("Ctrl+Alt+Del") {
                    sink.sendSecureAttention()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Spacer(minLength: 0)

                Button {
                    showsScrollPad.toggle()
                } label: {
                    Label("Scroll pad", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .tint(showsScrollPad ? .accentColor : nil)
            }

            Text(virtualKeyboardLatchHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Pinned to the keys' own width so a long caption can't stretch the
        // window past the keyboard it belongs to.
        .frame(width: VirtualKeyboardView.contentWidth)
        .multilineTextAlignment(.center)
    }
}
#endif
