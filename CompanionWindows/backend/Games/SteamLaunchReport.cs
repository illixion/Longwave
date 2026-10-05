namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>
/// <c>LongwaveCompanionBackend.exe --steam-launches [appid]</c>: prints, for each installed Steam
/// title (or one app), its detected kind and the VR and desktop entries a launch would use, without
/// starting anything. Moved here from the PCVR host with the library.
/// </summary>
public static class SteamLaunchReport
{
    public static int Run(uint? onlyAppId)
    {
        var root = SteamLibrary.FindSteamRoot();
        var path = root is null ? null : Path.Combine(root, "appcache", "appinfo.vdf");
        if (path is null || !File.Exists(path))
        {
            Console.Error.WriteLine("Steam appcache/appinfo.vdf was not found.");
            return 1;
        }
        var ids = onlyAppId is uint one
            ? new HashSet<uint> { one }
            : SteamLibrary.DiscoverInstalledApps(root).Select(a => a.AppId).ToHashSet();

        IReadOnlyDictionary<uint, SteamAppInfo.AppInfo> apps;
        try { apps = SteamAppInfo.ReadApps(path, ids); }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"appinfo.vdf: {ex.Message}");
            return 1;
        }

        var failures = 0;
        foreach (var appId in ids.OrderBy(i => i))
        {
            apps.TryGetValue(appId, out var app);
            var entries = app?.Entries ?? Array.Empty<SteamAppInfo.LaunchEntry>();
            var vr = SteamAppInfo.SelectPcvrLaunchEntry(entries);
            var desktop = SteamAppInfo.SelectDesktopLaunchEntry(entries);
            Console.WriteLine($"{appId}: kind={SteamAppInfo.DetectKind(app).Name()}"
                + $" vr=[{vr?.Index.ToString() ?? "-"}] desktop=[{desktop?.Index.ToString() ?? "-"}]"
                + (app is null ? " (not in appinfo.vdf)" : ""));
            foreach (var e in entries)
                Console.WriteLine($"  [{e.Index}] type={e.Type ?? "-"} os={e.OsList ?? "*"} {e.Executable}"
                    + (string.IsNullOrWhiteSpace(e.Arguments) ? "" : $" {e.Arguments}")
                    + (string.IsNullOrWhiteSpace(e.Description) ? "" : $"  \"{e.Description}\""));
            if (vr is null && desktop is null) failures++;
        }
        // A full listing includes tools with URI-only entries; that is information, not a failed
        // diagnostic. A specifically requested app must resolve.
        return onlyAppId is not null && failures > 0 ? 1 : 0;
    }
}
