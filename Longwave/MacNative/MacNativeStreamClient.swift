#if os(visionOS)
import Foundation
import Network

final class MacNativeStreamClient: @unchecked Sendable {
    struct Config: Sendable {
        let host: String
        let port: UInt16
        let token: String
        let deviceName: String
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
        label: "com.illixion.Longwave.mac-native.client",
        qos: .userInteractive
    )
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var inbound = Data()
    private nonisolated(unsafe) var closed = false
    /// Per-window renderers (v2 multiplexed streams), keyed by stream ID.
    /// The desktop stream (`desktopStreamID`) always routes to `renderer`.
    /// Only touched on `queue`.
    private nonisolated(unsafe) var windowRenderers: [UInt32: MacNativeVideoRenderer] = [:]

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
        guard !config.token.isEmpty,
              let port = NWEndpoint.Port(rawValue: config.port) else {
            onEvent?(.closed("The companion token or port is invalid."))
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: port,
            using: MacNativeStreamCrypto.tlsTCPParameters(token: config.token)
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(MacNativeStreamProtocol.encodeHello(deviceName: self.config.deviceName))
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
            connection?.cancel()
            connection = nil
            DispatchQueue.main.async { [renderer] in
                renderer.reset()
            }
        }
    }

    // MARK: - Remote control (mouse/keyboard)

    func sendMouseMove(x: UInt16, y: UInt16) {
        send(MacNativeStreamProtocol.encodeMouseMove(x: x, y: y))
    }

    func sendMouseDown(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        send(MacNativeStreamProtocol.encodeMouseButton(.mouseDown, button: button, x: x, y: y))
    }

    func sendMouseUp(button: MacNativeStreamProtocol.MouseButton, x: UInt16, y: UInt16) {
        send(MacNativeStreamProtocol.encodeMouseButton(.mouseUp, button: button, x: x, y: y))
    }

    func sendScroll(x: UInt16, y: UInt16, deltaX: Int16, deltaY: Int16) {
        send(MacNativeStreamProtocol.encodeScroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY))
    }

    func sendKeyDown(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        send(MacNativeStreamProtocol.encodeKeyEvent(.keyDown, keyCode: keyCode, modifiers: modifiers))
    }

    func sendKeyUp(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        send(MacNativeStreamProtocol.encodeKeyEvent(.keyUp, keyCode: keyCode, modifiers: modifiers))
    }

    // MARK: - v2 multiplexed streams

    /// Registers (or, with nil, removes) the renderer that receives a window
    /// stream's format/video frames.
    func setWindowRenderer(_ renderer: MacNativeVideoRenderer?, for windowID: UInt32) {
        queue.async { [self] in
            if let renderer {
                windowRenderers[windowID] = renderer
            } else {
                windowRenderers[windowID] = nil
            }
        }
    }

    func sendWindowStreamStart(windowID: UInt32) {
        send(MacNativeStreamProtocol.encodeWindowID(.windowStreamStart, windowID: windowID))
    }

    func sendWindowStreamStop(windowID: UInt32) {
        send(MacNativeStreamProtocol.encodeWindowID(.windowStreamStop, windowID: windowID))
    }

    func sendFocusWindow(windowID: UInt32) {
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
            case MacNativeStreamProtocol.FrameType.formatDescription.rawValue:
                DispatchQueue.main.async { [renderer, payload = frame.payload] in
                    renderer.setFormatDescription(payload)
                }
            case MacNativeStreamProtocol.FrameType.videoFrame.rawValue:
                if let videoFrame = MacNativeStreamProtocol.decodeVideoFrame(frame.payload) {
                    DispatchQueue.main.async { [renderer] in
                        renderer.enqueue(videoFrame)
                    }
                }
            case MacNativeStreamProtocol.FrameType.windowFormatDescription.rawValue:
                if let format = MacNativeStreamProtocol.decodeWindowFormatDescription(frame.payload),
                   let target = renderer(for: format.windowID) {
                    DispatchQueue.main.async {
                        target.setFormatDescription(format.data, kind: format.kind)
                    }
                }
            case MacNativeStreamProtocol.FrameType.windowVideoFrame.rawValue:
                if let decoded = MacNativeStreamProtocol.decodeWindowVideoFrame(frame.payload),
                   let target = renderer(for: decoded.windowID) {
                    DispatchQueue.main.async {
                        target.enqueue(decoded.frame)
                    }
                }
            case MacNativeStreamProtocol.FrameType.windowList.rawValue:
                if let windows = MacNativeStreamProtocol.decodeWindowInventory(frame.payload) {
                    onEvent?(.inventory(windows))
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
        DispatchQueue.main.async { [renderer] in
            renderer.reset()
        }
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
#endif
