using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Tls;
using Org.BouncyCastle.Tls.Crypto;
using Org.BouncyCastle.Tls.Crypto.Impl.BC;

namespace VisionVNC.Hotspot.Backend.NativeStream;

/// <summary>
/// The Windows counterpart of <c>Shared/MacNativeStreamCrypto.swift</c>: the
/// viewer connects with TLS 1.2 external PSK, ciphersuite
/// TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8), PSK identity
/// "VisionVNCMacNative/v1", PSK = HKDF-SHA256(token,
/// salt "VisionVNC-MacNative-PSK-v1", info "psk", 32 bytes). SChannel exposes
/// no PSK ciphersuites at all, so the handshake runs on BouncyCastle.
/// </summary>
public static class NativeStreamCrypto
{
    private const string PskIdentity = "VisionVNCMacNative/v1";
    private static readonly byte[] HkdfSalt = Encoding.UTF8.GetBytes("VisionVNC-MacNative-PSK-v1");
    private static readonly byte[] HkdfInfo = Encoding.UTF8.GetBytes("psk");

    public static byte[] DerivePsk(string token) =>
        HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            ikm: Encoding.UTF8.GetBytes(token),
            outputLength: 32,
            salt: HkdfSalt,
            info: HkdfInfo);

    /// <summary>
    /// Runs the server-side TLS-PSK handshake over an accepted TCP stream and
    /// returns the protocol wrapper whose <c>Stream</c> carries the framed
    /// protocol. Throws on handshake failure (wrong token, non-TLS client).
    /// </summary>
    public static TlsServerProtocol Accept(Stream tcpStream, byte[] psk)
    {
        var protocol = new TlsServerProtocol(tcpStream);
        protocol.Accept(new PskServer(psk));
        return protocol;
    }

    private sealed class PskServer : PskTlsServer
    {
        public PskServer(byte[] psk)
            : base(new BcTlsCrypto(new Org.BouncyCastle.Security.SecureRandom()), new IdentityManager(psk))
        {
        }

        protected override ProtocolVersion[] GetSupportedVersions() =>
            ProtocolVersion.TLSv12.Only();

        protected override int[] GetSupportedCipherSuites() =>
            new[] { CipherSuite.TLS_PSK_WITH_AES_128_GCM_SHA256 };
    }

    private sealed class IdentityManager : TlsPskIdentityManager
    {
        private readonly byte[] _psk;

        public IdentityManager(byte[] psk) => _psk = psk;

        public byte[]? GetHint() => null;

        public byte[]? GetPsk(byte[] identity)
        {
            // Constant-time comparison is unnecessary for the identity (it's
            // a public label); the PSK itself never leaves this process.
            var expected = Encoding.UTF8.GetBytes(PskIdentity);
            return identity.AsSpan().SequenceEqual(expected) ? (byte[])_psk.Clone() : null;
        }
    }
}
