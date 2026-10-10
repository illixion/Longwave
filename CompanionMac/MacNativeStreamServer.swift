import DebugTrace
import Foundation
import CoreVideo
import Network

/// Authenticated multi-viewer server for the native Mac stream. Every client
/// that completes TLS and sends its hello joins the set of viewers; an
/// unauthenticated socket sees nothing and can inject nothing.
///
/// This used to be newest-client-wins — a second viewer replaced the first,
/// which meant picking up the iPhone ended the session on the headset. Nothing
/// about the stream is single-viewer: one capture and one encode fan out to
/// however many sockets are subscribed, so the cost of the second viewer is
/// the bytes on the wire. What *is* shared is the pointer and the keyboard,
/// and that is by design — every viewer is the same authenticated user driving
/// the same Mac.
final class MacNativeStreamServer: @unchecked Sendable {
    /// One connected viewer, as the controller needs to see it.
    struct ClientSummary: Sendable {
        let deviceName: String
        let protocolVersion: Int
        let decodesHEVC422: Bool

        var isV2: Bool { protocolVersion >= 2 }
    }

    /// A viewer proved which paired device it is (nil: the shared token).
    nonisolated(unsafe) var onDeviceIdentified: (@Sendable (String?) -> Void)?
    /// A viewer finished its handshake — for the "connected" notification.
    nonisolated(unsafe) var onClientConnected:
        (@Sendable (_ deviceName: String, _ wantsScreen: Bool) -> Void)?
    /// The viewer set changed (someone joined or left) — for status text and
    /// for the chroma decision, which depends on what *every* viewer decodes.
    nonisolated(unsafe) var onClientsChanged: (@Sendable (_ clients: [ClientSummary]) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    // Remote control — fired for any promoted client. They all drive the same
    // cursor, which is what sharing a desktop means.
    nonisolated(unsafe) var onMouseMove: (@Sendable (UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onMouseDown: (@Sendable (MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onMouseUp: (@Sendable (MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onScroll: (@Sendable (UInt16, UInt16, Int16, Int16) -> Void)?
    nonisolated(unsafe) var onKeyDown: (@Sendable (UInt16, MacNativeKeyModifiers) -> Void)?
    nonisolated(unsafe) var onKeyUp: (@Sendable (UInt16, MacNativeKeyModifiers) -> Void)?

    // v2 multiplexed streams — `windowID == desktopStreamID` means the
    // whole-desktop stream; anything else is a per-window stream.
    nonisolated(unsafe) var onWindowStreamStart: (@Sendable (UInt32) -> Void)?
    nonisolated(unsafe) var onWindowStreamStop: (@Sendable (UInt32) -> Void)?
    /// A viewer joined a stream that is already running, so the encoder is
    /// mid-GOP and nothing it sends will decode until the next key frame.
    nonisolated(unsafe) var onKeyFrameNeeded: (@Sendable (UInt32) -> Void)?
    /// A viewer's link fell behind and a frame of this stream was dropped —
    /// the encoder should spend fewer bits until it stops happening.
    nonisolated(unsafe) var onCongestion: (@Sendable (UInt32) -> Void)?
    /// The desktop stream's pipe to every acking viewer has room again — a
    /// frame the capture held back can be encoded now.
    nonisolated(unsafe) var onDesktopPipeClear: (@Sendable () -> Void)?
    /// Smoothed send→ack time of the slowest acking viewer, in ms, at most
    /// twice a second. Transmission of the frame plus the network round trip.
    nonisolated(unsafe) var onLinkLatency: (@Sendable (Double) -> Void)?
    nonisolated(unsafe) var onFocusWindow: (@Sendable (UInt32) -> Void)?
    /// A viewer picked a desktop from `displayList` (a `DisplayInfo.id`).
    nonisolated(unsafe) var onSelectDisplay: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onConfigureVirtualDisplay:
        (@Sendable (MacNativeStreamProtocol.VirtualDisplayChange) -> Void)?
    nonisolated(unsafe) var onWindowMouseMove: (@Sendable (UInt32, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowMouseDown:
        (@Sendable (UInt32, MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowMouseUp:
        (@Sendable (UInt32, MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowScroll: (@Sendable (UInt32, UInt16, UInt16, Int16, Int16) -> Void)?

    private nonisolated static let maxPendingBytes = 12 * 1024 * 1024
    /// Video frames handed to the connection but not yet taken by the network
    /// stack, across all of a viewer's streams. A remote desktop is only as
    /// live as the oldest frame still queued for it, so the queue is kept to a
    /// couple of frames and anything beyond is dropped — 12 MB of backlog was
    /// seconds of video at these bitrates before the first drop.
    private nonisolated static let maxInFlightFrames = 3
    /// Desktop frames sent to an acking viewer and not yet acknowledged.
    /// Past this the capture holds the newest frame back instead of encoding
    /// it — nothing queues, and nothing has to be dropped (which would cost a
    /// key frame). Two keeps the link busy across one round trip.
    private nonisolated static let maxUnackedFrames = 2
    /// An unacknowledged frame older than this is presumed lost, so a stalled
    /// viewer cannot hold the gate shut forever.
    private nonisolated static let unackedTimeoutNanos: UInt64 = 300_000_000

    /// Read from the capture's output queue, written on `queue`.
    private let gateLock = NSLock()
    private nonisolated(unsafe) var desktopGateOpenStorage = true
    private nonisolated(unsafe) var lastLinkReport: UInt64 = 0

    private nonisolated final class Client: @unchecked Sendable {
        let connection: NWConnection
        var inbound = Data()
        var deviceName: String?
        /// The enrolled device this viewer proved it is (inner nil: the
        /// deprecated shared token), and what it may do.
        var deviceID: String??
        var grants: Set<CompanionGrant> = []
        var protocolVersion = 1
        var pendingBytes = 0
        var inFlightFrames = 0
        var acksFrames = false
        /// Desktop sequence → send time (uptime ns), for acking viewers.
        var unackedDesktop: [UInt64: UInt64] = [:]
        var linkLatencyMs: Double = 0
        /// Streams this viewer dropped a frame of, for which a key frame has
        /// been asked of the encoder already.
        var keyFrameRequested: Set<UInt32> = []
        /// True once the hello landed and this client joined the viewer set.
        var isActive = false
        /// v1 has no subscriptions: it takes the desktop stream unless its
        /// hello said otherwise.
        var wantsDesktopV1 = true
        var decodesHEVC422 = false
        /// A viewer that cannot decode video and takes JPEG stills of
        /// `stillViewport` instead (Apple Watch). It never subscribes to the
        /// HEVC desktop stream, but its presence keeps the capture running.
        var isStill = false
        var stillViewport = MacNativeStreamProtocol.StillViewport.full
        /// Something changed (a new frame, a new viewport) since the last still.
        var stillDirty = false
        var stillSequence: UInt64 = 0
        /// Uptime ns when the unacknowledged still went out; nil when none is.
        var stillSentAt: UInt64?
        var lastStillAt: UInt64 = 0
        /// Per stream ID; the v1 desktop stream uses `desktopStreamID`.
        var awaitingKeyFrame: [UInt32: Bool] = [MacNativeStreamProtocol.desktopStreamID: true]
        /// v2 stream subscriptions. A v1 client is implicitly subscribed to
        /// the desktop stream.
        var subscriptions: Set<UInt32> = []

        var isV2: Bool { protocolVersion >= 2 }

        func wantsStream(_ windowID: UInt32) -> Bool {
            if isStill { return false }
            if isV2 {
                return subscriptions.contains(windowID)
            }
            return windowID == MacNativeStreamProtocol.desktopStreamID && wantsDesktopV1
        }

        var summary: ClientSummary {
            ClientSummary(
                deviceName: deviceName ?? "Unknown",
                protocolVersion: protocolVersion,
                decodesHEVC422: decodesHEVC422
            )
        }

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let port: UInt16
    /// Every enrolled device's key; read when a listener is built and when a
    /// viewer identifies itself.
    private let keyring: CompanionKeyring
    private let queue = DispatchQueue(
        label: "pro.longwave.companion.mac-native.server",
        qos: .userInteractive
    )
    private let log = DebugLogger(
        subsystem: "pro.longwave.companion",
        category: "MacNativeStreamServer"
    )

    private nonisolated(unsafe) var listener: NWListener?
    /// Every viewer past its handshake, in the order they joined.
    private nonisolated(unsafe) var clients: [Client] = []
    /// Sockets that have completed TLS but not yet said hello. They receive
    /// nothing and may inject nothing.
    private nonisolated(unsafe) var pendingClients: [Client] = []
    /// The desktop stream's raw format-description blob — kept raw so it can
    /// be re-framed for either a v1 (legacy frame) or v2 (multiplexed frame)
    /// client at promotion time.
    private nonisolated(unsafe) var currentDesktopFormat: Data?
    /// The current window inventory, pre-encoded — sent to v2 clients on
    /// promotion and on change.
    private nonisolated(unsafe) var currentInventoryFrame: Data?
    /// The current display choice, pre-encoded — same lifecycle as the
    /// inventory frame.
    private nonisolated(unsafe) var currentDisplayListFrame: Data?
    /// Per-window format blobs, kept for the same reason as the desktop's: a
    /// viewer that subscribes to a stream another viewer already started gets
    /// no fresh format frame from the capture side, so it needs the cached one
    /// before the next key frame means anything.
    private nonisolated(unsafe) var currentWindowFormats: [UInt32: Data] = [:]
    private nonisolated(unsafe) var mouseAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var keyboardAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var stoppingListener: NWListener?
    /// The newest captured desktop frame, kept for still viewers: the screen
    /// only produces frames when it changes, but a viewport change must be
    /// answered from the picture already there.
    private nonisolated(unsafe) var lastStillBuffer: CVPixelBuffer?
    private let stillEncoder = MacNativeStillEncoder()
    private let stillQueue = DispatchQueue(label: "pro.longwave.companion.mac-native.stills", qos: .userInteractive)
    private nonisolated(unsafe) var stillRetryScheduled = false
    /// Whether any viewer takes the HEVC desktop stream — read from the
    /// capture's queue to skip encoding for a Mac that only has still viewers.
    private let videoViewerLock = NSLock()
    private nonisolated(unsafe) var videoViewerStorage = false
    /// Fastest rate a still viewer is sent pictures at.
    private static let minStillIntervalNanos: UInt64 = 80_000_000
    private static let stillLossTimeoutNanos: UInt64 = 1_500_000_000
    private nonisolated(unsafe) var stopCompletion: (@Sendable () -> Void)?

    nonisolated init(port: UInt16, keyring: CompanionKeyring) {
        self.port = port
        self.keyring = keyring
    }

    nonisolated func start() throws {
        let listener = try makeListener()
        self.listener = listener
        listener.start(queue: queue)
    }

    /// A listener holds its PSKs for life, so a device enrolled or revoked
    /// needs a new one. Viewers already connected keep their connections —
    /// those still enrolled with the same grants stay, the rest are told why
    /// and dropped. The port is rebound right after the old listener goes, so
    /// only a connection attempt in that instant can miss.
    nonisolated func reloadCredentials() {
        queue.async { [self] in
            for client in clients where client.isActive {
                guard let deviceID = client.deviceID,
                      let entry = keyring.entry(deviceID: deviceID),
                      entry.grants == client.grants else {
                    sendError("This device's access to this Mac changed. Connect again.", to: client)
                    continue
                }
            }
            guard let old = listener else { return }
            old.stateUpdateHandler = nil
            old.newConnectionHandler = nil
            old.cancel()
            listener = nil
            rebind(attempt: 0)
        }
    }

    private nonisolated func rebind(attempt: Int) {
        do {
            let listener = try makeListener()
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            guard attempt < 20 else {
                onError?("Native stream listener couldn't restart: \(error.localizedDescription)")
                return
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                guard listener == nil, stopCompletion == nil else { return }
                rebind(attempt: attempt + 1)
            }
        }
    }

    private nonisolated func makeListener() throws -> NWListener {
        let parameters = MacNativeStreamCrypto.tlsTCPParameters(credentials: keyring.credentials)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "Longwave Mac",
            type: "_longwave-native._tcp"
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.onError?("Native stream listener failed: \(error.localizedDescription)")
                self?.finishStop()
            case .cancelled:
                self?.finishStop()
            default:
                break
            }
        }
        return listener
    }

    nonisolated func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            stopCompletion = completion
            guard let listener else {
                finishStop()
                return
            }
            stoppingListener = listener
            listener.cancel()
            self.listener = nil
            for client in clients + pendingClients {
                client.connection.cancel()
            }
            clients = []
            pendingClients = []
            currentDesktopFormat = nil
            currentInventoryFrame = nil
            currentDisplayListFrame = nil
            currentWindowFormats = [:]
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                guard stopCompletion != nil else { return }
                finishStop()
            }
        }
    }

    /// Publishes a new mouse `RemoteControlStatus` byte (toggle flipped /
    /// Accessibility changed): cached for the next promotion, and pushed to a
    /// live client.
    nonisolated func setMouseAvailability(_ status: UInt8) {
        queue.async { [self] in
            mouseAvailability = status
            for client in clients {
                sendRequired(MacNativeStreamProtocol.encodeFrame(.mouseStatus, Data([inputStatus(status, for: client)])), to: client)
            }
        }
    }

    /// Same as `setMouseAvailability`, for keyboard *shortcuts* (full keycode
    /// + modifiers) — independent of mouse and of plain text-only typing.
    nonisolated func setKeyboardAvailability(_ status: UInt8) {
        queue.async { [self] in
            keyboardAvailability = status
            for client in clients {
                sendRequired(MacNativeStreamProtocol.encodeFrame(.keyboardStatus, Data([inputStatus(status, for: client)])), to: client)
            }
        }
    }

    /// A viewer without the input grant sees remote control as switched off.
    private nonisolated func inputStatus(_ status: UInt8, for client: Client) -> UInt8 {
        client.grants.contains(.input) ? status : MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    }

    /// Ends the session of every viewer watching the *desktop* stream, with
    /// the same error — the desktop capture died, so there is nothing left to
    /// show them.
    ///
    /// Scoped rather than "everyone": with several viewers, one of them may be
    /// watching only per-window streams (or be connected for audio and input
    /// alone), and those are unaffected by the desktop capture failing.
    nonisolated func disconnectDesktopViewers(withError message: String) {
        queue.async { [self] in
            let leaving = clients.filter {
                $0.wantsStream(MacNativeStreamProtocol.desktopStreamID)
            }
            guard !leaving.isEmpty else { return }
            clients.removeAll { client in leaving.contains { $0 === client } }
            updateDesktopGate()
            for client in leaving {
                client.isActive = false
                sendError(message, to: client)
            }
            // Stop only what no remaining viewer still wants.
            for streamID in Set(leaving.flatMap(\.subscriptions))
                .union([MacNativeStreamProtocol.desktopStreamID])
            where subscriberCount(streamID) == 0 {
                onWindowStreamStop?(streamID)
            }
            onClientsChanged?(clients.map(\.summary))
        }
    }

    /// Desktop-stream format description (raw CoreMedia blob) — framed as the
    /// legacy `formatDescription` for a v1 client or as a multiplexed
    /// `windowFormatDescription` for a v2 desktop subscriber.
    nonisolated func broadcastFormatDescription(_ data: Data) {
        queue.async { [self] in
            currentDesktopFormat = data
            for client in clients
            where client.wantsStream(MacNativeStreamProtocol.desktopStreamID) {
                client.awaitingKeyFrame[MacNativeStreamProtocol.desktopStreamID] = true
                sendRequired(Self.desktopFormatFrame(data, for: client), to: client)
            }
        }
    }

    private nonisolated static func desktopFormatFrame(_ data: Data, for client: Client) -> Data {
        if client.isV2 {
            return MacNativeStreamProtocol.encodeWindowFormatDescription(
                windowID: MacNativeStreamProtocol.desktopStreamID,
                kind: .coreMediaImageDescription,
                data: data
            )
        }
        return MacNativeStreamProtocol.encodeFrame(.formatDescription, data)
    }

    nonisolated func broadcastFrame(
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) {
        queue.async { [self] in
            guard !clients.isEmpty else { return }
            // Two framings of one encoded frame, built at most once each: the
            // viewers can be a mix of protocol versions.
            var v1Frame: Data?
            var v2Frame: Data?
            for client in clients {
                let frame: Data
                if client.isV2 {
                    if v2Frame == nil {
                        v2Frame = MacNativeStreamProtocol.encodeWindowVideoFrame(
                            windowID: MacNativeStreamProtocol.desktopStreamID,
                            data,
                            isKeyFrame: isKeyFrame,
                            sequence: sequence,
                            timestampNanoseconds: timestampNanoseconds
                        )
                    }
                    frame = v2Frame!
                } else {
                    if v1Frame == nil {
                        v1Frame = MacNativeStreamProtocol.encodeVideoFrame(
                            data,
                            isKeyFrame: isKeyFrame,
                            sequence: sequence,
                            timestampNanoseconds: timestampNanoseconds
                        )
                    }
                    frame = v1Frame!
                }
                deliver(
                    frame,
                    streamID: MacNativeStreamProtocol.desktopStreamID,
                    isKeyFrame: isKeyFrame,
                    sequence: sequence,
                    to: client
                )
            }
        }
    }

    // MARK: - v2 multiplexed streams

    /// Publishes a new window inventory: cached for the next promotion and
    /// pushed to a live v2 client.
    nonisolated func broadcastInventory(_ windows: [MacNativeStreamProtocol.WindowInfo]) {
        let frame = MacNativeStreamProtocol.encodeWindowInventory(windows)
        queue.async { [self] in
            currentInventoryFrame = frame
            for client in clients where client.isV2 {
                sendRequired(frame, to: client)
            }
        }
    }

    /// Publishes which desktops the stream can show and which it shows:
    /// cached for the next promotion and pushed to every live v2 client.
    nonisolated func broadcastDisplayList(_ list: MacNativeStreamProtocol.DisplayList) {
        let frame = MacNativeStreamProtocol.encodeDisplayList(list)
        queue.async { [self] in
            guard frame != currentDisplayListFrame else { return }
            currentDisplayListFrame = frame
            for client in clients where client.isV2 {
                sendRequired(frame, to: client)
            }
        }
    }

    nonisolated func broadcastWindowFormatDescription(
        windowID: UInt32,
        kind: MacNativeStreamProtocol.FormatKind,
        data: Data
    ) {
        let frame = MacNativeStreamProtocol.encodeWindowFormatDescription(
            windowID: windowID,
            kind: kind,
            data: data
        )
        queue.async { [self] in
            currentWindowFormats[windowID] = data
            for client in clients where client.wantsStream(windowID) {
                client.awaitingKeyFrame[windowID] = true
                sendRequired(frame, to: client)
            }
        }
    }

    nonisolated func broadcastWindowFrame(
        windowID: UInt32,
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) {
        let frame = MacNativeStreamProtocol.encodeWindowVideoFrame(
            windowID: windowID,
            data,
            isKeyFrame: isKeyFrame,
            sequence: sequence,
            timestampNanoseconds: timestampNanoseconds
        )
        queue.async { [self] in
            for client in clients {
                deliver(frame, streamID: windowID, isKeyFrame: isKeyFrame, sequence: sequence, to: client)
            }
        }
    }

    /// Tells the active v2 client a stream ended (window closed, capture
    /// failed, budget exceeded) and forgets its subscription.
    nonisolated func sendWindowClosed(windowID: UInt32, reason: String?) {
        queue.async { [self] in
            currentWindowFormats[windowID] = nil
            let frame = MacNativeStreamProtocol.encodeWindowClosed(windowID: windowID, reason: reason)
            for client in clients where client.isV2 {
                client.subscriptions.remove(windowID)
                client.awaitingKeyFrame[windowID] = nil
                sendRequired(frame, to: client)
            }
        }
    }

    /// Video delivery shared by the desktop and window streams: subscription
    /// check, per-stream first-key-frame gating, and connection-wide
    /// backpressure (drop when the client is too far behind).
    private nonisolated func deliver(
        _ frame: Data,
        streamID: UInt32,
        isKeyFrame: Bool,
        sequence: UInt64,
        to client: Client
    ) {
        guard client.wantsStream(streamID) else { return }
        guard client.pendingBytes < Self.maxPendingBytes,
              client.inFlightFrames < Self.maxInFlightFrames else {
            // Every frame after this one predicts from it, so dropping it
            // means waiting for a key frame — otherwise the viewer decodes
            // smeared garbage until the next scheduled one.
            client.awaitingKeyFrame[streamID] = true
            onCongestion?(streamID)
            return
        }
        if client.awaitingKeyFrame[streamID] ?? true {
            guard isKeyFrame else {
                // Ask once per gap, and only once the queue has room again —
                // a key frame sent into a full queue would just be dropped.
                if client.keyFrameRequested.insert(streamID).inserted {
                    onKeyFrameNeeded?(streamID)
                }
                return
            }
            client.awaitingKeyFrame[streamID] = false
            client.keyFrameRequested.remove(streamID)
        }
        client.pendingBytes += frame.count
        client.inFlightFrames += 1
        if client.acksFrames, streamID == MacNativeStreamProtocol.desktopStreamID {
            client.unackedDesktop[sequence] = DispatchTime.now().uptimeNanoseconds
            updateDesktopGate()
        }
        client.connection.send(content: frame, completion: .contentProcessed {
            [weak self, weak client] error in
            self?.queue.async {
                client?.pendingBytes = max(0, (client?.pendingBytes ?? 0) - frame.count)
                client?.inFlightFrames = max(0, (client?.inFlightFrames ?? 0) - 1)
                if let error {
                    self?.log.error("Video send failed: \(error.localizedDescription)")
                }
            }
        })
    }

    // MARK: - Stills

    nonisolated func hasVideoViewers() -> Bool {
        videoViewerLock.lock()
        defer { videoViewerLock.unlock() }
        return videoViewerStorage
    }

    /// Whether a Native-stream (fast-lane) still viewer is connected.
    nonisolated func hasDesktopStillViewers() -> Bool {
        queue.sync { clients.contains(where: \.isStill) }
    }

    private nonisolated func refreshVideoViewerFlag() {
        let any = clients.contains { $0.wantsStream(MacNativeStreamProtocol.desktopStreamID) }
        videoViewerLock.lock()
        videoViewerStorage = any
        videoViewerLock.unlock()
    }

    /// The capture produced a frame. Cheap when nobody takes stills.
    nonisolated func offerStillFrame(_ buffer: CVPixelBuffer) {
        queue.async { [self] in
            guard clients.contains(where: \.isStill) else {
                lastStillBuffer = nil
                return
            }
            lastStillBuffer = buffer
            for client in clients where client.isStill { client.stillDirty = true }
            pumpStills()
        }
    }

    /// Sends every still viewer that is idle and out of date its next picture.
    private nonisolated func pumpStills() {
        guard let buffer = lastStillBuffer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var nextWake: UInt64?
        for client in clients where client.isStill && client.stillDirty {
            if let sent = client.stillSentAt {
                // A viewer that stopped acking must not stall for good.
                guard now &- sent > Self.stillLossTimeoutNanos else {
                    nextWake = min(nextWake ?? .max, Self.stillLossTimeoutNanos - (now &- sent))
                    continue
                }
                client.stillSentAt = nil
            }
            let wait = now &- client.lastStillAt
            guard wait >= Self.minStillIntervalNanos else {
                nextWake = min(nextWake ?? .max, Self.minStillIntervalNanos - wait)
                continue
            }
            client.stillDirty = false
            client.stillSentAt = now
            client.lastStillAt = now
            client.stillSequence &+= 1
            let viewport = client.stillViewport
            let sequence = client.stillSequence
            let source = (UInt16(clamping: CVPixelBufferGetWidth(buffer)), UInt16(clamping: CVPixelBufferGetHeight(buffer)))
            stillQueue.async { [self] in
                let jpeg = stillEncoder.encode(buffer, viewport: viewport)
                queue.async { [self] in
                    guard let jpeg else {
                        client.stillSentAt = nil
                        return
                    }
                    let frame = MacNativeStreamProtocol.encodeStillFrame(.init(
                        sequence: sequence,
                        sourceWidth: source.0, sourceHeight: source.1,
                        region: viewport, jpeg: jpeg
                    ))
                    sendRequired(frame, to: client)
                }
            }
        }
        if let nextWake, !stillRetryScheduled {
            stillRetryScheduled = true
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nextWake) + 1_000_000)) { [self] in
                stillRetryScheduled = false
                pumpStills()
            }
        }
    }

    private nonisolated func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        pendingClients.append(client)

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                self.log.info("Authenticated native stream candidate connected")
            case .failed(let error):
                self.remove(client, reason: "connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.remove(client, reason: "connection cancelled")
            default:
                break
            }
        }
        receiveLoop(client)
        connection.start(queue: queue)
    }

    private nonisolated func receiveLoop(_ client: Client) {
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1 << 20
        ) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data, !data.isEmpty {
                client.inbound.append(data)
                self.processInbound(client)
            }
            if isComplete || error != nil {
                self.remove(client, reason: error.map { "receive failed: \($0.localizedDescription)" }
                    ?? "viewer closed the connection")
            } else {
                self.receiveLoop(client)
            }
        }
    }

    private nonisolated func processInbound(_ client: Client) {
        for frame in MacNativeStreamProtocol.drainFrames(&client.inbound) {
            switch frame.type {
            case MacNativeStreamProtocol.FrameType.hello.rawValue:
                guard let hello = MacNativeStreamProtocol.decodeHello(frame.payload) else {
                    sendError("Invalid client greeting.", to: client)
                    return
                }
                guard let identity = hello.identity,
                      let binding = CompanionIdentify.binding(client.connection, channel: .native),
                      let entry = keyring.verify(identity, binding: binding) else {
                    sendError("This device isn't paired with this Mac. Pair it again from Longwave's connection settings.", to: client)
                    return
                }
                client.deviceID = .some(entry.credential.deviceID)
                client.grants = entry.grants
                onDeviceIdentified?(entry.credential.deviceID)
                promote(
                    client,
                    deviceName: hello.deviceName,
                    protocolVersion: hello.protocolVersion ?? 1,
                    wantsScreen: hello.wantsScreen ?? true,
                    decodesHEVC422: hello.decodesHEVC422 ?? false,
                    acksFrames: hello.acksFrames ?? false,
                    stillsOnly: hello.stillsOnly ?? false
                )
            case MacNativeStreamProtocol.FrameType.keepAlive.rawValue:
                break
            // Remote control: any promoted viewer may inject — they are all
            // the same authenticated user. A pending (pre-hello) socket is
            // ignored.
            case MacNativeStreamProtocol.FrameType.mouseMove.rawValue:
                guard client.isActive, client.grants.contains(.input), let point = MacNativeStreamProtocol.decodeMouseMove(frame.payload) else { break }
                onMouseMove?(point.x, point.y)
            case MacNativeStreamProtocol.FrameType.mouseDown.rawValue:
                guard client.isActive, client.grants.contains(.input), let event = MacNativeStreamProtocol.decodeMouseButton(frame.payload) else { break }
                onMouseDown?(event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.mouseUp.rawValue:
                guard client.isActive, client.grants.contains(.input), let event = MacNativeStreamProtocol.decodeMouseButton(frame.payload) else { break }
                onMouseUp?(event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.scroll.rawValue:
                guard client.isActive, client.grants.contains(.input), let event = MacNativeStreamProtocol.decodeScroll(frame.payload) else { break }
                onScroll?(event.x, event.y, event.deltaX, event.deltaY)
            case MacNativeStreamProtocol.FrameType.keyDown.rawValue:
                guard client.isActive, client.grants.contains(.input), let event = MacNativeStreamProtocol.decodeKeyEvent(frame.payload) else { break }
                onKeyDown?(event.keyCode, event.modifiers)
            case MacNativeStreamProtocol.FrameType.keyUp.rawValue:
                guard client.isActive, client.grants.contains(.input), let event = MacNativeStreamProtocol.decodeKeyEvent(frame.payload) else { break }
                onKeyUp?(event.keyCode, event.modifiers)
            // v2 multiplexed streams — again active-client-only.
            case MacNativeStreamProtocol.FrameType.windowStreamStart.rawValue:
                guard client.isActive, client.grants.contains(.screen), client.isV2,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                guard !client.subscriptions.contains(windowID) else { break }
                let wasRunning = subscriberCount(windowID) > 0
                client.subscriptions.insert(windowID)
                refreshVideoViewerFlag()
                client.awaitingKeyFrame[windowID] = true
                if wasRunning {
                    // Someone else already has this stream going, so the
                    // capture side will not announce its format again — hand
                    // this viewer the cached one, and ask the encoder for a
                    // key frame so the gate above opens on the next frame
                    // rather than at the end of the current GOP.
                    sendCachedFormat(of: windowID, to: client)
                    onKeyFrameNeeded?(windowID)
                } else {
                    onWindowStreamStart?(windowID)
                }
            case MacNativeStreamProtocol.FrameType.windowStreamStop.rawValue:
                guard client.isActive, client.isV2,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                guard client.subscriptions.remove(windowID) != nil else { break }
                defer { refreshVideoViewerFlag() }
                client.awaitingKeyFrame[windowID] = nil
                // Only when the last viewer of this stream lets go.
                if subscriberCount(windowID) == 0,
                   !(windowID == MacNativeStreamProtocol.desktopStreamID && clients.contains(where: \.isStill)) {
                    onWindowStreamStop?(windowID)
                }
            case MacNativeStreamProtocol.FrameType.stillViewport.rawValue:
                guard client.isActive, client.grants.contains(.screen), client.isStill,
                      let viewport = MacNativeStreamProtocol.decodeStillViewport(frame.payload),
                      viewport != client.stillViewport else { break }
                client.stillViewport = viewport
                client.stillDirty = true
                pumpStills()
            case MacNativeStreamProtocol.FrameType.frameAck.rawValue:
                if client.isActive, client.isStill,
                   let ack = MacNativeStreamProtocol.decodeFrameAck(frame.payload),
                   ack.sequence >= client.stillSequence {
                    client.stillSentAt = nil
                    pumpStills()
                    break
                }
                guard client.isActive, client.acksFrames,
                      let ack = MacNativeStreamProtocol.decodeFrameAck(frame.payload),
                      ack.windowID == MacNativeStreamProtocol.desktopStreamID else { break }
                handleDesktopAck(ack.sequence, from: client)
            case MacNativeStreamProtocol.FrameType.requestKeyFrame.rawValue:
                guard client.isActive, client.isV2,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload),
                      client.wantsStream(windowID) else { break }
                onKeyFrameNeeded?(windowID)
            case MacNativeStreamProtocol.FrameType.selectDisplay.rawValue:
                guard client.isActive, client.grants.contains(.screen), client.isV2,
                      let displayID = MacNativeStreamProtocol.decodeSelectDisplay(frame.payload) else { break }
                onSelectDisplay?(displayID)
            case MacNativeStreamProtocol.FrameType.configureVirtualDisplay.rawValue:
                guard client.isActive, client.grants.contains(.screen), client.isV2,
                      let change = MacNativeStreamProtocol.decodeVirtualDisplayChange(frame.payload) else { break }
                onConfigureVirtualDisplay?(change)
            case MacNativeStreamProtocol.FrameType.focusWindow.rawValue:
                guard client.isActive, client.grants.contains(.input),
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                onFocusWindow?(windowID)
            case MacNativeStreamProtocol.FrameType.windowMouseMove.rawValue:
                guard client.isActive, client.grants.contains(.input),
                      let event = MacNativeStreamProtocol.decodeWindowMouseMove(frame.payload) else { break }
                onWindowMouseMove?(event.windowID, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowMouseDown.rawValue:
                guard client.isActive, client.grants.contains(.input),
                      let event = MacNativeStreamProtocol.decodeWindowMouseButton(frame.payload) else { break }
                onWindowMouseDown?(event.windowID, event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowMouseUp.rawValue:
                guard client.isActive, client.grants.contains(.input),
                      let event = MacNativeStreamProtocol.decodeWindowMouseButton(frame.payload) else { break }
                onWindowMouseUp?(event.windowID, event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowScroll.rawValue:
                guard client.isActive, client.grants.contains(.input),
                      let event = MacNativeStreamProtocol.decodeWindowScroll(frame.payload) else { break }
                onWindowScroll?(event.windowID, event.x, event.y, event.deltaX, event.deltaY)
            default:
                break
            }
        }
    }

    /// How many viewers currently want this stream — what decides whether the
    /// capture side is asked to start or stop it.
    private nonisolated func subscriberCount(_ windowID: UInt32) -> Int {
        clients.count { $0.wantsStream(windowID) }
    }

    /// Sends the cached format blob for a stream that is already running, so a
    /// viewer joining it mid-flight can decode.
    private nonisolated func sendCachedFormat(of windowID: UInt32, to client: Client) {
        if windowID == MacNativeStreamProtocol.desktopStreamID {
            guard let currentDesktopFormat else { return }
            sendRequired(Self.desktopFormatFrame(currentDesktopFormat, for: client), to: client)
        } else if let data = currentWindowFormats[windowID] {
            sendRequired(
                MacNativeStreamProtocol.encodeWindowFormatDescription(
                    windowID: windowID,
                    kind: .coreMediaImageDescription,
                    data: data
                ),
                to: client
            )
        }
    }

    private nonisolated func promote(
        _ client: Client,
        deviceName: String,
        protocolVersion: Int,
        wantsScreen: Bool,
        decodesHEVC422: Bool,
        acksFrames: Bool,
        stillsOnly: Bool
    ) {
        guard !client.isActive,
              let pendingIndex = pendingClients.firstIndex(where: { $0 === client }) else { return }

        client.deviceName = deviceName
        client.protocolVersion = min(protocolVersion, MacNativeStreamProtocol.protocolVersion)
        client.decodesHEVC422 = decodesHEVC422
        // Only a v2 viewer gets sequenced desktop frames it could ack.
        client.acksFrames = acksFrames && client.isV2
        client.isStill = stillsOnly && client.isV2
        let wantsScreen = wantsScreen && client.grants.contains(.screen)
        client.wantsDesktopV1 = wantsScreen
        client.awaitingKeyFrame = [MacNativeStreamProtocol.desktopStreamID: true]
        client.subscriptions = []
        // v1 has no subscribe frame — joining *is* its desktop subscription,
        // so count the transition before it is added to the viewer set.
        let desktopWasRunning = subscriberCount(MacNativeStreamProtocol.desktopStreamID) > 0
        pendingClients.remove(at: pendingIndex)
        client.isActive = true
        clients.append(client)

        if client.isV2 {
            sendRequired(MacNativeStreamProtocol.encodeHelloAck(.init(
                protocolVersion: MacNativeStreamProtocol.protocolVersion,
                platform: "macOS",
                keyCodeSpace: .macVirtual,
                supportsWindowStreams: true,
                supportsTransparentDesktop: false,
                supportsAudioStream: true,
                supportsStills: true,
                grants: client.grants.map(\.rawValue).sorted()
            )), to: client)
            if client.grants.contains(.screen), let currentInventoryFrame {
                sendRequired(currentInventoryFrame, to: client)
            }
            if client.grants.contains(.screen), let currentDisplayListFrame {
                sendRequired(currentDisplayListFrame, to: client)
            }
            // No format frame yet — a v2 client gets stream formats as it
            // subscribes.
        } else {
            // v1's desktop format is sent below, with the subscription this
            // hello implies — and only when it actually asked for Screen.
            sendRequired(MacNativeStreamProtocol.encodeFrame(.helloAck), to: client)
        }
        sendRequired(MacNativeStreamProtocol.encodeFrame(.mouseStatus, Data([inputStatus(mouseAvailability, for: client)])), to: client)
        sendRequired(MacNativeStreamProtocol.encodeFrame(.keyboardStatus, Data([inputStatus(keyboardAvailability, for: client)])), to: client)
        // Before any stream start below: starting the desktop capture reads
        // the chroma every viewer can decode, and that answer is derived from
        // this very callback. Announcing the viewer set afterwards would start
        // the capture at the old set's chroma and immediately restart it.
        onClientConnected?(deviceName, wantsScreen)
        onClientsChanged?(clients.map(\.summary))
        refreshVideoViewerFlag()
        if client.isStill, wantsScreen {
            client.stillDirty = true
            // Capture is shared: this is a no-op when it is already running.
            onWindowStreamStart?(MacNativeStreamProtocol.desktopStreamID)
            pumpStills()
        }
        if !client.isV2, wantsScreen {
            if desktopWasRunning {
                sendCachedFormat(of: MacNativeStreamProtocol.desktopStreamID, to: client)
                onKeyFrameNeeded?(MacNativeStreamProtocol.desktopStreamID)
            } else {
                onWindowStreamStart?(MacNativeStreamProtocol.desktopStreamID)
            }
        }
    }

    private nonisolated func sendRequired(_ data: Data, to client: Client?) {
        client?.connection.send(content: data, completion: .contentProcessed {
            [weak self, weak client] error in
            if let error, let client {
                self?.remove(client, reason: "required send failed: \(error.localizedDescription)")
            }
        })
    }

    private nonisolated func sendError(_ message: String, to client: Client) {
        log.notice("Ending a viewer's session: \(message, privacy: .public)")
        let frame = MacNativeStreamProtocol.encodeFrame(.error, Data(message.utf8))
        client.connection.send(content: frame, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    // MARK: - Ack pacing

    /// Whether the capture may encode another desktop frame right now: every
    /// acking viewer has fewer than `maxUnackedFrames` outstanding. Viewers
    /// that don't ack are paced by the drop path in `deliver` instead.
    nonisolated func desktopCanAcceptFrame() -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return desktopGateOpenStorage
    }

    private nonisolated func handleDesktopAck(_ sequence: UInt64, from client: Client) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let sentAt = client.unackedDesktop[sequence] {
            let sample = Double(now &- sentAt) / 1_000_000
            client.linkLatencyMs = client.linkLatencyMs == 0
                ? sample
                : client.linkLatencyMs * 0.85 + sample * 0.15
        }
        // Cumulative: anything older than the acked frame arrived too, or
        // never will.
        client.unackedDesktop = client.unackedDesktop.filter { $0.key > sequence }
        let wasOpen = desktopCanAcceptFrame()
        updateDesktopGate()
        if !wasOpen, desktopCanAcceptFrame() { onDesktopPipeClear?() }
        if now &- lastLinkReport > 500_000_000 {
            lastLinkReport = now
            let slowest = clients.filter(\.acksFrames).map(\.linkLatencyMs).max() ?? 0
            onLinkLatency?(slowest)
        }
    }

    /// Recomputes the gate on `queue`, expiring frames presumed lost. While
    /// it is shut, re-checks after the loss timeout so a viewer that stopped
    /// acking cannot stall the stream.
    private nonisolated func updateDesktopGate() {
        let now = DispatchTime.now().uptimeNanoseconds
        var open = true
        for client in clients where client.acksFrames
            && client.wantsStream(MacNativeStreamProtocol.desktopStreamID) {
            client.unackedDesktop = client.unackedDesktop.filter {
                now &- $0.value < Self.unackedTimeoutNanos
            }
            if client.unackedDesktop.count >= Self.maxUnackedFrames { open = false }
        }
        gateLock.lock()
        desktopGateOpenStorage = open
        gateLock.unlock()
        if !open {
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.unackedTimeoutNanos))) { [self] in
                guard !desktopCanAcceptFrame() else { return }
                updateDesktopGate()
                if desktopCanAcceptFrame() { onDesktopPipeClear?() }
            }
        }
    }

    /// `reason` is code-defined text plus a system error description — it
    /// carries no user data, so it is logged publicly; the viewer's name is not.
    private nonisolated func remove(_ client: Client, reason: String) {
        queue.async { [self] in
            pendingClients.removeAll { $0 === client }
            guard let index = clients.firstIndex(where: { $0 === client }) else {
                client.connection.cancel()
                return
            }
            log.notice("Viewer \(client.deviceName ?? "unknown", privacy: .private(mask: .hash)) left: \(reason, privacy: .public)")
            var streams = client.isV2
                ? client.subscriptions
                : (client.wantsDesktopV1 ? [MacNativeStreamProtocol.desktopStreamID] : [])
            if client.isStill, client.wantsDesktopV1 {
                streams.insert(MacNativeStreamProtocol.desktopStreamID)
            }
            clients.remove(at: index)
            client.isActive = false
            refreshVideoViewerFlag()
            client.connection.cancel()
            updateDesktopGate()
            if desktopCanAcceptFrame() { onDesktopPipeClear?() }
            // Stop only what no other viewer still wants.
            for streamID in streams where subscriberCount(streamID) == 0
                && !(streamID == MacNativeStreamProtocol.desktopStreamID && clients.contains(where: \.isStill)) {
                onWindowStreamStop?(streamID)
            }
            onClientsChanged?(clients.map(\.summary))
        }
    }

    private nonisolated func finishStop() {
        queue.async { [self] in
            let completion = stopCompletion
            stopCompletion = nil
            stoppingListener = nil
            completion?()
        }
    }
}
