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
    @State private var dictation = DictationController()
    /// How much of this dictation run has already been typed onto the remote, so
    /// each settled phrase only sends its new tail.
    @State private var dictatedSoFar = ""
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
            #if os(visionOS)
            .onDisappear {
                Task { await dictation.cancel() }
            }
            // Only settled phrases are typed onward: the recognizer's revisions
            // would arrive at the remote as backspace-and-retype churn.
            .onChange(of: dictation.settledTranscript) { _, transcript in
                typeDictated(transcript)
            }
            #endif
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
            Label(dictation.isListening ? "Stop" : "Dictate",
                  systemImage: dictation.isListening ? "mic.fill" : "mic")
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
        dictatedSoFar = ""
        await dictation.start()
    }

    /// Type whatever is new since the last settled transcript. Settled text only
    /// ever grows within a run; anything else means the session restarted or was
    /// cancelled, so resync silently rather than backspacing the remote.
    private func typeDictated(_ transcript: String) {
        guard transcript.hasPrefix(dictatedSoFar) else {
            dictatedSoFar = transcript
            return
        }
        let tail = String(transcript.dropFirst(dictatedSoFar.count))
        dictatedSoFar = transcript
        guard !tail.isEmpty else { return }
        connectionManager.routeInsertText(tail)
    }
    #else
    private var dictationNoteLabel: some View { EmptyView() }
    /// No in-app dictation on macOS: the system's own works there.
    private var dictationButton: some View { EmptyView() }
    #endif
}
