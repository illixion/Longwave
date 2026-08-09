# WebView2 shell — Electron replacement prototype

A ~600-line C# host that does everything the Electron app did: spawn the backend, bridge
the renderer to the backend's named pipe, and show a window. The web assets are **not
copied** — `Shell.csproj` links `../app/src/renderer/**` into `wwwroot/`, so the UI in this
prototype is byte-identical to the one Electron serves. That is the whole point: swapping
the shell must not touch the UI.

**The resident part is a tray icon, not a browser.** `TrayContext` holds the tray icon and
the pipe connection — that's it. The window, and with it the entire WebView2 process group,
is created when the user asks for it and destroyed when they close it. A settings panel has
no business being a resident 300 MB process, and after this it isn't one.

| Electron                | Here                                                        |
| ----------------------- | ----------------------------------------------------------- |
| `main.js`               | `Program.cs` + `MainForm.cs`                                 |
| `pipe-client.js`        | `PipeClient.cs`                                              |
| `preload.js`            | `bridge.js` (injected via `AddScriptToExecuteOnDocumentCreated`) |
| `ipcRenderer.invoke`    | `chrome.webview.postMessage` + `PostWebMessageAsJson`        |
| `randomToken` in main   | `Tokens.cs` (mirrors the backend alphabet)                    |
| (always-resident)       | `TrayContext.cs` — tray + pipe; the window is transient        |

`bridge.js` reproduces the `window.hotspot` surface the preload exposed, method for method,
so `renderer.js` runs unmodified.

## Running it

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -o out
$env:LONGWAVE_NO_SPAWN = "1"   # talk to an already-running backend instead of spawning one
$env:LONGWAVE_DEVTOOLS = "1"   # F12 in the window
out\LongwaveCompanion.exe
```

The shell is `asInvoker` on purpose — it is the unprivileged half. The backend keeps the
privileged surface and elevates for tethering on its own. The pipe's ACL grants
`InteractiveSid`, so a non-elevated shell reaches an elevated backend.

## Verified on Windows 10 (DESKTOP-B5T7DIS, 2026-08-08)

Against a live backend, with the renderer unmodified:

- The window renders identically to Electron's, including the page's
  `default-src 'self'` CSP — a virtual host mapping (`https://companion.longwave.local/`)
  keeps `'self'` meaningful, and the injected bridge is not subject to the page CSP.
- Read RPCs (`GetStatus`, `ListUpstreamProfiles`, `NativeStreamStatus`), write RPCs
  (`NativeStreamRegenerateToken` — clicked, token changed in the UI *and* the registry),
  local helpers (SSID/passphrase generation), and push events (`Backend: connected`) all work.
- Killing and restarting the backend reconnects the shell automatically.
- Closing the window leaves the tray running with **zero** WebView2 processes; relaunching
  the exe surfaces the existing instance (single-instance mutex + named event) rather than
  starting a second one, and the rebuilt window seeds its status badge from the live pipe.
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

## Measured memory, one open/close cycle

| State                    | Host process | WebView2 procs | Total  |
| ------------------------ | ------------ | -------------- | ------ |
| Window open (just loaded) | 52 MB        | 6 × = 309 MB   | 361 MB |
| Window open (settled)     | 19 MB        | 6 × = 116 MB   | 135 MB |
| **Closed — tray only**    | **20 MB**    | **0**          | **20 MB** |

Closing the window terminates every browser process it started; `MemoryTrim.ToIdle()` then
compacts and returns the working set, so the tray settles at ~20 MB (12.6 MB private).
Reopening rebuilds the WebView2 in a fresh window and reuses the still-connected pipe.

**With the backend at 23.9 MB idle, the whole companion costs ~44 MB at rest** — less than a
resident native UI would, because the expensive part isn't resident at all. WebView2 *is*
Chromium, so while the window is open this is Electron-class; the difference is that it's
only open while someone is looking at it.

The other wins are structural: 566 MB of `node_modules` and the whole Node toolchain leave
the repo, the companion becomes one language, and — the one that keeps paying — **browser
security servicing moves to Microsoft**, so no more chasing Electron CVE bumps. If the
open-window figure ever needs to come down too, the same `PipeClient` backs a native
WinForms/WPF panel; that trades ~3,600 lines of HTML across two branches for ~55 MB open.
