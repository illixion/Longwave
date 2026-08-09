using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace VisionVNC.WindowsCompanion.Backend;

/// <summary>
/// Named-pipe JSON-RPC server for the public backend (hotspot, native screen streaming).
/// Requests are newline-delimited JSON; responses echo the id back to the client that asked;
/// and the server broadcasts unsolicited "event" lines (state/nativeStream/clients/error) to
/// every connected client.
///
/// The CloudXR / Foveated-Streaming host and the game library are a separate process on their
/// own pipe (PcvrPipeServer, in the closed-source VisionVNC-PCVR-Host project) — this backend
/// has no reference to that assembly and no idea whether it's even installed.
///
/// Clients are served <b>concurrently</b>. That matters operationally: the Electron UI holds
/// a connection for its whole lifetime, so a serial accept loop would lock out every other
/// client. Each accepted connection therefore gets its own pipe instance and its own task, and
/// the loop goes straight back to waiting for the next one.
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
    private readonly ITetheringService _controller;
    private readonly NativeStream.NativeStreamingService _nativeStream;

    private readonly System.Collections.Concurrent.ConcurrentDictionary<Guid, ClientConnection> _clients = new();

    /// <summary>One connected client. Owns its own write lock so a slow or dead client
    /// cannot stall broadcasts to the others.</summary>
    private sealed class ClientConnection
    {
        private readonly SemaphoreSlim _writeLock = new(1, 1);
        private readonly StreamWriter _writer;

        public Guid Id { get; } = Guid.NewGuid();

        public ClientConnection(StreamWriter writer) => _writer = writer;

        public async Task WriteLineAsync(string json)
        {
            await _writeLock.WaitAsync().ConfigureAwait(false);
            try
            {
                await _writer.WriteLineAsync(json).ConfigureAwait(false);
                await _writer.FlushAsync().ConfigureAwait(false);
            }
            catch (IOException) { /* client disconnected mid-write */ }
            catch (ObjectDisposedException) { /* raced with teardown */ }
            finally { _writeLock.Release(); }
        }
    }

    public PipeServer(ILogger<PipeServer> log, ITetheringService controller,
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
            NamedPipeServerStream? accepted = null;
            try
            {
                accepted = CreateSecuredPipe();
                await accepted.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { accepted?.Dispose(); break; }
            catch (Exception ex)
            {
                accepted?.Dispose();
                _log.LogError(ex, "Pipe accept error; retrying shortly.");
                try { await Task.Delay(500, stoppingToken).ConfigureAwait(false); } catch { break; }
                continue;
            }

            // Serve on its own task and immediately loop back to create the next pipe
            // instance, so additional clients are not blocked behind this one.
            var stream = accepted;
            _ = Task.Run(() => ServeClientAsync(stream, stoppingToken), CancellationToken.None);
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
        //
        // CreateNewInstance is not optional and its absence is invisible while elevated. Adding an
        // instance to an *existing* pipe requires FILE_CREATE_PIPE_INSTANCE on that pipe, and this
        // server creates one instance per accepted client. An elevated process passes that check
        // through the Administrators FullControl rule below; an unelevated one cannot, because
        // Administrators is deny-only in a filtered token. The symptom is precise and misleading:
        // the pipe is created, the first client connects and is served normally, and then every
        // subsequent accept fails with UnauthorizedAccessException "Access to the path is denied"
        // — which reads as a problem with the pipe's path or the ACL as a whole rather than as one
        // missing right on one rule.
        using (var me = WindowsIdentity.GetCurrent())
        {
            if (me.User is { } user)
                security.AddAccessRule(new PipeAccessRule(user,
                    PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
                    AccessControlType.Allow));
        }

        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl, AccessControlType.Allow));

        // Real buffer sizes matter here. With 0/0 the kernel allocates no pipe buffer, so a
        // client's write cannot complete until the server happens to be in a read — observed
        // as a client connecting successfully, receiving the pushed snapshots, and then
        // blocking forever on its first request. The out buffer is generous because pairing
        // events carry the QR PNG as a base64 data URI (hundreds of KB), and a broadcast that
        // blocks on one slow reader stalls that client's UI.
        const int InBufferSize = 64 * 1024;
        const int OutBufferSize = 1024 * 1024;

        return NamedPipeServerStreamAcl.Create(
            PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous,
            inBufferSize: InBufferSize, outBufferSize: OutBufferSize, pipeSecurity: security);
    }

    private async Task ServeClientAsync(NamedPipeServerStream server, CancellationToken ct)
    {
        var utf8 = new UTF8Encoding(false);
        ClientConnection? client = null;
        try
        {
            using var reader = new StreamReader(server, utf8, false, 4096, leaveOpen: true);
            var writer = new StreamWriter(server, utf8, 4096, leaveOpen: true) { AutoFlush = false, NewLine = "\n" };

            client = new ClientConnection(writer);
            _clients[client.Id] = client;
            _log.LogInformation("Client connected ({Count} total).", _clients.Count);

            // The hotspot status goes through WinRT tethering APIs that can block indefinitely
            // on a box with no tetherable adapter. Hydrating it inline would mean a client
            // never sees any frame at all — not even a Ping reply — because the read loop
            // below has not started yet. Hydrate it out of band and let it fail without taking
            // the connection down with it.
            HydrateHotspotStateAsync(client, ct);

            while (!ct.IsCancellationRequested && server.IsConnected)
            {
                string? line = await reader.ReadLineAsync(ct).ConfigureAwait(false);
                if (line is null) break;            // client closed
                if (line.Length == 0) continue;
                // Dispatch without awaiting: responses carry their request id, so ordering is
                // not required, and one slow method must not stall the client's other calls.
                _ = DispatchAsync(line, client);
            }
        }
        catch (IOException) { /* client vanished */ }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _log.LogError(ex, "Client handler failed."); }
        finally
        {
            if (client is not null) _clients.TryRemove(client.Id, out _);
            try { if (server.IsConnected) server.Disconnect(); } catch { /* already gone */ }
            server.Dispose();
            _log.LogInformation("Client disconnected ({Count} remain).", _clients.Count);
        }
    }

    /// <summary>
    /// Fire-and-forget hotspot-status hydration for a freshly connected client. Bounded,
    /// because the underlying WinRT query has been observed to never return on a machine
    /// with no tetherable Wi-Fi adapter (the PCVR host).
    /// </summary>
    private void HydrateHotspotStateAsync(ClientConnection client, CancellationToken ct)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                var status = await _controller.GetStatusAsync().WaitAsync(TimeSpan.FromSeconds(10), ct)
                                              .ConfigureAwait(false);
                await SendEventAsync(client, RpcEvent.Of("state", status)).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                _log.LogWarning("Hotspot status query timed out; client hydrated without it.");
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Hotspot status hydration failed.");
            }
        }, CancellationToken.None);
    }

    private async Task DispatchAsync(string line, ClientConnection client)
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
                // Bounded: see HydrateHotspotStateAsync — these can hang on a host with no
                // tetherable adapter, and a UI panel spinning forever is worse than an error.
                "GetStatus" => await _controller.GetStatusAsync().WaitAsync(StatusQueryTimeout),
                "ListUpstreamProfiles" => _controller.ListUpstreamProfiles(),
                "StartHotspot" => await _controller.StartAsync(ParseParams<StartHotspotParams>(req) ?? new StartHotspotParams()),
                "StopHotspot" => await _controller.StopAsync(),
                "ListWifiAdapters" => _controller.ListWifiAdapters(),
                "PrepareApAdapter" => await _controller.PrepareApAdapterAsync(),
                "GetClients" => await GetClientsAsync(),
                // ---- Native screen streaming ----
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

        await SendAsync(client, response).ConfigureAwait(false);
    }

    private static readonly TimeSpan StatusQueryTimeout = TimeSpan.FromSeconds(10);

    private async Task<object> GetClientsAsync()
    {
        var s = await _controller.GetStatusAsync().WaitAsync(StatusQueryTimeout);
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
        _ = BroadcastAsync(RpcEvent.Of("nativeStream", _nativeStream.GetStatus()));
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
        // Fire-and-forget; each client serializes its own writes.
        _ = BroadcastAsync(RpcEvent.Of("state", status));
    }

    private static Task SendAsync(ClientConnection client, RpcResponse response) =>
        client.WriteLineAsync(JsonSerializer.Serialize(response, JsonOpts));

    private static Task SendEventAsync(ClientConnection client, RpcEvent evt) =>
        client.WriteLineAsync(JsonSerializer.Serialize(evt, JsonOpts));

    /// <summary>Push an event to every connected client. Serialize once, fan out.</summary>
    private async Task BroadcastAsync(RpcEvent evt)
    {
        if (_clients.IsEmpty) return;
        string json = JsonSerializer.Serialize(evt, JsonOpts);
        await Task.WhenAll(_clients.Values.Select(c => c.WriteLineAsync(json))).ConfigureAwait(false);
    }

    public override void Dispose()
    {
        _controller.StatusChanged -= OnStatusChanged;
        _nativeStream.StatusChanged -= OnNativeStreamChanged;
        base.Dispose();
    }

    private static class Sentinel { public static readonly object Unknown = new(); }
}
