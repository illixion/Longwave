import CoreVideo
import CryptoKit
import DebugTrace
import Foundation
import Network

/// The Apple Watch's any-route lane (`WatchLinkProtocol`): a minimal HTTP/1.1
/// server that long-polls desktop stills. The watch reaches it through
/// `URLSession`, which watchOS may route over the paired iPhone — the only
/// networking a watch app gets outside an audio session.
///
/// A watch has no persistent connection here, so "a watch is watching" means
/// "a still was requested in the last `idleSeconds`" — `onActiveChanged`
/// reports that, and the controller runs the desktop capture for it.
nonisolated final class MacWatchServer: @unchecked Sendable {
    var onActiveChanged: (@Sendable (Bool) -> Void)?

    private let port: UInt16
    /// A watch speaks with its iPhone's device key, so the server tries every
    /// device allowed the screen.
    private let keyring: CompanionKeyring
    private let queue = DispatchQueue(label: "pro.longwave.companion.watch-server", qos: .userInitiated)
    private let encodeQueue = DispatchQueue(label: "pro.longwave.companion.watch-stills", qos: .userInitiated)
    private let encoder = MacNativeStillEncoder()
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "MacWatchServer")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The newest captured frame and its number. A request whose `after` is
    /// older is answered at once; otherwise it waits for the next frame.
    private var latest: CVPixelBuffer?
    private var sequence: UInt64 = 0
    private var waiting: [PendingStill] = []
    /// Nonces seen inside the clock-skew window, for replay rejection.
    private var seenNonces: [String: Date] = [:]
    private var lastRequest: Date?
    private var active = false

    private static let idleSeconds: TimeInterval = 15
    private static let maxRequestBytes = 16 * 1024

    private struct PendingStill {
        let connection: NWConnection
        let viewport: WatchLinkProtocol.Viewport
        let nonce: String
        let key: SymmetricKey
        let deadline: Date
    }

    init(port: UInt16 = WatchLinkProtocol.defaultPort, keyring: CompanionKeyring) {
        self.port = port
        self.keyring = keyring
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.error("Watch listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        scheduleSweep()
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.cancel() }
            connections = [:]
            waiting = []
            latest = nil
            setActive(false)
        }
    }

    /// A new desktop frame. Wakes every waiting request.
    func offer(_ buffer: CVPixelBuffer) {
        queue.async { [self] in
            guard active else { return }
            latest = buffer
            sequence &+= 1
            let ready = waiting
            waiting = []
            for pending in ready {
                respond(pending.connection, viewport: pending.viewport, nonce: pending.nonce, key: pending.key)
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.connections[id] = nil
                    self?.waiting.removeAll { $0.connection === connection }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[..<end.lowerBound]
                let rest = Data(buffer[end.upperBound...])
                self.handle(head: head, on: connection)
                // GETs carry no body, so whatever follows is the next request.
                if !isComplete, error == nil { self.readRequest(on: connection, buffer: rest) }
            } else if buffer.count > Self.maxRequestBytes || isComplete || error != nil {
                connection.cancel()
            } else {
                self.readRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(head: Data, on connection: NWConnection) {
        guard let text = String(data: head, encoding: .utf8) else { return reply(connection, status: 400) }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count == 3 else { return reply(connection, status: 400) }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard let authorization = headers["authorization"].flatMap(WatchLinkProtocol.Authorization.init(headerValue:)),
              let key = keyring.entries(with: .screen).lazy
                .map({ WatchLinkProtocol.key(token: $0.credential.token) })
                .first(where: { WatchLinkProtocol.verify(authorization, method: method, target: target, key: $0) }),
              seenNonces[authorization.nonce] == nil else {
            return reply(connection, status: 401)
        }
        seenNonces[authorization.nonce] = Date()

        guard method == "GET", let components = URLComponents(string: target) else {
            return reply(connection, status: 404)
        }
        switch components.path {
        case WatchLinkProtocol.stillPath:
            let query = Dictionary(
                (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            guard let viewport = WatchLinkProtocol.Viewport(query: query) else { return reply(connection, status: 400) }
            let after = query["after"].flatMap(UInt64.init) ?? 0
            lastRequest = Date()
            setActive(true)
            if latest != nil, after < sequence {
                respond(connection, viewport: viewport, nonce: authorization.nonce, key: key)
            } else {
                waiting.append(PendingStill(
                    connection: connection,
                    viewport: viewport,
                    nonce: authorization.nonce,
                    key: key,
                    deadline: Date().addingTimeInterval(WatchLinkProtocol.longPollSeconds)
                ))
            }
        default:
            reply(connection, status: 404)
        }
    }

    private func respond(_ connection: NWConnection, viewport: WatchLinkProtocol.Viewport, nonce: String, key: SymmetricKey) {
        guard let buffer = latest else { return reply(connection, status: 204) }
        let sequence = sequence
        encodeQueue.async { [self] in
            guard let jpeg = encoder.encode(buffer, viewport: viewport.stillViewport) else {
                return queue.async { self.reply(connection, status: 500) }
            }
            let still = WatchLinkProtocol.Still(
                sequence: sequence,
                sourceWidth: CVPixelBufferGetWidth(buffer),
                sourceHeight: CVPixelBufferGetHeight(buffer),
                jpeg: jpeg
            )
            let body = WatchLinkProtocol.seal(still.encoded(), nonce: nonce, key: key)
            queue.async { self.reply(connection, status: body == nil ? 500 : 200, body: body ?? Data()) }
        }
    }

    private func reply(_ connection: NWConnection, status: Int, body: Data = Data()) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 500: "Internal Server Error"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/octet-stream\r\n" }
        head += "Cache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in })
    }

    // MARK: - Housekeeping

    private func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if !value { latest = nil }
        log.info("Watch viewer \(value ? "active" : "idle", privacy: .public)")
        onActiveChanged?(value)
    }

    /// Answers expired long-polls with 204, forgets old nonces, and goes idle
    /// once no watch has asked for a while.
    private func scheduleSweep() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.listener != nil else { return }
            let now = Date()
            let expired = self.waiting.filter { $0.deadline <= now }
            self.waiting.removeAll { $0.deadline <= now }
            for pending in expired { self.reply(pending.connection, status: 204) }
            let window = TimeInterval(WatchLinkProtocol.maxClockSkewMilliseconds) / 1000 * 2
            self.seenNonces = self.seenNonces.filter { now.timeIntervalSince($0.value) < window }
            if self.active, self.waiting.isEmpty,
               now.timeIntervalSince(self.lastRequest ?? .distantPast) > Self.idleSeconds {
                self.setActive(false)
            }
            self.scheduleSweep()
        }
    }
}
