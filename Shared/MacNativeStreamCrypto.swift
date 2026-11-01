import Foundation
import Network
import RAVECompanion

/// Domain-separated TLS-PSK parameters for the native Mac stream milestone.
/// Keeping this behind one type allows the planned TLS 1.3 pinned-identity
/// transport to replace it without changing the wire protocol.
nonisolated enum MacNativeStreamCrypto {
    static let channel = RAVECompanionChannel(identityBase: "LongwaveMacNative/v1", salt: "Longwave-MacNative-PSK-v1")

    /// One PSK per credential (a server: every enrolled device's). Interactive
    /// video on the Wi-Fi link (WMM video access category), ahead of
    /// best-effort traffic — the same reason audio rides the voice class.
    static func tlsTCPParameters(credentials: [CompanionCredential]) -> NWParameters {
        channel.tcpParameters(credentials: credentials, connectionTimeout: 10, serviceClass: .interactiveVideo)
    }
}
