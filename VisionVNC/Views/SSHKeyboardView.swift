import SwiftUI

/// Terminal keyboard window: our own key grid wired straight to the PTY, plus a
/// gaze scroll pad for the scrollback.
///
/// The terminal's own quick-key row can latch ⌃/⌥/⇧, but it has no letters — a
/// modified letter had to be typed into the composer and *sent*, and if you
/// forgot the send step you just typed the letter. Here ⌃ then G is 0x07, as it
/// would be on a real keyboard.
struct SSHKeyboardView: View {
    @Environment(SSHTerminalManager.self) private var manager

    let sessionID: SSHSessionID

    @AppStorage(ConnectionDefaults.Keys.terminalScrollPad) private var showsScrollPad = true

    var body: some View {
        Group {
            if let session = manager.session(sessionID) {
                content(session)
            } else {
                ContentUnavailableView("Session ended", systemImage: "terminal")
            }
        }
    }

    @ViewBuilder
    private func content(_ session: SSHSession) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                header(session)

                VirtualKeyboardView(sink: SSHKeyboardSink(session: session))
                    // Raw key bytes aren't worth queueing the way composed text
                    // is — better to show they can't be sent than to drop them.
                    .disabled(!session.isReady)

                if showsScrollPad {
                    ScrollPadView { steps in
                        session.scrollLines(steps)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Keyboard — \(session.title)")
        }
    }

    private func header(_ session: SSHSession) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(session.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(session.username + "@" + session.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Text("⌘ and Caps Lock have no meaning over a terminal, so they're disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Pinned to the keys' own width so a long caption can't stretch the
        // window past the keyboard it belongs to.
        .frame(width: VirtualKeyboardView.contentWidth)
        .multilineTextAlignment(.center)
    }
}
