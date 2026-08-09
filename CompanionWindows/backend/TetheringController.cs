using System.Diagnostics;
using System.Net.NetworkInformation;
using Microsoft.Extensions.Logging;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

namespace Longwave.WindowsCompanion.Backend;

/// <summary>
/// Wraps the Windows Mobile Hotspot API (<see cref="NetworkOperatorTetheringManager"/>):
/// enumerate upstreams, configure/start/stop the AP, report live state + client count,
/// and auto-restart if Windows idle-disables the hotspot. All public methods are safe to
/// call from any thread; operations are serialized with an async gate.
///
/// <para>Elevation: the queries here work unelevated, but <see cref="StartAsync"/>,
/// <see cref="StopAsync"/> and <see cref="PrepareApAdapterAsync"/> need administrator rights. An
/// unelevated backend therefore reaches this class through <see cref="ElevatedTetheringProxy"/>,
/// which runs it inside an elevated child; see TetheringElevation.cs.</para>
/// </summary>
public sealed class TetheringController : ITetheringService
{
    private readonly ILogger<TetheringController> _log;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private NetworkOperatorTetheringManager? _manager;
    private string? _activeProfileId;

    // Desired/displayed config (what the user asked for; survives an idle-disable).
    private bool _desiredOn;
    private string? _ssid;
    private string? _passphrase;
    private string _band = "auto";

    // Auto-restart throttling.
    private DateTime _lastRestartAttemptUtc = DateTime.MinValue;
    private int _consecutiveRestartFailures;

    // Cached SoftAP capability probe (cheap to re-run, but stable for a session).
    private (bool canHost, string detail)? _softApProbe;

    // Wi-Fi adapters we disabled to free the AP for a capable radio; re-enabled on Stop.
    private readonly List<string> _disabledAdapters = new();

    private HotspotStatus _last = new();

    public TetheringController(ILogger<TetheringController> log) => _log = log;

    /// <summary>Raised (on the poll thread) when the observable status changes.</summary>
    public event Action<HotspotStatus>? StatusChanged;

    // -------------------------------------------------------------------------
    // Queries
    // -------------------------------------------------------------------------

    public IReadOnlyList<UpstreamProfile> ListUpstreamProfiles()
    {
        var result = new List<UpstreamProfile>();
        var internetProfile = NetworkInformation.GetInternetConnectionProfile();
        var internetId = AdapterId(internetProfile);

        foreach (var p in NetworkInformation.GetConnectionProfiles())
        {
            var level = p.GetNetworkConnectivityLevel();
            bool hasInternet = level == NetworkConnectivityLevel.InternetAccess;
            var id = AdapterId(p);
            string cap;
            try { cap = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(p).ToString(); }
            catch (Exception ex) { cap = "error:" + ex.GetType().Name; }

            result.Add(new UpstreamProfile
            {
                Id = id,
                Name = p.ProfileName ?? "(unnamed)",
                Kind = KindOf(p),
                HasInternet = hasInternet,
                IsDefault = id == internetId && internetId.Length > 0,
                TetheringCapability = Camel(cap),
            });
        }
        return result;
    }

    public async Task<HotspotStatus> GetStatusAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { return BuildStatus(); }
        finally { _gate.Release(); }
    }

    /// <summary>Enumerate the host's Wi-Fi adapters and whether each can host an AP.</summary>
    public IReadOnlyList<WifiAdapterInfo> ListWifiAdapters()
    {
        var caps = ProbePerAdapterCapability();           // name -> canHostAp
        var states = ProbeInterfaceStates();              // name -> (enabled, connected)
        var result = new List<WifiAdapterInfo>();
        foreach (var (name, canHost) in caps)
        {
            var st = states.TryGetValue(name, out var s) ? s : (enabled: true, connected: false);
            result.Add(new WifiAdapterInfo
            {
                Name = name, CanHostAp = canHost, Enabled = st.enabled, Connected = st.connected,
            });
        }
        return result;
    }

    /// <summary>
    /// Disable enabled Wi-Fi adapters that can't host an AP, but only when a capable one also
    /// exists — so Windows is forced to host on the capable radio. Disabled adapters are
    /// remembered and re-enabled on <see cref="StopAsync"/>. (The Mobile Hotspot API gives no way
    /// to pick the AP radio, so this is how we steer it on multi-adapter machines.)
    /// </summary>
    public async Task<PrepareApResult> PrepareApAdapterAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var caps = ProbePerAdapterCapability();
            var states = ProbeInterfaceStates();
            var enabledWifi = caps.Keys.Where(n => states.TryGetValue(n, out var s) ? s.enabled : true).ToList();
            bool capableExists = enabledWifi.Any(n => caps[n]);
            var incapable = enabledWifi.Where(n => !caps[n]).ToList();

            if (!capableExists)
                return new PrepareApResult { Ok = false, Detail = "No SoftAP/Wi-Fi-Direct-GO-capable Wi-Fi adapter is present to host the AP." };
            if (incapable.Count == 0)
                return new PrepareApResult { Ok = true, Detail = "No conflicting adapters; nothing to disable." };

            var disabled = new List<string>();
            foreach (var name in incapable)
            {
                _log.LogInformation("Disabling incapable Wi-Fi adapter '{Name}' so the AP uses a capable radio.", name);
                if (RunNetsh($"interface set interface name=\"{name}\" admin=disabled"))
                {
                    _disabledAdapters.Add(name);
                    disabled.Add(name);
                }
            }
            // Force a fresh manager next Start (the adapter set changed).
            _manager = null;
            return new PrepareApResult { Ok = disabled.Count > 0, Disabled = disabled,
                Detail = $"Disabled {disabled.Count} adapter(s): {string.Join(", ", disabled)}." };
        }
        finally { _gate.Release(); }
    }

    // -------------------------------------------------------------------------
    // Start / Stop
    // -------------------------------------------------------------------------

    public async Task<OperationResult> StartAsync(StartHotspotParams p)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var profile = ResolveProfile(p.ProfileId);
            if (profile is null)
                return Fail("noUpstream", "No shareable internet connection profile was found.");

            var capability = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(profile);
            if (capability != TetheringCapability.Enabled)
                return Fail(Camel(capability.ToString()),
                    $"Tethering is not available on '{profile.ProfileName}' ({capability}).");

            _manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            _activeProfileId = AdapterId(profile);

            // Can't reconfigure while running — stop first if already up.
            if (_manager.TetheringOperationalState == TetheringOperationalState.On)
            {
                _log.LogInformation("Hotspot already on; stopping before reconfigure.");
                try { await _manager.StopTetheringAsync(); } catch (Exception ex) { _log.LogWarning(ex, "Pre-stop failed"); }
            }

            _ssid = string.IsNullOrWhiteSpace(p.Ssid) ? Tokens.DefaultSsid() : p.Ssid!.Trim();
            _passphrase = string.IsNullOrWhiteSpace(p.Passphrase) ? Tokens.DefaultPassphrase() : p.Passphrase!.Trim();
            _band = NormalizeBand(p.Band);

            // Say so when the radio cannot honour the requested band. Windows accepts the
            // configuration either way and hosts on whatever the driver picks, so the alternative
            // is a user who believes they are on 5 GHz and is not.
            var supported = ProbeSupportedBands();
            if (_band != "auto" && supported is not null && !supported.Contains(_band))
                _log.LogWarning(
                    "{Band} GHz was requested, but this radio reports supported bands [{Supported}]. " +
                    "The request will be ignored and the AP will come up on whatever the driver chooses.",
                    _band, supported.Count == 0 ? "none" : string.Join(", ", supported));

            var cfg = new NetworkOperatorTetheringAccessPointConfiguration
            {
                Ssid = _ssid,
                Passphrase = _passphrase,
            };
            TrySetBand(cfg, _band);

            _log.LogInformation("Configuring AP SSID='{Ssid}' band={Band} upstream='{Up}'", _ssid, _band, profile.ProfileName);
            await _manager.ConfigureAccessPointAsync(cfg);

            // Cold-start flakiness: a Wi-Fi-Direct-GO radio that's been idle/torn-down often
            // reports WiFiDeviceOff on the first one or two attempts, then succeeds once warm
            // (observed: 2 failures then 3 successes on the TP-Link RTL8811AU). Retry a few
            // times before treating WiFiDeviceOff as a real "can't host" verdict.
            _log.LogInformation("Starting tethering...");
            NetworkOperatorTetheringOperationResult res = await _manager.StartTetheringAsync();
            for (int attempt = 1; res.Status == TetheringOperationStatus.WiFiDeviceOff && attempt <= 4; attempt++)
            {
                _log.LogWarning("StartTetheringAsync -> WiFiDeviceOff (cold radio); retry {Attempt}/4 after warm-up delay.", attempt);
                await Task.Delay(2500);
                res = await _manager.StartTetheringAsync();
            }
            _log.LogInformation("StartTetheringAsync -> {Status} '{Msg}'", res.Status, res.AdditionalErrorMessage);

            if (res.Status == TetheringOperationStatus.Success)
            {
                _desiredOn = true;
                _consecutiveRestartFailures = 0;
                return Ok("success", null);
            }

            // Map the most important failure: the adapter/driver can't host an AP.
            _desiredOn = false;
            if (res.Status == TetheringOperationStatus.WiFiDeviceOff)
            {
                // If an incapable Wi-Fi adapter is enabled alongside a capable one, Windows may be
                // hosting on the wrong radio — offer the guided disable fix.
                var caps = ProbePerAdapterCapability();
                var states = ProbeInterfaceStates();
                var enabledWifi = caps.Keys.Where(n => states.TryGetValue(n, out var s) ? s.enabled : true).ToList();
                bool fixable = enabledWifi.Any(n => !caps[n]) && enabledWifi.Any(n => caps[n]);
                var probe = ProbeSoftApSupport();
                return Fail(fixable ? "adapterConflict" : "adapterCannotHostAp",
                    "Windows could not start the access point (WiFiDeviceOff). " +
                    (fixable
                        ? "Another Wi-Fi adapter that can't host an AP is enabled and may be blocking it. " +
                          "Disable it and retry."
                        : "The Wi-Fi adapter/driver does not expose the SoftAP/Wi-Fi-Direct-GO function the " +
                          "Mobile Hotspot requires. " + probe.detail));
            }
            return Fail(Camel(res.Status.ToString()),
                string.IsNullOrEmpty(res.AdditionalErrorMessage) ? res.Status.ToString() : res.AdditionalErrorMessage);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "StartAsync threw");
            return Fail("exception", $"{ex.GetType().Name}: 0x{ex.HResult:X8} {ex.Message}");
        }
        finally { _gate.Release(); }
    }

    public async Task<OperationResult> StopAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            _desiredOn = false;
            EnsureManager(); // bind to an AP a previous process/run may have left running
            if (_manager is null || _manager.TetheringOperationalState == TetheringOperationalState.Off)
            {
                ReenableDisabledAdapters();
                return Ok("success", null);
            }

            var res = await _manager.StopTetheringAsync();
            _log.LogInformation("StopTetheringAsync -> {Status}", res.Status);
            ReenableDisabledAdapters();
            return res.Status == TetheringOperationStatus.Success
                ? Ok("success", null)
                : Fail(Camel(res.Status.ToString()), res.AdditionalErrorMessage);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "StopAsync threw");
            return Fail("exception", ex.Message);
        }
        finally { _gate.Release(); }
    }

    // -------------------------------------------------------------------------
    // Monitor — called periodically by MonitorService.
    // -------------------------------------------------------------------------

    /// <summary>Refresh state, emit StatusChanged on change, auto-restart if idle-disabled.</summary>
    public async Task PollAsync()
    {
        if (!await _gate.WaitAsync(0).ConfigureAwait(false))
            return; // a Start/Stop is in flight; skip this tick.
        try
        {
            // Auto-restart: we wanted it on, but Windows turned it off.
            if (_desiredOn && _manager is not null &&
                _manager.TetheringOperationalState == TetheringOperationalState.Off)
            {
                var sinceLast = DateTime.UtcNow - _lastRestartAttemptUtc;
                if (sinceLast > TimeSpan.FromSeconds(10) && _consecutiveRestartFailures < 5)
                {
                    _lastRestartAttemptUtc = DateTime.UtcNow;
                    _log.LogWarning("Hotspot found Off while desired On; attempting auto-restart.");
                    try
                    {
                        var res = await _manager.StartTetheringAsync();
                        if (res.Status == TetheringOperationStatus.Success) _consecutiveRestartFailures = 0;
                        else _consecutiveRestartFailures++;
                    }
                    catch (Exception ex)
                    {
                        _consecutiveRestartFailures++;
                        _log.LogWarning(ex, "Auto-restart failed");
                    }
                }
            }

            var status = BuildStatus();
            if (!StatusEquals(status, _last))
            {
                _last = status;
                StatusChanged?.Invoke(status);
            }
        }
        finally { _gate.Release(); }
    }

    // -------------------------------------------------------------------------
    // Status assembly
    // -------------------------------------------------------------------------

    /// <summary>
    /// Bind <see cref="_manager"/> to the current internet upstream if we don't have one yet,
    /// so a freshly-started backend (service restart, app relaunch) can observe and stop a
    /// hotspot that an earlier process left running, rather than silently no-op'ing.
    /// </summary>
    private void EnsureManager()
    {
        if (_manager is not null) return;
        var profile = NetworkInformation.GetInternetConnectionProfile();
        if (profile is null) return;
        try
        {
            _manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
            _activeProfileId = AdapterId(profile);
        }
        catch (Exception ex) { _log.LogDebug(ex, "EnsureManager could not bind"); }
    }

    private HotspotStatus BuildStatus()
    {
        EnsureManager();
        var probe = ProbeSoftApSupport();
        var profile = ResolveProfile(_activeProfileId) ?? NetworkInformation.GetInternetConnectionProfile();

        var status = new HotspotStatus
        {
            Ssid = _ssid,
            Passphrase = _passphrase,
            Band = _band,
            CanHostAp = probe.canHost,
            CapabilityDetail = probe.detail,
            UpstreamName = profile?.ProfileName,
            UpstreamKind = profile is null ? null : KindOf(profile),
            ElevationOnDemand = !TetherElevation.IsElevated,
        };

        if (_manager is not null)
        {
            status.BandsSupported = ProbeSupportedBands();
            status.State = _manager.TetheringOperationalState switch
            {
                TetheringOperationalState.On => "on",
                TetheringOperationalState.Off => "off",
                TetheringOperationalState.InTransition => "inTransition",
                _ => "unknown",
            };
            try { status.ClientCount = _manager.ClientCount; } catch { }
            try { status.MaxClientCount = _manager.MaxClientCount; } catch { }
        }
        else
        {
            status.State = "off";
        }

        if (status.State == "on")
            status.GatewayIp = FindGatewayIp();

        return status;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static ConnectionProfile? ResolveProfile(string? id)
    {
        if (string.IsNullOrEmpty(id))
            return NetworkInformation.GetInternetConnectionProfile();
        foreach (var p in NetworkInformation.GetConnectionProfiles())
            if (AdapterId(p) == id) return p;
        // Fall back to the system internet profile if the requested one vanished.
        return NetworkInformation.GetInternetConnectionProfile();
    }

    private static string AdapterId(ConnectionProfile? p)
    {
        try { return p?.NetworkAdapter?.NetworkAdapterId.ToString() ?? ""; }
        catch { return ""; }
    }

    private static string KindOf(ConnectionProfile p)
    {
        if (p.IsWlanConnectionProfile) return "wifi";
        if (p.IsWwanConnectionProfile) return "wwan";
        try
        {
            if (p.NetworkAdapter?.IanaInterfaceType == 6) return "ethernet";
        }
        catch { }
        return "other";
    }

    private static string NormalizeBand(string? b) => b switch
    {
        "2.4" or "2.4ghz" or "twopointfourgigahertz" => "2.4",
        "5" or "5ghz" or "fivegigahertz" => "5",
        _ => "auto",
    };

    /// <summary>
    /// Which bands the radio actually offers, via <c>IsBandSupported</c>. Returns null when the
    /// query itself is unavailable, so "we could not ask" stays distinguishable from "the driver
    /// says neither".
    ///
    /// <para>The distinction matters for the 5 GHz case: a Wi-Fi-Direct-GO-only adapter (the
    /// TP-Link RTL8811AU with the inbox Microsoft driver, measured 2026-07-28) answers False for
    /// both 2.4 and 5 GHz while still tethering happily at 2.4, and setting
    /// <c>cfg.Band = FiveGigahertz</c> on it is accepted and then ignored. Without this the user
    /// asks for 5 GHz, gets no error, and streams over 2.4 believing otherwise. Only Auto is
    /// unqueryable — <c>IsBandSupported(Auto)</c> raises E_FAIL, which is why it is not asked.</para>
    /// </summary>
    private List<string>? ProbeSupportedBands()
    {
        try
        {
            var cfg = _manager?.GetCurrentAccessPointConfiguration();
            if (cfg is null) return null;
            var bands = new List<string>();
            if (IsBandSupported(cfg, TetheringWiFiBand.TwoPointFourGigahertz)) bands.Add("2.4");
            if (IsBandSupported(cfg, TetheringWiFiBand.FiveGigahertz)) bands.Add("5");
            return bands;
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Band support query failed");
            return null;
        }
    }

    private static bool IsBandSupported(NetworkOperatorTetheringAccessPointConfiguration cfg,
                                        TetheringWiFiBand band)
    {
        try { return cfg.IsBandSupported(band); }
        catch { return false; }   // Pre-2004 Windows, or a driver that refuses the query.
    }

    private void TrySetBand(NetworkOperatorTetheringAccessPointConfiguration cfg, string band)
    {
        try
        {
            cfg.Band = band switch
            {
                "2.4" => TetheringWiFiBand.TwoPointFourGigahertz,
                "5" => TetheringWiFiBand.FiveGigahertz,
                _ => TetheringWiFiBand.Auto,
            };
        }
        catch (Exception ex)
        {
            _log.LogWarning("Band '{Band}' not honored by this API/driver: {Msg}", band, ex.Message);
        }
    }

    /// <summary>The Mobile Hotspot ICS gateway the headset must target (host's AP IP).</summary>
    private static string FindGatewayIp()
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var ip in ni.GetIPProperties().UnicastAddresses)
                {
                    var s = ip.Address.ToString();
                    if (s.StartsWith("192.168.137.")) return "192.168.137.1";
                }
            }
        }
        catch { }
        return "192.168.137.1"; // ICS default
    }

    /// <summary>
    /// Best-effort SoftAP capability probe via <c>netsh wlan show wirelesscapabilities</c>.
    /// Mobile Hotspot needs an adapter whose driver exposes SoftAP (or, on some Windows
    /// builds, Wi-Fi-Direct GO). We surface a precise message instead of a raw status.
    /// </summary>
    private (bool canHost, string detail) ProbeSoftApSupport()
    {
        if (_softApProbe is { } cached) return cached;
        try
        {
            var psi = new ProcessStartInfo("netsh", "wlan show wirelesscapabilities")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
            };
            using var proc = Process.Start(psi)!;
            string outp = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(5000);

            bool anySoftAp = false, anyGo = false;
            string? curIface = null;
            var capableIfaces = new List<string>();
            foreach (var raw in outp.Split('\n'))
            {
                var line = raw.Trim();
                if (line.StartsWith("Interface name:", StringComparison.OrdinalIgnoreCase))
                    curIface = line.Substring("Interface name:".Length).Trim();
                bool isSoftAp = line.StartsWith("Soft AP", StringComparison.OrdinalIgnoreCase);
                bool isGo = line.StartsWith("Wi-Fi Direct GO", StringComparison.OrdinalIgnoreCase);
                if ((isSoftAp || isGo) && line.Contains("Supported", StringComparison.OrdinalIgnoreCase)
                    && !line.Contains("Not supported", StringComparison.OrdinalIgnoreCase))
                {
                    if (isSoftAp) { anySoftAp = true; if (curIface != null) capableIfaces.Add(curIface); }
                    if (isGo) anyGo = true;
                }
            }

            // Mobile Hotspot can host via SoftAP OR Wi-Fi-Direct-GO. We verified on this box
            // that GO-only adapters DO tether (after a cold-start retry), so GO counts as
            // capable — but flag it because GO-only is 2.4 GHz / low client-cap and starts cold.
            bool canHost = anySoftAp || anyGo;
            string detail = anySoftAp
                ? $"SoftAP-capable adapter present ({string.Join(", ", capableIfaces.Distinct())})."
                : anyGo
                    ? "No SoftAP adapter; hosting via Wi-Fi-Direct-GO (2.4 GHz, low client cap, may need a " +
                      "cold-start retry). Works, but a SoftAP-capable adapter/driver is more robust."
                    : "No Wi-Fi adapter on this machine exposes SoftAP or Wi-Fi-Direct-GO. A " +
                      "Mobile-Hotspot-capable Wi-Fi adapter/driver is required to host the access point.";
            _softApProbe = (canHost, detail);
        }
        catch (Exception ex)
        {
            _softApProbe = (false, $"SoftAP capability probe failed: {ex.Message}");
        }
        return _softApProbe!.Value;
    }

    /// <summary>Per-Wi-Fi-adapter AP capability (name → SoftAP-or-GO supported), via netsh.</summary>
    private Dictionary<string, bool> ProbePerAdapterCapability()
    {
        var map = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        string outp = RunNetshCapture("wlan show wirelesscapabilities");
        string? iface = null;
        foreach (var raw in outp.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("Interface name:", StringComparison.OrdinalIgnoreCase))
            {
                iface = line.Substring("Interface name:".Length).Trim();
                if (!map.ContainsKey(iface)) map[iface] = false;
            }
            else if (iface != null &&
                     (line.StartsWith("Soft AP", StringComparison.OrdinalIgnoreCase) ||
                      line.StartsWith("Wi-Fi Direct GO", StringComparison.OrdinalIgnoreCase)))
            {
                if (line.Contains("Supported", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("Not supported", StringComparison.OrdinalIgnoreCase))
                    map[iface] = true;
            }
        }
        return map;
    }

    /// <summary>Admin/connection state per interface name, via <c>netsh interface show interface</c>.</summary>
    private Dictionary<string, (bool enabled, bool connected)> ProbeInterfaceStates()
    {
        var map = new Dictionary<string, (bool, bool)>(StringComparer.OrdinalIgnoreCase);
        string outp = RunNetshCapture("interface show interface");
        foreach (var raw in outp.Split('\n'))
        {
            var line = raw.TrimEnd();
            // Columns: Admin State | State | Type | Interface Name (name may contain spaces).
            var m = System.Text.RegularExpressions.Regex.Match(line,
                @"^\s*(Enabled|Disabled)\s+(\S+)\s+(\S+)\s+(.+?)\s*$");
            if (!m.Success) continue;
            bool enabled = m.Groups[1].Value.Equals("Enabled", StringComparison.OrdinalIgnoreCase);
            bool connected = m.Groups[2].Value.Equals("Connected", StringComparison.OrdinalIgnoreCase);
            map[m.Groups[4].Value.Trim()] = (enabled, connected);
        }
        return map;
    }

    private void ReenableDisabledAdapters()
    {
        foreach (var name in _disabledAdapters)
        {
            _log.LogInformation("Re-enabling Wi-Fi adapter '{Name}'.", name);
            RunNetsh($"interface set interface name=\"{name}\" admin=enabled");
        }
        _disabledAdapters.Clear();
    }

    private bool RunNetsh(string args)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", args)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using var p = Process.Start(psi)!;
            p.WaitForExit(8000);
            return p.ExitCode == 0;
        }
        catch (Exception ex) { _log.LogWarning(ex, "netsh {Args} failed", args); return false; }
    }

    private static string RunNetshCapture(string args)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", args)
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, StandardOutputEncoding = System.Text.Encoding.UTF8 };
            using var p = Process.Start(psi)!;
            string outp = p.StandardOutput.ReadToEnd();
            p.WaitForExit(8000);
            return outp;
        }
        catch { return ""; }
    }

    private static string Camel(string s) =>
        string.IsNullOrEmpty(s) ? s : char.ToLowerInvariant(s[0]) + s.Substring(1);

    private OperationResult Ok(string status, string? detail) =>
        new() { Ok = true, Status = status, Detail = detail, Snapshot = BuildStatus() };

    private OperationResult Fail(string status, string? detail) =>
        new() { Ok = false, Status = status, Detail = detail, Snapshot = BuildStatus() };

    private static bool StatusEquals(HotspotStatus a, HotspotStatus b) =>
        a.State == b.State && a.ClientCount == b.ClientCount && a.MaxClientCount == b.MaxClientCount &&
        a.Ssid == b.Ssid && a.GatewayIp == b.GatewayIp && a.CanHostAp == b.CanHostAp &&
        a.UpstreamName == b.UpstreamName;
}
