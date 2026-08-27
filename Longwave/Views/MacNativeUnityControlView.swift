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

    @State private var requestedWindowIDs: Set<UInt32> = []
    @State private var isDisconnecting = false

    var body: some View {
        @Bindable var audioManager = audioManager

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(screenManager.title, systemImage: "slider.horizontal.3")
                    .font(.headline)

                Text(screenManager.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    openWindow(id: "main", value: MainWindowID.shared)
                } label: {
                    Label("Connections", systemImage: "house")
                        .labelStyle(.iconOnly)
                }

                Button(action: toggleDesktop) {
                    Label(
                        isDesktopWindowOpen ? "Hide Desktop" : "Show Desktop",
                        systemImage: isDesktopWindowOpen
                            ? "macwindow.on.rectangle.fill" : "macwindow.on.rectangle"
                    )
                        .labelStyle(.iconOnly)
                }
                .tint(isDesktopWindowOpen ? .accentColor : nil)

                Button(action: toggleKeyboardWindow) {
                    Label("Keyboard", systemImage: isKeyboardWindowOpen ? "keyboard.fill" : "keyboard")
                        .labelStyle(.iconOnly)
                }
                .tint(isKeyboardWindowOpen ? .accentColor : nil)

                Toggle(isOn: $audioManager.liveEnabled) {
                    Label("Audio", systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .disabled(!screenManager.hostServesAudio)

                Button(role: .destructive, action: disconnectAll) {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
            }

            Divider()

            if screenManager.windowInventory.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for Mac windows…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 64)
            } else {
                if screenManager.windowInventory.count > MacNativeStreamProtocol.maxConcurrentWindowStreams {
                    Text("Unity streams the first \(MacNativeStreamProtocol.maxConcurrentWindowStreams) visible windows. Close one to open another.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
        }
        .padding(14)
        .frame(width: 980)
        .glassBackgroundEffect()
        .onAppear {
            resumeSession()
            reconcileWindows(with: screenManager.windowInventory)
        }
        .onChange(of: screenManager.windowInventory) { _, windows in
            reconcileWindows(with: windows)
        }
        .onChange(of: audioManager.liveEnabled) { _, enabled in
            // The desktop scene already owns this side effect while open.
            guard WindowSessionRegistry.shared.sessions["mac-native-stream"] == nil else { return }
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

    private func windowButton(_ window: MacNativeStreamProtocol.WindowInfo) -> some View {
        let isOpen = screenManager.windowSessions[window.id] != nil
        let isAtCapacity = !isOpen
            && screenManager.windowSessions.count >= MacNativeStreamProtocol.maxConcurrentWindowStreams
        return Button {
            requestedWindowIDs.insert(window.id)
            screenManager.sendFocusWindow(windowID: window.id)
            openWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: window.id)
            )
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: window.isFocused ? "macwindow.badge.plus" : "macwindow")
                    Text(window.title.isEmpty ? window.appName : window.title)
                        .lineLimit(1)
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

    private var isDesktopWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions["mac-native-stream"] != nil
    }

    private func toggleDesktop() {
        if isDesktopWindowOpen {
            screenManager.liveEnabled = false
            screenManager.desktopToggleChanged(false)
            dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
        } else {
            if !screenManager.liveEnabled {
                screenManager.liveEnabled = true
                screenManager.desktopToggleChanged(true)
            }
            openWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
        }
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "mac-native-keyboard")
        } else {
            openWindow(id: "mac-native-keyboard")
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
        for windowID in requestedWindowIDs.subtracting(availableIDs) {
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: windowID)
            )
            requestedWindowIDs.remove(windowID)
        }

        for window in windows
            where requestedWindowIDs.count < MacNativeStreamProtocol.maxConcurrentWindowStreams
                && !requestedWindowIDs.contains(window.id) {
            requestedWindowIDs.insert(window.id)
            openWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: window.id)
            )
        }
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
        for windowID in requestedWindowIDs.union(screenManager.windowSessions.keys) {
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(windowID: windowID)
            )
        }
        screenManager.forget()
        audioManager.userDisconnect()
        WindowSessionRegistry.shared.closeAfterSurfacingMain(using: openWindow) {
            dismissWindow(id: "mac-native-keyboard")
            dismissWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
            dismissWindow(id: "mac-native-unity-controls", value: MacNativeUnityControlID.shared)
        }
    }
}
#endif
