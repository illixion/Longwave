import SwiftUI

/// The Native keyboard window: the same key grid the VNC and Moonlight windows
/// use, plus dictation and the gaze scroll pad.
///
/// The Native stream had no keyboard window at all — only the hardware-keyboard
/// capture inside the stream view — so with nothing paired there was no way to
/// type into the Mac, and no way to send a shortcut even with "Allow keyboard
/// control" enabled in the companion. The header spells out which of the two
/// channels is carrying the keys, because that decides what the caps can do:
/// with keyboard control off, only plain typing gets through and the modifier and
/// special-key caps are disabled rather than silently inert.
struct MacNativeKeyboardView: View {
    @Environment(MacNativeStreamManager.self) private var screenManager

    @AppStorage(ConnectionDefaults.Keys.keyboardScrollPad) private var showsScrollPad = false

    #if os(visionOS)
    /// Same in-app dictation the VNC keyboard has: visionOS's own dictation lives
    /// in the system keyboard, whose session a streaming window kills (see
    /// `DictationController`). The other clients keep the system's own dictation.
    @State private var dictation = DictationRelay()
    #endif

    private var sink: MacNativeKeyboardSink { MacNativeKeyboardSink(manager: screenManager) }

    /// Whether either keyboard channel can carry literal text right now — the
    /// text channel outright, or the shortcut channel one keystroke at a time.
    private var canType: Bool { sink.supports(.paste) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                VirtualKeyboardView(sink: sink)

                if showsScrollPad {
                    // Gaze scrolling for the Mac's desktop — no mouse wheel. One
                    // step is one scroll line, matching the stream view's pinch.
                    ScrollPadView(
                        onVerticalTick: { steps in
                            screenManager.scrollAtVirtualCursor(deltaX: 0, deltaY: Int16(clamping: steps))
                        },
                        onHorizontalTick: { steps in
                            screenManager.scrollAtVirtualCursor(deltaX: Int16(clamping: steps), deltaY: 0)
                        }
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Keyboard — \(screenManager.title)")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Spacer(minLength: 0)

                #if os(visionOS)
                DictationButton(relay: dictation, isEnabled: canType) { text in
                    sink.insertText(text)
                }
                #endif

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

            channelNote
            #if os(visionOS)
            DictationNote(relay: dictation)
            #endif
        }
        // Pinned to the keys' own width so a long caption can't stretch the
        // window past the keyboard it belongs to.
        .frame(width: VirtualKeyboardView.contentWidth)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var channelNote: some View {
        switch screenManager.keyboardShortcutsAvailability {
        case .available:
            Label("Every key goes to the Mac, modifiers included.",
                  systemImage: "keyboard.badge.ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .disabled, .unknown:
            Label(screenManager.textInputAvailable
                  ? "Plain typing only — enable “Allow keyboard control” on the Mac for modifiers and special keys."
                  : "No keyboard channel is up. Enable “Allow keyboard control” or text injection on the Mac.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .accessibilityDenied:
            Label("Keyboard control needs Accessibility permission on the Mac.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
