using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend;

/// <summary>
/// Polls the tethering controller on a fixed cadence so state changes, client-count changes,
/// and idle-disable auto-restart are observed even when the client isn't actively polling.
/// </summary>
public sealed class MonitorService : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(2);

    private readonly ILogger<MonitorService> _log;
    private readonly ITetheringService _controller;

    public MonitorService(ILogger<MonitorService> log, ITetheringService controller)
    {
        _log = log;
        _controller = controller;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false))
        {
            try { await _controller.PollAsync().ConfigureAwait(false); }
            catch (Exception ex) { _log.LogWarning(ex, "Monitor poll failed"); }
        }
    }
}
