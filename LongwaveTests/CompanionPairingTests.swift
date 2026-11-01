import CryptoKit
import RAVECompanion
import XCTest
@testable import Longwave

// The protocol itself is tested in RAVESDK (`RAVECompanionTests`, with vectors
// from the code that used to live here); these check Longwave's adapters.

final class CompanionPairingTests: XCTestCase {

    // MARK: Knock

    func testKnockTagValidWithinAMinuteEitherSide() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minute = CompanionDiscovery.minute(of: now)
        for offset in [-1, 0, 1] as [Int64] {
            let tag = CompanionDiscovery.knockTag(token: "tok", macID: "mac", headsetID: "hs", minute: minute + offset)
            XCTAssertTrue(CompanionDiscovery.isValidKnock(tag: tag, token: "tok", macID: "mac", headsetID: "hs", now: now))
        }
        let stale = CompanionDiscovery.knockTag(token: "tok", macID: "mac", headsetID: "hs", minute: minute - 2)
        XCTAssertFalse(CompanionDiscovery.isValidKnock(tag: stale, token: "tok", macID: "mac", headsetID: "hs", now: now))
    }

    func testKnockTagBindsTokenMacAndHeadset() {
        let now = Date()
        let tag = CompanionDiscovery.knockTag(token: "tok", macID: "mac", headsetID: "hs", minute: CompanionDiscovery.minute(of: now))
        XCTAssertFalse(CompanionDiscovery.isValidKnock(tag: tag, token: "other", macID: "mac", headsetID: "hs", now: now))
        XCTAssertFalse(CompanionDiscovery.isValidKnock(tag: tag, token: "tok", macID: "mac2", headsetID: "hs", now: now))
        XCTAssertFalse(CompanionDiscovery.isValidKnock(tag: tag, token: "tok", macID: "mac", headsetID: "hs2", now: now))
        // Short enough for a TXT entry.
        XCTAssertLessThan(tag.utf8.count, 32)
    }

    // MARK: Exchange

    private struct Run {
        let headset = PairingExchange()
        let mac = PairingExchange()
        var commitment: Data { PairingExchange.commitment(publicKey: headset.publicKey, nonce: headset.nonce) }

        func headsetSide(macPublicKey: Data? = nil) -> PairingExchange.Agreement? {
            PairingExchange.agree(
                CompanionDiscovery.namespace, mine: headset, theirPublicKey: macPublicKey ?? mac.publicKey,
                commitment: commitment, devicePublicKey: headset.publicKey, deviceNonce: headset.nonce,
                hostPublicKey: macPublicKey ?? mac.publicKey, hostNonce: mac.nonce
            )
        }

        func macSide(revealedKey: Data? = nil, revealedNonce: Data? = nil) -> PairingExchange.Agreement? {
            PairingExchange.agree(
                CompanionDiscovery.namespace, mine: mac, theirPublicKey: revealedKey ?? headset.publicKey,
                commitment: commitment, devicePublicKey: revealedKey ?? headset.publicKey,
                deviceNonce: revealedNonce ?? headset.nonce, hostPublicKey: mac.publicKey, hostNonce: mac.nonce
            )
        }
    }

    func testBothEndsAgreeOnCodeAndKey() throws {
        let run = Run()
        let h = try XCTUnwrap(run.headsetSide())
        let m = try XCTUnwrap(run.macSide())
        XCTAssertEqual(h.code, m.code)
        XCTAssertEqual(h.code.count, 6)
        XCTAssertTrue(h.code.allSatisfy(\.isNumber))
        let grant = PairingGrant(token: "secret", macID: "mac", macName: "Studio Mac", addresses: ["192.0.2.10"], grants: ["audio", "screen"])
        XCTAssertEqual(try PairingExchange.open(PairingExchange.seal(grant, with: m.key), with: h.key), grant)
    }

    func testRevealNotMatchingCommitmentIsRejected() {
        let run = Run()
        XCTAssertNil(run.macSide(revealedNonce: PairingExchange.randomNonce()))
        XCTAssertNil(run.macSide(revealedKey: PairingExchange().publicKey))
    }

    func testSomethingInTheMiddleGetsDifferentCodes() throws {
        // The headset talks to an impostor Mac; the real Mac talks to an
        // impostor headset. The two codes the user compares disagree.
        let run = Run()
        let impostor = PairingExchange()
        let headsetCode = try XCTUnwrap(run.headsetSide(macPublicKey: impostor.publicKey)).code
        let fakeHeadset = PairingExchange()
        let fakeCommitment = PairingExchange.commitment(publicKey: fakeHeadset.publicKey, nonce: fakeHeadset.nonce)
        let macCode = try XCTUnwrap(PairingExchange.agree(
            CompanionDiscovery.namespace, mine: run.mac, theirPublicKey: fakeHeadset.publicKey,
            commitment: fakeCommitment, devicePublicKey: fakeHeadset.publicKey, deviceNonce: fakeHeadset.nonce,
            hostPublicKey: run.mac.publicKey, hostNonce: run.mac.nonce
        )).code
        XCTAssertNotEqual(headsetCode, macCode)
    }

    func testGrantSealedForOneKeyWontOpenWithAnother() throws {
        let grant = PairingGrant(token: "secret", macID: "mac", macName: "M", addresses: [])
        let sealed = try PairingExchange.seal(grant, with: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try PairingExchange.open(sealed, with: SymmetricKey(size: .bits256)))
    }

    // MARK: Framing

    func testMessagesFrameAndSplitAcrossReads() throws {
        let messages: [PairingMessage] = [
            .commit(headsetID: "hs", headsetName: "Vision Pro", commitment: Data([1, 2, 3]), requested: [.screen, .projects]),
            .macHello(macID: "mac", macName: "Studio Mac", publicKey: Data(count: 32), nonce: Data(count: 32)),
            .deny,
        ]
        var stream = Data()
        for message in messages { stream.append(try message.framed()) }
        var buffer = Data()
        var received: [PairingMessage] = []
        for byte in stream {
            buffer.append(byte)
            while let message = try PairingMessage.take(from: &buffer) { received.append(message) }
        }
        XCTAssertEqual(received, messages)
    }

    func testOversizedFrameThrows() {
        var buffer = Data([0xFF, 0xFF, 0x00, 0x00])
        XCTAssertThrowsError(try PairingMessage.take(from: &buffer))
    }

    // MARK: Adapters

    func testLongwaveNamesKeepTheWireValues() {
        XCTAssertEqual(CompanionDiscovery.macServiceType, "_longwave-mac._tcp")
        XCTAssertEqual(CompanionDiscovery.knockServiceType, "_longwave-knock._tcp")
        XCTAssertEqual(CompanionDiscovery.pairServiceType, "_longwave-pair._tcp")
        XCTAssertEqual(CompanionDiscovery.Key.macID, "id")
        XCTAssertEqual(CompanionDiscovery.Key.headsetID, "hs")
        XCTAssertEqual(CompanionPairLink.defaultPort, 4859)
        // From the Longwave code before the move (RAVECompanionTests' vectors).
        XCTAssertEqual(CompanionDiscovery.knockTag(token: "tok-123", macID: "MAC-1", headsetID: "HS-1", minute: 29_000_000),
                       "h0HTFJVMA_OpRCZA")
        XCTAssertEqual(CompanionPairLink(url: URL(string: "longwave://pair?mac=M&name=N&addr=192.0.2.1")!)?.port, 4859)
    }
}
