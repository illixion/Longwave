using System.Security.Cryptography;

namespace VisionVNC.WindowsCompanion.Backend;

/// <summary>
/// Generates the SSID suffix and the WPA2 passphrase. The passphrase is an 8-char
/// alphanumeric string (WPA2 minimum length) drawn from an unambiguous alphabet so it's
/// painless to type by hand into visionOS Settings (no 0/O/1/l/I).
/// </summary>
public static class Tokens
{
    private const string Alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";

    public static string Random(int length)
    {
        if (length <= 0) throw new ArgumentOutOfRangeException(nameof(length));
        // Rejection-free, low-bias enough for a short human-typed secret: map random
        // bytes onto the alphabet. (Modulo bias over a 53-char alphabet is negligible
        // for an 8-char Wi-Fi passphrase shown on screen.)
        var bytes = RandomNumberGenerator.GetBytes(length);
        var chars = new char[length];
        for (int i = 0; i < length; i++) chars[i] = Alphabet[bytes[i] % Alphabet.Length];
        return new string(chars);
    }

    /// <summary>Default SSID, e.g. "VisionVNC-Gh7k".</summary>
    public static string DefaultSsid() => $"VisionVNC-{Random(4)}";

    /// <summary>Default 8-char WPA2 passphrase.</summary>
    public static string DefaultPassphrase() => Random(8);
}
