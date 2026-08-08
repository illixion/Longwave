using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace VisionVNC.Hotspot.Backend.NativeStream;

/// <summary>
/// Enumerates streamable top-level windows (the Windows counterpart of the
/// Mac coordinator's ScreenCaptureKit inventory) and resolves window IDs back
/// to live HWNDs. Window IDs on the wire are the low 32 bits of the HWND —
/// win32 guarantees handle values fit in 32 bits even on x64.
/// </summary>
public static class WindowInventory
{
    public sealed record Entry(
        uint Id,
        IntPtr Hwnd,
        string Title,
        string AppName,
        RECT Frame,
        bool IsFocused);

    /// <summary>Current streamable windows, front-to-back is not guaranteed.</summary>
    public static List<Entry> Enumerate()
    {
        var entries = new List<Entry>();
        var foreground = GetForegroundWindow();
        var ownPid = Environment.ProcessId;

        EnumWindows((hwnd, _) =>
        {
            if (!IsStreamable(hwnd, ownPid, out var title, out var appName, out var frame))
                return true;
            entries.Add(new Entry(
                Id: HwndToId(hwnd),
                Hwnd: hwnd,
                Title: title,
                AppName: appName,
                Frame: frame,
                IsFocused: hwnd == foreground));
            return true;
        }, IntPtr.Zero);

        return entries;
    }

    public static uint HwndToId(IntPtr hwnd) => unchecked((uint)hwnd.ToInt64());

    /// <summary>The window's visual bounds in physical pixels — what
    /// Windows.Graphics.Capture actually captures (the DWM extended frame,
    /// not the win32 rect with its invisible resize borders).</summary>
    public static RECT? VisualBounds(IntPtr hwnd)
    {
        if (DwmGetWindowAttributeRect(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out var rect, Marshal.SizeOf<RECT>()) == 0)
            return rect;
        return GetWindowRect(hwnd, out var fallback) ? fallback : null;
    }

    private static bool IsStreamable(IntPtr hwnd, int ownPid, out string title, out string appName, out RECT frame)
    {
        title = "";
        appName = "";
        frame = default;

        if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return false;

        // Skip cloaked windows (UWP suspended apps, other virtual desktops).
        if (DwmGetWindowAttributeInt(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            return false;

        var style = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        if ((style & WS_EX_TOOLWINDOW) != 0) return false;

        var length = GetWindowTextLength(hwnd);
        if (length == 0) return false;
        var builder = new StringBuilder(length + 1);
        GetWindowText(hwnd, builder, builder.Capacity);
        title = builder.ToString();
        if (title.Length == 0) return false;

        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == ownPid || pid == 0) return false;

        var bounds = VisualBounds(hwnd);
        if (bounds is null) return false;
        frame = bounds.Value;
        if (frame.Width < 64 || frame.Height < 64) return false;

        try
        {
            using var process = Process.GetProcessById((int)pid);
            appName = process.ProcessName;
        }
        catch
        {
            appName = "";
        }
        return true;
    }

    // MARK: Win32

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
    }

    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TOOLWINDOW = 0x00000080;
    private const int DWMWA_CLOAKED = 14;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")]
    private static extern int DwmGetWindowAttributeRect(IntPtr hwnd, int attribute, out RECT value, int size);

    [DllImport("dwmapi.dll", EntryPoint = "DwmGetWindowAttribute")]
    private static extern int DwmGetWindowAttributeInt(IntPtr hwnd, int attribute, out int value, int size);
}
