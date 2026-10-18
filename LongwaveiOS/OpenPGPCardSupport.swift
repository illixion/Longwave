@preconcurrency import CoreNFC
import Foundation
import DebugTrace
import CryptoKit
import NIOCore
import NIOSSH


nonisolated struct SendableNFCCard: @unchecked Sendable {
    let value: any NFCISO7816Tag
}



nonisolated enum OpenPGPMetadata {
    enum ParseError: Error { case malformed }

    static func summary(_ data: Data) throws -> [String: String] {
        guard data.count <= 65_536 else { throw ParseError.malformed }
        var fields: [Int: [UInt8]] = [:]
        try read(Array(data), depth: 0, fields: &fields)
        guard fields[0xC3] != nil else { throw ParseError.malformed }
        var result: [String: String] = [:]
        for (tag, label) in [(0xC1, "Signing algorithm"), (0xC2, "Decryption algorithm"), (0xC3, "Authentication algorithm")] {
            if let value = fields[tag] { result[label] = algorithm(value) }
        }
        if let aid = fields[0x4F], aid.count == 16,
           Array(aid.prefix(6)) == [0xD2, 0x76, 0x00, 0x01, 0x24, 0x01] {
            let major = aid[6], minor = aid[7]
            if major & 0x0F <= 9, major >> 4 <= 9, minor & 0x0F <= 9, minor >> 4 <= 9 {
                result["OpenPGP version"] = "\((major >> 4) * 10 + (major & 15)).\((minor >> 4) * 10 + (minor & 15))"
            }
        }
        if let pw = fields[0xC4], pw.count == 7 {
            result["User PIN retries"] = String(pw[4])
            result["Reset code retries"] = String(pw[5])
            result["Admin PIN retries"] = String(pw[6])
        }
        if let fingerprints = fields[0xC5], fingerprints.count >= 60, fingerprints.count % 20 == 0 {
            for (index, label) in ["Signing key present", "Decryption key present", "Authentication key present"].enumerated() {
                result[label] = fingerprints[(index * 20)..<(index * 20 + 20)].contains(where: { $0 != 0 }) ? "Yes" : "No"
            }
        }
        for (tag, label) in [(0xD6, "Signing touch policy"), (0xD7, "Decryption touch policy"), (0xD8, "Authentication touch policy")] {
            if let uif = fields[tag], uif.count == 2 {
                switch uif[0] {
                case 0: result[label] = "Not required"
                case 1: result[label] = "Required"
                case 2: result[label] = "Required (fixed)"
                case 3: result[label] = "Cached"
                case 4: result[label] = "Cached (fixed)"
                default: result[label] = "Unrecognized policy"
                }
            }
        }
        return result
    }

    private static func read(_ bytes: [UInt8], depth: Int, fields: inout [Int: [UInt8]]) throws {
        guard depth <= 4 else { throw ParseError.malformed }
        var offset = 0
        while offset < bytes.count {
            let first = bytes[offset]
            offset += 1
            var tag = Int(first)
            if first & 0x1F == 0x1F {
                var octets = 0
                while true {
                    guard offset < bytes.count, octets < 2 else { throw ParseError.malformed }
                    let next = bytes[offset]
                    offset += 1
                    octets += 1
                    tag = (tag << 8) | Int(next)
                    if next & 0x80 == 0 { break }
                }
            }
            guard offset < bytes.count else { throw ParseError.malformed }
            let lengthByte = bytes[offset]
            offset += 1
            var length = Int(lengthByte)
            if lengthByte & 0x80 != 0 {
                let octets = Int(lengthByte & 0x7F)
                guard (1...3).contains(octets), bytes.count - offset >= octets else { throw ParseError.malformed }
                length = 0
                for _ in 0..<octets {
                    length = (length << 8) | Int(bytes[offset])
                    offset += 1
                }
            }
            guard length <= bytes.count - offset else { throw ParseError.malformed }
            let value = Array(bytes[offset..<(offset + length)])
            offset += length
            // Recurse only into the two known containers. Never parse opaque
            // fingerprints, certificates or algorithm values as nested TLVs.
            if tag == 0x6E || tag == 0x73 {
                try read(value, depth: depth + 1, fields: &fields)
            } else if [0x4F, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xD6, 0xD7, 0xD8].contains(tag) {
                guard fields[tag] == nil else { throw ParseError.malformed }
                fields[tag] = value
            }
        }
    }

    static func field(_ tag: Int, in data: Data) throws -> Data? {
        guard data.count <= 65_536 else { throw ParseError.malformed }
        var fields: [Int: [UInt8]] = [:]
        try read(Array(data), depth: 0, fields: &fields)
        return fields[tag].map { Data($0) }
    }

    private static func algorithm(_ value: [UInt8]) -> String {
        guard let id = value.first else { return "Missing attributes" }
        if id == 1 {
            guard value.count == 6 else { return "Malformed RSA attributes" }
            return "RSA \(Int(value[1]) * 256 + Int(value[2])) bits"
        }
        let family: String
        switch id {
        case 18: family = "ECDH"
        case 19: family = "ECDSA"
        case 22: family = "EdDSA"
        default: return "Unrecognized algorithm"
        }
        var oid = Array(value.dropFirst())
        if oid.last == 0xFF { oid.removeLast() } // Optional public-key import marker.
        let curves: [([UInt8], String)] = [
            ([0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01], "Ed25519"),
            ([0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01], "Curve25519"),
            ([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07], "P-256"),
            ([0x2B, 0x81, 0x04, 0x00, 0x22], "P-384"),
            ([0x2B, 0x81, 0x04, 0x00, 0x23], "P-521")
        ]
        // Match Yubico's CurveOid handling: firmware can return trailing
        // attribute bytes after the registered curve OID.
        return family + " / " + (curves.first(where: { oid.starts(with: $0.0) })?.1 ?? "Unrecognized curve")
    }
}

nonisolated enum OpenPGPCardChannel {
    static func exchange(
        card: SendableNFCCard,
        apdu: NFCISO7816APDU,
        accumulated: Data = Data(),
        attempts: Int = 0,
        completion: @escaping @Sendable (Data, UInt8, UInt8, Error?) -> Void
    ) {
        guard attempts < 32 else {
            completion(Data(), 0, 0, NSError(domain: "OpenPGPNFC", code: 1))
            return
        }
        let request = OpenPGPSendableAPDU(value: apdu)
        card.value.sendCommand(apdu: request.value) { response, sw1, sw2, error in
            guard error == nil else {
                completion(Data(), sw1, sw2, error)
                return
            }
            guard accumulated.count + response.count <= 65_536 else {
                completion(Data(), 0, 0, NSError(domain: "OpenPGPNFC", code: 2))
                return
            }
            if sw1 == 0x6C && [0xA4, 0xCA, 0xC0, 0x47].contains(request.value.instructionCode) {
                let corrected = NFCISO7816APDU(
                    instructionClass: request.value.instructionClass,
                    instructionCode: request.value.instructionCode,
                    p1Parameter: request.value.p1Parameter,
                    p2Parameter: request.value.p2Parameter,
                    data: request.value.data ?? Data(),
                    expectedResponseLength: sw2 == 0 ? 256 : Int(sw2)
                )
                Self.exchange(card: card, apdu: corrected, accumulated: accumulated, attempts: attempts + 1, completion: completion)
                return
            }
            var collected = accumulated
            collected.append(response)
            AppLog.app.log("OpenPGP NFC APDU response: status \(Int(sw1) * 256 + Int(sw2), privacy: .public), bytes \(response.count, privacy: .public), round trip \(attempts + 1, privacy: .public)")
            if sw1 == 0x61 {
                let getResponse = NFCISO7816APDU(
                    instructionClass: 0x00,
                    instructionCode: 0xC0,
                    p1Parameter: 0x00,
                    p2Parameter: 0x00,
                    data: Data(),
                    expectedResponseLength: sw2 == 0 ? 256 : Int(sw2)
                )
                Self.exchange(card: card, apdu: getResponse, accumulated: collected, attempts: attempts + 1, completion: completion)
            } else {
                completion(collected, sw1, sw2, nil)
            }
        }
    }

}

nonisolated struct OpenPGPSendableAPDU: @unchecked Sendable {
    let value: NFCISO7816APDU
}


/// Holds only the session-scoped NFC handle and public key. SSH passes its exact
/// Ed25519 user-auth payload here; card commands and returned signatures stay local.
final class OpenPGPNFCSSHSigner: @unchecked Sendable {
    private let card: SendableNFCCard
    private let publicKey: Curve25519.Signing.PublicKey

    init(card: SendableNFCCard, publicKey: Curve25519.Signing.PublicKey) {
        self.card = card
        self.publicKey = publicKey
    }

    @MainActor
    func sign(_ payload: Data, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        let apdu = NFCISO7816APDU(
            instructionClass: 0,
            instructionCode: 0x88,
            p1Parameter: 0,
            p2Parameter: 0,
            data: payload,
            expectedResponseLength: 256
        )
        OpenPGPCardChannel.exchange(card: card, apdu: apdu) { [publicKey] signature, sw1, sw2, error in
            guard error == nil, sw1 == 0x90, sw2 == 0x00,
                  signature.count == 64,
                  publicKey.isValidSignature(signature, for: payload) else {
                completion(.failure(OpenPGPSSHSigningError.signatureFailed))
                return
            }
            completion(.success(signature))
        }
    }
}

private enum OpenPGPSSHSigningError: Error {
    case signatureFailed
}

nonisolated final class OpenPGPHostFingerprintDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: String

    init(expected: String) { self.expected = expected }

    nonisolated static func isValid(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:") else { return false }
        let encoded = String(value.dropFirst("SHA256:".count))
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let digest = Data(base64Encoded: padded), digest.count == 32,
              digest.base64EncodedString().replacingOccurrences(of: "=", with: "") == encoded else {
            return false
        }
        return true
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fields = String(openSSHPublicKey: hostKey).split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
            validationCompletePromise.fail(OpenPGPHostKeyError.invalid)
            return
        }
        let actual = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        guard Self.isValid(expected), actual == expected else {
            validationCompletePromise.fail(OpenPGPHostKeyError.mismatch)
            return
        }
        validationCompletePromise.succeed(())
    }
}

private enum OpenPGPHostKeyError: Error {
    case invalid
    case mismatch
}

nonisolated private struct OpenPGPAuthenticationReply: Sendable {
    let data: Data
    let word: Int
}

nonisolated enum OpenPGPAuthenticationError: Error, CustomStringConvertible {
    case message(String)
    case status(String, Int)
    var description: String {
        switch self {
        case .message(let text): return text
        case .status(let stage, let word): return "\(stage) returned \(String(format: "%04X", word)). No automatic PIN retry was made."
        }
    }
}

nonisolated enum OpenPGPAuthenticationCodec {
    static func fields(_ input: Data) throws -> [Int: Data] {
        let bytes = Array(input)
        guard bytes.count <= 65_536 else { throw OpenPGPAuthenticationError.message("Card response is too large.") }
        var offset = 0
        var result: [Int: Data] = [:]
        while offset < bytes.count {
            let first = bytes[offset]; offset += 1
            var tag = Int(first)
            if first & 31 == 31 {
                var count = 0
                repeat {
                    guard offset < bytes.count, count < 2 else { throw OpenPGPAuthenticationError.message("Malformed card data.") }
                    let next = bytes[offset]; offset += 1; count += 1
                    tag = (tag << 8) | Int(next)
                    if next & 128 == 0 { break }
                } while true
            }
            guard offset < bytes.count else { throw OpenPGPAuthenticationError.message("Malformed card data.") }
            let firstLength = bytes[offset]; offset += 1
            var length = Int(firstLength)
            if firstLength & 128 != 0 {
                let count = Int(firstLength & 127)
                guard (1...2).contains(count), bytes.count - offset >= count else { throw OpenPGPAuthenticationError.message("Malformed card length.") }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset, result[tag] == nil else { throw OpenPGPAuthenticationError.message("Malformed card data.") }
            result[tag] = Data(bytes[offset..<(offset + length)])
            offset += length
        }
        return result
    }

    static func publicKey(_ input: Data) throws -> Data {
        guard let template = try fields(input)[0x7F49], var key = try fields(template)[0x86] else {
            throw OpenPGPAuthenticationError.message("Missing authentication public key.")
        }
        if key.count == 33, key.first == 0x40 { key = Data(key.dropFirst()) }
        guard key.count == 32 else { throw OpenPGPAuthenticationError.message("Unexpected Ed25519 public key length.") }
        return key
    }

    static func kdfDisabled(_ input: Data) throws -> Bool {
        if input.isEmpty { return true }
        let outer = try fields(input)
        let values = try outer[0xF9].map { try fields($0) } ?? outer
        return values[0x81] == Data([0])
    }

    static func processPIN(_ pin: Data, configuration: Data) throws -> Data {
        if try kdfDisabled(configuration) { return pin }
        let outer = try fields(configuration)
        let values = try outer[0xF9].map { try fields($0) } ?? outer
        guard values[0x81] == Data([3]), let hash = values[0x82], hash.count == 1,
              let countBytes = values[0x83], countBytes.count == 4,
              let salt = values[0x84], salt.count == 8 else {
            throw OpenPGPAuthenticationError.message("Unsupported PIN KDF parameters. No PIN was sent.")
        }
        let count = countBytes.reduce(0) { ($0 << 8) | Int($1) }
        let block = salt + pin
        guard count >= block.count, count <= 64 * 1024 * 1024 else {
            throw OpenPGPAuthenticationError.message("Unsupported PIN KDF work factor. No PIN was sent.")
        }
        switch hash.first {
        case 8: return derivePIN(block, byteCount: count, using: SHA256.self)
        case 10: return derivePIN(block, byteCount: count, using: SHA512.self)
        default: throw OpenPGPAuthenticationError.message("Unsupported PIN KDF hash. No PIN was sent.")
        }
    }

    private static func derivePIN<H: HashFunction>(_ block: Data, byteCount: Int, using: H.Type) -> Data {
        // The count is bytes hashed, not repeated hash invocations. Use a
        // whole-number repetition buffer to preserve the S2K byte stream.
        let repetitions = max(1, 32_768 / block.count)
        var chunk = Data()
        for _ in 0..<repetitions { chunk.append(block) }
        var hasher = H()
        var remaining = byteCount
        while remaining >= chunk.count {
            hasher.update(data: chunk)
            remaining -= chunk.count
        }
        hasher.update(data: chunk.prefix(remaining))
        return Data(hasher.finalize())
    }

    static func sshKey(_ key: Data) -> String {
        func string(_ bytes: Data) -> Data {
            let size = UInt32(bytes.count)
            return Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + bytes
        }
        return "ssh-ed25519 " + (string(Data("ssh-ed25519".utf8)) + string(key)).base64EncodedString()
    }
}
