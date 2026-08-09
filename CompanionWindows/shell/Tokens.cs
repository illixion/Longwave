using System.Security.Cryptography;

namespace Longwave.Companion.Shell;

/// <summary>
/// Unambiguous WPA2 alphabet — mirrors the backend's Tokens.cs (no 0/O/1/l/I), so a
/// passphrase read off a screen and typed into a headset can't be misread.
/// </summary>
internal static class Tokens
{
    private const string Alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";

    public static string Random(int length)
    {
        var bytes = RandomNumberGenerator.GetBytes(length);
        return string.Create(length, bytes, static (span, source) =>
        {
            for (int i = 0; i < span.Length; i++) span[i] = Alphabet[source[i] % Alphabet.Length];
        });
    }

    public static string Passphrase() => Random(8);

    public static string Ssid() => $"Longwave-{Random(4)}";
}
