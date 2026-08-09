#if MOONLIGHT_ENABLED
import Foundation
import os
import Security
import CommonCrypto

actor CryptoManager {
    static let shared = CryptoManager()

    private static let keyTag = "pro.longwave.moonlight.clientkey"
    private static let certDefaultsKey = "moonlight_client_cert_der"
    private static let p12DefaultsKey = "moonlight_client_p12"
    private static let p12Password = "limelight"

    private var cachedPrivateKey: SecKey?
    private var cachedCertDER: Data?

    // MARK: - Client Identity

    /// Returns (privateKey, certificateDER). Generates and persists if needed.
    func getOrCreateIdentity() throws -> (privateKey: SecKey, certDER: Data) {
        if let key = cachedPrivateKey, let cert = cachedCertDER {
            return (key, cert)
        }

        // Try loading from Keychain / UserDefaults
        if let key = loadPrivateKey(), let cert = loadCertDER() {
            cachedPrivateKey = key
            cachedCertDER = cert
            return (key, cert)
        }

        // Generate new identity
        let (key, cert) = try generateIdentity()
        cachedPrivateKey = key
        cachedCertDER = cert
        return (key, cert)
    }

    func getClientCertPEM() throws -> String {
        let (_, certDER) = try getOrCreateIdentity()
        return Self.certDERToPEM(certDER)
    }

    func signWithClientKey(_ data: Data) throws -> Data {
        let (privateKey, _) = try getOrCreateIdentity()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw MoonlightError.cryptoError("RSA signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return signature
    }

    func getClientCertDER() throws -> Data {
        let (_, certDER) = try getOrCreateIdentity()
        return certDER
    }

    /// Get a SecIdentity for TLS client authentication via PKCS#12 import.
    /// This matches the moonlight-ios approach (SecPKCS12Import) which is more
    /// reliable than kSecClassIdentity Keychain queries on all Apple platforms.
    func getClientSecIdentity() throws -> SecIdentity {
        // Ensure key+cert exist
        let (_, _) = try getOrCreateIdentity()

        // Load or build PKCS#12
        let p12Data: Data
        if let stored = UserDefaults.standard.data(forKey: Self.p12DefaultsKey) {
            p12Data = stored
        } else {
            p12Data = try buildAndStorePKCS12()
        }

        do {
            return try Self.importPKCS12Identity(p12Data, password: Self.p12Password)
        } catch {
            // Cached P12 might be stale — rebuild and retry once
            AppLog.cryptoManager.line("PKCS#12 import failed, rebuilding: \(error)")
            UserDefaults.standard.removeObject(forKey: Self.p12DefaultsKey)
            let rebuilt = try buildAndStorePKCS12()
            return try Self.importPKCS12Identity(rebuilt, password: Self.p12Password)
        }
    }

    private static func importPKCS12Identity(_ p12Data: Data, password: String) throws -> SecIdentity {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess else {
            throw MoonlightError.cryptoError("SecPKCS12Import failed (OSStatus: \(status))")
        }

        guard let itemArray = items as? [[String: Any]] else {
            throw MoonlightError.cryptoError("SecPKCS12Import returned non-dictionary items")
        }

        guard let firstItem = itemArray.first else {
            throw MoonlightError.cryptoError("SecPKCS12Import returned empty items array (count: \(itemArray.count))")
        }

        AppLog.cryptoManager.line("P12 import keys: \(firstItem.keys.sorted())")

        guard let identity = firstItem[kSecImportItemIdentity as String] else {
            let keys = firstItem.keys.joined(separator: ", ")
            throw MoonlightError.cryptoError("SecPKCS12Import has no identity key. Available: [\(keys)]")
        }
        return identity as! SecIdentity
    }

    private func buildAndStorePKCS12() throws -> Data {
        let (privateKey, certDER) = try getOrCreateIdentity()
        var error: Unmanaged<CFError>?
        guard let pkData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw MoonlightError.cryptoError("Failed to export private key for PKCS#12")
        }
        let p12 = try Self.buildPKCS12(privateKeyPKCS1DER: pkData, certDER: certDER, password: Self.p12Password)
        UserDefaults.standard.set(p12, forKey: Self.p12DefaultsKey)
        return p12
    }

    func getClientSecCertificate() throws -> SecCertificate {
        let (_, certDER) = try getOrCreateIdentity()
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw MoonlightError.cryptoError("Failed to create SecCertificate")
        }
        return cert
    }

    // MARK: - Key/Cert Persistence

    private func generateIdentity() throws -> (SecKey, Data) {
        // Delete any existing key
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Clear cached PKCS#12 (will be rebuilt on next getClientSecIdentity call)
        UserDefaults.standard.removeObject(forKey: Self.p12DefaultsKey)

        // Generate RSA 2048 key pair, stored permanently in Keychain
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw MoonlightError.cryptoError("Key generation failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw MoonlightError.cryptoError("Failed to extract public key")
        }

        // Export public key as PKCS#1 DER
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw MoonlightError.cryptoError("Failed to export public key")
        }

        // Build self-signed X.509 certificate
        let certDER = try buildSelfSignedCert(publicKeyDER: publicKeyDER, privateKey: privateKey)

        // Store cert DER in UserDefaults
        UserDefaults.standard.set(certDER, forKey: Self.certDefaultsKey)

        return (privateKey, certDER)
    }

    private func loadPrivateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecKey)
    }

    private func loadCertDER() -> Data? {
        UserDefaults.standard.data(forKey: Self.certDefaultsKey)
    }

    // MARK: - X.509 Certificate Builder

    private func buildSelfSignedCert(publicKeyDER: Data, privateKey: SecKey) throws -> Data {
        let now = Date()
        let twentyYears = TimeInterval(60 * 60 * 24 * 365 * 20)
        let notAfter = now.addingTimeInterval(twentyYears)

        // Signature algorithm identifier
        let sigAlgId = ASN1.sequence(ASN1.oid(ASN1.sha256WithRSAEncryption) + ASN1.null())

        // Subject/Issuer: CN=NVIDIA GameStream Client
        let cnAttr = ASN1.sequence(ASN1.oid(ASN1.commonName) + ASN1.utf8String("NVIDIA GameStream Client"))
        let name = ASN1.sequence(ASN1.set(cnAttr))

        // Subject Public Key Info: wrap PKCS#1 key in SubjectPublicKeyInfo
        let spki = ASN1.sequence(
            ASN1.sequence(ASN1.oid(ASN1.rsaEncryption) + ASN1.null()) +
            ASN1.bitString(publicKeyDER)
        )

        // TBS Certificate
        var tbsContent = Data()
        tbsContent.append(ASN1.contextExplicit(0, ASN1.integer(2))) // version v3
        tbsContent.append(ASN1.integer(0))                          // serialNumber
        tbsContent.append(sigAlgId)                                   // signature algorithm
        tbsContent.append(name)                                       // issuer
        tbsContent.append(ASN1.sequence(ASN1.utcTime(now) + ASN1.utcTime(notAfter))) // validity
        tbsContent.append(name)                                       // subject
        tbsContent.append(spki)                                       // subjectPublicKeyInfo

        let tbsCert = ASN1.sequence(tbsContent)

        // Sign TBS with private key (SHA-256 + RSA PKCS#1 v1.5)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCert as CFData,
            &error
        ) as Data? else {
            throw MoonlightError.cryptoError("Certificate signing failed")
        }

        // Full certificate: TBS + algorithm + signature
        return ASN1.sequence(tbsCert + sigAlgId + ASN1.bitString(signature))
    }

    // MARK: - Static Crypto Operations

    static func aesEncryptECB(_ data: Data, key: Data) throws -> Data {
        try aesECB(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func aesDecryptECB(_ data: Data, key: Data) throws -> Data {
        try aesECB(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func aesECB(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        let bufferSize = data.count + kCCBlockSizeAES128
        var outBuffer = [UInt8](repeating: 0, count: bufferSize)
        var outLength: Int = 0

        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress, key.count,
                    nil, // no IV for ECB
                    dataPtr.baseAddress, data.count,
                    &outBuffer, bufferSize,
                    &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw MoonlightError.cryptoError("AES-ECB failed with status \(status)")
        }

        return Data(outBuffer.prefix(outLength))
    }

    static func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    static func sha1(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            hash.withUnsafeMutableBytes { hashPtr in
                _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash
    }

    static func verifySignature(_ data: Data, signature: Data, publicKey: SecKey) -> Bool {
        SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            signature as CFData,
            nil
        )
    }

    /// Extract the raw signature bytes from a DER-encoded X.509 certificate
    static func extractSignatureFromCert(_ certDER: Data) -> Data? {
        let bytes = Array(certDER)
        guard bytes.count > 2, bytes[0] == 0x30 else { return nil }

        // Parse outer SEQUENCE
        guard let (_, outerStart) = parseTagLength(bytes, offset: 0) else { return nil }
        var offset = outerStart

        // Skip TBS Certificate (first SEQUENCE)
        guard let (tbsLen, tbsStart) = parseTagLength(bytes, offset: offset) else { return nil }
        offset = tbsStart + tbsLen

        // Skip Signature Algorithm (second SEQUENCE)
        guard let (algLen, algStart) = parseTagLength(bytes, offset: offset) else { return nil }
        offset = algStart + algLen

        // Read Signature (BIT STRING: tag 0x03)
        guard offset < bytes.count, bytes[offset] == 0x03 else { return nil }
        guard let (sigLen, sigStart) = parseTagLength(bytes, offset: offset) else { return nil }

        // BIT STRING content: first byte is unused bits count (0x00), rest is signature
        let dataStart = sigStart + 1
        let dataEnd = sigStart + sigLen
        guard dataStart < dataEnd, dataEnd <= bytes.count else { return nil }

        return Data(bytes[dataStart..<dataEnd])
    }

    private static func parseTagLength(_ bytes: [UInt8], offset: Int) -> (contentLength: Int, contentStart: Int)? {
        guard offset + 1 < bytes.count else { return nil }
        var pos = offset + 1 // skip tag

        let firstLen = bytes[pos]
        pos += 1

        let length: Int
        if firstLen < 128 {
            length = Int(firstLen)
        } else {
            let numBytes = Int(firstLen & 0x7F)
            guard pos + numBytes <= bytes.count else { return nil }
            var len = 0
            for i in 0..<numBytes {
                len = (len << 8) | Int(bytes[pos + i])
            }
            pos += numBytes
            length = len
        }

        return (length, pos)
    }

    // MARK: - PKCS#12 Builder

    /// Build a PKCS#12 blob containing the client private key and certificate.
    /// Uses PBE-SHA1-3DES for key encryption and SHA-1 HMAC for MAC,
    /// matching the moonlight-ios format that iOS/visionOS reliably accepts.
    static func buildPKCS12(privateKeyPKCS1DER: Data, certDER: Data, password: String) throws -> Data {
        let keySalt = randomBytes(8)
        let keyIterations = 2048
        let macSalt = randomBytes(8)

        // localKeyId = SHA-1(certDER) — links the key bag to the cert bag
        // (matches OpenSSL's PKCS12_create which uses X509_digest)
        let localKeyId = sha1(certDER)

        // Bag attributes: localKeyId (required for SecPKCS12Import to link key+cert)
        let bagAttributes = ASN1.set(
            ASN1.sequence(
                ASN1.oid(ASN1.localKeyIdOID) +
                ASN1.set(ASN1.octetString(localKeyId))
            )
        )

        // Wrap PKCS#1 private key in PKCS#8 PrivateKeyInfo
        let pkcs8Key = ASN1.sequence(
            ASN1.integer(0) +
            ASN1.sequence(ASN1.oid(ASN1.rsaEncryption) + ASN1.null()) +
            ASN1.octetString(privateKeyPKCS1DER)
        )

        // Encrypt PKCS#8 key with PBE-SHA1-3DES
        let encryptedKey = try pbeEncrypt3DES(data: pkcs8Key, password: password,
                                              salt: keySalt, iterations: keyIterations)

        // EncryptedPrivateKeyInfo (for pkcs8ShroudedKeyBag)
        let encryptedKeyInfo = ASN1.sequence(
            ASN1.sequence(
                ASN1.oid(ASN1.pbeWithSHA1And3DES) +
                ASN1.sequence(ASN1.octetString(keySalt) + ASN1.integer(keyIterations))
            ) +
            ASN1.octetString(encryptedKey)
        )

        // Cert SafeBag (with localKeyId attribute)
        let certBag = ASN1.sequence(
            ASN1.oid(ASN1.certBagOID) +
            ASN1.contextExplicit(0,
                ASN1.sequence(
                    ASN1.oid(ASN1.x509CertificateOID) +
                    ASN1.contextExplicit(0, ASN1.octetString(certDER))
                )
            ) +
            bagAttributes
        )

        // Key SafeBag (pkcs8ShroudedKeyBag, with localKeyId attribute)
        let keyBag = ASN1.sequence(
            ASN1.oid(ASN1.pkcs8ShroudedKeyBagOID) +
            ASN1.contextExplicit(0, encryptedKeyInfo) +
            bagAttributes
        )

        // SafeContents = SEQUENCE of SafeBag
        let safeContents = ASN1.sequence(certBag + keyBag)

        // ContentInfo wrapping SafeContents (unencrypted pkcs7-data)
        let safeContentInfo = ASN1.sequence(
            ASN1.oid(ASN1.pkcs7DataOID) +
            ASN1.contextExplicit(0, ASN1.octetString(safeContents))
        )

        // AuthenticatedSafe = SEQUENCE OF ContentInfo
        let authSafe = ASN1.sequence(safeContentInfo)

        // Outer ContentInfo
        let outerContent = ASN1.sequence(
            ASN1.oid(ASN1.pkcs7DataOID) +
            ASN1.contextExplicit(0, ASN1.octetString(authSafe))
        )

        // MAC (SHA-1 HMAC with 1 iteration, matching moonlight-ios)
        let macKey = pkcs12KDF(password: password, salt: macSalt, iterations: 1,
                               id: 3, outputLength: 20)
        let macValue = hmacSHA1(key: macKey, data: authSafe)

        let macData = ASN1.sequence(
            ASN1.sequence(
                ASN1.sequence(ASN1.oid(ASN1.sha1OID) + ASN1.null()) +
                ASN1.octetString(macValue)
            ) +
            ASN1.octetString(macSalt) +
            ASN1.integer(1)
        )

        // PFX = SEQUENCE { version, authSafe, macData }
        return ASN1.sequence(
            ASN1.integer(3) +
            outerContent +
            macData
        )
    }

    // MARK: - PKCS#12 Key Derivation (RFC 7292, Appendix B.2)

    /// Derives key material from a password and salt using the PKCS#12 KDF.
    /// - Parameters:
    ///   - id: 1 = encryption key, 2 = IV, 3 = MAC key
    static func pkcs12KDF(password: String, salt: Data, iterations: Int,
                          id: UInt8, outputLength: Int) -> Data {
        let v = 64 // SHA-1 block size in bytes
        let u = 20 // SHA-1 output size in bytes

        // D = id byte repeated v times
        let D = Data(repeating: id, count: v)

        // S = salt repeated to fill v*ceil(|salt|/v) bytes
        let S: Data
        if salt.isEmpty {
            S = Data()
        } else {
            let sLen = v * ((salt.count + v - 1) / v)
            var s = Data(capacity: sLen)
            for i in 0..<sLen { s.append(salt[i % salt.count]) }
            S = s
        }

        // Password as BMP string (UTF-16BE) with null terminator
        var bmpPassword = Data()
        for scalar in password.unicodeScalars {
            bmpPassword.append(UInt8((scalar.value >> 8) & 0xFF))
            bmpPassword.append(UInt8(scalar.value & 0xFF))
        }
        bmpPassword.append(contentsOf: [0x00, 0x00])

        // P = BMP password repeated to fill v*ceil(|P|/v) bytes
        let P: Data
        let pLen = v * ((bmpPassword.count + v - 1) / v)
        var p = Data(capacity: pLen)
        for i in 0..<pLen { p.append(bmpPassword[i % bmpPassword.count]) }
        P = p

        // I = S || P
        var I = S + P

        var result = Data()

        while result.count < outputLength {
            // A = H^iterations(D || I)
            var A = sha1(D + I)
            for _ in 1..<iterations {
                A = sha1(A)
            }
            result.append(A)

            if result.count >= outputLength { break }

            // Extend A to v bytes by repeating
            var B = Data(capacity: v)
            for i in 0..<v { B.append(A[i % u]) }

            // I_j = (I_j + B + 1) mod 2^(v*8) for each v-byte block of I
            var newI = Data()
            for j in stride(from: 0, to: I.count, by: v) {
                let end = min(j + v, I.count)
                var carry: UInt16 = 1
                var block = [UInt8](repeating: 0, count: v)
                for k in stride(from: v - 1, through: 0, by: -1) {
                    let idx = j + k
                    carry += UInt16(idx < end ? I[idx] : 0) + UInt16(B[k])
                    block[k] = UInt8(carry & 0xFF)
                    carry >>= 8
                }
                newI.append(contentsOf: block)
            }
            I = newI
        }

        return result.prefix(outputLength)
    }

    /// Encrypt data using PBE-SHA1-3DES-CBC (PKCS#12 password-based encryption).
    static func pbeEncrypt3DES(data: Data, password: String, salt: Data,
                               iterations: Int) throws -> Data {
        let key = pkcs12KDF(password: password, salt: salt, iterations: iterations,
                            id: 1, outputLength: 24)
        let iv = pkcs12KDF(password: password, salt: salt, iterations: iterations,
                           id: 2, outputLength: 8)

        let bufferSize = data.count + kCCBlockSize3DES
        var outBuffer = [UInt8](repeating: 0, count: bufferSize)
        var outLength: Int = 0

        let status = data.withUnsafeBytes { dataPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithm3DES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, 24,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress, data.count,
                        &outBuffer, bufferSize,
                        &outLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MoonlightError.cryptoError("3DES-PBE encryption failed (status: \(status))")
        }

        return Data(outBuffer.prefix(outLength))
    }

    /// HMAC-SHA1 for PKCS#12 MAC computation.
    static func hmacSHA1(key: Data, data: Data) -> Data {
        var hmac = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                hmac.withUnsafeMutableBytes { hmacPtr in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA1),
                        keyPtr.baseAddress, key.count,
                        dataPtr.baseAddress, data.count,
                        hmacPtr.baseAddress
                    )
                }
            }
        }
        return hmac
    }

    // MARK: - PEM Conversion

    static func certDERToPEM(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }

    static func pemToCertDER(_ pem: String) -> Data? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Data(base64Encoded: stripped)
    }

    // MARK: - Random Bytes

    static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return bytes
    }
}

// MARK: - ASN.1 DER Builder

private enum ASN1 {
    // Well-known OIDs
    nonisolated(unsafe) static let sha256WithRSAEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    nonisolated(unsafe) static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    nonisolated(unsafe) static let commonName: [UInt8] = [0x55, 0x04, 0x03]

    // PKCS#12 OIDs
    nonisolated(unsafe) static let pkcs7DataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
    nonisolated(unsafe) static let certBagOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03]
    nonisolated(unsafe) static let pkcs8ShroudedKeyBagOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02]
    nonisolated(unsafe) static let x509CertificateOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01]
    nonisolated(unsafe) static let pbeWithSHA1And3DES: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03]
    nonisolated(unsafe) static let sha1OID: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]
    nonisolated(unsafe) static let localKeyIdOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15]

    nonisolated static func wrap(tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: lengthBytes(content.count))
        result.append(content)
        return result
    }

    nonisolated static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    nonisolated static func sequence(_ content: Data) -> Data { wrap(tag: 0x30, content) }
    nonisolated static func set(_ content: Data) -> Data { wrap(tag: 0x31, content) }
    nonisolated static func null() -> Data { Data([0x05, 0x00]) }
    nonisolated static func oid(_ bytes: [UInt8]) -> Data { wrap(tag: 0x06, Data(bytes)) }
    nonisolated static func utf8String(_ string: String) -> Data { wrap(tag: 0x0C, Data(string.utf8)) }
    nonisolated static func octetString(_ content: Data) -> Data { wrap(tag: 0x04, content) }

    nonisolated static func bitString(_ content: Data) -> Data {
        var inner = Data([0x00]) // 0 unused bits
        inner.append(content)
        return wrap(tag: 0x03, inner)
    }

    nonisolated static func integer(_ value: Int) -> Data {
        if value == 0 {
            return wrap(tag: 0x02, Data([0x00]))
        }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return wrap(tag: 0x02, Data(bytes))
    }

    nonisolated static func contextExplicit(_ tag: UInt8, _ content: Data) -> Data {
        wrap(tag: 0xA0 | tag, content)
    }

    nonisolated static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return wrap(tag: 0x17, Data(formatter.string(from: date).utf8))
    }
}
#endif
