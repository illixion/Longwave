import SwiftUI
import SwiftData

struct ConnectionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(VNCConnectionManager.self) private var connectionManager
    @Environment(AudioStreamManager.self) private var audioManager
    @Environment(MacNativeStreamManager.self) private var macNativeManager
    // Not macOS rather than visionOS-only: the Mac client drops SSH because it
    // has a real terminal a Cmd-Tab away. iPhone and iPad do not, so they keep it.
    #if !os(macOS)
    @Environment(SSHTerminalManager.self) private var sshManager
    #endif
    #if MOONLIGHT_ENABLED
    @Environment(MoonlightSessionStore.self) private var moonlightSessions
    #endif

    @Query(sort: \SavedConnection.lastConnected, order: .reverse)
    private var savedConnections: [SavedConnection]

    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?
    #if MOONLIGHT_ENABLED
    /// The pairing sheet's target: which connection, on which session. The
    /// session is chosen when the row is tapped, so the sheet can be handed the
    /// exact manager to observe rather than a global one.
    private struct MoonlightSheetTarget: Identifiable {
        let connection: SavedConnection
        let session: MoonlightConnectionManager
        var id: UUID { connection.id }
    }
    @State private var moonlightSheet: MoonlightSheetTarget?
    @State private var showingMoonlightSessionsBusy = false
    #endif

    /// PCVR rows are hidden here: PCVR moved to its own tab, which owns the one
    /// settings row it keeps (and adopts any left over from when this list was
    /// where you started a session). Showing it in both places would give a
    /// single session two sets of settings that disagree.
    private var visibleConnections: [SavedConnection] {
        #if os(macOS)
        savedConnections.filter { $0.connectionType != .ssh }
        #else
        savedConnections.filter { $0.connectionTypeRawValue != "foveated" }
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleConnections.isEmpty {
                    ContentUnavailableView(
                        "No Connections",
                        systemImage: "display",
                        description: Text(emptyStateDescription)
                    )
                } else {
                    List {
                        ForEach(visibleConnections) { connection in
                            Button {
                                connectTo(connection)
                            } label: {
                                connectionRow(connection)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    modelContext.delete(connection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    connectionToEdit = connection
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Longwave")
            .onChange(of: audioManager.pendingImportedToken) { _, token in
                // A token arrived via AirDrop while no form was open — open a
                // new connection form so it can auto-fill (the form clears the
                // pending token itself; if one is already open it consumes it).
                guard token != nil, !showingNewConnection, connectionToEdit == nil else { return }
                showingNewConnection = true
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Connection", systemImage: "plus") {
                        showingNewConnection = true
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    NavigationLink {
                        ThirdPartyNoticesView()
                    } label: {
                        Label("Third-Party Notices", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
            }
            .sheet(isPresented: $showingNewConnection) {
                NavigationStack {
                    ConnectionFormView(savedConnection: nil)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    showingNewConnection = false
                                }
                            }
                        }
                }
            }
            .sheet(item: $connectionToEdit) { connection in
                NavigationStack {
                    ConnectionFormView(savedConnection: connection)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    connectionToEdit = nil
                                }
                            }
                        }
                }
            }
            #if MOONLIGHT_ENABLED
            .sheet(item: $moonlightSheet) { target in
                MoonlightPairingView(connection: target.connection)
                    .environment(target.session)
            }
            .alert("All Moonlight sessions are in use", isPresented: $showingMoonlightSessionsBusy) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Longwave can stream from \(MoonlightLibrary.count) hosts at once. Disconnect one of the running streams to start another.")
            }
            #endif
        }
    }

    private var emptyStateDescription: String {
        #if MOONLIGHT_ENABLED
        "Add a VNC or Moonlight connection to get started."
        #else
        "Add a VNC connection to get started."
        #endif
    }

    private func connectionRow(_ connection: SavedConnection) -> some View {
        HStack {
            Image(systemName: connection.connectionType.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)

                HStack(spacing: 4) {
                    Text(connection.connectionType.label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    if connection.connectionType == .native {
                        Text(connection.hostname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(connection.hostname):\(connection.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                #if MOONLIGHT_ENABLED
                if connection.connectionType == .moonlight {
                    Text("\(connection.moonlightResolutionLabel) · \(connection.moonlightFPS) FPS")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                #endif

                if connection.connectionType == .native {
                    Text(nativeSummary(connection))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let date = connection.lastConnected {
                    Text("Last connected: \(date, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)

            Spacer()

            Button {
                connectionToEdit = connection
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func nativeSummary(_ connection: SavedConnection) -> String {
        var features: [String] = []
        if connection.nativeUnityEnabled { features.append("Unity") }
        if !connection.nativeUnityEnabled, connection.nativeScreenEnabled { features.append("Screen") }
        if connection.nativeAudioEnabled { features.append("Audio") }
        return features.isEmpty ? "Nothing enabled" : features.joined(separator: " + ")
    }

    private func connectTo(_ connection: SavedConnection) {
        connection.lastConnected = Date()

        switch connection.connectionType {
        case .vnc:
            connectVNC(connection)
        case .native:
            connectNative(connection)
        #if !os(macOS)
        case .ssh:
            connectSSH(connection)
        #else
        case .ssh:
            break
        #endif
        #if MOONLIGHT_ENABLED
        case .moonlight:
            connectMoonlight(connection)
        #endif
        #if FOVEATED_ENABLED
        case .foveated:
            // Unreachable — `visibleConnections` filters PCVR rows out, and the
            // PCVR tab starts sessions now. The case stays for exhaustiveness.
            break
        #endif
        }
    }

    /// Opens the Native window and starts whichever of Screen/Audio this
    /// connection has enabled — both share the same host and token. Both
    /// targets are always remembered (`prepare`/`prepareTarget`) even if
    /// off, so the window's live Screen/Audio toggles can start either one
    /// later without returning to the connection list.
    ///
    /// Unity (one scene per host window) is a spatial idea and stays on
    /// visionOS; the Mac and iPhone clients show a Unity-flagged connection
    /// as the plain desktop stream. visionOS also connects with Screen off,
    /// because a v2 host publishes its window inventory over the same
    /// session and the Native window acts as the per-window controller; the
    /// other clients have nothing to do with that session, so an audio-only
    /// connection there is audio only.
    private func connectNative(_ connection: SavedConnection) {
        macNativeManager.prepare(for: connection)
        #if os(visionOS)
        let unity = connection.nativeUnityEnabled
        #else
        let unity = false
        macNativeManager.unityEnabled = false
        #endif
        // Unity Controls owns the session and starts with the full desktop
        // hidden. Non-Unity Native connections retain their saved Screen
        // startup behavior.
        macNativeManager.liveEnabled = unity ? false : connection.nativeScreenEnabled
        #if os(visionOS)
        macNativeManager.connect(to: connection)
        #else
        if macNativeManager.liveEnabled {
            macNativeManager.connect(to: connection)
        }
        #endif
        audioManager.prepareTarget(
            hostname: connection.hostname,
            port: AudioStreamProtocol.defaultPort,
            token: connection.companionToken,
            title: connection.displayName,
            lowLatency: connection.lowLatencyAudio
        )
        audioManager.liveEnabled = connection.nativeAudioEnabled
        if connection.nativeAudioEnabled {
            audioManager.connect(
                hostname: connection.hostname,
                port: AudioStreamProtocol.defaultPort,
                token: connection.companionToken,
                title: connection.displayName,
                lowLatency: connection.lowLatencyAudio
            )
        }
        if unity {
            #if os(visionOS)
            openWindow(id: "mac-native-unity-controls", value: MacNativeUnityControlID.shared)
            #endif
        } else if connection.nativeScreenEnabled || connection.nativeAudioEnabled {
            openWindow(id: "mac-native-stream", value: MacNativeWindowID.shared)
        }
    }

    #if !os(macOS)
    private func connectSSH(_ connection: SavedConnection) {
        do {
            let id = try sshManager.newShellSession(
                host: connection.hostname,
                port: connection.port,
                username: connection.sshUsername,
                displayName: connection.displayName,
                command: connection.sshLaunchCommand,
                environment: connection.sshEnvironmentVariables(),
                useTmux: connection.sshUseTmux
            )
            openWindow(id: "ssh-terminal", value: id)
        } catch {
            // Device-key generation failure is rare; the terminal window
            // surfaces connection-level errors itself once opened.
        }
    }
    #endif

    private func connectVNC(_ connection: SavedConnection) {
        var username: String?
        var password: String?

        if connection.autoLogin {
            if !connection.savedUsername.isEmpty {
                username = connection.savedUsername
            }
            if !connection.savedPassword.isEmpty {
                password = connection.savedPassword
            }
        }

        // Resolve the companion (audio) connection once: prefer an explicitly
        // linked one (so the desktop can run over a tunnel while the companion
        // uses a LAN host), else a saved audio connection on the same host. It
        // drives both the companion audio stream and the text-injection channel.
        let companionConnection: SavedConnection? = connection.linkedCompanionConnectionID.flatMap { linkedID in
            savedConnections.first { $0.connectionType == .native && $0.nativeAudioEnabled && $0.id == linkedID }
        } ?? savedConnections.first {
            $0.connectionType == .native && $0.nativeAudioEnabled && $0.hostname == connection.hostname
        }

        // Companion audio is skipped for trackpad-only sessions (no video to
        // accompany), but text injection still applies — typing is the point of
        // a trackpad-only overlay over a Mac Virtual Display.
        let audioCompanion = (connection.quality == .trackpadOnly ? nil : companionConnection).map {
            VNCConnectionManager.AudioCompanion(
                hostname: $0.hostname,
                port: AudioStreamProtocol.defaultPort,
                token: $0.companionToken,
                title: $0.displayName,
                lowLatency: $0.lowLatencyAudio
            )
        }
        let companionInject = companionConnection.map {
            VNCConnectionManager.CompanionInject(
                hostname: $0.hostname,
                port: CompanionInjectProtocol.defaultPort,
                token: $0.companionToken
            )
        }

        connectionManager.pendingSavedConnection = connection
        connectionManager.hideLocalCursor = connection.hideLocalCursor
        // A Mac has a real pointer — relative "touchpad" mode makes no sense
        // there, so always use absolute positioning.
        #if os(macOS)
        let effectiveTouchMode: TouchMode = .absolute
        #else
        let effectiveTouchMode = connection.vncTouchMode
        #endif
        connectionManager.connect(
            hostname: connection.hostname,
            port: UInt16(connection.port),
            username: username,
            password: password,
            colorDepth: connection.quality.vncColorDepth,
            jpegQualityLevel: connection.quality.jpegQualityLevel,
            compressionLevel: connection.quality.compressionLevel,
            touchMode: effectiveTouchMode,
            trackpadOnly: connection.quality == .trackpadOnly,
            title: connection.displayName,
            audioCompanion: audioCompanion,
            companionInject: companionInject
        )

        // Open as a sibling window — the connection manager (main) stays open
        // alongside, so surfacing one window never dismisses the other.
        openWindow(id: "remote-desktop")
    }

    #if MOONLIGHT_ENABLED
    /// Each Moonlight session is its own linked copy of moonlight-common-c, so
    /// there are exactly `MoonlightLibrary.count` of them. A row that already
    /// has a session (streaming, or paired with its sheet swiped away) reopens
    /// that one; otherwise the first session with nothing in flight is reset
    /// and pointed at this host.
    private func connectMoonlight(_ connection: SavedConnection) {
        guard let session = moonlightSessions.session(for: connection) else {
            showingMoonlightSessionsBusy = true
            return
        }
        if session.activeConnectionID != connection.id {
            session.disconnect()
        }
        session.connect(to: connection)
        moonlightSheet = MoonlightSheetTarget(connection: connection, session: session)
    }
    #endif
}
