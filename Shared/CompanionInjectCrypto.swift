import Foundation
import Network
import RAVECompanion

/// Transport encryption for the keyboard-injection channel. Identical scheme to
/// `AudioCrypto` (TLS 1.2 external PSK derived from the companion token via
/// HKDF-SHA256, `TLS_PSK_WITH_AES_128_GCM_SHA256`), but **domain-separated**:
/// the HKDF salt and PSK identity differ, so the audio PSK and the inject PSK
/// are independent keys derived from the same token. A leak or break of one
/// channel's key therefore can't be replayed against the other.
nonisolated enum CompanionInjectCrypto {
    static let channel = RAVECompanionChannel(identityBase: "LongwaveInject/v1", salt: "Longwave-Inject-PSK-v1")

    /// TLS 1.2-PSK parameters for the TCP injection channel.
    static func tlsTCPParameters(credentials: [CompanionCredential]) -> NWParameters {
        channel.tcpParameters(credentials: credentials)
    }
}
