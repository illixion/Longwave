using System.Text.Json.Serialization;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Win32;
using Vortice.Direct3D11;
using Windows.Graphics.DirectX.Direct3D11;

namespace VisionVNC.Hotspot.Backend.NativeStream;

/// <summary>
/// Orchestrates native screen streaming on Windows: the TLS-PSK server, the
/// window inventory poll, and one capture→encode pipeline per subscribed
/// stream (stream 0 = the primary monitor, others = individual windows).
/// The Windows counterpart of the Mac companion's
/// MacNativeStreamingController + MacNativeWindowStreamCoordinator.
/// </summary>
public sealed class NativeStreamingService : BackgroundService
{
    private const int MaxStreams = 6;
    private const string RegistryPath = @"SOFTWARE\VisionVNC\Companion";

    private readonly ILogger<NativeStreamingService> _log;
    private readonly object _gate = new();

    private NativeStreamServer? _server;
    private ID3D11Device? _device;
    private IDirect3DDevice? _winrtDevice;
    private readonly InputInjector _input = new();
    private readonly Dictionary<uint, ActiveStream> _streams = new();
    private Dictionary<uint, WindowInventory.Entry> _inventory = new();
    private List<NativeStreamProtocol.WindowInfo> _lastPublished = new();
    private Timer? _inventoryTimer;
    private string? _connectedDevice;
    private string? _lastError;

    public event Action? StatusChanged;

    private sealed class ActiveStream : IDisposable
    {
        public required uint Id { get; init; }
        public IntPtr Hwnd { get; init; }
        public required CaptureSource Capture { get; init; }
        public VideoEncodePipeline? Pipeline;
        public readonly object PipelineGate = new();

        public void Dispose()
        {
            Capture.Dispose();
            lock (PipelineGate)
            {
                Pipeline?.Dispose();
                Pipeline = null;
            }
        }
    }

    public NativeStreamingService(ILogger<NativeStreamingService> log)
    {
        _log = log;
    }

    // MARK: Settings (registry-persisted)

    public bool Enabled
    {
        get => ReadRegistry("NativeStreamEnabled", 0) != 0;
        set => WriteRegistry("NativeStreamEnabled", value ? 1 : 0);
    }

    /// <summary>Unlike the Mac companion (whose extra opt-in mirrors the
    /// macOS Accessibility model), remote control defaults on — the paired
    /// token is the consent gate, and PCVR Desktop View needs input to work
    /// on a clean install.</summary>
    public bool MouseControlEnabled
    {
        get => ReadRegistry("NativeStreamMouseControl", 1) != 0;
        set { WriteRegistry("NativeStreamMouseControl", value ? 1 : 0); PushInputAvailability(); }
    }

    public bool KeyboardControlEnabled
    {
        get => ReadRegistry("NativeStreamKeyboardControl", 1) != 0;
        set { WriteRegistry("NativeStreamKeyboardControl", value ? 1 : 0); PushInputAvailability(); }
    }

    public string Token
    {
        get
        {
            var existing = ReadRegistryString("NativeStreamToken");
            if (!string.IsNullOrEmpty(existing)) return existing;
            var generated = Tokens.Random(20);
            WriteRegistryString("NativeStreamToken", generated);
            return generated;
        }
    }

    public string RegenerateToken()
    {
        var token = Tokens.Random(20);
        WriteRegistryString("NativeStreamToken", token);
        if (IsRunning)
        {
            StopServer();
            StartServer();
        }
        StatusChanged?.Invoke();
        return token;
    }

    public bool IsRunning
    {
        get { lock (_gate) { return _server is not null; } }
    }

    public NativeStreamStatus GetStatus() => new()
    {
        Enabled = Enabled,
        Running = IsRunning,
        Port = NativeStreamProtocol.DefaultPort,
        Token = Token,
        ConnectedDevice = _connectedDevice,
        LastError = _lastError,
        MouseControlEnabled = MouseControlEnabled,
        KeyboardControlEnabled = KeyboardControlEnabled,
        CaptureSupported = CaptureInterop.IsSupported(),
    };

    public void SetEnabled(bool enabled)
    {
        Enabled = enabled;
        if (enabled) StartServer();
        else StopServer();
        StatusChanged?.Invoke();
    }

    // MARK: Lifecycle

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (Enabled)
        {
            StartServer();
        }
        stoppingToken.Register(StopServer);
        return Task.CompletedTask;
    }

    private void StartServer()
    {
        lock (_gate)
        {
            if (_server is not null) return;
            if (!CaptureInterop.IsSupported())
            {
                _lastError = "Windows.Graphics.Capture is unavailable on this machine.";
                _log.LogWarning("{Error}", _lastError);
                return;
            }
            _lastError = null;
            try
            {
                var server = new NativeStreamServer(_log, Token);
                server.ClientActivated += OnClientActivated;
                server.ClientDisconnected += OnClientDisconnected;
                server.WindowStreamStart += OnWindowStreamStart;
                server.WindowStreamStop += id => StopStream(id);
                server.FocusWindow += OnFocusWindow;
                server.WindowMouseMove += OnWindowMouseMove;
                server.WindowMouseDown += OnWindowMouseDown;
                server.WindowMouseUp += OnWindowMouseUp;
                server.WindowScroll += OnWindowScroll;
                server.KeyEvent += OnKeyEvent;
                server.Start();
                _server = server;
            }
            catch (Exception ex)
            {
                _lastError = $"Native stream server failed to start: {ex.Message}";
                _log.LogError(ex, "Native stream server failed to start");
            }
        }
        StatusChanged?.Invoke();
    }

    private void StopServer()
    {
        lock (_gate)
        {
            _inventoryTimer?.Dispose();
            _inventoryTimer = null;
            foreach (var stream in _streams.Values) stream.Dispose();
            _streams.Clear();
            _server?.Dispose();
            _server = null;
            _device?.Dispose();
            _device = null;
            _winrtDevice = null;
            _connectedDevice = null;
        }
        StatusChanged?.Invoke();
    }

    private void OnClientActivated(string deviceName, string? replaced)
    {
        lock (_gate)
        {
            _connectedDevice = deviceName;
            // Fresh viewer, fresh subscriptions — drop any leftover streams.
            foreach (var stream in _streams.Values) stream.Dispose();
            _streams.Clear();
            _lastPublished = new List<NativeStreamProtocol.WindowInfo>();
            _inventoryTimer ??= new Timer(_ => PollInventory(), null, 0, 1000);
        }
        PushInputAvailability();
        StatusChanged?.Invoke();
    }

    private void OnClientDisconnected()
    {
        lock (_gate)
        {
            _connectedDevice = null;
            _inventoryTimer?.Dispose();
            _inventoryTimer = null;
            foreach (var stream in _streams.Values) stream.Dispose();
            _streams.Clear();
        }
        StatusChanged?.Invoke();
    }

    private void PushInputAvailability()
    {
        lock (_gate)
        {
            _server?.SetInputAvailability(MouseControlEnabled, KeyboardControlEnabled);
        }
    }

    // MARK: Inventory

    private void PollInventory()
    {
        List<WindowInventory.Entry> entries;
        try
        {
            entries = WindowInventory.Enumerate();
        }
        catch (Exception ex)
        {
            _log.LogWarning("Window inventory failed: {Message}", ex.Message);
            return;
        }

        var published = entries.Select(e => new NativeStreamProtocol.WindowInfo
        {
            Id = e.Id,
            Title = e.Title,
            AppName = e.AppName,
            Width = e.Frame.Width,
            Height = e.Frame.Height,
            IsFocused = e.IsFocused,
        }).ToList();

        NativeStreamServer? server;
        List<uint> vanished = new();
        lock (_gate)
        {
            _inventory = entries.ToDictionary(e => e.Id);
            server = _server;
            foreach (var id in _streams.Keys)
            {
                if (id != NativeStreamProtocol.DesktopStreamId && !_inventory.ContainsKey(id))
                {
                    vanished.Add(id);
                }
            }
        }

        foreach (var id in vanished)
        {
            StopStream(id);
            server?.SendWindowClosed(id, "The window left the screen.");
        }

        if (server is not null && !published.SequenceEqual(_lastPublished))
        {
            _lastPublished = published;
            server.PublishInventory(published);
        }
    }

    // MARK: Streams

    private void OnWindowStreamStart(uint windowId)
    {
        lock (_gate)
        {
            if (_server is null || _streams.ContainsKey(windowId)) return;
            if (_streams.Count >= MaxStreams)
            {
                _server.SendWindowClosed(windowId, $"Window stream limit reached ({MaxStreams}).");
                return;
            }

            IntPtr hwnd = IntPtr.Zero;
            if (windowId != NativeStreamProtocol.DesktopStreamId)
            {
                if (!_inventory.TryGetValue(windowId, out var entry))
                {
                    // First subscription can beat the first poll; look it up.
                    var fresh = WindowInventory.Enumerate().FirstOrDefault(e => e.Id == windowId);
                    if (fresh is null)
                    {
                        _server.SendWindowClosed(windowId, "The window is no longer on screen.");
                        return;
                    }
                    _inventory[windowId] = fresh;
                    entry = fresh;
                }
                hwnd = entry.Hwnd;
            }

            try
            {
                if (_device is null)
                {
                    (_device, _winrtDevice) = CaptureInterop.CreateDevice();
                }
                var capture = new CaptureSource(_device!, _winrtDevice!);
                var stream = new ActiveStream { Id = windowId, Hwnd = hwnd, Capture = capture };
                capture.FrameArrived += (texture, size, qpc) => OnCaptureFrame(stream, texture, size.Width, size.Height, qpc);
                capture.Failed += message =>
                {
                    StopStream(windowId);
                    lock (_gate) { _server?.SendWindowClosed(windowId, message); }
                };
                if (windowId == NativeStreamProtocol.DesktopStreamId)
                {
                    capture.StartForPrimaryMonitor();
                }
                else
                {
                    capture.StartForWindow(hwnd);
                }
                _streams[windowId] = stream;
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Failed to start stream {Id}", windowId);
                _server.SendWindowClosed(windowId, $"Capture failed: {ex.Message}");
            }
        }
    }

    private void StopStream(uint windowId)
    {
        ActiveStream? stream;
        lock (_gate)
        {
            if (!_streams.Remove(windowId, out stream)) return;
        }
        stream!.Dispose();
    }

    private void OnCaptureFrame(ActiveStream stream, ID3D11Texture2D texture, int width, int height, long qpc)
    {
        lock (stream.PipelineGate)
        {
            var pipeline = stream.Pipeline;
            if (pipeline is null || pipeline.Width != (width & ~1) || pipeline.Height != (height & ~1))
            {
                pipeline?.Dispose();
                try
                {
                    var pixelArea = (double)width * height;
                    var ceiling = stream.Id == NativeStreamProtocol.DesktopStreamId ? 24_000_000 : 15_000_000;
                    var bitrate = (int)Math.Max(3_000_000, Math.Min(ceiling, pixelArea * 4));
                    pipeline = new VideoEncodePipeline(_device!, width, height, bitrate);
                    var streamId = stream.Id;
                    pipeline.ParameterSetsChanged += sets =>
                    {
                        lock (_gate) { _server?.BroadcastWindowFormat(streamId, sets); }
                    };
                    pipeline.EncodedFrame += (data, isKey, seq, pts) =>
                    {
                        lock (_gate) { _server?.BroadcastWindowFrame(streamId, data, isKey, seq, pts); }
                    };
                    pipeline.Diagnostic += message =>
                        _log.LogInformation("Stream {Id} diag: {Message}", streamId, message);
                    pipeline.Failed += message =>
                    {
                        _log.LogError("Stream {Id} encode failed: {Message}", streamId, message);
                        StopStream(streamId);
                        lock (_gate) { _server?.SendWindowClosed(streamId, message); }
                    };
                    stream.Pipeline = pipeline;
                }
                catch (Exception ex)
                {
                    _log.LogError(ex, "Encoder pipeline creation failed for stream {Id}", stream.Id);
                    var streamId = stream.Id;
                    StopStream(streamId);
                    lock (_gate) { _server?.SendWindowClosed(streamId, $"Encoder unavailable: {ex.Message}"); }
                    return;
                }
            }
            pipeline.Submit(texture, width, height, qpc);
        }
    }

    // MARK: Input

    private (int X, int Y)? ToScreen(uint windowId, ushort x, ushort y)
    {
        if (windowId == NativeStreamProtocol.DesktopStreamId)
        {
            // Primary-monitor capture: stream pixels are physical pixels with
            // the monitor's origin at (0,0).
            return (x, y);
        }
        lock (_gate)
        {
            if (!_inventory.TryGetValue(windowId, out var entry)) return null;
            var bounds = WindowInventory.VisualBounds(entry.Hwnd) ?? entry.Frame;
            return (bounds.Left + x, bounds.Top + y);
        }
    }

    private IntPtr HwndFor(uint windowId)
    {
        lock (_gate)
        {
            return _inventory.TryGetValue(windowId, out var entry) ? entry.Hwnd : IntPtr.Zero;
        }
    }

    private void OnFocusWindow(uint windowId)
    {
        if (!MouseControlEnabled && !KeyboardControlEnabled) return;
        var hwnd = HwndFor(windowId);
        if (hwnd != IntPtr.Zero) InputInjector.RaiseWindow(hwnd);
    }

    private void OnWindowMouseMove(uint windowId, ushort x, ushort y)
    {
        if (!MouseControlEnabled) return;
        if (ToScreen(windowId, x, y) is { } point) _input.MouseMove(point.X, point.Y);
    }

    private void OnWindowMouseDown(uint windowId, NativeStreamProtocol.MouseButton button, ushort x, ushort y)
    {
        if (!MouseControlEnabled) return;
        if (ToScreen(windowId, x, y) is not { } point) return;
        if (windowId != NativeStreamProtocol.DesktopStreamId)
        {
            var hwnd = HwndFor(windowId);
            if (hwnd != IntPtr.Zero && !InputInjector.IsTopmostAt(hwnd, point.X, point.Y))
            {
                InputInjector.RaiseWindow(hwnd);
            }
        }
        _input.MouseDown(button, point.X, point.Y);
    }

    private void OnWindowMouseUp(uint windowId, NativeStreamProtocol.MouseButton button, ushort x, ushort y)
    {
        if (!MouseControlEnabled) return;
        if (ToScreen(windowId, x, y) is { } point) _input.MouseUp(button, point.X, point.Y);
    }

    private void OnWindowScroll(uint windowId, ushort x, ushort y, short deltaX, short deltaY)
    {
        if (!MouseControlEnabled) return;
        if (ToScreen(windowId, x, y) is { } point) _input.Scroll(point.X, point.Y, deltaX, deltaY);
    }

    private void OnKeyEvent(ushort hidUsage, bool isDown)
    {
        if (!KeyboardControlEnabled) return;
        _input.Key(hidUsage, isDown);
    }

    // MARK: Registry helpers

    private static int ReadRegistry(string name, int fallback)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(name) is int value ? value : fallback;
        }
        catch { return fallback; }
    }

    private static void WriteRegistry(string name, int value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        key.SetValue(name, value, RegistryValueKind.DWord);
    }

    private static string? ReadRegistryString(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(name) as string;
        }
        catch { return null; }
    }

    private static void WriteRegistryString(string name, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        key.SetValue(name, value, RegistryValueKind.String);
    }
}

public sealed record NativeStreamStatus
{
    [JsonPropertyName("enabled")] public bool Enabled { get; init; }
    [JsonPropertyName("running")] public bool Running { get; init; }
    [JsonPropertyName("port")] public int Port { get; init; }
    [JsonPropertyName("token")] public string Token { get; init; } = "";
    [JsonPropertyName("connectedDevice")] public string? ConnectedDevice { get; init; }
    [JsonPropertyName("lastError")] public string? LastError { get; init; }
    [JsonPropertyName("mouseControlEnabled")] public bool MouseControlEnabled { get; init; }
    [JsonPropertyName("keyboardControlEnabled")] public bool KeyboardControlEnabled { get; init; }
    [JsonPropertyName("captureSupported")] public bool CaptureSupported { get; init; }
}
