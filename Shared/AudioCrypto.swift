import Foundation
import Network
import RAVECompanion

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
    /// PSK identity `LongwaveAudio/v5/<device id>` (bare for the shared
    /// token), HKDF salt versioned so a future key-schedule change can't
    /// silently interop with an old peer. (D)TLS 1.2 +
    /// `TLS_PSK_WITH_AES_128_GCM_SHA256`, since TLS 1.3 external PSK is
    /// discarded by Network.framework's boringssl (`RAVECompanionChannel`).
    static let channel = RAVECompanionChannel(identityBase: "LongwaveAudio/v5", salt: "Longwave-Audio-PSK-v5")

    /// TLS 1.2-PSK parameters for the TCP control/metadata channel.
    static func tlsTCPParameters(credentials: [CompanionCredential]) -> NWParameters {
        channel.tcpParameters(credentials: credentials)
    }

    /// DTLS 1.2-PSK parameters for the low-latency UDP PCM channel. Voice
    /// access category (WMM AC_VO) rather than best effort: the flow is small,
    /// steady and latency-bound, which is exactly what the class is for, and
    /// on a contended Wi-Fi link it queues ahead of bulk traffic.
    static func dtlsUDPParameters(credentials: [CompanionCredential]) -> NWParameters {
        channel.udpParameters(credentials: credentials, serviceClass: .interactiveVoice)
    }
}
