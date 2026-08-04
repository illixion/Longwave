import SwiftUI

/// What a keyboard window does with the keys our on-screen keyboard emits.
/// Implemented once per transport — VNC keysyms, Moonlight virtual-key codes —
/// so the key grid itself stays protocol-agnostic.
@MainActor
protocol VirtualKeyboardSink {
    /// One keystroke. `modifiers` is everything active for it; `held` is the
    /// subset a locked latch already has pressed down on the remote, so only the
    /// difference needs pressing and releasing around the key.
    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers)

    /// Hold or release a locked modifier on the remote. `allHeld` is the full
    /// held set *after* the change (Moonlight stamps a modifier mask on every
    /// event, so it needs more than the one that changed).
    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers)

    /// Type literal text — clipboard paste and dictation, where there are no
    /// modifiers to preserve and the transport's own text route is better.
    func insertText(_ text: String)
}

/// Our own on-screen keyboard: a US ANSI key grid where every cap sends a real
/// key event, with the modifier latches applied to it.
///
/// This replaces typing into a `TextField` and mirroring its edits, which could
/// only ever carry characters — a latched Ctrl was invisible to it, so Ctrl+G
/// reached the remote as a bare "g".
struct VirtualKeyboardView: View {
    let sink: any VirtualKeyboardSink

    @State private var latch: VirtualModifierLatch

    /// `initialLatch` exists so the previews below can show the armed and locked
    /// states; the app always starts clean.
    init(sink: any VirtualKeyboardSink, initialLatch: VirtualModifierLatch = VirtualModifierLatch()) {
        self.sink = sink
        _latch = State(initialValue: initialLatch)
    }

    private var shifted: Bool { latch.active.contains(.shift) }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.clusterGap) {
            VStack(spacing: Metrics.spacing) {
                ForEach(Array(VirtualKeyboardLayout.mainRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Metrics.spacing) {
                        ForEach(row) { cap in
                            keyButton(cap)
                        }
                    }
                }
            }

            VStack(spacing: Metrics.spacing) {
                ForEach(Array(VirtualKeyboardLayout.navRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Metrics.spacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cap in
                            if let cap {
                                keyButton(cap)
                            } else {
                                Color.clear.frame(width: Metrics.unit, height: Metrics.height)
                            }
                        }
                    }
                }
            }
        }
        .onDisappear(perform: releaseHeldModifiers)
    }

    /// Total width of the keyboard, so the hosting window can size itself to it.
    /// A row of *u* units always comes out `u * unit + (u - 1) * spacing` wide
    /// however many caps it is divided into — see `width(_:)`.
    static var contentWidth: CGFloat {
        func rowWidth(_ units: Double) -> CGFloat {
            units * Metrics.unit + (units - 1) * Metrics.spacing
        }
        return rowWidth(VirtualKeyboardLayout.mainRowUnits)
            + Metrics.clusterGap
            + rowWidth(VirtualKeyboardLayout.navRowUnits)
    }

    // MARK: - Key Caps

    @ViewBuilder
    private func keyButton(_ cap: VirtualKeyCap) -> some View {
        let state = cap.modifier.map(latch.state(of:)) ?? .off
        let label = Text(cap.displayLabel(shifted: shifted))
            .font(.system(size: Metrics.font, weight: .medium, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        // A locked latch stays down on the remote, so it gets the louder
        // treatment: one-shot is merely armed for the next key.
        switch state {
        case .locked:
            Button { activate(cap) } label: { label }
                .buttonStyle(.borderedProminent)
                .frame(width: width(cap), height: Metrics.height)
        case .oneShot:
            Button { activate(cap) } label: { label }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .frame(width: width(cap), height: Metrics.height)
        case .off:
            Button { activate(cap) } label: { label }
                .buttonStyle(.bordered)
                .frame(width: width(cap), height: Metrics.height)
        }
    }

    /// A cap spans its own units *and* the gaps between them, so every row comes
    /// out exactly `mainRowUnits` wide however it's divided up.
    private func width(_ cap: VirtualKeyCap) -> CGFloat {
        cap.width * Metrics.unit + (cap.width - 1) * Metrics.spacing
    }

    // MARK: - Dispatch

    private func activate(_ cap: VirtualKeyCap) {
        switch cap.action {
        case .modifier(let modifier):
            switch latch.tap(modifier) {
            case .none:
                break
            case .hold(let modifier):
                sink.setHeld(modifier, held: true, allHeld: latch.locked)
            case .release(let modifier):
                sink.setHeld(modifier, held: false, allHeld: latch.locked)
            }

        case .key(let key):
            let held = latch.locked
            let oneShot = latch.consumeOneShot()
            sink.press(key, modifiers: held.union(oneShot), held: held)

        case .paste:
            guard let text = Pasteboard.read(), !text.isEmpty else { return }
            sink.insertText(text)
        }
    }

    /// Locked latches are genuinely held down on the remote — leaving the window
    /// with one armed would strand it there.
    private func releaseHeldModifiers() {
        var remaining = latch.reset()
        for modifier in remaining.ordered.reversed() {
            remaining.remove(modifier)
            sink.setHeld(modifier, held: false, allHeld: remaining)
        }
    }

    // MARK: - Metrics

    private enum Metrics {
        #if os(visionOS)
        // Gaze targets want to be generous; this lands close to the system
        // keyboard's own key size.
        static let unit: CGFloat = 56
        static let height: CGFloat = 52
        static let spacing: CGFloat = 6
        static let font: CGFloat = 18
        static let clusterGap: CGFloat = 20
        #else
        static let unit: CGFloat = 36
        static let height: CGFloat = 32
        static let spacing: CGFloat = 4
        static let font: CGFloat = 13
        static let clusterGap: CGFloat = 14
        #endif
    }
}

/// The one-line explanation of the three-state latches, shared by both keyboard
/// windows.
let virtualKeyboardLatchHint =
    "Tap a modifier to arm it for the next key; tap again to lock it down (⌃-click works then too)."

#if DEBUG
/// Swallows keystrokes so the layout can be previewed without a connection.
private struct PreviewKeyboardSink: VirtualKeyboardSink {
    func press(_ key: VirtualKey, modifiers: VirtualModifiers, held: VirtualModifiers) {}
    func setHeld(_ modifier: VirtualModifiers, held: Bool, allHeld: VirtualModifiers) {}
    func insertText(_ text: String) {}
}

#Preview("Keyboard") {
    VirtualKeyboardView(sink: PreviewKeyboardSink())
        .padding(24)
}

#Preview("Shift armed, Ctrl locked") {
    var latch = VirtualModifierLatch()
    _ = latch.tap(.shift)
    _ = latch.tap(.control)
    _ = latch.tap(.control)
    return VirtualKeyboardView(sink: PreviewKeyboardSink(), initialLatch: latch)
        .padding(24)
}
#endif
