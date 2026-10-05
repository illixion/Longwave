using System.Globalization;

namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>
/// Steam's on-disk layout: where it is installed, its libraries, each installed app's manifest,
/// and its local art cache. Ported from the PCVR host's GameLibrary (2026-10-05). Everything takes
/// the Steam root explicitly so tests can point it at a fixture directory.
/// </summary>
public static class SteamLibrary
{
    /// <summary>One installed app, from its <c>appmanifest_&lt;id&gt;.acf</c>.</summary>
    public sealed record InstalledApp(
        uint AppId,
        string Name,
        string InstallDir,
        long? SizeOnDisk,
        DateTimeOffset? LastPlayed);

    /// <summary>
    /// SteamVR and the redistributables are tools, not games. SteamVR in particular must never be
    /// offered: PCVR routes OpenVR through OpenComposite, and launching it produces a vrstartup
    /// failure and invites games to bind to a runtime with no headset.
    /// </summary>
    public static readonly IReadOnlySet<uint> NonGameAppIds = new HashSet<uint>
    {
        250820, // SteamVR
        228980, // Steamworks Common Redistributables
        1070560, 1391110, 1628350, // Steam Linux Runtime / Proton bits (harmless off Linux)
    };

    /// <summary>
    /// Steam's install directory, from the registry rather than a hardcoded Program Files path —
    /// Steam is frequently moved, and it records the path in lowercase.
    /// </summary>
    public static string? FindSteamRoot()
    {
        if (!OperatingSystem.IsWindows()) return null;
        string?[] candidates =
        {
            Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string,
            Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string,
            Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", null) as string,
        };
        foreach (var c in candidates)
        {
            if (string.IsNullOrWhiteSpace(c)) continue;
            var full = Path.GetFullPath(c.Replace('/', '\\'));
            if (Directory.Exists(full)) return full;
        }
        return null;
    }

    /// <summary>Library roots from <c>libraryfolders.vdf</c> (both the current and pre-2021 layout).</summary>
    public static List<string> ParseLibraryFolders(string vdfContent)
    {
        var result = new List<string>();
        foreach (var (key, value) in VdfPairs(vdfContent))
        {
            if (key.Equals("path", StringComparison.OrdinalIgnoreCase))
                result.Add(value);
            else if (int.TryParse(key, out _) && value.Length > 2 && value[1] == ':')
                result.Add(value); // old layout: "1" "D:\\SteamLibrary"
        }
        return result;
    }

    /// <summary>A fully installed app from its manifest, or null (not installed / unparseable).</summary>
    public static InstalledApp? ParseAppManifest(string acfContent)
    {
        string? appId = null, name = null, installDir = null, stateFlags = null, size = null, played = null;
        foreach (var (key, value) in VdfPairs(acfContent))
        {
            switch (key.ToLowerInvariant())
            {
                case "appid": appId ??= value; break;
                case "name": name ??= value; break;
                case "installdir": installDir ??= value; break;
                case "stateflags": stateFlags ??= value; break;
                case "sizeondisk": size ??= value; break;
                case "lastplayed": played ??= value; break;
            }
        }
        if (appId is null || name is null || string.IsNullOrWhiteSpace(installDir)) return null;
        if (!uint.TryParse(appId, out var id)) return null;
        // StateFlags bit 4 = fully installed; an app mid-download or uninstalled is not launchable.
        if (stateFlags is not null && int.TryParse(stateFlags, out var flags) && (flags & 4) == 0)
            return null;
        DateTimeOffset? lastPlayed = long.TryParse(played, out var unix) && unix > 0
            ? DateTimeOffset.FromUnixTimeSeconds(unix)
            : null;
        return new InstalledApp(id, name, installDir,
            long.TryParse(size, NumberStyles.Integer, CultureInfo.InvariantCulture, out var bytes) && bytes > 0 ? bytes : null,
            lastPlayed);
    }

    /// <summary>
    /// Every fully installed app across every library, de-duplicated (an app in two libraries is
    /// listed once), tools excluded. InstallDir is made absolute
    /// (<c>&lt;library&gt;\steamapps\common\&lt;installdir&gt;</c>).
    /// </summary>
    public static List<InstalledApp> DiscoverInstalledApps(string? steamRoot, Action<string, Exception?>? warn = null)
    {
        var apps = new List<InstalledApp>();
        if (steamRoot is null) return apps;

        var libraries = new List<string> { steamRoot };
        var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
        if (File.Exists(vdf))
        {
            try { libraries.AddRange(ParseLibraryFolders(File.ReadAllText(vdf))); }
            catch (Exception ex) { warn?.Invoke($"Could not read {vdf}", ex); }
        }

        var seen = new HashSet<uint>();
        foreach (var library in libraries.Select(NormalizeDir).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var steamapps = Path.Combine(library, "steamapps");
            if (!Directory.Exists(steamapps)) continue;
            IEnumerable<string> manifests;
            try { manifests = Directory.EnumerateFiles(steamapps, "appmanifest_*.acf"); }
            catch (Exception ex) { warn?.Invoke($"Could not enumerate {steamapps}", ex); continue; }

            foreach (var manifest in manifests)
            {
                InstalledApp? app;
                try { app = ParseAppManifest(File.ReadAllText(manifest)); }
                catch (Exception ex) { warn?.Invoke($"Skipping unreadable manifest {manifest}", ex); continue; }
                if (app is null || NonGameAppIds.Contains(app.AppId) || !seen.Add(app.AppId)) continue;
                apps.Add(app with
                {
                    InstallDir = Path.GetFullPath(Path.Combine(steamapps, "common", app.InstallDir)),
                });
            }
        }
        return apps;
    }

    private static string NormalizeDir(string p) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(p));

    /// <summary>Steam's local art cache, or null. Everything there is already on disk, so the
    /// gallery needs no network and works offline.</summary>
    public static string? ArtCacheRoot(string? steamRoot)
    {
        if (steamRoot is null) return null;
        var cache = Path.Combine(steamRoot, "appcache", "librarycache");
        return Directory.Exists(cache) ? cache : null;
    }

    /* Each orientation falls back to the other rather than to nothing: coverage is not symmetric
       (25 of 29 titles on the reference host had portrait art, 21 a header), and a stretched header
       beats an empty tile. */
    public static readonly string[] PortraitCandidates =
        { "library_600x900.jpg", "library_600x900_2x.jpg", "header.jpg" };

    public static readonly string[] LandscapeCandidates =
        { "header.jpg", "library_hero.jpg", "library_600x900.jpg" };

    /// <summary>First existing art file, trying both cache layouts: current Steam's
    /// <c>&lt;appid&gt;\header.jpg</c> and older flat <c>&lt;appid&gt;_header.jpg</c>.</summary>
    public static string? FindArt(string? cacheRoot, uint appId, string[] fileNames)
    {
        if (cacheRoot is null) return null;
        foreach (var name in fileNames)
        {
            var perApp = Path.Combine(cacheRoot, appId.ToString(CultureInfo.InvariantCulture), name);
            if (File.Exists(perApp)) return perApp;
            var flat = Path.Combine(cacheRoot, $"{appId}_{name}");
            if (File.Exists(flat)) return flat;
        }
        return null;
    }

    /// <summary>
    /// True if the path is one we are willing to hand out as art: inside Steam's art cache, and an
    /// image. An art fetch on behalf of the headset gates on this so it cannot become a file read.
    /// </summary>
    public static bool IsAllowedArtPath(string? path, string? steamRoot)
    {
        var cache = ArtCacheRoot(steamRoot);
        if (string.IsNullOrWhiteSpace(path) || cache is null) return false;
        string full, root;
        try
        {
            full = Path.GetFullPath(path);
            root = Path.GetFullPath(cache);
        }
        catch { return false; }
        if (!full.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
            return false;
        var ext = Path.GetExtension(full);
        return ext.Equals(".jpg", StringComparison.OrdinalIgnoreCase)
            || ext.Equals(".jpeg", StringComparison.OrdinalIgnoreCase)
            || ext.Equals(".png", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Steam's cached client icon for a title (<c>steam\games\&lt;hash&gt;.ico</c>), or null.</summary>
    public static string? ClientIconPath(string? steamRoot, string? clientIcon)
    {
        if (steamRoot is null || string.IsNullOrWhiteSpace(clientIcon)
            || clientIcon.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) return null;
        var ico = Path.Combine(steamRoot, "steam", "games", clientIcon + ".ico");
        return File.Exists(ico) ? ico : null;
    }

    /// <summary>Every <c>"key" "value"</c> pair in a text VDF/ACF file, in order, unescaped.</summary>
    public static IEnumerable<(string Key, string Value)> VdfPairs(string content)
    {
        var i = 0;
        string? pendingKey = null;
        while (i < content.Length)
        {
            var c = content[i];
            if (c == '"')
            {
                var sb = new System.Text.StringBuilder();
                i++;
                while (i < content.Length && content[i] != '"')
                {
                    if (content[i] == '\\' && i + 1 < content.Length)
                    {
                        i++;
                        sb.Append(content[i] switch { 'n' => '\n', 't' => '\t', var other => other });
                    }
                    else sb.Append(content[i]);
                    i++;
                }
                i++; // closing quote
                if (pendingKey is null) pendingKey = sb.ToString();
                else
                {
                    yield return (pendingKey, sb.ToString());
                    pendingKey = null;
                }
            }
            else if (c == '{' || c == '}')
            {
                pendingKey = null; // the key named a block, not a value
                i++;
            }
            else if (c == '\n')
            {
                // A key alone on its line is a block name, whatever follows on the next.
                if (pendingKey is not null && NextNonSpace(content, i) == '{') pendingKey = null;
                i++;
            }
            else i++;
        }
    }

    private static char NextNonSpace(string s, int from)
    {
        for (var j = from; j < s.Length; j++)
            if (!char.IsWhiteSpace(s[j])) return s[j];
        return '\0';
    }
}
