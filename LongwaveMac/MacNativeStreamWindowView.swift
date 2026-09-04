import SwiftUI
import AppKit
import RAVEMedia

/// macOS window for a Native connection: the host's whole desktop as HEVC,
/// with real mouse and keyboard `NSEvent`s forwarded to the companion, and the
/// Audio half of the connection alongside it.
///
/// The visionOS `NativeStreamView` is a state machine of glass panels sized for
/// a `.plain` spatial window (per-window Unity scenes, pop-out audio, ornament
/// controls). A Mac window has a title bar and a toolbar, and per-window
/// streaming of another Mac's windows is a spatial idea, so this is the
/// desktop stream plus audio, on the same `MacNativeStreamManager`. Always
/// absolute pointing — a Mac has a real pointer.
struct MacNativeStreamWindowView: View {
    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewSize: CGSize = .zero
    @State private var leftDown = false
    @State private var scrollAccumX: CGFloat = 0
    @State private var scrollAccumY: CGFloat = 0
    @State private var lastPointer: (x: UInt16, y: UInt16)?
    @State private var showAudioPanel = false
    @State private var showEQ = false

    var body: some View {
        @Bindable var screenManager = screenManager
        @Bindable var audioManager = audioManager

        ZStack {
            Color.black.ignoresSafeArea()

            if screenManager.liveEnabled {
                screenContent
            } else if audioManager.liveEnabled {
                audioOnlyContent
            } else {
                emptyContent
            }
        }
        .navigationTitle(screenManager.title)
        .toolbar { toolbarContent(screenOn: $screenManager.liveEnabled, audioOn: $audioManager.liveEnabled) }
        .onAppear { resumeIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resumeIfNeeded() }
        }
        .onChange(of: screenManager.liveEnabled) { _, on in
            screenManager.desktopToggleChanged(on)
        }
        .onChange(of: audioManager.liveEnabled) { _, on in
            if on {
                // A host that serves no audio would leave this on
                // "Connecting…" forever; refuse the toggle instead.
                guard screenManager.hostServesAudio else {
                    audioManager.liveEnabled = false
                    return
                }
                audioManager.reconnectLast()
            } else {
                audioManager.disconnect()
            }
        }
        .onChange(of: screenManager.hostServesAudio) { _, servesAudio in
            applyAudioAvailability(servesAudio)
        }
        .onDisappear {
            // Closing the window is the whole session on a Mac — there is no
            // other scene keeping it alive.
            dismissWindow(id: "mac-native-keyboard")
            screenManager.forget()
            audioManager.userDisconnect()
        }
    }

    // MARK: - Session

    private func resumeIfNeeded() {
        if audioManager.liveEnabled {
            if screenManager.hostServesAudio {
                audioManager.ensureConnected()
            } else {
                applyAudioAvailability(false)
            }
        }
        if screenManager.liveEnabled, !screenManager.isEnabled, let connection = screenManager.connection {
            screenManager.connect(to: connection)
        }
    }

    private func applyAudioAvailability(_ servesAudio: Bool) {
        guard !servesAudio else { return }
        if audioManager.liveEnabled { audioManager.liveEnabled = false }
        audioManager.disconnect()
    }

    private func disconnectAll() {
        screenManager.forget()
        audioManager.userDisconnect()
        dismissWindow(id: "mac-native-keyboard")
        dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
    }

    // MARK: - Screen

    private var screenContent: some View {
        GeometryReader { geo in
            ZStack {
                if let layer = screenManager.displayLayer {
                    MacVideoLayerView(displayLayer: layer)
                }

                if screenManager.state != .streaming {
                    statusView
                }

                MacInputSurface(
                    onMouseMove: handleMove,
                    onMouseDown: handleDown,
                    onMouseUp: handleUp,
                    onScroll: handleScroll,
                    onKeyDown: { handleKey($0, down: true) },
                    onKeyUp: { handleKey($0, down: false) },
                    onFlagsChanged: handleFlags,
                    hideCursorWhenInside: screenManager.connection?.hideLocalCursor ?? false
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { _, s in viewSize = s }
        }
        .overlay(alignment: .top) {
            if let message = inputWarningMessage {
                Label(message, systemImage: "computermouse")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusView: some View {
        VStack(spacing: 16) {
            if case .disconnected = screenManager.state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 42))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(desktopStatusText)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    private var desktopStatusText: String {
        if screenManager.state == .connected {
            return "Waiting for the first frame…"
        }
        return screenManager.state.statusText
    }

    private var inputWarningMessage: String? {
        switch screenManager.mouseAvailability {
        case .disabled: return "Mouse control is off — enable it in the host's Native settings."
        case .accessibilityDenied: return "Mouse control needs Accessibility permission on the Mac."
        case .available, .unknown: return nil
        }
    }

    // MARK: - Audio only / nothing

    private var audioOnlyContent: some View {
        VStack(spacing: 0) {
            AudioPlayerPanel(width: 360)
            AudioVolumeRow()
                .padding(.horizontal, 28)
                .padding(.top, 22)
            HStack(spacing: 24) {
                Button {
                    audioManager.reconnectLast()
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .disabled(audioManager.state == .connecting)
                .help("Reconnect the audio stream")

                Button {
                    audioManager.toggleAudioMode()
                } label: {
                    Image(systemName: audioManager.audioMode == .music ? "music.note" : "hifispeaker")
                }
                .help(audioManager.audioMode == .music ? "Music Mode" : "Speaker Mode")

                Button {
                    showEQ.toggle()
                } label: {
                    Image(systemName: "waveform")
                }
                .tint(audioManager.eqSettings.enabled ? .accentColor : nil)
                .help("Equalizer")
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 360)
        .sheet(isPresented: $showEQ) {
            @Bindable var audioManager = audioManager
            EQEditorView(settings: $audioManager.eqSettings)
                .frame(minWidth: 420, minHeight: 320)
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Screen and Audio are both off")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Turn one on in the toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(screenOn: Binding<Bool>, audioOn: Binding<Bool>) -> some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: screenOn) {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .help("Stream the host's desktop")

            Button {
                openWindow(id: "mac-native-keyboard")
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .help("Open the on-screen keyboard")

            Toggle(isOn: audioOn) {
                Label("Audio", systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash")
            }
            .disabled(!screenManager.hostServesAudio)
            .help(screenManager.hostServesAudio ? "Stream the host's system audio" : "This host doesn't stream audio")

            if audioManager.liveEnabled, screenManager.liveEnabled {
                Button {
                    showAudioPanel.toggle()
                } label: {
                    Label("Player", systemImage: audioManager.state == .streaming ? "hifispeaker.fill" : "hifispeaker")
                }
                .popover(isPresented: $showAudioPanel, arrowEdge: .bottom) {
                    AudioPlayerPanel(width: 360, showsVolume: true)
                        .padding(.vertical, 8)
                        .environment(audioManager)
                }
            }

            Button(role: .destructive, action: disconnectAll) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Mouse

    private var translator: GestureTranslator? {
        guard screenManager.streamSize.width > 0, viewSize.width > 0 else { return nil }
        return GestureTranslator(framebufferSize: screenManager.streamSize, viewSize: viewSize)
    }

    private func handleMove(_ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastPointer = fb
        if leftDown {
            screenManager.sendMouseMove(x: fb.x, y: fb.y)
        } else {
            screenManager.moveCursorAbsolute(x: fb.x, y: fb.y)
        }
    }

    private func handleDown(_ button: Int, _ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastPointer = fb
        let b = wireButton(button)
        if b == .left { leftDown = true }
        screenManager.sendMouseDown(button: b, x: fb.x, y: fb.y)
    }

    private func handleUp(_ button: Int, _ p: CGPoint) {
        guard let fb = translator?.viewToFramebuffer(p) else { return }
        lastPointer = fb
        let b = wireButton(button)
        if b == .left { leftDown = false }
        screenManager.sendMouseUp(button: b, x: fb.x, y: fb.y)
    }

    private func wireButton(_ i: Int) -> MacNativeStreamProtocol.MouseButton {
        switch i { case 1: return .right; case 2: return .other; default: return .left }
    }

    /// Accumulate trackpad deltas and emit one scroll line per threshold, so
    /// fine-grained deltas don't flood the host. The wire carries lines with
    /// +Y = up, the same convention as the visionOS pinch and scroll pad.
    private func handleScroll(_ dx: CGFloat, _ dy: CGFloat) {
        let threshold: CGFloat = 6
        scrollAccumY += dy
        scrollAccumX += dx
        var linesY = 0
        var linesX = 0
        while abs(scrollAccumY) >= threshold {
            linesY += scrollAccumY > 0 ? 1 : -1
            scrollAccumY += scrollAccumY > 0 ? -threshold : threshold
        }
        while abs(scrollAccumX) >= threshold {
            linesX += scrollAccumX > 0 ? 1 : -1
            scrollAccumX += scrollAccumX > 0 ? -threshold : threshold
        }
        guard linesX != 0 || linesY != 0 else { return }
        let point = lastPointer ?? (
            x: UInt16(clamping: Int(screenManager.streamSize.width / 2)),
            y: UInt16(clamping: Int(screenManager.streamSize.height / 2))
        )
        screenManager.sendScroll(x: point.x, y: point.y, deltaX: Int16(clamping: linesX), deltaY: Int16(clamping: linesY))
    }

    // MARK: - Keyboard

    /// `NSEvent.keyCode` is already a macOS virtual keycode, so a macOS host
    /// gets it verbatim; a Windows host (`hidUsage` space) gets the HID usage
    /// for the same physical key. When the companion allows keyboard control
    /// every key is a keycode + modifier mask; otherwise only plain typing
    /// gets through, as text over the always-attempted inject channel —
    /// the same split the visionOS capture view applies.
    private func handleKey(_ event: NSEvent, down: Bool) {
        let modifiers = Self.wireModifiers(event.modifierFlags)
        if screenManager.keyboardShortcutsAvailability == .available {
            guard let code = MacKeyCodeMap.wireKeyCode(forMacKeyCode: event.keyCode, space: screenManager.keyCodeSpace) else { return }
            if down {
                screenManager.sendKeyDown(keyCode: code, modifiers: modifiers)
            } else {
                screenManager.sendKeyUp(keyCode: code, modifiers: modifiers)
            }
            return
        }
        guard down, screenManager.textInputAvailable else { return }
        if event.keyCode == MacKeyMaps.VK.delete {
            screenManager.sendInjectBackspace(1)
        } else if event.keyCode == MacKeyMaps.VK.return || event.keyCode == MacKeyMaps.VK.keypadEnter {
            screenManager.sendInjectText("\n")
        } else if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            // A shortcut can't be expressed as text.
            return
        } else if let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 }) {
            screenManager.sendInjectText(text)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard screenManager.keyboardShortcutsAvailability == .available,
              let flag = MacKeyMaps.modifierFlag(for: event.keyCode),
              let code = MacKeyCodeMap.wireKeyCode(forMacKeyCode: event.keyCode, space: screenManager.keyCodeSpace)
        else { return }
        let modifiers = Self.wireModifiers(event.modifierFlags)
        if event.modifierFlags.contains(flag) {
            screenManager.sendKeyDown(keyCode: code, modifiers: modifiers)
        } else {
            screenManager.sendKeyUp(keyCode: code, modifiers: modifiers)
        }
    }

    private static func wireModifiers(_ flags: NSEvent.ModifierFlags) -> MacNativeKeyModifiers {
        var result: MacNativeKeyModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }
}
