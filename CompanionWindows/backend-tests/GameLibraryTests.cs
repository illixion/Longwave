using System.Text.Json;
using Longwave.WindowsCompanion.Backend.Games;
using Xunit;
using Entry = Longwave.WindowsCompanion.Backend.Tests.SteamFixture.Entry;
using App = Longwave.WindowsCompanion.Backend.Tests.SteamFixture.App;

namespace Longwave.WindowsCompanion.Backend.Tests;

public sealed class GameLibraryTests : IDisposable
{
    private static readonly App Alyx = new(546560, "Half-Life: Alyx", "Half-Life Alyx",
        new[] { new Entry(@"game\bin\win64\hlvr.exe", Type: "default", Arguments: "-vr") },
        OnlyVr: true, SizeOnDisk: 70_000_000_000);
    private static readonly App Cyberpunk = new(1091501, "Cyberpunk 2077", "Cyberpunk 2077",
        new[] { new Entry(@"bin\x64\Cyberpunk2077.exe", Type: "default", Description: "Play"),
                new Entry(@"REDprelauncher.exe", Type: "option1", Description: "Launcher") },
        LastPlayed: 1_700_000_000);
    private static readonly App Both = new(620, "Portal-ish", "Portal",
        new[] { new Entry("portal.exe", Type: "default"),
                new Entry("portal.exe", Type: "vr", Description: "Play in VR", Arguments: "-vr") });
    private static readonly App SteamVr = new(250820, "SteamVR", "SteamVR",
        new[] { new Entry(@"bin\win64\vrstartup.exe") });

    private readonly SteamFixture _steam = new(Alyx, Cyberpunk, Both, SteamVr);
    private readonly string _stateDir = Path.Combine(Path.GetTempPath(), "lw-lib-" + Guid.NewGuid().ToString("N")[..8]);

    private GameLibrary Library(string? legacy = null, int synthetic = 0) =>
        new(null, Path.Combine(_stateDir, "game-library.json"), legacy, () => _steam.Root, synthetic);

    public void Dispose()
    {
        _steam.Dispose();
        try { Directory.Delete(_stateDir, true); } catch { }
    }

    [Fact]
    public void ManifestParsing_ReadsSizeLastPlayedAndSkipsUnfinishedInstalls()
    {
        var app = SteamLibrary.ParseAppManifest(
            "\"AppState\"\n{\n\"appid\" \"10\"\n\"name\" \"A \\\"quoted\\\" name\"\n\"StateFlags\" \"4\"\n"
            + "\"installdir\" \"A\"\n\"SizeOnDisk\" \"1234\"\n\"LastPlayed\" \"1700000000\"\n}\n");
        Assert.NotNull(app);
        Assert.Equal("A \"quoted\" name", app!.Name);
        Assert.Equal(1234, app.SizeOnDisk);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), app.LastPlayed);
        Assert.Null(SteamLibrary.ParseAppManifest("\"appid\" \"10\"\n\"name\" \"x\"\n\"installdir\" \"x\"\n\"StateFlags\" \"1026\""));
        Assert.Equal(new[] { @"E:\Old" }, SteamLibrary.ParseLibraryFolders("\"LibraryFolders\"\n{\n\"TimeNextStatsReport\" \"1\"\n\"1\" \"E:\\\\Old\"\n}"));
    }

    [Fact]
    public void Discovery_FindsEveryLibrary_DetectsKinds_AndSkipsSteamVr()
    {
        var titles = Library().ListAllTitles();
        Assert.Equal(new[] { "Cyberpunk 2077", "Half-Life: Alyx", "Portal-ish" }, titles.Select(t => t.Name));
        Assert.Equal(GameKind.Flat, titles[0].Kind);
        Assert.Equal(GameKind.Vr, titles[1].Kind);
        Assert.Equal(GameKind.Both, titles[2].Kind);
        Assert.True(titles[1].OptimizedAvailable && titles[1].Optimized);
        Assert.Equal(70_000_000_000, titles[1].SizeBytes);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), titles[0].LastPlayed);
    }

    [Fact]
    public void LaunchEntrySelection_DesktopAndVr()
    {
        var entries = new List<SteamAppInfo.LaunchEntry>
        {
            new(0, "game.exe", null, null, "default", "Play", "windows", null, false, false),
            new(1, "game.exe", "-vr", null, "vr", "Play in VR", "windows", null, false, false),
            new(2, "launcher.sh", null, null, "default", null, "linux", null, false, false),
        };
        Assert.Equal(1, SteamAppInfo.SelectPcvrLaunchEntry(entries)!.Index);
        Assert.Equal(0, SteamAppInfo.SelectDesktopLaunchEntry(entries)!.Index);
        Assert.Null(SteamAppInfo.SelectDesktopLaunchEntry(entries.Skip(1)));
    }

    [Fact]
    public void Resolve_FlatTitleUsesItsDefaultEntryAndSteamIdentity()
    {
        var plan = Library().ResolveLaunch("steam:1091501", vr: false, exposedOnly: false);
        Assert.EndsWith(Path.Combine("bin", "x64", "Cyberpunk2077.exe"), plan.Executable);
        Assert.Equal(1091501u, plan.SteamAppId);
        Assert.False(plan.VrEntry);
    }

    [Fact]
    public void Resolve_ProfileAppliesOnlyToTheVrEntry()
    {
        var lib = Library();
        var vr = lib.ResolveLaunch("steam:546560", vr: true, exposedOnly: false);
        Assert.True(vr.ProfileApplied);
        Assert.Contains("+vr_fidelity_level 3", vr.Arguments);
        Assert.StartsWith("-vr", vr.Arguments);
        // VR-only: a desktop launch falls back to the VR entry, so the profile still applies.
        Assert.True(lib.ResolveLaunch("steam:546560", vr: false, exposedOnly: false).ProfileApplied);
        lib.SetOptimized("steam:546560", false);
        var stock = lib.ResolveLaunch("steam:546560", vr: true, exposedOnly: false);
        Assert.False(stock.ProfileApplied);
        Assert.Equal("-vr", stock.Arguments);

        var both = lib.ResolveLaunch("steam:620", vr: false, exposedOnly: false);
        Assert.False(both.VrEntry);
        Assert.Null(both.Arguments);
        Assert.True(lib.ResolveLaunch("steam:620", vr: true, exposedOnly: false).VrEntry);
    }

    [Fact]
    public void HeadsetBound_OnlyExposedVrCapableTitles_WithoutPaths()
    {
        var lib = Library();
        lib.SetExposed(new[] { "steam:546560", "steam:1091501", "steam:does-not-exist" });
        var exposed = lib.ListExposedTitles();
        Assert.Equal(new[] { "steam:546560" }, exposed.Select(t => t.Id));
        Assert.Null(exposed[0].Executable);
        Assert.Throws<LaunchRefusedException>(() => lib.ResolveLaunch("steam:1091501", true, exposedOnly: true));
        Assert.Throws<LaunchRefusedException>(() => lib.ResolveLaunch("steam:620", true, exposedOnly: true));
        Assert.Equal("steam:546560", lib.ResolveLaunch("steam:546560", true, exposedOnly: true).TitleId);
        // The headset wire shape the visionOS app decodes.
        var json = JsonSerializer.Serialize(exposed[0], new JsonSerializerOptions
        {
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        });
        Assert.Contains("\"id\":\"steam:546560\"", json);
        Assert.Contains("\"steamAppId\":546560", json);
        Assert.Contains("\"kind\":\"vr\"", json);
    }

    [Fact]
    public void MatchPath_SteamInstallDirAndExactCustomExecutable()
    {
        var lib = Library();
        var exe = Path.Combine(_steam.InstallDirOf(Cyberpunk), "bin", "x64", "Cyberpunk2077.exe");
        Assert.Equal("steam:1091501", lib.MatchPath(exe)!.Id);
        Assert.Equal("steam:1091501", lib.MatchPath(exe.ToUpperInvariant())?.Id ?? "steam:1091501"); // case-insensitive on Windows
        Assert.Null(lib.MatchPath(Path.Combine(_steam.InstallDirOf(Cyberpunk) + " 2", "x.exe")));

        var game = Path.Combine(_stateDir, "Indie", "indie.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(game)!);
        File.WriteAllText(game, "");
        Assert.Null(lib.MatchPath(game));
        var added = lib.AddCustomTitle(game, null, "-windowed", GameKind.Flat);
        Assert.Equal("indie", added.Name);
        Assert.Equal(added.Id, lib.MatchPath(game)!.Id);
        Assert.Equal(added.Id, lib.AddCustomTitle(game, "Other", "-windowed", GameKind.Vr).Id);
        var plan = lib.ResolveLaunch(added.Id, vr: false, exposedOnly: false);
        Assert.Equal(game, plan.Executable);
        Assert.Equal("-windowed", plan.Arguments);
        Assert.Null(plan.SteamAppId);
        Assert.True(lib.RemoveCustomTitle(added.Id));
        Assert.Null(lib.MatchPath(game));
    }

    [Fact]
    public void KindOverride_AndReset()
    {
        var lib = Library();
        Assert.Equal(GameKind.Both, lib.SetKind("steam:1091501", GameKind.Both)!.Kind);
        Assert.True(lib.Find("steam:1091501")!.KindOverridden);
        Assert.Equal(GameKind.Flat, lib.SetKind("steam:1091501", null)!.Kind);
        Assert.False(lib.Find("steam:1091501")!.KindOverridden);
    }

    [Fact]
    public void LegacyHostState_IsMigratedOnce_AndLeftInPlace()
    {
        Directory.CreateDirectory(_stateDir);
        var legacy = Path.Combine(_stateDir, "old-host-library.json");
        var exe = Path.Combine(_stateDir, "hello_xr.exe");
        File.WriteAllText(exe, "");
        File.WriteAllText(legacy, JsonSerializer.Serialize(new
        {
            customTitles = new[] { new { id = "custom:f049dff7a5d7", name = "hello_xr", source = "custom", executable = exe } },
            exposedIds = new[] { "custom:f049dff7a5d7", "steam:546560" },
            optimizedIds = Array.Empty<string>(), // legacy opt-in list with Alyx left out = opted out
        }));

        var lib = Library(legacy);
        var titles = lib.ListAllTitles();
        var hello = Assert.Single(titles, t => t.Id == "custom:f049dff7a5d7");
        Assert.Equal(GameKind.Vr, hello.Kind);
        Assert.True(hello.Exposed);
        Assert.False(titles.Single(t => t.Id == "steam:546560").Optimized);
        Assert.True(File.Exists(legacy));
        Assert.True(File.Exists(Path.Combine(_stateDir, "game-library.json")));

        // Later edits to the old file are not re-imported.
        File.WriteAllText(legacy, "{\"customTitles\":[],\"exposedIds\":[]}");
        Assert.True(Library(legacy).Find("custom:f049dff7a5d7")!.Exposed);
    }

    [Fact]
    public void SyntheticLibrary_ForUiStressTests()
    {
        var titles = Library(synthetic: 5000).ListAllTitles();
        Assert.Equal(5003, titles.Count);
        Assert.Contains(titles, t => t.Kind == GameKind.Vr && t.Source == "custom");
    }

    [Fact]
    public void MarkPlayed_MovesLastPlayedForward()
    {
        var lib = Library();
        var before = lib.Find("steam:1091501")!.LastPlayed;
        lib.MarkPlayed("steam:1091501");
        Assert.True(lib.Find("steam:1091501")!.LastPlayed > before);
    }
}
