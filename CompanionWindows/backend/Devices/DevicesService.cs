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
    /// <summary>Paired Quests' controller streams, handed to the broker's tracker hub.</summary>
    public QuestControllers Quests { get; }

    /// <summary>The last pairing's outcome, for the window.</summary>
    public string? LastStatus { get; private set; }
    public event Action? Changed;
    /// <summary>A Quest connected or went quiet.</summary>
    public event Action? QuestsChanged;

    public DevicesService(ILogger<DevicesService> log, DeviceRegistry registry)
    {
        _log = log;
        Registry = registry;
        Pairing = new PairingService(log, registry, () => Environment.MachineName);
        _advertiser = new DnsSdAdvertiser(log, registry);
        Pairing.Requested += _ => Changed?.Invoke();
        Pairing.Status += status => { LastStatus = status; Changed?.Invoke(); };
        Quests = new QuestControllers(log, () => registry.Devices
            .Where(d => d.Grants.Contains(Grant.Controllers))
            .Select(d => registry.Lookup(d.Id) is { } found
                ? new QuestControllers.Credential(d.Id, d.Name, found.Token)
                : null)
            .OfType<QuestControllers.Credential>()
            .ToList());
        Quests.Seen += registry.NoteSeen;
        Quests.Changed += () => QuestsChanged?.Invoke();
        registry.Changed += () =>
        {
            Quests.Reload();
            Changed?.Invoke();
        };
    }

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try { Pairing.Start(); }
        catch (Exception ex) { _log.LogError(ex, "Couldn't open the pairing port"); }
        try { _advertiser.Start(); }
        catch (Exception ex) { _log.LogError(ex, "Couldn't announce this PC on the local network"); }
        try { Quests.Start(); }
        catch (Exception ex) { _log.LogError(ex, "Couldn't open the Quest controller port {Port}", Grant.ControllerPort); }
        stoppingToken.Register(() =>
        {
            Quests.Dispose();
            Pairing.Dispose();
            _advertiser.Dispose();
        });
        return Task.CompletedTask;
    }
}
