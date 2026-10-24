import Crypto
@testable import StreamCrypto
import StreamWire
import XCTest

/// Golden bytes from `Reference/ns3_reference.py`, an independent implementation
/// on pyca/cryptography that first checks itself against the cacophony NNpsk0
/// vector. They pin the Longwave framing for the C++ and .NET peers.
private enum Golden {
    static let token = "longwave-test-token"
    static let identity = "device-1234"
    static let psk = "565c71ba02c05b06b4f65d15b152440f75a18203443fff7b4ed669e70c2e4220"
    static let keyID = "64a6aa34585192a1"
    // The cacophony NNpsk0 vector's ephemerals.
    static let initiatorEphemeral = "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a"
    static let responderEphemeral = "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b"
    static let initiatorIndex: UInt32 = 0x1122_3344
    static let responderIndex: UInt32 = 0xAABB_CCDD
    static let initiation = "010364a6aa34585192a1ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944"
        + "d2b994844e43a949b9af6c87df81a1b2cab2c8b6da607acb1d14"
    static let response = "024433221195ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884328e8b7c0237b"
        + "847ae12d63fb9da3ae7bb75dfec45ed8e45ad2fa8593faae"
    static let handshakeHash = "a4a30920fc2bbed1329afa68b259f7a592e89b3a2a7d638050b3f6537c153bb7"
    static let clientRecord0 = "03ddccbbaa00000000000000009e472351edfcc73154bfba5c8a2b60aa443ed00a"
    static let hostRecord0 = "03443322110000000000000000bb877a0fa131881f4655f23a7881246b00af4d7d"
    static let clientRecordGen1 = "13ddccbbaa050000000000000078aef7918537f71aca0b759d28609e470deb3d5206d53cc9795287"
    static let chaChaClientRecord0 = "03ddccbbaa00000000000000005d4bfe84c8f9a3093b3ce43828790da7b77b0e60"
}

final class SecureSessionTests: XCTestCase {
    private let psk = StreamPSK(token: Golden.token, identity: Golden.identity)

    private func goldenHandshake(cipher: RecordCipher = .aes256GCM) throws
        -> (client: SecureSession, host: SecureSession, initiation: [UInt8], response: [UInt8]) {
        let initiator = try StreamInitiator(
            psk: psk, localIndex: Golden.initiatorIndex, ciphers: RecordCipher.allCases, payload: Array("hello".utf8),
            ephemeral: try .init(rawRepresentation: hex(Golden.initiatorEphemeral)))
        let responder = try StreamResponder(
            initiation: initiator.initiation, lookup: { [psk] in $0 == psk.keyID ? psk : nil },
            ephemeral: try .init(rawRepresentation: hex(Golden.responderEphemeral)))
        XCTAssertEqual(responder.payload, Array("hello".utf8))
        XCTAssertEqual(responder.initiatorIndex, Golden.initiatorIndex)
        XCTAssertEqual(responder.offeredCiphers, [.aes256GCM, .chaCha20Poly1305])
        let host = try responder.respond(localIndex: Golden.responderIndex, cipher: cipher,
                                         payload: Array("hello-ack".utf8), now: 0)
        let client = try initiator.complete(response: host.response, now: 0)
        XCTAssertEqual(client.payload, Array("hello-ack".utf8))
        return (client.session, host.session, initiator.initiation, host.response)
    }

    // MARK: Keys

    func testPSKAndKeyIDMatchTheReference() {
        XCTAssertEqual(hexString(psk.bytes), Golden.psk)
        XCTAssertEqual(psk.keyID.description, Golden.keyID)
        let other = StreamPSK(token: Golden.token, identity: "device-5678")
        XCTAssertNotEqual(other.bytes, psk.bytes)
        XCTAssertNotEqual(other.keyID, psk.keyID)
    }

    // MARK: Handshake

    func testHandshakeMatchesTheReference() throws {
        let result = try goldenHandshake()
        XCTAssertEqual(hexString(result.initiation), Golden.initiation)
        XCTAssertEqual(hexString(result.response), Golden.response)
        XCTAssertEqual(hexString(result.client.handshakeHash), Golden.handshakeHash)
        XCTAssertEqual(result.client.handshakeHash, result.host.handshakeHash)
        XCTAssertEqual(result.client.localIndex, Golden.initiatorIndex)
        XCTAssertEqual(result.client.remoteIndex, Golden.responderIndex)
        XCTAssertEqual(result.host.localIndex, Golden.responderIndex)
        XCTAssertEqual(result.host.remoteIndex, Golden.initiatorIndex)
        XCTAssertEqual(result.client.cipher, .aes256GCM)
    }

    func testRecordsMatchTheReference() throws {
        var result = try goldenHandshake()
        let ping = try result.client.sender.seal(Array("ping".utf8), now: 0)
        XCTAssertEqual(ping.packetNumber, 0)
        XCTAssertEqual(hexString(ping.datagram), Golden.clientRecord0)
        XCTAssertEqual(try result.host.receiver.open(ping.datagram).body, Array("ping".utf8))
        let pong = try result.host.sender.seal(Array("pong".utf8), now: 0)
        XCTAssertEqual(hexString(pong.datagram), Golden.hostRecord0)
        XCTAssertEqual(try result.client.receiver.open(pong.datagram).body, Array("pong".utf8))

        // Generation 1 after five packets.
        var sender = RecordSender(key: RecordKey(cipher: .aes256GCM, splitKey: try clientSplitKey()),
                                  receiverIndex: Golden.responderIndex, now: 0, packetsPerKey: 5)
        for _ in 0..<5 { _ = try sender.seal([], now: 0) }
        let rekeyed = try sender.seal(Array("after rekey".utf8), now: 0)
        XCTAssertEqual(sender.generation, 1)
        XCTAssertEqual(hexString(rekeyed.datagram), Golden.clientRecordGen1)

        var chacha = try goldenHandshake(cipher: .chaCha20Poly1305)
        let chachaPing = try chacha.client.sender.seal(Array("ping".utf8), now: 0)
        XCTAssertEqual(hexString(chachaPing.datagram), Golden.chaChaClientRecord0)
        XCTAssertEqual(try chacha.host.receiver.open(chachaPing.datagram).body, Array("ping".utf8))
    }

    /// The initiator-to-responder split key of the golden handshake.
    private func clientSplitKey() throws -> [UInt8] {
        let clear = [PacketKind.initiation.rawValue, 3] + psk.keyID.bytes
        var state = NoiseHandshakeState(role: .initiator, pattern: .nnPSK0, prologue: StreamHandshake.prologue(clear),
                                        psks: [psk.bytes],
                                        ephemeral: try .init(rawRepresentation: hex(Golden.initiatorEphemeral)))
        var inner = WireWriter()
        inner.writeUInt32(Golden.initiatorIndex)
        inner.writeUInt8(0x03)
        inner.writeBytes(Array("hello".utf8))
        _ = try state.writeMessage(payload: inner.bytes)
        _ = try state.readMessage(Array(hex(Golden.response)[StreamHandshake.responseClearSize...]))
        return try state.split().initiatorToResponder
    }

    func testRealHandshakeWithRandomEphemerals() throws {
        let initiator = try StreamInitiator(psk: psk, localIndex: 7, payload: [1, 2, 3])
        let responder = try StreamResponder(initiation: initiator.initiation, lookup: { [psk] _ in psk })
        XCTAssertEqual(responder.choose(from: [.chaCha20Poly1305, .aes256GCM]), .chaCha20Poly1305)
        var host = try responder.respond(localIndex: 9, cipher: .chaCha20Poly1305, payload: [4], now: 0)
        var client = try initiator.complete(response: host.response, now: 0)
        XCTAssertEqual(client.payload, [4])
        XCTAssertFalse(host.session.receiver.hasAcceptedPacket)
        let packet = try client.session.sender.seal([9, 9], now: 0)
        XCTAssertEqual(try host.session.receiver.open(packet.datagram).body, [9, 9])
        XCTAssertTrue(host.session.receiver.hasAcceptedPacket)
    }

    func testHostRejectsInitiationsItCannotAuthenticate() throws {
        let initiator = try StreamInitiator(psk: psk, localIndex: 1, payload: [])
        let wrong = StreamPSK(token: "other", identity: Golden.identity)

        XCTAssertThrowsError(try StreamResponder(initiation: initiator.initiation, lookup: { _ in nil })) {
            XCTAssertEqual($0 as? StreamCryptoError, .unknownKey)
        }
        // A lookup that returns a PSK for the wrong key ID is refused before Noise runs.
        XCTAssertThrowsError(try StreamResponder(initiation: initiator.initiation, lookup: { _ in wrong })) {
            XCTAssertEqual($0 as? StreamCryptoError, .unknownKey)
        }

        var version = initiator.initiation
        version[1] = 4
        XCTAssertThrowsError(try StreamResponder(initiation: version, lookup: { [psk] _ in psk })) {
            XCTAssertEqual($0 as? StreamCryptoError, .unsupportedVersion(4))
        }
        XCTAssertThrowsError(try StreamResponder(initiation: Array(initiator.initiation.prefix(40)), lookup: { [psk] _ in psk }))

        // Every single-bit flip after the clear header fails authentication.
        for index in StreamHandshake.initiationClearSize..<initiator.initiation.count {
            var tampered = initiator.initiation
            tampered[index] ^= 0x01
            XCTAssertThrowsError(try StreamResponder(initiation: tampered, lookup: { [psk] _ in psk }), "byte \(index)")
        }
        // A flipped key ID byte, answered with the right PSK anyway, fails through the prologue.
        var keyID = initiator.initiation
        keyID[2] ^= 0x80
        let forgedLookup: (StreamPSK.KeyID) -> StreamPSK? = { [psk] _ in psk }
        XCTAssertThrowsError(try StreamResponder(initiation: keyID, lookup: forgedLookup))
    }

    func testClientRejectsResponsesThatAreNotItsOwn() throws {
        let initiator = try StreamInitiator(psk: psk, localIndex: 1, payload: [])
        let responder = try StreamResponder(initiation: initiator.initiation, lookup: { [psk] _ in psk })
        let host = try responder.respond(localIndex: 2, cipher: .aes256GCM, payload: [], now: 0)

        var otherIndex = host.response
        otherIndex[1] ^= 0xFF
        XCTAssertThrowsError(try initiator.complete(response: otherIndex, now: 0)) {
            XCTAssertEqual($0 as? StreamCryptoError, .unknownConnection)
        }
        for index in StreamHandshake.responseClearSize..<host.response.count {
            var tampered = host.response
            tampered[index] ^= 0x01
            XCTAssertThrowsError(try initiator.complete(response: tampered, now: 0), "byte \(index)")
        }
        // A response to someone else's initiation (other ephemeral) fails.
        let other = try StreamInitiator(psk: psk, localIndex: 1, payload: [])
        XCTAssertThrowsError(try other.complete(response: host.response, now: 0))
        // And the real one still completes: a failed attempt doesn't consume the initiator.
        XCTAssertNoThrow(try initiator.complete(response: host.response, now: 0))
    }

    func testPayloadLimitsKeepHandshakesInOneDatagram() throws {
        let big = [UInt8](repeating: 0xAB, count: StreamHandshake.maxInitiationPayload)
        let initiator = try StreamInitiator(psk: psk, localIndex: 1, payload: big)
        XCTAssertEqual(initiator.initiation.count, DatagramLayout.defaultUDPPayload)
        XCTAssertThrowsError(try StreamInitiator(psk: psk, localIndex: 1, payload: big + [0]))

        let responder = try StreamResponder(initiation: initiator.initiation, lookup: { [psk] _ in psk })
        let ack = [UInt8](repeating: 0xCD, count: StreamHandshake.maxResponsePayload)
        XCTAssertEqual(try responder.respond(localIndex: 2, cipher: .aes256GCM, payload: ack, now: 0).response.count,
                       DatagramLayout.defaultUDPPayload)
        XCTAssertThrowsError(try responder.respond(localIndex: 2, cipher: .aes256GCM, payload: ack + [0], now: 0))
    }

    func testPacketKindRejectsReservedBits() {
        XCTAssertEqual(PacketKind.of([0x01]), .initiation)
        XCTAssertEqual(PacketKind.of([0x13]), .transport)
        XCTAssertNil(PacketKind.of([0x11]))   // key phase on a handshake packet
        XCTAssertNil(PacketKind.of([0x23]))   // reserved bit
        XCTAssertNil(PacketKind.of([0x04]))
        XCTAssertNil(PacketKind.of([]))
    }

    // MARK: Records

    func testReplayAndReorderingWithinTheWindow() throws {
        var session = try goldenHandshake()
        var packets: [[UInt8]] = []
        for index in 0..<10 { packets.append(try session.client.sender.seal([UInt8(index)], now: 0).datagram) }
        for index in [3, 0, 9, 1, 2, 8, 4, 7, 6, 5] {
            XCTAssertEqual(try session.host.receiver.open(packets[index]).body, [UInt8(index)])
        }
        XCTAssertThrowsError(try session.host.receiver.open(packets[4])) {
            XCTAssertEqual($0 as? StreamCryptoError, .replayed)
        }
        // A packet more than a window behind the newest is too old.
        var late: [UInt8] = []
        for index in 0..<(ReplayWindow.defaultSize + 1) {
            let datagram = try session.client.sender.seal([], now: 0).datagram
            if index == 0 { late = datagram } else { _ = try session.host.receiver.open(datagram) }
        }
        XCTAssertThrowsError(try session.host.receiver.open(late)) {
            XCTAssertEqual($0 as? StreamCryptoError, .replayed)
        }
    }

    func testTamperedRecordsFailAndDoNotMoveTheWindow() throws {
        var session = try goldenHandshake()
        let packet = try session.client.sender.seal(Array("data".utf8), now: 0).datagram
        for index in 0..<packet.count {
            var tampered = packet
            tampered[index] ^= 0x04
            XCTAssertThrowsError(try session.host.receiver.open(tampered), "byte \(index)")
        }
        XCTAssertGreaterThan(session.host.receiver.authenticationFailures, 0)
        // The genuine packet still opens: no forgery consumed its packet number.
        XCTAssertEqual(try session.host.receiver.open(packet).body, Array("data".utf8))
        XCTAssertThrowsError(try session.host.receiver.open(Array(packet.prefix(RecordHeader.size + 15))))
    }

    func testRekeyFollowsAcrossReorderingAndDropsTheOldKey() throws {
        let key = RecordKey(cipher: .chaCha20Poly1305, splitKey: [UInt8](repeating: 3, count: 32))
        var sender = RecordSender(key: key, receiverIndex: 5, now: 0, packetsPerKey: 100)
        var receiver = RecordReceiver(key: key, localIndex: 5, windowSize: 256)
        var packets: [[UInt8]] = []
        for _ in 0..<1000 { packets.append(try sender.seal([1], now: 0).datagram) }
        XCTAssertEqual(sender.generation, 9)

        // Deliver with local reordering across every switch: swap neighbours.
        var order = Array(packets.indices)
        for index in stride(from: 0, to: order.count - 1, by: 2) { order.swapAt(index, index + 1) }
        for index in order {
            XCTAssertNoThrow(try receiver.open(packets[index]), "packet \(index)")
        }
        XCTAssertEqual(receiver.generation, 9)
        XCTAssertEqual(receiver.authenticationFailures, 0)
    }

    func testRekeyAfterTheTimeInterval() throws {
        let key = RecordKey(cipher: .aes256GCM, splitKey: [UInt8](repeating: 4, count: 32))
        var sender = RecordSender(key: key, receiverIndex: 1, now: 0, rekeyInterval: 1_000)
        var receiver = RecordReceiver(key: key, localIndex: 1)
        _ = try receiver.open(try sender.seal([], now: 10).datagram)
        // Few packets, long gaps: the receiver still holds the previous key when the
        // sender moves again, and must try the next one.
        for step in 1...5 {
            let packet = try sender.seal([UInt8(step)], now: UInt64(step) * 1_500)
            XCTAssertEqual(sender.generation, UInt64(step))
            XCTAssertEqual(try receiver.open(packet.datagram).body, [UInt8(step)])
        }
        XCTAssertEqual(receiver.generation, 5)
    }

    func testIntegrityLimitEndsTheSession() throws {
        let key = RecordKey(cipher: .aes256GCM, splitKey: [UInt8](repeating: 5, count: 32))
        var sender = RecordSender(key: key, receiverIndex: 1, now: 0)
        var receiver = RecordReceiver(key: key, localIndex: 1, integrityLimit: 3)
        let good = try sender.seal([1], now: 0).datagram
        var forged = good
        forged[forged.count - 1] ^= 1
        for _ in 0..<3 { XCTAssertThrowsError(try receiver.open(forged)) }
        XCTAssertThrowsError(try receiver.open(good)) {
            XCTAssertEqual($0 as? StreamCryptoError, .integrityLimitReached)
        }
    }

    func testWrongConnectionID() throws {
        var session = try goldenHandshake()
        let packet = try session.host.sender.seal([], now: 0).datagram
        XCTAssertThrowsError(try session.host.receiver.open(packet)) {
            XCTAssertEqual($0 as? StreamCryptoError, .unknownConnection)
        }
    }

    // MARK: Replay filter

    func testInitiationReplayFilter() {
        var filter = InitiationReplayFilter<Int>(lifetime: 100, capacity: 2)
        filter.remember([1], response: 10, now: 0)
        XCTAssertEqual(filter.lookup([1], now: 50), 10)
        XCTAssertNil(filter.lookup([1], now: 100))
        filter.remember([1], response: 1, now: 200)
        filter.remember([2], response: 2, now: 201)
        filter.remember([3], response: 3, now: 202)
        XCTAssertNil(filter.lookup([1], now: 203), "oldest evicted at capacity")
        XCTAssertEqual(filter.lookup([3], now: 203), 3)
    }
}

final class ReplayWindowTests: XCTestCase {
    /// Against a model that remembers every number: the window must agree inside
    /// it and reject everything behind it.
    func testAgainstAModel() {
        for seed in UInt64(1)...20 {
            var random = SplitMix64(seed: seed)
            var window = ReplayWindow(size: 128)
            var seen = Set<UInt64>()
            var highest: UInt64?
            for _ in 0..<5_000 {
                let base = highest ?? 0
                let jump = random.next() % 10 == 0 ? random.next() % 400 : random.next() % 8
                let candidate = random.next() % 2 == 0 ? base &+ jump : (base >= jump * 20 ? base - jump * 20 : 0)
                let tooOld = highest.map { $0 > candidate && $0 - candidate >= 128 } ?? false
                let expected = !seen.contains(candidate) && !tooOld
                XCTAssertEqual(window.check(candidate), expected, "seed \(seed) number \(candidate)")
                XCTAssertEqual(window.accept(candidate), expected)
                if expected {
                    seen.insert(candidate)
                    highest = max(highest ?? candidate, candidate)
                }
            }
        }
    }

    func testLargeJumpsAndExtremes() {
        var window = ReplayWindow()
        XCTAssertTrue(window.accept(0))
        XCTAssertFalse(window.accept(0))
        XCTAssertTrue(window.accept(UInt64.max - 1))
        XCTAssertFalse(window.check(0))
        XCTAssertTrue(window.accept(UInt64.max - 2048))   // 2047 behind: the oldest slot
        XCTAssertFalse(window.check(UInt64.max - 2049))
        XCTAssertTrue(window.accept(UInt64.max))
    }
}
