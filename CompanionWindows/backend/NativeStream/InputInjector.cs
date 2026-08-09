using System.Runtime.InteropServices;

namespace Longwave.WindowsCompanion.Backend.NativeStream;

/// <summary>
/// SendInput-based remote control for the native stream: absolute mouse
/// moves/clicks/wheel and HID-usage keyboard events (the server negotiates
/// <c>keyCodeSpace: hidUsage</c>, so the viewer sends raw USB HID keyboard
/// usages and the modifier mask is redundant — modifiers arrive as their own
/// key events). All coordinates are physical pixels; the process runs
/// per-monitor-v2 DPI aware.
/// </summary>
public sealed class InputInjector
{
    /// <summary>Raises and focuses a window so clicks and typing land in it.</summary>
    public static void RaiseWindow(IntPtr hwnd)
    {
        if (IsIconic(hwnd))
        {
            ShowWindow(hwnd, SW_RESTORE);
        }
        // SetForegroundWindow is allowed to fail when another process holds
        // the foreground lock; attaching to the foreground thread's input
        // queue is the standard (documented-adjacent) way to hand focus over.
        var foreground = GetForegroundWindow();
        if (foreground == hwnd) return;
        var targetThread = GetWindowThreadProcessId(hwnd, out _);
        var foregroundThread = foreground != IntPtr.Zero
            ? GetWindowThreadProcessId(foreground, out _)
            : 0;
        if (foregroundThread != 0 && foregroundThread != targetThread)
        {
            AttachThreadInput(foregroundThread, targetThread, true);
            SetForegroundWindow(hwnd);
            AttachThreadInput(foregroundThread, targetThread, false);
        }
        else
        {
            SetForegroundWindow(hwnd);
        }
    }

    /// <summary>Whether `hwnd` is the topmost window at the given screen
    /// point — when it isn't, a click there would land on whatever occludes
    /// it, so the caller should raise the window first.</summary>
    public static bool IsTopmostAt(IntPtr hwnd, int screenX, int screenY)
    {
        var atPoint = WindowFromPoint(new POINT { X = screenX, Y = screenY });
        if (atPoint == IntPtr.Zero) return true;
        var root = GetAncestor(atPoint, GA_ROOT);
        return root == hwnd || atPoint == hwnd;
    }

    public void MouseMove(int screenX, int screenY) =>
        SendMouse(screenX, screenY, MOUSEEVENTF_MOVE);

    public void MouseDown(NativeStreamProtocol.MouseButton button, int screenX, int screenY) =>
        SendMouse(screenX, screenY, MOUSEEVENTF_MOVE | DownFlag(button));

    public void MouseUp(NativeStreamProtocol.MouseButton button, int screenX, int screenY) =>
        SendMouse(screenX, screenY, MOUSEEVENTF_MOVE | UpFlag(button));

    public void Scroll(int screenX, int screenY, int deltaX, int deltaY)
    {
        SendMouse(screenX, screenY, MOUSEEVENTF_MOVE);
        if (deltaY != 0)
        {
            SendMouseData(MOUSEEVENTF_WHEEL, deltaY * WHEEL_DELTA);
        }
        if (deltaX != 0)
        {
            // Horizontal wheel: positive = right.
            SendMouseData(MOUSEEVENTF_HWHEEL, deltaX * WHEEL_DELTA);
        }
    }

    public void Key(ushort hidUsage, bool isDown)
    {
        if (!HidToVirtualKey.TryGetValue(hidUsage, out var vk)) return;
        var input = new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    dwFlags = (isDown ? 0u : KEYEVENTF_KEYUP)
                        | (ExtendedKeys.Contains(vk) ? KEYEVENTF_EXTENDEDKEY : 0u),
                },
            },
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static void SendMouse(int screenX, int screenY, uint flags)
    {
        var virtualLeft = GetSystemMetrics(SM_XVIRTUALSCREEN);
        var virtualTop = GetSystemMetrics(SM_YVIRTUALSCREEN);
        var virtualWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        var virtualHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (virtualWidth <= 1 || virtualHeight <= 1) return;

        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    dx = (int)Math.Round((screenX - virtualLeft) * 65535.0 / (virtualWidth - 1)),
                    dy = (int)Math.Round((screenY - virtualTop) * 65535.0 / (virtualHeight - 1)),
                    dwFlags = flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                },
            },
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static void SendMouseData(uint flags, int data)
    {
        var input = new INPUT
        {
            type = INPUT_MOUSE,
            U = new InputUnion
            {
                mi = new MOUSEINPUT
                {
                    mouseData = data,
                    dwFlags = flags,
                },
            },
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    private static uint DownFlag(NativeStreamProtocol.MouseButton button) => button switch
    {
        NativeStreamProtocol.MouseButton.Right => MOUSEEVENTF_RIGHTDOWN,
        NativeStreamProtocol.MouseButton.Other => MOUSEEVENTF_MIDDLEDOWN,
        _ => MOUSEEVENTF_LEFTDOWN,
    };

    private static uint UpFlag(NativeStreamProtocol.MouseButton button) => button switch
    {
        NativeStreamProtocol.MouseButton.Right => MOUSEEVENTF_RIGHTUP,
        NativeStreamProtocol.MouseButton.Other => MOUSEEVENTF_MIDDLEUP,
        _ => MOUSEEVENTF_LEFTUP,
    };

    /// <summary>USB HID keyboard-page usage → Windows virtual key. Covers the
    /// same physical keys the viewer's key-capture path forwards.</summary>
    private static readonly Dictionary<ushort, ushort> HidToVirtualKey = new()
    {
        // Letters (HID 0x04-0x1D → 'A'-'Z')
        [0x04] = 0x41, [0x05] = 0x42, [0x06] = 0x43, [0x07] = 0x44, [0x08] = 0x45,
        [0x09] = 0x46, [0x0A] = 0x47, [0x0B] = 0x48, [0x0C] = 0x49, [0x0D] = 0x4A,
        [0x0E] = 0x4B, [0x0F] = 0x4C, [0x10] = 0x4D, [0x11] = 0x4E, [0x12] = 0x4F,
        [0x13] = 0x50, [0x14] = 0x51, [0x15] = 0x52, [0x16] = 0x53, [0x17] = 0x54,
        [0x18] = 0x55, [0x19] = 0x56, [0x1A] = 0x57, [0x1B] = 0x58, [0x1C] = 0x59,
        [0x1D] = 0x5A,
        // Digits 1-9,0
        [0x1E] = 0x31, [0x1F] = 0x32, [0x20] = 0x33, [0x21] = 0x34, [0x22] = 0x35,
        [0x23] = 0x36, [0x24] = 0x37, [0x25] = 0x38, [0x26] = 0x39, [0x27] = 0x30,
        // Return, Escape, Backspace, Tab, Space
        [0x28] = 0x0D, [0x29] = 0x1B, [0x2A] = 0x08, [0x2B] = 0x09, [0x2C] = 0x20,
        // -, =, [, ], \, ;, ', `, ,, ., /
        [0x2D] = 0xBD, [0x2E] = 0xBB, [0x2F] = 0xDB, [0x30] = 0xDD, [0x31] = 0xDC,
        [0x33] = 0xBA, [0x34] = 0xDE, [0x35] = 0xC0, [0x36] = 0xBC, [0x37] = 0xBE,
        [0x38] = 0xBF,
        // Caps Lock, F1-F12
        [0x39] = 0x14,
        [0x3A] = 0x70, [0x3B] = 0x71, [0x3C] = 0x72, [0x3D] = 0x73, [0x3E] = 0x74,
        [0x3F] = 0x75, [0x40] = 0x76, [0x41] = 0x77, [0x42] = 0x78, [0x43] = 0x79,
        [0x44] = 0x7A, [0x45] = 0x7B,
        // PrintScreen, ScrollLock, Pause, Insert, Home, PageUp, Delete, End, PageDown
        [0x46] = 0x2C, [0x47] = 0x91, [0x48] = 0x13, [0x49] = 0x2D, [0x4A] = 0x24,
        [0x4B] = 0x21, [0x4C] = 0x2E, [0x4D] = 0x23, [0x4E] = 0x22,
        // Arrows: Right, Left, Down, Up
        [0x4F] = 0x27, [0x50] = 0x25, [0x51] = 0x28, [0x52] = 0x26,
        // Keypad
        [0x53] = 0x90, [0x54] = 0x6F, [0x55] = 0x6A, [0x56] = 0x6D, [0x57] = 0x6B,
        [0x58] = 0x0D, [0x59] = 0x61, [0x5A] = 0x62, [0x5B] = 0x63, [0x5C] = 0x64,
        [0x5D] = 0x65, [0x5E] = 0x66, [0x5F] = 0x67, [0x60] = 0x68, [0x61] = 0x69,
        [0x62] = 0x60, [0x63] = 0x6E,
        // Menu/application key
        [0x65] = 0x5D,
        // Modifiers: LCtrl, LShift, LAlt, LGUI, RCtrl, RShift, RAlt, RGUI.
        // Command (GUI) maps to the Windows key.
        [0xE0] = 0xA2, [0xE1] = 0xA0, [0xE2] = 0xA4, [0xE3] = 0x5B,
        [0xE4] = 0xA3, [0xE5] = 0xA1, [0xE6] = 0xA5, [0xE7] = 0x5C,
    };

    private static readonly HashSet<ushort> ExtendedKeys = new()
    {
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, // nav + arrows
        0x2C, 0x2D, 0x2E, // print screen, insert, delete
        0x5B, 0x5C, 0x5D, // win keys, menu
        0xA3, 0xA5,       // right ctrl, right alt
        0x90, 0x6F,       // num lock, keypad divide
    };

    // MARK: Win32

    private const int INPUT_MOUSE = 0;
    private const int INPUT_KEYBOARD = 1;
    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x1000;
    private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
    private const uint MOUSEEVENTF_ABSOLUTE = 0x8000;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const int WHEEL_DELTA = 120;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;
    private const int SW_RESTORE = 9;
    private const uint GA_ROOT = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool doAttach);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
}
