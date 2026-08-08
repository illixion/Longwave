import Foundation
import CoreGraphics

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

    private(set) var connectedDeviceName: String?
    private(set) var lastError: String?
    private(set) var isCapturing = false

    /// Mouse/keyboard remote control for the Screen stream — see
    /// `MacNativeInputService` for why it's a separate opt-in from Screen
    /// itself.
    let input = MacNativeInputService()

    /// Bridges `input.inputControlEnabled` so `NativePane` can bind through
    /// this controller and so toggling it immediately re-broadcasts
    /// availability to a connected client.
    var inputControlEnabled: Bool {
        get { input.inputControlEnabled }
        set {
            input.inputControlEnabled = newValue
            updateInputAvailability()
        }
    }

    /// Re-checks Accessibility and pushes the current availability to a live
    /// client. Safe to call repeatedly.
    func updateInputAvailability() {
        input.refreshAccessibility()
        server?.setInputAvailability(input.statusByte)
    }

    /// Prompts for Accessibility, then refreshes the live channel's availability.
    func grantInputAccessibility() {
        input.promptAccessibility()
        server?.setInputAvailability(input.statusByte)
    }

    /// The captured display's frame in global (point-space) coordinates —
    /// used to translate a stream-space (x, y) from the viewer into a real
    /// `CGEvent` screen position.
    private var displayFrame: CGRect = .zero

    private func globalPoint(x: UInt16, y: UInt16) -> CGPoint {
        CGPoint(x: displayFrame.origin.x + CGFloat(x), y: displayFrame.origin.y + CGFloat(y))
    }

    var statusText: String {
        if let connectedDeviceName {
            return "Streaming to \(connectedDeviceName)"
        }
        return enabled ? "Listening on port \(port)" : "Disabled"
    }

    private var token = ""
    private var server: MacNativeStreamServer?
    private var capture: MacNativeScreenCapture?
    private var captureGeneration = 0
    private var serverGeneration = 0

    init() {
        _ = MacNativeStreamNotifications.shared
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
        connectedDeviceName = nil
        stopCapture()

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
        server.onClientActivated = { [weak self] deviceName, replacedName in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.connectedDeviceName = deviceName
                MacNativeStreamNotifications.shared.connected(
                    deviceName: deviceName,
                    replacedDeviceName: replacedName
                )
                if self.capture == nil {
                    self.startCapture()
                }
            }
        }
        server.onClientDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.serverGeneration == generation else { return }
                self.connectedDeviceName = nil
                self.stopCapture()
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

        do {
            self.server = server
            try server.start()
            server.setInputAvailability(input.statusByte)
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
        connectedDeviceName = nil
        stopCapture()
    }

    private func startCapture() {
        captureGeneration += 1
        let generation = captureGeneration
        let capture = MacNativeScreenCapture()
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
                self.server?.disconnectActive(withError: message)
                self.stopCapture()
            }
        }
        capture.onDisplayFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, generation == self.captureGeneration else { return }
                self.displayFrame = frame
            }
        }
        self.capture = capture

        Task {
            do {
                try await capture.start()
                guard generation == captureGeneration else {
                    await capture.stop()
                    return
                }
                isCapturing = true
            } catch {
                guard generation == captureGeneration else { return }
                self.capture = nil
                isCapturing = false
                lastError = error.localizedDescription
                server?.disconnectActive(withError: error.localizedDescription)
            }
        }
    }

    private func stopCapture() {
        captureGeneration += 1
        let capture = self.capture
        self.capture = nil
        isCapturing = false
        Task {
            await capture?.stop()
        }
    }
}
