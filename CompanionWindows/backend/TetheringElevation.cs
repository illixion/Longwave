using System.Diagnostics;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend;

// ---------------------------------------------------------------------------
// On-demand elevation for tethering.
//
// The companion used to declare requireAdministrator for one feature: the Mobile Hotspot.
// That elevated everything else with it, including the PCVR path, and elevation there is
// actively harmful — the OpenXR loader ignores XR_RUNTIME_JSON in an elevated process, so the
// machine registry default had to be CloudXR purely to steer the broker, which is the default
// games want for themselves. Elevation also forced games to be launched de-elevated by hand and
// forced an explicit DACL on the gaze-pivot shared section.
//
// So the backend now runs asInvoker and the hotspot elevates on demand: the first mutating
// tethering call spawns this same executable with `--tether-host` through ShellExecute "runas",
// which raises exactly one consent prompt, and that elevated child owns the access point for the
// rest of the backend's life. Reading hotspot state needs no elevation at all (verified at medium
// integrity on the RTX host, 2026-07-28: CreateFromConnectionProfile, TetheringOperationalState,
// ClientCount and GetCurrentAccessPointConfiguration all answer), so status, polling and the
// UI's live client count keep working with no prompt and no host process.
//
// Why a resident child rather than one-shot elevation per operation: Windows idle-disables the
// hotspot, and the auto-restart in TetheringController.PollAsync has to call StartTetheringAsync
// again. One-shot elevation would mean a consent prompt appearing by itself, minutes later, with
// no user action behind it. A resident host restarts it silently.
// ---------------------------------------------------------------------------

/// <summary>
/// The tethering surface the rest of the backend talks to, so that the caller does not have to
/// know whether the access point is owned in-process (already elevated: service mode, or the
/// elevated host itself) or by an elevated child (<see cref="ElevatedTetheringProxy"/>).
/// </summary>
public interface ITetheringService
{
    event Action<HotspotStatus>? StatusChanged;

    IReadOnlyList<UpstreamProfile> ListUpstreamProfiles();
    IReadOnlyList<WifiAdapterInfo> ListWifiAdapters();
    Task<HotspotStatus> GetStatusAsync();
    Task<PrepareApResult> PrepareApAdapterAsync();
    Task<OperationResult> StartAsync(StartHotspotParams p);
    Task<OperationResult> StopAsync();
    Task PollAsync();
}

/// <summary>Elevation state of the current process, and the wire details the two roles share.</summary>
public static class TetherElevation
{
    /// <summary>Pipe the elevated <c>--tether-host</c> serves and the proxy connects to.</summary>
    public const string HostPipeName = "longwave-tether-host";

    /// <summary>Argument that switches this executable into the elevated tethering host role.</summary>
    public const string HostRoleArg = "--tether-host";

    private static readonly Lazy<bool> Elevated = new(() =>
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    });

    /// <summary>True when this process already has administrator rights.</summary>
    public static bool IsElevated => Elevated.Value;
}

/// <summary>
/// Serves the tethering operations that need administrator rights, over a named pipe, for an
/// unelevated backend of the same user. Runs as <c>--tether-host --parent-pid=N</c>.
///
/// <para>The exposed surface is deliberately tiny — start, stop, prepare-adapter, ping — because
/// this is an elevated process taking instructions from an unelevated one, which is a privilege
/// boundary. Nothing here takes a path or a command line: the parameters are an SSID, a
/// passphrase, a band and a profile id, and they are handed to WinRT, never to a shell. The one
/// operation that does shell out (<c>netsh interface set interface</c>, in PrepareApAdapter)
/// chooses the adapter name itself from its own enumeration and accepts no caller input. The pipe
/// is ACL'd to the single user SID that started us — not Authenticated Users, not
/// Administrators — so the only process that can drive it belongs to the user who already
/// consented at the UAC prompt.</para>
/// </summary>
public sealed class TetherHost
{
    private readonly ILogger _log;
    private readonly TetheringController _controller;
    private readonly int _parentPid;

    /// <summary>Set once a Start succeeded, so exit can undo what we did and nothing else.</summary>
    private bool _startedByUs;

    public TetherHost(ILogger log, TetheringController controller, int parentPid)
    {
        _log = log;
        _controller = controller;
        _parentPid = parentPid;
    }

    public async Task<int> RunAsync()
    {
        _log.LogInformation("Elevated tethering host starting (elevated={Elevated}, parentPid={Pid}).",
            TetherElevation.IsElevated, _parentPid);

        if (!TetherElevation.IsElevated)
        {
            // Being asked to be the elevated host without being elevated means the runas failed
            // open somehow. Say so rather than serving a pipe that cannot do its job.
            _log.LogError("Refusing to run as the tethering host: this process is not elevated.");
            return 3;
        }

        using var stopping = new CancellationTokenSource();
        WatchParent(stopping);

        // Auto-restart after an idle-disable lives here, with the rights to act on it.
        var poll = PollLoopAsync(stopping.Token);

        try
        {
            while (!stopping.IsCancellationRequested)
            {
                using var server = CreatePipe();
                try
                {
                    await server.WaitForConnectionAsync(stopping.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) { break; }

                _log.LogInformation("Backend connected.");
                await ServeAsync(server, stopping.Token).ConfigureAwait(false);
                _log.LogInformation("Backend disconnected.");
            }
        }
        finally
        {
            try { await poll.ConfigureAwait(false); } catch { /* cancelled */ }
            await ShutdownAsync().ConfigureAwait(false);
        }
        return 0;
    }

    /// <summary>
    /// Exit with the backend. Without this the elevated child would outlive the app that asked
    /// for it, holding an access point nothing can turn off through the UI any more.
    /// </summary>
    private void WatchParent(CancellationTokenSource stopping)
    {
        if (_parentPid <= 0) return;
        try
        {
            var parent = Process.GetProcessById(_parentPid);
            parent.EnableRaisingEvents = true;
            parent.Exited += (_, _) =>
            {
                _log.LogInformation("Backend (pid {Pid}) exited; shutting down.", _parentPid);
                stopping.Cancel();
            };
            if (parent.HasExited) stopping.Cancel();
        }
        catch (ArgumentException)
        {
            _log.LogWarning("Backend pid {Pid} is already gone; shutting down.", _parentPid);
            stopping.Cancel();
        }
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        try
        {
            while (await timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                try { await _controller.PollAsync().ConfigureAwait(false); }
                catch (Exception ex) { _log.LogWarning(ex, "Poll failed"); }
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>
    /// Undo on the way out: stop the access point if we are the ones who started it. This is not
    /// only tidiness — PrepareApAdapter disables Wi-Fi adapters to free the radio and it is
    /// <see cref="TetheringController.StopAsync"/> that re-enables them, so skipping the stop
    /// would leave the user's adapter administratively disabled after the app closed.
    /// </summary>
    private async Task ShutdownAsync()
    {
        if (!_startedByUs) return;
        try
        {
            _log.LogInformation("Stopping the access point we started.");
            await _controller.StopAsync().ConfigureAwait(false);
        }
        catch (Exception ex) { _log.LogWarning(ex, "Stop on shutdown failed"); }
    }

    /// <summary>
    /// Pipe reachable by exactly one SID: the user who started us. An elevated process's default
    /// DACL is owned by Administrators, and that group is deny-only in the same user's filtered
    /// (unelevated) token, so without an explicit rule the backend could not open its own helper.
    /// Elevation does not change the user SID, which is what makes a single-SID grant both
    /// sufficient and tight.
    /// </summary>
    private static NamedPipeServerStream CreatePipe()
    {
        var security = new PipeSecurity();
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw new InvalidOperationException("No user SID on the current token.");
        // CreateNewInstance because this loop re-creates the pipe after each client; see the same
        // right in PipeServer.CreateSecuredPipe for why leaving it out fails only when unelevated.
        security.AddAccessRule(new PipeAccessRule(user,
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));

        // Real buffer sizes, for the reason documented in PipeServer.CreateSecuredPipe: with 0/0
        // the kernel allocates no pipe buffer, so a write cannot complete until the peer happens
        // to be inside a read.
        return NamedPipeServerStreamAcl.Create(
            TetherElevation.HostPipeName, PipeDirection.InOut, maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
            inBufferSize: 16 * 1024, outBufferSize: 64 * 1024, security);
    }

    private async Task ServeAsync(NamedPipeServerStream server, CancellationToken ct)
    {
        var reader = new StreamReader(server, new UTF8Encoding(false));
        var writer = new StreamWriter(server, new UTF8Encoding(false)) { AutoFlush = true };

        while (!ct.IsCancellationRequested && server.IsConnected)
        {
            string? line;
            try { line = await reader.ReadLineAsync(ct).ConfigureAwait(false); }
            catch (Exception) { break; }
            if (line is null) break;
            if (line.Length == 0) continue;

            RpcResponse response;
            RpcRequest? req = null;
            try
            {
                req = JsonSerializer.Deserialize<RpcRequest>(line);
                object? result = req?.Method switch
                {
                    "StartHotspot" => await StartAsync(req!).ConfigureAwait(false),
                    "StopHotspot" => await StopAsync().ConfigureAwait(false),
                    "PrepareApAdapter" => await _controller.PrepareApAdapterAsync().ConfigureAwait(false),
                    "GetStatus" => await _controller.GetStatusAsync().ConfigureAwait(false),
                    "Ping" => "pong",
                    _ => null,
                };
                response = result is null
                    ? RpcResponse.Fail(req?.Id ?? 0, "methodNotFound", $"Unknown method '{req?.Method}'.")
                    : RpcResponse.Ok(req!.Id, result);
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Method {Method} threw", req?.Method);
                response = RpcResponse.Fail(req?.Id ?? 0, "exception", ex.Message);
            }

            try { await writer.WriteLineAsync(JsonSerializer.Serialize(response)).ConfigureAwait(false); }
            catch (Exception) { break; }
        }
    }

    private async Task<OperationResult> StartAsync(RpcRequest req)
    {
        var p = req.Params is { } raw
            ? JsonSerializer.Deserialize<StartHotspotParams>(raw.GetRawText()) ?? new StartHotspotParams()
            : new StartHotspotParams();
        var result = await _controller.StartAsync(p).ConfigureAwait(false);
        if (result.Ok) _startedByUs = true;
        return result;
    }

    private async Task<OperationResult> StopAsync()
    {
        var result = await _controller.StopAsync().ConfigureAwait(false);
        if (result.Ok) _startedByUs = false;
        return result;
    }
}

/// <summary>
/// <see cref="ITetheringService"/> for an unelevated backend. Status, enumeration and polling are
/// answered locally — none of them needs administrator rights — and only the three operations that
/// do (start, stop, prepare-adapter) are forwarded to an elevated <see cref="TetherHost"/>, which
/// is spawned on first use and lives until this process exits.
/// </summary>
public sealed class ElevatedTetheringProxy : ITetheringService, IDisposable
{
    /// <summary>Long enough for a user to notice the consent prompt and click it.</summary>
    private static readonly TimeSpan ConsentTimeout = TimeSpan.FromSeconds(90);

    private readonly ILogger _log;
    private readonly TetheringController _local;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;
    private Process? _host;
    private int _nextId;

    /// <summary>
    /// Why the last attempt to reach the helper failed. Declining the consent prompt is a normal
    /// answer and has to be reported as one: "the helper did not answer" describes a broken
    /// install, and would send the user looking for a fault instead of clicking Yes.
    /// </summary>
    private bool _lastAttemptDeclined;

    public ElevatedTetheringProxy(ILogger log, TetheringController local)
    {
        _log = log;
        _local = local;
    }

    public event Action<HotspotStatus>? StatusChanged
    {
        add => _local.StatusChanged += value;
        remove => _local.StatusChanged -= value;
    }

    // ---- unprivileged: answered in-process, no host, no prompt ----

    public IReadOnlyList<UpstreamProfile> ListUpstreamProfiles() => _local.ListUpstreamProfiles();
    public IReadOnlyList<WifiAdapterInfo> ListWifiAdapters() => _local.ListWifiAdapters();
    public Task<HotspotStatus> GetStatusAsync() => _local.GetStatusAsync();

    /// <summary>
    /// Polls locally. The local controller never auto-restarts, because its <c>_desiredOn</c> is
    /// only set by a local Start and this proxy never performs one — the elevated host owns the
    /// access point and does the restarting. So this is a pure observer, which is what keeps the
    /// UI's state and client count live without a host process.
    /// </summary>
    public Task PollAsync() => _local.PollAsync();

    // ---- privileged: forwarded to the elevated host ----

    public async Task<OperationResult> StartAsync(StartHotspotParams p) =>
        Relabel(await CallAsync<OperationResult>("StartHotspot", p).ConfigureAwait(false))
        ?? Unreachable();

    public async Task<OperationResult> StopAsync()
    {
        // Nothing to stop if we never elevated, and asking for consent in order to turn off
        // something we did not turn on would be absurd.
        if (_host is null or { HasExited: true } && _pipe is not { IsConnected: true })
        {
            var status = await _local.GetStatusAsync().ConfigureAwait(false);
            if (status.State == "off")
                return new OperationResult { Ok = true, Status = "success", Snapshot = status };
        }
        return Relabel(await CallAsync<OperationResult>("StopHotspot", null).ConfigureAwait(false))
            ?? Unreachable();
    }

    /// <summary>
    /// Snapshots inside a relayed result were built by the elevated helper, so they carry
    /// <c>elevationOnDemand = false</c> — true of the helper, wrong for the client that asked. Left
    /// alone, the UI would drop its elevation hint the moment the user first started the hotspot.
    /// </summary>
    private static OperationResult? Relabel(OperationResult? result)
    {
        if (result?.Snapshot is { } snapshot) snapshot.ElevationOnDemand = true;
        return result;
    }

    public async Task<PrepareApResult> PrepareApAdapterAsync() =>
        await CallAsync<PrepareApResult>("PrepareApAdapter", null).ConfigureAwait(false)
        ?? new PrepareApResult { Ok = false, Detail = UnreachableDetail() };

    /// <summary>Result for "could not reach the helper", distinguishing a decline from a fault.</summary>
    private OperationResult Unreachable() => new()
    {
        Ok = false,
        Status = _lastAttemptDeclined ? "elevationDeclined" : "hostUnavailable",
        Detail = UnreachableDetail(),
    };

    private string UnreachableDetail() => _lastAttemptDeclined
        ? "Changing the hotspot needs administrator approval, and the prompt was dismissed. "
          + "Try again and choose Yes."
        : "The elevated tethering helper did not answer.";

    private async Task<T?> CallAsync<T>(string method, object? param) where T : class
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!await EnsureHostAsync().ConfigureAwait(false))
                return null;

            var req = new
            {
                id = ++_nextId,
                method,
                @params = param,
            };
            await _writer!.WriteLineAsync(JsonSerializer.Serialize(req)).ConfigureAwait(false);
            var line = await _reader!.ReadLineAsync().ConfigureAwait(false);
            if (line is null)
            {
                _log.LogWarning("Elevated tethering helper closed the pipe during {Method}.", method);
                Disconnect();
                return null;
            }

            using var doc = JsonDocument.Parse(line);
            if (doc.RootElement.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.Object)
            {
                _log.LogWarning("Elevated tethering helper rejected {Method}: {Error}", method, err.ToString());
                return null;
            }
            return doc.RootElement.TryGetProperty("result", out var result)
                ? result.Deserialize<T>()
                : null;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Call {Method} to the elevated tethering helper failed", method);
            Disconnect();
            return null;
        }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Connect to the elevated host, spawning it (one UAC prompt) if it is not there. Called
    /// under <see cref="_gate"/>.
    /// </summary>
    private async Task<bool> EnsureHostAsync()
    {
        _lastAttemptDeclined = false;
        if (_pipe is { IsConnected: true }) return true;
        Disconnect();

        // A host from an earlier call may still be up; try it before prompting again. Quiet,
        // because this probe is *expected* to fail on the first call and a warning about a
        // timeout reads as a fault right before the thing succeeds.
        if (await TryConnectAsync(TimeSpan.FromMilliseconds(500), quiet: true).ConfigureAwait(false))
            return true;

        if (!TrySpawnHost()) return false;
        return await TryConnectAsync(ConsentTimeout, quiet: false).ConfigureAwait(false);
    }

    private bool TrySpawnHost()
    {
        string exe = Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? throw new InvalidOperationException("Cannot determine this executable's path.");

        var psi = new ProcessStartInfo
        {
            FileName = exe,
            // Redirection is impossible with UseShellExecute, which "runas" requires; the host
            // logs to its own file instead.
            UseShellExecute = true,
            Verb = "runas",
            Arguments = $"{TetherElevation.HostRoleArg} --parent-pid={Environment.ProcessId}",
            WorkingDirectory = AppContext.BaseDirectory,
        };

        try
        {
            _log.LogInformation("Requesting elevation for the tethering helper.");
            _host = Process.Start(psi);
            return _host is not null;
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            // ERROR_CANCELLED — the consent prompt was dismissed, or timed out on the secure
            // desktop. A normal answer, not a fault, and reported as "elevationDeclined" so the UI
            // says "approve the prompt" instead of implying the helper is broken.
            _log.LogInformation("Elevation for the tethering helper was declined.");
            _lastAttemptDeclined = true;
            return false;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Could not start the elevated tethering helper");
            return false;
        }
    }

    private async Task<bool> TryConnectAsync(TimeSpan timeout, bool quiet)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (_host is { HasExited: true })
            {
                _log.LogWarning("The elevated tethering helper exited before connecting (exit {Code}).",
                    _host.ExitCode);
                return false;
            }
            try
            {
                var pipe = new NamedPipeClientStream(".", TetherElevation.HostPipeName,
                    PipeDirection.InOut, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(1000).ConfigureAwait(false);
                _pipe = pipe;
                _reader = new StreamReader(pipe, new UTF8Encoding(false));
                _writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
                _log.LogInformation("Connected to the elevated tethering helper.");
                return true;
            }
            catch (TimeoutException) { }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Connect to the tethering helper failed; retrying.");
                await Task.Delay(250).ConfigureAwait(false);
            }
        }
        if (!quiet) _log.LogWarning("Timed out waiting for the elevated tethering helper.");
        return false;
    }

    private void Disconnect()
    {
        try { _writer?.Dispose(); } catch { }
        try { _reader?.Dispose(); } catch { }
        try { _pipe?.Dispose(); } catch { }
        _writer = null;
        _reader = null;
        _pipe = null;
    }

    public void Dispose()
    {
        Disconnect();
        // The host exits on its own when it sees this process go (and stops an AP it started).
        _host?.Dispose();
        _gate.Dispose();
    }
}
