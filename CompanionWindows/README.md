# VisionVNC Windows Companion

Turns a **Windows host into a NAT'd Wi-Fi access point** that a Vision Pro joins directly,
so the headset and host get a direct, low-latency link **even on networks with client-to-client
(AP) isolation** — cafés, hotels, conference Wi-Fi. From the venue's view there's a single
client (the Windows PC); the Vision Pro rides behind the PC's NAT, keeping internet **and**
gaining a path to the local Sunshine/VNC server at the AP gateway (`192.168.137.1`).

This is the Windows analogue of Apple's Mac Virtual Display P2P link, and it also hosts
**native screen streaming** — the same encrypted protocol the macOS companion serves on
port 4857, so VisionVNC's *Native* connection type works against a Windows host too
(opaque desktop or individual windows as their own visionOS windows, with remote mouse
and keyboard). It's a **separate codebase** (Node + .NET) sibling to the macOS companion
(`CompanionMac/`); it mirrors that companion's conventions but shares no compiled code.

> **Status: working PoC, validated end-to-end on real hardware.** A device joined the hotspot,
> received a DHCP lease, and had working internet through the host's NAT (see
> [Verification](#verification)).

## Architecture

```
┌───────────────────────────── Windows host ─────────────────────────────┐
│  Electron app (requireAdministrator, interactive user)                  │
│    renderer (UI)  ──contextBridge/IPC──  main process                   │
│                                │                                         │
│                  named pipe \\.\pipe\visionvnc-hotspot (ACL'd)           │
│                                ▼                                         │
│  ┌────────────────────────────────────────────────────────────┐        │
│  │  Privileged backend  (C# / .NET 8, WinRT via CsWinRT)        │        │
│  │   • TetheringController → NetworkOperatorTetheringManager    │        │
│  │       (SoftAP/Wi-Fi-Direct-GO + DHCP + NAT/ICS, bundled)     │        │
│  │   • PipeServer (newline-delimited JSON-RPC + push events)    │        │
│  └────────────────────────────────────────────────────────────┘        │
│  Upstream: Ethernet or Wi-Fi (STA)  ──► NAT ──►  VisionVNC AP           │
└──────────────────────────────────────────────────────────────────────┬─┘
                                                                         │ Wi-Fi
                                            joins SSID + 8-char password │
                                                                         ▼
                                                        ┌──────────────────────────┐
                                                        │  Vision Pro                │
                                                        │  gets 192.168.137.x lease  │
                                                        │  → VisionVNC connects to    │
                                                        │    192.168.137.1 (gateway)  │
                                                        └──────────────────────────┘
```

**Why the Mobile Hotspot API (`NetworkOperatorTetheringManager`)** over `netsh`/Hosted Network +
manual ICS: it bundles the SoftAP, a DHCP server, NAT, and internet-connection-sharing of a
chosen upstream into one supported WinRT API. Trade-offs: ~8-client cap, band-only control, and
a driver SoftAP/Wi-Fi-Direct-GO dependency (see [Hardware requirements](#hardware-requirements)).

## Layout

```
CompanionWindows/
├── backend/            # .NET 8 worker — TetheringController, PipeServer, MonitorService
├── app/                # Electron (main + preload + renderer), electron-builder NSIS config
├── spike/              # Step-1 capability spike + SPIKE-FINDINGS.md (the decision record)
└── README.md
```

## Hardware requirements

The host needs a **Wi-Fi adapter whose driver exposes SoftAP or Wi-Fi-Direct-GO**. Check with:

```powershell
netsh wlan show wirelesscapabilities   # look for "Soft AP" / "Wi-Fi Direct GO : Supported"
```

Findings from the validation machine (see `spike/SPIKE-FINDINGS.md` for the full record):

- The built-in **Broadcom 802.11ac** adapter is **Station-only** — it cannot host an AP at all
  (`Soft AP: Not supported`, `Wi-Fi Direct GO: Not supported`). `StartTetheringAsync` always
  returns `WiFiDeviceOff` on it.
- A **TP-Link Archer T2U-series USB adapter** (RTL8811AU) reports `Wi-Fi Direct GO: Supported`
  (no SoftAP, 2.4 GHz only, ~2 clients) and **does** host the hotspot via GO. It needs a
  **cold-start retry** — the GO radio reports `WiFiDeviceOff` on the first one or two attempts
  after being idle, then succeeds; the backend retries automatically (4×, 2.5 s apart).

**Multiple Wi-Fi adapters — usually fine.** The Mobile Hotspot API doesn't let you *choose* the
host radio, but testing showed **Windows reliably selects the SoftAP/GO-capable adapter on its
own** — even with an incapable Station-only adapter enabled *and connected*. In that config the AP
started first-try on the capable adapter and the incapable adapter's station link was untouched.
So **disabling the other adapter is not normally required.** (An early belief that it was needed
turned out to be a misattribution: the real cause of the initial failures was the USB radio's
**cold-start warm-up** — see below — not adapter selection.)

**Fallback safety net (rare):** if some driver/machine *does* let Windows pick an incapable radio,
`StartHotspot` fails with status **`adapterConflict`** and the UI offers a **"Disable conflicting
adapter & retry"** button → `PrepareApAdapter` disables the incapable adapter(s) and re-enables
them on `StopHotspot`. `ListWifiAdapters` exposes each adapter's `canHostAp`. This path was
validated mechanically but is not expected in normal operation.

## Install (prebuilt)

Most people don't need to build this. Download the installer for your CPU from the repo's
[Releases](../../releases) page and run it — the .NET backend is bundled, so no
toolchain or compilation is required. Both are built natively:

- `VisionVNCHotspotCompanion-…-x64-Setup.exe` — Intel / AMD
- `VisionVNCHotspotCompanion-…-arm64-Setup.exe` — Windows on ARM (Snapdragon X-class)

CI builds the installers and emits a **signed build-provenance attestation**. Verify the
download was produced by this repo's workflow and not tampered with:

```bash
gh attestation verify VisionVNCHotspotCompanion-<version>-<arch>-Setup.exe --repo illixion/VisionVNC
```

The installer is **unsigned** (no code-signing cert), so SmartScreen may warn on first run;
the attestation is the integrity guarantee. Still **Beta** — re-read the hardware caveats above.

## Build (from source)

Prereqs: **.NET 8 SDK**, **Node.js LTS**. (Installed on the validation box via winget:
`Microsoft.DotNet.SDK.8`, `OpenJS.NodeJS.LTS`.)

```powershell
# Backend (framework-dependent build for dev)
cd backend
dotnet build -c Release

# Backend (self-contained publish — what the installer bundles)
dotnet publish -c Release -r win-x64 --self-contained true `
  -o bin\Release\net8.0-windows10.0.22621.0\publish

# Electron app
cd ..\app
npm install
npm start            # dev run (expects a backend; see below)

# Installer (NSIS) — bundles the published backend under resources\backend
npm run dist         # -> app\dist\VisionVNC Hotspot Companion Setup <ver>.exe
```

## Run

Two deployment shapes share one backend binary (`Microsoft.Extensions.Hosting`, detects which):

1. **Elevated interactive-session helper (PoC default).** The `requireAdministrator` Electron app
   spawns the bundled backend as a child (it inherits elevation). No Windows service. This
   side-steps the unresolved Session-0 question (see [Elevation](#elevation)). Just run the
   installed app.
2. **Windows Service (optional, future).** The backend can be hosted by the SCM
   (`AddWindowsService`). Register it once Session-0 tethering is validated — see the commented
   `sc.exe` lines in `app/build/installer.nsh`, and set `VISIONVNC_NO_SPAWN=1` for the app so it
   connects to the service instead of spawning its own.

Dev tips:
- Run the backend standalone: `backend\bin\Release\net8.0-windows10.0.22621.0\VisionVNCHotspotBackend.exe`
- Run the app against it without spawning: `setx`-free `$env:VISIONVNC_NO_SPAWN=1; npm start`
- Capability check only: `VisionVNCHotspotBackend.exe --probe`
- Handy pipe-client scripts: `backend\test-client.js`, `start-hold.js`, `stop.js` (Node).

## IPC protocol

Newline-delimited JSON over `\\.\pipe\visionvnc-hotspot`. The pipe ACL grants the interactive
desktop user + the process owner + Administrators + SYSTEM, and denies everyone else (the backend
is privileged — an open pipe would be a local privilege-escalation vector).

- **Requests** `{ "id", "method", "params"? }` → **responses** `{ "id", "result" | "error" }`
- **Methods:** `GetStatus`, `ListUpstreamProfiles`, `StartHotspot{ssid?,passphrase?,band?,profileId?}`,
  `StopHotspot`, `ListWifiAdapters`, `PrepareApAdapter`, `GetClients`, `NativeStreamStatus`,
  `NativeStreamSetEnabled{enabled}`, `NativeStreamSetInput{mouse?,keyboard?}`,
  `NativeStreamRegenerateToken`, `Ping`
- **Push events** `{ "event":"state", "data": <HotspotStatus> }` on state/client-count changes
  (driven by `MonitorService`, polling every 2 s) and `{ "event":"nativeStream", "data":
  <NativeStreamStatus> }` on streaming state changes

`HotspotStatus` carries `state` (off/on/inTransition), `ssid`, `passphrase`, `band`, `gatewayIp`,
`clientCount`/`maxClientCount`, `upstreamName`/`upstreamKind`, `canHostAp`, `capabilityDetail`.

## Native screen streaming

`backend/NativeStream/` serves VisionVNC's framed native-stream protocol (protocol v2) on
TCP 4857 — the same wire format `CompanionMac` speaks, so the headset's *Native* connection
type works unchanged against a Windows host:

- **Transport:** TLS 1.2 external PSK (`TLS_PSK_WITH_AES_128_GCM_SHA256`), PSK derived
  HKDF-SHA256 from the access token shown in the UI. SChannel exposes no PSK ciphersuites,
  so the handshake runs on BouncyCastle. Newest authenticated viewer wins.
- **Capture:** Windows.Graphics.Capture — the primary monitor is stream 0; every streamable
  top-level window is published in a 1 s inventory and can be streamed individually
  (Unity-style per-window visionOS scenes).
- **Encode:** GPU-only — hardware HEVC MFT (async model), fed BGRA directly where the driver
  allows (NVIDIA) or through the Video Processor MFT (BGRA→NV12) otherwise. Streams are
  opaque (no alpha); the format rides the wire as Annex-B VPS/SPS/PPS
  (`hevcParameterSets`), samples as 4-byte length-prefixed NALs. 60 fps cap, 1 s keyframes,
  area-scaled bitrate, six concurrent streams max.
- **Input:** SendInput — absolute mouse (physical pixels; the process is per-monitor-v2 DPI
  aware), wheel, and keyboard from raw HID usages (the server negotiates
  `keyCodeSpace: hidUsage`). Clicks on an occluded streamed window raise it first. Mouse and
  keyboard control default **on** — the paired token is the consent gate — and can be
  disabled in the UI.
- **Settings** persist under `HKCU\SOFTWARE\VisionVNC\Companion` (token, enabled, input
  toggles).

Requires Windows 10 2004+ for Windows.Graphics.Capture and a hardware HEVC encoder
(NVIDIA/Intel/AMD — there is no software fallback yet).

## Behavior notes

- **SSID/passphrase:** SSID defaults to `VisionVNC-XXXX`; the passphrase is a freshly generated
  **8-char** WPA2 string from an unambiguous alphabet (no `0/O/1/l/I`) for easy manual typing in
  visionOS Settings. Both are editable in the UI and shown large in the **Join from Vision Pro**
  panel alongside the gateway IP.
- **Cold-start retry:** `StartHotspot` retries `WiFiDeviceOff` up to 4× (2.5 s apart) to absorb
  GO-radio warm-up.
- **Idle-disable auto-restart:** `MonitorService` re-starts the hotspot if Windows turns it off
  while it's meant to be on (throttled, capped at 5 consecutive failures).
- **Adopt + stop across restarts:** a freshly started backend lazily binds to the current
  upstream, so it can observe and stop a hotspot a previous process/run left running (rather than
  silently no-op'ing).

## Elevation

`ConfigureAccessPointAsync` + `StartTetheringAsync` are confirmed to work **elevated in an
interactive session** (Session 1). Whether they work from a **Session-0 SYSTEM service** could
**not** be tested — the validation hardware's only working path is Wi-Fi-Direct-GO, and the
question is moot until a SoftAP-capable driver is present. Microsoft's tethering samples run the
API from an interactive desktop app, and there are reports it fails under SYSTEM. The PoC
therefore defaults to the **elevated interactive-session helper** and keeps the service path as a
documented, opt-in future step. Re-run `spike/HotspotSpike.exe --start` under a SYSTEM service to
finalize this once capable hardware is available.

## Verification

Validated live on Windows 10 Pro 22H2 with the TP-Link adapter, Ethernet upstream:

- ✅ **AP up:** `StartHotspot` → `success`; a `Microsoft Wi-Fi Direct Virtual Adapter` came up at
  `192.168.137.1`; ICS (`SharedAccess`) running.
- ✅ **Client joined:** a device associated and received a DHCP lease (`192.168.137.207`).
- ✅ **Internet through NAT:** the joined device had working internet — proving the re-NAT
  defeats client isolation (the core value).
- ✅ **Full IPC path:** Electron ⇄ named pipe ⇄ backend, live status push, start/stop.
- ✅ **Packaged spawn path:** the built app spawns its bundled backend from `resources\backend`.
- ✅ **Restart adoption:** a fresh backend observed (`state:on, clients:3`) and stopped an AP a
  prior process had left running.

- ❌ **STA+AP concurrency (café single-adapter scenario) — does NOT work on this adapter.**
  With the TP-Link joined to a 2.4 GHz network and `StartHotspot` sharing that Wi-Fi upstream, the
  AP came up and the STA held for ~20 s, then the **station link reliably collapsed** (→ APIPA),
  killing internet + DHCP; a joined device got no traffic and couldn't ping the gateway. The
  single 2.4 GHz radio (`1 concurrent channel`) can't *sustain* STA+AP. **Use an Ethernet
  upstream (validated), a true-concurrency/dual-band adapter, or a second Wi-Fi adapter** for the
  café scenario. See `spike/SPIKE-FINDINGS.md`.

Not yet exercised: Session-0 service tethering; SoftAP (vs Wi-Fi-Direct-GO) path.

### Adapter-reset quirk (known issue)
After stopping a hotspot, the TP-Link could not scan/join networks as a station until an adapter
**disable/enable cycle**. If users will return to normal Wi-Fi on the same adapter, the backend
should reset the adapter on `StopHotspot` (TODO).

## Companion to the visionOS app

To remove manual gateway entry, the visionOS VisionVNC app now **auto-pre-fills `192.168.137.1`**
in the connection form when it detects it's on a Windows ICS subnet (`192.168.137.0/24`) — a
lightweight alternative to mDNS. See `VisionVNC/Utilities/LocalNetwork.swift` and
`VisionVNCTests/LocalNetworkTests.swift` (build/test on macOS with Xcode).

## Deferred (post-PoC)

- **mDNS advertising + visionOS NWBrowser discovery** (`_rfb._tcp` / `_nvstream._tcp`) — fuller
  auto-discovery than the ICS-subnet pre-fill above.
- **Windows audio/inject companion** — port of `SystemAudioTap`/`CompanionInject`; the
  companion-token / TLS-PSK channel is **not** exercised in this PoC.
- **Captive-portal auto-auth** — the host completes the portal once in a browser; NAT'd clients
  ride along. Document, don't automate.
- **SoftAP-class adapter** for >2 clients, 5 GHz, and no cold-start retry.
```
