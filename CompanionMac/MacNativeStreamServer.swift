import Foundation
import Network
import os

/// Authenticated newest-client-wins server for the native Mac stream. A new
/// client replaces the active viewer only after completing TLS and sending its
/// hello, so an unauthenticated socket cannot kick off the current user.
final class MacNativeStreamServer: @unchecked Sendable {
    nonisolated(unsafe) var onClientActivated:
        (@Sendable (
            _ deviceName: String,
            _ replacedDeviceName: String?,
            _ protocolVersion: Int,
            _ wantsScreen: Bool,
            _ decodesHEVC422: Bool
        ) -> Void)?
    nonisolated(unsafe) var onClientDisconnected: (@Sendable () -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    // Remote control — only ever fired for the active (promoted) client.
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
    nonisolated(unsafe) var onFocusWindow: (@Sendable (UInt32) -> Void)?
    nonisolated(unsafe) var onWindowMouseMove: (@Sendable (UInt32, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowMouseDown:
        (@Sendable (UInt32, MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowMouseUp:
        (@Sendable (UInt32, MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onWindowScroll: (@Sendable (UInt32, UInt16, UInt16, Int16, Int16) -> Void)?

    private nonisolated static let maxPendingBytes = 12 * 1024 * 1024

    private nonisolated final class Client: @unchecked Sendable {
        let connection: NWConnection
        var inbound = Data()
        var deviceName: String?
        var protocolVersion = 1
        var pendingBytes = 0
        /// Per stream ID; the v1 desktop stream uses `desktopStreamID`.
        var awaitingKeyFrame: [UInt32: Bool] = [MacNativeStreamProtocol.desktopStreamID: true]
        /// v2 stream subscriptions. A v1 client is implicitly subscribed to
        /// the desktop stream.
        var subscriptions: Set<UInt32> = []

        var isV2: Bool { protocolVersion >= 2 }

        func wantsStream(_ windowID: UInt32) -> Bool {
            if isV2 {
                return subscriptions.contains(windowID)
            }
            return windowID == MacNativeStreamProtocol.desktopStreamID
        }

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(
        label: "pro.longwave.companion.mac-native.server",
        qos: .userInteractive
    )
    private let log = Logger(
        subsystem: "pro.longwave.companion",
        category: "MacNativeStreamServer"
    )

    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var activeClient: Client?
    private nonisolated(unsafe) var pendingClient: Client?
    /// The desktop stream's raw format-description blob — kept raw so it can
    /// be re-framed for either a v1 (legacy frame) or v2 (multiplexed frame)
    /// client at promotion time.
    private nonisolated(unsafe) var currentDesktopFormat: Data?
    /// The current window inventory, pre-encoded — sent to v2 clients on
    /// promotion and on change.
    private nonisolated(unsafe) var currentInventoryFrame: Data?
    private nonisolated(unsafe) var mouseAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var keyboardAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var stoppingListener: NWListener?
    private nonisolated(unsafe) var stopCompletion: (@Sendable () -> Void)?

    nonisolated init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    nonisolated func start() throws {
        let listener = try NWListener(
            using: MacNativeStreamCrypto.tlsTCPParameters(token: token),
            on: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = listener
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
        listener.start(queue: queue)
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
            activeClient?.connection.cancel()
            pendingClient?.connection.cancel()
            activeClient = nil
            pendingClient = nil
            currentDesktopFormat = nil
            currentInventoryFrame = nil
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
            guard let activeClient else { return }
            sendRequired(MacNativeStreamProtocol.encodeFrame(.mouseStatus, Data([status])), to: activeClient)
        }
    }

    /// Same as `setMouseAvailability`, for keyboard *shortcuts* (full keycode
    /// + modifiers) — independent of mouse and of plain text-only typing.
    nonisolated func setKeyboardAvailability(_ status: UInt8) {
        queue.async { [self] in
            keyboardAvailability = status
            guard let activeClient else { return }
            sendRequired(MacNativeStreamProtocol.encodeFrame(.keyboardStatus, Data([status])), to: activeClient)
        }
    }

    nonisolated func disconnectActive(withError message: String) {
        queue.async { [self] in
            guard let client = activeClient else { return }
            activeClient = nil
            sendError(message, to: client)
            onClientDisconnected?()
        }
    }

    /// Desktop-stream format description (raw CoreMedia blob) — framed as the
    /// legacy `formatDescription` for a v1 client or as a multiplexed
    /// `windowFormatDescription` for a v2 desktop subscriber.
    nonisolated func broadcastFormatDescription(_ data: Data) {
        queue.async { [self] in
            currentDesktopFormat = data
            guard let client = activeClient,
                  client.wantsStream(MacNativeStreamProtocol.desktopStreamID) else { return }
            client.awaitingKeyFrame[MacNativeStreamProtocol.desktopStreamID] = true
            sendRequired(Self.desktopFormatFrame(data, for: client), to: client)
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
            guard let client = activeClient else { return }
            let frame: Data
            if client.isV2 {
                frame = MacNativeStreamProtocol.encodeWindowVideoFrame(
                    windowID: MacNativeStreamProtocol.desktopStreamID,
                    data,
                    isKeyFrame: isKeyFrame,
                    sequence: sequence,
                    timestampNanoseconds: timestampNanoseconds
                )
            } else {
                frame = MacNativeStreamProtocol.encodeVideoFrame(
                    data,
                    isKeyFrame: isKeyFrame,
                    sequence: sequence,
                    timestampNanoseconds: timestampNanoseconds
                )
            }
            deliver(
                frame,
                streamID: MacNativeStreamProtocol.desktopStreamID,
                isKeyFrame: isKeyFrame,
                to: client
            )
        }
    }

    // MARK: - v2 multiplexed streams

    /// Publishes a new window inventory: cached for the next promotion and
    /// pushed to a live v2 client.
    nonisolated func broadcastInventory(_ windows: [MacNativeStreamProtocol.WindowInfo]) {
        let frame = MacNativeStreamProtocol.encodeWindowInventory(windows)
        queue.async { [self] in
            currentInventoryFrame = frame
            guard let client = activeClient, client.isV2 else { return }
            sendRequired(frame, to: client)
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
            guard let client = activeClient, client.wantsStream(windowID) else { return }
            client.awaitingKeyFrame[windowID] = true
            sendRequired(frame, to: client)
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
            guard let client = activeClient else { return }
            deliver(frame, streamID: windowID, isKeyFrame: isKeyFrame, to: client)
        }
    }

    /// Tells the active v2 client a stream ended (window closed, capture
    /// failed, budget exceeded) and forgets its subscription.
    nonisolated func sendWindowClosed(windowID: UInt32, reason: String?) {
        queue.async { [self] in
            guard let client = activeClient, client.isV2 else { return }
            client.subscriptions.remove(windowID)
            client.awaitingKeyFrame[windowID] = nil
            sendRequired(
                MacNativeStreamProtocol.encodeWindowClosed(windowID: windowID, reason: reason),
                to: client
            )
        }
    }

    /// Video delivery shared by the desktop and window streams: subscription
    /// check, per-stream first-key-frame gating, and connection-wide
    /// backpressure (drop when the client is too far behind).
    private nonisolated func deliver(
        _ frame: Data,
        streamID: UInt32,
        isKeyFrame: Bool,
        to client: Client
    ) {
        guard client.wantsStream(streamID),
              client.pendingBytes < Self.maxPendingBytes else {
            return
        }
        if client.awaitingKeyFrame[streamID] ?? true {
            guard isKeyFrame else { return }
            client.awaitingKeyFrame[streamID] = false
        }
        client.pendingBytes += frame.count
        client.connection.send(content: frame, completion: .contentProcessed {
            [weak self, weak client] error in
            self?.queue.async {
                client?.pendingBytes = max(0, (client?.pendingBytes ?? 0) - frame.count)
                if let error {
                    self?.log.error("Video send failed: \(error.localizedDescription)")
                }
            }
        })
    }

    private nonisolated func accept(_ connection: NWConnection) {
        pendingClient?.connection.cancel()
        let client = Client(connection: connection)
        pendingClient = client

        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                self.log.info("Authenticated native stream candidate connected")
            case .failed(let error):
                self.log.error("Native stream candidate failed: \(error.localizedDescription)")
                self.remove(client)
            case .cancelled:
                self.remove(client)
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
                self.remove(client)
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
                promote(
                    client,
                    deviceName: hello.deviceName,
                    protocolVersion: hello.protocolVersion ?? 1,
                    wantsScreen: hello.wantsScreen ?? true,
                    decodesHEVC422: hello.decodesHEVC422 ?? false
                )
            case MacNativeStreamProtocol.FrameType.keepAlive.rawValue:
                break
            // Remote control: only the promoted/active client may inject —
            // a pending (not-yet-authenticated-as-current) client is ignored.
            case MacNativeStreamProtocol.FrameType.mouseMove.rawValue:
                guard activeClient === client, let point = MacNativeStreamProtocol.decodeMouseMove(frame.payload) else { break }
                onMouseMove?(point.x, point.y)
            case MacNativeStreamProtocol.FrameType.mouseDown.rawValue:
                guard activeClient === client, let event = MacNativeStreamProtocol.decodeMouseButton(frame.payload) else { break }
                onMouseDown?(event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.mouseUp.rawValue:
                guard activeClient === client, let event = MacNativeStreamProtocol.decodeMouseButton(frame.payload) else { break }
                onMouseUp?(event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.scroll.rawValue:
                guard activeClient === client, let event = MacNativeStreamProtocol.decodeScroll(frame.payload) else { break }
                onScroll?(event.x, event.y, event.deltaX, event.deltaY)
            case MacNativeStreamProtocol.FrameType.keyDown.rawValue:
                guard activeClient === client, let event = MacNativeStreamProtocol.decodeKeyEvent(frame.payload) else { break }
                onKeyDown?(event.keyCode, event.modifiers)
            case MacNativeStreamProtocol.FrameType.keyUp.rawValue:
                guard activeClient === client, let event = MacNativeStreamProtocol.decodeKeyEvent(frame.payload) else { break }
                onKeyUp?(event.keyCode, event.modifiers)
            // v2 multiplexed streams — again active-client-only.
            case MacNativeStreamProtocol.FrameType.windowStreamStart.rawValue:
                guard activeClient === client, client.isV2,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                guard !client.subscriptions.contains(windowID) else { break }
                client.subscriptions.insert(windowID)
                client.awaitingKeyFrame[windowID] = true
                onWindowStreamStart?(windowID)
            case MacNativeStreamProtocol.FrameType.windowStreamStop.rawValue:
                guard activeClient === client, client.isV2,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                guard client.subscriptions.remove(windowID) != nil else { break }
                client.awaitingKeyFrame[windowID] = nil
                onWindowStreamStop?(windowID)
            case MacNativeStreamProtocol.FrameType.focusWindow.rawValue:
                guard activeClient === client,
                      let windowID = MacNativeStreamProtocol.decodeWindowID(frame.payload) else { break }
                onFocusWindow?(windowID)
            case MacNativeStreamProtocol.FrameType.windowMouseMove.rawValue:
                guard activeClient === client,
                      let event = MacNativeStreamProtocol.decodeWindowMouseMove(frame.payload) else { break }
                onWindowMouseMove?(event.windowID, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowMouseDown.rawValue:
                guard activeClient === client,
                      let event = MacNativeStreamProtocol.decodeWindowMouseButton(frame.payload) else { break }
                onWindowMouseDown?(event.windowID, event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowMouseUp.rawValue:
                guard activeClient === client,
                      let event = MacNativeStreamProtocol.decodeWindowMouseButton(frame.payload) else { break }
                onWindowMouseUp?(event.windowID, event.button, event.x, event.y)
            case MacNativeStreamProtocol.FrameType.windowScroll.rawValue:
                guard activeClient === client,
                      let event = MacNativeStreamProtocol.decodeWindowScroll(frame.payload) else { break }
                onWindowScroll?(event.windowID, event.x, event.y, event.deltaX, event.deltaY)
            default:
                break
            }
        }
    }

    private nonisolated func promote(
        _ client: Client,
        deviceName: String,
        protocolVersion: Int,
        wantsScreen: Bool,
        decodesHEVC422: Bool
    ) {
        guard pendingClient === client || activeClient === client else { return }
        if activeClient === client { return }

        let previous = activeClient
        let previousName = previous?.deviceName
        client.deviceName = deviceName
        client.protocolVersion = min(protocolVersion, MacNativeStreamProtocol.protocolVersion)
        client.awaitingKeyFrame = [MacNativeStreamProtocol.desktopStreamID: true]
        client.subscriptions = []
        activeClient = client
        if pendingClient === client {
            pendingClient = nil
        }

        if let previous {
            let replacement = MacNativeStreamProtocol.encodeFrame(
                .replaced,
                Data(deviceName.utf8)
            )
            previous.connection.send(content: replacement, completion: .contentProcessed { _ in
                previous.connection.cancel()
            })
        }

        if client.isV2 {
            sendRequired(MacNativeStreamProtocol.encodeHelloAck(.init(
                protocolVersion: MacNativeStreamProtocol.protocolVersion,
                platform: "macOS",
                keyCodeSpace: .macVirtual,
                supportsWindowStreams: true,
                supportsTransparentDesktop: false,
                supportsAudioStream: true
            )), to: client)
            if let currentInventoryFrame {
                sendRequired(currentInventoryFrame, to: client)
            }
            // No format frame yet — a v2 client gets stream formats as it
            // subscribes.
        } else {
            sendRequired(MacNativeStreamProtocol.encodeFrame(.helloAck), to: client)
            if let currentDesktopFormat {
                sendRequired(Self.desktopFormatFrame(currentDesktopFormat, for: client), to: client)
            }
        }
        sendRequired(MacNativeStreamProtocol.encodeFrame(.mouseStatus, Data([mouseAvailability])), to: client)
        sendRequired(MacNativeStreamProtocol.encodeFrame(.keyboardStatus, Data([keyboardAvailability])), to: client)
        onClientActivated?(
            deviceName,
            previousName,
            client.protocolVersion,
            wantsScreen,
            decodesHEVC422
        )
    }

    private nonisolated func sendRequired(_ data: Data, to client: Client?) {
        client?.connection.send(content: data, completion: .contentProcessed {
            [weak self, weak client] error in
            if let error, let client {
                self?.log.error("Required send failed: \(error.localizedDescription)")
                self?.remove(client)
            }
        })
    }

    private nonisolated func sendError(_ message: String, to client: Client) {
        let frame = MacNativeStreamProtocol.encodeFrame(.error, Data(message.utf8))
        client.connection.send(content: frame, completion: .contentProcessed { _ in
            client.connection.cancel()
        })
    }

    private nonisolated func remove(_ client: Client) {
        queue.async { [self] in
            if pendingClient === client {
                pendingClient = nil
            }
            guard activeClient === client else {
                client.connection.cancel()
                return
            }
            activeClient = nil
            client.connection.cancel()
            onClientDisconnected?()
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
