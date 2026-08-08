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
        }
        .formStyle(.grouped)
        // Fixed window size (System Settings convention) so tall panes scroll
        // *inside* the grouped Form instead of growing the window off-screen.
        .frame(width: 640, height: 520)
        .onAppear {
            controller.refreshKeys()
            controller.injection.refreshAccessibility()
        }
    }
}

// MARK: - Native (Screen + Audio)

/// Combines what used to be separate "Mac Stream" (screen) and "Audio" tabs:
/// one Native feature, two independent toggles, sharing the host/token shown
/// in the Token tab (AirDrop included) — so pairing once covers both.
struct NativePane: View {
    @Bindable var controller: AudioStreamerController

    var body: some View {
        Form {
            Section {
                Toggle("Screen", isOn: $controller.macNativeStreaming.enabled)
                Toggle("Audio", isOn: $controller.isRunning)
            } footer: {
                Text("Screen streams the Mac's visible windows over a clear background using ScreenCaptureKit and HEVC with its native alpha channel. Audio streams the Mac's system audio — playback on VisionVNC honors its own Spatial Audio setting (Mac Virtual Display forces it on). Both use the same host and token as shown in the Token tab; toggle either independently.")
            }

            if controller.macNativeStreaming.enabled {
                Section("Screen Status") {
                    LabeledContent("Stream", value: controller.macNativeStreaming.statusText)
                    LabeledContent("Port", value: String(controller.macNativeStreaming.port))
                    if controller.macNativeStreaming.isCapturing {
                        Label("Screen capture active", systemImage: "record.circle")
                            .foregroundStyle(.green)
                    }
                    if let error = controller.macNativeStreaming.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
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
                        .help("Silences the local (or Vision Pro Sidecar) output so audio only plays through the VisionVNC app.")
                    Toggle("Show track in menu bar", isOn: $controller.showTrackInMenuBar)
                        .help("Shows the current Music.app track as \"Artist – Title\" in the menu bar while streaming.")
                    if let error = controller.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Text("The Mac shows its system screen-capture indicator while Screen is on. VisionVNC Companion also posts a notification naming the connecting device and whether it replaced another viewer.")
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
                        Label("AirDrop to Vision Pro", systemImage: "square.and.arrow.up")
                    }

                    Spacer()

                    Button("Regenerate", role: .destructive) {
                        controller.regenerateToken()
                    }
                    .help("Invalidates the current token — connected devices must re-pair.")
                }
            } footer: {
                Text("Enter this token in VisionVNC as a Native connection, or AirDrop it to auto-fill — it covers both Screen and Audio. The token both authorizes the connection and encrypts it (TLS) — no VPN needed. Keep it secret; regenerate to revoke access for both.")
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
                     ? "Configures the local mediamtx server for encrypted ingest from the Vision Pro, then AirDrop the pairing link to auto-fill VisionVNC's Broadcast tab."
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
                Text("Copy the key from VisionVNC (Projects → Copy Public Key), then add it here. Enable Remote Login in System Settings → General → Sharing for SSH to work.")
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
                    .help("Lets a paired Vision Pro type text into the frontmost Mac app over an encrypted channel. Text and backspace only — never shortcuts or modifier keys.")

                if controller.injectionEnabled && !controller.injection.accessibilityTrusted {
                    HStack {
                        Text("Needs Accessibility permission to type.")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Grant Accessibility…") {
                            controller.grantAccessibility()
                        }
                    }
                } else if controller.injectionEnabled {
                    LabeledContent("Status", value: "Ready — remote typing routes through this Mac.")
                }
            } footer: {
                Text("Text-only injection (no modifier keys) keeps remote typing from triggering shortcuts. In VisionVNC, link this companion to a VNC connection to use it.")
            }
        }
    }
}
