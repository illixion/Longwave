using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>
/// Controller Bridge's sealed datagrams, byte for byte as its
/// <c>protocol/qcb_crypto.c</c> (QuestControllerBridge repo) writes them:
/// a 36-byte header (0xE0, version 2, direction, 0, key id[8], session[16],
/// counter u64 LE), the inner packet under ChaCha20-Poly1305 with the header as
/// AAD, then the 16-byte tag.
/// <list type="bullet">
/// <item>key id = HMAC-SHA256(token, "ControllerBridge-KeyID-v1")[0..8]</item>
/// <item>Quest's key = HKDF-SHA256(token, salt: Quest session, info "… v2 sender")</item>
/// <item>host's key = HKDF-SHA256(token, salt: Quest session ‖ host session, info "… v2 host")</item>
/// <item>nonce = 0x00000000 ‖ counter LE</item>
/// </list>
/// QuestSealTests pins it to the vectors in that repo's test_qcb_crypto.c.
/// </summary>
public static class QuestSeal
{
    public const byte PacketSealed = 0xE0;
    public const byte Version = 2;
    public const int SessionSize = 16;
    public const int ChallengeSize = 32;
    public const byte FromSender = 0;
    public const byte FromHost = 1;
    public const int HeaderSize = 36;
    public const int TagSize = 16;
    public const int Overhead = HeaderSize + TagSize;

    public static byte[] KeyId(string token) =>
        HMACSHA256.HashData(Encoding.UTF8.GetBytes(token), Encoding.UTF8.GetBytes("ControllerBridge-KeyID-v1"))[..8];

    public static byte[] SessionKey(string token, ReadOnlySpan<byte> senderSession, ReadOnlySpan<byte> hostSession, byte direction)
    {
        if (senderSession.Length != SessionSize || (direction == FromHost && hostSession.Length != SessionSize))
            throw new ArgumentException("QuestSeal v2 sessions must be 16 bytes.");
        var salt = direction == FromHost
            ? [.. senderSession, .. hostSession]
            : senderSession.ToArray();
        var info = Encoding.UTF8.GetBytes(direction == FromHost
            ? "ControllerBridge-Seal-v2 host"
            : "ControllerBridge-Seal-v2 sender");
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, Encoding.UTF8.GetBytes(token), 32, salt, info);
    }

    public readonly record struct Header(byte Direction, byte[] KeyId, byte[] Session, ulong Counter);

    public static bool TryPeek(ReadOnlySpan<byte> packet, out Header header)
    {
        header = default;
        if (packet.Length < Overhead || packet[0] != PacketSealed || packet[1] != Version || packet[2] > FromHost)
            return false;
        var counter = BinaryPrimitives.ReadUInt64LittleEndian(packet.Slice(28, 8));
        if (counter == 0) return false;
        header = new Header(packet[2], packet.Slice(4, 8).ToArray(), packet.Slice(12, SessionSize).ToArray(), counter);
        return true;
    }

    public static byte[] Seal(byte[] key, byte[] keyId, ReadOnlySpan<byte> session, byte direction, ulong counter,
                              ReadOnlySpan<byte> inner)
    {
        if (keyId.Length != 8 || session.Length != SessionSize || counter == 0)
            throw new ArgumentException("Invalid QuestSeal v2 packet parameters.");
        var output = new byte[inner.Length + Overhead];
        output[0] = PacketSealed;
        output[1] = Version;
        output[2] = direction;
        keyId.CopyTo(output, 4);
        session.CopyTo(output.AsSpan(12, SessionSize));
        BinaryPrimitives.WriteUInt64LittleEndian(output.AsSpan(28, 8), counter);
        var cipher = Cipher(true, key, counter, output.AsSpan(0, HeaderSize).ToArray());
        var body = inner.ToArray();
        var length = cipher.ProcessBytes(body, 0, body.Length, output, HeaderSize);
        cipher.DoFinal(output, HeaderSize + length);
        return output;
    }

    /// <summary>The inner packet, or null when the datagram does not authenticate.</summary>
    public static byte[]? Open(byte[] key, ReadOnlySpan<byte> packet)
    {
        if (!TryPeek(packet, out var header)) return null;
        var cipher = Cipher(false, key, header.Counter, packet[..HeaderSize].ToArray());
        var body = packet[HeaderSize..].ToArray();
        var output = new byte[cipher.GetOutputSize(body.Length)];
        try
        {
            var length = cipher.ProcessBytes(body, 0, body.Length, output, 0);
            length += cipher.DoFinal(output, length);
            return output[..length];
        }
        catch (Org.BouncyCastle.Crypto.InvalidCipherTextException)
        {
            return null;
        }
    }

    private static Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305 Cipher(bool encrypt, byte[] key, ulong counter, byte[] aad)
    {
        var nonce = new byte[12];
        BinaryPrimitives.WriteUInt64LittleEndian(nonce.AsSpan(4), counter);
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(encrypt, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
        return cipher;
    }
}
