import Foundation
import AppKit
import CoreGraphics
import DebugTrace

@Observable
final class MacNativeStreamingController {
    let port: UInt16 = MacNativeStreamProtocol.defaultPort

    private static let enabledKey = "macNativeStreamingEnabled"

    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            withMutation(keyPath: \.enabled) {
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
            if newValue {
                startServer()
            } else {
                stopServer()
            }
        }
    }

    // MARK: Virtual display

    /// The pre-picker switch. Read once, as the default for `selectedDisplayID`.
    private static let virtualDisplayEnabledKey = "macNativeVirtualDisplayEnabled"
    private static let selectedDisplayKey = "macNativeSelectedDisplay"
    private static let virtualDisplayPresetKey = "macNativeVirtualDisplayPreset"
    private static let virtualDisplayExclusiveKey = "macNativeVirtualDisplayExclusive"
    private static let bitrateCeilingKey = "macNativeBitrateMbps"

    /// The desktop stream's bitrate in Mbps, or 0 for automatic (scaled to
    /// the display's pixel count and frame rate). Either way the stream backs
    /// off on its own when the link drops frames, and recovers after.
    var bitrateMbps: Int {
        get {
            access(keyPath: \.bitrateMbps)
            return UserDefaults.standard.integer(forKey: Self.bitrateCeilingKey)
        }
        set {
            withMutation(keyPath: \.bitrateMbps) {
                UserDefaults.standard.set(newValue, forKey: Self.bitrateCeilingKey)
            }
            capture?.setBitrateCeiling(bitrateCeiling)
        }
    }

    private var bitrateCeiling: Int? {
        bitrateMbps > 0 ? bitrateMbps * 1_000_000 : nil
    }

    /// Which desktop the stream shows: `MacNativeStreamProtocol.virtualDisplayID`
    /// for a display the Mac renders just for the headset (the Mac Virtual
    /// Display model), or a physical display's UUID. Changeable from this
    /// pane and from the headset (`selectDisplay`). A physical display that
    /// is not connected falls back to the main one.
    var selectedDisplayID: String {
        get {
            access(keyPath: \.selectedDisplayID)
            if let stored = UserDefaults.standard.string(forKey: Self.selectedDisplayKey) {
                return stored
            }
            if UserDefaults.standard.bool(forKey: Self.virtualDisplayEnabledKey) {
                return MacNativeStreamProtocol.virtualDisplayID
            }
            return MacNativeDisplayCatalog.mainDisplayUUID() ?? ""
        }
        set {
            guard newValue != selectedDisplayID else { return }
            withMutation(keyPath: \.selectedDisplayID) {
                UserDefaults.standard.set(newValue, forKey: Self.selectedDisplayKey)
            }
            restartCaptureIfRunning()
            publishDisplayList()
        }
    }

    var virtualDisplayEnabled: Bool {
        selectedDisplayID == MacNativeStreamProtocol.virtualDisplayID
    }

    /// The Mac's physical displays, for the picker here and on the headset.
    /// Remembered while they are offline, so a display the exclusive virtual
    /// display switched off can still be picked to bring it back.
    private(set) var physicalDisplays: [MacNativeStreamProtocol.DisplayInfo] = []
    @ObservationIgnored private var screenObserver: NSObjectProtocol?

    /// Re-reads the display set and pushes the choice to connected viewers.
    func refreshDisplays() {
        let online = MacNativeDisplayCatalog.physicalDisplays()
        if !online.isEmpty || !(virtualDisplay?.configuration.exclusive ?? false) {
            physicalDisplays = online
        }
        publishDisplayList()
    }

    private var displayList: MacNativeStreamProtocol.DisplayList {
        let size = virtualDisplayPreset.pointSize
        let virtual = MacNativeStreamProtocol.DisplayInfo(
            id: MacNativeStreamProtocol.virtualDisplayID,
            name: "Virtual Display",
            isVirtual: true,
            width: size.width,
            height: size.height
        )
        let selected = selectedDisplayID
        let effective = selected == MacNativeStreamProtocol.virtualDisplayID
            || physicalDisplays.contains(where: { $0.id == selected })
            ? selected
            : MacNativeDisplayCatalog.mainDisplayUUID()
        return .init(displays: [virtual] + physicalDisplays, selectedID: effective)
    }

    private func publishDisplayList() {
        server?.broadcastDisplayList(displayList)
    }

    var virtualDisplayPreset: MacNativeVirtualDisplayPreset {
        get {
            access(keyPath: \.virtualDisplayPreset)
            return UserDefaults.standard.string(forKey: Self.virtualDisplayPresetKey)
                .flatMap(MacNativeVirtualDisplayPreset.init(rawValue:)) ?? .qhd
        }
        set {
            withMutation(keyPath: \.virtualDisplayPreset) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.virtualDisplayPresetKey)
            }
            if virtualDisplayEnabled { restartCaptureIfRunning() }
            publishDisplayList()
        }
    }

    /// Disconnect the Mac's physical displays while the virtual one streams,
    /// so the desktop exists only on the headset. They reconnect on their own
    /// when the stream ends (or the companion dies).
    var virtualDisplayExclusive: Bool {
        get {
            access(keyPath: \.virtualDisplayExclusive)
            return UserDefaults.standard.bool(forKey: Self.virtualDisplayExclusiveKey)
        }
        set {
            withMutation(keyPath: \.virtualDisplayExclusive) {
                UserDefaults.standard.set(newValue, forKey: Self.virtualDisplayExclusiveKey)
            }
            // Settable ahead of time: it only matters once the virtual
            // display is the one streaming.
            if virtualDisplayEnabled { restartCaptureIfRunning() }
        }
    }

    /// The live virtual display, if the running capture is streaming one.
    private var virtualDisplay: MacNativeVirtualDisplay?
    /// One line for the Native pane: what the virtual display came up as,
    /// or why it was skipped.
    private(set) var virtualDisplaySummary: String?
    /// Why the virtual display would be skipped if a stream started now —
    /// a Mac Virtual Display session owning the display stack. Refreshed
    /// when the Native pane appears and whenever a capture starts.
    private(set) var virtualDisplayConflict: String?

    func refreshVirtualDisplayConflict() {
        virtualDisplayConflict = MacNativeVirtualDisplay.activeSessionConflict()
    }

    private var virtualDisplayConfiguration: MacNativeVirtualDisplay.Configuration? {
        guard virtualDisplayEnabled else { return nil }
        return MacNativeVirtualDisplay.Configuration(
            pointSize: virtualDisplayPreset.pointSize,
            exclusive: virtualDisplayExclusive
        )
    }

    /// A settings change while viewers are watching applies immediately,
    /// at the cost of the same brief black frame a chroma change costs.
    private func restartCaptureIfRunning() {
        guard capture != nil else { return }
        stopCapture()
        startCapture()
    }

    /// Every viewer currently connected, in join order. Several at once is
    /// normal now — one capture and one encode fan out to all of them.
    private(set) var connectedDeviceNames: [String] = []
    private(set) var lastError: String?
    private(set) var isCapturing = false
    /// What the live desktop capture negotiated — worth surfacing, because the
    /// chroma format is chosen by the viewer's own hardware probe and there is
    /// otherwise no way to tell 4:2:2 from 4:2:0 by looking at the picture.
    private(set) var desktopVideoSummary: String?
    /// Where a desktop frame's time goes before it reaches the headset —
    /// display refresh to capture, encode, and send to acknowledgement — so
    /// "it feels laggy" can be pinned on one of them.
    private(set) var latencySummary: String?
    @ObservationIgnored private var lastLatencyLog = ContinuousClock.now
    @ObservationIgnored private let log = DebugLogger(
        subsystem: "pro.longwave.companion",
        category: "MacNativeStreaming"
    )

    /// Mouse/keyboard remote control for the Screen stream — see
    /// `MacNativeInputService` for why it's a separate opt-in from Screen
    /// itself.
    let input = MacNativeInputService()

    /// Bridges `input.mouseControlEnabled`/`keyboardShortcutsEnabled` so
    /// `NativePane` can bind through this controller and so toggling either
    /// immediately re-broadcasts availability to a connected client.
    var mouseControlEnabled: Bool {
        get { input.mouseControlEnabled }
        set {
            input.mouseControlEnabled = newValue
            updateInputAvailability()
        }
    }

    var keyboardShortcutsEnabled: Bool {
        get { input.keyboardShortcutsEnabled }
        set {
            input.keyboardShortcutsEnabled = newValue
            updateInputAvailability()
        }
    }

    /// Re-checks Accessibility and pushes current mouse + keyboard-shortcuts
    /// availability to a live client. Safe to call repeatedly.
    func updateInputAvailability() {
        input.refreshAccessibility()
        server?.setMouseAvailability(input.mouseStatusByte)
        server?.setKeyboardAvailability(input.keyboardStatusByte)
    }

    /// Prompts for Accessibility, then refreshes the live channel's availability.
    func grantInputAccessibility() {
        input.promptAccessibility()
        updateInputAvailability()
    }

    /// The captured display's frame in global (point-space) coordinates, and
    /// the desktop stream's pixels-per-point — together they translate a
    /// stream-space (x, y) from the viewer into a real `CGEvent` screen
    /// position. The desktop is captured at the display's native backing scale,
    /// so on a Retina Mac the two spaces differ by 2 and skipping the divide
    /// puts every click at twice its intended offset.
    private var displayFrame: CGRect = .zero
    private var displayPixelScale: CGFloat = 1
    /// Whether *every* connected viewer said it can hardware-decode 4:2:2.
    /// There is one encode for all of them, so the odd one out decides: a
    /// 4:2:0-only viewer joining a 4:2:2 session restarts the capture at 4:2:0
    /// rather than sending it a picture it cannot decode.
    private var viewersDecodeHEVC422 = false
    /// What the running capture was started with, so a change in the viewer
    /// set only restarts it when it actually differs.
    private var captureChroma: MacHEVCEncoder.Chroma = .yuv420
    /// Whether the window-stream coordinator (inventory + per-window capture)
    /// is running — it starts with the first v2 viewer, not with each one.
    private var windowStreamsRunning = false

    private func globalPoint(x: UInt16, y: UInt16) -> CGPoint {
        CGPoint(
            x: displayFrame.origin.x + CGFloat(x) / displayPixelScale,
            y: displayFrame.origin.y + CGFloat(y) / displayPixelScale
        )
    }

    /// Maps a stream-space (x, y) to a global point for any stream: the
    /// desktop stream via the display frame, a window stream via its
    /// window's current frame and pixel scale.
    private func globalPoint(windowID: UInt32, x: UInt16, y: UInt16) -> CGPoint? {
        if windowID == MacNativeStreamProtocol.desktopStreamID {
            return globalPoint(x: x, y: y)
        }
        guard let target = windowStreams.target(for: windowID) else { return nil }
        return CGPoint(
            x: target.frame.origin.x + CGFloat(x) / target.pixelScale,
            y: target.frame.origin.y + CGFloat(y) / target.pixelScale
        )
    }

    /// Raises the target window when a click would otherwise land on
    /// whatever occludes it — CGEvent clicks are routed by screen position,
    /// not by window, so per-window input needs the window frontmost.
    private func raiseIfOccluded(windowID: UInt32, at point: CGPoint) {
        guard windowID != MacNativeStreamProtocol.desktopStreamID,
              let target = windowStreams.target(for: windowID),
              !MacNativeWindowStreamCoordinator.isTopmost(target, at: point) else { return }
        input.raiseWindow(target)
    }

    var statusText: String {
        if !connectedDeviceNames.isEmpty {
            return "Streaming to \(connectedDeviceNames.joined(separator: ", "))"
        }
        return enabled ? "Listening on port \(port)" : "Disabled"
    }

    private var token = ""
    private var server: MacNativeStreamServer?
    private var capture: MacNativeScreenCapture?
    /// Per-window (Unity-style) streams for the active v2 viewer.
    private let windowStreams = MacNativeWindowStreamCoordinator()
    private var captureGeneration = 0
    private var serverGeneration = 0

    init() {
        _ = MacNativeStreamNotifications.shared
        physicalDisplays = MacNativeDisplayCatalog.physicalDisplays()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplays() }
        }
    }

    func configure(token: String) {
        self.token = token
        if enabled {
            startServer()
        }
    }

    func updateToken(_ token: String) {
        self.token = token
        if enabled {
            startServer()
        }
    }

    private func startServer() {
        serverGeneration += 1
        let generation = serverGeneration
        let previousServer = server
        server = nil
        connectedDeviceNames = []
        viewersDecodeHEVC422 = false
        stopCapture()
        stopWindowStreams()

        guard !token.isEmpty else {
            lastError = "The companion access token is empty."
            previousServer?.stop()
            return
        }

        lastError = nil
        MacNativeStreamNotifications.shared.requestAuthorization()

        let startReplacement: @Sendable () -> Void = { [weak self] in
            _ = Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation, self.enabled else {
                    return
                }
                self.launchServer(generation: generation)
            }
        }
        if let previousServer {
            previousServer.stop(completion: startReplacement)
        } else {
            startReplacement()
        }
    }

    private func launchServer(generation: Int) {
        let server = MacNativeStreamServer(port: port, token: token)
        server.onClientConnected = { [weak self] deviceName, wantsScreen in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                // A session that's audio-only from the start (the Native
                // window's Screen toggle already off when it connected) skips
                // the notification — it's redundant on every headset don,
                // unlike an actual screen connection.
                if wantsScreen {
                    MacNativeStreamNotifications.shared.connected(deviceName: deviceName)
                }
            }
        }
        // Whoever is watching right now. Capture itself is driven by stream
        // subscriptions (below), which are reference-counted across viewers —
        // this is only the things that depend on *who* is connected.
        server.onClientsChanged = { [weak self] clients in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.connectedDeviceNames = clients.map(\.deviceName)
                // Only ever raised by a viewer that has probed its own
                // hardware decoder — see `MacNativeVideoCapability`.
                self.viewersDecodeHEVC422 = !clients.isEmpty
                    && clients.allSatisfy(\.decodesHEVC422)
                // The inventory runs for as long as at least one v2 viewer is
                // around to receive it.
                if clients.contains(where: \.isV2) {
                    self.startWindowStreams()
                } else {
                    self.stopWindowStreams()
                }
                self.applyDesktopChromaChange()
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.lastError = message
            }
        }
        server.onMouseMove = { [weak self] x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.moveMouse(to: self.globalPoint(x: x, y: y))
            }
        }
        server.onMouseDown = { [weak self] button, x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.mouseDown(button: button, at: self.globalPoint(x: x, y: y))
            }
        }
        server.onMouseUp = { [weak self] button, x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.mouseUp(button: button, at: self.globalPoint(x: x, y: y))
            }
        }
        server.onScroll = { [weak self] x, y, deltaX, deltaY in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.scroll(deltaX: Int32(deltaX), deltaY: Int32(deltaY), at: self.globalPoint(x: x, y: y))
            }
        }
        server.onKeyDown = { [weak self] keyCode, modifiers in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.keyDown(keyCode: keyCode, modifiers: modifiers)
            }
        }
        server.onKeyUp = { [weak self] keyCode, modifiers in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.input.keyUp(keyCode: keyCode, modifiers: modifiers)
            }
        }

        // v2 multiplexed streams: the desktop stream starts/stops on demand,
        // per-window streams go through the coordinator.
        server.onWindowStreamStart = { [weak self] windowID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                if windowID == MacNativeStreamProtocol.desktopStreamID {
                    if self.capture == nil {
                        self.startCapture()
                    }
                } else {
                    self.windowStreams.startStream(windowID: windowID)
                }
            }
        }
        server.onWindowStreamStop = { [weak self] windowID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                if windowID == MacNativeStreamProtocol.desktopStreamID {
                    self.stopCapture()
                } else {
                    self.windowStreams.stopStream(windowID: windowID)
                }
            }
        }
        server.onCongestion = { [weak self] windowID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      windowID == MacNativeStreamProtocol.desktopStreamID else { return }
                self.capture?.linkCongested()
            }
        }
        server.onLinkLatency = { [weak self] milliseconds in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.capture?.linkLatency(milliseconds)
                self.updateLatencySummary(linkMilliseconds: milliseconds)
            }
        }
        server.onKeyFrameNeeded = { [weak self] windowID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                if windowID == MacNativeStreamProtocol.desktopStreamID {
                    self.capture?.requestKeyFrame()
                } else {
                    self.windowStreams.requestKeyFrame(windowID: windowID)
                }
            }
        }
        server.onSelectDisplay = { [weak self] displayID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                guard displayID == MacNativeStreamProtocol.virtualDisplayID
                        || self.physicalDisplays.contains(where: { $0.id == displayID }) else { return }
                self.selectedDisplayID = displayID
            }
        }
        server.onFocusWindow = { [weak self] windowID in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      let target = self.windowStreams.target(for: windowID) else { return }
                self.input.raiseWindow(target)
            }
        }
        server.onWindowMouseMove = { [weak self] windowID, x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      let point = self.globalPoint(windowID: windowID, x: x, y: y) else { return }
                self.input.moveMouse(to: point)
            }
        }
        server.onWindowMouseDown = { [weak self] windowID, button, x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      let point = self.globalPoint(windowID: windowID, x: x, y: y) else { return }
                self.raiseIfOccluded(windowID: windowID, at: point)
                self.input.mouseDown(button: button, at: point)
            }
        }
        server.onWindowMouseUp = { [weak self] windowID, button, x, y in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      let point = self.globalPoint(windowID: windowID, x: x, y: y) else { return }
                self.input.mouseUp(button: button, at: point)
            }
        }
        server.onWindowScroll = { [weak self] windowID, x, y, deltaX, deltaY in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation,
                      let point = self.globalPoint(windowID: windowID, x: x, y: y) else { return }
                self.input.scroll(deltaX: Int32(deltaX), deltaY: Int32(deltaY), at: point)
            }
        }

        // Window coordinator → server: inventory pushes and per-window
        // stream data, all tagged with the window ID.
        windowStreams.onInventoryChanged = { [weak self] windows in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.server?.broadcastInventory(windows)
            }
        }
        windowStreams.onWindowFormatDescription = { [weak self] windowID, data in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.server?.broadcastWindowFormatDescription(
                    windowID: windowID,
                    kind: .coreMediaImageDescription,
                    data: data
                )
            }
        }
        windowStreams.onWindowFrame = { [weak self] windowID, data, keyFrame, sequence, timestamp in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.server?.broadcastWindowFrame(
                    windowID: windowID,
                    data,
                    isKeyFrame: keyFrame,
                    sequence: sequence,
                    timestampNanoseconds: timestamp
                )
            }
        }
        windowStreams.onWindowClosed = { [weak self] windowID, reason in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.server?.sendWindowClosed(windowID: windowID, reason: reason)
            }
        }

        do {
            self.server = server
            try server.start()
            server.setMouseAvailability(input.mouseStatusByte)
            server.setKeyboardAvailability(input.keyboardStatusByte)
            refreshDisplays()
        } catch {
            self.server = nil
            lastError = error.localizedDescription
        }
    }

    private func stopServer() {
        serverGeneration += 1
        let oldServer = server
        server = nil
        oldServer?.stop()
        connectedDeviceNames = []
        viewersDecodeHEVC422 = false
        stopCapture()
        stopWindowStreams()
    }

    private func startWindowStreams() {
        guard !windowStreamsRunning else { return }
        windowStreamsRunning = true
        windowStreams.start()
    }

    private func stopWindowStreams() {
        guard windowStreamsRunning else {
            windowStreams.stop()
            return
        }
        windowStreamsRunning = false
        windowStreams.stop()
    }

    /// Restarts a running desktop capture when the viewer set changes what
    /// chroma every one of them can decode. A brief black frame for the
    /// viewers already watching, and the only alternative is sending one of
    /// them a stream it cannot decode at all.
    private func applyDesktopChromaChange() {
        // Never with an empty viewer set: the stream-stop callback that tears
        // the capture down is a separate hop, so restarting here could race it
        // and leave a capture running for nobody.
        guard !connectedDeviceNames.isEmpty else { return }
        let wanted: MacHEVCEncoder.Chroma = viewersDecodeHEVC422 ? .yuv422_10 : .yuv420
        guard capture != nil, wanted != captureChroma else { return }
        stopCapture()
        startCapture()
    }

    private func updateLatencySummary(linkMilliseconds: Double) {
        guard let capture else { return }
        let captureMs = capture.averageCaptureMilliseconds
        let encodeMs = capture.averageEncodeMilliseconds
        latencySummary = String(
            format: "capture %.1f ms · encode %.1f ms · link %.1f ms",
            captureMs, encodeMs, linkMilliseconds
        )
        let now = ContinuousClock.now
        guard now - lastLatencyLog > .seconds(5) else { return }
        lastLatencyLog = now
        log.info("Desktop latency: capture \(captureMs, format: .fixed(precision: 1), privacy: .public) ms, encode \(encodeMs, format: .fixed(precision: 1), privacy: .public) ms, link \(linkMilliseconds, format: .fixed(precision: 1), privacy: .public) ms; \(self.desktopVideoSummary ?? "-", privacy: .public)")
    }

    private func startCapture() {
        captureGeneration += 1
        let generation = captureGeneration
        let chroma: MacHEVCEncoder.Chroma = viewersDecodeHEVC422 ? .yuv422_10 : .yuv420
        captureChroma = chroma

        // The virtual display comes first: it has to exist (and be online)
        // before ScreenCaptureKit can be pointed at it. Not while Mac Virtual
        // Display is connected, though — its exclusive display defers every
        // other display change until the session ends, so ours would neither
        // take over nor go away. The stream then follows the main display,
        // which is Mac VD's, and the pane says why.
        var virtualDisplay: MacNativeVirtualDisplay?
        var skippedReason: String?
        refreshVirtualDisplayConflict()
        if let configuration = virtualDisplayConfiguration {
            if let conflict = virtualDisplayConflict {
                skippedReason = conflict
            } else {
                do {
                    virtualDisplay = try MacNativeVirtualDisplay(configuration: configuration)
                } catch {
                    lastError = error.localizedDescription
                    server?.disconnectDesktopViewers(withError: error.localizedDescription)
                    return
                }
            }
        }
        self.virtualDisplay = virtualDisplay
        if let skippedReason {
            virtualDisplaySummary = "Skipped — \(skippedReason)"
        }

        let physicalTarget = virtualDisplayEnabled
            ? nil
            : MacNativeDisplayCatalog.displayID(forUUID: selectedDisplayID)
        let capture = MacNativeScreenCapture(
            chroma: chroma,
            displayID: virtualDisplay?.displayID ?? physicalTarget,
            bitrateCeiling: bitrateCeiling
        )
        capture.onVideoSummary = { [weak self] summary in
            Task { @MainActor [weak self] in
                guard let self, generation == self.captureGeneration else { return }
                self.desktopVideoSummary = summary
            }
        }
        capture.onFormatDescription = { [weak server] data in
            server?.broadcastFormatDescription(data)
        }
        capture.onFrame = { [weak server] data, keyFrame, sequence, timestamp in
            server?.broadcastFrame(
                data,
                isKeyFrame: keyFrame,
                sequence: sequence,
                timestampNanoseconds: timestamp
            )
        }
        capture.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, generation == self.captureGeneration else { return }
                self.lastError = message
                self.server?.disconnectDesktopViewers(withError: message)
                self.stopCapture()
            }
        }
        capture.onDisplayGeometry = { [weak self] frame, pixelScale in
            Task { @MainActor [weak self] in
                guard let self, generation == self.captureGeneration else { return }
                self.displayFrame = frame
                self.displayPixelScale = pixelScale > 0 ? pixelScale : 1
            }
        }
        capture.canEncode = { [weak server] in server?.desktopCanAcceptFrame() ?? true }
        server?.onDesktopPipeClear = { [weak capture] in capture?.pipeCleared() }
        self.capture = capture

        Task {
            do {
                if let virtualDisplay {
                    try await virtualDisplay.waitUntilOnline()
                    guard generation == captureGeneration else { return }
                    let size = virtualDisplay.configuration.pointSize
                    virtualDisplaySummary = "\(Int(size.width)) × \(Int(size.height)) HiDPI"
                        + (virtualDisplay.configuration.exclusive ? ", Mac displays off" : "")
                }
                try await capture.start()
                guard generation == captureGeneration else {
                    await capture.stop()
                    return
                }
                isCapturing = true
            } catch {
                guard generation == captureGeneration else { return }
                self.capture = nil
                self.virtualDisplay?.invalidate()
                self.virtualDisplay = nil
                virtualDisplaySummary = nil
                isCapturing = false
                lastError = error.localizedDescription
                server?.disconnectDesktopViewers(withError: error.localizedDescription)
            }
        }
    }

    private func stopCapture() {
        captureGeneration += 1
        let capture = self.capture
        self.capture = nil
        isCapturing = false
        desktopVideoSummary = nil
        latencySummary = nil
        // Released after the capture is torn down: pulling the display out
        // from under a running SCStream is an error path, not a stop.
        let virtualDisplay = self.virtualDisplay
        self.virtualDisplay = nil
        virtualDisplaySummary = nil
        Task {
            await capture?.stop()
            virtualDisplay?.invalidate()
        }
    }
}
