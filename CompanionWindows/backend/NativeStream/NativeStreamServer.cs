using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Org.BouncyCastle.Tls;

namespace Longwave.WindowsCompanion.Backend.NativeStream;

/// <summary>
/// Authenticated multi-viewer TCP server for the native stream — the Windows
/// counterpart of <c>MacNativeStreamServer</c>. Every connection runs the
/// TLS-PSK handshake first and joins the viewer set on a valid hello. This
/// host only speaks protocol v2 (multiplexed streams); v1 clients get an error
/// frame.
///
/// It used to be newest-client-wins, so a second viewer ended the first one's
/// session. One capture and one encode per stream now fan out to every viewer
/// subscribed to it, and <see cref="WindowStreamStart"/> /
/// <see cref="WindowStreamStop"/> are reference-counted so the capture side
/// still sees one start and one stop per stream.
/// </summary>
public sealed class NativeStreamServer : IDisposable
{
    public event Action<string>? ClientConnected; // device name
    /// <summary>Every viewer currently connected, in join order.</summary>
    public event Action<IReadOnlyList<string>>? ClientsChanged;
    public event Action<uint>? WindowStreamStart;
    public event Action<uint>? WindowStreamStop;
    public event Action<uint>? FocusWindow;
    public event Action<uint, ushort, ushort>? WindowMouseMove;
    public event Action<uint, NativeStreamProtocol.MouseButton, ushort, ushort>? WindowMouseDown;
    public event Action<uint, NativeStreamProtocol.MouseButton, ushort, ushort>? WindowMouseUp;
    public event Action<uint, ushort, ushort, short, short>? WindowScroll;
    public event Action<ushort, bool>? KeyEvent; // HID usage, isDown

    private const int MaxPendingBytes = 12 * 1024 * 1024;

    private readonly ILogger _log;
    private readonly byte[] _psk;
    private readonly ushort _port;
    private TcpListener? _listener;
    private CancellationTokenSource? _cancel;
    /// Viewers past their handshake, in join order. Guarded by <c>_gate</c>,
    /// which also guards every client's <c>Subscriptions</c>.
    private readonly List<Client> _clients = new();
    private readonly object _gate = new();
    private volatile byte[]? _inventoryFrame;
    /// The last format blob published for each running stream, so a viewer
    /// that subscribes to a stream someone else already started can decode it
    /// without waiting for the capture side to announce the format again
    /// (it never will — the stream is already going).
    private readonly Dictionary<uint, byte[]> _windowFormats = new();
    private byte _mouseStatus = (byte)NativeStreamProtocol.RemoteControlStatus.Disabled;
    private byte _keyboardStatus = (byte)NativeStreamProtocol.RemoteControlStatus.Disabled;

    private sealed class Client : IDisposable
    {
        public required TcpClient Tcp { get; init; }
        public required TlsServerProtocol Tls { get; init; }
        public string? DeviceName;
        public readonly HashSet<uint> Subscriptions = new();
        public readonly HashSet<uint> AwaitingKeyFrame = new();
        public readonly BlockingCollection<byte[]> Outbound = new();
        public int PendingBytes;

        public void Dispose()
        {
            try { Outbound.CompleteAdding(); } catch { }
            try { Tls.Close(); } catch { }
            try { Tcp.Close(); } catch { }
        }
    }

    public NativeStreamServer(ILogger log, string token, ushort port = NativeStreamProtocol.DefaultPort)
    {
        _log = log;
        _psk = NativeStreamCrypto.DerivePsk(token);
        _port = port;
    }

    public void Start()
    {
        _cancel = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.IPv6Any, _port);
        _listener.Server.DualMode = true;
        _listener.Server.NoDelay = true;
        _listener.Start();
        _ = AcceptLoopAsync(_cancel.Token);
        _log.LogInformation("Native stream server listening on {Port}", _port);
    }

    public void Stop()
    {
        _cancel?.Cancel();
        _listener?.Stop();
        Client[] leaving;
        lock (_gate)
        {
            leaving = _clients.ToArray();
            _clients.Clear();
            _windowFormats.Clear();
        }
        foreach (var client in leaving) client.Dispose();
    }

    public void Dispose() => Stop();

    // MARK: Broadcast

    public void PublishInventory(IReadOnlyList<NativeStreamProtocol.WindowInfo> windows)
    {
        var frame = NativeStreamProtocol.EncodeWindowInventory(windows);
        _inventoryFrame = frame;
        SendRequired(frame);
    }

    public void SetInputAvailability(bool mouseAvailable, bool keyboardAvailable)
    {
        _mouseStatus = (byte)(mouseAvailable
            ? NativeStreamProtocol.RemoteControlStatus.Available
            : NativeStreamProtocol.RemoteControlStatus.Disabled);
        _keyboardStatus = (byte)(keyboardAvailable
            ? NativeStreamProtocol.RemoteControlStatus.Available
            : NativeStreamProtocol.RemoteControlStatus.Disabled);
        SendRequired(NativeStreamProtocol.EncodeFrame(
            NativeStreamProtocol.FrameType.MouseStatus, new[] { _mouseStatus }));
        SendRequired(NativeStreamProtocol.EncodeFrame(
            NativeStreamProtocol.FrameType.KeyboardStatus, new[] { _keyboardStatus }));
    }

    public void BroadcastWindowFormat(uint windowId, byte[] parameterSets)
    {
        lock (_gate) { _windowFormats[windowId] = parameterSets; }
        var frame = NativeStreamProtocol.EncodeWindowFormatDescription(
            windowId, NativeStreamProtocol.FormatKind.HevcParameterSets, parameterSets);
        foreach (var client in SubscribersOf(windowId))
        {
            lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Add(windowId); }
            Enqueue(client, frame);
        }
    }

    public void BroadcastWindowFrame(uint windowId, byte[] data, bool isKeyFrame, ulong sequence, ulong ptsNanos)
    {
        var subscribers = SubscribersOf(windowId);
        if (subscribers.Length == 0) return;
        // One encode, one framing, N sockets.
        var frame = NativeStreamProtocol.EncodeWindowVideoFrame(
            windowId, data, isKeyFrame, sequence, ptsNanos);
        foreach (var client in subscribers)
        {
            // Backpressure is per viewer: a headset on a bad link drops
            // frames without stalling anyone else.
            if (Volatile.Read(ref client.PendingBytes) > MaxPendingBytes) continue;
            lock (client.AwaitingKeyFrame)
            {
                if (client.AwaitingKeyFrame.Contains(windowId))
                {
                    if (!isKeyFrame) continue;
                    client.AwaitingKeyFrame.Remove(windowId);
                }
            }
            Enqueue(client, frame);
        }
    }

    public void SendWindowClosed(uint windowId, string? reason)
    {
        Client[] snapshot;
        lock (_gate)
        {
            _windowFormats.Remove(windowId);
            snapshot = _clients.ToArray();
            foreach (var client in snapshot) client.Subscriptions.Remove(windowId);
        }
        var frame = NativeStreamProtocol.EncodeWindowClosed(windowId, reason);
        foreach (var client in snapshot) Enqueue(client, frame);
    }

    private void SendRequired(byte[] frame)
    {
        foreach (var client in Snapshot()) Enqueue(client, frame);
    }

    private Client[] Snapshot()
    {
        lock (_gate) { return _clients.ToArray(); }
    }

    /// <summary>Viewers subscribed to one stream, snapshotted under the lock
    /// that also guards every subscription change.</summary>
    private Client[] SubscribersOf(uint windowId)
    {
        lock (_gate)
        {
            return _clients.Where(c => c.Subscriptions.Contains(windowId)).ToArray();
        }
    }

    /// <summary>How many viewers want this stream — what decides whether the
    /// capture side is told to start or stop it. Caller holds <c>_gate</c>.</summary>
    private int SubscriberCountLocked(uint windowId)
    {
        return _clients.Count(c => c.Subscriptions.Contains(windowId));
    }

    private void Enqueue(Client client, byte[] frame)
    {
        Interlocked.Add(ref client.PendingBytes, frame.Length);
        try
        {
            client.Outbound.Add(frame);
        }
        catch (InvalidOperationException)
        {
            // Outbound completed — client is going away.
            Interlocked.Add(ref client.PendingBytes, -frame.Length);
        }
    }

    // MARK: Accept / receive

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient tcp;
            try
            {
                tcp = await _listener!.AcceptTcpClientAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex)
            {
                _log.LogWarning("Native stream accept failed: {Message}", ex.Message);
                continue;
            }
            tcp.NoDelay = true;
            // Handshake + receive on a dedicated thread — BC's TLS layer and
            // the framed protocol are synchronous, and the viewer count is a
            // handful plus the occasional prober.
            var thread = new Thread(() => ServeClient(tcp, ct)) { IsBackground = true };
            thread.Start();
        }
    }

    private void ServeClient(TcpClient tcp, CancellationToken ct)
    {
        TlsServerProtocol tls;
        try
        {
            tls = NativeStreamCrypto.Accept(tcp.GetStream(), _psk);
        }
        catch (Exception ex)
        {
            _log.LogInformation(ex, "TLS-PSK handshake rejected: {Message}", ex.Message);
            try { tcp.Close(); } catch { }
            return;
        }

        var client = new Client { Tcp = tcp, Tls = tls };
        var writer = new Thread(() => WriteLoop(client)) { IsBackground = true };
        writer.Start();

        var reader = new NativeStreamProtocol.FrameReader();
        var buffer = new byte[64 * 1024];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var read = tls.Stream.Read(buffer, 0, buffer.Length);
                if (read <= 0) break;
                reader.Append(buffer.AsSpan(0, read));
                foreach (var frame in reader.Drain())
                {
                    HandleFrame(client, frame.Type, frame.Payload);
                }
            }
        }
        catch (Exception)
        {
            // Socket torn down / TLS closed — normal disconnect path.
        }
        finally
        {
            Remove(client);
        }
    }

    private void WriteLoop(Client client)
    {
        try
        {
            foreach (var frame in client.Outbound.GetConsumingEnumerable())
            {
                client.Tls.Stream.Write(frame, 0, frame.Length);
                Interlocked.Add(ref client.PendingBytes, -frame.Length);
            }
        }
        catch (Exception)
        {
            Remove(client);
        }
    }

    private void HandleFrame(Client client, NativeStreamProtocol.FrameType type, byte[] payload)
    {
        // Any viewer past its hello may drive the stream and the input: they
        // are all the same authenticated user on the same PC.
        var isActive = IsJoined(client);
        switch (type)
        {
            case NativeStreamProtocol.FrameType.Hello:
            {
                var hello = NativeStreamProtocol.DecodeHello(payload);
                if (hello is null)
                {
                    Enqueue(client, NativeStreamProtocol.EncodeError("Invalid client greeting."));
                    return;
                }
                if ((hello.Version ?? 1) < 2)
                {
                    Enqueue(client, NativeStreamProtocol.EncodeError(
                        "This host requires a newer Longwave (protocol v2)."));
                    return;
                }
                Promote(client, hello.DeviceName);
                break;
            }
            case NativeStreamProtocol.FrameType.KeepAlive:
                break;
            case NativeStreamProtocol.FrameType.WindowStreamStart when isActive:
            {
                if (NativeStreamProtocol.DecodeWindowId(payload) is not { } id) break;
                bool alreadyRunning;
                byte[]? cachedFormat;
                lock (_gate)
                {
                    if (!client.Subscriptions.Add(id)) break;
                    alreadyRunning = SubscriberCountLocked(id) > 1;
                    _windowFormats.TryGetValue(id, out cachedFormat);
                }
                lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Add(id); }
                if (alreadyRunning)
                {
                    // Another viewer already started this stream, so no fresh
                    // format frame is coming — hand over the cached one and let
                    // the key-frame gate hold the decoder until the next IDR.
                    if (cachedFormat is not null)
                    {
                        Enqueue(client, NativeStreamProtocol.EncodeWindowFormatDescription(
                            id, NativeStreamProtocol.FormatKind.HevcParameterSets, cachedFormat));
                    }
                }
                else
                {
                    WindowStreamStart?.Invoke(id);
                }
                break;
            }
            case NativeStreamProtocol.FrameType.WindowStreamStop when isActive:
            {
                if (NativeStreamProtocol.DecodeWindowId(payload) is not { } id) break;
                bool last;
                lock (_gate)
                {
                    if (!client.Subscriptions.Remove(id)) break;
                    last = SubscriberCountLocked(id) == 0;
                }
                lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Remove(id); }
                // Only when the last viewer of this stream lets go.
                if (last) WindowStreamStop?.Invoke(id);
                break;
            }
            case NativeStreamProtocol.FrameType.FocusWindow when isActive:
                if (NativeStreamProtocol.DecodeWindowId(payload) is { } focusId)
                    FocusWindow?.Invoke(focusId);
                break;
            case NativeStreamProtocol.FrameType.WindowMouseMove when isActive:
                if (NativeStreamProtocol.DecodeWindowMouseMove(payload) is { } move)
                    WindowMouseMove?.Invoke(move.WindowId, move.X, move.Y);
                break;
            case NativeStreamProtocol.FrameType.WindowMouseDown when isActive:
                if (NativeStreamProtocol.DecodeWindowMouseButton(payload) is { } down)
                    WindowMouseDown?.Invoke(down.WindowId, down.Button, down.X, down.Y);
                break;
            case NativeStreamProtocol.FrameType.WindowMouseUp when isActive:
                if (NativeStreamProtocol.DecodeWindowMouseButton(payload) is { } up)
                    WindowMouseUp?.Invoke(up.WindowId, up.Button, up.X, up.Y);
                break;
            case NativeStreamProtocol.FrameType.WindowScroll when isActive:
                if (NativeStreamProtocol.DecodeWindowScroll(payload) is { } scroll)
                    WindowScroll?.Invoke(scroll.WindowId, scroll.X, scroll.Y, scroll.DeltaX, scroll.DeltaY);
                break;
            // Legacy (v1) desktop-space mouse frames target the desktop stream.
            case NativeStreamProtocol.FrameType.MouseMove when isActive:
                if (NativeStreamProtocol.DecodeMouseMove(payload) is { } legacyMove)
                    WindowMouseMove?.Invoke(NativeStreamProtocol.DesktopStreamId, legacyMove.X, legacyMove.Y);
                break;
            case NativeStreamProtocol.FrameType.MouseDown when isActive:
                if (NativeStreamProtocol.DecodeMouseButton(payload) is { } legacyDown)
                    WindowMouseDown?.Invoke(
                        NativeStreamProtocol.DesktopStreamId, legacyDown.Button, legacyDown.X, legacyDown.Y);
                break;
            case NativeStreamProtocol.FrameType.MouseUp when isActive:
                if (NativeStreamProtocol.DecodeMouseButton(payload) is { } legacyUp)
                    WindowMouseUp?.Invoke(
                        NativeStreamProtocol.DesktopStreamId, legacyUp.Button, legacyUp.X, legacyUp.Y);
                break;
            case NativeStreamProtocol.FrameType.Scroll when isActive:
                if (NativeStreamProtocol.DecodeScroll(payload) is { } legacyScroll)
                    WindowScroll?.Invoke(
                        NativeStreamProtocol.DesktopStreamId,
                        legacyScroll.X, legacyScroll.Y, legacyScroll.DeltaX, legacyScroll.DeltaY);
                break;
            case NativeStreamProtocol.FrameType.KeyDown when isActive:
                if (NativeStreamProtocol.DecodeKeyEvent(payload) is { } keyDown)
                    KeyEvent?.Invoke(keyDown.KeyCode, true);
                break;
            case NativeStreamProtocol.FrameType.KeyUp when isActive:
                if (NativeStreamProtocol.DecodeKeyEvent(payload) is { } keyUp)
                    KeyEvent?.Invoke(keyUp.KeyCode, false);
                break;
        }
    }

    private bool IsJoined(Client client)
    {
        lock (_gate) { return _clients.Contains(client); }
    }

    private void Promote(Client client, string deviceName)
    {
        string[] names;
        lock (_gate)
        {
            if (_clients.Contains(client)) return;
            client.DeviceName = deviceName;
            _clients.Add(client);
            names = _clients.Select(c => c.DeviceName ?? "Unknown").ToArray();
        }

        Enqueue(client, NativeStreamProtocol.EncodeHelloAck(new NativeStreamProtocol.HelloAck()));
        if (_inventoryFrame is { } inventory)
        {
            Enqueue(client, inventory);
        }
        Enqueue(client, NativeStreamProtocol.EncodeFrame(
            NativeStreamProtocol.FrameType.MouseStatus, new[] { _mouseStatus }));
        Enqueue(client, NativeStreamProtocol.EncodeFrame(
            NativeStreamProtocol.FrameType.KeyboardStatus, new[] { _keyboardStatus }));

        _log.LogInformation("Native stream viewer connected: {Device}", deviceName);
        ClientConnected?.Invoke(deviceName);
        ClientsChanged?.Invoke(names);
    }

    private void Remove(Client client)
    {
        bool wasJoined;
        uint[] orphaned;
        string[] names;
        lock (_gate)
        {
            wasJoined = _clients.Remove(client);
            // Streams this viewer was the last one watching.
            orphaned = client.Subscriptions.Where(id => SubscriberCountLocked(id) == 0).ToArray();
            names = _clients.Select(c => c.DeviceName ?? "Unknown").ToArray();
        }
        client.Dispose();
        if (!wasJoined) return;

        _log.LogInformation("Native stream viewer disconnected: {Device}", client.DeviceName);
        foreach (var id in orphaned) WindowStreamStop?.Invoke(id);
        ClientsChanged?.Invoke(names);
    }
}
