using System.Threading;

namespace VisionVNC.Companion.Shell;

internal static class Program
{
    private const string InstanceMutex = @"Local\VisionVNC.Companion.Shell";
    private const string ShowWindowEvent = @"Local\VisionVNC.Companion.Shell.Show";

    [STAThread]
    private static void Main(string[] args)
    {
        // A second launch shouldn't cost a second tray icon (or a second WebView2) — poke
        // the running instance into surfacing its window and get out of the way.
        using var mutex = new Mutex(initiallyOwned: true, InstanceMutex, out bool isFirst);
        if (!isFirst)
        {
            if (EventWaitHandle.TryOpenExisting(ShowWindowEvent, out var existing))
            {
                using (existing) existing.Set();
            }
            return;
        }

        ApplicationConfiguration.Initialize();

        // --tray starts minimized to the notification area (for a run-at-login entry).
        bool startHidden = args.Any(a => a.Equals("--tray", StringComparison.OrdinalIgnoreCase));
        var context = new TrayContext(showWindowAtStart: !startHidden);

        using var showRequested = new EventWaitHandle(false, EventResetMode.AutoReset, ShowWindowEvent);
        var pump = new Thread(() => WaitForShowRequests(showRequested, context)) { IsBackground = true };
        pump.Start();

        Application.Run(context);
    }

    private static void WaitForShowRequests(EventWaitHandle handle, TrayContext context)
    {
        while (handle.WaitOne())
        {
            try { context.RequestShowWindow(); }
            catch (ObjectDisposedException) { return; }
        }
    }
}
