using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>
/// Pairing for this PC: the direct pairing port and the DNS-SD announcement
/// that lets headsets list it nearby. Runs whether or not screen streaming is
/// switched on, so a device can pair first and stream once it is.
/// </summary>
public sealed class DevicesService : BackgroundService
{
    private readonly ILogger<DevicesService> _log;
    public DeviceRegistry Registry { get; }
    public PairingService Pairing { get; }
    private readonly DnsSdAdvertiser _advertiser;

    /// <summary>The last pairing's outcome, for the window.</summary>
    public string? LastStatus { get; private set; }
    public event Action? Changed;

    public DevicesService(ILogger<DevicesService> log, DeviceRegistry registry)
    {
        _log = log;
        Registry = registry;
        Pairing = new PairingService(log, registry, () => Environment.MachineName);
        _advertiser = new DnsSdAdvertiser(log, registry);
        Pairing.Requested += _ => Changed?.Invoke();
        Pairing.Status += status => { LastStatus = status; Changed?.Invoke(); };
        registry.Changed += () => Changed?.Invoke();
    }

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { Pairing.Start(); }
        catch (Exception ex) { _log.LogError(ex, "Couldn't open the pairing port"); }
        try { _advertiser.Start(); }
        catch (Exception ex) { _log.LogError(ex, "Couldn't announce this PC on the local network"); }
        stoppingToken.Register(() =>
        {
            Pairing.Dispose();
            _advertiser.Dispose();
        });
        return Task.CompletedTask;
    }
}
