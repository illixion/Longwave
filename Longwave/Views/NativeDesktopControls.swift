#if os(visionOS)
import SwiftUI

/// The Native desktop's controls: Screen, touch mode, right-click, Mouse,
/// Display, Keyboard, Audio, Disconnect. Keyboard stays when Screen is off. The desktop window's bottom
/// ornament. (While a mouse drove the Mac they were briefly a window of their
/// own, so the pointer couldn't slide onto them; the padded desktop layout
/// holds the pointer now, and the window is gone.)
struct NativeDesktopControls: View {
    let sessionID: MacNativeSessionID

    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(MacNativeSessionStore.self) private var sessions
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("nativeScreenCurvature.v3") private var curvatureSetting = NativeScreenCurvature.standard.rawValue

    private var mouseBridge: MacNativeMouseBridge { .shared(for: screenManager) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "main", value: MainWindowID.shared)
            } label: {
                Label("Connections", systemImage: "house")
            }

            Toggle(isOn: Binding(
                get: { screenManager.liveEnabled },
                set: { screenManager.liveEnabled = $0 }
            )) {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .toggleStyle(.button)

            if screenManager.liveEnabled {
                Button {
                    screenManager.touchMode = screenManager.touchMode == .absolute ? .relative : .absolute
                } label: {
                    Label(
                        screenManager.touchMode == .absolute ? "Direct" : "Touchpad",
                        systemImage: screenManager.touchMode == .absolute
                            ? "hand.tap" : "rectangle.and.hand.point.up.left"
                    )
                }

                Button {
                    screenManager.rightClickAtDesktopCursor()
                } label: {
                    Label("Right-click", systemImage: "cursorarrow.click.2")
                }

                if mouseBridge.isConnected {
                    Toggle(isOn: Binding(
                        get: { mouseBridge.captureEnabled },
                        set: { mouseBridge.captureEnabled = $0 }
                    )) {
                        Label("Mouse", systemImage: "computermouse")
                    }
                    .toggleStyle(.button)
                    .help(mouseBridge.captureEnabled
                        ? "The mouse controls the Mac; hand gestures are off until you turn this off"
                        : "Use the mouse on the Mac's desktop")
                }

                displayButton
            }

            // Outside the Screen group: typing to the Mac doesn't need its
            // picture on.
            Button(action: toggleKeyboardWindow) {
                Label("Keyboard", systemImage: isKeyboardWindowOpen ? "keyboard.fill" : "keyboard")
            }
            .tint(isKeyboardWindowOpen ? .accentColor : nil)

            Toggle(isOn: audioBinding) {
                Label(
                    "Audio",
                    systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash"
                )
            }
            .toggleStyle(.button)
            .disabled(!screenManager.hostServesAudio)

            Button(action: disconnectAll) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(12)
        .glassBackgroundEffect()
        .onHover { hovering in
            mouseBridge.pointerOverControls = hovering
        }
    }

    // MARK: - Display

    /// A popover rather than a menu: a popover's open state is ours to know,
    /// and the mouse hit target has to stand aside, and presses be held back,
    /// for exactly as long as it shows. A menu offers no such signal.
    private var displayButton: some View {
        Button {
            mouseBridge.menuOpen.toggle()
        } label: {
            Label("Display", systemImage: "display.2")
        }
        .help("Choose which Mac desktop to show, and how much it curves around you")
        .popover(isPresented: Binding(
            get: { mouseBridge.menuOpen },
            set: { mouseBridge.menuOpen = $0 }
        ), arrowEdge: .top) {
            displaySettings
                .padding(20)
                .frame(width: 380)
        }
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            if screenManager.virtualDisplaySettings != nil {
                virtualDisplayControls
            } else if screenManager.displays.count > 1 {
                // A host that doesn't publish its virtual display's settings:
                // just the list it offers.
                Picker("Desktop", selection: Binding(
                    get: { screenManager.selectedDisplayID ?? "" },
                    set: { screenManager.selectDisplay($0) }
                )) {
                    ForEach(screenManager.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Curve").font(.headline)
                Picker("Curve", selection: $curvatureSetting) {
                    ForEach(NativeScreenCurvature.allCases) { curvature in
                        Text(curvature.title).tag(curvature.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    /// The host's virtual display: on (a desktop that exists only for the
    /// headset — its resolution, and whether the Mac's own screens go dark)
    /// or off (mirror one of the Mac's physical displays).
    @ViewBuilder
    private var virtualDisplayControls: some View {
        let virtualID = MacNativeStreamProtocol.virtualDisplayID
        let physical = screenManager.displays.filter { !$0.isVirtual }
        if let settings = screenManager.virtualDisplaySettings {
            let virtualOn = screenManager.selectedDisplayID == virtualID
            Toggle(isOn: Binding(
                get: { virtualOn },
                set: { on in
                    if on {
                        screenManager.selectDisplay(virtualID)
                    } else if let main = physical.first {
                        // The host lists the main display first.
                        screenManager.selectDisplay(main.id)
                    }
                }
            )) {
                Label("Virtual Display", systemImage: "rectangle.on.rectangle")
            }
            .disabled(!virtualOn && physical.isEmpty)

            if virtualOn {
                Picker(selection: Binding(
                    get: { settings.resolution },
                    set: { screenManager.configureVirtualDisplay(.init(resolution: $0)) }
                )) {
                    ForEach(settings.resolutions) { resolution in
                        Text(resolution.title).tag(resolution.id)
                    }
                } label: {
                    Label("Resolution", systemImage: "aspectratio")
                }
                .pickerStyle(.menu)

                Toggle(isOn: Binding(
                    get: { settings.hostDisplaysOff },
                    set: { screenManager.configureVirtualDisplay(.init(hostDisplaysOff: $0)) }
                )) {
                    Label("Turn Off Mac Displays", systemImage: "power")
                }
            } else if physical.count > 1 {
                Picker(selection: Binding(
                    get: { screenManager.selectedDisplayID ?? "" },
                    set: { screenManager.selectDisplay($0) }
                )) {
                    ForEach(physical) { display in
                        Text(display.name).tag(display.id)
                    }
                } label: {
                    Label("Mirror", systemImage: "display")
                }
                .pickerStyle(.menu)
            } else if let only = physical.first {
                Label("Mirroring \(only.name)", systemImage: "display")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Audio

    /// Turning Audio on points this session's player at this session's host
    /// — `prepareTarget` first, because the window can be opened with Audio
    /// off and the player then has nothing to reconnect to.
    private var audioBinding: Binding<Bool> {
        Binding(
            get: { audioManager.liveEnabled },
            set: { on in
                guard on else {
                    audioManager.liveEnabled = false
                    return
                }
                if let connection = screenManager.connection {
                    audioManager.prepareTarget(
                        hostname: connection.companionHost,
                        port: AudioStreamProtocol.defaultPort,
                        credential: connection.resolvedCompanionCredential,
                        title: connection.displayName,
                        lowLatency: connection.lowLatencyAudio
                    )
                }
                audioManager.liveEnabled = true
            }
        )
    }

    // MARK: - Windows

    private func key(_ id: String) -> String {
        WindowSessionRegistry.key(id, instance: sessionID.registryInstance)
    }

    private var isKeyboardWindowOpen: Bool {
        WindowSessionRegistry.shared.sessions[key("mac-native-keyboard")] != nil
    }

    private func toggleKeyboardWindow() {
        if isKeyboardWindowOpen {
            dismissWindow(id: "mac-native-keyboard", value: sessionID)
        } else {
            openWindow(id: "mac-native-keyboard", value: sessionID)
        }
    }

    private func disconnectAll() {
        // Take the per-window scenes down first — their sessions die with
        // the manager's forget() below.
        for windowID in screenManager.windowSessions.keys {
            dismissWindow(
                id: "mac-native-window",
                value: MacNativeWindowStreamID(session: sessionID, windowID: windowID)
            )
        }
        screenManager.unityEnabled = false
        // Ends this session only: another host's Native window keeps streaming,
        // audio included. `end` disconnects this session's player.
        sessions.end(sessionID)
        let ids = ["mac-native-keyboard", "mac-native-stream", "mac-native-unity-controls", "mac-native-audio"]
        WindowSessionRegistry.shared.closeAfterSurfacingMain(
            closing: Set(ids.map(key)),
            using: openWindow
        ) {
            for id in ids { dismissWindow(id: id, value: sessionID) }
        }
    }
}
#endif
