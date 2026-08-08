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
        case connected
        case format(CGSize)
        case firstFrame
        case closed(String?)
        case replaced(String)
        /// The companion's current mouse/keyboard availability — pushed on
        /// connect and whenever the Mac's toggle or Accessibility grant
        /// changes.
        case inputAvailability(InputAvailability)

        enum InputAvailability: Sendable {
            case available
            case disabled
            case accessibilityDenied
        }
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let config: Config
    private let renderer: MacNativeVideoRenderer
    private let queue = DispatchQueue(
        label: "com.illixion.VisionVNC.mac-native.client",
        qos: .userInteractive
    )
    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var inbound = Data()
    private nonisolated(unsafe) var closed = false

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
                onEvent?(.connected)
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
            case MacNativeStreamProtocol.FrameType.inputStatus.rawValue:
                let raw = frame.payload.first ?? MacNativeStreamProtocol.InputStatus.disabled.rawValue
                let availability: Event.InputAvailability
                switch MacNativeStreamProtocol.InputStatus(rawValue: raw) {
                case .available: availability = .available
                case .accessibilityDenied: availability = .accessibilityDenied
                case .disabled, nil: availability = .disabled
                }
                onEvent?(.inputAvailability(availability))
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
}
#endif
