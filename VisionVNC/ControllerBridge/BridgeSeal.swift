//  BridgeSeal.swift
//
//  Authenticated encryption for the direct link to the PCVR host. The Swift
//  mirror of OpenXRLayer/src/seal.{h,cpp} — if the two disagree about a single
//  byte, nothing opens, which is the failure mode to want here.
//
//  The rendezvous arrives inside CloudXR's encrypted session carrying 32 bytes of
//  host CSPRNG output. That is already a session-specific shared secret, so
//  encrypting the LAN/tailnet link costs one HMAC per session plus an AES-GCM pass
//  per datagram — hardware AES on both ends, unmeasurable against an 83 Hz input
//  stream.
//
//  Worth doing for two reasons beyond secrecy:
//    - The link carries a launch verb. GCM gives integrity, not just privacy.
//    - A bearer token has to be *sent* to be checked, so stamping it on every
//      datagram put the secret on the LAN. Sealed traffic never does.
//
//  Construction (see the C++ header for the authoritative comment):
//    key   = HMAC-SHA256(token, info)     — info differs per direction
//    nonce = 12-byte little-endian counter, zero-padded
//    aad   = the 12-byte cleartext header
//
//  Gated behind FOVEATED_ENABLED.

#if FOVEATED_ENABLED
import CryptoKit
import Foundation

/// One session's keys and counters. A value type on purpose: it is owned by
/// whichever object owns the session, and a copy carrying stale counters cannot
/// silently coexist with the original.
struct BridgeSeal {
    static let packetType: UInt8 = 0x0B
    static let headerSize = 12
    static let tagBytes = 16
    static let overhead = headerSize + tagBytes      // 28
    static let directionClientToHost: UInt8 = 0
    static let directionHostToClient: UInt8 = 1

    private static let infoClientToHost = "VisionVNC-CB-v1 client->host"
    private static let infoHostToClient = "VisionVNC-CB-v1 host->client"
    private static let infoClientToHostStream = "VisionVNC-CB-v1 client->host stream"
    private static let infoHostToClientStream = "VisionVNC-CB-v1 host->client stream"

    /// Which transport a seal belongs to. The two derive **different** keys from the
    /// same token, and that is a requirement rather than hygiene: the nonce is the
    /// send counter, so two seals sharing a key and both counting from 1 repeat a
    /// (key, nonce) pair on their first packet each — which for AES-GCM leaks the
    /// authentication key. It was also breaking the link outright, because the host
    /// keeps one replay window per key and read the second seal's counters as
    /// replays of the first's. This app had exactly that: the input sender and the
    /// game library each held their own `BridgeSeal` over one token.
    enum Channel {
        /// UDP :9520 — hand tracking and controller input.
        case datagram
        /// TCP :9523 — the library, perf, telemetry, haptics, tuning.
        case stream
    }

    /// This end seals client→host and opens host→client. The host is the mirror.
    private let sealKey: SymmetricKey
    private let openKey: SymmetricKey

    private var sendCounter: UInt64 = 0
    /// Highest counter opened, plus a bitmap of the 64 below it. Out-of-order
    /// delivery inside that window is accepted — this is UDP, and refusing a
    /// reordered pose would drop input for no reason — but nothing opens twice.
    private var recvHighest: UInt64 = 0
    private var recvWindow: UInt64 = 0
    private static let replayWindow: UInt64 = 64

    init(token: Data, channel: Channel = .datagram) {
        let secret = SymmetricKey(data: token)
        let stream = channel == .stream
        sealKey = Self.derive(from: secret,
                              info: stream ? Self.infoClientToHostStream : Self.infoClientToHost)
        openKey = Self.derive(from: secret,
                              info: stream ? Self.infoHostToClientStream : Self.infoHostToClient)
    }

    /// HKDF-Expand with a single block. No extract step: the token is already
    /// uniform CSPRNG output, so there is no entropy to concentrate.
    private static func derive(from secret: SymmetricKey, info: String) -> SymmetricKey {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(info.utf8), using: secret)
        return SymmetricKey(data: Data(mac))
    }

    // MARK: Sealing

    /// Wrap one datagram. Returns nil only if CryptoKit refuses, which would mean
    /// something is wrong with the platform rather than with the peer.
    mutating func seal(_ plain: Data) -> Data? {
        guard !plain.isEmpty else { return nil }
        sendCounter += 1
        let header = Self.header(direction: Self.directionClientToHost, counter: sendCounter)
        guard let nonce = try? AES.GCM.Nonce(data: Self.nonce(sendCounter)),
              let box = try? AES.GCM.seal(plain, using: sealKey, nonce: nonce,
                                          authenticating: header) else { return nil }
        return header + box.ciphertext + box.tag
    }

    /// Unwrap one datagram from the host. Returns nil — deliberately without
    /// saying why — on a bad tag, the wrong direction, a replay, or a stale
    /// counter. A caller must read nil as "not from the host we paired with".
    mutating func open(_ packet: Data) -> Data? {
        guard Self.isSealed(packet) else { return nil }
        let bytes = [UInt8](packet)
        guard bytes[2] == Self.directionHostToClient else { return nil }

        var counter: UInt64 = 0
        for i in 0 ..< 8 { counter |= UInt64(bytes[4 + i]) << (8 * i) }
        guard counter > 0 else { return nil }   // counters start at 1

        let header = packet.prefix(Self.headerSize)
        let body = packet.dropFirst(Self.headerSize)
        guard body.count > Self.tagBytes else { return nil }
        let ciphertext = body.prefix(body.count - Self.tagBytes)
        let tag = body.suffix(Self.tagBytes)

        guard let nonce = try? AES.GCM.Nonce(data: Self.nonce(counter)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: openKey, authenticating: header)
        else { return nil }

        // Counter accepted only after the tag verified, so nobody can burn the
        // replay window with datagrams they could not have authenticated.
        guard acceptCounter(counter) else { return nil }
        return plain
    }

    /// Cheap check that something is a sealed datagram at all, before any crypto.
    static func isSealed(_ data: Data) -> Bool {
        guard data.count >= overhead + 1 else { return false }
        let b = [UInt8](data.prefix(2))
        return b[0] == packetType && b[1] == ControllerBridgeProtocol.version
    }

    // MARK: Internals

    private static func header(direction: UInt8, counter: UInt64) -> Data {
        var d = Data(capacity: headerSize)
        d.append(packetType)
        d.append(ControllerBridgeProtocol.version)
        d.append(direction)
        d.append(0)
        for i in 0 ..< 8 { d.append(UInt8((counter >> (8 * i)) & 0xff)) }
        return d
    }

    private static func nonce(_ counter: UInt64) -> Data {
        var d = Data(count: 12)
        for i in 0 ..< 8 { d[i] = UInt8((counter >> (8 * i)) & 0xff) }
        return d
    }

    private mutating func acceptCounter(_ counter: UInt64) -> Bool {
        if counter > recvHighest {
            let advance = counter - recvHighest
            recvWindow = advance >= 64 ? 1 : ((recvWindow << advance) | 1)
            recvHighest = counter
            return true
        }
        let back = recvHighest - counter
        guard back < Self.replayWindow else { return false }   // too old to judge
        let bit: UInt64 = 1 << back
        guard recvWindow & bit == 0 else { return false }      // already seen
        recvWindow |= bit
        return true
    }
}
#endif
