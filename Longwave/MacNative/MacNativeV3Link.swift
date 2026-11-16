import DebugTrace
import Foundation
import Network
import StreamCrypto
import StreamPlayout
import StreamTransport
import StreamWire

/// The client's half of Native v3 (NATIVE_V3_PROTOCOL.md) for one session:
/// a UDP socket and a timer driving the package's sans-I/O `ClientConnector`,
/// `TransportSession` and `VideoStreamReceiver`. `MacNativeStreamClient` owns
/// it and shares its queue and renderer, so a v3 session looks the same to
/// everything above.
///
/// It carries the desktop stream, Unity's per-window streams (more stream IDs
/// on this session, §4.2; only when the host negotiated them), remote input,
/// the display choice and the remote-control status.
nonisolated final class MacNativeV3Link: @unchecked Sendable {
    typealias Event = MacNativeStreamClient.Event

    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let renderer: MacNativeVideoRenderer
    // Called on `queue`, like the v2 client's own connection callbacks.
    private let emit: (Event) -> Void
    private let noAnswer: () -> Void
    /// The renderer for a window's stream, if its scene is open. Called on `queue`.
    private let windowRenderer: (UInt32) -> MacNativeVideoRenderer?
    private let log = DebugLogger(subsystem: "pro.longwave", category: "MacNativeV3Link")

    private let hello: ClientHello
    private var connector: ClientConnector
    private var connection: NWConnection?
    private var timer: NativeV3Timer?
    private var session: TransportSession?
    private var capabilities = CapabilitySet()
    /// What one video stream needs to play out: its receiver, and the formats
    /// and frames that arrive out of step with each other.
    private final class Playout {
        var receiver: VideoStreamReceiver
        /// Formats not yet in force, oldest first: each applies from its
        /// `firstFrameNumber` on.
        var pendingFormats: [FormatDescription] = []
        var hasFormat = false
        /// Frames that arrived before any format did.
        var heldFrames: [AssembledVideoFrame] = []

        init(streamID: UInt32, configuration: VideoStreamReceiver.Configuration = .init()) {
            receiver = VideoStreamReceiver(streamID: streamID, configuration: configuration)
        }

        /// Drops the picture with its format, so a restart waits for the host's next one.
        func reset() {
            hasFormat = false
            pendingFormats.removeAll()
            heldFrames.removeAll()
        }
    }

    private var desktop = Playout(streamID: NativeV3.desktopStreamID)
    /// One per subscribed window.
    private var windows: [UInt32: Playout] = [:]
    private var receiverConfiguration = VideoStreamReceiver.Configuration()
    /// Whether the host negotiated window streams.
    private var windowsNegotiated: Bool { capabilities.contains(.windowStreams) }
    private var pointerSequence: UInt32 = 0
    private var latency = MacNativeFrameLatencyMeter(label: "v3 desktop")
    /// When the receiver next needs a poll (timeouts, NACKs). Not on every
    /// datagram: a key frame is hundreds of them.
    private var receiverDue: UInt64 = 0
    private var closed = false

    /// How long a host gets to answer before the client falls back to v2
    /// (§4.6 says 500 ms once `ns=3` is advertised; without it, longer).
    private static let answerTimeout: UInt64 = 2_000_000_000

    init?(host: String, port: UInt16, credential: CompanionCredential, deviceName: String, wantsScreen: Bool,
          wantsWindows: Bool, queue: DispatchQueue, renderer: MacNativeVideoRenderer,
          windowRenderer: @escaping (UInt32) -> MacNativeVideoRenderer?,
          emit: @escaping (Event) -> Void, noAnswer: @escaping () -> Void) {
        guard let psk = NativeV3.psk(for: credential) else { return nil }
        var offer: [Capability] = [.nack]
        if MacNativeVideoCapability.decodesHEVC422InHardware { offer.append(.hevc422) }
        // Asked for only by a session using Unity: the host then sends the
        // window inventory, which names every window on the Mac.
        if wantsWindows { offer.append(.windowStreams) }
        hello = ClientHello(capabilities: CapabilitySet(offer), platform: Self.platform,
                            maxUDPPayload: DatagramLayout.maxProbedUDPPayload,
                            intent: wantsScreen ? [.screen, .audio] : [.audio],
                            deviceName: NativeV3.helloName(deviceName), software: NativeV3.softwareVersion)
        guard let helloBytes = try? hello.encoded() else { return nil }
        var configuration = ClientConnector.Configuration()
        configuration.giveUpAfter = Self.answerTimeout
        connector = ClientConnector(psk: psk, hello: helloBytes, configuration: configuration)
        self.host = host
        self.port = port
        self.queue = queue
        self.renderer = renderer
        self.windowRenderer = windowRenderer
        self.emit = emit
        self.noAnswer = noAnswer
    }

    private static var platform: DevicePlatform {
        #if os(visionOS)
        .visionOS
        #elseif os(iOS)
        .iOS
        #else
        .macOS
        #endif
    }

    // MARK: Lifecycle (on `queue`)

    func start() {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            finish("This connection's port is invalid.")
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: NativeV3.parameters())
        self.connection = connection
        timer = NativeV3Timer(queue: queue) { [weak self] in
            self?.timer?.fired()
            self?.drive()
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.drive()
            case .failed(let error):
                // Before the handshake, a refused port is a host without v3.
                if self?.session == nil { self?.fallBack() } else { self?.finish(error.localizedDescription) }
            default:
                break
            }
        }
        receive(on: connection)
        connection.start(queue: queue)
    }

    /// Ends the session, telling the host.
    func close() {
        guard !closed else { return }
        if session != nil, let body = try? TextBody.encode("") {
            try? session?.send(.bye, body: body, on: .control)
            flush(now: NativeV3.now())
        }
        tearDown()
    }

    private func tearDown() {
        closed = true
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        session = nil
    }

    /// No v3 host here: hand over to v2.
    private func fallBack() {
        guard !closed else { return }
        log.notice("No Native v3 answer from the host; falling back to v2")
        tearDown()
        noAnswer()
    }

    private func finish(_ message: String?) {
        guard !closed else { return }
        tearDown()
        emit(.closed(message))
    }

    // MARK: Input and control (on `queue`)

    func sendMouseMove(x: UInt16, y: UInt16, streamID: UInt32 = NativeV3.desktopStreamID) {
        guard session != nil else { return }
        pointerSequence &+= 1
        // Built first: hostTime() reads `session`, which the optional-chained
        // mutating send already holds for writing (a runtime exclusivity trap).
        let snapshot = StateSnapshot(sequence: pointerSequence, hostTime: hostTime(),
                                     payload: .pointerAbsolute(PointerPosition(streamID: streamID, x: x, y: y)))
        session?.send(snapshot)
        flush(now: NativeV3.now())
    }

    func sendMouseButton(down: Bool, button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16,
                         streamID: UInt32 = NativeV3.desktopStreamID) {
        let event = MouseButtonEvent(streamID: streamID, button: MouseButton(rawValue: button.rawValue) ?? .middle,
                                     x: x, y: y)
        send(down ? .mouseDown(event) : .mouseUp(event))
    }

    func sendScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16, streamID: UInt32 = NativeV3.desktopStreamID) {
        send(.scroll(ScrollEvent(streamID: streamID, x: x, y: y, lineDeltaX: deltaX, lineDeltaY: deltaY,
                                 preciseDeltaX: Int32(deltaX) * 120, preciseDeltaY: Int32(deltaY) * 120)))
    }

    func sendKey(down: Bool, keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        let key = KeyEvent(keyCode: keyCode, modifiers: KeyModifiers(rawValue: modifiers.rawValue).intersection(.defined))
        send(down ? .keyDown(key) : .keyUp(key))
    }

    func sendFocusWindow(streamID: UInt32) {
        send(.focusWindow(streamID: streamID))
    }

    /// The decoder lost its state: freeze until a key frame, and ask for one.
    func requestKeyFrame(streamID: UInt32 = NativeV3.desktopStreamID) {
        guard let playout = playout(for: streamID) else { return }
        let now = NativeV3.now()
        handle(playout.receiver.requestKeyFrame(now: now), stream: streamID)
        receiverDue = min(receiverDue, playout.receiver.nextWakeTime(now: now) ?? .max)
        drive()
    }

    /// The Screen toggle. Stopping drops the format with the picture (the
    /// manager resets the renderer), so a restart waits for the host's next one.
    func setDesktopSubscribed(_ on: Bool) {
        if !on { desktop.reset() }
        guard let body = try? StreamSubscription(streamID: NativeV3.desktopStreamID).encoded() else { return }
        sendControl(on ? .streamStart : .streamStop, body: body)
    }

    /// A window's stream (its scene opened or closed). Subscribing again, as a
    /// scene does when visionOS brings it back, starts the stream afresh.
    func setWindowSubscribed(_ windowID: UInt32, _ on: Bool) {
        guard windowsNegotiated, windowID != NativeV3.desktopStreamID else { return }
        if on {
            windows[windowID] = Playout(streamID: windowID, configuration: receiverConfiguration)
        } else {
            windows[windowID] = nil
        }
        guard let body = try? StreamSubscription(streamID: windowID).encoded() else { return }
        sendControl(on ? .streamStart : .streamStop, body: body)
    }

    private func playout(for streamID: UInt32) -> Playout? {
        streamID == NativeV3.desktopStreamID ? desktop : windows[streamID]
    }

    func sendSelectDisplay(id: String) {
        guard let body = try? TextBody.encode(id) else { return }
        sendControl(.selectDisplay, body: body)
    }

    func sendVirtualDisplayChange(_ change: MacNativeStreamProtocol.VirtualDisplayChange) {
        guard let json = try? JSONEncoder().encode(change) else { return }
        sendControl(.virtualDisplayChange, body: Array(json))
    }

    private func send(_ event: InputEvent) {
        guard session != nil else { return }
        var body = WireWriter(reservingCapacity: 32)
        guard (try? TimedInputEvent(hostTime: hostTime(), event: event).encodeBody(to: &body)) != nil else { return }
        try? session?.send(event.messageType, body: body.bytes, on: .input)
        flush(now: NativeV3.now())
    }

    private func sendControl(_ type: MessageType, body: [UInt8]) {
        guard session != nil else { return }
        try? session?.send(type, body: body, on: .control)
        flush(now: NativeV3.now())
    }

    /// The client's estimate of host time now (§5); 0 until the clock syncs.
    private func hostTime() -> UInt64 {
        session?.clock.remoteTime(atLocal: NativeV3.now()) ?? 0
    }

    // MARK: Datagrams (on `queue`)

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !closed else { return }
            if let data, !data.isEmpty { handle(datagram: [UInt8](data)) }
            if error == nil {
                receive(on: connection)
            } else if session == nil {
                fallBack()
            }
        }
    }

    private func handle(datagram: [UInt8]) {
        let now = NativeV3.now()
        guard session != nil else {
            guard let (opened, ackBytes) = connector.receive(datagram, now: now) else { return }
            connected(opened, ackBytes: ackBytes, now: now)
            return
        }
        let events: [SessionEvent]
        do {
            // In place, so the session's buffers aren't copied per datagram.
            events = try session!.receive(datagram, now: now)
        } catch {
            finish("Lost the connection to the computer (\(error)).")
            return
        }
        for event in events { handle(event, now: now) }
        drive()
    }

    private func connected(_ opened: TransportSession, ackBytes: [UInt8], now: UInt64) {
        guard let ack = try? HostHelloAck(decoding: ackBytes) else {
            finish("The computer's answer couldn't be read.")
            return
        }
        guard !ack.refused else {
            finish("This computer doesn't allow this device to connect. Check the Devices tab in Longwave Companion, and that its Native stream switch is on.")
            return
        }
        var session = opened
        session.setPathCeiling(ack.maxUDPPayload, now: now)
        self.session = session
        capabilities = hello.sessionCapabilities(from: ack)
        var configuration = VideoStreamReceiver.Configuration()
        configuration.nacks = capabilities.contains(.nack)
        receiverConfiguration = configuration
        desktop = Playout(streamID: NativeV3.desktopStreamID, configuration: configuration)
        windows = [:]
        log.notice("Native v3 session up (\(ack.platform.description, privacy: .public), datagrams up to \(ack.maxUDPPayload, privacy: .public) bytes)")
        emit(.connected(Self.v2Ack(ack, windowStreams: windowsNegotiated)))
        drive()
    }

    /// What the rest of the client reads from a v2 ack: the host's platform,
    /// key code space and grants. Stills are v2-only for now.
    private static func v2Ack(_ ack: HostHelloAck, windowStreams: Bool) -> MacNativeStreamProtocol.HelloAck {
        var grants: [String] = []
        for (bit, grant) in CompanionGrant.allCases.enumerated() where ack.grants.rawValue & (1 << bit) != 0 {
            grants.append(grant.rawValue)
        }
        return .init(
            protocolVersion: MacNativeStreamProtocol.protocolVersion,
            platform: ack.platform == .windows ? "windows" : "macOS",
            keyCodeSpace: ack.keyCodeSpace == .hidUsage ? .hidUsage : .macVirtual,
            supportsWindowStreams: windowStreams,
            supportsTransparentDesktop: false,
            supportsAudioStream: ack.platform == .macOS,
            supportsStills: false,
            grants: grants
        )
    }

    private func handle(_ event: SessionEvent, now: UInt64) {
        switch event {
        case .message(.control, let message):
            handleControl(message)
        case .message(.input, let message):
            guard case .controlStatus(let kind, let status)? = try? HostInputEvent(message: message) else { return }
            let availability: Event.RemoteControlAvailability = switch status {
            case .available: .available
            case .accessibilityDenied: .accessibilityDenied
            case .disabled: .disabled
            }
            emit(kind == .mouse ? .mouseAvailability(availability) : .keyboardAvailability(availability))
        case .video(let header, let data):
            guard let playout = playout(for: header.streamID) else { return }
            handle(playout.receiver.receive(header, data: data, now: now), stream: header.streamID)
            receiverDue = min(receiverDue, now + 2_000_000)
        case .message, .audio, .state, .nack, .feedback:
            break
        }
    }

    private func handleControl(_ message: Message) {
        switch message.type {
        case .formatDescription:
            guard let format = try? FormatDescription(decoding: message.body),
                  let playout = playout(for: format.streamID) else { return }
            playout.pendingFormats.append(format)
            if !playout.hasFormat {
                // Frames that beat their format here wait for it.
                let held = playout.heldFrames
                playout.heldFrames = []
                for frame in held { deliver(frame, stream: format.streamID) }
            }
        case .windowInventory:
            if let inventory = try? JSONDecoder().decode(MacNativeStreamProtocol.WindowInventory.self, from: Data(message.body)) {
                emit(.inventory(inventory.windows))
            }
        case .streamClosed:
            guard let closed = try? StreamClosed(decoding: message.body) else { return }
            // The host dropped it: the scene stays subscribed on this side.
            windows[closed.streamID] = nil
            emit(.windowClosed(closed.streamID, closed.reason.isEmpty ? nil : closed.reason))
        case .displayList:
            if let list = try? JSONDecoder().decode(MacNativeStreamProtocol.DisplayList.self, from: Data(message.body)) {
                emit(.displays(list))
            }
        case .bye:
            let reason = (try? TextBody.decode(message.body)) ?? ""
            finish(reason.isEmpty ? nil : reason)
        default:
            break
        }
    }

    private func handle(_ outputs: [VideoStreamReceiver.Output], stream streamID: UInt32) {
        for output in outputs {
            switch output {
            case .frame(let frame):
                deliver(frame, stream: streamID)
            case .nack(let nack):
                session?.send(nack)
            case .recovery(let request):
                if let body = try? request.encoded() { try? session?.send(.recoveryRequest, body: body, on: .control) }
            }
        }
    }

    /// Hands a decodable frame to the renderer, under the format in force for it.
    private func deliver(_ frame: AssembledVideoFrame, stream streamID: UInt32) {
        guard let playout = playout(for: streamID) else { return }
        // A window whose scene isn't open (any more) has nowhere to draw.
        guard let renderer = streamID == NativeV3.desktopStreamID ? renderer : windowRenderer(streamID) else { return }
        while let next = playout.pendingFormats.first, !SerialNumber.isNewer(next.firstFrameNumber, than: frame.frameNumber) {
            playout.pendingFormats.removeFirst()
            renderer.setFormatDescription(
                Data(next.configuration),
                kind: MacNativeStreamProtocol.FormatKind(rawValue: next.formatKind.rawValue) ?? .coreMediaImageDescription)
            playout.hasFormat = true
        }
        guard playout.hasFormat else {
            playout.heldFrames.append(frame)
            if playout.heldFrames.count > 8 { playout.heldFrames.removeFirst() }
            return
        }
        let now = NativeV3.now()
        if streamID == NativeV3.desktopStreamID {
            latency.record(captureTime: frame.captureTime, isKeyFrame: frame.flags.contains(.key), now: now,
                           hostNow: session?.clock.remoteTime(atLocal: now))
        }
        renderer.enqueue(MacNativeStreamProtocol.VideoFrame(
            data: Data(frame.payload.accessUnit), isKeyFrame: frame.flags.contains(.key),
            sequence: UInt64(frame.frameNumber), timestampNanoseconds: frame.captureTime))
    }

    /// Sends what's due and re-arms the timer. Before the handshake completes
    /// it sends initiations, and falls back to v2 if nothing answers.
    private func drive() {
        guard !closed else { return }
        let now = NativeV3.now()
        guard session != nil else {
            do {
                if let initiation = try connector.poll(now: now), let connection {
                    NativeV3.send([initiation], on: connection)
                }
                timer?.arm(at: connector.nextWakeTime)
            } catch .timedOut {
                fallBack()
            } catch {
                finish("Couldn't start a secure Native v3 session.")
            }
            return
        }
        if now >= receiverDue {
            let rtt = session?.rtt.smoothed ?? 0
            var due = UInt64.max
            for streamID in [NativeV3.desktopStreamID] + Array(windows.keys) {
                guard let playout = playout(for: streamID) else { continue }
                handle(playout.receiver.poll(now: now, rtt: rtt), stream: streamID)
                due = min(due, playout.receiver.nextWakeTime(now: now) ?? .max)
            }
            receiverDue = due
        }
        flush(now: now)
        if let closure = session?.closure {
            finish(closure == .timedOut ? "The computer stopped answering." : "Lost the connection to the computer (\(closure)).")
            return
        }
        let wakes = [session?.nextWakeTime(now: now), receiverDue].compactMap { $0 }
        timer?.arm(at: max(wakes.min() ?? now + 250_000_000, now + 50_000))
    }

    private func flush(now: UInt64) {
        guard let connection, let datagrams = session?.poll(now: now) else { return }
        NativeV3.send(datagrams, on: connection)
    }
}
