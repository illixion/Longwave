import Foundation
import Network

final class MacNativeStreamClient: @unchecked Sendable {
    struct Config: Sendable {
        let host: String
        let port: UInt16
        let credential: CompanionCredential
        let deviceName: String
        /// Whether Screen is on for this session at connect time — lets the
        /// Mac skip starting capture and skip its "connected" notification
        /// for a session that's audio-only from the start. See
        /// `MacNativeStreamProtocol.Hello.wantsScreen`.
        var wantsScreen: Bool = true
        /// Try Native v3 first (the client's experimental setting), falling
        /// back to v2 when no v3 host answers. Needs a per-device credential.
        var prefersV3: Bool = false
    }

    enum Event: Sendable {
        /// The server accepted the hello. Carries the v2 capability payload,
        /// or nil when the server is v1 (one anonymous desktop stream, macOS
        /// virtual keycodes).
        case connected(MacNativeStreamProtocol.HelloAck?)
        case format(CGSize)
        case firstFrame
        case closed(String?)
        case replaced(String)
        /// v2: the host's current streamable-window inventory.
        case inventory([MacNativeStreamProtocol.WindowInfo])
        /// v2: a subscribed window stream ended on the host side.
        case windowClosed(UInt32, String?)
        /// v2: which desktops the host can stream, and which it is streaming.
        case displays(MacNativeStreamProtocol.DisplayList)
        /// The companion's current mouse availability — pushed on connect and
        /// whenever the Mac's toggle or Accessibility grant changes.
        case mouseAvailability(RemoteControlAvailability)
        /// Same, for keyboard *shortcuts* (full keycode + modifiers). Plain
        /// typing has its own always-attempted fallback independent of this —
        /// see `MacNativeStreamManager`.
        case keyboardAvailability(RemoteControlAvailability)

        enum RemoteControlAvailability: Sendable {
            case available
            case disabled
            case accessibilityDenied
        }
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let config: Config
    private let renderer: MacNativeVideoRenderer
    private let queue = DispatchQueue(
        label: "pro.longwave.mac-native.client",
        qos: .userInteractive
    )
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var inbound = Data()
    private nonisolated(unsafe) var closed = false
    /// Per-window renderers (v2 multiplexed streams), keyed by stream ID.
    /// The desktop stream (`desktopStreamID`) always routes to `renderer`.
    /// Only touched on `queue`.
    private nonisolated(unsafe) var windowRenderers: [UInt32: MacNativeVideoRenderer] = [:]
    /// The v3 session, while this client runs over v3. Only touched on `queue`.
    private nonisolated(unsafe) var v3: MacNativeV3Link?

    init(config: Config, renderer: MacNativeVideoRenderer) {
        self.config = config
        self.renderer = renderer
        renderer.onFormat = { [weak self] size in
            self?.onEvent?(.format(size))
        }
        renderer.onFirstFrame = { [weak self] in
            self?.onEvent?(.firstFrame)
        }
        renderer.onError = { [weak self] message in
            self?.queue.async {
                self?.emitClosed(message)
            }
        }
    }

    func start() {
        if config.prefersV3, let link = MacNativeV3Link(
            host: config.host, port: config.port, credential: config.credential, deviceName: config.deviceName,
            wantsScreen: config.wantsScreen, queue: queue, renderer: renderer,
            emit: { [weak self] event in
                if case .closed(let message) = event {
                    self?.emitClosed(message)
                } else {
                    self?.onEvent?(event)
                }
            },
            noAnswer: { [weak self] in
                guard let self else { return }
                usingV3 = false
                v3 = nil
                startV2()
            }
        ) {
            usingV3 = true
            queue.async { [self] in
                v3 = link
                link.start()
            }
            return
        }
        startV2()
    }

    private func startV2() {
        guard !config.credential.token.isEmpty,
              let port = NWEndpoint.Port(rawValue: config.port) else {
            onEvent?(.closed("This connection isn't paired, or its port is invalid."))
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: port,
            using: MacNativeStreamCrypto.tlsTCPParameters(credentials: [config.credential])
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(MacNativeStreamProtocol.encodeHello(
                    deviceName: self.config.deviceName,
                    wantsScreen: self.config.wantsScreen,
                    // Measured, not assumed — a host only sends 4:2:2 to a
                    // headset whose own hardware decoder claimed the profile.
                    decodesHEVC422: MacNativeVideoCapability.decodesHEVC422InHardware,
                    acksFrames: true,
                    identity: CompanionIdentify.make(self.config.credential, channel: .native, connection: connection)
                ))
                self.receiveLoop()
            case .failed(let error):
                self.emitClosed(error.localizedDescription)
            case .cancelled:
                self.emitClosed(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        queue.async { [self] in
            v3?.close()
            v3 = nil
            connection?.cancel()
            connection = nil
            renderer.reset()
        }
    }

    // MARK: - Remote control (mouse/keyboard)

    func sendMouseMove(x: UInt16, y: UInt16) {
        if onV3({ $0.sendMouseMove(x: x, y: y) }) { return }
        send(MacNativeStreamProtocol.encodeMouseMove(x: x, y: y))
    }

    func sendMouseDown(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        if onV3({ $0.sendMouseButton(down: true, button: button, x: x, y: y) }) { return }
        send(MacNativeStreamProtocol.encodeMouseButton(.mouseDown, button: button, x: x, y: y))
    }

    func sendMouseUp(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        if onV3({ $0.sendMouseButton(down: false, button: button, x: x, y: y) }) { return }
        send(MacNativeStreamProtocol.encodeMouseButton(.mouseUp, button: button, x: x, y: y))
    }

    func sendScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        if onV3({ $0.sendScroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY) }) { return }
        send(MacNativeStreamProtocol.encodeScroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY))
    }

    func sendKeyDown(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        if onV3({ $0.sendKey(down: true, keyCode: keyCode, modifiers: modifiers) }) { return }
        send(MacNativeStreamProtocol.encodeKeyEvent(.keyDown, keyCode: keyCode, modifiers: modifiers))
    }

    func sendKeyUp(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        if onV3({ $0.sendKey(down: false, keyCode: keyCode, modifiers: modifiers) }) { return }
        send(MacNativeStreamProtocol.encodeKeyEvent(.keyUp, keyCode: keyCode, modifiers: modifiers))
    }

    /// Runs `body` on the v3 link if this client went v3; false on v2. Until
    /// the handshake completes the link drops input, as v2 does before `.ready`.
    private func onV3(_ body: @escaping @Sendable (MacNativeV3Link) -> Void) -> Bool {
        guard usingV3 else { return false }
        queue.async { [self] in
            if let v3 { body(v3) }
        }
        return true
    }

    /// Whether v3 is the transport: set by `start`, cleared by the fallback to
    /// v2. Written before either transport starts sending, so reading it off
    /// the queue is safe.
    private nonisolated(unsafe) var usingV3 = false

    // MARK: - v2 multiplexed streams

    /// Registers (or, with nil, removes) the renderer that receives a window
    /// stream's format/video frames.
    func setWindowRenderer(_ renderer: MacNativeVideoRenderer?, for windowID: UInt32) {
        // A window renderer that loses its decoder (see
        // `MacNativeVideoRenderer`) asks for its own stream's key frame.
        renderer?.onKeyFrameNeeded = { [weak self] in
            self?.sendRequestKeyFrame(windowID: windowID)
        }
        queue.async { [self] in
            if let renderer {
                windowRenderers[windowID] = renderer
            } else {
                windowRenderers[windowID] = nil
            }
        }
    }

    func sendWindowStreamStart(windowID: UInt32) {
        if usingV3 { return }
        send(MacNativeStreamProtocol.encodeWindowID(.windowStreamStart, windowID: windowID))
    }

    func sendWindowStreamStop(windowID: UInt32) {
        if usingV3 { return }
        send(MacNativeStreamProtocol.encodeWindowID(.windowStreamStop, windowID: windowID))
    }

    func sendRequestKeyFrame(windowID: UInt32) {
        if onV3({ link in if windowID == NativeV3.desktopStreamID { link.requestKeyFrame() } }) { return }
        send(MacNativeStreamProtocol.encodeWindowID(.requestKeyFrame, windowID: windowID))
    }

    func sendSelectDisplay(id: String) {
        if onV3({ $0.sendSelectDisplay(id: id) }) { return }
        send(MacNativeStreamProtocol.encodeSelectDisplay(id: id))
    }

    func sendVirtualDisplayChange(_ change: MacNativeStreamProtocol.VirtualDisplayChange) {
        if onV3({ $0.sendVirtualDisplayChange(change) }) { return }
        send(MacNativeStreamProtocol.encodeVirtualDisplayChange(change))
    }

    func sendFocusWindow(windowID: UInt32) {
        if usingV3 { return }
        send(MacNativeStreamProtocol.encodeWindowID(.focusWindow, windowID: windowID))
    }

    func sendWindowMouseMove(windowID: UInt32, x: UInt16, y: UInt16) {
        send(MacNativeStreamProtocol.encodeWindowMouseMove(windowID: windowID, x: x, y: y))
    }

    func sendWindowMouseDown(
        windowID: UInt32,
        button: MacNativeStreamProtocol.MouseButton,
        x: UInt16,
        y: UInt16
    ) {
        send(MacNativeStreamProtocol.encodeWindowMouseButton(
            .windowMouseDown, windowID: windowID, button: button, x: x, y: y
        ))
    }

    func sendWindowMouseUp(
        windowID: UInt32,
        button: MacNativeStreamProtocol.MouseButton,
        x: UInt16,
        y: UInt16
    ) {
        send(MacNativeStreamProtocol.encodeWindowMouseButton(
            .windowMouseUp, windowID: windowID, button: button, x: x, y: y
        ))
    }

    func sendWindowScroll(windowID: UInt32, x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        send(MacNativeStreamProtocol.encodeWindowScroll(
            windowID: windowID, x: x, y: y, deltaX: deltaX, deltaY: deltaY
        ))
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.emitClosed(error.localizedDescription)
            }
        })
    }

    private func receiveLoop() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1 << 20
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inbound.append(data)
                self.processInbound()
            }
            if isComplete || error != nil {
                self.emitClosed(error?.localizedDescription)
            } else {
                self.receiveLoop()
            }
        }
    }

    private func processInbound() {
        for frame in MacNativeStreamProtocol.drainFrames(&inbound) {
            switch frame.type {
            case MacNativeStreamProtocol.FrameType.helloAck.rawValue:
                onEvent?(.connected(MacNativeStreamProtocol.decodeHelloAck(frame.payload)))
            // Decoding is fed from this queue directly — see
            // `MacNativeVideoRenderer` for why not the main thread.
            case MacNativeStreamProtocol.FrameType.formatDescription.rawValue:
                renderer.setFormatDescription(frame.payload)
            case MacNativeStreamProtocol.FrameType.videoFrame.rawValue:
                if let videoFrame = MacNativeStreamProtocol.decodeVideoFrame(frame.payload) {
                    renderer.enqueue(videoFrame)
                }
            case MacNativeStreamProtocol.FrameType.windowFormatDescription.rawValue:
                if let format = MacNativeStreamProtocol.decodeWindowFormatDescription(frame.payload),
                   let target = renderer(for: format.windowID) {
                    target.setFormatDescription(format.data, kind: format.kind)
                }
            case MacNativeStreamProtocol.FrameType.windowVideoFrame.rawValue:
                if let decoded = MacNativeStreamProtocol.decodeWindowVideoFrame(frame.payload) {
                    // Acknowledged on arrival, before decoding, so the host
                    // measures the link and paces the stream by it.
                    if decoded.windowID == MacNativeStreamProtocol.desktopStreamID {
                        send(MacNativeStreamProtocol.encodeFrameAck(
                            windowID: decoded.windowID,
                            sequence: decoded.frame.sequence
                        ))
                    }
                    renderer(for: decoded.windowID)?.enqueue(decoded.frame)
                }
            case MacNativeStreamProtocol.FrameType.windowList.rawValue:
                if let windows = MacNativeStreamProtocol.decodeWindowInventory(frame.payload) {
                    onEvent?(.inventory(windows))
                }
            case MacNativeStreamProtocol.FrameType.displayList.rawValue:
                if let list = MacNativeStreamProtocol.decodeDisplayList(frame.payload) {
                    onEvent?(.displays(list))
                }
            case MacNativeStreamProtocol.FrameType.windowClosed.rawValue:
                if let closed = MacNativeStreamProtocol.decodeWindowClosed(frame.payload) {
                    onEvent?(.windowClosed(closed.windowID, closed.reason))
                }
            case MacNativeStreamProtocol.FrameType.mouseStatus.rawValue:
                onEvent?(.mouseAvailability(Self.decodeRemoteControlStatus(frame.payload)))
            case MacNativeStreamProtocol.FrameType.keyboardStatus.rawValue:
                onEvent?(.keyboardAvailability(Self.decodeRemoteControlStatus(frame.payload)))
            case MacNativeStreamProtocol.FrameType.replaced.rawValue:
                let replacement = String(data: frame.payload, encoding: .utf8) ?? "another viewer"
                onEvent?(.replaced(replacement))
                connection?.cancel()
            case MacNativeStreamProtocol.FrameType.error.rawValue:
                let message = String(data: frame.payload, encoding: .utf8) ?? "The Mac rejected the stream."
                emitClosed(message)
            default:
                break
            }
        }
    }

    /// The renderer for a multiplexed stream — the shared desktop renderer
    /// for `desktopStreamID`, a registered per-window renderer otherwise.
    private func renderer(for windowID: UInt32) -> MacNativeVideoRenderer? {
        if windowID == MacNativeStreamProtocol.desktopStreamID {
            return renderer
        }
        return windowRenderers[windowID]
    }

    private func emitClosed(_ message: String?) {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        renderer.reset()
        onEvent?(.closed(message))
    }

    private static func decodeRemoteControlStatus(_ payload: Data) -> Event.RemoteControlAvailability {
        let raw = payload.first ?? MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
        switch MacNativeStreamProtocol.RemoteControlStatus(rawValue: raw) {
        case .available: return .available
        case .accessibilityDenied: return .accessibilityDenied
        case .disabled, nil: return .disabled
        }
    }
}
