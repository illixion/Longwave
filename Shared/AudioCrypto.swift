import Foundation
import Network
import CryptoKit

/// Transport encryption for the audio stream. The pairing token (256 bits,
/// delivered out-of-band via AirDrop or clipboard — see `AudioTokenURL`) is
/// already a high-entropy shared secret, so we use it as a **(D)TLS 1.2
/// external pre-shared key** rather than layering a separate key exchange on
/// top. (TLS 1.3 external PSK is not honored by Network.framework's boringssl
/// — see `pskCiphersuite` below.)
///
/// Both transports authenticate and encrypt from the token:
///   - TCP control/metadata channel → TLS 1.2-PSK (`NWProtocolTLS` over TCP)
///   - UDP low-latency PCM channel   → DTLS 1.2-PSK (`NWProtocolTLS` over UDP)
///
/// Mutual authentication falls out of the PSK: only a peer holding the token
/// can complete the handshake, so a rogue LAN client can neither connect nor
/// inject (D)TLS records. Confidentiality, integrity, and — on the UDP path —
/// DTLS's built-in replay window come from the (D)TLS stack, so there is no
/// hand-rolled framing, nonce bookkeeping, or identity keypair to manage. This
/// replaces the previous plaintext-token-over-TCP scheme (which relied on an
/// external Tailscale/WireGuard tunnel for confidentiality).
///
/// The token is never sent on the wire under this scheme — it only ever feeds
/// the PSK derivation below; the legacy `auth`/`authFailed` frames are gone.
nonisolated enum AudioCrypto {
    /// PSK identity exchanged in the clear during the handshake. Versioned so a
    /// future key-schedule change can't silently interop with an old peer.
    private static let pskIdentity = Data("LongwaveAudio/v5".utf8)
    private static let hkdfSalt = Data("Longwave-Audio-PSK-v5".utf8)
    private static let hkdfInfo = Data("psk".utf8)

    /// Derives a stable 32-byte PSK from the pairing token via HKDF-SHA256.
    /// Both ends derive the same key from the same token; the raw token bytes
    /// are stretched/whitened rather than used directly.
    private static func derivePSK(token: String) -> DispatchData {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: 32
        )
        let raw = derived.withUnsafeBytes { Data($0) }
        return dispatchData(raw)
    }

    private static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }

    /// `TLS_PSK_WITH_AES_128_GCM_SHA256`. Network.framework exposes no PSK
    /// ciphersuites in the typed `tls_ciphersuite_t` enum, but boringssl
    /// honors this one by raw value. It is the only reliably-working
    /// external-PSK path here: TLS **1.3** PSK via `add_pre_shared_key` is
    /// silently discarded by boringssl ("Clearing PSK identity/data" →
    /// handshake failure), so both channels pin (D)TLS **1.2** + this suite.
    private static let pskCiphersuite = tls_ciphersuite_t(rawValue: 0x00A8)!

    /// Applies the PSK + (D)TLS 1.2 PSK-ciphersuite constraints to a
    /// security-protocol options block. `dtls` selects DTLS 1.2 vs TLS 1.2 —
    /// the only DTLS version Network.framework supports.
    private static func configure(_ options: sec_protocol_options_t, token: String, dtls: Bool) {
        sec_protocol_options_add_pre_shared_key(
            options,
            derivePSK(token: token) as __DispatchData,
            dispatchData(pskIdentity) as __DispatchData
        )
        let version: tls_protocol_version_t = dtls ? .DTLSv12 : .TLSv12
        sec_protocol_options_set_min_tls_protocol_version(options, version)
        sec_protocol_options_set_max_tls_protocol_version(options, version)
        sec_protocol_options_append_tls_ciphersuite(options, pskCiphersuite)
    }

    /// TLS 1.2-PSK parameters for the TCP control/metadata channel.
    /// `noDelay` is preserved from the previous plaintext TCP options.
    static func tlsTCPParameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        configure(tls.securityProtocolOptions, token: token, dtls: false)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// DTLS 1.2-PSK parameters for the low-latency UDP PCM channel.
    static func dtlsUDPParameters(token: String) -> NWParameters {
        let dtls = NWProtocolTLS.Options()
        configure(dtls.securityProtocolOptions, token: token, dtls: true)
        return NWParameters(dtls: dtls, udp: NWProtocolUDP.Options())
    }
}
