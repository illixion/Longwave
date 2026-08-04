import SwiftUI
import RoyalVNCKit

struct KeyboardInputView: View {
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool

    #if os(visionOS)
    /// In-app dictation, so typing by voice into a remote desktop doesn't depend on
    /// the system keyboard's dictation session (see `DictationController`). macOS
    /// keeps its own dictation — the session that fails is visionOS's.
    @State private var dictation = DictationController()
    @State private var textBeforeDictation = ""
    #endif

    // Modifier key toggle state
    @State private var ctrlActive = false
    @State private var altActive = false
    @State private var shiftActive = false
    @State private var cmdActive = false

    var body: some View {
        NavigationStack {
        VStack(spacing: 24) {
            Text("Type text to send to the remote desktop")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            routeControl

            typingRow

            dictationNoteLabel

            // Modifier keys
            HStack(spacing: 12) {
                modifierToggle("Ctrl", isActive: $ctrlActive, keyDown: .control, keyUp: .control)
                modifierToggle("Alt", isActive: $altActive, keyDown: .option, keyUp: .option)
                modifierToggle("Shift", isActive: $shiftActive, keyDown: .shift, keyUp: .shift)
                modifierToggle("Cmd", isActive: $cmdActive, keyDown: .command, keyUp: .command)
            }

            // Special keys
            HStack(spacing: 12) {
                specialKeyButton("Esc", keyCode: .escape)
                specialKeyButton("Tab", keyCode: .tab)
                specialKeyButton("Enter", keyCode: .return)
                specialKeyButton("⌫", keyCode: .delete)
                specialKeyButton("⌦", keyCode: .forwardDelete)
            }

            // Arrow keys
            VStack(spacing: 8) {
                specialKeyButton("↑", keyCode: .upArrow)
                HStack(spacing: 16) {
                    specialKeyButton("←", keyCode: .leftArrow)
                    specialKeyButton("↓", keyCode: .downArrow)
                    specialKeyButton("→", keyCode: .rightArrow)
                }
            }

            // Function keys
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(functionKeys, id: \.label) { fk in
                        specialKeyButton(fk.label, keyCode: fk.keyCode)
                    }
                }
                .padding(.horizontal)
            }

            // Scroll pad — gaze scrolling for the remote desktop (no mouse wheel).
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

            Spacer()
        }
        .padding(.top)
        .navigationTitle("Keyboard — \(connectionManager.connectionTitle)")
        .onAppear {
            isTextFieldFocused = true
        }
        .onDisappear {
            releaseAllModifiers()
            #if os(visionOS)
            Task { await dictation.cancel() }
            #endif
        }
        #if os(visionOS)
        // Only settled phrases reach the field: it mirrors every change onto the
        // remote as typing, and the recognizer's revisions would arrive there as
        // backspace-and-retype churn.
        .onChange(of: dictation.settledTranscript) { _, text in
            textInput = textBeforeDictation + text
        }
        #endif
        } // NavigationStack
    }

    // MARK: - Typing

    /// The mirror field: every edit is sent onward as typing (see `sendDelta`),
    /// whether it came from the keyboard or from dictation.
    private var typingRow: some View {
        HStack(spacing: 12) {
            TextField("Type here…", text: $textInput)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isTextFieldFocused)
                .onChange(of: textInput) { oldValue, newValue in
                    sendDelta(old: oldValue, new: newValue)
                }
                .onSubmit {
                    connectionManager.sendKeyDown(.return)
                    connectionManager.sendKeyUp(.return)
                }
            dictationButton
        }
        .padding(.horizontal)
    }

    // MARK: - Dictation

    #if os(visionOS)
    @ViewBuilder
    private var dictationNoteLabel: some View {
        if let note = dictationNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(dictation.isListening ? Color.secondary : Color.orange)
        }
    }

    private var dictationButton: some View {
        Button {
            Task { await toggleDictation() }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.title3)
        }
        .buttonStyle(.bordered)
        .tint(dictation.isListening ? .red : nil)
        .disabled(dictation.isBusy)
        .help(dictation.isListening ? "Stop dictating" : "Dictate text to the remote desktop")
    }

    private var dictationNote: String? {
        switch dictation.status {
        case .preparing: return "Preparing dictation…"
        case .listening: return "Listening — words are typed as each phrase settles."
        case .unavailable(let reason), .failed(let reason): return reason
        case .idle: return nil
        }
    }

    private func toggleDictation() async {
        if dictation.isListening {
            await dictation.stop()
            return
        }
        // Drop the software keyboard: its own dictation would compete for the
        // microphone, and it is the session that keeps dying.
        isTextFieldFocused = false
        textBeforeDictation = textInput
        await dictation.start()
    }
    #else
    private var dictationNoteLabel: some View { EmptyView() }
    /// No in-app dictation on macOS: the system's own works there.
    private var dictationButton: some View { EmptyView() }
    #endif

    // MARK: - Typing Route

    /// Lets the user pick how text is typed when a companion is paired, and
    /// surfaces a fallback notice if the companion route is selected but down.
    /// Hidden entirely when there's no companion (plain VNC keyboard).
    @ViewBuilder
    private var routeControl: some View {
        @Bindable var manager = connectionManager
        if manager.hasCompanionInput {
            VStack(spacing: 6) {
                Picker("Typing route", selection: $manager.keyboardRoute) {
                    ForEach(VNCConnectionManager.KeyboardRoute.allCases) { route in
                        Text(route.label).tag(route)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if manager.keyboardRoute == .companion {
                    if manager.companionInputAvailable {
                        Label("Typed via the Mac companion — modifiers and special keys still use VNC.",
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
            .padding(.horizontal)
        }
    }

    // MARK: - Character Sending

    /// Mirror the text field's edits to the remote as a common-prefix delta:
    /// backspaces for the removed tail, then the new tail typed. Unlike the old
    /// append-only diff this sends deletions (fixes backspace) and reconciles
    /// dictation's mid-string rewrites. The field is a live mirror — never
    /// cleared — so the diff only ever transmits the changed tail.
    private func sendDelta(old: String, new: String) {
        let delta = TextDiff.delta(old: old, new: new)
        if delta.deleteCount > 0 {
            connectionManager.routeDeleteBackward(delta.deleteCount)
        }
        if !delta.insert.isEmpty {
            connectionManager.routeInsertText(delta.insert)
        }
    }

    // MARK: - Modifier Toggle

    private func modifierToggle(_ label: String, isActive: Binding<Bool>,
                                keyDown: VNCKeyCode, keyUp: VNCKeyCode) -> some View {
        Button(label) {
            isActive.wrappedValue.toggle()
            if isActive.wrappedValue {
                connectionManager.sendKeyDown(keyDown)
            } else {
                connectionManager.sendKeyUp(keyUp)
            }
        }
        .buttonStyle(.bordered)
        .tint(isActive.wrappedValue ? .accentColor : nil)
    }

    // MARK: - Special Key Button

    private func specialKeyButton(_ label: String, keyCode: VNCKeyCode) -> some View {
        Button(label) {
            connectionManager.sendKeyDown(keyCode)
            connectionManager.sendKeyUp(keyCode)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Function Keys

    private var functionKeys: [(label: String, keyCode: VNCKeyCode)] {
        [
            ("F1", .f1), ("F2", .f2), ("F3", .f3), ("F4", .f4),
            ("F5", .f5), ("F6", .f6), ("F7", .f7), ("F8", .f8),
            ("F9", .f9), ("F10", .f10), ("F11", .f11), ("F12", .f12),
        ]
    }

    // MARK: - Release All Modifiers

    private func releaseAllModifiers() {
        if ctrlActive {
            connectionManager.sendKeyUp(.control)
            ctrlActive = false
        }
        if altActive {
            connectionManager.sendKeyUp(.option)
            altActive = false
        }
        if shiftActive {
            connectionManager.sendKeyUp(.shift)
            shiftActive = false
        }
        if cmdActive {
            connectionManager.sendKeyUp(.command)
            cmdActive = false
        }
    }
}
