using System.Runtime;
using System.Runtime.InteropServices;

namespace VisionVNC.Companion.Shell;

/// <summary>
/// After the window closes, the tray is all that's left — but the process still holds the
/// working set it needed to run a browser. Collect, then hand the pages back to Windows.
/// They return from the standby list if the window is reopened.
/// </summary>
internal static class MemoryTrim
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);

    public static void ToIdle()
    {
        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);

        // -1/-1 is the documented "trim to the minimum" request.
        SetProcessWorkingSetSize(GetCurrentProcess(), -1, -1);
    }
}
