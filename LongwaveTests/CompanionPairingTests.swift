import CryptoKit
import XCTest
@testable import Longwave

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
                mine: headset, theirPublicKey: macPublicKey ?? mac.publicKey, commitment: commitment,
                headsetPublicKey: headset.publicKey, headsetNonce: headset.nonce,
                macPublicKey: macPublicKey ?? mac.publicKey, macNonce: mac.nonce
            )
        }

        func macSide(revealedKey: Data? = nil, revealedNonce: Data? = nil) -> PairingExchange.Agreement? {
            PairingExchange.agree(
                mine: mac, theirPublicKey: revealedKey ?? headset.publicKey, commitment: commitment,
                headsetPublicKey: revealedKey ?? headset.publicKey, headsetNonce: revealedNonce ?? headset.nonce,
                macPublicKey: mac.publicKey, macNonce: mac.nonce
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
        let grant = PairingGrant(token: "secret", macID: "mac", macName: "Pegasus", addresses: ["172.20.48.198"])
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
            mine: run.mac, theirPublicKey: fakeHeadset.publicKey, commitment: fakeCommitment,
            headsetPublicKey: fakeHeadset.publicKey, headsetNonce: fakeHeadset.nonce,
            macPublicKey: run.mac.publicKey, macNonce: run.mac.nonce
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
            .commit(headsetID: "hs", headsetName: "Vision Pro", commitment: Data([1, 2, 3])),
            .macHello(macID: "mac", macName: "Pegasus", publicKey: Data(count: 32), nonce: Data(count: 32)),
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
}
