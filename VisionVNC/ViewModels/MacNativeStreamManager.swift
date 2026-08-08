#if os(visionOS)
import Foundation
import AVFoundation
import UIKit

@Observable
final class MacNativeStreamManager {
    enum State: Equatable {
        case disconnected(String?)
        case connecting
        case connected
        case streaming

        var statusText: String {
            switch self {
            case .disconnected(let message): message ?? "Disconnected"
            case .connecting: "Connecting to Mac…"
            case .connected: "Waiting for the first frame…"
            case .streaming: "Streaming"
            }
        }
    }

    private(set) var state: State = .disconnected(nil)
    private(set) var displayLayer: AVSampleBufferDisplayLayer?
    private(set) var streamSize: CGSize = .zero
    private(set) var title = "Native Screen"

    private var client: MacNativeStreamClient?
    private var activeConnectionID: UUID?

    func connect(to connection: SavedConnection) {
        disconnect()
        let connectionID = UUID()
        activeConnectionID = connectionID
        title = connection.displayName
        state = .connecting

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        layer.isOpaque = false
        displayLayer = layer

        let renderer = MacNativeVideoRenderer(displayLayer: layer)
        let client = MacNativeStreamClient(
            config: .init(
                host: connection.hostname,
                port: MacNativeStreamProtocol.defaultPort,
                token: connection.companionToken,
                deviceName: UIDevice.current.name
            ),
            renderer: renderer
        )
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, connectionID: connectionID)
            }
        }
        self.client = client
        client.start()
    }

    func disconnect() {
        activeConnectionID = nil
        let oldClient = client
        client = nil
        oldClient?.close()
        displayLayer = nil
        streamSize = .zero
        if case .disconnected = state {
            return
        }
        state = .disconnected(nil)
    }

    private func handle(_ event: MacNativeStreamClient.Event, connectionID: UUID) {
        guard activeConnectionID == connectionID else { return }
        switch event {
        case .connected:
            state = .connected
        case .format(let size):
            streamSize = size
        case .firstFrame:
            state = .streaming
        case .replaced(let deviceName):
            state = .disconnected("Replaced by \(deviceName).")
            activeConnectionID = nil
            client = nil
        case .closed(let message):
            if case .disconnected(let existing) = state, existing != nil {
                return
            }
            state = .disconnected(message)
            activeConnectionID = nil
            client = nil
        }
    }
}
#endif
