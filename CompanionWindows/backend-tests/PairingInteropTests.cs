using System.Text;
using Longwave.WindowsCompanion.Backend.Devices;
using Longwave.WindowsCompanion.Backend.NativeStream;
using Org.BouncyCastle.Crypto.Parameters;
using Xunit;

namespace Longwave.WindowsCompanion.Backend.Tests;

/// <summary>
/// The pairing and the device proof must match the Swift side byte for byte.
/// Every expected value here came out of CryptoKit, running
/// Shared/CompanionPairing.swift and Shared/CompanionDevices.swift on fixed
/// inputs (keys of 0x11/0x22 bytes, nonces of 0x33/0x44, binding of 0x55).
/// </summary>
public sealed class PairingInteropTests
{
    private static byte[] B64(string s) => Convert.FromBase64String(s);
    private static byte[] Fill(byte value) => Enumerable.Repeat(value, 32).ToArray();

    [Fact]
    public void AgreesWithCryptoKitOnCodeAndKey()
    {
        var host = new X25519PrivateKeyParameters(Fill(0x22), 0);
        Assert.Equal(B64("D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA="), host.GeneratePublicKey().GetEncoded());
        var headsetPublic = new X25519PrivateKeyParameters(Fill(0x11), 0).GeneratePublicKey().GetEncoded();
        Assert.Equal(B64("e06Qm75//kTEZaIgA31gjuNYl9Me+XLwf3SJLLD3PxM="), headsetPublic);

        var commitment = PairingExchange.Commitment(headsetPublic, Fill(0x33));
        Assert.Equal(B64("SQk2NS3hqeZ0sucpBIhKFZQzc1PsrGH/MzseF0/qDeg="), commitment);

        var agreement = PairingExchange.Agree(host, commitment, headsetPublic, Fill(0x33),
            host.GeneratePublicKey().GetEncoded(), Fill(0x44));
        Assert.NotNull(agreement);
        Assert.Equal("741941", agreement!.Code);
        Assert.Equal(B64("G+LIwDHwlWEQTwGJQ5NfBMEsXeZM08jiEihcVQWyy0A="), agreement.Key);
    }

    [Fact]
    public void RejectsARevealThatDoesNotMatchItsCommitment()
    {
        var host = new X25519PrivateKeyParameters(Fill(0x22), 0);
        var headsetPublic = new X25519PrivateKeyParameters(Fill(0x11), 0).GeneratePublicKey().GetEncoded();
        var commitment = PairingExchange.Commitment(headsetPublic, Fill(0x33));
        Assert.Null(PairingExchange.Agree(host, commitment, headsetPublic, Fill(0x34),
            host.GeneratePublicKey().GetEncoded(), Fill(0x44)));
    }

    [Fact]
    public void SealsInCryptoKitsCombinedLayout()
    {
        var key = B64("G+LIwDHwlWEQTwGJQ5NfBMEsXeZM08jiEihcVQWyy0A=");
        // Swift sealed "hello": open it the way this side's Seal lays it out.
        var swiftSealed = B64("+43HdK/F0lGjWZKFeM+Fbu+7WxDWwYFl71VnfPfEYx2k");
        Assert.Equal("hello", Encoding.UTF8.GetString(Open(swiftSealed, key)));
        Assert.Equal("hi", Encoding.UTF8.GetString(Open(PairingExchange.Seal(Encoding.UTF8.GetBytes("hi"), key), key)));
    }

    [Fact]
    public void DeviceProofMatchesCompanionIdentify()
    {
        Assert.Equal(B64("1QA00VKWQY/2qAcxGQwkacMb8060g4HbVcEfk5EI174="),
            NativeStreamCrypto.Proof("device-token", Enumerable.Repeat((byte)0x55, 32).ToArray()));
    }

    [Fact]
    public void PskIdentityNamesTheDevice()
    {
        Assert.True(NativeStreamCrypto.ParseIdentity(Encoding.UTF8.GetBytes("LongwaveMacNative/v1"), out var legacy));
        Assert.Null(legacy);
        Assert.True(NativeStreamCrypto.ParseIdentity(Encoding.UTF8.GetBytes("LongwaveMacNative/v1/HS-1"), out var device));
        Assert.Equal("HS-1", device);
        Assert.False(NativeStreamCrypto.ParseIdentity(Encoding.UTF8.GetBytes("LongwaveAudio/v5/HS-1"), out _));
    }

    private static byte[] Open(byte[] combined, byte[] key)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(false, new AeadParameters(new KeyParameter(key), 128, combined[..12]));
        var body = combined[12..];
        var output = new byte[cipher.GetOutputSize(body.Length)];
        var length = cipher.ProcessBytes(body, 0, body.Length, output, 0);
        length += cipher.DoFinal(output, length);
        return output[..length];
    }
}
