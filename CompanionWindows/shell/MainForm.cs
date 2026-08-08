using System.Diagnostics;
using System.Reflection;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace VisionVNC.Companion.Shell;

/// <summary>
/// The whole shell: a WebView2 hosting the companion's web assets, bridged to the
/// backend's named pipe. This is the Electron main process's job in one window.
/// </summary>
internal sealed class MainForm : Form
{
    private const string VirtualHost = "companion.visionvnc.local";
    private const string DownloadUrl = "https://developer.microsoft.com/microsoft-edge/webview2/";

    private readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    private readonly PipeClient _client;
    private bool _bridgeReady;

    /// <summary>The pipe outlives the window — <see cref="TrayContext"/> owns it.</summary>
    public MainForm(PipeClient client)
    {
        _client = client;

        Text = "VisionVNC Hotspot";
        ClientSize = new Size(780, 980);
        MinimumSize = new Size(640 + (Width - ClientSize.Width), 700 + (Height - ClientSize.Height));
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.FromArgb(0x0F, 0x11, 0x17);
        Icon = AppIcon.Load();

        Controls.Add(_web);
    }

    protected override async void OnLoad(EventArgs e)
    {
        base.OnLoad(e);

        if (!EnsureRuntimeInstalled()) { Close(); return; }

        try { await InitializeWebViewAsync(); }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"Could not start the embedded browser.\n\n{ex.Message}",
                "VisionVNC Companion", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
            return;
        }

        _client.ConnectionChanged += OnConnectionChanged;
        _client.Notified += OnNotified;

        // The pipe was already up before this window existed; seed the badge.
        OnConnectionChanged(_client.Connected);
    }

    /// <summary>
    /// WebView2's Evergreen runtime ships with Edge and is preinstalled on Windows 11, but
    /// is *not* guaranteed on Windows 10 — so check before we try, and say something useful.
    /// </summary>
    private bool EnsureRuntimeInstalled()
    {
        try
        {
            var version = CoreWebView2Environment.GetAvailableBrowserVersionString();
            if (!string.IsNullOrEmpty(version)) return true;
        }
        catch (WebView2RuntimeNotFoundException) { }
        catch (Exception ex) { Debug.WriteLine($"[shell] runtime probe failed: {ex.Message}"); }

        var answer = MessageBox.Show(this,
            "The Microsoft Edge WebView2 Runtime is required and was not found on this PC.\n\n" +
            "Open the download page now?",
            "VisionVNC Companion", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (answer == DialogResult.Yes)
        {
            try { Process.Start(new ProcessStartInfo(DownloadUrl) { UseShellExecute = true }); }
            catch { /* nothing more we can do */ }
        }
        return false;
    }

    private async Task InitializeWebViewAsync()
    {
        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VisionVNC", "WebView2");
        Directory.CreateDirectory(userData);

        var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: userData);
        await _web.EnsureCoreWebView2Async(environment);

        var core = _web.CoreWebView2;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsSwipeNavigationEnabled = false;
        core.Settings.AreDevToolsEnabled = Environment.GetEnvironmentVariable("VISIONVNC_DEVTOOLS") == "1";
        _web.DefaultBackgroundColor = Color.FromArgb(0x0F, 0x11, 0x17);

        // Serve the renderer from a virtual origin so the page's `default-src 'self'` CSP
        // behaves exactly as it did under Electron's file:// load.
        var wwwroot = Path.Combine(AppContext.BaseDirectory, "wwwroot");
        core.SetVirtualHostNameToFolderMapping(VirtualHost, wwwroot, CoreWebView2HostResourceAccessKind.DenyCors);

        await core.AddScriptToExecuteOnDocumentCreatedAsync(ReadBridgeScript());
        core.WebMessageReceived += OnWebMessageReceived;

        // Keep external links out of the app frame.
        core.NewWindowRequested += (_, args) =>
        {
            args.Handled = true;
            try { Process.Start(new ProcessStartInfo(args.Uri) { UseShellExecute = true }); }
            catch { /* ignore */ }
        };

        _bridgeReady = true;
        core.Navigate($"https://{VirtualHost}/index.html");
    }

    private static string ReadBridgeScript()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var name = assembly.GetManifestResourceNames().Single(n => n.EndsWith("bridge.js", StringComparison.Ordinal));
        using var stream = assembly.GetManifestResourceStream(name)!;
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    // ---- bridge: renderer -> backend RPC ----

    private async void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonNode? request;
        try { request = JsonNode.Parse(e.WebMessageAsJson); }
        catch { return; }
        if (request is not JsonObject message) return;

        var id = message["id"]?.GetValue<int>();
        if (id is null) return;
        var channel = message["channel"]?.GetValue<string>();
        var method = message["method"]?.GetValue<string>();
        var parameters = message["params"];

        try
        {
            var result = channel switch
            {
                "rpc" when method is not null => await _client.RpcAsync(method, parameters),
                "local" => Local(method),
                _ => throw new InvalidOperationException($"unknown channel: {channel}"),
            };
            Reply(new JsonObject { ["id"] = id, ["result"] = result?.DeepClone() });
        }
        catch (Exception ex)
        {
            Reply(new JsonObject { ["id"] = id, ["error"] = ex.Message });
        }
    }

    private JsonNode? Local(string? method) => method switch
    {
        "gen-passphrase" => JsonValue.Create(Tokens.Passphrase()),
        "gen-ssid" => JsonValue.Create(Tokens.Ssid()),
        "get-connection" => JsonValue.Create(_client.Connected),
        _ => throw new InvalidOperationException($"unknown local method: {method}"),
    };

    // ---- bridge: backend -> renderer events ----

    private void OnConnectionChanged(bool connected) =>
        Reply(new JsonObject { ["event"] = "connection", ["data"] = connected });

    private void OnNotified(string name, JsonNode? data) =>
        Reply(new JsonObject
        {
            ["event"] = "notify",
            ["data"] = new JsonObject { ["event"] = name, ["data"] = data?.DeepClone() },
        });

    private void Reply(JsonObject payload)
    {
        if (!_bridgeReady || IsDisposed) return;
        if (InvokeRequired) { BeginInvoke(() => Reply(payload)); return; }
        try { _web.CoreWebView2?.PostWebMessageAsJson(payload.ToJsonString()); }
        catch (Exception ex) { Debug.WriteLine($"[shell] post failed: {ex.Message}"); }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        base.OnFormClosed(e);
        _bridgeReady = false;
        _client.ConnectionChanged -= OnConnectionChanged;
        _client.Notified -= OnNotified;

        // Explicit: disposing the control tears down the browser, GPU, renderer and utility
        // processes this window brought up. Leaving it to finalization keeps them resident.
        try { _web.Dispose(); }
        catch (Exception ex) { Debug.WriteLine($"[shell] webview dispose: {ex.Message}"); }
    }
}
