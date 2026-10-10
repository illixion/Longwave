import Foundation
import Network
import CryptoKit

/// Domain-separated TLS-PSK parameters for the native Mac stream milestone.
/// Keeping this behind one type allows the planned TLS 1.3 pinned-identity
/// transport to replace it without changing the wire protocol.
nonisolated enum MacNativeStreamCrypto {
    private static let pskIdentityBase = "LongwaveMacNative/v1"
    private static let hkdfSalt = Data("Longwave-MacNative-PSK-v1".utf8)
    private static let hkdfInfo = Data("psk".utf8)
    private static let pskCiphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    static func tlsTCPParameters(credentials: [CompanionCredential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        // One PSK per credential (a server: every enrolled device's).
        CompanionPSK.add(credentials, to: options, identityBase: pskIdentityBase, salt: hkdfSalt, info: hkdfInfo)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, pskCiphersuite)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // Interactive video on the Wi-Fi link (WMM video access category),
        // ahead of best-effort traffic — the same reason audio rides the
        // voice class.
        parameters.serviceClass = .interactiveVideo
        return parameters
    }
}
