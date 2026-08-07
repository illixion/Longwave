import Foundation
import Network
import CryptoKit

/// Domain-separated TLS-PSK parameters for the native Mac stream milestone.
/// Keeping this behind one type allows the planned TLS 1.3 pinned-identity
/// transport to replace it without changing the wire protocol.
nonisolated enum MacNativeStreamCrypto {
    private static let pskIdentity = Data("VisionVNCMacNative/v1".utf8)
    private static let hkdfSalt = Data("VisionVNC-MacNative-PSK-v1".utf8)
    private static let hkdfInfo = Data("psk".utf8)
    private static let pskCiphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

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
        tcp.connectionTimeout = 10
        return NWParameters(tls: tls, tcp: tcp)
    }
}
