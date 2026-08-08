using System.Diagnostics;

namespace VisionVNC.Companion.Shell;

/// <summary>
/// The resident half of the shell: a tray icon and the pipe connection, and nothing else.
/// The window — and with it the whole WebView2 process group — is built when the user asks
/// for it and destroyed when they close it, so the idle cost is this context alone.
/// </summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly PipeClient _client = new();
    private readonly Control _marshal = new();
    private MainForm? _window;

    public TrayContext(bool showWindowAtStart)
    {
        // A handle owned by the UI thread, so off-thread callers have something to post to.
        _marshal.CreateControl();
        _ = _marshal.Handle;

        _tray = new NotifyIcon
        {
            Icon = AppIcon.Load() ?? SystemIcons.Application,
            Text = "VisionVNC Companion",
            Visible = true,
            ContextMenuStrip = BuildMenu(),
        };
        _tray.DoubleClick += (_, _) => ShowWindow();

        _client.ConnectionChanged += OnConnectionChanged;
        _client.Start();
        BackendLauncher.Start();

        if (showWindowAtStart) ShowWindow();
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("&Open VisionVNC Companion", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("&Quit", null, (_, _) => Quit());
        return menu;
    }

    /// <summary>Thread-safe entry point for a second launch asking us to surface.</summary>
    public void RequestShowWindow()
    {
        if (_marshal.IsDisposed) return;
        try { _marshal.BeginInvoke(ShowWindow); }
        catch (ObjectDisposedException) { /* shutting down */ }
        catch (InvalidOperationException) { /* handle gone */ }
    }

    /// <summary>Surface the window, creating it (and the WebView2) if it isn't up.</summary>
    private void ShowWindow()
    {
        if (_window is { IsDisposed: false })
        {
            if (_window.WindowState == FormWindowState.Minimized) _window.WindowState = FormWindowState.Normal;
            _window.Activate();
            return;
        }

        _window = new MainForm(_client);
        _window.FormClosed += (_, _) =>
        {
            _window = null;
            // The window owned the browser processes; with it gone, shrink back to a tray app.
            MemoryTrim.ToIdle();
        };
        _window.Show();
    }

    private void OnConnectionChanged(bool connected)
    {
        // NotifyIcon.Text is capped at 63 chars; ours is nowhere near it.
        var text = connected ? "VisionVNC Companion — backend connected" : "VisionVNC Companion — backend offline";
        try { _tray.Text = text; }
        catch (Exception ex) { Debug.WriteLine($"[shell] tray text failed: {ex.Message}"); }
    }

    private void Quit()
    {
        _tray.Visible = false;
        if (_window is { IsDisposed: false }) _window.Close();
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
            _marshal.Dispose();
            _ = _client.DisposeAsync();
            BackendLauncher.Stop();
        }
        base.Dispose(disposing);
    }
}

/// <summary>Shared icon loading — the tray and the window want the same one.</summary>
internal static class AppIcon
{
    public static Icon? Load()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "VisionVNCCompanion.exe");
            return File.Exists(path) ? Icon.ExtractAssociatedIcon(path) : null;
        }
        catch { return null; }
    }
}
