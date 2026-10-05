using System.Text;
using ValveKeyValue;

namespace Longwave.WindowsCompanion.Backend.Tests;

/// <summary>
/// A throwaway Steam install on disk: libraryfolders.vdf, appmanifests, game folders, and a binary
/// appinfo.vdf (version 40 layout, no string table) with the launch entries a test asks for.
/// </summary>
internal sealed class SteamFixture : IDisposable
{
    public sealed record Entry(string Executable, string? Type = null, string? Description = null,
                               string? Arguments = null, string? OsList = "windows");

    public sealed record App(uint AppId, string Name, string InstallDir, Entry[] Entries,
                             bool OnlyVr = false, bool OpenVr = false, string[]? Files = null,
                             long SizeOnDisk = 0, long LastPlayed = 0);

    public string Root { get; }
    public string SecondLibrary { get; }

    public SteamFixture(params App[] apps)
    {
        Root = Path.Combine(Path.GetTempPath(), "lw-steam-" + Guid.NewGuid().ToString("N")[..8]);
        SecondLibrary = Root + "-lib2";
        Directory.CreateDirectory(Path.Combine(Root, "steamapps"));
        Directory.CreateDirectory(Path.Combine(Root, "appcache"));
        Directory.CreateDirectory(Path.Combine(SecondLibrary, "steamapps"));
        File.WriteAllText(Path.Combine(Root, "steamapps", "libraryfolders.vdf"),
            "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"" + Esc(Root) + "\"\n\t}\n"
            + "\t\"1\"\n\t{\n\t\t\"path\"\t\t\"" + Esc(SecondLibrary) + "\"\n\t\t\"apps\"\n\t\t{\n\t\t}\n\t}\n}\n");

        // Odd app ids live in the second library, to cover multi-library discovery.
        foreach (var app in apps)
        {
            var library = app.AppId % 2 == 1 ? SecondLibrary : Root;
            File.WriteAllText(Path.Combine(library, "steamapps", $"appmanifest_{app.AppId}.acf"),
                "\"AppState\"\n{\n"
                + $"\t\"appid\"\t\t\"{app.AppId}\"\n\t\"name\"\t\t\"{app.Name}\"\n"
                + $"\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"{app.InstallDir}\"\n"
                + $"\t\"SizeOnDisk\"\t\t\"{app.SizeOnDisk}\"\n\t\"LastPlayed\"\t\t\"{app.LastPlayed}\"\n}}\n");
            var dir = Path.Combine(library, "steamapps", "common", app.InstallDir);
            Directory.CreateDirectory(dir);
            foreach (var file in (app.Files ?? Array.Empty<string>()).Concat(app.Entries.Select(e => e.Executable)))
            {
                var full = Path.Combine(dir, file.Replace('\\', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(full)!);
                File.WriteAllText(full, "");
            }
        }
        WriteAppInfo(Path.Combine(Root, "appcache", "appinfo.vdf"), apps);
    }

    public string InstallDirOf(App app) =>
        Path.Combine(app.AppId % 2 == 1 ? SecondLibrary : Root, "steamapps", "common", app.InstallDir);

    private static string Esc(string s) => s.Replace("\\", "\\\\");

    private static void WriteAppInfo(string path, App[] apps)
    {
        using var file = File.Create(path);
        using var w = new BinaryWriter(file, Encoding.UTF8);
        w.Write(0x07564428u); // magic, version 40
        w.Write(1u);          // universe
        var serializer = KVSerializer.Create(KVSerializationFormat.KeyValues1Binary);
        foreach (var app in apps)
        {
            var launch = app.Entries.Select((e, i) =>
            {
                var items = new List<KVObject> { new("executable", e.Executable) };
                if (e.Type is not null) items.Add(new KVObject("type", e.Type));
                if (e.Description is not null) items.Add(new KVObject("description", e.Description));
                if (e.Arguments is not null) items.Add(new KVObject("arguments", e.Arguments));
                if (e.OsList is not null) items.Add(new KVObject("config", new[] { new KVObject("oslist", e.OsList) }));
                return new KVObject(i.ToString(), items);
            }).ToList();
            var common = new List<KVObject> { new("name", app.Name), new("clienticon", "abc123") };
            if (app.OnlyVr) common.Add(new KVObject("onlyvrsupport", "1"));
            if (app.OpenVr) common.Add(new KVObject("openvrsupport", "1"));
            var root = new KVObject("appinfo", new[]
            {
                new KVObject("appid", app.AppId.ToString()),
                new KVObject("common", common),
                new KVObject("config", new[] { new KVObject("launch", launch) }),
            });
            using var kv = new MemoryStream();
            serializer.Serialize(kv, root);
            var body = kv.ToArray();

            w.Write(app.AppId);
            w.Write((uint)(4 + 4 + 8 + 20 + 4 + 20 + body.Length));
            w.Write(2u);              // info state
            w.Write(0u);              // last updated
            w.Write(0ul);             // PICS token
            w.Write(new byte[20]);    // sha1
            w.Write(1u);              // change number
            w.Write(new byte[20]);    // binary sha1 (v40)
            w.Write(body);
        }
        w.Write(0u);
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, true); } catch { }
        try { Directory.Delete(SecondLibrary, true); } catch { }
    }
}
