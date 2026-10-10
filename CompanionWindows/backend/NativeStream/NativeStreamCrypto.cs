using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace Longwave.WindowsCompanion.Backend.NativeStream;

/// <summary>
/// The Windows counterpart of <c>Shared/MacNativeStreamCrypto.swift</c>: the
/// viewer connects with TLS 1.2 external PSK, ciphersuite
/// TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8), PSK identity
/// "LongwaveMacNative/v1/&lt;device id&gt;" (bare for the old shared token),
/// PSK = HKDF-SHA256(that device's token,
/// salt "Longwave-MacNative-PSK-v1", info "psk", 32 bytes). SChannel exposes
/// no PSK ciphersuites at all, so the handshake runs on BouncyCastle.
/// </summary>
public static class NativeStreamCrypto
{
    private const string PskIdentityBase = "LongwaveMacNative/v1";
    private const string IdentifyLabel = "EXPORTER-Longwave-Native-Device-v1";
    private static readonly byte[] HkdfSalt = Encoding.UTF8.GetBytes("Longwave-MacNative-PSK-v1");
    private static readonly byte[] HkdfInfo = Encoding.UTF8.GetBytes("psk");
    private static readonly byte[] ProofSalt = Encoding.UTF8.GetBytes("Longwave-Device-Proof-v1");

    public static byte[] DerivePsk(string token) =>
        HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            ikm: Encoding.UTF8.GetBytes(token),
            outputLength: 32,
            salt: HkdfSalt,
            info: HkdfInfo);

    /// <summary>
    /// The PSK identity names the credential (COMPANION_ENROLLMENT_PLAN.md):
    /// <c>LongwaveMacNative/v1/&lt;device id&gt;</c> for a paired device, the
    /// bare base for the token this PC used to show. Returns the device id
    /// (null: that old token), or false for an identity that names nothing.
    /// </summary>
    public static bool ParseIdentity(byte[] identity, out string? deviceId)
    {
        var text = Encoding.UTF8.GetString(identity);
        deviceId = null;
        if (text == PskIdentityBase) return true;
        if (!text.StartsWith(PskIdentityBase + "/", StringComparison.Ordinal)) return false;
        deviceId = text[(PskIdentityBase.Length + 1)..];
        return deviceId.Length is > 0 and <= 64;
    }

    /// <summary>The accepted handshake: the framed-protocol carrier, which
    /// credential it used, and the session's exporter value for the identify
    /// proof.</summary>
    public sealed record Session(TlsServerProtocol Protocol, string? DeviceId, byte[] Binding);

    /// <summary>
    /// Runs the server-side TLS-PSK handshake over an accepted TCP stream,
    /// choosing each connection's PSK by the identity it presents. Throws on
    /// handshake failure (an unknown or revoked device, a non-TLS client).
    /// </summary>
    public static Session Accept(Stream tcpStream, Func<string?, string?> tokenFor)
    {
        var protocol = new TlsServerProtocol(tcpStream);
        var identities = new IdentityManager(tokenFor);
        var server = new PskServer(identities);
        protocol.Accept(server);
        return new Session(protocol, identities.Matched,
            server.Binding ?? throw new InvalidOperationException("TLS exporter unavailable"));
    }

    /// <summary>
    /// Checks a hello's <c>identity</c> (<c>CompanionIdentify</c>): it must
    /// name the credential the handshake used and prove its token over this
    /// session's exporter value, so a device can neither claim another's grants
    /// nor replay a proof.
    /// </summary>
    public static bool Verifies(string? claimedDeviceId, byte[] proof, Session session, string token)
    {
        if (claimedDeviceId != session.DeviceId) return false;
        return CryptographicOperations.FixedTimeEquals(Proof(token, session.Binding), proof);
    }

    /// <summary>HMAC-SHA256 under HKDF(token, "Longwave-Device-Proof-v1"), as
    /// <c>CompanionIdentify.proof</c> computes it.</summary>
    public static byte[] Proof(string token, byte[] binding)
    {
        var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(token), 32, ProofSalt, Array.Empty<byte>());
        return HMACSHA256.HashData(key, binding);
    }

    private sealed class PskServer : PskTlsServer
    {
        public PskServer(TlsPskIdentityManager identities)
            : base(new BcTlsCrypto(new Org.BouncyCastle.Security.SecureRandom()), identities)
        {
        }

        /// <summary>The session's exporter value. BouncyCastle only exports
        /// key material from inside <c>NotifyHandshakeComplete</c>.</summary>
        public byte[]? Binding { get; private set; }

        public override void NotifyHandshakeComplete()
        {
            base.NotifyHandshakeComplete();
            // An *empty* context, not none: that is what Apple's
            // sec_protocol_metadata_create_secret exports (RFC 5705 tells
            // the two apart; measured against a headset-side proof, 2026-10-10).
            Binding = m_context.ExportKeyingMaterial(IdentifyLabel, Array.Empty<byte>(), 32);
        }

        protected override ProtocolVersion[] GetSupportedVersions() =>
            ProtocolVersion.TLSv12.Only();

        protected override int[] GetSupportedCipherSuites() =>
            new[] { CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256 };

        // BouncyCastle's AbstractTlsServer happily echoes the client's
        // status_request (OCSP stapling) extension even in a PSK handshake.
        // That extension is only legal when a Certificate message follows —
        // PSK has none — and Apple's TLS stack (unlike OpenSSL) rejects the
        // ServerHello with decode_error. Certificate status has no meaning
        // here; refuse it so the extension is never echoed.
        protected override bool AllowCertificateStatus() => false;

        protected override bool AllowMultiCertStatus() => false;
    }

    private sealed class IdentityManager : TlsPskIdentityManager
    {
        private readonly Func<string?, string?> _tokenFor;

        public IdentityManager(Func<string?, string?> tokenFor) => _tokenFor = tokenFor;

        /// <summary>The device whose PSK the handshake used (null: the old token).</summary>
        public string? Matched { get; private set; }

        public byte[]? GetHint() => null;

        public byte[]? GetPsk(byte[] identity)
        {
            // The identity is a public label; the PSK never leaves this process.
            if (!ParseIdentity(identity, out var deviceId)) return null;
            if (_tokenFor(deviceId) is not { } token) return null;
            Matched = deviceId;
            return DerivePsk(token);
        }
    }
}
