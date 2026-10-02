import SwiftUI
import AppKit

/// The companion's main window: a tabbed Settings layout (the canonical macOS
/// System Settings look — icon toolbar across the top, one grouped-form pane
/// per tab). All configuration lives here; the menu bar popover keeps only the
/// quick audio controls and a button that opens this window.
///
/// Using `TabView` (rather than a `NavigationSplitView`) lets the Settings
/// window manage its own title bar: the selected tab's label becomes the
/// centered window title automatically, so there's no need to hide or
/// reposition it (an earlier sidebar version fought SwiftUI over
/// `titleVisibility` via KVO, which pegged a CPU core whenever the window was
/// open).
struct CompanionWindowView: View {
    @Bindable var controller: AudioStreamerController
    @Bindable var broadcastServer: BroadcastServerManager

    var body: some View {
        TabView {
            NativePane(controller: controller)
                .tabItem { Label("Native", systemImage: "macwindow.on.rectangle") }
            AccessTokenPane(controller: controller)
                .tabItem { Label("Token", systemImage: "key") }
            BroadcastPane(broadcastServer: broadcastServer)
                .tabItem { Label("Broadcast", systemImage: "dot.radiowaves.left.and.right") }
            RemoteControlPane(controller: controller)
                .tabItem { Label("Remote", systemImage: "terminal") }
            KeyboardPane(controller: controller)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            KVMPane(controller: controller)
                .tabItem { Label("KVM", systemImage: "cable.connector") }
        }
        .formStyle(.grouped)
        // Fixed window size (System Settings convention) so tall panes scroll
        // *inside* the grouped Form instead of growing the window off-screen.
        .frame(width: 640, height: 520)
        .onAppear {
            controller.refreshKeys()
            controller.injection.refreshAccessibility()
            controller.macNativeStreaming.input.refreshAccessibility()
            controller.macNativeStreaming.refreshVirtualDisplayConflict()
            controller.macNativeStreaming.refreshDisplays()
        }
    }
}

// MARK: - Native (Screen + Audio)

/// Combines what used to be separate "Mac Stream" (screen) and "Audio" tabs:
/// one Native feature, two independent toggles, sharing the host/token shown
/// in the Token tab (AirDrop included) — so pairing once covers both.
struct NativePane: View {
    @Bindable var controller: AudioStreamerController

    /// macOS 27 renamed the pane, and the old name is nowhere in its Settings.
    static func accessibilityNeeded(_ purpose: String) -> String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return "Needs Device Control permission \(purpose)."
        }
        return "Needs Accessibility permission \(purpose)."
    }

    /// Whether anything in the remote-control section is asking for the
    /// Accessibility grant. All three switches post events through it, and both
    /// services read it from `AccessibilityTrustMonitor` — so one row covers
    /// the set, and it clears by itself once System Settings grants it.
    private var remoteControlRequested: Bool {
        controller.macNativeStreaming.mouseControlEnabled
            || controller.macNativeStreaming.keyboardShortcutsEnabled
            || controller.injectionEnabled
    }

    var body: some View {
        Form {
            Section {
                Toggle("Screen", isOn: $controller.macNativeStreaming.enabled)
                Toggle("Audio", isOn: $controller.isRunning)
            } footer: {
                Text("Screen streams the Mac's visible windows over a clear background using ScreenCaptureKit and HEVC with its native alpha channel. Audio streams the Mac's system audio — playback on Longwave honors its own Spatial Audio setting (Mac Virtual Display forces it on). Both use the same host and token as shown in the Token tab; toggle either independently.")
            }

            if controller.macNativeStreaming.enabled {
                Section {
                    Picker("Desktop", selection: $controller.macNativeStreaming.selectedDisplayID) {
                        Text("Virtual Display").tag(MacNativeStreamProtocol.virtualDisplayID)
                        ForEach(controller.macNativeStreaming.physicalDisplays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                    .help("Which desktop the headset sees. The virtual display is rendered just for the headset — any size, whether or not a monitor like it is attached. The headset can switch this too, from the stream's controls.")

                    Picker("Virtual display size", selection: $controller.macNativeStreaming.virtualDisplayPreset) {
                        ForEach(MacNativeVirtualDisplayPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .help("Desktop size in points. The display is HiDPI, so text is drawn at twice this and streamed as sharp as the link allows.")

                    Toggle("Turn off the Mac's displays while streaming it", isOn: $controller.macNativeStreaming.virtualDisplayExclusive)
                        .help("While the virtual display streams, disconnects the built-in and external displays, exactly as Mac Virtual Display does. They come back when the stream ends, another desktop is picked, or the companion quits.")

                    if controller.macNativeStreaming.virtualDisplayEnabled,
                       let conflict = controller.macNativeStreaming.virtualDisplayConflict {
                        Label("\(conflict) — the stream will follow its display instead until it disconnects.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Desktop")
                } footer: {
                    Text("The size and display switch apply only while the virtual display is the one streaming, so both can be set before it ever connects. The virtual display uses the same mechanism as Mac Virtual Display, and the Mac's own keyboard and trackpad keep working on it. Changing these while a viewer is connected restarts the stream.")
                }

                Section {
                    Picker("Bitrate", selection: $controller.macNativeStreaming.bitrateMbps) {
                        Text("Automatic").tag(0)
                        ForEach([50, 100, 150, 200, 300], id: \.self) { mbps in
                            Text("\(mbps) Mbps").tag(mbps)
                        }
                    }
                    .help("How many bits the desktop stream may spend. Automatic scales with the display's size and frame rate, up to 150 Mbps at 120 fps.")
                } footer: {
                    Text("Higher keeps text sharp while scrolling and dragging windows. Whatever is set, the stream lowers its bitrate when Wi-Fi can't keep up and climbs back once it can, so a high setting costs sharpness rather than lag on a weak link. The status below shows the rate in use.")
                }

                Section("Screen Status") {
                    LabeledContent("Stream", value: controller.macNativeStreaming.statusText)
                    LabeledContent("Port", value: String(controller.macNativeStreaming.port))
                    if controller.macNativeStreaming.isCapturing {
                        Label("Screen capture active", systemImage: "record.circle")
                            .foregroundStyle(.green)
                    }
                    if let virtualDisplay = controller.macNativeStreaming.virtualDisplaySummary {
                        LabeledContent("Virtual display", value: virtualDisplay)
                    }
                    if let latency = controller.macNativeStreaming.latencySummary {
                        LabeledContent("Latency", value: latency)
                            .help("Display refresh to capture, then encode, then send until the headset acknowledges the frame (transmission plus the round trip). Decoding and display on the headset add roughly one more refresh on top.")
                    }
                    if let video = controller.macNativeStreaming.desktopVideoSummary {
                        LabeledContent("Desktop video", value: video)
                            .help("Chroma is 4:2:2 only when the connected viewer proved it can decode that profile in hardware; otherwise 4:2:0.")
                    }
                    if let error = controller.macNativeStreaming.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Allow mouse control", isOn: $controller.macNativeStreaming.mouseControlEnabled)
                        .help("Lets the connected Vision Pro click, drag, and scroll on this Mac while viewing its Screen stream.")

                    // The Keyboard tab's switch, shown a second time rather than
                    // copied: it is the same setting, and typing on the Screen
                    // stream depends on it. Left a tab away, this section read as
                    // if "shortcuts off" meant the keyboard did nothing at all.
                    Toggle("Allow keyboard control", isOn: $controller.injectionEnabled)
                        .help("Plain typing, over the text-only channel — no modifier keys. The same switch as in the Keyboard tab, where VNC typing uses it too.")

                    Toggle("Allow keyboard shortcuts", isOn: $controller.macNativeStreaming.keyboardShortcutsEnabled)
                        .help("Lets the connected Vision Pro send modifier shortcuts and special keys (Cmd+C, arrows, F-keys, …) on this Mac. Plain typing is the switch above instead.")

                    if remoteControlRequested && !controller.macNativeStreaming.input.accessibilityTrusted {
                        HStack {
                            Text(Self.accessibilityNeeded("to control input"))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Grant Access…") {
                                controller.macNativeStreaming.grantInputAccessibility()
                            }
                        }
                    } else if remoteControlRequested {
                        LabeledContent("Status", value: "Ready — remote control routes through this Mac.")
                    }
                } footer: {
                    Text("All off by default — Screen alone is view-only. The two keyboard switches are separate channels: \"keyboard control\" carries plain text (the same one VNC typing uses), \"keyboard shortcuts\" carries real key presses with modifiers. All three need the same Accessibility permission.")
                }
            }

            if controller.isRunning {
                Section("Audio Status") {
                    LabeledContent("Stream", value: controller.statusText)
                    LabeledContent("Format", value: "Port \(String(controller.port)) · \(controller.formatText)")
                    if let nowPlaying = controller.nowPlaying, nowPlaying.hasTrack {
                        LabeledContent("Now Playing", value: "\(nowPlaying.title ?? "") — \(nowPlaying.artist ?? "")")
                    }
                    Toggle("Mute Mac output while streaming", isOn: $controller.muteWhileStreaming)
                        .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the Longwave app.")
                    Toggle("Show track in menu bar", isOn: $controller.showTrackInMenuBar)
                        .help("Shows the current Music.app track as \"Artist – Title\" in the menu bar while streaming.")
                    if let error = controller.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Text("The Mac shows its system screen-capture indicator while Screen is on. Longwave Companion also posts a notification naming the connecting device and whether it replaced another viewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Access Token

struct AccessTokenPane: View {
    @Bindable var controller: AudioStreamerController
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Token") {
                    Text(controller.token)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.token, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    Button {
                        guard let url = controller.tokenShareURL,
                              let service = NSSharingService(named: .sendViaAirDrop) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label("AirDrop to Device", systemImage: "square.and.arrow.up")
                    }

                    Spacer()

                    Button("Regenerate", role: .destructive) {
                        controller.regenerateToken()
                    }
                    .help("Invalidates the current token — connected devices must re-pair.")
                }
            } footer: {
                Text("Enter this token in Longwave as a Native connection, or AirDrop it to auto-fill — it covers both Screen and Audio. The token both authorizes the connection and encrypts it (TLS) — no VPN needed. Keep it secret; regenerate to revoke access for both.")
            }
        }
    }
}

// MARK: - Broadcast (OBS)

struct BroadcastPane: View {
    @Bindable var broadcastServer: BroadcastServerManager
    @State private var linkCopied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(broadcastServer.statusText)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button(broadcastServer.isWorking ? "Configuring…" : "Set Up Broadcast Server") {
                        broadcastServer.setUpServer()
                    }
                    .disabled(!broadcastServer.mediamtxInstalled || broadcastServer.isWorking)
                    .help("Writes the mediamtx config (encrypted RTSPS ingest, OBS-only output), generates credentials + TLS certificate, and restarts the service.")

                    Spacer()

                    Button {
                        guard let url = broadcastServer.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        linkCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            linkCopied = false
                        }
                    } label: {
                        Label(linkCopied ? "Copied" : "Copy Link", systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(broadcastServer.shareURL == nil)
                    .help("Copy the pairing link to the clipboard")

                    Button {
                        guard let url = broadcastServer.shareURL,
                              let service = NSSharingService(named: .sendViaAirDrop) else { return }
                        service.perform(withItems: [url])
                    } label: {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                    }
                    .disabled(broadcastServer.shareURL == nil)
                    .help("Send the pairing link to your Vision Pro via AirDrop")
                }

                if let error = broadcastServer.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Server")
            } footer: {
                Text(broadcastServer.mediamtxInstalled
                     ? "Configures the local mediamtx server for encrypted ingest from the Vision Pro, then AirDrop the pairing link to auto-fill Longwave's Broadcast tab."
                     : "Install the server first: brew install mediamtx")
            }

            Section {
                SecureField("WebSocket password", text: $broadcastServer.obsPassword)
                    .help("The password from OBS → Tools → WebSocket Server Settings (leave empty if authentication is disabled).")

                HStack {
                    Button(broadcastServer.isOBSWorking ? "Adding…" : "Add Sources to OBS") {
                        broadcastServer.addSourcesToOBS()
                    }
                    .disabled(!broadcastServer.mediamtxInstalled || broadcastServer.isOBSWorking)
                    .help("Creates \"Vision Pro Camera\" and \"Vision Pro View\" Browser Sources in the current OBS scene, with audio routed into the OBS mixer.")

                    if let obsStatus = broadcastServer.obsStatusText {
                        Text(obsStatus)
                            .font(.caption)
                            .foregroundStyle(obsStatus.hasPrefix("OBS scene") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
            } header: {
                Text("OBS")
            } footer: {
                Text("In OBS, enable Tools → WebSocket Server Settings, press Show Connect Info → Copy Password, then click Add Sources to OBS — it picks the password up from the clipboard if the field is empty.")
            }
        }
    }
}

// MARK: - Remote Control (SSH)

struct RemoteControlPane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                if let fingerprint = controller.macHostFingerprint {
                    LabeledContent("This Mac") {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Button("Add Vision Pro Key from Clipboard") {
                    controller.addKeyFromClipboard()
                }

                if let status = controller.keyActionStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Copy the key from Longwave (Projects → Copy Public Key), then add it here. Enable Remote Login in System Settings → General → Sharing for SSH to work.")
            }

            if !controller.installedVisionKeys.isEmpty {
                Section("Authorized Keys") {
                    ForEach(controller.installedVisionKeys) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.comment.isEmpty ? key.type : key.comment)
                                Text(key.fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.removeKey(key)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .onAppear { controller.refreshKeys() }
    }
}

// MARK: - Keyboard Control

struct KeyboardPane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                Toggle("Allow keyboard control", isOn: $controller.injectionEnabled)
                    .help("Lets a paired Vision Pro type text into the frontmost Mac app over an encrypted channel. Text and backspace only — never shortcuts or modifier keys. The Native tab shows this same switch alongside the stream's own input toggles.")

                if controller.injectionEnabled && !controller.injection.accessibilityTrusted {
                    HStack {
                        Text(NativePane.accessibilityNeeded("to type"))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Access…") {
                            controller.grantAccessibility()
                        }
                    }
                } else if controller.injectionEnabled {
                    LabeledContent("Status", value: "Ready — remote typing routes through this Mac.")
                }
            } footer: {
                Text("Text-only injection (no modifier keys) keeps remote typing from triggering shortcuts. In Longwave it carries typing for a VNC connection linked to this companion, and for the Native stream — where \"Allow keyboard shortcuts\" in the Native tab adds real key presses on top.")
            }
        }
    }
}

// MARK: - KVM (this Mac's keyboard and mouse, on the headset)

/// The other direction from every other pane here: instead of letting the
/// headset drive this Mac, it hands this Mac's keyboard and mouse to the
/// headset through the USB dongle, which the headset sees as an ordinary
/// Bluetooth keyboard and pointer. visionOS has no input-injection API for
/// apps, so a real HID device is the only way in.
struct KVMPane: View {
    @Bindable var controller: AudioStreamerController

    private var kvm: KVMBridgeController { controller.kvm }

    var body: some View {
        Form {
            Section {
                Picker("Dongle", selection: $controller.kvm.portPath) {
                    if kvm.ports.isEmpty {
                        Text("No serial device found").tag("")
                    }
                    ForEach(kvm.ports, id: \.self) { path in
                        Text(path.replacingOccurrences(of: "/dev/", with: "")).tag(path)
                    }
                }
                .disabled(kvm.isConnected)

                HStack {
                    Button(kvm.isConnected ? "Disconnect" : "Connect") {
                        if kvm.isConnected {
                            kvm.disconnect()
                        } else {
                            Task { await kvm.connect() }
                        }
                    }
                    .disabled(kvm.isConnecting || (!kvm.isConnected && kvm.ports.isEmpty))

                    Button("Rescan") { kvm.refreshPorts() }
                        .disabled(kvm.isConnected)

                    Spacer()
                    Text(kvm.summary)
                        .foregroundStyle(kvm.isCapturing ? .green : .secondary)
                }

                Toggle("Connect automatically", isOn: $controller.kvm.autoConnect)

                if let error = kvm.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Dongle")
            } footer: {
                Text("The ESP32 board from Firmware/kvm-dongle, over its USB serial link. Connecting claims the port exclusively, so kvmctl.py can't be running at the same time.")
            }

            if let status = kvm.status {
                Section("Headset") {
                    LabeledContent("Bluetooth", value: status.state.title)
                    LabeledContent("Paired", value: status.hasBond ? "Yes (\(status.bondCount))" : "No")
                    LabeledContent("Listening for", value: subscriptionSummary(status))
                    LabeledContent("Dongle address", value: status.address)
                        .font(.system(.body, design: .monospaced))
                    LabeledContent("Firmware", value: status.firmware)
                    if let roundTrip = kvm.roundTrip {
                        LabeledContent("Round trip", value: "\(roundTrip.milliseconds) ms")
                    }
                }
            }

            Section {
                Toggle("Send this Mac's keyboard and mouse to the headset",
                       isOn: Binding(get: { kvm.isCapturing },
                                     set: { kvm.setCapturing($0) }))
                    .disabled(!kvm.headsetIsListening)

                Slider(value: $controller.kvm.pointerSpeed, in: 0.25...3.0, step: 0.25) {
                    Text("Pointer speed")
                } minimumValueLabel: {
                    Text("Slow").font(.caption)
                } maximumValueLabel: {
                    Text("Fast").font(.caption)
                }

                HStack {
                    Button("Type Test Phrase") { Task { await kvm.sendTestPhrase() } }
                    Button("Measure Round Trip") { Task { await kvm.measureRoundTrip() } }
                    Button("Release Everything") { Task { await kvm.releaseEverything() } }
                }
                .disabled(!kvm.isConnected || kvm.isCapturing)
            } header: {
                Text("Input")
            } footer: {
                Text("While this is on, the Mac sees none of it — every key and every movement goes to the headset instead, and the Mac's pointer stays put. Press \(KVMBridgeController.toggleShortcutDescription) to hand input back; the same shortcut turns it on again. Needs the Accessibility permission, like the other input features here.")
            }

            if !kvm.recentActivity.isEmpty {
                Section("Recent") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(kvm.recentActivity.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Section {
                Button("Forget Pairing", role: .destructive) {
                    Task { await kvm.forgetPairing() }
                }
                .disabled(!kvm.isConnected)
            } footer: {
                Text("Clears the dongle's half of the pairing. Also forget “Longwave KVM” on the headset, or it keeps trying to reconnect with a key the dongle no longer holds.")
            }
        }
        .onAppear { kvm.refreshPorts() }
    }

    private func subscriptionSummary(_ status: KVMDongleLink.Status) -> String {
        var parts: [String] = []
        if status.keyboardSubscribed { parts.append("keyboard") }
        if status.mouseSubscribed { parts.append("pointer") }
        if status.consumerSubscribed { parts.append("media keys") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
    }
}

private extension Duration {
    var milliseconds: String {
        String(format: "%.2f", Double(components.attoseconds) / 1e15 + Double(components.seconds) * 1000)
    }
}
