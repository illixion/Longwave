import Foundation
import Network
import Security
import CryptoKit

/// RTSP publishing client (ANNOUNCE/SETUP/RECORD) pushing interleaved RTP
/// over a single TCP connection to a mediamtx server — the broadcast
/// counterpart of `NvHTTPClient`'s hand-rolled HTTP. Supports Basic auth
/// (mediamtx's default `rtspAuthMethods`), sends periodic RTCP sender
/// reports for A/V sync and OPTIONS keepalives.
///
/// All socket work happens on a private serial queue; `sendVideo`/`sendAudio`
/// are safe to call from encoder callback threads.
final class RTSPPublisher: @unchecked Sendable {

    enum Event: Sendable {
        /// ANNOUNCE/SETUP/RECORD completed — media may now flow.
        case ready
        /// Terminal for this publisher instance; the manager decides
        /// whether to rebuild and retry.
        case failed(String)
    }

    nonisolated(unsafe) var onEvent: (@Sendable (Event) -> Void)?

    private let host: String
    private let port: UInt16
    private let path: String
    private let username: String?
    private let password: String?
    private let sdp: String
    /// When set, connects with RTSPS and accepts only the certificate whose
    /// DER SHA-256 matches (self-signed + pinning, like the Moonlight side).
    private let pinnedCertSHA256: Data?

    private let queue = DispatchQueue(label: "com.illixion.Longwave.rtsp-publish", qos: .userInteractive)

    private nonisolated(unsafe) var connection: NWConnection?
    private nonisolated(unsafe) var stopped = false
    private nonisolated(unsafe) var recording = false
    private nonisolated(unsafe) var cseq = 0
    private nonisolated(unsafe) var sessionID: String?
    private nonisolated(unsafe) var authorizationHeader: String?
    private nonisolated(unsafe) var receiveBuffer = Data()
    /// RTSP is sequential: responses are matched to requests in FIFO order.
    private nonisolated(unsafe) var pendingResponses: [(RTSPResponse) -> Void] = []
    private nonisolated(unsafe) var keepaliveTimer: DispatchSourceTimer?
    private nonisolated(unsafe) var rtcpTimer: DispatchSourceTimer?

    private nonisolated(unsafe) var videoPacketizer: H264Packetizer
    private nonisolated(unsafe) var audioPacketizer: OpusPacketizer
    private nonisolated(unsafe) var videoStats = TrackStats(clockRate: 90_000)
    private nonisolated(unsafe) var audioStats = TrackStats(clockRate: 48_000)

    private struct TrackStats {
        let clockRate: Double
        var packetCount: UInt32 = 0
        var octetCount: UInt32 = 0
        var lastRTPTimestamp: UInt32 = 0
        var lastSendUptimeNanos: UInt64 = 0
        var hasSent: Bool { lastSendUptimeNanos != 0 }
    }

    private struct RTSPResponse {
        let statusCode: Int
        let headers: [String: String]
    }

    nonisolated init(host: String, port: UInt16, path: String,
                     username: String?, password: String?, sdp: String,
                     pinnedCertSHA256: Data? = nil) {
        self.host = host
        self.port = port
        self.path = path
        self.username = username
        self.password = password
        self.sdp = sdp
        self.pinnedCertSHA256 = pinnedCertSHA256
        self.videoPacketizer = H264Packetizer(ssrc: UInt32.random(in: 1...UInt32.max),
                                              initialSequenceNumber: UInt16.random(in: 0...0x7FFF))
        self.audioPacketizer = OpusPacketizer(ssrc: UInt32.random(in: 1...UInt32.max),
                                              initialSequenceNumber: UInt16.random(in: 0...0x7FFF))
    }

    private nonisolated var baseURL: String { "rtsp://\(host):\(port)/\(path)" }

    // MARK: - Lifecycle

    nonisolated func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onEvent?(.failed("Invalid port \(port)"))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort,
                                      using: makeParameters())
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
                self.handshake()
            case .waiting(let error):
                broadcastLog("⚠️ RTSP connection waiting: \(error.localizedDescription)")
            case .failed(let error):
                self.fail("Connection failed: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private nonisolated func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        guard let pinned = pinnedCertSHA256 else { return NWParameters(tls: nil, tcp: tcp) }
        let tls = NWProtocolTLS.Options()
        // The companion's mediamtx cert is self-signed: replace system trust
        // evaluation with an exact DER-hash match against the fingerprint
        // delivered in the pairing URL.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            complete(Data(SHA256.hash(data: der)) == pinned)
        }, queue)
        return NWParameters(tls: tls, tcp: tcp)
    }

    nonisolated func stop() {
        queue.async { [self] in
            stopped = true
            recording = false
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            rtcpTimer?.cancel(); rtcpTimer = nil
            connection?.cancel(); connection = nil
        }
    }

    private nonisolated func fail(_ message: String) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            recording = false
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            rtcpTimer?.cancel(); rtcpTimer = nil
            connection?.cancel(); connection = nil
            onEvent?(.failed(message))
        }
    }

    // MARK: - Handshake

    private nonisolated func handshake() {
        sendRequest(method: "ANNOUNCE", url: baseURL,
                    headers: ["Content-Type": "application/sdp"], body: sdp) { [self] response in
            if response.statusCode == 401, authorizationHeader == nil,
               let user = username, let pass = password {
                let credentials = Data("\(user):\(pass)".utf8).base64EncodedString()
                authorizationHeader = "Basic \(credentials)"
                handshake()    // retry the whole sequence with auth attached
                return
            }
            guard response.statusCode == 200 else {
                fail("ANNOUNCE rejected (\(response.statusCode))" +
                     (response.statusCode == 401 ? " — check publish credentials" : ""))
                return
            }
            setupTracks()
        }
    }

    private nonisolated func setupTracks() {
        sendRequest(method: "SETUP", url: "\(baseURL)/\(SDPBuilder.videoControl)",
                    headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1;mode=record"]) { [self] response in
            guard response.statusCode == 200 else { fail("SETUP video rejected (\(response.statusCode))"); return }
            if let session = response.headers["session"] {
                sessionID = session.components(separatedBy: ";").first
            }
            let hasAudio = sdp.contains("m=audio")
            if hasAudio {
                sendRequest(method: "SETUP", url: "\(baseURL)/\(SDPBuilder.audioControl)",
                            headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=2-3;mode=record"]) { [self] response in
                    guard response.statusCode == 200 else { fail("SETUP audio rejected (\(response.statusCode))"); return }
                    record()
                }
            } else {
                record()
            }
        }
    }

    private nonisolated func record() {
        sendRequest(method: "RECORD", url: baseURL, headers: ["Range": "npt=0-"]) { [self] response in
            guard response.statusCode == 200 else { fail("RECORD rejected (\(response.statusCode))"); return }
            recording = true
            startKeepalive()
            startRTCP()
            broadcastLog("✅ RTSP publishing to \(baseURL)")
            onEvent?(.ready)
        }
    }

    // MARK: - Media

    /// One H.264 access unit. `timestamp90k` is the 90 kHz RTP clock value.
    nonisolated func sendVideo(nalUnits: [Data], timestamp90k: UInt32) {
        queue.async { [self] in
            guard recording else { return }
            for packet in videoPacketizer.packetize(nalUnits: nalUnits, timestamp: timestamp90k) {
                videoStats.packetCount &+= 1
                videoStats.octetCount &+= UInt32(truncatingIfNeeded: packet.count - 12)
                videoStats.lastRTPTimestamp = timestamp90k
                videoStats.lastSendUptimeNanos = DispatchTime.now().uptimeNanoseconds
                sendInterleaved(channel: 0, payload: packet)
            }
        }
    }

    /// One Opus frame. `timestamp48k` is the 48 kHz RTP clock value.
    nonisolated func sendAudio(frame: Data, timestamp48k: UInt32) {
        queue.async { [self] in
            guard recording else { return }
            let packet = audioPacketizer.packetize(frame: frame, timestamp: timestamp48k)
            audioStats.packetCount &+= 1
            audioStats.octetCount &+= UInt32(truncatingIfNeeded: packet.count - 12)
            audioStats.lastRTPTimestamp = timestamp48k
            audioStats.lastSendUptimeNanos = DispatchTime.now().uptimeNanoseconds
            sendInterleaved(channel: 2, payload: packet)
        }
    }

    /// Wraps a packet in RFC 2326 §10.12 interleaved framing ($ + channel + length).
    private nonisolated func sendInterleaved(channel: UInt8, payload: Data) {
        var frame = Data(capacity: 4 + payload.count)
        frame.append(0x24)
        frame.append(channel)
        frame.appendBigEndian(UInt16(truncatingIfNeeded: payload.count))
        frame.append(payload)
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("Send failed: \(error.localizedDescription)") }
        })
    }

    // MARK: - Keepalive / RTCP

    private nonisolated func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self, self.recording else { return }
            self.sendRequest(method: "OPTIONS", url: self.baseURL, headers: [:]) { _ in }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private nonisolated func startRTCP() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.recording else { return }
            self.sendSenderReport(stats: self.videoStats, ssrc: self.videoPacketizer.ssrc, channel: 1)
            self.sendSenderReport(stats: self.audioStats, ssrc: self.audioPacketizer.ssrc, channel: 3)
        }
        timer.resume()
        rtcpTimer = timer
    }

    private nonisolated func sendSenderReport(stats: TrackStats, ssrc: UInt32, channel: UInt8) {
        guard stats.hasSent else { return }
        // Project the track's RTP clock forward from the last packet so the
        // report pairs "now" (NTP) with a consistent RTP timestamp.
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - stats.lastSendUptimeNanos) / 1_000_000_000
        let rtpNow = stats.lastRTPTimestamp &+ UInt32(truncatingIfNeeded: Int64(elapsed * stats.clockRate))
        let report = RTCPSenderReport.encode(
            ssrc: ssrc,
            ntpTime: RTCPSenderReport.ntpTimestamp(unixTime: Date().timeIntervalSince1970),
            rtpTimestamp: rtpNow,
            packetCount: stats.packetCount,
            octetCount: stats.octetCount
        )
        sendInterleaved(channel: channel, payload: report)
    }

    // MARK: - RTSP request/response plumbing

    private nonisolated func sendRequest(method: String, url: String,
                                         headers: [String: String], body: String? = nil,
                                         completion: @escaping (RTSPResponse) -> Void) {
        queue.async { [self] in
            guard !stopped, let connection else { return }
            cseq += 1
            var lines = ["\(method) \(url) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: Longwave"]
            if let sessionID { lines.append("Session: \(sessionID)") }
            if let authorizationHeader { lines.append("Authorization: \(authorizationHeader)") }
            for (key, value) in headers { lines.append("\(key): \(value)") }
            let bodyData = body.map { Data($0.utf8) } ?? Data()
            if !bodyData.isEmpty { lines.append("Content-Length: \(bodyData.count)") }
            var request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            request.append(bodyData)
            pendingResponses.append(completion)
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail("Send failed: \(error.localizedDescription)") }
            })
        }
    }

    private nonisolated func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data { self.receiveBuffer.append(data); self.drainReceiveBuffer() }
            if let error { self.fail("Receive failed: \(error.localizedDescription)"); return }
            if isComplete { self.fail("Server closed the connection"); return }
            self.receiveLoop()
        }
    }

    /// The TCP stream mixes RTSP responses with interleaved binary frames
    /// (server RTCP receiver reports) — demux and discard the latter.
    private nonisolated func drainReceiveBuffer() {
        while !receiveBuffer.isEmpty {
            if receiveBuffer[receiveBuffer.startIndex] == 0x24 {
                guard receiveBuffer.count >= 4 else { return }
                let bytes = [UInt8](receiveBuffer.prefix(4))
                let length = Int(bytes[2]) << 8 | Int(bytes[3])
                guard receiveBuffer.count >= 4 + length else { return }
                receiveBuffer.removeFirst(4 + length)
                continue
            }
            guard let headerEnd = receiveBuffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let headerData = receiveBuffer[receiveBuffer.startIndex..<headerEnd.lowerBound]
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                fail("Malformed RTSP response")
                return
            }
            var headers: [String: String] = [:]
            let lines = headerText.components(separatedBy: "\r\n")
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
            let totalLength = headerData.count + 4 + contentLength
            guard receiveBuffer.count >= totalLength else { return }
            receiveBuffer.removeFirst(totalLength)

            let statusParts = lines.first?.components(separatedBy: " ") ?? []
            let statusCode = statusParts.count >= 2 ? Int(statusParts[1]) ?? 0 : 0
            guard !pendingResponses.isEmpty else { continue }
            let completion = pendingResponses.removeFirst()
            completion(RTSPResponse(statusCode: statusCode, headers: headers))
        }
    }
}
