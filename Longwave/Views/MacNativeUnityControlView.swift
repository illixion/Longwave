#if os(visionOS)
import SwiftUI

/// Persistent controller for a Unity session. It turns the host's live window
/// inventory into value-keyed visionOS scenes and keeps the controls available
/// even when the full desktop scene is not open.
struct MacNativeUnityControlView: View {
    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDisconnecting = false

    var body: some View {
        @Bindable var audioManager = audioManager

        VStack(alignment: .leading, spacing: 12) {
            header

            // Session controls only. The window-management cluster lives with
            // the chips below: eight labelled buttons never fit one row, and
            // SwiftUI's answer was to wrap every label onto two lines
            // ("Desk / top", "Right- / click") rather than truncate.
            HStack(spacing: 10) {
                Toggle(isOn: desktopBinding) {
                    Label("Desktop", systemImage: "macwindow.on.rectangle")
                }
                .toggleStyle(.button)

                if screenManager.liveEnabled {
                    Button {
                        screenManager.touchMode = screenManager.touchMode == .absolute
                            ? .relative : .absolute
                    } label: {
                        Label(
                            screenManager.touchMode == .absolute ? "Direct" : "Touchpad",
                            systemImage: screenManager.touchMode == .absolute
                                ? "hand.tap" : "rectangle.and.hand.point.up.left"
                        )
                    }

                    Button(action: screenManager.rightClickAtDesktopCursor) {
                        Label("Right-click", systemImage: "cursorarrow.click.2")
                    }
                    .disabled(!screenManager.canRightClickDesktop)
                }

                Button(action: toggleKeyboardWindow) {
                    Label("Keyboard", systemImage: isKeyboardWindowOpen ? "keyboard.fill" : "keyboard")
                }
                .tint(isKeyboardWindowOpen ? .accentColor : nil)

                Toggle(isOn: $audioManager.liveEnabled) {
                    Label("Audio", systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash")
                }
                .toggleStyle(.button)
                .disabled(!screenManager.hostServesAudio)

                // A Unity session has no ornament and no inline player — the
                // desktop scene it would live on is usually closed — so the
                // mini player has to be reachable from here or not at all.
                if audioManager.liveEnabled {
                    Button(action: togglePlayerWindow) {
                        Label(
                            "Player",
                            systemImage: isPlayerWindowOpen
                                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.forward.app"
                        )
                    }
                    .tint(isPlayerWindowOpen ? .accentColor : nil)
                }

                Spacer(minLength: 0)
            }
            .lineLimit(1)

            Divider()

            windowStrip
        }
        .padding(14)
        .frame(width: unityControlsWidth)
        .glassBackgroundEffect()
        .onAppear {
            resumeSession()
            reconcileWindows(with: screenManager.windowInventory)
        }
        .onChange(of: screenManager.windowInventory) { _, windows in
            reconcileWindows(with: windows)
        }
        .onChange(of: audioManager.liveEnabled) { _, enabled in
            if enabled {
                guard screenManager.hostServesAudio else {
                    audioManager.liveEnabled = false
                    return
                }
                audioManager.reconnectLast()
            } else {
                audioManager.disconnect()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resumeSession()
            }
        }
        .onDisappear {
            reopenIfNeeded()
        }
    }

    /// Wide enough that the session controls, the three all-window actions and
    /// a few window chips all sit on their own line without wrapping. The chip
    /// strip scrolls past whatever is left.
    private let unityControlsWidth: CGFloat = 1100

    private var header: some View {
        HStack(spacing: 12) {
            Label(screenManager.title, systemImage: "slider.horizontal.3")
                .font(.headline)
                .lineLimit(1)

            Text(screenManager.state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // Replaces the old standalone "Up to N windows can stream at once"
            // caption: it says the same thing, plus where you are against the
            // cap, without spending a row on it.
            if !screenManager.windowInventory.isEmpty {
                Text("\(screenManager.unityVisibleWindowIDs.count) of \(MacNativeStreamProtocol.maxConcurrentWindowStreams) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
                    .labelStyle(.iconOnly)
            }

            Button(role: .destructive, action: disconnectAll) {
                Label("Disconnect", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
        }
    }

    /// The all-window actions and the per-window chips on one line. The strip
    /// is `fixedSize`d vertically because a horizontal `ScrollView` reports an
    /// unconstrained height, and under `.contentSize` resizability that let the
    /// window settle at its `defaultSize` and clip the chips out of sight.
    @ViewBuilder
    private var windowStrip: some View {
        if screenManager.windowInventory.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Waiting for Mac windows…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        } else {
            HStack(spacing: 10) {
                Button("Show All", systemImage: "rectangle.stack.badge.plus", action: showAllWindows)
                    .disabled(!canShowAnyWindow)

                Button("Hide All", systemImage: "rectangle.stack.badge.minus", action: hideAllWindows)
                    .disabled(screenManager.unityVisibleWindowIDs.isEmpty)

                Toggle("Auto-show", isOn: autoShowBinding)
                    .toggleStyle(.button)

                Divider()
                    .frame(height: 36)

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(screenManager.windowInventory) { window in
                            windowButton(window)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowButton(_ window: MacNativeStreamProtocol.WindowInfo) -> some View {
        let isOpen = screenManager.unityVisibleWindowIDs.contains(window.id)
        let isAtCapacity = !isOpen
            && screenManager.unityVisibleWindowIDs.count >= MacNativeStreamProtocol.maxConcurrentWindowStreams
        return Button {
            if isOpen {
                hideWindow(window.id, suppressAutoShow: true)
            } else {
                showWindow(window.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: window.isFocused ? "macwindow.badge.plus" : "macwindow")
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: isOpen ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                Text(window.title.isEmpty ? "Mac window" : window.appName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isOpen || window.isFocused ? .accentColor : nil)
        .disabled(isAtCapacity)
    }

    private var isKeyboardWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions["mac-native-keyboard"] != nil
    }

    /// Tracked off the live registry rather than a flag of our own, the same
    /// way `NativeStreamView` decides whether to show its inline player — so
    /// the button reflects the window even when something else closed it.
    private var isPlayerWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions["audio-stream"] != nil
    }

    private var desktopBinding: Binding<Bool> {
        Binding(
            get: { screenManager.liveEnabled },
            set: { showDesktop($0) }
        )
    }

    private var autoShowBinding: Binding<Bool> {
        Binding(
            get: { screenManager.unityAutoShow },
            set: { enabled in
                screenManager.setUnityAutoShow(enabled)
                if enabled {
                    reconcileWindows(with: screenManager.windowInventory)
                }
            }
        )
    }

    private var canShowAnyWindow: Bool {
        screenManager.unityVisibleWindowIDs.count < MacNativeStreamProtocol.maxConcurrentWindowStreams
            && screenManager.windowInventory.contains {
                !screenManager.unityVisibleWindowIDs.contains($0.id)
            }
    }

    private func showDesktop(_ show: Bool) {
        screenManager.liveEnabled = show
        screenManager.desktopToggleChanged(show)
        if show {
            openWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
        } else {
            dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
        }
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "mac-native-keyboard")
        } else {
            openWindow(id: "mac-native-keyboard")
        }
    }

    private func togglePlayerWindow() {
        if isPlayerWindowOpen {
            dismissWindow(id: "audio-stream")
        } else {
            openWindow(id: "audio-stream")
        }
    }

    private func resumeSession() {
        screenManager.ensureSessionConnected()
        if audioManager.liveEnabled {
            audioManager.ensureConnected()
        }
    }

    private func reconcileWindows(with windows: [MacNativeStreamProtocol.WindowInfo]) {
        guard screenManager.unityEnabled else { return }

        let availableIDs = Set(windows.map(\.id))
        let missingIDs = screenManager.unityVisibleWindowIDs.subtracting(availableIDs)
        for windowID in missingIDs {
            screenManager.markUnityWindowHidden(windowID, suppressAutoShow: false)
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: windowID)
            )
        }
        screenManager.pruneUnityWindowState(availableWindowIDs: availableIDs)

        guard screenManager.unityAutoShow else { return }
        for window in windows
            where screenManager.unityVisibleWindowIDs.count
                < MacNativeStreamProtocol.maxConcurrentWindowStreams
                && !screenManager.unityVisibleWindowIDs.contains(window.id)
                && !screenManager.unityAutoShowSuppressedWindowIDs.contains(window.id) {
            showWindow(window.id)
        }
    }

    private func showAllWindows() {
        for window in screenManager.windowInventory
            where screenManager.unityVisibleWindowIDs.count
                < MacNativeStreamProtocol.maxConcurrentWindowStreams
                && !screenManager.unityVisibleWindowIDs.contains(window.id) {
            showWindow(window.id)
        }
    }

    private func hideAllWindows() {
        for windowID in Array(screenManager.unityVisibleWindowIDs) {
            hideWindow(windowID, suppressAutoShow: true)
        }
    }

    private func showWindow(_ windowID: UInt32) {
        guard screenManager.unityVisibleWindowIDs.count
                < MacNativeStreamProtocol.maxConcurrentWindowStreams
                || screenManager.unityVisibleWindowIDs.contains(windowID) else { return }
        screenManager.markUnityWindowVisible(windowID)
        openWindow(
            id: "mac-native-window",
            value: MacNativeWindowStreamID(windowID: windowID)
        )
    }

    private func hideWindow(_ windowID: UInt32, suppressAutoShow: Bool) {
        screenManager.markUnityWindowHidden(windowID, suppressAutoShow: suppressAutoShow)
        dismissWindow(
            id: "mac-native-window",
            value: MacNativeWindowStreamID(windowID: windowID)
        )
    }

    private func reopenIfNeeded() {
        guard screenManager.unityEnabled,
              screenManager.connection != nil,
              !isDisconnecting,
              scenePhase == .active else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard screenManager.unityEnabled,
                  screenManager.connection != nil,
                  WindowSessionRegistry.shared.sessions["mac-native-unity-controls"] == nil else { return }
            openWindow(id: "mac-native-unity-controls", value: MacNativeUnityControlID.shared)
        }
    }

    private func disconnectAll() {
        isDisconnecting = true
        screenManager.unityEnabled = false
        for windowID in screenManager.unityVisibleWindowIDs.union(screenManager.windowSessions.keys) {
            screenManager.markUnityWindowHidden(windowID, suppressAutoShow: false)
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: windowID)
            )
        }
        screenManager.forget()
        audioManager.userDisconnect()
        WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
            dismissWindow(id: "audio-stream")
            dismissWindow(id: "mac-native-keyboard")
            dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
            dismissWindow(id: "mac-native-unity-controls", value: MacNativeUnityControlID.shared)
        }
    }
}
#endif
