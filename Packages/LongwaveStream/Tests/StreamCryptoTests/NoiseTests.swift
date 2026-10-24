import Crypto
@testable import StreamCrypto
import XCTest

final class NoiseTests: XCTestCase {
    private func pattern(for name: String) throws -> NoisePattern {
        let patterns: [NoisePattern] = [.nn, .nnPSK0, .nnPSK2, .nnPSK0PSK2]
        return try XCTUnwrap(patterns.first { $0.protocolName() == name }, "no pattern for \(name)")
    }

    /// Every published NN-family vector: the handshake byte for byte, the
    /// handshake hash where given, then transport messages under the split keys.
    func testPublishedVectors() throws {
        XCTAssertEqual(noiseVectors.count, 5)
        for vector in noiseVectors {
            let context = "\(vector.source) \(vector.protocolName)"
            let pattern = try pattern(for: vector.protocolName)
            let psks = vector.psks.map { hex($0) }
            var initiator = NoiseHandshakeState(
                role: .initiator, pattern: pattern, prologue: hex(vector.prologue), psks: psks,
                ephemeral: try .init(rawRepresentation: hex(vector.initiatorEphemeral)))
            var responder = NoiseHandshakeState(
                role: .responder, pattern: pattern, prologue: hex(vector.prologue), psks: psks,
                ephemeral: try .init(rawRepresentation: hex(vector.responderEphemeral)))

            var index = 0
            while !initiator.isFinished {
                let message = vector.messages[index]
                let initiatorWrites = index % 2 == 0
                let written = initiatorWrites
                    ? try initiator.writeMessage(payload: hex(message.payload))
                    : try responder.writeMessage(payload: hex(message.payload))
                XCTAssertEqual(hexString(written), message.ciphertext, "\(context) message \(index)")
                let read = initiatorWrites ? try responder.readMessage(written) : try initiator.readMessage(written)
                XCTAssertEqual(read, hex(message.payload), "\(context) message \(index)")
                index += 1
            }
            XCTAssertTrue(responder.isFinished, context)
            XCTAssertEqual(initiator.handshakeHash, responder.handshakeHash, context)
            if let expected = vector.handshakeHash {
                XCTAssertEqual(hexString(initiator.handshakeHash), expected, context)
            }

            let keys = try initiator.split()
            let responderKeys = try responder.split()
            XCTAssertEqual(keys.initiatorToResponder, responderKeys.initiatorToResponder, context)
            XCTAssertEqual(keys.responderToInitiator, responderKeys.responderToInitiator, context)
            var send = NoiseCipherState()
            send.initializeKey(keys.initiatorToResponder)
            var receive = NoiseCipherState()
            receive.initializeKey(keys.responderToInitiator)
            for message in vector.messages[index...] {
                let initiatorWrites = index % 2 == 0
                let ciphertext = initiatorWrites
                    ? try send.encrypt(ad: [], hex(message.payload))
                    : try receive.encrypt(ad: [], hex(message.payload))
                XCTAssertEqual(hexString(ciphertext), message.ciphertext, "\(context) transport \(index)")
                index += 1
            }
        }
    }

    func testProtocolName() {
        XCTAssertEqual(StreamHandshake.protocolName, "Noise_NNpsk0_25519_ChaChaPoly_SHA256")
    }

    func testOutOfTurnCallsAreRefused() throws {
        var initiator = NoiseHandshakeState(role: .initiator, pattern: .nnPSK0, prologue: [], psks: [[UInt8](repeating: 1, count: 32)])
        XCTAssertThrowsError(try initiator.readMessage([UInt8](repeating: 0, count: 48)))
        XCTAssertThrowsError(try initiator.split())
        _ = try initiator.writeMessage(payload: [])
        XCTAssertThrowsError(try initiator.writeMessage(payload: []))
    }

    func testWrongPSKFailsTheFirstMessage() throws {
        var initiator = NoiseHandshakeState(role: .initiator, pattern: .nnPSK0, prologue: [], psks: [[UInt8](repeating: 1, count: 32)])
        var responder = NoiseHandshakeState(role: .responder, pattern: .nnPSK0, prologue: [], psks: [[UInt8](repeating: 2, count: 32)])
        let message = try initiator.writeMessage(payload: Array("hello".utf8))
        XCTAssertThrowsError(try responder.readMessage(message)) {
            XCTAssertEqual($0 as? StreamCryptoError, .authenticationFailed)
        }
    }

    func testDifferentProloguesFail() throws {
        let psk = [UInt8](repeating: 7, count: 32)
        var initiator = NoiseHandshakeState(role: .initiator, pattern: .nnPSK0, prologue: [1], psks: [psk])
        var responder = NoiseHandshakeState(role: .responder, pattern: .nnPSK0, prologue: [2], psks: [psk])
        XCTAssertThrowsError(try responder.readMessage(try initiator.writeMessage(payload: [])))
    }
}
