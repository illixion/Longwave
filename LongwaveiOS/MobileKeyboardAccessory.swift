import SwiftUI
import UIKit

/// Modifier typing on top of the system keyboard — the approach iOS
/// remote-desktop clients use, and the only one that can work here.
///
/// iOS's software keyboard has no ⌃/⌥/⌘ keys at all and reports only inserted
/// text, so a modified keystroke can never arrive from it directly. What it does
/// report is *which character* was typed, and `VirtualKeyboardLayout.stroke(typing:)`
/// maps a character back to the physical key that produces it ("!" is the 1 key
/// with Shift). So: latch a modifier in this strip, type a letter on the system
/// keyboard, and the keystroke goes out as real keysyms with the modifier wrapped
/// around it — the same path `VNCKeyboardSink.press` already takes for our own
/// on-screen grid, with the same three-state latches.
///
/// That is why the latch lives here rather than in the text field: the character
/// the keyboard hands us is only half the keystroke.
struct MobileKeyboardAccessory: View {
    let sink: any VirtualKeyboardSink
    /// Raises and dismisses the system keyboard by driving the capture field's
    /// first-responder status.
    @Binding var isActive: Bool
    /// Opens the full ANSI grid, for the caps a phone keyboard cannot type.
    var onOpenFullKeyboard: () -> Void

    @State private var latch = VirtualModifierLatch()

    private static let modifiers: [(VirtualModifiers, String)] = [
        (.control, "⌃"),
        (.option, "⌥"),
        (.command, "⌘"),
        (.shift, "⇧"),
    ]

    private static let specials: [(VirtualKey, String)] = [
        (.escape, "esc"),
        (.tab, "⇥"),
        (.left, "←"),
        (.down, "↓"),
        (.up, "↑"),
        (.right, "→"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // The capture field is invisible and 1×1: it exists only to own first
            // responder so the system keyboard appears and reports its text.
            MobileKeyInputField(
                isFocused: isActive,
                onInsert: insert,
                onDeleteBackward: { press(.backspace) },
                onResignFirstResponder: {
                    // The user dismissed the keyboard itself — release anything
                    // latched down on the remote rather than stranding it.
                    releaseHeldModifiers()
                    isActive = false
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.modifiers, id: \.0.rawValue) { modifier, label in
                        modifierButton(modifier, label: label)
                    }

                    Divider().frame(height: 22)

                    ForEach(Array(Self.specials.enumerated()), id: \.offset) { _, entry in
                        Button(entry.1) { press(entry.0) }
                            .buttonStyle(.bordered)
                            .disabled(!sink.supports(.key(entry.0)))
                    }

                    Divider().frame(height: 22)

                    Button {
                        onOpenFullKeyboard()
                    } label: {
                        Image(systemName: "keyboard.badge.ellipsis")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Full keyboard")

                    Button {
                        releaseHeldModifiers()
                        isActive = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Hide keyboard")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .background(.bar)
        }
        .onDisappear(perform: releaseHeldModifiers)
    }

    // MARK: - Strip buttons

    @ViewBuilder
    private func modifierButton(_ modifier: VirtualModifiers, label: String) -> some View {
        // Same visual grammar as the full grid: a locked latch is genuinely held
        // down on the remote and gets the louder treatment; armed is merely
        // waiting for the next key.
        switch latch.state(of: modifier) {
        case .locked:
            Button(label) { tap(modifier) }
                .buttonStyle(.borderedProminent)
        case .oneShot:
            Button(label) { tap(modifier) }
                .buttonStyle(.bordered)
                .tint(.accentColor)
        case .off:
            Button(label) { tap(modifier) }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Dispatch

    private func tap(_ modifier: VirtualModifiers) {
        switch latch.tap(modifier) {
        case .none:
            break
        case .hold(let modifier):
            sink.setHeld(modifier, held: true, allHeld: latch.locked)
        case .release(let modifier):
            sink.setHeld(modifier, held: false, allHeld: latch.locked)
        }
    }

    /// A character came out of the system keyboard. Resolve it back to a physical
    /// key so the latched modifiers can be applied to it.
    private func insert(_ text: String) {
        for character in text {
            if character == "\n" || character == "\r" {
                press(.return)
                continue
            }
            guard let stroke = VirtualKeyboardLayout.stroke(typing: character) else {
                // Nothing on a US ANSI keyboard types this — emoji, or a glyph
                // from another layout. There is no keysym pair to send, so it
                // goes as literal text and any latched modifier is meaningless.
                sink.insertText(String(character))
                continue
            }
            // The keyboard already applied Shift to produce the glyph, so add it
            // back: VNC wants the shifted keysym *and* the Shift modifier.
            var modifiers = latch.locked
            modifiers.formUnion(latch.consumeOneShot())
            if stroke.shift { modifiers.insert(.shift) }
            sink.press(stroke.key, modifiers: modifiers, held: latch.locked)
        }
    }

    private func press(_ key: VirtualKey) {
        let held = latch.locked
        let oneShot = latch.consumeOneShot()
        sink.press(key, modifiers: held.union(oneShot), held: held)
    }

    /// Locked latches are really down on the remote; leaving without releasing
    /// them strands the far end with a stuck Ctrl.
    private func releaseHeldModifiers() {
        var remaining = latch.reset()
        for modifier in remaining.ordered.reversed() {
            remaining.remove(modifier)
            sink.setHeld(modifier, held: false, allHeld: remaining)
        }
    }
}

/// Invisible text field that raises the system keyboard and forwards what it
/// types, without ever holding any text of its own.
///
/// A real `UITextField` rather than a bare `UIKeyInput` view, because
/// `TextInputActivity` finds the active text responder by polling — so this
/// automatically makes `HardwareKeyboardView` stand down instead of the two
/// fighting over first responder.
private struct MobileKeyInputField: UIViewRepresentable {
    var isFocused: Bool
    var onInsert: (String) -> Void
    var onDeleteBackward: () -> Void
    var onResignFirstResponder: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        // Every one of these would otherwise corrupt what reaches the remote:
        // autocorrection rewrites words after the fact, smart quotes turn " into
        // a curly quote with no keysym, and capitalisation invents Shift presses.
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = .default
        // Keeping one space in the field is what makes backspace reportable: with
        // an empty field iOS sends no deletion at all.
        field.text = " "
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.owner = self
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var owner: MobileKeyInputField

        init(owner: MobileKeyInputField) {
            self.owner = owner
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                owner.onDeleteBackward()
            } else {
                owner.onInsert(string)
            }
            // Never accept the edit: the field is a keystroke source, not a text
            // buffer, and its contents must stay exactly the one sentinel space.
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            owner.onInsert("\n")
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            owner.onResignFirstResponder()
        }
    }
}
