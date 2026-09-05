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
//  Laid out as panels rather than a `Form`. Two of the settings here are choices
//  that need explaining — how the PC is found, and how much of your room the game
//  replaces — and a segmented control with three one-word labels explains
//  nothing. Panels carry a drawing and a sentence per option; the settings that
//  really are just switches stay switches.
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
        connection.controllerBridgeEnabled = ConnectionDefaults.foveatedControllerBridge
        modelContext.insert(connection)
    }
}

// MARK: - Page

private struct PCVRSessionForm: View {
    @Bindable var connection: SavedConnection

    @Environment(FoveatedConnectionManager.self) private var manager
    @Environment(PCVRStore.self) private var store
    @Environment(PCVRSessionLimiter.self) private var limiter
    @Environment(PCVRBandwidthMonitor.self) private var bandwidthMonitor
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    // Live in-session preferences rather than new-connection defaults, so they
    // stay where the immersive view reads them from.
    @AppStorage("foveatedWristHUD") private var wristHUD = true
    @AppStorage("foveatedWristHUDOnRight") private var wristHUDOnRight = false

    @State private var showGestureSettings = false
    @State private var showAlignmentDebug = false
    @State private var showHelp = false
    @State private var showPaywall = false
    @State private var paywallAfterSessionEnd = false
    @State private var showDisconnectAlert = false
    @State private var disconnectMessage = ""
    @State private var showBandwidthCapAlert = false
    @State private var stagedBandwidthEnabled = false
    @State private var stagedWarningGB: Double = 60
    @State private var stagedStopGB: Double = 90
    @State private var hasSeededBandwidthPanel = false

    private var canConnect: Bool {
        FoveatedEndpoint.canConnect(
            mode: connection.foveatedConnectionMode,
            host: connection.hostname,
            port: connection.port
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                sessionPanel
                connectionPanel
                immersionPanel
                controlsPanel
                bandwidthPanel
            }
            .padding(28)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .animation(.spring, value: manager.isDisconnected)
        .toolbar {
            // Access sits in the toolbar rather than in a panel of its own. It is
            // status, not a setting — a seal you can glance at, and the one button
            // that opens the one place this app asks for money.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    paywallAfterSessionEnd = false
                    showPaywall = true
                } label: {
                    accessLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isUnlocked ? "PCVR unlocked" : "Unlock PCVR")
            }
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
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PCVRPaywallView(afterSessionEnd: paywallAfterSessionEnd)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showPaywall = false }
                        }
                    }
            }
            .frame(minWidth: 640, minHeight: 660)
        }
        // A session that stops on its own has to explain itself. The alert path
        // below is for connections that broke; this one is for a limit that was
        // reached, which is not an error and must not be dressed as one.
        .onChange(of: limiter.didEndSession) { _, ended in
            guard ended else { return }
            limiter.didEndSession = false
            paywallAfterSessionEnd = true
            showPaywall = true
        }
        // A bandwidth cap has nothing to do with the trial — explain it on its own
        // terms rather than routing to the paywall above.
        .onChange(of: bandwidthMonitor.didEndSession) { _, ended in
            guard ended else { return }
            bandwidthMonitor.didEndSession = false
            showBandwidthCapAlert = true
        }
        .alert("Bandwidth Cap Reached", isPresented: $showBandwidthCapAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This session ended because the PC's monthly data cap was reached. Reset the counter or raise the limit in the Bandwidth panel to keep streaming.")
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

    // MARK: Access

    /// Sealed or unsealed, and during a trial session the clock that is running
    /// down — the answer to "how long have I got" belongs where the answer to
    /// "why is there a limit" already is.
    ///
    /// The word is carried, not just the seal: an unbroken-seal icon on its own is
    /// only legible to someone who already knows what it means, and "Trial" in
    /// orange is legible to everyone. Green for the unlocked state, which is the
    /// state nobody needs to act on.
    @ViewBuilder
    private var accessLabel: some View {
        if store.isUnlocked {
            accessPill("Unlocked", systemImage: "checkmark.seal.fill", color: Self.unlockedGreen)
        } else if store.isTrial {
            if let remaining = limiter.remaining, !manager.isDisconnected {
                accessPill("Trial · \(PCVRSessionLimiter.clock(remaining))",
                           systemImage: "xmark.seal.fill", color: Self.trialOrange)
                    .monospacedDigit()
            } else {
                accessPill("Trial", systemImage: "xmark.seal.fill", color: Self.trialOrange)
            }
        } else {
            // StoreKit has not answered yet. A seal either way would be a guess,
            // and the wrong guess to show a paying customer.
            ProgressView().controlSize(.small)
        }
    }

    /// A status pill: solid disc for the glyph at the leading edge, word beside
    /// it, tinted capsule behind both. Drawn rather than left to the toolbar's own
    /// glass capsule, because the state is the point — a plain button in the
    /// toolbar's usual grey says "a control lives here", and what this has to say
    /// is "you are on the trial".
    /// Fixed rather than the system `.orange`, which is lighter and sits close
    /// enough to the window's grey glass to read as a disabled control.
    private static let trialOrange = Color(red: 0xF9 / 255, green: 0x72 / 255, blue: 0x0B / 255)
    private static let unlockedGreen = Color(red: 0x2F / 255, green: 0xA9 / 255, blue: 0x4E / 255)

    private func accessPill(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                // Close to the word beside it in weight, so the disc and the text
                // read as one mark on the fill rather than two shades of orange —
                // but grey rather than black, which at this size looked like a
                // hole punched in the pill.
                .background(Color(white: 0.28), in: Circle())
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(.black.opacity(0.85))
        }
        // Sized to the 44 pt circular button beside it — a toolbar reads as one
        // row of controls or as a mistake, and there is no middle.
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        // Solid, not a tint: a translucent capsule over the window's glass leaves
        // orange-on-grey at about the contrast of a disabled control, and this is
        // the one thing in the toolbar that has something to say.
        .background(color, in: Capsule())
        .contentShape(Capsule())
        // `.plain` drops the system's gaze highlight along with its capsule; this
        // puts the gaze response back on the shape actually being drawn.
        .hoverEffect(.highlight)
    }

    // MARK: Header + session

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
        .padding(.vertical, 6)
    }

    /// The panel that changes: the start button while disconnected, the live
    /// session controls while streaming.
    private var sessionPanel: some View {
        VStack(spacing: 14) {
            if manager.isDisconnected {
                if let error = manager.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    if manager.isConnecting || manager.isAutoReconnecting {
                        manager.cancelConnect()
                    } else {
                        connection.lastConnected = Date()
                        manager.beginConnect(connection)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if manager.isConnecting || manager.isAutoReconnecting {
                            ProgressView().controlSize(.small)
                        }
                        Text(manager.isConnecting || manager.isAutoReconnecting
                             ? "Cancel" : "Start streaming")
                    }
                    .frame(maxWidth: 320)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(manager.isConnecting || manager.isAutoReconnecting ? .red : .accentColor)
                .disabled(!manager.isConnecting && !manager.isAutoReconnecting && !canConnect)

                Text(manager.isAutoReconnecting
                     // A wait, not a hang: the PC restarts to apply a setting change and is
                     // gone for the better part of a minute. Saying nothing for that long
                     // looks exactly like a session that quietly died.
                     ? "The PC is not answering — probably restarting to apply a change. Reconnecting as soon as it is back."
                     : startCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                FoveatedControlsView(embedded: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    /// How the PC will be found, plus — while the limit still applies — what will
    /// happen twenty minutes in. Said before the session starts rather than after,
    /// which is the difference between a limit and a surprise.
    private var startCaption: String {
        let mode = connection.foveatedConnectionMode.detail
        guard store.isTrial else { return mode }
        return mode + " · Trial sessions end after 20 minutes."
    }

    // MARK: Panels

    /// Automatic first and selected by default; the IP fields only appear if you
    /// go looking for them. Discovery is the whole point — a PC running the
    /// companion announces itself, and typing an address is the fallback for a
    /// network where mDNS does not carry.
    private var connectionPanel: some View {
        PCVRPanel(title: "Connection",
                  systemImage: "antenna.radiowaves.left.and.right",
                  subtitle: "How the headset finds your PC") {
            HStack(alignment: .top, spacing: 14) {
                ForEach(FoveatedConnectionMode.allCases, id: \.self) { mode in
                    PCVROptionTile(
                        title: mode.label,
                        detail: mode.detail,
                        isSelected: connection.foveatedConnectionMode == mode,
                        action: { connection.foveatedConnectionMode = mode }
                    ) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 30))
                            .foregroundStyle(.tint)
                            .frame(height: 40)
                    }
                }
            }

            if connection.foveatedConnectionMode == .local {
                VStack(spacing: 10) {
                    LabeledContent("Host IP") {
                        TextField("192.168.1.20", text: $connection.hostname)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Port") {
                        TextField("Port", value: $connection.port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: connection.foveatedConnectionMode)
        .disabled(!manager.isDisconnected)
    }

    /// Status, not a chooser. Which style is in force follows from whether the PC
    /// is sending an alpha channel, and that switch lives in the Windows Companion
    /// because the PC is what pays for it — an encoder encoding transparency the
    /// headset was never going to composite is pure waste. So the tab reports the
    /// state and says where the switch is, rather than offering a choice it cannot
    /// honour on its own.
    private var immersionPanel: some View {
        PCVRPanel(title: "Immersion",
                  systemImage: "cube.transparent",
                  subtitle: "How much of your room the game replaces") {
            HStack(alignment: .top, spacing: 14) {
                ForEach(FoveatedImmersionStyle.allCases, id: \.self) { style in
                    PCVRStatusTile(
                        title: style.label,
                        detail: style.detail,
                        isActive: manager.immersionStyle == style
                    ) {
                        ImmersionGlyph(style: style)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if let disagreement = manager.alphaDisagreement {
                    // The host's own telemetry contradicting the style we opened in. The
                    // loudest thing this panel can say, because it is the one case where
                    // the tiles above are describing something the PC is not doing.
                    Label(disagreement, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if manager.immersionStyle == nil {
                    Label("The PC decides this. It is read when you connect.",
                          systemImage: "pc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if manager.immersionUnanswered {
                    Label("The PC did not answer when this session started, so it opened in Progressive.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !manager.isDisconnected {
                    // Which route answered, not just what it said. Opening in the wrong
                    // immersion is the failure that keeps coming back here, and every time
                    // the first question has been "did it actually ask the PC, and how".
                    Label("Read from \(FoveatedHostInfo.lastSource.rawValue) when this session started.",
                          systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label(passthroughNote, systemImage: "pc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            /* Status, not a switch. visionOS forwards the headset microphone for the whole
               session on its own — `FoveatedStreamingSession` has no microphone API at all,
               so a toggle here would persist a preference nothing could act on (one did, for
               a while). What can vary is the PC: CloudXR delivers the mic through its own
               kernel audio driver, and without that driver the runtime creates the stream
               and captures nothing. The PC reports whether the driver is there, and this
               row relays it. */
            VStack(alignment: .leading, spacing: 6) {
                Label("Microphone", systemImage: "mic")
                Text("The headset microphone is always sent to the PC, where it appears as an ordinary recording device named NVIDIA CloudXR. Games and voice chat pick it from the list like any USB microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch manager.hostMicrophone {
                case .ready:
                    Label("The PC has the CloudXR audio driver. Microphone is available.",
                          systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .driverMissing:
                    Label("The PC is missing the CloudXR audio driver, so nothing will hear you. Install it from the PCVR tab in the Windows Companion.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    Label("Whether the PC can receive it is read when you connect.",
                          systemImage: "pc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var controlsPanel: some View {
        PCVRPanel(title: "Controls",
                  systemImage: "hand.point.up.left",
                  subtitle: "Hands, controllers and the wrist HUD") {
            Toggle(isOn: $connection.controllerBridgeEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Hands and controllers", systemImage: "gamecontroller")
                    Text("Sends your hand tracking, and a paired Switch Pro or Quest controller, to the PC. The Windows Companion chooses whether games see OpenXR controllers, an Xbox 360 controller, or both. A controller is optional — pinch gestures work on their own. Turn this off and a session has no input at all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!manager.isDisconnected)

            Divider()

            Toggle(isOn: $wristHUD) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Wrist HUD", systemImage: "hand.raised")
                    Text("Turn a palm toward your face to quit the running title, show the PC's desktop, or switch between controllers and bare hands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if wristHUD {
                Picker("Worn on", selection: $wristHUDOnRight) {
                    Text("Left wrist").tag(false)
                    Text("Right wrist").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Divider()

            HStack(spacing: 14) {
                Button {
                    showGestureSettings = true
                } label: {
                    Label("Gesture mapping", systemImage: "hand.pinch")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)

                // Alignment is diagnosed against a live stream — offering it while
                // disconnected would only show an empty graph.
                if !manager.isDisconnected {
                    Button {
                        showAlignmentDebug = true
                    } label: {
                        Label("Hand alignment", systemImage: "hand.raised.fingers.spread")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// A monthly cap, configured per PC rather than per connection: each machine's own
    /// host keeps its own counter and thresholds (see `PCVRBandwidthMonitor`), so this
    /// panel is only ever showing and editing whichever one you're connected to right
    /// now — nothing here is cached client-side by hostname.
    ///
    /// Three states, not two: a host running an older binary never sends the packet
    /// this panel depends on, and gating purely on "connected" would show editable
    /// controls that silently do nothing. Gate on having actually heard from the host.
    private var bandwidthPanel: some View {
        PCVRPanel(title: "Bandwidth",
                  systemImage: "network",
                  subtitle: "A monthly data cap for this PC") {
            if manager.isDisconnected {
                Label("Connect to a PC to configure its bandwidth cap.", systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if manager.controllerBridge?.bandwidth == nil {
                Label("This PC's host doesn't report bandwidth.", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Level state: stays true for the rest of the month once crossed,
                // regardless of whether this session was the one that crossed it — see
                // PCVRBandwidthMonitor. This is the only place Reset is reachable once
                // it's set, so it has to render every time, not just right after a stop.
                if bandwidthMonitor.isOverStopThreshold {
                    Label("Cap reached — reset the counter or raise the limit to keep streaming.",
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                Toggle("Enabled", isOn: $stagedBandwidthEnabled)
                    .onChange(of: stagedBandwidthEnabled) { _, _ in commitBandwidthControl() }

                LabeledContent("Warning at") {
                    TextField("GB", value: $stagedWarningGB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitBandwidthControl)
                }
                LabeledContent("Stop at") {
                    TextField("GB", value: $stagedStopGB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitBandwidthControl)
                }

                if let used = bandwidthMonitor.usedGB, let stop = bandwidthMonitor.stopThresholdGB, stop > 0 {
                    ProgressView(value: min(used, stop), total: stop) {
                        Text("\(used, specifier: "%.1f") / \(stop, specifier: "%.0f") GB this month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    manager.controllerBridge?.requestBandwidthReset()
                } label: {
                    Label("Reset counter", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: manager.controllerBridge?.bandwidth != nil) { _, hasData in
            if hasData { seedBandwidthPanelIfNeeded() }
        }
        .onChange(of: manager.isDisconnected) { _, disconnected in
            // A new connection may be a different PC with different settings — don't
            // carry the last one's staged values into it.
            if disconnected { hasSeededBandwidthPanel = false }
        }
    }

    /// Seed the staged fields from whatever the host is already reporting, once, the
    /// first time real data arrives this connection. Deliberately not re-seeded on
    /// every packet after that (~1 Hz) — it would fight the user mid-edit, and
    /// CompanionWindows has no edit controls today for another actor to race against.
    private func seedBandwidthPanelIfNeeded() {
        guard !hasSeededBandwidthPanel, let bandwidth = manager.controllerBridge?.bandwidth else { return }
        stagedBandwidthEnabled = bandwidth.flags.contains(.enabled)
        stagedWarningGB = Double(bandwidth.warningThresholdGB)
        stagedStopGB = Double(bandwidth.stopThresholdGB)
        hasSeededBandwidthPanel = true
    }

    private func commitBandwidthControl() {
        manager.controllerBridge?.updateBandwidthControl(
            enabled: stagedBandwidthEnabled,
            warningThresholdGB: Float(stagedWarningGB),
            stopThresholdGB: Float(stagedStopGB)
        )
    }

    /// Says where the switch is, and — once a session can answer — what it is set
    /// to. Before that there is nothing to report but the location.
    private var passthroughNote: String {
        let base = "Turn on Passthrough cutouts in the Windows Companion to let games "
            + "punch holes in the picture: anything the PC marks transparent becomes your "
            + "room instead of black. Changing it restarts PCVR on the PC."
        switch manager.controllerBridge?.alphaBlendActive {
        case true:  return "Passthrough cutouts are on for this PC. " + base
        case false: return "Passthrough cutouts are off for this PC. " + base
        case nil:   return base
        }
    }

    // MARK: Disconnect handling

    /// A cheap value that changes whenever the session status changes, so
    /// `onChange` fires.
    private var statusKey: String { manager.status.description }

    private func evaluateDisconnect() {
        guard case .disconnected(let reason) = manager.status else { return }
        manager.noteDisconnect(reason: "\(reason)")
        /* Silent only when we asked for it, which the reason code cannot tell us.
           `appInitiatedDisconnect` used to be suppressed here outright, following Apple's
           sample — but the *host* tearing the session down arrives under that same reason,
           so a PC restarting to apply the passthrough switch was indistinguishable from
           the user pressing Disconnect, and got the same silence. Measured on device:
           control link closed by the host, `appInitiatedDisconnect`, swallowed before it
           reached any reconnect path. Intent now comes from our own flag. */
        if manager.consumeExpectedDisconnect() { return }
        if reason == .unauthorized { return }
        /* The host ending the session is usually the PC restarting PCVR to apply something
           it can only read at start — the passthrough switch does exactly that. Still no
           alert, but no longer nothing: the manager waits for the PC to come back and
           reconnects if it does, and leaves it alone if the person simply stopped it. */
        /* If no reconnect was scheduled, fall through to the alert rather than returning.
           This used to `return` unconditionally, so a host-ended session that could not be
           retried — the budget already spent — produced nothing at all: no reconnect and no
           alert, just a session that stopped. Silence is the one response that leaves
           somebody staring at an idle tab wondering whether to wait. */
        if reason == .endpointInitiatedDisconnect || reason == .appInitiatedDisconnect,
           manager.handleHostEndedSession() {
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
