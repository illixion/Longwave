import Foundation
import Network
import os

/// TCP server that streams interleaved signed int24 PCM to the connected
/// Longwave client. Sends the AudioStreamHeader on accept, then
/// length-prefixed frames (see AudioStreamProtocol).
///
/// Only one client may be connected at a time (security measure):
/// a new connection displaces any existing one (newest wins), which also
/// lets the Vision Pro reconnect past a stale half-open socket. A slow
/// client that falls more than `maxPendingBytes` behind has frames
/// dropped (latency cap) rather than queueing unbounded.
final class AudioStreamServer: @unchecked Sendable {

    /// ~0.7 s of 48 kHz stereo int24 — beyond this a client is lagging
    /// badly and queueing more would only grow its latency.
    private static let maxPendingBytes = 200_000

    nonisolated(unsafe) var onClientCountChange: (@Sendable (Int) -> Void)?
    /// Media transport command received from the client (fires on `queue`).
    nonisolated(unsafe) var onCommand: (@Sendable (MediaCommand) -> Void)?

    private final class Client {
        let connection: NWConnection
        var pendingBytes = 0
        /// TLS-PSK handshake completed — the peer is authenticated and counted
        /// as a connected client, but the header may not be sent yet (it's
        /// supplied lazily once the audio tap starts; see `provideHeader`).
        var ready = false
        var headerSent = false
        /// Buffer for inbound frames (commands, udpHello) from the client.
        var inbound = Data()
        /// Low-latency UDP return path, established once the client sends a
        /// valid `udpHello` datagram. When set, PCM is sent here instead of
        /// over `connection` (TCP). nil → PCM rides TCP as before.
        var udp: NWConnection?
        /// One-shot guard so a persistent UDP send failure logs once, not
        /// hundreds of times per second.
        var udpErrorLogged = false
        /// Set whenever a PCM frame is sent to this client; cleared on each
        /// keepalive tick. Gates the silence heartbeat so the beat is sent
        /// only while the source is actually silent (no PCM this interval).
        var sentPCMSinceBeat = false
        init(connection: NWConnection) { self.connection = connection }
    }

    private let port: UInt16
    private let token: String
    /// Stream header (sample rate / channel count), supplied lazily by the
    /// controller once the audio tap starts on the first client connecting —
    /// the tap (and thus the format) doesn't exist while idle. Mutated only
    /// on `queue`.
    private nonisolated(unsafe) var header: AudioStreamHeader?
    private let queue = DispatchQueue(label: "pro.longwave.companion.server", qos: .userInteractive)
    private nonisolated(unsafe) var listener: NWListener?
    private nonisolated(unsafe) var clients: [ObjectIdentifier: Client] = [:]
    /// Heartbeat for the UDP/DTLS path so the receiver sees liveness during
    /// silence (no audio → no PCM datagrams). Runs on `queue`.
    private nonisolated(unsafe) var keepAliveTimer: DispatchSourceTimer?
    private static let keepAliveFrame = AudioStreamProtocol.encodeFrame(.keepAlive, Data())

    private let log = Logger(subsystem: "pro.longwave.companion", category: "AudioStreamServer")

    /// Latest pre-encoded metadata frames, replayed to newly connected
    /// clients right after the header. Mutated only on `queue`.
    private nonisolated(unsafe) var currentNowPlayingFrame: Data?
    private nonisolated(unsafe) var currentArtworkFrame: Data?

    nonisolated init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    nonisolated func start() throws {
        let listener = try NWListener(
            using: AudioCrypto.tlsTCPParameters(token: token),
            on: NWEndpoint.Port(rawValue: port)!
        )
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        // Heartbeat so a silent source still proves liveness. The source now
        // suppresses silent PCM (see SystemAudioTap), so without a beat a
        // quiet-but-live connection would look dead to the receiver's health
        // probe and trigger a needless reconnect (which, in the receiver's
        // Music mode, re-asserts an exclusive audio session and interrupts
        // whatever else the device is playing). Beat only while silent — when
        // PCM is flowing it already proves liveness — on whichever path the
        // client uses (UDP datagram, else the TCP stream).
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.headerSent {
                let silent = !client.sentPCMSinceBeat
                client.sentPCMSinceBeat = false
                guard silent else { continue }
                if let udp = client.udp {
                    udp.send(content: Self.keepAliveFrame, completion: .contentProcessed { _ in })
                } else {
                    client.connection.send(content: Self.keepAliveFrame, completion: .contentProcessed { _ in })
                }
            }
        }
        timer.resume()
        keepAliveTimer = timer
    }

    nonisolated func stop() {
        queue.async { [self] in
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            listener?.cancel()
            listener = nil
            for client in clients.values {
                client.connection.cancel()
                client.udp?.cancel()
            }
            clients.removeAll()
            notifyClientCount()
        }
    }

    /// Publishes new now-playing metadata. Pre-encoded frames are stored
    /// for replay-on-connect and sent to the connected client immediately.
    /// Metadata frames bypass the PCM latency cap — they're rare and must
    /// not be dropped. Pass a nil artwork frame when artwork is unchanged;
    /// pass nil info to clear (e.g. Music quit).
    nonisolated func updateMetadata(infoFrame: Data?, artworkFrame: Data?) {
        queue.async { [self] in
            if let artworkFrame {
                currentArtworkFrame = artworkFrame
            } else if infoFrame == nil {
                currentArtworkFrame = nil
            }
            currentNowPlayingFrame = infoFrame
            for client in clients.values where client.headerSent {
                if let artworkFrame {
                    client.connection.send(content: artworkFrame, completion: .contentProcessed { _ in })
                }
                if let infoFrame {
                    client.connection.send(content: infoFrame, completion: .contentProcessed { _ in })
                }
            }
        }
    }

    /// Called from the Core Audio realtime thread — hops to the server
    /// queue immediately, keeping the audio callback non-blocking.
    nonisolated func broadcast(_ pcm: Data) {
        queue.async { [self] in
            guard !clients.isEmpty else { return }
            let frame = AudioStreamProtocol.encodeFrame(pcm)
            // Built lazily only if a UDP (DTLS) client is connected.
            var udpFrames: [Data]?
            for client in clients.values where client.headerSent {
                client.sentPCMSinceBeat = true
                if let udp = client.udp {
                    // Low-latency path: DTLS won't fragment one application
                    // record across datagrams, so a full ~4 KB PCM blob would
                    // exceed the path MTU and be dropped. Split it into
                    // datagram-sized, sample-frame-aligned `pcm` frames — the
                    // receiver just schedules whatever samples arrive. No
                    // backpressure accounting: the OS drops if it can't keep
                    // up, which is the desired latency-over-reliability trade.
                    if udpFrames == nil {
                        udpFrames = Self.chunkPCMForDatagram(pcm, channelCount: header?.channelCount ?? 2)
                    }
                    for datagram in udpFrames! {
                        udp.send(content: datagram, completion: .contentProcessed { [weak self, weak client] error in
                            guard let error, let client, !client.udpErrorLogged else { return }
                            client.udpErrorLogged = true
                            self?.log.error("UDP datagram send failed (\(datagram.count) bytes): \(String(describing: error))")
                        })
                    }
                    continue
                }
                // Latency cap: drop frames for clients that can't keep up
                guard client.pendingBytes < Self.maxPendingBytes else { continue }
                client.pendingBytes += frame.count
                client.connection.send(content: frame, completion: .contentProcessed { [weak self, weak client] _ in
                    self?.queue.async { client?.pendingBytes -= frame.count }
                })
            }
        }
    }

    /// Conservative single-datagram PCM payload budget for the DTLS path:
    /// path MTU (~1500) minus IP/UDP and DTLS record overhead, with margin.
    private static let maxUDPPCMPayload = 1100

    /// Splits an interleaved int24 PCM blob into `pcm` frames that each fit
    /// one DTLS datagram. Chunks are aligned to a whole sample-frame boundary
    /// (channelCount × 3 bytes) so each datagram is independently schedulable
    /// PCM on the receiver — no reassembly required.
    private nonisolated static func chunkPCMForDatagram(_ pcm: Data, channelCount: Int) -> [Data] {
        let bytesPerSampleFrame = max(1, channelCount * AudioStreamProtocol.bytesPerSample)
        let maxChunk = max(bytesPerSampleFrame, (maxUDPPCMPayload / bytesPerSampleFrame) * bytesPerSampleFrame)
        if pcm.count <= maxChunk {
            return [AudioStreamProtocol.encodeFrame(pcm)]
        }
        var frames: [Data] = []
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(pcm.index(offset, offsetBy: maxChunk, limitedBy: pcm.endIndex) ?? pcm.endIndex, pcm.endIndex)
            frames.append(AudioStreamProtocol.encodeFrame(pcm.subdata(in: offset..<end)))
            offset = end
        }
        return frames
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private nonisolated func accept(_ connection: NWConnection) {
        // Newest wins: displace any existing client so only one is ever
        // connected. Cancelling fires their .cancelled handlers, but the
        // dict is already cleared so remove() is a no-op for them.
        for old in clients.values {
            old.connection.cancel()
        }
        clients.removeAll()

        let client = Client(connection: connection)
        clients[ObjectIdentifier(connection)] = client

        log.info("Client connecting from \(String(describing: connection.endpoint)) — starting TLS-PSK handshake")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // TLS-PSK handshake succeeded → the peer holds the token.
                // Mark it connected; there is no app-layer auth. The header is
                // sent once the controller starts the tap and calls
                // `provideHeader` (the tap only runs while a client is present).
                self.log.info("TLS-PSK handshake ready — client connected")
                self.markReady(client)
            case .waiting(let error):
                self.log.error("Client connection waiting: \(String(describing: error))")
            case .failed(let error):
                self.log.error("Client connection failed: \(String(describing: error))")
                self.remove(connection)
            case .cancelled:
                self.remove(connection)
            default:
                break
            }
        }

        // Receive loop: parses inbound command frames and detects remote close
        receiveLoop(client)
        connection.start(queue: queue)
    }

    /// Opens the outbound low-latency UDP path to a client that advertised a
    /// listener port via a `udpHello` frame (over TCP). The receiver's IP is
    /// taken from its TCP connection; PCM then flows to (that IP, `udpPort`).
    /// Runs on `queue`.
    private nonisolated func attachUDP(_ client: Client, udpPort: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: udpPort) else {
            log.error("udpHello: invalid UDP port \(udpPort)")
            return
        }
        guard let host = remoteHost(of: client.connection) else {
            log.error("udpHello: could not resolve client IP from TCP connection")
            return
        }
        let udp = NWConnection(host: host, port: port, using: AudioCrypto.dtlsUDPParameters(token: token))
        client.udp?.cancel()
        client.udp = udp
        udp.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("Low-latency UDP attached → \(String(describing: host)):\(udpPort)")
            case .failed(let error):
                self?.log.error("UDP path failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    /// Extracts the peer IP host from a connection's remote endpoint.
    private nonisolated func remoteHost(of connection: NWConnection) -> NWEndpoint.Host? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case let .hostPort(host, _) = endpoint { return host }
        return nil
    }

    private nonisolated func receiveLoop(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.inbound.append(data)
                self.processInbound(client)
            }
            if isComplete || error != nil {
                self.remove(client.connection)
            } else {
                self.receiveLoop(client)
            }
        }
    }

    /// Parses typed frames from the client. Only `command` and `udpHello`
    /// frames are meaningful; unknown types are skipped. Runs on `queue`.
    private nonisolated func processInbound(_ client: Client) {
        while let length = AudioStreamProtocol.decodeFrameLength(client.inbound) {
            guard length >= 1, length <= AudioStreamProtocol.maxFrameBytes else {
                // Malformed stream — drop the client
                remove(client.connection)
                return
            }
            let frameEnd = AudioStreamProtocol.frameLengthPrefixSize + Int(length)
            guard client.inbound.count >= frameEnd else { return }

            let start = client.inbound.startIndex
            let type = client.inbound[start + AudioStreamProtocol.frameLengthPrefixSize]
            let payload = client.inbound.subdata(
                in: start.advanced(by: AudioStreamProtocol.frameLengthPrefixSize + 1)..<start.advanced(by: frameEnd)
            )
            client.inbound.removeFirst(frameEnd)

            if type == AudioStreamProtocol.FrameType.command.rawValue,
               let message = MediaCommandMessage.decode(payload) {
                onCommand?(message.command)
            } else if type == AudioStreamProtocol.FrameType.udpHello.rawValue {
                guard payload.count == 2 else {
                    log.error("udpHello: bad payload (\(payload.count) bytes)")
                    continue
                }
                let udpPort = UInt16(payload[payload.startIndex]) | (UInt16(payload[payload.startIndex + 1]) << 8)
                log.info("udpHello: client requests low-latency UDP on port \(udpPort)")
                attachUDP(client, udpPort: udpPort)
            }
        }
    }

    /// Marks the client as connected (TLS ready) and notifies the count so the
    /// controller can spin up the audio tap. The header is not sent yet — it's
    /// deferred until `provideHeader` arrives with the tap's format. If the tap
    /// is already running (a header is on hand, e.g. a reconnect while another
    /// client was present), send it right away. Runs on `queue`.
    private nonisolated func markReady(_ client: Client) {
        guard !client.ready else { return }
        client.ready = true
        notifyClientCount()
        if let header { sendHeader(header, to: client) }
    }

    /// Supplies the stream header once the controller has started the tap.
    /// Stores it for late-joining clients and flushes it to any connected
    /// client still awaiting one. Runs on `queue`.
    nonisolated func provideHeader(_ header: AudioStreamHeader) {
        queue.async { [self] in
            self.header = header
            for client in clients.values where client.ready && !client.headerSent {
                sendHeader(header, to: client)
            }
        }
    }

    /// Sends the header and replays the current now-playing state to a single
    /// connected client. Guarded against double-send. Runs on `queue`.
    private nonisolated func sendHeader(_ header: AudioStreamHeader, to client: Client) {
        guard client.ready, !client.headerSent else { return }
        client.connection.send(content: header.encoded(), completion: .contentProcessed { _ in })
        client.headerSent = true
        // Replay current now-playing state (artwork first so the receiver
        // can pair it with the info's artworkID).
        if let artwork = currentArtworkFrame {
            client.connection.send(content: artwork, completion: .contentProcessed { _ in })
        }
        if let info = currentNowPlayingFrame {
            client.connection.send(content: info, completion: .contentProcessed { _ in })
        }
    }

    private nonisolated func remove(_ connection: NWConnection) {
        guard let client = clients.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        client.udp?.cancel()
        client.udp = nil
        connection.cancel()
        notifyClientCount()
    }

    private nonisolated func notifyClientCount() {
        // Count TLS-ready clients (not header-sent): the controller starts the
        // tap in response, and the tap is what produces the header.
        let count = clients.values.filter(\.ready).count
        onClientCountChange?(count)
    }
}
