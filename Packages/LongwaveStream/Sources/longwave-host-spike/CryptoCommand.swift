// SPIKE ONLY: the swift-crypto checks from StreamSpikeTests, run inside the
// shipped executable (so the packaged folder proves the crypto runtime too),
// plus the per-packet AEAD throughput v3 would need.
import Crypto
import StreamHostWindows
import StreamSpikeWire

func runCryptoSmoke() {
    func hex(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var iterator = string.utf8.makeIterator()
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : (c | 0x20) - 87 }
        while let high = iterator.next(), let low = iterator.next() { bytes.append(nibble(high) << 4 | nibble(low)) }
        return bytes
    }
    var failures = 0
    func expect(_ ok: Bool, _ what: String) {
        print("  \(ok ? "pass" : "FAIL")  \(what)")
        if !ok { failures += 1 }
    }
    do {
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        expect(shared.withUnsafeBytes { Array($0) } == hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"),
               "X25519 RFC 7748 6.1 shared secret")

        let key = SymmetricKey(data: hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
        let nonce = try ChaChaPoly.Nonce(data: hex("070000004041424344454647"))
        let aad = hex("50515253c0c1c2c3c4c5c6c7")
        let plaintext = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        expect(Array(box.tag) == hex("1ae10b594f09e26a7e902ecbd0600691"), "ChaCha20-Poly1305 RFC 8439 2.8.2 tag")
        expect(Array(try ChaChaPoly.open(box, using: key, authenticating: aad)) == plaintext, "ChaCha20-Poly1305 open")

        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: [UInt8](repeating: 0x0b, count: 22)),
                                         salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"),
                                         outputByteCount: 42)
        expect(okm.withUnsafeBytes { Array($0) } == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"),
               "HKDF-SHA256 RFC 5869 case 1")

        // Throughput: seal 1200-byte datagrams, as a v3 record layer would.
        let payload = [UInt8](repeating: 0xA5, count: SpikeWire.maxDatagram)
        let count = 100_000
        let start = HostClock.now()
        var sink = 0
        for i in 0..<count {
            var nonceBytes = [UInt8](repeating: 0, count: 12)
            withUnsafeBytes(of: UInt64(i).littleEndian) { nonceBytes.replaceSubrange(4..<12, with: $0) }
            let sealed = try ChaChaPoly.seal(payload, using: key, nonce: try ChaChaPoly.Nonce(data: nonceBytes))
            sink &+= Int(sealed.tag.first ?? 0)
        }
        let seconds = HostClock.milliseconds(HostClock.now() - start) / 1000
        print(String(format2: "  ChaChaPoly seal of %d x %d-byte datagrams: %.2f s = %.0f MB/s, %.2f us each (sink %d)",
                     count, payload.count, seconds, Double(count * payload.count) / seconds / 1e6,
                     seconds / Double(count) * 1e6, sink & 1))
    } catch {
        print("  FAIL  threw \(error)")
        failures += 1
    }
    print(failures == 0 ? "crypto: all checks passed" : "crypto: \(failures) FAILED")
}
