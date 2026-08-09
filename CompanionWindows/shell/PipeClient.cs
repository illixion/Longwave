using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Longwave.Companion.Shell;

/// <summary>
/// Newline-delimited JSON-RPC client over the backend's named pipe — the C# twin of the
/// Electron app's pipe-client.js. Auto-reconnects, surfaces server push notifications,
/// and exposes <see cref="RpcAsync"/>.
/// </summary>
internal sealed class PipeClient : IAsyncDisposable
{
    private const string PipeName = "longwave-hotspot";
    private static readonly TimeSpan RpcTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan ReconnectDelay = TimeSpan.FromSeconds(1);

    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonNode?>> _pending = new();
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    private NamedPipeClientStream? _pipe;
    private int _nextId;
    private volatile bool _connected;

    /// <summary>Raised with the new state whenever the pipe connects or drops.</summary>
    public event Action<bool>? ConnectionChanged;

    /// <summary>Raised for server-pushed <c>{"event":…,"data":…}</c> messages.</summary>
    public event Action<string, JsonNode?>? Notified;

    public bool Connected => _connected;

    public void Start() => _ = Task.Run(RunAsync);

    private async Task RunAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            try
            {
                var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(_stop.Token).ConfigureAwait(false);
                _pipe = pipe;
                SetConnected(true);
                await ReadLoopAsync(pipe).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                // Backend not up yet, or the pipe dropped — fall through and retry.
            }

            SetConnected(false);
            FailPending("pipe closed");
            _pipe = null;

            try { await Task.Delay(ReconnectDelay, _stop.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task ReadLoopAsync(NamedPipeClientStream pipe)
    {
        var buffer = new byte[16 * 1024];
        var pendingText = new StringBuilder();

        while (!_stop.IsCancellationRequested)
        {
            int read = await pipe.ReadAsync(buffer.AsMemory(), _stop.Token).ConfigureAwait(false);
            if (read <= 0) return; // EOF — server closed.

            pendingText.Append(Encoding.UTF8.GetString(buffer, 0, read));
            var text = pendingText.ToString();
            int newline;
            while ((newline = text.IndexOf('\n')) >= 0)
            {
                var line = text[..newline].Trim();
                text = text[(newline + 1)..];
                if (line.Length > 0) Dispatch(line);
            }
            pendingText.Clear();
            pendingText.Append(text);
        }
    }

    private void Dispatch(string line)
    {
        JsonNode? msg;
        try { msg = JsonNode.Parse(line); }
        catch { return; }
        if (msg is not JsonObject obj) return;

        if (obj.TryGetPropertyValue("event", out var evt) && evt is not null)
        {
            obj.TryGetPropertyValue("data", out var data);
            Notified?.Invoke(evt.GetValue<string>(), data?.DeepClone());
            return;
        }

        if (!obj.TryGetPropertyValue("id", out var idNode) || idNode is null) return;
        if (!_pending.TryRemove(idNode.GetValue<int>(), out var tcs)) return;

        if (obj.TryGetPropertyValue("error", out var error) && error is JsonObject errObj)
        {
            var code = errObj["code"]?.ToString() ?? "error";
            var message = errObj["message"]?.ToString() ?? "backend error";
            tcs.TrySetException(new InvalidOperationException($"{code}: {message}"));
            return;
        }

        obj.TryGetPropertyValue("result", out var result);
        tcs.TrySetResult(result?.DeepClone());
    }

    public async Task<JsonNode?> RpcAsync(string method, JsonNode? parameters)
    {
        var pipe = _pipe;
        if (!_connected || pipe is null) throw new InvalidOperationException("backend not connected");

        int id = Interlocked.Increment(ref _nextId);
        var tcs = new TaskCompletionSource<JsonNode?>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;

        var request = new JsonObject { ["id"] = id, ["method"] = method };
        if (parameters is not null) request["params"] = parameters.DeepClone();

        try
        {
            var bytes = Encoding.UTF8.GetBytes(request.ToJsonString(JsonSerializerOptions.Default) + "\n");
            await _writeLock.WaitAsync(_stop.Token).ConfigureAwait(false);
            try { await pipe.WriteAsync(bytes, _stop.Token).ConfigureAwait(false); }
            finally { _writeLock.Release(); }
        }
        catch
        {
            _pending.TryRemove(id, out _);
            throw;
        }

        using var timeout = new CancellationTokenSource(RpcTimeout);
        var completed = await Task.WhenAny(tcs.Task, Task.Delay(Timeout.Infinite, timeout.Token)).ConfigureAwait(false);
        if (completed != tcs.Task)
        {
            _pending.TryRemove(id, out _);
            throw new TimeoutException($"RPC timeout: {method}");
        }
        return await tcs.Task.ConfigureAwait(false);
    }

    private void SetConnected(bool value)
    {
        if (_connected == value) return;
        _connected = value;
        ConnectionChanged?.Invoke(value);
    }

    private void FailPending(string reason)
    {
        foreach (var key in _pending.Keys)
        {
            if (_pending.TryRemove(key, out var tcs)) tcs.TrySetException(new InvalidOperationException(reason));
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync().ConfigureAwait(false);
        _pipe?.Dispose();
        _stop.Dispose();
        _writeLock.Dispose();
    }
}
