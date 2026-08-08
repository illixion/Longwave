using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace VisionVNC.Hotspot.Backend;

/// <summary>
/// Named-pipe JSON-RPC server. One client (the Electron app) at a time; reconnections are
/// accepted in a loop. Requests are newline-delimited JSON; responses echo the id; and the
/// server pushes unsolicited "event" lines (state/clients/error) to the connected client.
///
/// The pipe ACL restricts access to the interactive desktop user + Administrators + SYSTEM —
/// the backend is privileged, so an open pipe would be a local privilege-escalation vector.
/// </summary>
public sealed class PipeServer : BackgroundService
{
    public const string PipeName = "visionvnc-hotspot";

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly ILogger<PipeServer> _log;
    private readonly TetheringController _controller;
    private readonly NativeStream.NativeStreamingService _nativeStream;

    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private StreamWriter? _writer;

    public PipeServer(
        ILogger<PipeServer> log,
        TetheringController controller,
        NativeStream.NativeStreamingService nativeStream)
    {
        _log = log;
        _controller = controller;
        _nativeStream = nativeStream;
        _controller.StatusChanged += OnStatusChanged;
        _nativeStream.StatusChanged += OnNativeStreamChanged;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _log.LogInformation("PipeServer listening on \\\\.\\pipe\\{Pipe}", PipeName);
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var server = CreateSecuredPipe();
                await server.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
                _log.LogInformation("Client connected.");
                await HandleConnectionAsync(server, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                _log.LogError(ex, "Pipe accept/handle loop error; retrying shortly.");
                try { await Task.Delay(500, stoppingToken).ConfigureAwait(false); } catch { break; }
            }
        }
        _log.LogInformation("PipeServer stopped.");
    }

    private NamedPipeServerStream CreateSecuredPipe()
    {
        var security = new PipeSecurity();

        // The desktop user who runs the Electron app (covers the SYSTEM-service case too).
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.InteractiveSid, null),
            PipeAccessRights.ReadWrite, AccessControlType.Allow));

        // The current process owner (covers the interactive-helper deployment, same user).
        using (var me = WindowsIdentity.GetCurrent())
        {
            if (me.User is { } user)
                security.AddAccessRule(new PipeAccessRule(user,
                    PipeAccessRights.ReadWrite, AccessControlType.Allow));
        }

        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));

        return NamedPipeServerStreamAcl.Create(
            PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
            inBufferSize: 0, outBufferSize: 0, pipeSecurity: security);
    }

    private async Task HandleConnectionAsync(NamedPipeServerStream server, CancellationToken ct)
    {
        var utf8 = new UTF8Encoding(false);
        using var reader = new StreamReader(server, utf8, false, 4096, leaveOpen: true);
        var writer = new StreamWriter(server, utf8, 4096, leaveOpen: true) { AutoFlush = false, NewLine = "\n" };

        await _writeLock.WaitAsync(ct).ConfigureAwait(false);
        _writer = writer;
        _writeLock.Release();

        try
        {
            // Push an initial snapshot so the UI hydrates immediately.
            await SendEventAsync(RpcEvent.Of("state", await _controller.GetStatusAsync())).ConfigureAwait(false);

            while (!ct.IsCancellationRequested && server.IsConnected)
            {
                string? line = await reader.ReadLineAsync(ct).ConfigureAwait(false);
                if (line is null) break;            // client closed
                if (line.Length == 0) continue;
                await DispatchAsync(line).ConfigureAwait(false);
            }
        }
        catch (IOException) { /* client vanished */ }
        catch (OperationCanceledException) { }
        finally
        {
            await _writeLock.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            _writer = null;
            _writeLock.Release();
            _log.LogInformation("Client disconnected.");
        }
    }

    private async Task DispatchAsync(string line)
    {
        RpcRequest? req;
        try { req = JsonSerializer.Deserialize<RpcRequest>(line, JsonOpts); }
        catch (Exception ex)
        {
            _log.LogWarning("Bad request JSON: {Msg}", ex.Message);
            return;
        }
        if (req is null || string.IsNullOrEmpty(req.Method)) return;

        RpcResponse response;
        try
        {
            object? result = req.Method switch
            {
                "GetStatus" => await _controller.GetStatusAsync(),
                "ListUpstreamProfiles" => _controller.ListUpstreamProfiles(),
                "StartHotspot" => await _controller.StartAsync(ParseParams<StartHotspotParams>(req) ?? new StartHotspotParams()),
                "StopHotspot" => await _controller.StopAsync(),
                "ListWifiAdapters" => _controller.ListWifiAdapters(),
                "PrepareApAdapter" => await _controller.PrepareApAdapterAsync(),
                "GetClients" => await GetClientsAsync(),
                "NativeStreamStatus" => _nativeStream.GetStatus(),
                "NativeStreamSetEnabled" => SetNativeStreamEnabled(ParseParams<NativeStreamEnableParams>(req)),
                "NativeStreamSetInput" => SetNativeStreamInput(ParseParams<NativeStreamInputParams>(req)),
                "NativeStreamRegenerateToken" => RegenerateNativeStreamToken(),
                "Ping" => "pong",
                _ => Sentinel.Unknown,
            };

            response = ReferenceEquals(result, Sentinel.Unknown)
                ? RpcResponse.Fail(req.Id, "methodNotFound", $"Unknown method '{req.Method}'.")
                : RpcResponse.Ok(req.Id, result);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Method {Method} threw", req.Method);
            response = RpcResponse.Fail(req.Id, "exception", ex.Message);
        }

        await SendAsync(response).ConfigureAwait(false);
    }

    private async Task<object> GetClientsAsync()
    {
        var s = await _controller.GetStatusAsync();
        return new { count = s.ClientCount, max = s.MaxClientCount };
    }

    private object SetNativeStreamEnabled(NativeStreamEnableParams? p)
    {
        _nativeStream.SetEnabled(p?.Enabled ?? false);
        return _nativeStream.GetStatus();
    }

    private object SetNativeStreamInput(NativeStreamInputParams? p)
    {
        if (p?.Mouse is { } mouse) _nativeStream.MouseControlEnabled = mouse;
        if (p?.Keyboard is { } keyboard) _nativeStream.KeyboardControlEnabled = keyboard;
        return _nativeStream.GetStatus();
    }

    private object RegenerateNativeStreamToken()
    {
        _nativeStream.RegenerateToken();
        return _nativeStream.GetStatus();
    }

    private void OnNativeStreamChanged()
    {
        _ = SendEventAsync(RpcEvent.Of("nativeStream", _nativeStream.GetStatus()));
    }

    private sealed record NativeStreamEnableParams
    {
        [System.Text.Json.Serialization.JsonPropertyName("enabled")]
        public bool Enabled { get; init; }
    }

    private sealed record NativeStreamInputParams
    {
        [System.Text.Json.Serialization.JsonPropertyName("mouse")]
        public bool? Mouse { get; init; }

        [System.Text.Json.Serialization.JsonPropertyName("keyboard")]
        public bool? Keyboard { get; init; }
    }

    private static T? ParseParams<T>(RpcRequest req) where T : class =>
        req.Params is { } p ? JsonSerializer.Deserialize<T>(p.GetRawText(), JsonOpts) : null;

    private void OnStatusChanged(HotspotStatus status)
    {
        // Fire-and-forget; the write path is serialized by _writeLock.
        _ = SendEventAsync(RpcEvent.Of("state", status));
    }

    private Task SendAsync(RpcResponse response) => WriteLineAsync(response);
    private Task SendEventAsync(RpcEvent evt) => WriteLineAsync(evt);

    private async Task WriteLineAsync(object message)
    {
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            var w = _writer;
            if (w is null) return; // no client connected
            await w.WriteLineAsync(JsonSerializer.Serialize(message, JsonOpts)).ConfigureAwait(false);
            await w.FlushAsync().ConfigureAwait(false);
        }
        catch (IOException) { /* client disconnected mid-write */ }
        finally { _writeLock.Release(); }
    }

    public override void Dispose()
    {
        _controller.StatusChanged -= OnStatusChanged;
        _nativeStream.StatusChanged -= OnNativeStreamChanged;
        base.Dispose();
    }

    private static class Sentinel { public static readonly object Unknown = new(); }
}
