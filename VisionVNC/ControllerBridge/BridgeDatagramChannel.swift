//  BridgeDatagramChannel.swift
//
//  The UDP input path, off the main actor. The sender's 83 Hz loop builds packets
//  on the main actor (that is where the gesture engine and GameController state
//  live), but sealing and the socket write happen here, on a private serial queue
//  — AES-GCM per packet is microseconds, yet doing it on the main actor put the
//  input cadence in contention with SwiftUI layout, and on a busy frame that is
//  input jitter.
//
//  It also owns the plaintext policy. Nothing leaves in the clear unless the
//  VISIONVNC_CB_ALLOW_PLAINTEXT environment variable is set (an Xcode-scheme dev
//  opt-in, mirroring the host's gate): a seal that exists but fails must DROP the
//  packet, never downgrade it — silently unencrypted is the one outcome nobody
//  would notice.
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import Foundation
import Network
import os

nonisolated final class BridgeDatagramChannel: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.illixion.VisionVNC.controllerbridge.net")
    private let log = Logger(subsystem: "com.illixion.VisionVNC", category: "BridgeDatagram")

    private var connection: NWConnection?
    private var seal: BridgeSeal?
    private var endpointDescription: String?
    private var droppedUnsealable: UInt64 = 0

    /// Dev opt-in for plaintext v2 packets, matching the host's own gate. Set it
    /// in the Xcode scheme; a user install never has it.
    private let plaintextAllowed =
        ProcessInfo.processInfo.environment["VISIONVNC_CB_ALLOW_PLAINTEXT"] == "1"

    /// Called (on an arbitrary queue) when a send fails at the socket.
    var onSendError: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onSendError } }
        set { lock.withLock { _onSendError = newValue } }
    }
    private var _onSendError: (@Sendable (String) -> Void)?

    /// Whether send() currently has both somewhere to go and a way to go there
    /// legally (sealed, or the dev plaintext opt-in).
    var isReady: Bool {
        lock.withLock { connection != nil && (seal != nil || plaintextAllowed) }
    }

    var isSealed: Bool { lock.withLock { seal != nil } }

    /// Point the stream at a host. Replaces any previous connection.
    func setEndpoint(host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        lock.withLock {
            connection?.cancel()
            connection = conn
            endpointDescription = "\(host):\(port)"
        }
        conn.start(queue: queue)
        log.notice("""
            ControllerBridge UDP → \(host, privacy: .public):\(port, privacy: .public) \
            (\(self.isSealed ? "sealed" : self.plaintextAllowed ? "PLAINTEXT (dev)" : "waiting for keys", privacy: .public))
            """)
    }

    /// Derive fresh datagram keys from a session token. Counters restart, which is
    /// only safe on a genuinely new token — the caller (the sender's `adopt`)
    /// guarantees that.
    func adoptToken(_ token: Data) {
        lock.withLock { seal = BridgeSeal(token: token) }
    }

    func clearSeal() {
        lock.withLock { seal = nil }
    }

    func stop() {
        lock.withLock {
            connection?.cancel()
            connection = nil
            seal = nil
            endpointDescription = nil
        }
    }

    /// Seal and send one datagram. Runs on the private queue; safe from any actor.
    /// Drops (with a rate-limited log) when there is no lawful way to send.
    func send(_ plain: Data) {
        queue.async { [self] in
            let payload: Data
            let conn: NWConnection?
            lock.lock()
            conn = connection
            if seal != nil {
                guard let sealed = seal!.seal(plain) else {
                    // CryptoKit refusing is a platform fault, not a peer one; the
                    // packet is dropped rather than downgraded to plaintext.
                    droppedUnsealable += 1
                    let n = droppedUnsealable
                    lock.unlock()
                    if n == 1 || n % 500 == 0 {
                        log.error("Dropped \(n, privacy: .public) packet(s) that could not be sealed.")
                    }
                    return
                }
                payload = sealed
            } else if plaintextAllowed {
                payload = plain
            } else {
                droppedUnsealable += 1
                let n = droppedUnsealable
                lock.unlock()
                if n == 1 || n % 500 == 0 {
                    log.notice("Dropped \(n, privacy: .public) packet(s): no session keys and plaintext is not allowed.")
                }
                return
            }
            let errorHandler = _onSendError
            lock.unlock()

            guard let conn else { return }
            conn.send(content: payload, completion: .contentProcessed { error in
                if let error { errorHandler?(error.localizedDescription) }
            })
        }
    }
}
#endif
