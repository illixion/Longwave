using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Longwave.WindowsCompanion.Backend.NativeStream;

/// <summary>
/// One Windows.Graphics.Capture source (a monitor for the desktop stream or
/// a single window) delivering BGRA D3D11 textures on a free-threaded frame
/// pool. The delivered texture belongs to the pool — consumers must copy out
/// of it before returning.
/// </summary>
public sealed class CaptureSource : IDisposable
{
    /// <summary>(pool texture, content size, capture time in QPC 100 ns ticks).</summary>
    public event Action<ID3D11Texture2D, SizeInt32, long>? FrameArrived;
    public event Action<string>? Failed;

    private readonly ID3D11Device _device;
    private readonly IDirect3DDevice _winrtDevice;
    private GraphicsCaptureItem? _item;
    private Direct3D11CaptureFramePool? _framePool;
    private GraphicsCaptureSession? _session;
    private SizeInt32 _lastSize;
    private bool _closed;

    public CaptureSource(ID3D11Device device, IDirect3DDevice winrtDevice)
    {
        _device = device;
        _winrtDevice = winrtDevice;
    }

    public SizeInt32 ContentSize => _lastSize;

    public void StartForPrimaryMonitor()
    {
        var monitor = MonitorFromPoint(new POINT { X = 0, Y = 0 }, MONITOR_DEFAULTTOPRIMARY);
        Start(CaptureInterop.CreateItemForMonitor(monitor));
    }

    public void StartForWindow(IntPtr hwnd)
    {
        Start(CaptureInterop.CreateItemForWindow(hwnd));
    }

    private void Start(GraphicsCaptureItem item)
    {
        _item = item;
        _lastSize = item.Size;
        _framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            _winrtDevice,
            DirectXPixelFormat.B8G8R8A8UIntNormalized,
            2,
            item.Size);
        _framePool.FrameArrived += OnFrameArrived;
        item.Closed += OnItemClosed;

        _session = _framePool.CreateCaptureSession(item);
        _session.IsCursorCaptureEnabled = true;
        try
        {
            // Best effort: hide the yellow capture border (needs Win11; may
            // require consent the service doesn't have).
            _session.IsBorderRequired = false;
        }
        catch
        {
            // Border stays; capture still works.
        }
        _session.StartCapture();
    }

    private void OnItemClosed(GraphicsCaptureItem sender, object args)
    {
        Failed?.Invoke("The captured window closed.");
    }

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        if (_closed) return;
        using var frame = sender.TryGetNextFrame();
        if (frame is null) return;

        var contentSize = frame.ContentSize;
        var texture = CaptureInterop.TextureFromSurface(frame.Surface);
        try
        {
            FrameArrived?.Invoke(texture, contentSize, frame.SystemRelativeTime.Ticks);
        }
        finally
        {
            texture.Dispose();
        }

        // A resized window needs a matching pool; recreate once the content
        // outgrows (or shrinks from) the current buffers.
        if (contentSize.Width != _lastSize.Width || contentSize.Height != _lastSize.Height)
        {
            _lastSize = contentSize;
            try
            {
                sender.Recreate(
                    _winrtDevice,
                    DirectXPixelFormat.B8G8R8A8UIntNormalized,
                    2,
                    contentSize);
            }
            catch (Exception ex)
            {
                Failed?.Invoke($"Capture resize failed: {ex.Message}");
            }
        }
    }

    public void Dispose()
    {
        _closed = true;
        if (_framePool is not null) _framePool.FrameArrived -= OnFrameArrived;
        if (_item is not null) _item.Closed -= OnItemClosed;
        _session?.Dispose();
        _framePool?.Dispose();
        _session = null;
        _framePool = null;
        _item = null;
    }

    private const uint MONITOR_DEFAULTTOPRIMARY = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
}

/// <summary>
/// The COM/WinRT plumbing Windows.Graphics.Capture needs outside a UWP app:
/// activating GraphicsCaptureItems from HWND/HMONITOR and unwrapping D3D11
/// textures from capture surfaces.
/// </summary>
public static class CaptureInterop
{
    public static bool IsSupported()
    {
        try { return GraphicsCaptureSession.IsSupported(); }
        catch { return false; }
    }

    /// <summary>The D3D11 device (BGRA + video capable) and its WinRT wrapper
    /// shared by capture and encode.</summary>
    public static (ID3D11Device Device, IDirect3DDevice WinRTDevice) CreateDevice()
    {
        var result = D3D11.D3D11CreateDevice(
            null,
            DriverType.Hardware,
            DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 },
            out ID3D11Device? device);
        result.CheckError();

        // Encoders and capture read/write the same textures from different
        // threads; multithread protection avoids device-context races.
        using (var multithread = device!.ImmediateContext.QueryInterface<ID3D11Multithread>())
        {
            multithread.SetMultithreadProtected(true);
        }

        using var dxgiDevice = device!.QueryInterface<IDXGIDevice>();
        var hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.NativePointer, out var inspectable);
        if (hr != 0)
        {
            device.Dispose();
            throw new InvalidOperationException($"CreateDirect3D11DeviceFromDXGIDevice failed (0x{hr:X8}).");
        }
        var winrtDevice = WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        Marshal.Release(inspectable);
        return (device, winrtDevice);
    }

    public static GraphicsCaptureItem CreateItemForWindow(IntPtr hwnd)
    {
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemGuid;
        var abi = interop.CreateForWindow(hwnd, ref iid);
        var item = GraphicsCaptureItem.FromAbi(abi);
        Marshal.Release(abi);
        return item;
    }

    public static GraphicsCaptureItem CreateItemForMonitor(IntPtr hmonitor)
    {
        var interop = GraphicsCaptureItem.As<IGraphicsCaptureItemInterop>();
        var iid = GraphicsCaptureItemGuid;
        var abi = interop.CreateForMonitor(hmonitor, ref iid);
        var item = GraphicsCaptureItem.FromAbi(abi);
        Marshal.Release(abi);
        return item;
    }

    public static ID3D11Texture2D TextureFromSurface(IDirect3DSurface surface)
    {
        var access = surface.As<IDirect3DDxgiInterfaceAccess>();
        var iid = typeof(ID3D11Texture2D).GUID;
        var pointer = access.GetInterface(ref iid);
        return new ID3D11Texture2D(pointer);
    }

    private static readonly Guid GraphicsCaptureItemGuid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    [ComImport]
    [Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IGraphicsCaptureItemInterop
    {
        IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
        IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
    }

    [ComImport]
    [Guid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDirect3DDxgiInterfaceAccess
    {
        IntPtr GetInterface([In] ref Guid iid);
    }

    [DllImport("d3d11.dll")]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);
}
