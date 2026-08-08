using System.Runtime.InteropServices;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using VisionVNC.Hotspot.Backend;
using VisionVNC.Hotspot.Backend.NativeStream;

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

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddWindowsService(o => o.ServiceName = "VisionVNCHotspot");
builder.Services.AddSingleton<TetheringController>();
builder.Services.AddSingleton<NativeStreamingService>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<NativeStreamingService>());
builder.Services.AddHostedService<MonitorService>();
builder.Services.AddHostedService<PipeServer>();

builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
if (OperatingSystem.IsWindows())
    builder.Logging.AddEventLog(o => o.SourceName = "VisionVNCHotspot");

var host = builder.Build();
await host.RunAsync();
return 0;
