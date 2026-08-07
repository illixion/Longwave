import Foundation

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

        do {
            self.server = server
            try server.start()
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
