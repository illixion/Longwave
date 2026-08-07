import Foundation
import Network
import os

/// Authenticated newest-client-wins server for the native Mac stream. A new
/// client replaces the active viewer only after completing TLS and sending its
/// hello, so an unauthenticated socket cannot kick off the current user.
final class MacNativeStreamServer: @unchecked Sendable {
    nonisolated(unsafe) var onClientActivated:
        (@Sendable (_ deviceName: String, _ replacedDeviceName: String?) -> Void)?
    nonisolated(unsafe) var onClientDisconnected: (@Sendable () -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?

    private static let maxPendingBytes = 12 * 1024 * 1024

    private nonisolated final class Client: @unchecked Sendable {
        let connection: NWConnection
        var inbound = Data()
        var deviceName: String?
        var pendingBytes = 0
        var awaitingKeyFrame = true

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(
        label: "com.illixion.VisionVNCCompanion.mac-native.server",
        qos: .userInteractive
    )
    private let log = Logger(
        subsystem: "com.illixion.VisionVNCCompanion",
        category: "MacNativeStreamServer"
    )

    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var activeClient: Client?
    private nonisolated(unsafe) var pendingClient: Client?
    private nonisolated(unsafe) var currentFormatFrame: Data?
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
            name: Host.current().localizedName ?? "VisionVNC Mac",
            type: "_visionvnc-native._tcp"
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
            currentFormatFrame = nil
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in
                guard stopCompletion != nil else { return }
                finishStop()
            }
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

    nonisolated func broadcastFormatDescription(_ data: Data) {
        let frame = MacNativeStreamProtocol.encodeFrame(.formatDescription, data)
        queue.async { [self] in
            currentFormatFrame = frame
            activeClient?.awaitingKeyFrame = true
            sendRequired(frame, to: activeClient)
        }
    }

    nonisolated func broadcastFrame(
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) {
        let frame = MacNativeStreamProtocol.encodeVideoFrame(
            data,
            isKeyFrame: isKeyFrame,
            sequence: sequence,
            timestampNanoseconds: timestampNanoseconds
        )
        queue.async { [self] in
            guard let client = activeClient,
                  client.pendingBytes < Self.maxPendingBytes else {
                return
            }
            if client.awaitingKeyFrame {
                guard isKeyFrame else { return }
                client.awaitingKeyFrame = false
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
                promote(client, deviceName: hello.deviceName)
            case MacNativeStreamProtocol.FrameType.keepAlive.rawValue:
                break
            default:
                break
            }
        }
    }

    private nonisolated func promote(_ client: Client, deviceName: String) {
        guard pendingClient === client || activeClient === client else { return }
        if activeClient === client { return }

        let previous = activeClient
        let previousName = previous?.deviceName
        client.deviceName = deviceName
        client.awaitingKeyFrame = true
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

        sendRequired(MacNativeStreamProtocol.encodeFrame(.helloAck), to: client)
        if let currentFormatFrame {
            sendRequired(currentFormatFrame, to: client)
        }
        onClientActivated?(deviceName, previousName)
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
