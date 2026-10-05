using System.Buffers;
using System.Globalization;
using System.Text;
using ValveKeyValue;

namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>
/// Reads launch entries and VR support from Steam's local binary <c>appinfo.vdf</c> cache.
/// Ported from the PCVR host (2026-10-05, when the game library became public): the reader is
/// unchanged, plus <see cref="ReadApps"/> (one pass for a whole library), the <c>common</c>
/// section's VR flags, and <see cref="DetectKind"/>.
/// </summary>
public static class SteamAppInfo
{
    private const uint MagicPrefix = 0x075644;
    private const byte MinimumVersion = 39;
    private const byte MaximumVersion = 41;

    public sealed record LaunchEntry(
        int Index,
        string Executable,
        string? Arguments,
        string? WorkingDirectory,
        string? Type,
        string? Description,
        string? OsList,
        string? OsArchitecture,
        bool RequiresBeta,
        bool RequiresDlc);

    /// <summary>What the library needs from one app's appinfo: its launch entries, the
    /// <c>common</c> section's VR flags, and its client icon's hash (for desktop shortcuts).</summary>
    public sealed record AppInfo(
        IReadOnlyList<LaunchEntry> Entries,
        bool OnlyVrSupport,
        bool VrSupport,
        string? ClientIcon);

    /// <summary>
    /// Reads one app rather than materializing the full cache. Entry sizes let non-matching apps be
    /// skipped, while version 41's shared string table is loaded once before the scan.
    /// </summary>
    public static IReadOnlyList<LaunchEntry> ReadLaunchEntries(string path, uint wantedAppId) =>
        ReadApps(path, new HashSet<uint> { wantedAppId }).TryGetValue(wantedAppId, out var app)
            ? app.Entries
            : Array.Empty<LaunchEntry>();

    /// <summary>
    /// Every wanted app in one pass over the file — a library of thousands of titles costs one
    /// read, not one per title. Apps the cache does not hold are simply absent from the result.
    /// </summary>
    public static IReadOnlyDictionary<uint, AppInfo> ReadApps(string path, IReadOnlySet<uint> wanted)
    {
        var result = new Dictionary<uint, AppInfo>();
        if (wanted.Count == 0) return result;
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new BinaryReader(input, Encoding.UTF8, leaveOpen: true);

        var rawMagic = reader.ReadUInt32();
        var version = (byte)(rawMagic & 0xff);
        if ((rawMagic >> 8) != MagicPrefix
            || version < MinimumVersion
            || version > MaximumVersion)
        {
            throw new InvalidDataException($"Unsupported Steam appinfo version 0x{rawMagic:X8}.");
        }

        _ = reader.ReadUInt32(); // Steam universe
        var options = new KVSerializerOptions();
        if (version >= 41)
        {
            var stringTableOffset = reader.ReadInt64();
            if (stringTableOffset < reader.BaseStream.Position
                || stringTableOffset >= reader.BaseStream.Length)
            {
                throw new InvalidDataException("Steam appinfo has an invalid string-table offset.");
            }

            var entriesOffset = reader.BaseStream.Position;
            reader.BaseStream.Position = stringTableOffset;
            var count = reader.ReadUInt32();
            if (count > 1_000_000)
                throw new InvalidDataException("Steam appinfo string table is unreasonably large.");

            var strings = new string[(int)count];
            for (var i = 0; i < strings.Length; i++)
                strings[i] = ReadNullTerminatedUtf8(reader.BaseStream);
            options.StringTable = new StringTable(strings);
            reader.BaseStream.Position = entriesOffset;
        }

        var deserializer = KVSerializer.Create(KVSerializationFormat.KeyValues1Binary);
        while (reader.BaseStream.Position + sizeof(uint) <= reader.BaseStream.Length
               && result.Count < wanted.Count)
        {
            var appId = reader.ReadUInt32();
            if (appId == 0) break;

            var size = reader.ReadUInt32();
            var end = checked(reader.BaseStream.Position + size);
            if (end > reader.BaseStream.Length)
                throw new InvalidDataException($"Steam appinfo entry {appId} extends past EOF.");

            if (!wanted.Contains(appId))
            {
                reader.BaseStream.Position = end;
                continue;
            }

            SkipEntryMetadata(reader, version);
            var document = deserializer.Deserialize(reader.BaseStream, options);
            if (reader.BaseStream.Position != end)
                throw new InvalidDataException($"Steam appinfo entry {appId} has an invalid size.");
            var common = FindChild(document, "common");
            result[appId] = new AppInfo(
                ParseLaunchEntries(document),
                OnlyVrSupport: IsOne(common, "onlyvrsupport"),
                VrSupport: IsOne(common, "openvrsupport") || IsOne(common, "openxrsupport")
                           || IsOne(common, "oculusvrsupport") || IsOne(common, "onlyvrsupport"),
                ClientIcon: GetString(common, "clienticon"));
        }

        return result;
    }

    private static bool IsOne(KVObject? parent, string key) => GetString(parent, key) == "1";

    /// <summary>
    /// VR, flat or both, from Steam's own metadata: <c>onlyvrsupport</c> (or nothing but VR launch
    /// entries) is VR-only; VR support next to a desktop entry is both; no VR anywhere is flat.
    /// An app the cache does not describe is flat — the user can override any of these.
    /// </summary>
    public static GameKind DetectKind(AppInfo? app)
    {
        if (app is null) return GameKind.Flat;
        var compatible = app.Entries.Where(IsCompatibleWindowsEntry).ToList();
        var hasVrEntry = compatible.Any(IsVrEntry);
        var hasDesktopEntry = compatible.Any(e => !IsVrEntry(e));
        if (app.OnlyVrSupport || (hasVrEntry && !hasDesktopEntry)) return GameKind.Vr;
        if (app.VrSupport || hasVrEntry) return GameKind.Both;
        return GameKind.Flat;
    }

    /// <summary>
    /// Selects the launch Steam would expose for PCVR: a compatible Windows VR entry first, then a
    /// compatible default. Steam's own order breaks ties, preserving the publisher's preference.
    /// </summary>
    public static LaunchEntry? SelectPcvrLaunchEntry(IEnumerable<LaunchEntry> entries) =>
        entries
            .Where(IsCompatibleWindowsEntry)
            .OrderByDescending(Score)
            .ThenBy(entry => entry.Index)
            .FirstOrDefault();

    /// <summary>
    /// Selects the launch Steam's Play button would use on a plain desktop: the best compatible
    /// entry that is not a VR one (no "vr" type, no VR runtime named in its description).
    /// Returns null when every compatible entry is a VR entry, i.e. a VR-only title — the caller
    /// decides whether to fall back to <see cref="SelectPcvrLaunchEntry"/>.
    /// </summary>
    public static LaunchEntry? SelectDesktopLaunchEntry(IEnumerable<LaunchEntry> entries) =>
        entries
            .Where(IsCompatibleWindowsEntry)
            .Where(entry => !IsVrEntry(entry))
            .OrderByDescending(entry =>
                entry.Type?.Equals("default", StringComparison.OrdinalIgnoreCase) == true ? 1 : 0)
            .ThenBy(entry => entry.Index)
            .FirstOrDefault();

    public static bool IsVrEntry(LaunchEntry entry)
    {
        if (entry.Type?.Equals("vr", StringComparison.OrdinalIgnoreCase) == true) return true;
        var description = entry.Description ?? "";
        return description.Contains("OpenXR", StringComparison.OrdinalIgnoreCase)
            || description.Contains("Oculus", StringComparison.OrdinalIgnoreCase)
            || description.Contains("SteamVR", StringComparison.OrdinalIgnoreCase)
            || description.Contains(" VR", StringComparison.OrdinalIgnoreCase)
            || description.StartsWith("VR", StringComparison.OrdinalIgnoreCase);
    }

    private static int Score(LaunchEntry entry)
    {
        var score = entry.Type?.Equals("vr", StringComparison.OrdinalIgnoreCase) == true ? 100 : 0;
        var description = entry.Description ?? "";
        if (description.Contains("OpenXR", StringComparison.OrdinalIgnoreCase)) score += 40;
        else if (description.Contains("Oculus", StringComparison.OrdinalIgnoreCase)) score += 30;
        else if (description.Contains("SteamVR", StringComparison.OrdinalIgnoreCase)
                 || description.Contains(" VR", StringComparison.OrdinalIgnoreCase)) score += 20;
        if (entry.Type?.Equals("default", StringComparison.OrdinalIgnoreCase) == true) score += 10;
        if (entry.RequiresBeta) score -= 50;
        if (entry.RequiresDlc) score -= 25;
        return score;
    }

    private static bool IsCompatibleWindowsEntry(LaunchEntry entry)
    {
        if (!entry.Executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return false;
        // These entries are available only under Steam-owned state that the local cache does not
        // expose here. Selecting one without proving its condition is worse than using the next
        // unconditional launch entry.
        if (entry.RequiresBeta || entry.RequiresDlc) return false;

        if (!string.IsNullOrWhiteSpace(entry.OsList))
        {
            var operatingSystems = entry.OsList.Split(
                ',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            if (!operatingSystems.Any(os => os.Equals("windows", StringComparison.OrdinalIgnoreCase)))
                return false;
        }

        return entry.OsArchitecture is null
            || !entry.OsArchitecture.Contains("arm", StringComparison.OrdinalIgnoreCase);
    }

    private static IReadOnlyList<LaunchEntry> ParseLaunchEntries(KVObject root)
    {
        var config = FindChild(root, "config");
        var launch = FindChild(config, "launch");
        if (launch is null) return Array.Empty<LaunchEntry>();

        var result = new List<LaunchEntry>();
        foreach (var value in launch.Children)
        {
            if (!int.TryParse(value.Name, out var index)) continue;
            var executable = GetString(value, "executable");
            if (string.IsNullOrWhiteSpace(executable)) continue;

            var entryConfig = FindChild(value, "config");
            result.Add(new LaunchEntry(
                Index: index,
                Executable: executable,
                Arguments: GetString(value, "arguments"),
                WorkingDirectory: GetString(value, "workingdir"),
                Type: GetString(value, "type"),
                Description: GetString(value, "description"),
                OsList: GetString(entryConfig, "oslist"),
                OsArchitecture: GetString(entryConfig, "osarch"),
                RequiresBeta: HasValue(entryConfig, "betakey"),
                RequiresDlc: HasValue(entryConfig, "ownsdlc")));
        }
        return result;
    }

    private static KVObject? FindChild(KVObject? parent, string key) =>
        parent?.Children.FirstOrDefault(
            child => child.Name.Equals(key, StringComparison.OrdinalIgnoreCase));

    private static string? GetString(KVObject? parent, string key) =>
        FindChild(parent, key) is { } value
            ? Convert.ToString(value.Value, CultureInfo.InvariantCulture)?.Trim()
            : null;

    private static bool HasValue(KVObject? parent, string key) =>
        !string.IsNullOrWhiteSpace(GetString(parent, key));

    private static void SkipEntryMetadata(BinaryReader reader, byte version)
    {
        const int sha1Length = 20;
        _ = reader.ReadUInt32(); // info state
        _ = reader.ReadUInt32(); // last updated
        _ = reader.ReadUInt64(); // PICS token
        if (reader.ReadBytes(sha1Length).Length != sha1Length)
            throw new EndOfStreamException();
        _ = reader.ReadUInt32(); // change number
        if (version >= 40 && reader.ReadBytes(sha1Length).Length != sha1Length)
            throw new EndOfStreamException();
    }

    private static string ReadNullTerminatedUtf8(Stream stream)
    {
        var buffer = ArrayPool<byte>.Shared.Rent(64);
        try
        {
            var length = 0;
            while (true)
            {
                var next = stream.ReadByte();
                if (next < 0) throw new EndOfStreamException();
                if (next == 0) return Encoding.UTF8.GetString(buffer, 0, length);
                if (length >= 1_048_576)
                    throw new InvalidDataException("Steam appinfo contains an oversized string.");
                if (length == buffer.Length)
                {
                    var expanded = ArrayPool<byte>.Shared.Rent(buffer.Length * 2);
                    Buffer.BlockCopy(buffer, 0, expanded, 0, length);
                    ArrayPool<byte>.Shared.Return(buffer);
                    buffer = expanded;
                }
                buffer[length++] = (byte)next;
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }
}
