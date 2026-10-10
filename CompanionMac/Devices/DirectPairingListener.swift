import DebugTrace
import Foundation
import Network

/// The fixed pairing port (`CompanionPairLink.defaultPort`) a headset dials
/// when it can't see this Mac over Bonjour — after opening the address link
/// the Mac AirDropped or copied to it. Plain TCP: the six-digit exchange that
/// runs on it protects everything, exactly as on the Bonjour-found listener.
///
/// It listens only while connections by address are allowed, or for ten
/// minutes after an address link was sent.
@MainActor
final class DirectPairingListener {
    var onConnection: ((NWConnection) -> Void)?
    private(set) var isListening = false
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pro.longwave.companion.direct-pairing")
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "Pairing")

    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        if listening { open() } else { close() }
    }

    private func open() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: CompanionPairLink.defaultPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, let onConnection = self.onConnection else { connection.cancel(); return }
                    onConnection(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor [weak self] in
                        self?.log.error("Direct pairing listener failed: \(error.localizedDescription, privacy: .public)")
                        self?.close()
                        self?.isListening = false
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            log.info("Direct pairing port open")
        } catch {
            log.error("Couldn't open the direct pairing port: \(error.localizedDescription, privacy: .public)")
            isListening = false
        }
    }

    private func close() {
        listener?.cancel()
        listener = nil
    }
}
