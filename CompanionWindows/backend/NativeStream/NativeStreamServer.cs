using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Org.BouncyCastle.Tls;

namespace VisionVNC.Hotspot.Backend.NativeStream;

/// <summary>
/// Authenticated newest-client-wins TCP server for the native stream — the
/// Windows counterpart of <c>MacNativeStreamServer</c>. Every connection runs
/// the TLS-PSK handshake first; a new viewer replaces the active one only
/// after a valid hello. This host only speaks protocol v2 (multiplexed
/// streams); v1 clients get an error frame.
/// </summary>
public sealed class NativeStreamServer : IDisposable
{
    public event Action<string, string?>? ClientActivated; // device name, replaced name
    public event Action? ClientDisconnected;
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
    private Client? _active;
    private readonly object _gate = new();
    private volatile byte[]? _inventoryFrame;
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
        lock (_gate)
        {
            _active?.Dispose();
            _active = null;
        }
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
        Client? client;
        lock (_gate) { client = _active; }
        if (client is null || !client.Subscriptions.Contains(windowId)) return;
        lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Add(windowId); }
        Enqueue(client, NativeStreamProtocol.EncodeWindowFormatDescription(
            windowId, NativeStreamProtocol.FormatKind.HevcParameterSets, parameterSets));
    }

    public void BroadcastWindowFrame(uint windowId, byte[] data, bool isKeyFrame, ulong sequence, ulong ptsNanos)
    {
        Client? client;
        lock (_gate) { client = _active; }
        if (client is null || !client.Subscriptions.Contains(windowId)) return;
        if (Volatile.Read(ref client.PendingBytes) > MaxPendingBytes) return;

        lock (client.AwaitingKeyFrame)
        {
            if (client.AwaitingKeyFrame.Contains(windowId))
            {
                if (!isKeyFrame) return;
                client.AwaitingKeyFrame.Remove(windowId);
            }
        }
        Enqueue(client, NativeStreamProtocol.EncodeWindowVideoFrame(
            windowId, data, isKeyFrame, sequence, ptsNanos));
    }

    public void SendWindowClosed(uint windowId, string? reason)
    {
        Client? client;
        lock (_gate) { client = _active; }
        if (client is null) return;
        client.Subscriptions.Remove(windowId);
        Enqueue(client, NativeStreamProtocol.EncodeWindowClosed(windowId, reason));
    }

    private void SendRequired(byte[] frame)
    {
        Client? client;
        lock (_gate) { client = _active; }
        if (client is null) return;
        Enqueue(client, frame);
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
            // the framed protocol are synchronous, and there's at most one
            // real viewer plus the occasional prober.
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
        var isActive = ReferenceEquals(ActiveClient(), client);
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
                        "This host requires a newer VisionVNC (protocol v2)."));
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
                if (!client.Subscriptions.Add(id)) break;
                lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Add(id); }
                WindowStreamStart?.Invoke(id);
                break;
            }
            case NativeStreamProtocol.FrameType.WindowStreamStop when isActive:
            {
                if (NativeStreamProtocol.DecodeWindowId(payload) is not { } id) break;
                if (!client.Subscriptions.Remove(id)) break;
                lock (client.AwaitingKeyFrame) { client.AwaitingKeyFrame.Remove(id); }
                WindowStreamStop?.Invoke(id);
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

    private Client? ActiveClient()
    {
        lock (_gate) { return _active; }
    }

    private void Promote(Client client, string deviceName)
    {
        Client? previous;
        string? previousName;
        lock (_gate)
        {
            if (ReferenceEquals(_active, client)) return;
            previous = _active;
            previousName = previous?.DeviceName;
            client.DeviceName = deviceName;
            _active = client;
        }

        if (previous is not null)
        {
            Enqueue(previous, NativeStreamProtocol.EncodeReplaced(deviceName));
            // Give the frame a moment to flush, then drop the old viewer.
            var stale = previous;
            Task.Delay(250).ContinueWith(_ => stale.Dispose());
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
        ClientActivated?.Invoke(deviceName, previousName);
    }

    private void Remove(Client client)
    {
        bool wasActive;
        lock (_gate)
        {
            wasActive = ReferenceEquals(_active, client);
            if (wasActive) _active = null;
        }
        client.Dispose();
        if (wasActive)
        {
            _log.LogInformation("Native stream viewer disconnected.");
            ClientDisconnected?.Invoke();
        }
    }
}
