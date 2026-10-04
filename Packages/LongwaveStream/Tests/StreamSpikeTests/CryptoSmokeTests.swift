// NATIVE_V3_PROTOCOL.md risk 11: does swift-crypto build and work on x64
// Windows? Published test vectors, so a pass means the right answer, not just
// a self-consistent one.
import Crypto
import XCTest

final class CryptoSmokeTests: XCTestCase {
    func testX25519MatchesRFC7748() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        XCTAssertEqual(Array(alice.publicKey.rawRepresentation), hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
        XCTAssertEqual(Array(bob.publicKey.rawRepresentation), hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        XCTAssertEqual(shared.withUnsafeBytes { Array($0) }, hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"))
    }

    func testChaChaPolyMatchesRFC8439() throws {
        let key = SymmetricKey(data: hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
        let nonce = try ChaChaPoly.Nonce(data: hex("070000004041424344454647"))
        let aad = hex("50515253c0c1c2c3c4c5c6c7")
        let plaintext = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        XCTAssertEqual(Array(box.tag), hex("1ae10b594f09e26a7e902ecbd0600691"))
        XCTAssertEqual(Array(box.ciphertext.prefix(16)), hex("d31a8d34648e60db7b86afbc53ef7ec2"))
        XCTAssertEqual(Array(try ChaChaPoly.open(box, using: key, authenticating: aad)), plaintext)
        var tampered = Array(box.combined)
        tampered[20] ^= 1
        XCTAssertThrowsError(try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: tampered), using: key, authenticating: aad))
    }

    func testHKDFAndSHA256() {
        XCTAssertEqual(Array(SHA256.hash(data: Array("abc".utf8))),
                       hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        // RFC 5869 test case 1.
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: [UInt8](repeating: 0x0b, count: 22)),
                                         salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"),
                                         outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Array($0) },
                       hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }
}

func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var iterator = string.utf8.makeIterator()
    func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 0x20) - 87 }
    while let high = iterator.next(), let low = iterator.next() { bytes.append(nibble(high) << 4 | nibble(low)) }
    return bytes
}
