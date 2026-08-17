#if MOONLIGHT_ENABLED
import Foundation
import os
import SwiftUI
import AVFoundation
import QuartzCore
@preconcurrency import MoonlightCommonC

/// NSObject proxy for CADisplayLink target (since MoonlightConnectionManager doesn't extend NSObject).
private class DisplayLinkProxy: NSObject {
    var handler: (() -> Void)?
    @objc func displayLinkFired() {
        handler?()
    }
}

/// Live streaming statistics displayed in the stats overlay.
struct StreamStats {
    var videoCodec: String = ""
    var resolution: String = ""
    var configuredFPS: Int = 0
    var actualFPS: Double = 0
    var networkRttMs: UInt32 = 0
    var rttVarianceMs: UInt32 = 0
    var decodeTimeMs: Double = 0
    var totalFrames: UInt64 = 0
    var droppedFrames: UInt64 = 0
}

/// Orchestrates the Moonlight connection lifecycle:
/// server info → pairing → app list → stream launch.
@Observable
class MoonlightConnectionManager: MoonlightStreamDelegate {

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case fetchingServerInfo
        case pairing(pin: String)
        case paired
        case fetchingApps
        case ready
        case launching
        case streaming
        case error(String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.connecting, .connecting),
                 (.fetchingServerInfo, .fetchingServerInfo),
                 (.paired, .paired), (.fetchingApps, .fetchingApps),
                 (.ready, .ready), (.launching, .launching),
                 (.streaming, .streaming):
                return true
            case (.pairing(let a), .pairing(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var connectionState: ConnectionState = .idle
    var serverInfo: ServerInfo?
    var apps: [MoonlightApp] = []
    var statusMessage: String = ""
    /// Touch mode for the active connection (relative trackpad vs absolute positioning).
    var touchMode: TouchMode = .relative
    /// macOS: hide the system pointer while it's over the stream (set from the
    /// connection). Ignored on visionOS.
    var hideLocalCursor: Bool = false
    /// Stream resolution for coordinate mapping in absolute mode.
    var streamWidth: Int = 1920
    var streamHeight: Int = 1080

    /// Whether a physical (Bluetooth/USB) mouse is currently connected. When
    /// true, the stream view suppresses its touch-gesture clicks so the GCMouse
    /// path owns all clicks (avoids visionOS's double-delivery double-clicks).
    var isMouseConnected: Bool = false
    /// Selected display index for multi-display servers.
    var selectedDisplayIndex: Int = 0

    /// Video renderer — exposed so MoonlightStreamView can check streaming state.
    var videoRenderer: MoonlightVideoRenderer?
    /// Display layer for hardware-accelerated video decode and display.
    var displayLayer: AVSampleBufferDisplayLayer?
    /// Live streaming statistics.
    var streamStats = StreamStats()
    /// Whether HDR is active for the current stream (set by server callback).
    var isHDRActive: Bool = false

    private static let spatialAudioEnabledKey = "moonlightSpatialAudioEnabled"

    /// Whether decoded game audio is spatialized (head-tracked) at the
    /// session level, or bypassed (flat passthrough of the stream's own
    /// mix — the default). Persisted; applied live to the running session
    /// via the audio renderer, no reconnect needed.
    var spatialAudioEnabled: Bool = UserDefaults.standard.bool(forKey: MoonlightConnectionManager.spatialAudioEnabledKey) {
        didSet {
            guard spatialAudioEnabled != oldValue else { return }
            UserDefaults.standard.set(spatialAudioEnabled, forKey: Self.spatialAudioEnabledKey)
            audioRenderer?.setSpatialAudioEnabled(spatialAudioEnabled)
        }
    }

    /// Flips spatialization on/off (stream controls bar button).
    func toggleSpatialAudio() {
        spatialAudioEnabled.toggle()
    }

    private var audioRenderer: MoonlightAudioRenderer?
    private var gamepadManager: MoonlightGamepadManager?
    private var mouseManager: MoonlightMouseManager?
    private var keyboardManager: MoonlightKeyboardManager?
    private var isStreamActive = false
    /// Guards against concurrent teardowns (e.g. a manual disconnect racing a
    /// server-initiated termination) issuing overlapping LiStopConnection calls.
    private var isTearingDown = false

    // MARK: - Auto-reconnect state

    /// Last app the user asked to stream — the target for automatic resume
    /// when the stream drops without the user asking (headset doffed, network
    /// blip). Cleared on clean stream end and user-initiated session quit.
    private var lastLaunchedApp: MoonlightApp?
    /// True while an unexpected drop is being retried automatically.
    private(set) var isAutoReconnecting = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30

    // FPS tracking
    private var fpsFrameCount: UInt64 = 0
    private var fpsLastSampleTime: CFTimeInterval = 0

    /// Display link proxy and timer for throttled frame updates.
    private var displayLinkProxy: DisplayLinkProxy?
    private var streamDisplayLink: CADisplayLink?

    private var httpClient: NvHTTPClient?
    private var activeConnection: SavedConnection?
    private let cryptoManager = CryptoManager.shared
    private let pairingManager = NvPairingManager()

    // MARK: - Connection Flow

    /// Begin connecting to a Moonlight/Sunshine server.
    func connect(to connection: SavedConnection) {
        guard connectionState == .idle || isErrorState else { return }

        connectionState = .connecting
        statusMessage = "Connecting to \(connection.hostname)..."
        apps = []
        serverInfo = nil
        activeConnection = connection
        hideLocalCursor = connection.hideLocalCursor

        let hostname = connection.hostname
        let port = UInt16(connection.port)
        let savedServerCert = connection.moonlightServerCert

        Task {
            do {
                let client = NvHTTPClient(hostname: hostname, httpPort: port)
                httpClient = client

                // If we have a saved server cert, configure HTTPS
                if let certDER = savedServerCert {
                    try await client.setServerCert(certDER)
                }

                // Fetch server info
                connectionState = .fetchingServerInfo
                statusMessage = "Fetching server info..."
                let info = try await client.getServerInfo()
                serverInfo = info

                if info.httpsPort != 47984 {
                    await client.updateHttpsPort(info.httpsPort)
                }

                if info.pairStatus {
                    // Already paired — configure HTTPS if not already done
                    if savedServerCert == nil, let uuid = serverInfo?.uuid, !uuid.isEmpty {
                        // Paired but we don't have the cert stored — need to re-pair
                        startPairing(connection: connection)
                        return
                    }

                    connectionState = .paired
                    statusMessage = "Paired with \(info.hostname)"
                    await fetchApps()
                } else {
                    // Need to pair
                    startPairing(connection: connection)
                }
            } catch {
                connectionState = .error(error.localizedDescription)
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    /// Initiate pairing — generates PIN and immediately starts the handshake.
    /// The first pair request blocks on the server until the user enters the PIN,
    /// so we fire it immediately and display the PIN while waiting.
    private func startPairing(connection: SavedConnection) {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        connectionState = .pairing(pin: pin)
        statusMessage = "Enter PIN \(pin) on your server"

        Task {
            do {
                guard let client = httpClient, let info = serverInfo else {
                    connectionState = .error("No server connection")
                    return
                }

                let result = try await pairingManager.pair(with: client, pin: pin, serverInfo: info)

                switch result {
                case .success(let serverCertDER):
                    // Store server cert on the connection
                    connection.moonlightServerCert = serverCertDER
                    connection.moonlightUUID = info.uuid

                    connectionState = .paired
                    statusMessage = "Paired successfully!"
                    await fetchApps()

                case .pinRejected:
                    connectionState = .error("Incorrect PIN. Please try again.")
                    statusMessage = "PIN rejected"

                case .alreadyInProgress:
                    connectionState = .error("Server is already in a pairing session. Cancel the existing pairing on the server and try again.")
                    statusMessage = "Already pairing"

                case .failed(let message):
                    connectionState = .error("Pairing failed: \(message)")
                    statusMessage = "Pairing failed"
                }
            } catch {
                connectionState = .error("Pairing error: \(error.localizedDescription)")
                statusMessage = "Pairing error"
            }
        }
    }

    /// Fetch the app list from the server.
    private func fetchApps() async {
        connectionState = .fetchingApps
        statusMessage = "Fetching apps..."

        do {
            guard let client = httpClient else { return }
            let appList = try await client.getAppList()
            apps = appList.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            connectionState = .ready
            statusMessage = "\(appList.count) app(s) available"
        } catch {
            connectionState = .error("Failed to fetch apps: \(error.localizedDescription)")
            statusMessage = "Failed to fetch apps"
        }
    }

    // MARK: - App Launch

    /// Launch or resume a streaming session for the given app.
    func launchApp(_ app: MoonlightApp) {
        guard let connection = activeConnection,
              let client = httpClient,
              let info = serverInfo else { return }

        // Override resolution/fps from selected display mode if available
        let displayOverride: DisplayMode?
        if selectedDisplayIndex > 0,
           selectedDisplayIndex < info.displayModes.count {
            displayOverride = info.displayModes[selectedDisplayIndex]
        } else {
            displayOverride = nil
        }

        // A fresh launch supersedes any pending automatic retry (but keeps
        // auto-reconnect mode, so a failed retry launch schedules the next one).
        reconnectTask?.cancel()
        reconnectTask = nil
        lastLaunchedApp = app

        connectionState = .launching
        statusMessage = "Launching \(app.name)..."

        Task.detached { [weak self] in
            guard let self else { return }

            do {
                // Generate AES key and key ID for remote input encryption
                let riKey = self.generateRandomBytes(16)
                let riKeyId = Int32(bitPattern: UInt32.random(in: 0...UInt32.max))

                // Determine video format based on server support, connection settings, and HDR
                let enableHDR = connection.moonlightEnableHDR
                let videoFormats = self.resolveVideoFormats(
                    serverCodecModeSupport: Int32(info.serverCodecModeSupport),
                    preference: connection.moonlightVideoCodec,
                    enableHDR: enableHDR
                )

                // Determine audio configuration
                // Values: ((channelMask) << 16) | (channelCount << 8) | 0xCA
                let noAudio = connection.moonlightAudioConfig == .none
                let audioConfig: Int32
                switch connection.moonlightAudioConfig {
                case .surround51: audioConfig = 0x3F06CA  // 5.1
                case .surround71: audioConfig = 0x63F08CA // 7.1
                default: audioConfig = 0x302CA            // stereo (also used for .none — audio stream still negotiated)
                }

                let surroundInfo = surroundAudioInfo(from: audioConfig)

                // A fresh install/user has never touched the spatial toggle —
                // default a surround connection to head-tracked rather than
                // inheriting the flat/off default sized for stereo, since a
                // negotiated 5.1/7.1 mix is the case head-tracking matters
                // most for. Any preference the user has already set (on or
                // off, from any prior connection) is left alone.
                let isSurroundConfig = connection.moonlightAudioConfig == .surround51
                    || connection.moonlightAudioConfig == .surround71
                if isSurroundConfig,
                   UserDefaults.standard.object(forKey: Self.spatialAudioEnabledKey) == nil {
                    self.spatialAudioEnabled = true
                }

                // Use display mode override if selected, otherwise connection settings
                let effectiveWidth = displayOverride?.width ?? connection.moonlightResolutionWidth
                let effectiveHeight = displayOverride?.height ?? connection.moonlightResolutionHeight
                let effectiveFPS = displayOverride?.refreshRate ?? connection.moonlightFPS

                // Launch or resume the app via HTTP
                let launchPath = info.currentGameId == app.id ? "resume"
                    : (info.currentGameId != 0 ? "quit+launch" : "launch")
                AppLog.moonlightStream.line("Launch app=\(app.id) '\(app.name)' path=\(launchPath) currentGameId=\(info.currentGameId) mode=\(effectiveWidth)x\(effectiveHeight)x\(effectiveFPS) bitrate=\(connection.moonlightBitrate) hdr=\(enableHDR) videoFormats=0x\(String(videoFormats, radix: 16))")
                let sessionUrl: String
                if info.currentGameId == app.id {
                    // App already running — resume
                    sessionUrl = try await client.resumeApp(
                        riKey: riKey, riKeyId: riKeyId,
                        surroundAudioInfo: surroundInfo
                    )
                } else if info.currentGameId != 0 {
                    // Different app running — quit it first, then launch
                    try await client.quitApp()
                    sessionUrl = try await client.launchApp(
                        appId: app.id,
                        width: effectiveWidth,
                        height: effectiveHeight,
                        fps: effectiveFPS,
                        bitrate: connection.moonlightBitrate,
                        riKey: riKey, riKeyId: riKeyId,
                        localAudioPlayMode: connection.moonlightPlayAudioOnPC,
                        surroundAudioInfo: surroundInfo,
                        supportedVideoFormats: Int(videoFormats),
                        optimizeGameSettings: connection.moonlightOptimizeGameSettings
                    )
                } else {
                    sessionUrl = try await client.launchApp(
                        appId: app.id,
                        width: effectiveWidth,
                        height: effectiveHeight,
                        fps: effectiveFPS,
                        bitrate: connection.moonlightBitrate,
                        riKey: riKey, riKeyId: riKeyId,
                        localAudioPlayMode: connection.moonlightPlayAudioOnPC,
                        surroundAudioInfo: surroundInfo,
                        supportedVideoFormats: Int(videoFormats),
                        optimizeGameSettings: connection.moonlightOptimizeGameSettings
                    )
                }

                // Create display layer on main thread and renderers
                let layer = await MainActor.run {
                    let l = AVSampleBufferDisplayLayer()
                    l.videoGravity = .resizeAspect
                    return l
                }

                let video = MoonlightVideoRenderer()
                video.displayLayer = layer
                let audio = MoonlightAudioRenderer()
                audio.muted = noAudio
                audio.spatialAudioEnabled = self.spatialAudioEnabled

                // Determine codec name for stats display
                let videoFormat10BitMask: Int32 = 0xAA00 // VIDEO_FORMAT_MASK_10BIT
                let is10Bit = videoFormats & videoFormat10BitMask != 0
                let codecName: String
                if videoFormats & Int32(VIDEO_FORMAT_AV1_MAIN8) != 0 || videoFormats & Int32(VIDEO_FORMAT_AV1_MAIN10) != 0 {
                    codecName = is10Bit ? "AV1 10-bit" : "AV1"
                } else if videoFormats & VIDEO_FORMAT_H265 != 0 || videoFormats & Int32(VIDEO_FORMAT_H265_MAIN10) != 0 {
                    codecName = is10Bit ? "HEVC Main 10" : "HEVC"
                } else {
                    codecName = "H.264"
                }

                await MainActor.run {
                    self.videoRenderer = video
                    self.audioRenderer = audio
                    self.displayLayer = layer
                    self.isStreamActive = true
                    // A Mac has a real pointer — relative "touchpad" mode makes no
                    // sense there, so always use absolute positioning.
                    #if os(macOS)
                    self.touchMode = .absolute
                    #else
                    self.touchMode = connection.moonlightTouchMode
                    #endif
                    self.streamWidth = effectiveWidth
                    self.streamHeight = effectiveHeight
                    self.streamStats = StreamStats(
                        videoCodec: codecName,
                        resolution: "\(effectiveWidth)x\(effectiveHeight)",
                        configuredFPS: effectiveFPS
                    )
                }

                // Determine color space for HDR
                let colorSpace = is10Bit ? COLORSPACE_REC_2020 : COLORSPACE_REC_709
                let colorRange = COLOR_RANGE_LIMITED

                // Build stream config
                let streamConfig = MoonlightStreamConfig(
                    width: Int32(effectiveWidth),
                    height: Int32(effectiveHeight),
                    fps: Int32(effectiveFPS),
                    bitrate: Int32(connection.moonlightBitrate),
                    audioConfiguration: audioConfig,
                    supportedVideoFormats: videoFormats,
                    colorSpace: colorSpace,
                    colorRange: colorRange,
                    serverAddress: connection.hostname,
                    serverAppVersion: info.appVersion,
                    serverGfeVersion: info.gfeVersion,
                    rtspSessionUrl: sessionUrl,
                    serverCodecModeSupport: Int32(info.serverCodecModeSupport),
                    riKey: riKey,
                    riKeyId: riKeyId
                )

                // Start connection (blocks until connected or fails)
                let result = startMoonlightStream(
                    config: streamConfig,
                    videoRenderer: video,
                    audioRenderer: audio,
                    delegate: self
                )

                if result != 0 {
                    await MainActor.run {
                        self.teardownStream {
                            self.connectionState = .error("Failed to start stream (error: \(result))")
                            self.statusMessage = "Stream failed"
                            if self.isAutoReconnecting { self.scheduleReconnect() }
                        }
                    }
                }
            } catch {
                AppLog.moonlightStream.line("Launch failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.connectionState = .error("Launch failed: \(error.localizedDescription)")
                    self.statusMessage = "Launch failed"
                    if self.isAutoReconnecting { self.scheduleReconnect() }
                }
            }
        }
    }

    /// Stop the active streaming session.
    func stopStreaming() {
        cancelReconnect()
        teardownStream {
            self.connectionState = .ready
            self.statusMessage = "Disconnected from stream"
        }
    }

    /// Fully tear the active session down: `LiStopConnection()` on a background
    /// thread (it must not run on the connection's callback thread or block the
    /// main thread), then release Swift-side resources and apply the final UI
    /// state. Guarded so it runs exactly once regardless of which path triggers
    /// it (manual disconnect, server termination, or stage failure) — concurrent
    /// LiStopConnection calls would race on moonlight-common-c's internal state.
    private func teardownStream(quitOnServer: Bool = false, _ applyFinalState: @escaping @MainActor () -> Void) {
        guard isStreamActive, !isTearingDown else {
            applyFinalState()
            return
        }
        isTearingDown = true
        let client = quitOnServer ? httpClient : nil
        Task.detached {
            stopMoonlightStream()
            if quitOnServer { try? await client?.quitApp() }
            await MainActor.run {
                self.cleanupStream()       // sets isStreamActive = false
                self.isTearingDown = false
                applyFinalState()
            }
        }
    }

    private func cleanupStream() {
        stopDisplayLink()
        gamepadManager?.stopListening()
        gamepadManager = nil
        activeGamepadManager = nil
        mouseManager?.stopListening()
        mouseManager = nil
        isMouseConnected = false
        keyboardManager?.stopListening()
        keyboardManager = nil
        displayLayer?.flush()
        displayLayer = nil
        videoRenderer?.displayLayer = nil
        videoRenderer = nil
        audioRenderer = nil
        isStreamActive = false
        isHDRActive = false
        // Reset FPS tracking so the next session doesn't underflow
        fpsFrameCount = 0
        fpsLastSampleTime = 0
    }

    private func startGamepadManager() {
        let swapABXY = activeConnection?.moonlightSwapABXY ?? false
        let manager = MoonlightGamepadManager(swapABXY: swapABXY)
        gamepadManager = manager
        activeGamepadManager = manager
        manager.startListening()
    }

    private func startMouseManager() {
        let manager = MoonlightMouseManager(relativeMotionEnabled: touchMode == .relative)
        manager.onConnectedChange = { [weak self] connected in
            self?.isMouseConnected = connected
        }
        mouseManager = manager
        manager.startListening() // fires onConnectedChange for any already-connected mouse
    }

    private func startKeyboardManager() {
        let manager = MoonlightKeyboardManager()
        keyboardManager = manager
        manager.startListening()
    }

    /// Switch the active touch/pointer mode. Keeps the `GCMouse` bridge in sync
    /// so raw motion deltas are only forwarded in relative mode (absolute mode
    /// drives the pointer from the view's hover position events instead).
    func setTouchMode(_ mode: TouchMode) {
        touchMode = mode
        mouseManager?.relativeMotionEnabled = (mode == .relative)
    }

    /// Tell the `GCMouse` bridge whether the pointer is over the stream content,
    /// so physical clicks on the app's own controls aren't sent to the remote.
    func setPointerOverContent(_ over: Bool) {
        mouseManager?.pointerOverContent = over
    }

    private func startDisplayLink() {
        let proxy = DisplayLinkProxy()
        proxy.handler = { [weak self] in
            self?.updateStreamFrame()
        }
        displayLinkProxy = proxy
        guard let link = DisplayLinkFactory.make(target: proxy, selector: #selector(DisplayLinkProxy.displayLinkFired)) else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        streamDisplayLink = link
    }

    private func stopDisplayLink() {
        streamDisplayLink?.invalidate()
        streamDisplayLink = nil
        displayLinkProxy = nil
    }

    private nonisolated(unsafe) var displayLinkLogCount = 0
    private func updateStreamFrame() {
        guard let renderer = videoRenderer else {
            if displayLinkLogCount < 3 {
                AppLog.moonlightStream.line("Display link: no videoRenderer")
                displayLinkLogCount += 1
            }
            return
        }

        // Update stats periodically (display layer handles rendering directly)
        updateStats(renderer: renderer)
    }

    private func updateStats(renderer: MoonlightVideoRenderer) {
        let now = CACurrentMediaTime()

        // Compute actual FPS every second
        let currentFrameCount = renderer.frameCount
        if fpsLastSampleTime == 0 {
            fpsLastSampleTime = now
            fpsFrameCount = currentFrameCount
        } else {
            let elapsed = now - fpsLastSampleTime
            if elapsed >= 1.0 {
                // Use Int64 to avoid unsigned underflow if frame counter was reset
                let frames = Int64(currentFrameCount) - Int64(fpsFrameCount)
                streamStats.actualFPS = frames > 0 ? Double(frames) / elapsed : 0
                fpsLastSampleTime = now
                fpsFrameCount = currentFrameCount
            }
        }

        // Update decode time and frame counts
        streamStats.decodeTimeMs = renderer.lastDecodeTimeMs
        streamStats.totalFrames = currentFrameCount
        streamStats.droppedFrames = renderer.droppedFrames

        // Update network RTT
        var rtt: UInt32 = 0
        var rttVariance: UInt32 = 0
        if LiGetEstimatedRttInfo(&rtt, &rttVariance) {
            streamStats.networkRttMs = rtt
            streamStats.rttVarianceMs = rttVariance
        }
    }

    // MARK: - MoonlightStreamDelegate

    nonisolated func moonlightStreamStageStarting(_ stage: Int32) {
        let name = String(cString: LiGetStageName(stage))
        Task { @MainActor in
            self.statusMessage = "Starting \(name)..."
        }
    }

    nonisolated func moonlightStreamStageComplete(_ stage: Int32) {}

    nonisolated func moonlightStreamStageFailed(_ stage: Int32, errorCode: Int32) {
        let name = String(cString: LiGetStageName(stage))
        Task { @MainActor in
            self.teardownStream {
                self.connectionState = .error("Stage '\(name)' failed (error: \(errorCode))")
                self.statusMessage = "Stream setup failed"
            }
        }
    }

    nonisolated func moonlightStreamConnectionStarted() {
        Task { @MainActor in
            self.connectionState = .streaming
            self.statusMessage = "Streaming"
            self.isAutoReconnecting = false
            self.reconnectDelay = 2
            self.startDisplayLink()
            self.startGamepadManager()
            self.startMouseManager()
            self.startKeyboardManager()
        }
    }

    nonisolated func moonlightStreamConnectionTerminated(_ errorCode: Int32) {
        Task { @MainActor in
            // A server-initiated termination (e.g. wifi dropout) must still call
            // LiStopConnection to join the internal threads and reset moonlight's
            // static state — otherwise the next session corrupts/crashes. Route
            // through the guarded teardown (off-main, since LiStopConnection
            // blocks and must not run on the callback thread).
            self.teardownStream {
                if errorCode == 0 {
                    self.connectionState = .ready
                    self.statusMessage = "Stream ended"
                    self.lastLaunchedApp = nil
                } else {
                    // Unexpected drop (headset doffed, network blip, host
                    // hiccup). The host session was not quit, so auto-resume
                    // instead of parking in a dead-end error state — the
                    // retry hits the resumeApp path while currentGameId is
                    // still set on the server.
                    self.connectionState = .error("Stream terminated (error: \(errorCode))")
                    self.statusMessage = "Stream lost — reconnecting"
                    self.scheduleReconnect()
                }
            }
        }
    }

    nonisolated func moonlightStreamConnectionStatusUpdate(_ status: Int32) {
        // Could update UI with connection quality indicators
    }

    nonisolated func moonlightStreamSetHdrMode(_ enabled: Bool) {
        Task { @MainActor in self.isHDRActive = enabled }
    }

    // MARK: - Helpers

    private nonisolated func generateRandomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    /// Determine supported video formats based on server capabilities, user preference, and HDR.
    private nonisolated func resolveVideoFormats(serverCodecModeSupport: Int32, preference: VideoCodecPreference, enableHDR: Bool) -> Int32 {
        switch preference {
        case .h264:
            if enableHDR {
                // H.264 doesn't support HDR — auto-upgrade to HEVC Main 10 if available
                if serverCodecModeSupport & Int32(SCM_HEVC_MAIN10) != 0 {
                    return VIDEO_FORMAT_H265 | Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
            return VIDEO_FORMAT_H264
        case .hevc:
            if serverCodecModeSupport & Int32(SCM_HEVC) != 0 {
                var formats = VIDEO_FORMAT_H265
                if enableHDR && serverCodecModeSupport & Int32(SCM_HEVC_MAIN10) != 0 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
                return formats
            }
            return VIDEO_FORMAT_H264
        case .av1:
            if serverCodecModeSupport & Int32(SCM_AV1_MAIN8) != 0 {
                var formats = Int32(VIDEO_FORMAT_AV1_MAIN8)
                if enableHDR && serverCodecModeSupport & Int32(SCM_AV1_MAIN10) != 0 {
                    formats |= Int32(VIDEO_FORMAT_AV1_MAIN10)
                }
                return formats
            }
            return VIDEO_FORMAT_H264
        case .auto:
            var formats = VIDEO_FORMAT_H264
            // Prefer AV1 > HEVC > H.264
            if serverCodecModeSupport & Int32(SCM_AV1_MAIN8) != 0 {
                formats |= Int32(VIDEO_FORMAT_AV1_MAIN8)
                if enableHDR && serverCodecModeSupport & Int32(SCM_AV1_MAIN10) != 0 {
                    formats |= Int32(VIDEO_FORMAT_AV1_MAIN10)
                }
            }
            if serverCodecModeSupport & Int32(SCM_HEVC) != 0 {
                formats |= VIDEO_FORMAT_H265
                if enableHDR && serverCodecModeSupport & Int32(SCM_HEVC_MAIN10) != 0 {
                    formats |= Int32(VIDEO_FORMAT_H265_MAIN10)
                }
            }
            return formats
        }
    }

    /// Quit the currently running app on the server (ends the session).
    func quitServerSession() {
        guard let client = httpClient else { return }
        Task {
            do {
                try await client.quitApp()
                // Refresh server info to update currentGameId
                if let info = try? await client.getServerInfo() {
                    serverInfo = info
                }
                statusMessage = "Session ended on server"
            } catch {
                statusMessage = "Failed to quit: \(error.localizedDescription)"
            }
        }
    }

    /// Stop the local stream AND quit the app on the server.
    func stopStreamingAndQuit() {
        cancelReconnect()
        lastLaunchedApp = nil
        teardownStream(quitOnServer: true) {
            self.connectionState = .ready
            self.statusMessage = "Session ended"
        }
    }

    /// Disconnect and reset state.
    func disconnect() {
        cancelReconnect()
        lastLaunchedApp = nil
        if isStreamActive {
            stopStreaming()
        }
        httpClient = nil
        activeConnection = nil
        connectionState = .idle
        serverInfo = nil
        apps = []
        statusMessage = ""
    }

    // MARK: - Auto-reconnect

    /// Whether a dropped stream can be resumed (there is a remembered app and
    /// no stream is active) — drives the Reconnect button in the stream view.
    var canReconnect: Bool {
        lastLaunchedApp != nil && !isStreamActive && !isTearingDown
    }

    /// Cancel any pending automatic reconnect and leave auto-reconnect mode.
    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isAutoReconnecting = false
        reconnectDelay = 2
    }

    /// Schedule the next automatic reconnect attempt with exponential backoff.
    private func scheduleReconnect() {
        guard lastLaunchedApp != nil else { return }
        isAutoReconnecting = true
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
        AppLog.moonlightStream.line("Reconnecting in \(Int(delay)) s")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    /// Try to resume the dropped session. Refreshes server info first so
    /// `launchApp` takes the resumeApp path when the host session is still
    /// alive (an unexpected drop never quits the app on the server).
    private func attemptReconnect() async {
        guard let app = lastLaunchedApp, let client = httpClient else { return }
        guard connectionState != .streaming, connectionState != .launching else { return }
        if isStreamActive || isTearingDown {
            // Teardown still in flight — try again after the next backoff.
            scheduleReconnect()
            return
        }
        statusMessage = "Reconnecting to \(app.name)..."
        do {
            serverInfo = try await client.getServerInfo()
            launchApp(app)
        } catch {
            AppLog.moonlightStream.line("Reconnect failed: \(error.localizedDescription)")
            connectionState = .error("Reconnect failed: \(error.localizedDescription)")
            statusMessage = "Reconnect failed"
            scheduleReconnect()
        }
    }

    /// Retry immediately, resetting backoff. Wired to the stream window
    /// returning to the foreground (headset donned) and the Reconnect button.
    func reconnectNow() {
        guard canReconnect else { return }
        reconnectDelay = 2
        isAutoReconnecting = true
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.attemptReconnect()
        }
    }

    /// Scene became active (headset donned / window refocused): if an
    /// automatic reconnect is pending, don't wait out the backoff timer.
    func sceneBecameActive() {
        guard isAutoReconnecting else { return }
        reconnectNow()
    }

    /// Retry connection after an error.
    func retry(connection: SavedConnection) {
        disconnect()
        connect(to: connection)
    }

    private var isErrorState: Bool {
        if case .error = connectionState { return true }
        return false
    }
}
#endif
