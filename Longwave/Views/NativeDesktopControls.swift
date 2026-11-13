#if os(visionOS)
import SwiftUI

/// The Native desktop's controls on the shared `StreamControlsBar`: Screen
/// before the pointer group, Display inside it, Audio after Keyboard. The
/// desktop window's bottom ornament. (While a mouse drove the Mac they were
/// briefly a window of their own, so the pointer couldn't slide onto them;
/// the padded desktop layout holds the pointer now, and the window is gone.)
struct NativeDesktopControls: View {
    let sessionID: MacNativeSessionID

    @Environment(MacNativeStreamManager.self) private var screenManager
    @Environment(MacNativeSessionStore.self) private var sessions
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("nativeScreenCurvature.v3") private var curvatureSetting = NativeScreenCurvature.standard.rawValue

    private var mouseBridge: StreamMouseBridge { .shared(for: screenManager) }

    var body: some View {
        StreamControlsBar(
            target: screenManager,
            mouse: mouseBridge,
            showsPointerControls: screenManager.liveEnabled,
            // Typing to the Mac doesn't need its picture on, so Keyboard
            // stays when Screen is off.
            keyboardOpen: isKeyboardWindowOpen,
            toggleKeyboard: toggleKeyboardWindow,
            audio: StreamAudioButton(
                isOn: audioBinding,
                systemImage: screenManager.hostServesAudio ? "speaker.wave.2" : "speaker.slash",
                disabled: !screenManager.hostServesAudio,
                help: screenManager.hostServesAudio
                    ? "Stream the Mac's audio, with its player beside the desktop"
                    : "This host doesn't stream audio"
            ),
            disconnect: disconnectAll
        ) {
            Toggle(isOn: Binding(
                get: { screenManager.liveEnabled },
                set: { screenManager.liveEnabled = $0 }
            )) {
                Label("Screen", systemImage: "macwindow.on.rectangle")
            }
            .toggleStyle(.button)
        } display: {
            displaySettings
        }
    }

    // MARK: - Display

    /// Which Mac desktop to show, and how much it curves around you — the
    /// Native desktop's content for the shared Display popover.
    @ViewBuilder
    private var displaySettings: some View {
        Group {
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
