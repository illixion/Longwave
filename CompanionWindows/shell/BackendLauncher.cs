using System.Diagnostics;

namespace Longwave.Companion.Shell;

/// <summary>
/// Starts the backend as an interactive-session helper, mirroring what the Electron
/// main process did. If a service already owns the pipe, the spawned child fails to
/// bind and exits — we simply talk to whichever instance holds it.
/// </summary>
internal static class BackendLauncher
{
    private const string ExeName = "LongwaveWindowsCompanionBackend.exe";
    private const string Tfm = "net8.0-windows10.0.22621.0";

    private static Process? _process;

    public static string? Resolve()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            // Packaged: installer drops the published backend beside the shell.
            Path.Combine(baseDir, "backend", ExeName),
            // Dev tree: CompanionWindows/shell/bin/<cfg>/<tfm>/ → ../../../../backend/…
            Path.Combine(baseDir, "..", "..", "..", "..", "backend", "bin", "Release", Tfm, "publish", ExeName),
            Path.Combine(baseDir, "..", "..", "..", "..", "backend", "bin", "Release", Tfm, ExeName),
            Path.Combine(baseDir, "..", "..", "..", "..", "backend", "bin", "Debug", Tfm, ExeName),
        };

        foreach (var candidate in candidates)
        {
            var full = Path.GetFullPath(candidate);
            if (File.Exists(full)) return full;
        }
        return null;
    }

    public static void Start()
    {
        if (Environment.GetEnvironmentVariable("LONGWAVE_NO_SPAWN") == "1") return;

        var exe = Resolve();
        if (exe is null)
        {
            Debug.WriteLine("[shell] backend exe not found; expecting an externally-run backend/service.");
            return;
        }

        try
        {
            _process = Process.Start(new ProcessStartInfo(exe)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(exe)!,
            });
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[shell] backend spawn error: {ex.Message}");
        }
    }

    /// <summary>Tear down only a backend we spawned; leave a service-hosted one running.</summary>
    public static void Stop()
    {
        if (_process is null || _process.HasExited) return;
        try { _process.Kill(entireProcessTree: true); } catch { /* ignore */ }
    }
}
