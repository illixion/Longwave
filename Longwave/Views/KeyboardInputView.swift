import SwiftUI
import RoyalVNCKit

/// The VNC keyboard window: our own key grid, plus the extras that belong beside
/// it (typing route, dictation, gaze scroll pad).
///
/// It used to be a `TextField` whose edits were mirrored to the remote, with a
/// row of modifier toggles above it. That could only ever carry *characters*,
/// so a latched modifier never reached the remote alongside one — Ctrl+G typed a
/// "g". `VirtualKeyboardView` owns the caps instead, so every tap is a key.
struct KeyboardInputView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager

    @AppStorage(ConnectionDefaults.Keys.keyboardScrollPad) private var showsScrollPad = false

    #if os(visionOS)
    /// In-app dictation, so typing by voice into a remote desktop doesn't depend
    /// on the system keyboard's dictation session (see `DictationController`).
    /// macOS keeps its own dictation — the session that fails is visionOS's.
    @State private var dictation = DictationRelay()
    #endif

    private var sink: VNCKeyboardSink { VNCKeyboardSink(manager: connectionManager) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                header

                VirtualKeyboardView(sink: sink)

                if showsScrollPad {
                    // Gaze scrolling for the remote desktop — no mouse wheel.
                    ScrollPadView(
                        onVerticalTick: { steps in
                            connectionManager.scrollAtVirtualCursor(
                                wheel: steps > 0 ? .up : .down, steps: UInt32(abs(steps)))
                        },
                        onHorizontalTick: { steps in
                            connectionManager.scrollAtVirtualCursor(
                                wheel: steps > 0 ? .right : .left, steps: UInt32(abs(steps)))
                        }
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Keyboard — \(connectionManager.connectionTitle)")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                routeControl

                Spacer(minLength: 0)

                #if os(visionOS)
                dictationButton
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

            routeNote
            dictationNoteLabel
        }
        // Pinned to the keys' own width so a long caption can't stretch the
        // window past the keyboard it belongs to.
        .frame(width: VirtualKeyboardView.contentWidth)
        .multilineTextAlignment(.center)
    }

    // MARK: - Typing Route

    /// Lets the user pick how plain text is typed when a companion is paired.
    /// Hidden entirely when there's no companion (plain VNC keyboard).
    @ViewBuilder
    private var routeControl: some View {
        @Bindable var manager = connectionManager
        if manager.hasCompanionInput {
            Picker("Typing route", selection: $manager.keyboardRoute) {
                ForEach(VNCConnectionManager.KeyboardRoute.allCases) { route in
                    Text(route.label).tag(route)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    /// Surfaces the fallback when the companion route is selected but down.
    @ViewBuilder
    private var routeNote: some View {
        if connectionManager.hasCompanionInput, connectionManager.keyboardRoute == .companion {
            if connectionManager.companionInputAvailable {
                Label("Plain typing goes via the Mac companion — modified keys always use VNC.",
                      systemImage: "keyboard.badge.ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Companion unavailable — falling back to VNC keys. Enable “Allow keyboard control” on the Mac.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Dictation

    #if os(visionOS)
    private var dictationNoteLabel: some View { DictationNote(relay: dictation) }

    private var dictationButton: some View {
        DictationButton(relay: dictation) { text in
            connectionManager.routeInsertText(text)
        }
    }
    #else
    private var dictationNoteLabel: some View { EmptyView() }
    /// No in-app dictation on macOS: the system's own works there.
    private var dictationButton: some View { EmptyView() }
    #endif
}
