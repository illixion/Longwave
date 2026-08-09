//  PCVRTabView.swift
//
//  The PCVR tab: one place to start a foveated CloudXR session, learn the
//  in-headset gestures, and change every PCVR setting.
//
//  PCVR used to be a row in the connection list that flung open a window of its
//  own. That fitted badly on both sides — its settings were split between the
//  connection form and the Settings tab, and the connection list is otherwise a
//  list of *addresses*, which PCVR does not have: the host advertises itself over
//  Bonjour and the system presents the picker. So it gets a tab, and the rest of
//  the app stays about desktops and terminals.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import SwiftUI
import SwiftData

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

struct PCVRTabView: View {
    @Environment(\.modelContext) private var modelContext

    /// PCVR keeps exactly one set of settings, stored as a `SavedConnection` of
    /// type `.foveated` so the manager, the bridge and the game library all keep
    /// taking the type they already take. Rows created back when PCVR was a
    /// connection-list entry are picked up here rather than orphaned — most
    /// recent first, so an upgrade lands on the one last used.
    @Query(
        filter: #Predicate<SavedConnection> { $0.connectionTypeRawValue == "foveated" },
        sort: \SavedConnection.lastConnected,
        order: .reverse
    )
    private var savedSessions: [SavedConnection]

    var body: some View {
        NavigationStack {
            Group {
                if let connection = savedSessions.first {
                    PCVRSessionForm(connection: connection)
                } else {
                    // One frame at most, between `onAppear` inserting the row and
                    // the query seeing it.
                    ProgressView()
                }
            }
            .navigationTitle("PCVR")
        }
        .onAppear(perform: createSettingsIfNeeded)
    }

    private func createSettingsIfNeeded() {
        guard savedSessions.isEmpty else { return }
        let connection = SavedConnection(
            hostname: "",
            port: ConnectionDefaults.port(for: .foveated),
            label: "PCVR",
            connectionType: .foveated
        )
        connection.foveatedConnectionMode = ConnectionDefaults.foveatedMode
        connection.foveatedImmersionStyle = ConnectionDefaults.foveatedImmersion
        connection.controllerBridgeEnabled = ConnectionDefaults.foveatedControllerBridge
        modelContext.insert(connection)
    }
}

// MARK: - Form

private struct PCVRSessionForm: View {
    @Bindable var connection: SavedConnection

    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    // Live in-session preferences rather than new-connection defaults, so they
    // stay where the immersive view reads them from.
    @AppStorage("foveatedWristHUD") private var wristHUD = true
    @AppStorage("foveatedWristHUDOnRight") private var wristHUDOnRight = false

    @State private var showGestureSettings = false
    @State private var showAlignmentDebug = false
    @State private var showHelp = false
    @State private var showDisconnectAlert = false
    @State private var disconnectMessage = ""

    private var canConnect: Bool {
        FoveatedEndpoint.canConnect(
            mode: connection.foveatedConnectionMode,
            host: connection.hostname,
            port: connection.port
        )
    }

    var body: some View {
        Form {
            Section { header }
            if manager.isDisconnected {
                Section { connectRow }
            } else {
                Section("Session") {
                    FoveatedControlsView(embedded: true)
                        .padding(.vertical, 8)
                }
            }
            connectionSection
            immersionSection
            controlsSection
        }
        .animation(.spring, value: manager.isDisconnected)
        .toolbar {
            // A question mark rather than the old Gesture Controls button: the
            // gestures are one part of learning PCVR, and the rest of it had
            // nowhere to go. Mapping still has its own row under Controls.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHelp = true
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                PCVRHelpView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showHelp = false }
                        }
                    }
            }
            .frame(minWidth: 620, minHeight: 640)
        }
        .sheet(isPresented: $showGestureSettings) {
            GestureMappingSettingsView()
        }
        .sheet(isPresented: $showAlignmentDebug) {
            NavigationStack {
                FoveatedAlignmentDebugView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showAlignmentDebug = false }
                        }
                    }
            }
            .frame(minWidth: 560, minHeight: 620)
        }
        .task {
            // The immersive space (the streamed video) opens and closes with the
            // session. Must be set before connecting — and the main window outlives
            // every other scene, which is the other reason this belongs in a tab.
            manager.setImmersivePresentationBehaviors(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
        }
        .onChange(of: statusKey) { _, _ in evaluateDisconnect() }
        .alert("Disconnected", isPresented: $showDisconnectAlert) {
            Button("Reconnect") { manager.retryLastConnection() }
            Button("OK", role: .cancel) { }
        } message: {
            Text(disconnectMessage)
        }
    }

    // MARK: Header + connect

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "visionpro")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
            Text("PC VR, streamed")
                .font(.title2).fontWeight(.semibold)
            Text("Play SteamVR and OpenXR titles from a Windows PC with an NVIDIA RTX card. Your eye tracking reaches the PC, so the game renders in full detail where you are looking and spends less everywhere else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var connectRow: some View {
        if let error = manager.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        }

        Button {
            if manager.isConnecting {
                manager.cancelConnect()
            } else {
                connection.lastConnected = Date()
                manager.beginConnect(connection)
            }
        } label: {
            HStack(spacing: 10) {
                if manager.isConnecting { ProgressView().controlSize(.small) }
                Text(manager.isConnecting ? "Cancel" : "Start streaming")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(manager.isConnecting ? .red : .accentColor)
        .disabled(!manager.isConnecting && !canConnect)
        .listRowBackground(Color.clear)

        Text(connection.foveatedConnectionMode.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
    }

    // MARK: Settings

    /// Automatic first and selected by default; the IP fields only appear if you
    /// go looking for them. Discovery is the whole point — a PC running the
    /// companion announces itself, and typing an address is the fallback for a
    /// network where mDNS does not carry.
    private var connectionSection: some View {
        Section("Connection") {
            Picker("Find the PC", selection: $connection.foveatedConnectionMode) {
                ForEach(FoveatedConnectionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if connection.foveatedConnectionMode == .local {
                TextField("Host IP", text: $connection.hostname)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Port", value: $connection.port, format: .number.grouping(.never))
            }
        }
        .disabled(!manager.isDisconnected)
    }

    private var immersionSection: some View {
        Section("Immersion") {
            Picker("Style", selection: $connection.foveatedImmersionStyle) {
                ForEach(FoveatedImmersionStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            Toggle("Microphone", isOn: $connection.foveatedMicEnabled)
        }
        .disabled(!manager.isDisconnected)
    }

    private var controlsSection: some View {
        Section("Controls") {
            Toggle("Hands and controllers", isOn: $connection.controllerBridgeEnabled)
                .disabled(!manager.isDisconnected)
            Text("Sends your hand tracking, and a paired Switch Pro or Quest controller, to the PC as a pair of Valve Index controllers. A controller is optional — pinch gestures work on their own. Turn this off and a session has no input at all.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Wrist HUD", isOn: $wristHUD)
            if wristHUD {
                Picker("HUD hand", selection: $wristHUDOnRight) {
                    Text("Left").tag(false)
                    Text("Right").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Button {
                showGestureSettings = true
            } label: {
                Label("Gesture mapping", systemImage: "hand.pinch")
            }

            // Alignment is diagnosed against a live stream — offering it while
            // disconnected would only show an empty graph.
            if !manager.isDisconnected {
                Button {
                    showAlignmentDebug = true
                } label: {
                    Label("Hand alignment", systemImage: "hand.raised.fingers.spread")
                }
            }
        }
    }

    // MARK: Disconnect handling

    /// A cheap value that changes whenever the session status changes, so
    /// `onChange` fires.
    private var statusKey: String { manager.status.description }

    private func evaluateDisconnect() {
        guard case .disconnected(let reason) = manager.status else { return }
        // Suppress alerts for expected reasons (mirrors Apple's sample).
        if reason == .appInitiatedDisconnect || reason == .unauthorized || reason == .endpointInitiatedDisconnect {
            return
        }
        // Wi-Fi blips are routine on the networks this must work on: the first
        // response is a quiet automatic retry (the system's per-session consent
        // prompt will reappear — that is the framework's, not ours). Only when the
        // retry budget is spent does this become a modal, and then with a
        // Reconnect button rather than a dead end.
        if manager.handleUnexpectedDisconnect() { return }
        disconnectMessage = reason.errorDescription ?? "The PCVR session ended unexpectedly."
        showDisconnectAlert = true
    }
}
#endif
