@preconcurrency import CoreNFC
import Combine
import CryptoKit
import DebugTrace
import Foundation
import NIOCore
import NIOSSH
import SwiftUI
import UIKit

struct SSHKeyManagementView: View {
    @StateObject private var enrollment = YubiKeySSHEnrollment()
    @State private var keys = YubiKeySSHCredentialStore.all()
    @State private var label = "YubiKey"
    @State private var pin = ""
    @State private var keyToDelete: YubiKeySSHCredential?
    @State private var copiedFingerprint: String?

    var body: some View {
        Form {
            Section("Registered YubiKeys") {
                if keys.isEmpty {
                    Text("No YubiKeys registered on this iPhone.")
                        .foregroundStyle(.secondary)
                }
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.label).font(.headline)
                        Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        Text(key.authorizedKeysLine)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        HStack {
                            Button(copiedFingerprint == key.fingerprint ? "Copied" : "Copy public key") {
                                UIPasteboard.general.string = key.authorizedKeysLine
                                copiedFingerprint = key.fingerprint
                            }
                            Button("Remove", role: .destructive) { keyToDelete = key }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Register a YubiKey") {
                TextField("Name", text: $label)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .disabled(enrollment.running)
                SecureField("OpenPGP user PIN", text: $pin)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(enrollment.running)
                Button {
                    let enteredPIN = pin
                    let enteredLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    pin = ""
                    enrollment.register(label: enteredLabel, pin: enteredPIN)
                } label: {
                    Label("Scan and register", systemImage: "wave.3.right")
                }
                .disabled(enrollment.running || pin.isEmpty || !NFCTagReaderSession.readingAvailable)

                if enrollment.running { ProgressView("Hold the top of the iPhone near the YubiKey") }
                Text(enrollment.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The PIN is verified once, then stored in this iPhone’s Keychain with device-only protection. Longwave never syncs or logs it. Keep the YubiKey with you; it must be scanned for each new SSH authentication.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SSH Security Keys")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove this YubiKey?", item: $keyToDelete, titleVisibility: .visible) { key in
            Button("Remove Key and PIN", role: .destructive) {
                YubiKeySSHCredentialStore.delete(fingerprint: key.fingerprint)
                refreshKeys()
            }
            Button("Cancel", role: .cancel) {}
        } message: { key in
            Text("Connections using \(key.label) will need another authentication key selected.")
        }
        .onAppear(perform: refreshKeys)
        .onChange(of: enrollment.running) { _, running in
            if !running { refreshKeys() }
        }
        .onDisappear { pin = ""; enrollment.cancel() }
    }

    private func refreshKeys() {
        keys = YubiKeySSHCredentialStore.all()
    }
}

/// Fresh NFC interaction for every SSH handshake. It reads the selected card's
/// authentication key, verifies that it matches the enrolled public key, then
/// validates the remembered user PIN once before offering the async signer.
@MainActor
final class YubiKeySSHAuthenticationProvider: NSObject, SSHAuthenticationProvider, NFCTagReaderSessionDelegate {
    private let keyFingerprint: String
    private let expectedHostFingerprint: String
    private var reader: NFCTagReaderSession?
    private var continuation: CheckedContinuation<SSHPreparedAuthentication, Error>?
    private var operation: Task<Void, Never>?
    private var credential: YubiKeySSHCredential?

    init(keyFingerprint: String, expectedHostFingerprint: String) {
        self.keyFingerprint = keyFingerprint
        self.expectedHostFingerprint = expectedHostFingerprint
    }

    func prepareAuthentication() async throws -> SSHPreparedAuthentication {
        guard OpenPGPHostFingerprintDelegate.isValid(expectedHostFingerprint) else {
            throw YubiKeySSHAuthenticationError.message("Set a trusted SHA256 host fingerprint in this SSH connection’s settings.")
        }
        guard let credential = YubiKeySSHCredentialStore.credential(fingerprint: keyFingerprint) else {
            throw YubiKeySSHAuthenticationError.message("This YubiKey is no longer registered. Register it again or choose another SSH key.")
        }
        guard NFCTagReaderSession.readingAvailable,
              let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
            throw YubiKeySSHAuthenticationError.message("NFC tag reading is unavailable on this device.")
        }
        self.credential = credential
        session.alertMessage = "Hold the selected YubiKey near the top of the iPhone."
        reader = session
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.begin()
        }
    }

    func finishAuthentication() {
        operation?.cancel()
        operation = nil
        reader?.invalidate()
        reader = nil
        credential = nil
    }

    func cancelAuthentication() {
        operation?.cancel()
        operation = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        reader?.invalidate()
        reader = nil
        credential = nil
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else { session.restartPolling(); return }
        guard case .iso7816(let rawCard) = tag else {
            session.invalidate(errorMessage: "This SSH credential requires an ISO 7816 OpenPGP card.")
            return
        }
        let card = SendableNFCCard(value: rawCard)
        let owner = self
        let sessionID = ObjectIdentifier(session)
        session.connect(to: tag) { error in
            Task { @MainActor in
                guard owner.reader.map(ObjectIdentifier.init) == sessionID,
                      owner.continuation != nil, owner.operation == nil else { return }
                if error != nil {
                    owner.fail("Could not connect to the YubiKey over NFC. Try holding it steadily near the top of the phone.")
                    return
                }
                owner.operation = Task { await owner.prepareOffer(card: card) }
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let owner = self
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard owner.reader.map(ObjectIdentifier.init) == sessionID else { return }
            owner.reader = nil
            owner.operation?.cancel()
            owner.operation = nil
            if let continuation = owner.continuation {
                owner.continuation = nil
                owner.credential = nil
                continuation.resume(throwing: YubiKeySSHAuthenticationError.message("The NFC session ended before SSH authentication. Retry the connection and scan the key again."))
            }
        }
    }

    private func prepareOffer(card: SendableNFCCard) async {
        do {
            guard let credential else { throw YubiKeySSHAuthenticationError.message("The selected YubiKey credential is unavailable.") }
            let publicBytes = try await OpenPGPCardOperations.readAuthenticationKey(card)
            let actualFingerprint = try OpenPGPCardOperations.sshFingerprint(publicKey: publicBytes)
            guard actualFingerprint == keyFingerprint,
                  publicBytes == credential.publicKey else {
                throw YubiKeySSHAuthenticationError.message("A different YubiKey was scanned. No PIN was sent.")
            }
            try await OpenPGPCardOperations.verifyUserPIN(card, pin: credential.pin)

            let publicKeyLine = OpenPGPAuthenticationCodec.sshKey(publicBytes)
            let sshPublicKey = try NIOSSHPublicKey(openSSHPublicKey: publicKeyLine)
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
            let signer = OpenPGPNFCSSHSigner(card: card, publicKey: signingKey)
            let offer = NIOSSHUserAuthenticationOffer.Offer.customPublicKey(publicKey: sshPublicKey) { payload, eventLoop in
                let promise = eventLoop.makePromise(of: Data.self)
                Task { @MainActor in signer.sign(payload) { promise.completeWith($0) } }
                return promise.futureResult
            }
            let prepared = SSHPreparedAuthentication(
                offer: offer,
                serverAuthDelegate: OpenPGPHostFingerprintDelegate(expected: expectedHostFingerprint)
            )
            guard let continuation else { return }
            self.continuation = nil
            operation = nil
            reader?.alertMessage = "Verifying the SSH host and signing in. Keep the YubiKey in place."
            continuation.resume(returning: prepared)
        } catch {
            let message = (error as? YubiKeySSHAuthenticationError)?.localizedDescription
                ?? "YubiKey authentication failed. No automatic PIN retry was made."
            fail(message)
        }
    }

    private func fail(_ message: String) {
        operation?.cancel()
        operation = nil
        credential = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: YubiKeySSHAuthenticationError.message(message))
        }
        reader?.invalidate(errorMessage: message)
        reader = nil
    }
}

@MainActor
private final class YubiKeySSHEnrollment: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    @Published private(set) var running = false
    @Published private(set) var status = "Register a key to use it for SSH connections."

    private var reader: NFCTagReaderSession?
    private var operation: Task<Void, Never>?
    private var pendingPIN: String?
    private var pendingLabel = ""
    private var completion: ((Result<YubiKeySSHCredential, Error>) -> Void)?

    func register(label: String, pin: String) {
        guard !running else { return }
        guard (6...127).contains(Data(pin.utf8).count) else {
            status = "The OpenPGP user PIN must be 6–127 UTF-8 bytes."
            return
        }
        guard NFCTagReaderSession.readingAvailable,
              let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
            status = "NFC tag reading is unavailable on this device."
            return
        }
        pendingPIN = pin
        pendingLabel = String((label.isEmpty ? "YubiKey" : label).prefix(40))
        running = true
        status = "Hold the YubiKey near the top of the iPhone."
        session.alertMessage = "Hold the YubiKey near the top of the iPhone."
        reader = session
        session.begin()
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        pendingPIN = nil
        completion = nil
        running = false
        reader?.invalidate()
        reader = nil
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard tags.count == 1, let tag = tags.first else { session.restartPolling(); return }
        guard case .iso7816(let rawCard) = tag else { session.invalidate(errorMessage: "ISO 7816 OpenPGP card required."); return }
        let card = SendableNFCCard(value: rawCard)
        let owner = self
        let sessionID = ObjectIdentifier(session)
        session.connect(to: tag) { error in
            Task { @MainActor in
                guard owner.reader.map(ObjectIdentifier.init) == sessionID, owner.running else { return }
                if error != nil { owner.finish(.failure(YubiKeySSHAuthenticationError.message("NFC connection failed. Hold the key steadily and try again."))); return }
                owner.operation = Task { await owner.readAndRegister(card: card) }
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let owner = self
        let sessionID = ObjectIdentifier(session)
        Task { @MainActor in
            guard owner.reader.map(ObjectIdentifier.init) == sessionID else { return }
            owner.reader = nil
            owner.operation?.cancel()
            owner.operation = nil
            owner.pendingPIN = nil
            owner.running = false
        }
    }

    private func readAndRegister(card: SendableNFCCard) async {
        do {
            guard let pin = pendingPIN else { throw CancellationError() }
            let publicBytes = try await OpenPGPCardOperations.readAuthenticationKey(card)
            try await OpenPGPCardOperations.verifyUserPIN(card, pin: pin)
            let fingerprint = try OpenPGPCardOperations.sshFingerprint(publicKey: publicBytes)
            let credential = YubiKeySSHCredential(fingerprint: fingerprint, label: pendingLabel,
                                                  publicKey: publicBytes, pin: pin)
            guard YubiKeySSHCredentialStore.save(credential) else {
                throw YubiKeySSHAuthenticationError.message("Could not save this key to the iPhone Keychain.")
            }
            pendingPIN = nil
            finish(.success(credential))
        } catch {
            pendingPIN = nil
            let message = (error as? YubiKeySSHAuthenticationError)?.localizedDescription
                ?? "YubiKey registration failed. No automatic PIN retry was made."
            finish(.failure(YubiKeySSHAuthenticationError.message(message)))
        }
    }

    private func finish(_ result: Result<YubiKeySSHCredential, Error>) {
        switch result {
        case .success(let credential):
            status = "Registered \(credential.label) (\(credential.fingerprint)). The PIN is stored in this iPhone’s Keychain."
            AppLog.app.log("YubiKey SSH credential registered")
        case .failure(let error):
            status = error.localizedDescription
        }
        running = false
        operation = nil
        reader?.alertMessage = status
        reader?.invalidate()
        reader = nil
    }
}

private enum OpenPGPCardOperations {
    static func readAuthenticationKey(_ card: SendableNFCCard) async throws -> Data {
        _ = try await command(card, ins: 0xA4, p1: 0x04,
                             data: Data([0xD2, 0x76, 0, 1, 0x24, 1]))
        let metadata = try await command(card, ins: 0xCA, p2: 0x6E)
        guard let attributes = try OpenPGPMetadata.field(0xC3, in: metadata),
              attributes.starts(with: [0x16, 0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]) else {
            throw YubiKeySSHAuthenticationError.message("This feature currently supports an Ed25519 authentication key only.")
        }
        let response = try await command(card, ins: 0x47, p1: 0x81, data: Data([0xA4, 0]))
        return try OpenPGPAuthenticationCodec.publicKey(response)
    }

    static func verifyUserPIN(_ card: SendableNFCCard, pin: String) async throws {
        let metadata = try await command(card, ins: 0xCA, p2: 0x6E)
        guard let capabilities = try OpenPGPMetadata.field(0xC0, in: metadata), let flags = capabilities.first,
              let pinStatus = try OpenPGPMetadata.field(0xC4, in: metadata), pinStatus.count == 7 else {
            throw YubiKeySSHAuthenticationError.message("The card’s PIN configuration could not be read. No PIN was sent.")
        }
        guard pinStatus[pinStatus.startIndex + 4] > 0 else {
            throw YubiKeySSHAuthenticationError.message("The user PIN is blocked. No PIN was sent.")
        }
        let kdf = flags & 1 != 0 ? try await command(card, ins: 0xCA, p2: 0xF9) : Data()
        var processedPIN = try OpenPGPAuthenticationCodec.processPIN(Data(pin.utf8), configuration: kdf)
        defer { processedPIN.resetBytes(in: 0..<processedPIN.count) }
        let maximumPINBytes = Int(pinStatus[pinStatus.startIndex + 1] & 0x7F)
        guard pinStatus[pinStatus.startIndex + 1] & 0x80 == 0,
              processedPIN.count <= maximumPINBytes else {
            throw YubiKeySSHAuthenticationError.message("The saved PIN format does not match this card. No PIN was sent.")
        }
        let reply = try await send(card, ins: 0x20, p2: 0x82, data: processedPIN, le: -1)
        guard reply.word == 0x9000 else {
            throw YubiKeySSHAuthenticationError.message("The YubiKey rejected its user PIN (\(String(format: "%04X", reply.word))). No automatic PIN retry was made.")
        }
    }

    static func sshFingerprint(publicKey: Data) throws -> String {
        let fields = OpenPGPAuthenticationCodec.sshKey(publicKey).split(separator: " ")
        guard fields.count == 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw YubiKeySSHAuthenticationError.message("Could not encode the YubiKey’s public authentication key.")
        }
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private static func command(_ card: SendableNFCCard, ins: UInt8, p1: UInt8 = 0, p2: UInt8 = 0,
                                data: Data = Data()) async throws -> Data {
        let reply = try await send(card, ins: ins, p1: p1, p2: p2, data: data)
        guard reply.word == 0x9000 else {
            throw YubiKeySSHAuthenticationError.message("OpenPGP card command failed (\(String(format: "%04X", reply.word))).")
        }
        return reply.data
    }

    private static func send(_ card: SendableNFCCard, ins: UInt8, p1: UInt8 = 0, p2: UInt8 = 0,
                             data: Data = Data(), le: Int = 256) async throws -> CardReply {
        let apdu = NFCISO7816APDU(instructionClass: 0, instructionCode: ins, p1Parameter: p1,
                                  p2Parameter: p2, data: data, expectedResponseLength: le)
        return try await withCheckedThrowingContinuation { continuation in
            OpenPGPCardChannel.exchange(card: card, apdu: apdu) { response, sw1, sw2, error in
                if error != nil { continuation.resume(throwing: YubiKeySSHAuthenticationError.message("NFC transport failed.")) }
                else { continuation.resume(returning: CardReply(data: response, word: Int(sw1) * 256 + Int(sw2))) }
            }
        }
    }

    private struct CardReply {
        let data: Data
        let word: Int
    }
}

private enum YubiKeySSHAuthenticationError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return "YubiKey SSH authentication failed."
    }
}

extension YubiKeySSHCredential {
    var authorizedKeysLine: String {
        let comment = label.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            let safe = (48...57).contains(value) || (65...90).contains(value)
                || (97...122).contains(value) || [45, 46, 95].contains(value)
            return safe ? String(scalar) : "-"
        }.joined()
        return OpenPGPAuthenticationCodec.sshKey(publicKey) + " Longwave-\(comment.isEmpty ? "YubiKey" : comment)"
    }
}
