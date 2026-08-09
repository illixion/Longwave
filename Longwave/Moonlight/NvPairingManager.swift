#if MOONLIGHT_ENABLED
import Foundation
import Security

/// Implements the Moonlight/GameStream pairing protocol.
/// Multi-step challenge-response using AES-128-ECB and SHA-256 RSA signatures.
actor NvPairingManager {

    enum PairResult: Sendable {
        case success(serverCertDER: Data)
        case pinRejected
        case alreadyInProgress
        case failed(String)
    }

    private let cryptoManager: CryptoManager

    init(cryptoManager: CryptoManager = .shared) {
        self.cryptoManager = cryptoManager
    }

    /// Execute the full pairing handshake.
    /// - Parameters:
    ///   - client: HTTP client connected to the target server
    ///   - pin: 4-digit PIN displayed to the user (must be entered on server)
    ///   - serverInfo: Server info for hash algorithm selection
    func pair(with client: NvHTTPClient, pin: String, serverInfo: ServerInfo) async throws -> PairResult {
        let useSHA256 = serverInfo.usesSHA256
        let hashLength = useSHA256 ? 32 : 20

        // Step 0: Derive AES key from salt + PIN
        let salt = CryptoManager.randomBytes(16)
        var saltedPin = Data()
        saltedPin.append(salt)
        saltedPin.append(Data(pin.utf8))

        let hashResult = useSHA256 ? CryptoManager.sha256(saltedPin) : CryptoManager.sha1(saltedPin)
        let aesKey = hashResult.prefix(16) // Truncate to 128-bit AES key

        // Get client certificate PEM
        let clientCertPEM = try await cryptoManager.getClientCertPEM()
        let clientCertHex = Data(clientCertPEM.utf8).hexString

        // Step 1: Send salt + client cert, receive server cert
        let step1Response = try await client.pairRequest(args: [
            ("phrase", "getservercert"),
            ("salt", salt.hexString),
            ("clientcert", clientCertHex),
        ], timeout: 0) // No timeout — waits for user to enter PIN on server

        try step1Response.verifyStatus()

        guard step1Response.elements["paired"] == "1" else {
            return .failed("Server rejected pairing request")
        }

        guard let serverCertHex = step1Response.elements["plaincert"] else {
            // No cert means server is already in a pairing session
            try? await client.unpair()
            return .alreadyInProgress
        }

        // Decode server certificate (hex → PEM bytes → DER)
        guard let serverCertPEMData = Data(hexString: serverCertHex) else {
            return .failed("Invalid server certificate encoding")
        }
        let serverCertPEM = String(data: serverCertPEMData, encoding: .utf8) ?? ""
        guard let serverCertDER = CryptoManager.pemToCertDER(serverCertPEM) else {
            return .failed("Failed to decode server certificate")
        }

        // Pin this cert for the HTTPS session
        try await client.setServerCert(serverCertDER)

        // Step 2: Client challenge
        let randomChallenge = CryptoManager.randomBytes(16)
        let encryptedChallenge = try CryptoManager.aesEncryptECB(randomChallenge, key: Data(aesKey))

        let step2Response = try await client.pairRequest(args: [
            ("clientchallenge", encryptedChallenge.hexString),
        ])

        try step2Response.verifyStatus()

        guard step2Response.elements["paired"] == "1" else {
            try? await client.unpair()
            return .failed("Server rejected client challenge")
        }

        guard let challengeResponseHex = step2Response.elements["challengeresponse"],
              let challengeResponseEncrypted = Data(hexString: challengeResponseHex) else {
            try? await client.unpair()
            return .failed("Missing challenge response")
        }

        // Step 3: Process server challenge and send response
        let challengeResponseData = try CryptoManager.aesDecryptECB(challengeResponseEncrypted, key: Data(aesKey))

        // Extract server response hash and server challenge from decrypted data
        guard challengeResponseData.count >= hashLength + 16 else {
            try? await client.unpair()
            return .failed("Challenge response too short")
        }

        let serverResponse = challengeResponseData.prefix(hashLength)
        let serverChallenge = challengeResponseData[hashLength..<(hashLength + 16)]

        // Generate client secret
        let clientSecret = CryptoManager.randomBytes(16)

        // Get client certificate signature
        let clientCertDER = try await cryptoManager.getClientCertDER()
        guard let clientCertSignature = CryptoManager.extractSignatureFromCert(clientCertDER) else {
            try? await client.unpair()
            return .failed("Failed to extract client cert signature")
        }

        // Build challenge response: serverChallenge + clientCertSignature + clientSecret
        var challengeRespPayload = Data()
        challengeRespPayload.append(serverChallenge)
        challengeRespPayload.append(clientCertSignature)
        challengeRespPayload.append(clientSecret)

        // Hash and pad to 32 bytes
        var paddedHash: Data
        if useSHA256 {
            paddedHash = CryptoManager.sha256(challengeRespPayload)
        } else {
            paddedHash = CryptoManager.sha1(challengeRespPayload)
            // Zero-pad SHA-1 (20 bytes) to 32 bytes for AES block alignment
            paddedHash.append(Data(count: 12))
        }

        let encryptedHash = try CryptoManager.aesEncryptECB(paddedHash, key: Data(aesKey))

        let step3Response = try await client.pairRequest(args: [
            ("serverchallengeresp", encryptedHash.hexString),
        ])

        try step3Response.verifyStatus()

        guard step3Response.elements["paired"] == "1" else {
            try? await client.unpair()
            return .failed("Server rejected challenge response")
        }

        guard let pairingSecretHex = step3Response.elements["pairingsecret"],
              let pairingSecret = Data(hexString: pairingSecretHex) else {
            try? await client.unpair()
            return .failed("Missing pairing secret")
        }

        // Step 4: Verify server's pairing secret
        guard pairingSecret.count > 16 else {
            try? await client.unpair()
            return .failed("Pairing secret too short")
        }

        let serverSecret = pairingSecret.prefix(16)
        let serverSignature = pairingSecret.dropFirst(16)

        // Verify server signature over serverSecret using server cert's public key
        guard let serverCert = SecCertificateCreateWithData(nil, serverCertDER as CFData) else {
            try? await client.unpair()
            return .failed("Invalid server certificate")
        }

        guard let serverPublicKey = SecCertificateCopyKey(serverCert) else {
            try? await client.unpair()
            return .failed("Failed to extract server public key")
        }

        guard CryptoManager.verifySignature(serverSecret, signature: Data(serverSignature), publicKey: serverPublicKey) else {
            try? await client.unpair()
            return .failed("Server signature verification failed — possible MITM attack")
        }

        // Verify PIN by checking server's response hash
        guard let serverCertSignature = CryptoManager.extractSignatureFromCert(serverCertDER) else {
            try? await client.unpair()
            return .failed("Failed to extract server cert signature")
        }

        var expectedPayload = Data()
        expectedPayload.append(randomChallenge)
        expectedPayload.append(serverCertSignature)
        expectedPayload.append(serverSecret)

        let expectedHash: Data
        if useSHA256 {
            expectedHash = CryptoManager.sha256(expectedPayload)
        } else {
            expectedHash = CryptoManager.sha1(expectedPayload)
        }

        guard expectedHash.prefix(hashLength) == serverResponse.prefix(hashLength) else {
            try? await client.unpair()
            return .pinRejected
        }

        // Step 5: Send client pairing secret
        let clientSignature = try await cryptoManager.signWithClientKey(clientSecret)

        var clientPairingSecret = Data()
        clientPairingSecret.append(clientSecret)
        clientPairingSecret.append(clientSignature)

        let step5Response = try await client.pairRequest(args: [
            ("clientpairingsecret", clientPairingSecret.hexString),
        ])

        try step5Response.verifyStatus()

        guard step5Response.elements["paired"] == "1" else {
            try? await client.unpair()
            return .failed("Server rejected client pairing secret")
        }

        // Step 6: Final pair challenge over HTTPS
        let step6Response = try await client.pairRequest(args: [
            ("phrase", "pairchallenge"),
        ], useHTTPS: true)

        // Note: Step 6 may not verify status cleanly on all servers,
        // but if we get here without error the pairing is successful.
        if let paired = step6Response.elements["paired"], paired != "1" {
            try? await client.unpair()
            return .failed("Final pair verification failed")
        }

        return .success(serverCertDER: serverCertDER)
    }
}
#endif
