import SwiftUI

/// Terminal window: status row, the SwiftTerm display, a gaze-friendly quick-key
/// row, and a dictation-capable composer. Looks up its `SSHSession` by id so the
/// session can outlive the window (tmux-backed re-attach).
struct SSHTerminalView: View {
    @Environment(SSHTerminalManager.self) private var manager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    let sessionID: SSHSessionID

    @State private var composer: String = ""
    @FocusState private var composerFocused: Bool

    /// Latched on-screen modifiers (⌃/⌥/⇧). Applied to the next quick-key press
    /// or the next composer send, then cleared. E.g. ⌃ + "b" → 0x02 (tmux
    /// prefix), ⌥ + ← → word-left, ⇧ + tab → back-tab.
    @State private var modifiers: TerminalModifiers = []

    /// Keeps terminal keyboard intent separate from current first-responder
    /// status. The distinction matters because dictation may temporarily resign
    /// its input view; that must not disable direct input or trigger a focus race.
    @State private var keyboardFocus = TerminalKeyboardFocusState()

    #if os(visionOS)
    /// In-app dictation, transcribed on device. Deliberately not the keyboard's
    /// dictation — see `DictationController` for why that one keeps dying.
    @State private var dictation = DictationController()
    /// Whatever was already typed when dictation started; recognized text is
    /// appended to it so a half-typed command isn't thrown away.
    @State private var composerBeforeDictation = ""
    #endif


    /// Drives the "close or force-restart" modal raised by the header's ✕ button.
    @State private var showingSessionActions = false

    /// Auto-hands keyboard focus to the terminal whenever a hardware keyboard is
    /// attached, so a Bluetooth keyboard drives the session without first tapping
    /// the keyboard toggle (mirrors Moonlight/VNC's always-on capture).
    @State private var keyboardMonitor = HardwareKeyboardMonitor()

    @AppStorage(ConnectionDefaults.Keys.terminalFontSize)
    private var terminalFontSize: Double = ConnectionDefaults.terminalFontSizeDefault
    @AppStorage(ConnectionDefaults.Keys.terminalQuickKeys)
    private var quickKeysRaw: String = TerminalQuickKey.defaultSelectionStored

    var body: some View {
        Group {
            if let session = manager.session(sessionID) {
                content(session)
            } else {
                ContentUnavailableView("Session ended", systemImage: "terminal")
            }
        }
        .background(Color(white: 0.07))
        // Auto-reconnect lifecycle (same shape as AudioStreamView): revive on
        // appear / scene activation, stop retrying when the window goes away.
        // Sessions are looked up by id inside the closures — the window can
        // outlive a captured session reference.
        .onAppear {
            manager.session(sessionID)?.ensureConnected()
            keyboardMonitor.start()
            // A keyboard already paired when the window opens should drive the
            // terminal right away (unless the composer is actively focused).
            if keyboardMonitor.isConnected, !composerFocused { keyboardFocus.request() }
        }
        .onDisappear {
            manager.session(sessionID)?.windowDisappeared()
            keyboardMonitor.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.session(sessionID)?.ensureConnected() }
        }
        // Hardware keyboard plugged in → grab focus; unplugged → release back to
        // the dictation-safe display-only state.
        .onChange(of: keyboardMonitor.isConnected) { _, connected in
            if connected {
                if !composerFocused { keyboardFocus.request() }
            } else {
                keyboardFocus.release()
            }
        }
        // Composer focus always wins. Do not auto-focus the terminal on blur:
        // visionOS can transiently report a blur while dictation updates, and
        // immediately reclaiming first responder aborts the active dictation.
        .onChange(of: composerFocused) { _, focused in
            keyboardFocus.composerFocusChanged(focused)
        }
        #if os(visionOS)
        // Mirror recognized speech into the composer as it arrives, including the
        // phrase still being revised, so dictation reads as live.
        .onChange(of: dictation.transcript) { _, text in
            composer = composerBeforeDictation + text
        }
        .onDisappear { Task { await dictation.cancel() } }
        #endif
    }

    @ViewBuilder
    private func content(_ session: SSHSession) -> some View {
        VStack(spacing: 0) {
            statusRow(session)
            TerminalEmulatorView(session: session, fontSize: terminalFontSize,
                                 keyboardFocusEnabled: keyboardFocus.isEnabled,
                                 keyboardFocusRequest: keyboardFocus.requestID,
                                 keyboardFocusIsDeliberate: keyboardFocus.requestIsDeliberate) { focused in
                keyboardFocus.firstResponderChanged(focused)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            quickKeyRow(session)
            composerBar(session)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private func statusRow(_ session: SSHSession) -> some View {
        HStack(spacing: 10) {
            // Controls on the left.
            scrollControls(session)
            keyboardFocusToggle
            reloadButton(session)
            closeButton
            // Connection status next to the controls.
            Circle()
                .fill(statusColor(session.state))
                .frame(width: 8, height: 8)
            Text(statusText(session))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Host info on the right.
            Text(session.title)
                .font(.headline)
            Text(session.username + "@" + session.host)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .confirmationDialog("Session", isPresented: $showingSessionActions,
                            titleVisibility: .visible) {
            Button("Close Session", role: .destructive) {
                manager.stopSession(sessionID)
                dismissWindow(id: "ssh-terminal", value: sessionID)
            }
            Button("Force Restart") {
                manager.forceRestartSession(sessionID)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Close this session, or force a fresh restart if the shell is frozen (e.g. bash stopped responding).")
        }
    }

    /// Raises the close/force-restart modal. The remote tmux session is only
    /// torn down once the user confirms a choice in the dialog.
    private var closeButton: some View {
        Button {
            showingSessionActions = true
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .tint(.red)
        .help("Close or restart this session")
    }

    /// Gaze-friendly paging, a screenful at a time. Lands wherever a drag would:
    /// the scrollback, or wheel events for a program that tracks the mouse.
    @ViewBuilder
    private func scrollControls(_ session: SSHSession) -> some View {
        Button { session.scrollPageUp() } label: {
            Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        Button { session.scrollPageDown() } label: {
            Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
    }

    /// Hand the keyboard to the terminal (BT keyboard, shortcuts, text
    /// selection). Off by default keeps dictation in the composer safe.
    private var keyboardFocusToggle: some View {
        Button {
            if keyboardFocus.hasFocus {
                keyboardFocus.release()
            } else {
                composerFocused = false
                keyboardFocus.requestDeliberately()
            }
        } label: {
            Image(systemName: keyboardFocus.hasFocus ? "keyboard.fill" : "keyboard")
        }
        .buttonStyle(.borderless)
        .tint(keyboardFocus.hasFocus ? .accentColor : nil)
        .help(keyboardFocus.hasFocus ? "Terminal has the keyboard — tap to release" : "Send keyboard input to the terminal")
    }

    /// Manual relaunch — always reachable so a wedged launch can be kicked, and
    /// prominent once the connection has died (e.g. claude exited via Ctrl+C,
    /// taking its tmux session with it).
    @ViewBuilder
    private func reloadButton(_ session: SSHSession) -> some View {
        switch session.state {
        case .closed, .failed:
            Button {
                session.restart()
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        case .connecting, .ready:
            Button {
                session.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private func statusColor(_ state: SSHSession.State) -> Color {
        switch state {
        case .connecting: return .yellow
        case .ready: return .green
        case .closed, .failed: return .red
        }
    }

    private func statusText(_ session: SSHSession) -> String {
        if session.isAutoReconnecting { return "Reconnecting…" }
        switch session.state {
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .closed(let reason): return reason.map { "Closed: \($0)" } ?? "Closed"
        case .failed(let message): return message
        }
    }

    // MARK: - Quick keys

    /// Enabled keys in stable catalog order (user-customizable in Settings →
    /// Terminal).
    private var enabledQuickKeys: [TerminalQuickKey] {
        let enabled = TerminalQuickKey.enabledIDs(from: quickKeysRaw)
        return TerminalQuickKey.catalog.filter { enabled.contains($0.id) }
    }

    @ViewBuilder
    private func quickKeyRow(_ session: SSHSession) -> some View {
        let keys = enabledQuickKeys
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                modifierLatch("⌃", .ctrl)
                modifierLatch("⌥", .alt)
                modifierLatch("⇧", .shift)
                Divider().frame(height: 28)
                ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                    if index > 0, keys[index - 1].group != key.group {
                        Divider().frame(height: 28)
                    }
                    quickKey(key, session)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    /// A latching modifier key. Tap to arm/disarm; armed modifiers apply to the
    /// next emitted key (quick-key or composer send) and then clear.
    private func modifierLatch(_ label: String, _ mod: TerminalModifiers) -> some View {
        Button(label) {
            if modifiers.contains(mod) { modifiers.remove(mod) } else { modifiers.insert(mod) }
        }
        .buttonStyle(.bordered)
        .tint(modifiers.contains(mod) ? .accentColor : nil)
        .frame(minWidth: 48, minHeight: 44)
    }

    private func quickKey(_ key: TerminalQuickKey, _ session: SSHSession) -> some View {
        Button(key.label) {
            let bytes = TerminalKeyEncoder.encodeQuickKey(key, modifiers: modifiers)
            if session.sendBytes(bytes) { modifiers = [] }
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 48, minHeight: 44)
        // Unlike composed text, raw key bytes aren't worth queueing —
        // disable instead of silently dropping while disconnected.
        .disabled(!session.isReady)
    }

    // MARK: - Composer

    @ViewBuilder
    private func composerBar(_ session: SSHSession) -> some View {
        VStack(spacing: 8) {
            if let queued = session.queuedComposerText {
                HStack(spacing: 8) {
                    Label("Sends on reconnect: \(queued)", systemImage: "clock")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Cancel") { session.clearQueuedComposerText() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            #if os(visionOS)
            dictationStatus
            #endif
            HStack(spacing: 12) {
                TextField("Type a command…", text: $composer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($composerFocused)
                    .onSubmit { send(session) }
                #if os(visionOS)
                dictationButton
                #endif
                Button {
                    send(session)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(composer.isEmpty)
            }
        }
        .padding(16)
        .background(.bar)
    }

    #if os(visionOS)
    /// Tap to talk, tap to stop. Recognized text lands in the composer for review
    /// rather than being sent, so a misheard word is fixable before it reaches the
    /// agent.
    private var dictationButton: some View {
        Button {
            Task { await toggleDictation() }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.title2)
        }
        .buttonStyle(.bordered)
        .tint(dictation.isListening ? .red : nil)
        .disabled(dictation.isBusy)
        .help(dictation.isListening ? "Stop dictating" : "Dictate a message")
    }

    /// Surfaces the states a user can act on: the first-run model download, and
    /// anything that stopped dictation from working.
    @ViewBuilder
    private var dictationStatus: some View {
        switch dictation.status {
        case .preparing:
            Label("Preparing dictation…", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .listening:
            Label("Listening — tap the mic to stop", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    private func toggleDictation() async {
        if dictation.isListening {
            await dictation.stop()
            return
        }
        // Drop the software keyboard first: its own dictation session would be
        // competing for the microphone, and it is the one that keeps failing.
        composerFocused = false
        composerBeforeDictation = composer.isEmpty || composer.hasSuffix(" ") ? composer : composer + " "
        await dictation.start()
    }
    #endif

    /// Note: the send path has no focus dependency — neither the terminal view
    /// nor the composer needs focus for delivery. The historical "had to focus
    /// the session first" text loss was a dead channel silently dropping the
    /// bytes; with a dead connection the text now queues (visible chip above)
    /// and flushes when the session reconnects.
    private func send(_ session: SSHSession) {
        guard !composer.isEmpty else { return }
        if !modifiers.isEmpty {
            // A latched modifier turns the composed text into a single modified
            // keypress (e.g. ⌃b → 0x02, ⌥f → ESC f). Only single ASCII chars
            // have a modified form; anything longer falls through to plain text.
            if let bytes = TerminalKeyEncoder.encodeComposerKey(composer, modifiers: modifiers) {
                if session.sendBytes(bytes) { composer = ""; modifiers = [] }
                return
            }
            modifiers = []
        }
        session.sendComposerText(composer)
        composer = ""
    }
}
