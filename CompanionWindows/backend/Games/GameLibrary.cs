using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>
/// The Companion's game library: every installed Steam game plus titles the user added, VR and
/// flat alike. Public (MIT) since 2026-10-05 — it moved here from the closed PCVR host, which now
/// only does the CloudXR-specific part of a VR launch (see NATIVE_V3_PROTOCOL.md §7.6).
///
/// <para><b>What it owns.</b> Discovery (Steam manifests + <c>appinfo.vdf</c>), each title's kind
/// (VR / flat / both, from Steam metadata, user-overridable), custom entries (an exact executable
/// and arguments — a custom entry runs exactly what the user picked), cover art, optimised launch
/// profiles, last played, and the set exposed to the headset. And launch <i>resolution</i>: turning
/// a title into an executable, arguments, working directory and Steam identity. It never starts a
/// game itself — the Companion starts desktop launches and the PCVR host starts VR ones — because
/// this process is tree-killed on quit and a game must outlive it.</para>
///
/// <para><b>Why Steam titles launch directly.</b> Steam asks for desktop confirmation when a
/// <c>steam://run</c> URL carries arguments, which makes an unattended launch unusable. So the
/// library reads the title's Windows launch entries from <c>appinfo.vdf</c> and the caller starts
/// that executable with <c>SteamAppId</c>/<c>SteamGameId</c> set, Steam already running — which
/// keeps Steam's DRM from quitting the game and relaunching it through Steam.</para>
///
/// <para><b>Headset boundary.</b> The headset sees, illustrates and starts only what the user
/// exposed, and for now only VR-capable titles (the PCVR gallery has no flat mode). The methods
/// that serve it take <c>exposedOnly</c>; there is deliberately no directory-listing API.</para>
/// </summary>
public sealed class GameLibrary
{
    private static readonly JsonSerializerOptions StateJsonOpts = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly ILogger? _log;
    private readonly string _statePath;
    private readonly string? _legacyStatePath;
    private readonly Func<string?> _steamRoot;
    private readonly object _stateLock = new();
    private readonly object _appInfoLock = new();
    private (string Path, DateTime Mtime, long Length, IReadOnlyDictionary<uint, SteamAppInfo.AppInfo> Apps)? _appInfoCache;
    private readonly int _syntheticCount;

    /// <summary>Where the PCVR host kept its curation before the library moved (every install
    /// used this one path). Read once to migrate, never written.</summary>
    public const string LegacyHostStatePath = @"C:\dev\Longwave-companion\game-library.json";

    public GameLibrary(ILogger? log, string statePath, string? legacyStatePath = LegacyHostStatePath,
                       Func<string?>? steamRoot = null, int syntheticCount = 0)
    {
        _log = log;
        _statePath = statePath;
        _legacyStatePath = legacyStatePath;
        _steamRoot = steamRoot ?? SteamLibrary.FindSteamRoot;
        _syntheticCount = syntheticCount;
    }

    /// <summary>The per-user state file: next to the Companion's own settings
    /// (<c>%APPDATA%\longwave-windows-companion</c>, passed in as LONGWAVE_STATE_DIR by the app).</summary>
    public static string DefaultStatePath()
    {
        var dir = Environment.GetEnvironmentVariable("LONGWAVE_STATE_DIR");
        if (string.IsNullOrWhiteSpace(dir))
            dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                               "longwave-windows-companion");
        return Path.Combine(dir, "game-library.json");
    }

    // ---- State ------------------------------------------------------------

    internal sealed record CustomTitle(
        [property: JsonPropertyName("id")] string Id,
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("executable")] string Executable,
        [property: JsonPropertyName("arguments")] string? Arguments,
        [property: JsonPropertyName("kind")] GameKind Kind,
        [property: JsonPropertyName("linkedSteamAppId")] uint? LinkedSteamAppId = null);

    internal sealed record LibraryState
    {
        [JsonPropertyName("version")] public int Version { get; init; } = 2;
        [JsonPropertyName("customTitles")] public List<CustomTitle> CustomTitles { get; init; } = new();
        [JsonPropertyName("exposedIds")] public List<string> ExposedIds { get; init; } = new();
        /// <summary>Optimised profiles are on by default; this is the explicit opt-out list.</summary>
        [JsonPropertyName("disabledOptimizedIds")] public List<string> DisabledOptimizedIds { get; init; } = new();
        [JsonPropertyName("kindOverrides")] public Dictionary<string, GameKind> KindOverrides { get; init; } = new();
        [JsonPropertyName("lastLaunched")] public Dictionary<string, DateTimeOffset> LastLaunched { get; init; } = new();
        [JsonPropertyName("migratedFrom")] public string? MigratedFrom { get; init; }
    }

    /// <summary>The PCVR host's old format, read only to migrate it.</summary>
    internal sealed record LegacyState(
        [property: JsonPropertyName("customTitles")] List<LegacyTitle>? CustomTitles,
        [property: JsonPropertyName("exposedIds")] List<string>? ExposedIds,
        [property: JsonPropertyName("optimizedIds")] List<string>? OptimizedIds = null,
        [property: JsonPropertyName("disabledOptimizedIds")] List<string>? DisabledOptimizedIds = null);

    internal sealed record LegacyTitle(
        [property: JsonPropertyName("id")] string? Id,
        [property: JsonPropertyName("name")] string? Name,
        [property: JsonPropertyName("executable")] string? Executable,
        [property: JsonPropertyName("arguments")] string? Arguments);

    private LibraryState LoadState()
    {
        lock (_stateLock)
        {
            if (File.Exists(_statePath))
            {
                try
                {
                    return JsonSerializer.Deserialize<LibraryState>(File.ReadAllText(_statePath), StateJsonOpts)
                           ?? new LibraryState();
                }
                catch (Exception ex)
                {
                    // Reported, not thrown: a corrupt file must not take the library down, and
                    // Steam titles are rediscoverable regardless.
                    _log?.LogWarning(ex, "Could not read game library state from {Path}", _statePath);
                    return new LibraryState();
                }
            }
            var migrated = MigrateLegacy();
            if (migrated is not null)
            {
                try { SaveState(migrated); }
                catch (Exception ex) { _log?.LogWarning(ex, "Could not write the migrated library state."); }
                return migrated;
            }
            return new LibraryState();
        }
    }

    /// <summary>
    /// One-time import of the PCVR host's state, so curated and exposed lists survive the move.
    /// The old file is left where it is (an older host that is still installed keeps working).
    /// </summary>
    private LibraryState? MigrateLegacy()
    {
        if (string.IsNullOrEmpty(_legacyStatePath) || !File.Exists(_legacyStatePath)) return null;
        try
        {
            var old = JsonSerializer.Deserialize<LegacyState>(File.ReadAllText(_legacyStatePath), StateJsonOpts);
            if (old is null) return null;
            var custom = (old.CustomTitles ?? new())
                .Where(t => !string.IsNullOrWhiteSpace(t.Id) && !string.IsNullOrWhiteSpace(t.Executable))
                // Everything in the old library was a PCVR title.
                .Select(t => new CustomTitle(t.Id!, string.IsNullOrWhiteSpace(t.Name)
                    ? Path.GetFileNameWithoutExtension(t.Executable!) : t.Name!,
                    t.Executable!, t.Arguments, GameKind.Vr))
                .ToList();
            List<string> disabled;
            if (old.DisabledOptimizedIds is not null) disabled = old.DisabledOptimizedIds;
            else if (old.OptimizedIds is null) disabled = new();
            else
            {
                var enabled = new HashSet<string>(old.OptimizedIds, StringComparer.OrdinalIgnoreCase);
                disabled = LaunchProfiles.LegacyOptInIds.Select(SteamTitleId).Where(id => !enabled.Contains(id)).ToList();
            }
            _log?.LogInformation(
                "Migrated the PCVR host's game library ({Custom} custom, {Exposed} exposed) from {Path}.",
                custom.Count, old.ExposedIds?.Count ?? 0, _legacyStatePath);
            return new LibraryState
            {
                CustomTitles = custom,
                ExposedIds = old.ExposedIds ?? new(),
                DisabledOptimizedIds = disabled,
                MigratedFrom = _legacyStatePath,
            };
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "Could not migrate the old library state from {Path}", _legacyStatePath);
            return null;
        }
    }

    private void SaveState(LibraryState state)
    {
        lock (_stateLock)
        {
            var dir = Path.GetDirectoryName(_statePath);
            if (dir is not null) Directory.CreateDirectory(dir);
            // Write-then-move so a crash mid-write cannot lose every custom title.
            var tmp = _statePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(state, StateJsonOpts));
            File.Move(tmp, _statePath, overwrite: true);
        }
    }

    private void Update(Func<LibraryState, LibraryState> change)
    {
        lock (_stateLock) SaveState(change(LoadState()));
    }

    // ---- Listing ----------------------------------------------------------

    public static string SteamTitleId(uint appId) => $"steam:{appId}";

    /// <summary>appinfo for every given app, from one pass over the file, cached until Steam
    /// rewrites it.</summary>
    private IReadOnlyDictionary<uint, SteamAppInfo.AppInfo> AppInfos(string? steamRoot, IReadOnlySet<uint> ids)
    {
        var path = steamRoot is null ? null : Path.Combine(steamRoot, "appcache", "appinfo.vdf");
        if (path is null || !File.Exists(path)) return new Dictionary<uint, SteamAppInfo.AppInfo>();
        var info = new FileInfo(path);
        lock (_appInfoLock)
        {
            if (_appInfoCache is { } c && c.Path == path && c.Mtime == info.LastWriteTimeUtc
                && c.Length == info.Length && ids.All(c.Apps.ContainsKey))
                return c.Apps;
            try
            {
                var apps = SteamAppInfo.ReadApps(path, ids);
                _appInfoCache = (path, info.LastWriteTimeUtc, info.Length, apps);
                return apps;
            }
            catch (Exception ex)
            {
                _log?.LogWarning(ex, "Could not read Steam's appinfo.vdf; kinds fall back to flat.");
                return new Dictionary<uint, SteamAppInfo.AppInfo>();
            }
        }
    }

    private readonly object _installedLock = new();
    private (string? Root, DateTime At, List<SteamLibrary.InstalledApp> Apps)? _installedCache;
    private static readonly TimeSpan InstalledCacheLifetime = TimeSpan.FromSeconds(15);

    /// <summary>Forget what was discovered, so the next listing rescans Steam (the Games tab's
    /// refresh, and opening the tab).</summary>
    public void Invalidate()
    {
        lock (_installedLock) _installedCache = null;
    }

    /// <summary>Manifest discovery, cached briefly: one launch resolves, matches and lists several
    /// times, and a library of thousands of manifests should not be re-read for each.</summary>
    private List<SteamLibrary.InstalledApp> InstalledApps(string? steamRoot)
    {
        lock (_installedLock)
        {
            if (_installedCache is { } c && c.Root == steamRoot && DateTime.UtcNow - c.At < InstalledCacheLifetime)
                return c.Apps;
            var apps = SteamLibrary.DiscoverInstalledApps(steamRoot, (m, ex) => _log?.LogDebug(ex, "{Message}", m));
            _installedCache = (steamRoot, DateTime.UtcNow, apps);
            return apps;
        }
    }

    /// <summary>Everything installed or added, each with its kind, exposure, profile and art.</summary>
    public IReadOnlyList<GameTitle> ListAllTitles()
    {
        var state = LoadState();
        var exposed = new HashSet<string>(state.ExposedIds, StringComparer.OrdinalIgnoreCase);
        var disabledOptimized = new HashSet<string>(state.DisabledOptimizedIds, StringComparer.OrdinalIgnoreCase);
        var steamRoot = _steamRoot();
        var artRoot = SteamLibrary.ArtCacheRoot(steamRoot);
        var installed = InstalledApps(steamRoot);
        var infos = AppInfos(steamRoot, installed.Select(a => a.AppId).ToHashSet());

        var all = new List<GameTitle>(installed.Count + state.CustomTitles.Count + _syntheticCount);
        foreach (var t in state.CustomTitles)
        {
            var id = t.Id;
            var linked = t.LinkedSteamAppId;
            all.Add(Finish(new GameTitle
            {
                Id = id, Name = t.Name, Source = "custom",
                Executable = t.Executable, Arguments = t.Arguments,
                InstallDir = Path.GetDirectoryName(t.Executable),
                DetectedKind = t.Kind, Kind = t.Kind,
                Icon = t.Executable,
                LinkedSteamAppId = linked,
                PortraitArt = linked is uint a1 ? SteamLibrary.FindArt(artRoot, a1, SteamLibrary.PortraitCandidates) : null,
                LandscapeArt = linked is uint a2 ? SteamLibrary.FindArt(artRoot, a2, SteamLibrary.LandscapeCandidates) : null,
            }, state, exposed, disabledOptimized));
        }
        foreach (var app in installed)
        {
            infos.TryGetValue(app.AppId, out var info);
            var detected = SteamAppInfo.DetectKind(info);
            all.Add(Finish(new GameTitle
            {
                Id = SteamTitleId(app.AppId), Name = app.Name, Source = "steam",
                SteamAppId = app.AppId, InstallDir = app.InstallDir,
                DetectedKind = detected, Kind = detected,
                PortraitArt = SteamLibrary.FindArt(artRoot, app.AppId, SteamLibrary.PortraitCandidates),
                LandscapeArt = SteamLibrary.FindArt(artRoot, app.AppId, SteamLibrary.LandscapeCandidates),
                Icon = SteamLibrary.ClientIconPath(steamRoot, info?.ClientIcon),
                LastPlayed = app.LastPlayed,
                SizeBytes = app.SizeOnDisk,
            }, state, exposed, disabledOptimized));
        }
        for (var i = 0; i < _syntheticCount; i++)
        {
            // LONGWAVE_LIBRARY_SYNTHETIC=<n>: a large fake library for exercising the UI. Not
            // launchable (the executable does not exist), and never persisted.
            var kind = (GameKind)(i % 3);
            all.Add(new GameTitle
            {
                Id = $"synthetic:{i}", Name = $"Synthetic title {i:D5}", Source = "custom",
                Executable = $@"C:\synthetic\{i}\game.exe", Kind = kind, DetectedKind = kind,
                LastPlayed = DateTimeOffset.UtcNow.AddHours(-i), SizeBytes = 1_000_000L * (i % 997 + 1),
            });
        }
        all.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
        return all;
    }

    private static GameTitle Finish(GameTitle t, LibraryState state, HashSet<string> exposed,
                                    HashSet<string> disabledOptimized)
    {
        var kind = state.KindOverrides.TryGetValue(t.Id, out var k) ? k : t.DetectedKind;
        var played = state.LastLaunched.TryGetValue(t.Id, out var p) && (t.LastPlayed is null || p > t.LastPlayed)
            ? p : t.LastPlayed;
        var profile = t.SteamAppId is uint appId && LaunchProfiles.ByAppId.TryGetValue(appId, out var pr) ? pr : null;
        return t with
        {
            Kind = kind,
            KindOverridden = state.KindOverrides.ContainsKey(t.Id),
            Exposed = exposed.Contains(t.Id),
            LastPlayed = played,
            OptimizedAvailable = profile is not null,
            OptimizedNote = profile?.Note,
            Optimized = profile is not null && !disabledOptimized.Contains(t.Id),
        };
    }

    /// <summary>
    /// The headset's view: exposed and VR-capable, and only the fields the visionOS app decodes
    /// (no executable paths leave the PC). Flat titles can be exposed in the state for a future
    /// "launch from headset" over Native/v3, but the PCVR gallery has no flat mode.
    /// </summary>
    public IReadOnlyList<GameTitle> ListExposedTitles() =>
        ListAllTitles()
            .Where(t => t.Exposed && t.Kind.CanRunInVr())
            .Select(t => new GameTitle
            {
                Id = t.Id, Name = t.Name, Source = t.Source, SteamAppId = t.SteamAppId,
                InstallDir = t.InstallDir, PortraitArt = t.PortraitArt, LandscapeArt = t.LandscapeArt,
                Kind = t.Kind, DetectedKind = t.DetectedKind, Exposed = true,
            })
            .ToList();

    public GameTitle? Find(string id) =>
        ListAllTitles().FirstOrDefault(t => string.Equals(t.Id, id, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// What a file on disk is to the library, by path: a custom title with exactly that executable
    /// (<c>Exact</c>), or else the Steam title whose install folder contains it, with whether the file
    /// is the executable that title's desktop or VR launch entry would start. A different file in
    /// the same folder (a launcher, a DX11 build, a tool) is still that Steam game for its identity,
    /// but the caller must run that file, not the title. Null when the file belongs to nothing.
    /// </summary>
    public PathMatch? MatchPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        string full;
        try { full = Path.GetFullPath(path); } catch { return null; }
        var titles = ListAllTitles();
        var custom = titles.FirstOrDefault(t => t.Executable is not null
            && string.Equals(Path.GetFullPath(t.Executable), full, StringComparison.OrdinalIgnoreCase));
        if (custom is not null) return new PathMatch(custom, Exact: true, DesktopEntry: false, VrEntry: false);
        var steam = titles.Where(t => t.Source == "steam" && t.InstallDir is not null && IsInside(full, t.InstallDir))
                          .OrderByDescending(t => t.InstallDir!.Length)
                          .FirstOrDefault();
        if (steam is null) return null;
        bool Same(string? exe) => exe is not null && string.Equals(exe, full, StringComparison.OrdinalIgnoreCase);
        bool Starts(bool vr)
        {
            try
            {
                var plan = ResolveSteam(steam, steam.SteamAppId!.Value, vr);
                if (Same(plan.Executable)) return true;
                // The entry's own executable counts too when a profile swapped it for another.
                return vr && plan.ProfileApplied && Same(ResolveSteam(steam with { Optimized = false }, steam.SteamAppId.Value, true).Executable);
            }
            catch (LaunchRefusedException) { return false; }
        }
        return new PathMatch(steam, Exact: false, DesktopEntry: Starts(false), VrEntry: Starts(true));
    }

    private static bool IsInside(string full, string dir)
    {
        var prefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(dir)) + Path.DirectorySeparatorChar;
        return full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    // ---- Curation ---------------------------------------------------------

    /// <summary>Replaces the exposed set. Ids that match nothing are dropped, so uninstalling a
    /// game does not leave dead entries behind.</summary>
    public IReadOnlyList<GameTitle> SetExposed(IEnumerable<string> ids)
    {
        var known = ListAllTitles().Select(t => t.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var wanted = ids.Where(known.Contains).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        Update(s => s with { ExposedIds = wanted });
        _log?.LogInformation("Exposed set is now {Count} titles.", wanted.Count);
        return ListAllTitles();
    }

    public IReadOnlyList<GameTitle> SetOptimized(string id, bool enabled)
    {
        Update(s =>
        {
            var set = new HashSet<string>(s.DisabledOptimizedIds, StringComparer.OrdinalIgnoreCase);
            if (enabled) set.Remove(id); else set.Add(id);
            return s with { DisabledOptimizedIds = set.ToList() };
        });
        _log?.LogInformation("Optimised launch profile {State} for {Id}.", enabled ? "enabled" : "disabled", id);
        return ListAllTitles();
    }

    /// <summary>Overrides a title's kind, or (null) returns it to what was detected.</summary>
    public GameTitle? SetKind(string id, GameKind? kind)
    {
        Update(s =>
        {
            var overrides = new Dictionary<string, GameKind>(s.KindOverrides, StringComparer.OrdinalIgnoreCase);
            var custom = s.CustomTitles;
            var c = custom.FirstOrDefault(t => string.Equals(t.Id, id, StringComparison.OrdinalIgnoreCase));
            if (c is not null && kind is { } k)
            {
                // A custom title's kind is the user's own choice already: change it in place.
                custom = custom.Select(t => t == c ? t with { Kind = k } : t).ToList();
                overrides.Remove(id);
            }
            else if (kind is { } k2) overrides[id] = k2;
            else overrides.Remove(id);
            return s with { KindOverrides = overrides, CustomTitles = custom };
        });
        return Find(id);
    }

    /// <summary>
    /// Adds a user-picked executable. The path comes from the Companion's own file dialog, so it
    /// was chosen locally — but it is still validated, because an entry that cannot launch is
    /// worse than a rejected add. Re-adding the same executable returns the existing entry.
    /// </summary>
    /// <param name="linkedSteamAppId">The Steam game the file belongs to (a non-entry file in its
    /// folder): launches then carry that app's identity, and art comes from it.</param>
    public GameTitle AddCustomTitle(string executablePath, string? name, string? arguments, GameKind kind,
                                    uint? linkedSteamAppId = null)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
            throw new ArgumentException("Executable path is required.", nameof(executablePath));
        var full = Path.GetFullPath(executablePath);
        if (!File.Exists(full)) throw new FileNotFoundException($"No such file: {full}");

        string id = "";
        Update(s =>
        {
            var existing = s.CustomTitles.FirstOrDefault(
                t => string.Equals(t.Executable, full, StringComparison.OrdinalIgnoreCase)
                     && string.Equals(t.Arguments ?? "", arguments ?? "", StringComparison.Ordinal));
            if (existing is not null) { id = existing.Id; return s; }
            id = "custom:" + Guid.NewGuid().ToString("N")[..12];
            var title = new CustomTitle(id,
                string.IsNullOrWhiteSpace(name) ? Path.GetFileNameWithoutExtension(full) : name.Trim(),
                full, string.IsNullOrWhiteSpace(arguments) ? null : arguments, kind, linkedSteamAppId);
            return s with { CustomTitles = new List<CustomTitle>(s.CustomTitles) { title } };
        });
        _log?.LogInformation("Added custom {Kind} title {Id}.", kind.Name(), id);
        return Find(id)!;
    }

    public bool RemoveCustomTitle(string id)
    {
        var removed = false;
        Update(s =>
        {
            var kept = s.CustomTitles.Where(t => !string.Equals(t.Id, id, StringComparison.OrdinalIgnoreCase)).ToList();
            removed = kept.Count != s.CustomTitles.Count;
            return s with
            {
                CustomTitles = kept,
                ExposedIds = s.ExposedIds.Where(e => !string.Equals(e, id, StringComparison.OrdinalIgnoreCase)).ToList(),
            };
        });
        return removed;
    }

    public bool MarkPlayed(string id)
    {
        Update(s => s with
        {
            LastLaunched = new Dictionary<string, DateTimeOffset>(s.LastLaunched, StringComparer.OrdinalIgnoreCase)
            {
                [id] = DateTimeOffset.UtcNow,
            },
        });
        return true;
    }

    // ---- Launch resolution ------------------------------------------------

    /// <summary>
    /// Resolves a title to the process to start. <paramref name="vr"/> picks the title's VR launch
    /// entry (and its optimised profile); false picks Steam's desktop entry, falling back to the VR
    /// one for a VR-only title as Steam's Play button does. <paramref name="exposedOnly"/> is the
    /// headset's bound: only exposed, VR-capable titles. Throws <see cref="LaunchRefusedException"/>
    /// with a message for the user.
    /// </summary>
    public LaunchPlan ResolveLaunch(string titleId, bool vr, bool exposedOnly)
    {
        var title = (exposedOnly ? ListAllTitles().Where(t => t.Exposed && t.Kind.CanRunInVr()) : ListAllTitles())
            .FirstOrDefault(t => string.Equals(t.Id, titleId, StringComparison.OrdinalIgnoreCase));
        if (title is null)
        {
            _log?.LogWarning("Launch refused for {Id} (unknown{Scope}).", titleId, exposedOnly ? " or not exposed" : "");
            throw new LaunchRefusedException(exposedOnly
                ? "That game is not available to the headset."
                : "That game is no longer in the library.");
        }

        if (title.SteamAppId is uint appId) return ResolveSteam(title, appId, vr);

        if (string.IsNullOrWhiteSpace(title.Executable) || !File.Exists(title.Executable))
            throw new LaunchRefusedException($"{title.Name}: {title.Executable} no longer exists.");
        return new LaunchPlan
        {
            TitleId = title.Id, Name = title.Name, Executable = title.Executable!,
            Arguments = title.Arguments,
            WorkingDirectory = Path.GetDirectoryName(title.Executable!)!,
            // A file from a Steam game's folder runs as is, but as that Steam app, so its DRM
            // does not quit and relaunch it through Steam. No profile: profiles target the entry.
            SteamAppId = title.LinkedSteamAppId,
            VrEntry = vr && title.Kind.CanRunInVr(),
        };
    }

    private LaunchPlan ResolveSteam(GameTitle title, uint appId, bool vr)
    {
        var steamRoot = _steamRoot();
        var appInfoPath = steamRoot is null ? null : Path.Combine(steamRoot, "appcache", "appinfo.vdf");
        if (appInfoPath is null || !File.Exists(appInfoPath))
            throw new LaunchRefusedException("Steam's app cache (appinfo.vdf) was not found, so Longwave cannot start Steam games directly.");

        IReadOnlyList<SteamAppInfo.LaunchEntry> entries;
        try { entries = SteamAppInfo.ReadLaunchEntries(appInfoPath, appId); }
        catch (Exception ex)
        {
            _log?.LogError(ex, "Could not read Steam launch metadata for {Id}.", title.Id);
            throw new LaunchRefusedException($"Steam's launch information for {title.Name} could not be read.");
        }
        // A VR-only title (Steam's onlyvrsupport, or the user said so) has no desktop launch even
        // when its only entry is typed "default" — Half-Life: Alyx is exactly that.
        var desktop = vr || title.Kind == GameKind.Vr ? null : SteamAppInfo.SelectDesktopLaunchEntry(entries);
        if (!vr && desktop is null)
            _log?.LogInformation("{Id} has no desktop launch entry (VR-only); using its VR entry.", title.Id);
        var entry = desktop ?? SteamAppInfo.SelectPcvrLaunchEntry(entries);
        var vrEntry = desktop is null;
        if (entry is null)
            throw new LaunchRefusedException(
                $"Steam lists no Windows launch option for {title.Name} that Longwave can start directly. Start it from Steam.");

        var executable = ResolveInstallPath(title, entry.Executable, requireFile: true);
        var workingDirectory = string.IsNullOrWhiteSpace(entry.WorkingDirectory)
            ? Path.GetDirectoryName(executable)!
            : ResolveInstallPath(title, entry.WorkingDirectory, requireFile: false);
        if (!Directory.Exists(workingDirectory))
            throw new LaunchRefusedException($"{title.Name}'s working folder is missing: {workingDirectory}");

        var arguments = entry.Arguments;
        var profileApplied = false;
        if (vrEntry && title.Optimized && LaunchProfiles.ByAppId.TryGetValue(appId, out var profile))
        {
            executable = ResolveInstallPath(title, profile.ExecutableRelativePath, requireFile: true);
            arguments = JoinArguments(arguments, profile.AdditionalArguments);
            profileApplied = true;
        }
        _log?.LogInformation("Resolved {Mode} launch for {Id} from appinfo entry {Entry}{Profile}.",
            vrEntry ? "VR" : "desktop", title.Id, entry.Index, profileApplied ? " with its optimised profile" : "");
        return new LaunchPlan
        {
            TitleId = title.Id, Name = title.Name, Executable = executable, Arguments = arguments,
            WorkingDirectory = workingDirectory, SteamAppId = appId, VrEntry = vrEntry,
            ProfileApplied = profileApplied,
        };
    }

    private static string? JoinArguments(string? a, string? b)
    {
        var joined = string.Join(' ', new[] { a, b }.Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v!.Trim()));
        return joined.Length == 0 ? null : joined;
    }

    /// <summary>A path from Steam's metadata, resolved inside the title's install directory and
    /// refused if it escapes it.</summary>
    private static string ResolveInstallPath(GameTitle title, string relativePath, bool requireFile)
    {
        if (string.IsNullOrWhiteSpace(title.InstallDir))
            throw new LaunchRefusedException($"{title.Name} has no install folder.");
        string installDirectory, resolved;
        try
        {
            installDirectory = Path.GetFullPath(title.InstallDir);
            var rel = relativePath.Trim().Trim('"').Replace('\\', Path.DirectorySeparatorChar);
            resolved = Path.GetFullPath(Path.Combine(installDirectory, rel));
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new LaunchRefusedException($"{title.Name}'s launch path is invalid.");
        }
        if (!resolved.Equals(installDirectory, StringComparison.OrdinalIgnoreCase) && !IsInside(resolved, installDirectory))
            throw new LaunchRefusedException($"{title.Name}'s launch path points outside its install folder.");
        if (requireFile && !File.Exists(resolved))
            throw new LaunchRefusedException($"{title.Name}'s executable is missing ({resolved}). Verify the game's files in Steam.");
        return resolved;
    }

    /// <summary>
    /// Makes sure Steam is up before a Steam title starts: games still use it for ownership and
    /// the Steam API even though Steam is not their parent. Steam is started through
    /// <c>cmd /c start</c> so it is not a child of this process — the Companion tree-kills this
    /// backend on quit, and Steam must not go with it.
    /// </summary>
    public async Task<bool> EnsureSteamRunningAsync(CancellationToken ct = default)
    {
        if (Process.GetProcessesByName("steam").Length > 0) return true;
        var root = _steamRoot();
        var exe = root is null ? null : Path.Combine(root, "steam.exe");
        if (exe is null || !File.Exists(exe))
        {
            _log?.LogError("Steam is not running and steam.exe was not found.");
            return false;
        }
        _log?.LogInformation("Steam is not running; starting it first.");
        try
        {
            using var _ = Process.Start(new ProcessStartInfo("cmd.exe", $"/d /c start \"\" \"{exe}\" -silent")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = root!,
            });
        }
        catch (Exception ex)
        {
            _log?.LogError(ex, "Could not start Steam.");
            return false;
        }
        for (var i = 0; i < 60 && !ct.IsCancellationRequested; i++)
        {
            if (Process.GetProcessesByName("steam").Length > 0)
            {
                // Steam needs a moment past process start before Steamworks clients can connect.
                await Task.Delay(2000, ct).ConfigureAwait(false);
                return true;
            }
            await Task.Delay(500, ct).ConfigureAwait(false);
        }
        _log?.LogError("Steam did not start within 30 s.");
        return false;
    }

    // ---- Art --------------------------------------------------------------

    private const int MaxPortraitEdge = 450;
    private const int MaxLandscapeEdge = 460;

    /// <summary>
    /// Cover art bytes for one title, base64 in JSON. The headset has no filesystem access and no
    /// HTTP endpoint to fetch from, so art travels inline on the CloudXR data channel — hence
    /// per-title, lazy, and re-encoded smaller (Steam's 600x900 covers are ~40 KB; halving the
    /// dimensions is a quarter of the bytes for art drawn 148 pt wide). Any scaling failure sends
    /// the file as is: a large cover beats no cover. Bounded twice when <paramref name="exposedOnly"/>:
    /// by the exposed set, and by <see cref="SteamLibrary.IsAllowedArtPath"/>.
    /// </summary>
    public async Task<ArtResult> GetArtAsync(string titleId, string? orientation, bool exposedOnly,
                                             CancellationToken ct = default)
    {
        var source = exposedOnly ? ListExposedTitles() : ListAllTitles();
        var title = source.FirstOrDefault(t => string.Equals(t.Id, titleId, StringComparison.OrdinalIgnoreCase));
        if (title is null) return new ArtResult(titleId, null, null, "no such exposed title");

        var landscape = string.Equals(orientation, "landscape", StringComparison.OrdinalIgnoreCase);
        var path = landscape ? title.LandscapeArt : title.PortraitArt;
        if (string.IsNullOrEmpty(path)) return new ArtResult(titleId, null, null, "no art for this title");
        if (!SteamLibrary.IsAllowedArtPath(path, _steamRoot()))
        {
            _log?.LogWarning("Refusing art outside the Steam cache for {Id}.", titleId);
            return new ArtResult(titleId, null, null, "art path not allowed");
        }
        try
        {
            var bytes = await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false);
            var scaled = ArtScaler.TryScale(bytes, landscape ? MaxLandscapeEdge : MaxPortraitEdge, _log);
            var mime = scaled is not null || !Path.GetExtension(path).Equals(".png", StringComparison.OrdinalIgnoreCase)
                ? "image/jpeg" : "image/png";
            return new ArtResult(titleId, mime, Convert.ToBase64String(scaled ?? bytes), null);
        }
        catch (Exception ex)
        {
            _log?.LogWarning(ex, "Could not read art for {Id}", titleId);
            return new ArtResult(titleId, null, null, "could not read the art file");
        }
    }
}
