using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Longwave.WindowsCompanion.Backend;
using Longwave.WindowsCompanion.Backend.NativeStream;

// Native streaming maps stream pixels straight onto screen coordinates —
// per-monitor-v2 awareness keeps every win32 rect/metric in physical pixels.
[DllImport("user32.dll")]
static extern bool SetProcessDpiAwarenessContext(IntPtr context);
SetProcessDpiAwarenessContext(new IntPtr(-4)); // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2

// One binary, two deployment shapes (the spike left the Session-0 question open, so we keep
// both): a Windows Service (control plane) OR an elevated interactive-session helper (the
// PoC default, side-stepping the documented Session-0 tethering risk). AddWindowsService()
// auto-detects which the SCM launched us as.

// --probe : print capability + status and exit (used by the installer / troubleshooting).
if (args.Contains("--probe"))
{
    using var lf = LoggerFactory.Create(b => b.AddSimpleConsole());
    var controller = new TetheringController(lf.CreateLogger<TetheringController>());
    Console.WriteLine("Upstream profiles:");
    foreach (var p in controller.ListUpstreamProfiles())
        Console.WriteLine($"  - {p.Name,-28} kind={p.Kind,-9} internet={p.HasInternet} default={p.IsDefault} cap={p.TetheringCapability}");
    var status = await controller.GetStatusAsync();
    Console.WriteLine($"State={status.State}  canHostAp={status.CanHostAp}");
    Console.WriteLine($"Capability: {status.CapabilityDetail}");
    return status.CanHostAp ? 0 : 1;
}

// --tether-host [--parent-pid=N] : the elevated tethering helper. Spawned by an unelevated
// backend through ShellExecute "runas" when the user turns the hotspot on, so that the Mobile
// Hotspot API — the one feature here that genuinely needs administrator rights — gets them
// without elevating the PCVR path with it. See TetheringElevation.cs for why this is a resident
// child rather than one-shot elevation, and why the PCVR path must stay unelevated.
//
// Deliberately ahead of the single-instance mutex: this is a second process of the same image and
// must not be mistaken for a competing backend.
if (args.Contains(TetherElevation.HostRoleArg))
{
    using var lf = LoggerFactory.Create(b => b.AddSimpleConsole(o => o.SingleLine = true));
    int parentPid = 0;
    foreach (var a in args)
        if (a.StartsWith("--parent-pid=", StringComparison.Ordinal))
            _ = int.TryParse(a["--parent-pid=".Length..], out parentPid);

    var hostController = new TetheringController(lf.CreateLogger<TetheringController>());
    var tetherHost = new TetherHost(lf.CreateLogger<TetherHost>(), hostController, parentPid);
    return await tetherHost.RunAsync();
}

// Exactly one backend may own the machine-wide resources below (the RPC pipe, NvStreamManager,
// the mDNS advertisement). Nothing enforces that for us: NamedPipeServerStream lets a *second*
// process create further instances of the same pipe name, so two backends do not conflict
// loudly — they silently split clients between two independent hosts, each with its own
// NvStreamManager. That happened by running the UI task (which spawns its own backend) next to
// the standalone backend task. Fail fast and visibly instead.
using var singleInstance = new Mutex(initiallyOwned: true, @"Global\LongwaveCompanionBackend", out bool isOnlyInstance);
if (!isOnlyInstance)
{
    Console.Error.WriteLine(
        "Another Longwave companion backend is already running (it owns the RPC pipe and CloudXR). " +
        "Run either the Electron UI (which spawns its own backend) or the standalone backend — not both.");
    return 2;
}

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(o => o.ServiceName = "LongwaveCompanion");
builder.Services.AddSingleton<TetheringController>();
// Tethering is the only administrator-gated feature, so it is the only thing that elevates, and
// only when used. Already elevated (a Windows service, or the user started us elevated anyway)?
// Own the access point in-process. Otherwise hand out a proxy that answers status locally and
// forwards the three privileged operations to an elevated child.
builder.Services.AddSingleton<ITetheringService>(sp =>
{
    var local = sp.GetRequiredService<TetheringController>();
    if (TetherElevation.IsElevated) return local;
    var lf = sp.GetRequiredService<ILoggerFactory>();
    return new ElevatedTetheringProxy(lf.CreateLogger<ElevatedTetheringProxy>(), local);
});
builder.Services.AddSingleton<NativeStreamingService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<NativeStreamingService>());
builder.Services.AddHostedService<MonitorService>();
builder.Services.AddHostedService<PipeServer>();

builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
if (OperatingSystem.IsWindows())
    builder.Logging.AddEventLog(o => o.SourceName = "LongwaveCompanion");

var host = builder.Build();
await host.RunAsync();
return 0;
