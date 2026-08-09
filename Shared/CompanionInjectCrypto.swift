import Foundation
import Network
import CryptoKit

/// Transport encryption for the keyboard-injection channel. Identical scheme to
/// `AudioCrypto` (TLS 1.2 external PSK derived from the companion token via
/// HKDF-SHA256, `TLS_PSK_WITH_AES_128_GCM_SHA256`), but **domain-separated**:
/// the HKDF salt and PSK identity differ, so the audio PSK and the inject PSK
/// are independent keys derived from the same token. A leak or break of one
/// channel's key therefore can't be replayed against the other. Kept separate
/// from `AudioCrypto` so the audio path's crypto is never touched by changes
/// here.
nonisolated enum CompanionInjectCrypto {
    private static let pskIdentity = Data("LongwaveInject/v1".utf8)
    private static let hkdfSalt = Data("Longwave-Inject-PSK-v1".utf8)
    private static let hkdfInfo = Data("psk".utf8)

    private static func derivePSK(token: String) -> DispatchData {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: 32
        )
        let raw = derived.withUnsafeBytes { Data($0) }
        return raw.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    private static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    /// `TLS_PSK_WITH_AES_128_GCM_SHA256` — the only reliably-working external
    /// PSK path in Network.framework's boringssl (TLS 1.3 PSK is discarded).
    private static let pskCiphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    /// TLS 1.2-PSK parameters for the TCP injection channel.
    static func tlsTCPParameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            options,
            derivePSK(token: token) as __DispatchData,
            dispatchData(pskIdentity) as __DispatchData
        )
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, pskCiphersuite)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}
