# WebView2 shell — Electron replacement prototype

A ~450-line C# host that does everything the Electron app did: spawn the backend, bridge
the renderer to the backend's named pipe, and show a window. The web assets are **not
copied** — `Shell.csproj` links `../app/src/renderer/**` into `wwwroot/`, so the UI in this
prototype is byte-identical to the one Electron serves. That is the whole point: swapping
the shell must not touch the UI.

| Electron                | Here                                                        |
| ----------------------- | ----------------------------------------------------------- |
| `main.js`               | `Program.cs` + `MainForm.cs`                                 |
| `pipe-client.js`        | `PipeClient.cs`                                              |
| `preload.js`            | `bridge.js` (injected via `AddScriptToExecuteOnDocumentCreated`) |
| `ipcRenderer.invoke`    | `chrome.webview.postMessage` + `PostWebMessageAsJson`        |
| `randomToken` in main   | `Tokens.cs` (mirrors the backend alphabet)                    |

`bridge.js` reproduces the `window.hotspot` surface the preload exposed, method for method,
so `renderer.js` runs unmodified.

## Running it

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -o out
$env:VISIONVNC_NO_SPAWN = "1"   # talk to an already-running backend instead of spawning one
$env:VISIONVNC_DEVTOOLS = "1"   # F12 in the window
out\VisionVNCCompanion.exe
```

The shell is `asInvoker` on purpose — it is the unprivileged half. The backend keeps the
privileged surface and elevates for tethering on its own. The pipe's ACL grants
`InteractiveSid`, so a non-elevated shell reaches an elevated backend.

## Verified on Windows 10 (DESKTOP-B5T7DIS, 2026-08-08)

Against a live backend, with the renderer unmodified:

- The window renders identically to Electron's, including the page's
  `default-src 'self'` CSP — a virtual host mapping (`https://companion.visionvnc.local/`)
  keeps `'self'` meaningful, and the injected bridge is not subject to the page CSP.
- Read RPCs (`GetStatus`, `ListUpstreamProfiles`, `NativeStreamStatus`), write RPCs
  (`NativeStreamRegenerateToken` — clicked, token changed in the UI *and* the registry),
  local helpers (SSID/passphrase generation), and push events (`Backend: connected`) all work.
- Killing and restarting the backend reconnects the shell automatically.
- **WebView2 runtime 151.0.4129.59 was already present** on this Windows 10 box — it arrives
  with Edge. It is not *guaranteed* there the way it is on Windows 11, so a shipping
  installer must still carry the Evergreen bootstrapper (~2 MB) and `MainForm` degrades to a
  "download the runtime" prompt when it is missing.

## Measured cost

| Payload (win-x64)                       | On disk | Compressed |
| --------------------------------------- | ------- | ---------- |
| Backend alone, self-contained            | 107 MB  | —          |
| Backend + shell, self-contained, one dir | 182 MB  | 74 MB      |
| Shell alone, framework-dependent         | 28 MB   | 7.2 MB     |

Publishing both into one directory shares the .NET runtime; the shell's 75 MB delta is the
WindowsDesktop runtime the worker backend doesn't otherwise carry.

**Memory is not the win.** Idle: 49 MB host + 6 WebView2 processes at 313 MB = ~362 MB.
WebView2 *is* Chromium, so this is in the same class as Electron. The real wins are the
566 MB of `node_modules` and the whole Node toolchain leaving the repo, a single language
for the companion, and — the one that keeps paying — **browser security servicing moves to
Microsoft**: no more chasing Electron CVE bumps. If idle RAM ever matters more than keeping
the HTML UI, the same `PipeClient` backs a native WinForms/WPF panel at ~50 MB total.
