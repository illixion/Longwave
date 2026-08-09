# Longwave Companion

This companion is **multi-purpose**. It hosts several independent subsystems behind one
.NET 8 backend and one window. Everything runs **unelevated**; only the hotspot elevates, and
only when you turn it on (see [Elevation](#elevation)):

1. **Foveated Streaming (CloudXR) host** — advertises the PC over Bonjour as an Apple
   Foveated-Streaming host, runs the session-management TCP protocol, and drives the NVIDIA
   CloudXR runtime so the Vision Pro can stream desktop OpenXR content. Foveation happens
   **here, on the PC, from the headset's real gaze** — the game renders foveated rather than
   uniformly, which stock CloudXR cannot do because it exposes no eye tracking to games. The
   same gaze can optionally drive VRChat's avatar eyes over OSC. Needs an NVIDIA RTX GPU —
   CloudXR supports 40-series and newer, and reports anything older as unsupported, but a
   30-series card does work with less headroom (developed against a 3080). See
   [Foveated Streaming (CloudXR) host](#foveated-streaming-cloudxr-host).
2. **Native screen streaming** — TLS-PSK server on port 4857 that sends the desktop, or
   individual windows, to Longwave's Native connection type, with optional mouse and
   keyboard control.
3. **Wi-Fi Hotspot** (the original PoC) — turns the Windows host into a NAT'd Wi-Fi AP the
   Vision Pro joins directly. Documented in the bulk of this README below.

All of them surface through the same ACL'd named pipe and the same window. PCVR and its game
library are the primary navigation; screen streaming and the Wi-Fi hotspot sit alongside them.

---

## Wi-Fi Hotspot

Turns a **Windows host into a NAT'd Wi-Fi access point** that a Vision Pro joins directly,
so the headset and host get a direct, low-latency link **even on networks with client-to-client
(AP) isolation** — cafés, hotels, conference Wi-Fi. From the venue's view there's a single
client (the Windows PC); the Vision Pro rides behind the PC's NAT, keeping internet **and**
gaining a path to the local Sunshine/VNC server at the AP gateway (`192.168.137.1`).

This is the Windows analogue of Apple's Mac Virtual Display P2P link, and it also hosts
**native screen streaming** — the same encrypted protocol the macOS companion serves on
port 4857, so Longwave's *Native* connection type works against a Windows host too
(opaque desktop or individual windows as their own visionOS windows, with remote mouse
and keyboard). It's a **separate codebase** (Node + .NET) sibling to the macOS companion
(`CompanionMac/`); it mirrors that companion's conventions but shares no compiled code.

> **Status: working PoC, validated end-to-end on real hardware.** A device joined the hotspot,
> received a DHCP lease, and had working internet through the host's NAT (see
> [Verification](#verification)).

## Architecture

```
┌───────────────────────────── Windows host ─────────────────────────────┐
│  Electron app (asInvoker, interactive user)                             │
│    renderer (UI)  ──contextBridge/IPC──  main process                   │
│                                │                                         │
│                  named pipe \\.\pipe\longwave-hotspot (ACL'd)           │
│                                ▼                                         │
│  ┌────────────────────────────────────────────────────────────┐        │
│  │  Privileged backend  (C# / .NET 8, WinRT via CsWinRT)        │        │
│  │   • TetheringController → NetworkOperatorTetheringManager    │        │
│  │       (SoftAP/Wi-Fi-Direct-GO + DHCP + NAT/ICS, bundled)     │        │
│  │   • PipeServer (newline-delimited JSON-RPC + push events)    │        │
│  └────────────────────────────────────────────────────────────┘        │
│  Upstream: Ethernet or Wi-Fi (STA)  ──► NAT ──►  Longwave AP           │
└──────────────────────────────────────────────────────────────────────┬─┘
                                                                         │ Wi-Fi
                                            joins SSID + 8-char password │
                                                                         ▼
                                                        ┌──────────────────────────┐
                                                        │  Vision Pro                │
                                                        │  gets 192.168.137.x lease  │
                                                        │  → Longwave connects to    │
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
├── backend/                  # .NET 8 worker — TetheringController, PipeServer, MonitorService,
│                             #   NativeStream/ (window + desktop capture, encode, input injection)
├── app/                      # Electron (main + preload + renderer), electron-builder NSIS config
├── spike/                    # Step-1 capability spike + SPIKE-FINDINGS.md (the decision record)
├── THIRD_PARTY_NOTICES.md    # this app's own dependencies — see below
└── README.md
```

The CloudXR/Foveated host is no longer part of `backend/`; it is a separate process built
from the private `Longwave-PCVR-Host/` submodule and downloaded on demand at runtime.

## Licenses

Dependencies, and — just as importantly — the boundary between what ships in this installer,
what ships in the optional PCVR download, and what is only ever installed on the host by the
user, are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app itself shows
the same notices under **Licences** in the bottom-left of the window.

Two rules that file exists to keep: OpenPGP.js (LGPL-3.0+) stays in this open-source app and
never enters the closed PCVR bundle, and OpenComposite (GPL-3.0) is fetched onto the host,
never redistributed. `scripts/package-pcvr-bundle.sh` fails the build if either drifts in.

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

- `LongwaveCompanion-…-x64-Setup.exe` — Intel / AMD
- `LongwaveCompanion-…-arm64-Setup.exe` — Windows on ARM (Snapdragon X-class)

CI builds the installers and emits a **signed build-provenance attestation**. Verify the
download was produced by this repo's workflow and not tampered with:

```bash
gh attestation verify LongwaveCompanion-<version>-<arch>-Setup.exe --repo illixion/Longwave
```

The installer is **unsigned** (no code-signing cert), so SmartScreen may warn on first run;
the attestation is the integrity guarantee. Still **Beta** — re-read the hardware caveats above.

### What the installer must get right for PCVR

Two things are easy to get wrong in a way that produces symptoms pointing somewhere else.
Neither is currently done by the NSIS installer — the PCVR host is only provisioned by
`scripts/provision-pc.ps1` — so both are **open work** for shipping PCVR to an end user.
See `Longwave-PCVR-Host/docs/HOST_PROVISIONING.md` for the measurements behind them — it
lives in the private PCVR submodule, so a public checkout will not have it.

1. **Set the OpenXR machine default (`HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime`) to the
   game-facing runtime, and set no machine-wide `XR_RUNTIME_JSON` at all.** The broker points
   itself at CloudXR with its own environment variable; everything else — every game — must
   get the default. Steering games with a machine environment variable instead looks
   equivalent and is not: a machine variable only reaches a process whose parent already had
   it, and Explorer's environment is captured at logon. On the dev host Explorer had been
   running for eight days, so anything launched from the desktop or from Steam inherited a
   stale block, fell through to the registry, and landed on CloudXR — which already holds the
   broker's session and permits exactly one. hello_xr exited immediately with code 1 and
   Half-Life: Alyx failed `xrCreateSession` with `XR_ERROR_LIMIT_REACHED`. An installer that
   sets the variable "because it worked when I tested it" ships that intermittently.
2. **Do not create a shortcut marked "Run as administrator", and do not request elevation for
   the app.** An elevated companion elevates its backend, and with it NvStreamManager and
   CloudXrService, which then create `ipc_cloudxr` with an Administrators DACL that the
   unelevated broker cannot open. The reported error is CloudXR's Monado-derived runtime
   saying its service is not running, plus `xrCreateInstance` → `-51`, which reads as a broken
   CloudXR install. Only tethering needs admin, and it asks for it on demand.

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
npm run dist         # -> app\dist\Longwave Companion Setup <ver>.exe
```

## Run

Two deployment shapes share one backend binary (`Microsoft.Extensions.Hosting`, detects which):

1. **Interactive-session helper (PoC default).** The Electron app spawns the bundled backend as a
   child; both run as the signed-in user. No Windows service. Turning the hotspot on raises one
   consent prompt for a short-lived elevated helper — see [Elevation](#elevation). Just run the
   installed app.
2. **Windows Service (optional, future).** The backend can be hosted by the SCM
   (`AddWindowsService`). Register it once Session-0 tethering is validated — see the commented
   `sc.exe` lines in `app/build/installer.nsh`, and set `LONGWAVE_NO_SPAWN=1` for the app so it
   connects to the service instead of spawning its own.

Dev tips:
- Run the backend standalone: `backend\bin\Release\net8.0-windows10.0.22621.0\LongwaveCompanionBackend.exe`
- Run the app against it without spawning: `setx`-free `$env:LONGWAVE_NO_SPAWN=1; npm start`
- Capability check only: `LongwaveCompanionBackend.exe --probe`
- Handy pipe-client scripts: `backend\test-client.js`, `start-hold.js`, `stop.js` (Node).

## IPC protocol

Newline-delimited JSON over `\\.\pipe\longwave-hotspot`. The pipe ACL grants the interactive
desktop user + the process owner + Administrators + SYSTEM, and denies everyone else (the backend
is privileged — an open pipe would be a local privilege-escalation vector).

- **Requests** `{ "id", "method", "params"? }` → **responses** `{ "id", "result" | "error" }`
- **Hotspot methods:** `GetStatus`, `ListUpstreamProfiles`, `StartHotspot{ssid?,passphrase?,band?,profileId?}`,
  `StopHotspot`, `ListWifiAdapters`, `PrepareApAdapter`, `GetClients`, `Ping`
- **Foveated methods:** `FoveatedStart{bundleId?,port?,ipAddress?,forceQrCode?}`, `FoveatedStop`,
  `FoveatedStatus` (see [Foveated Streaming](#foveated-streaming-cloudxr-host))
- **Native streaming methods:** `NativeStreamStatus`, `NativeStreamSetEnabled{enabled}`,
  `NativeStreamSetInput{mouse?,keyboard?}`, `NativeStreamRegenerateToken`
- **Push events** `{ "event":"state", "data": <HotspotStatus> }` on hotspot state/client-count
  changes (driven by `MonitorService`, polling every 2 s), `{ "event":"foveated", "data":
  <FoveatedStatus> }` on host start/stop, session-status and pairing/QR changes, and
  `{ "event":"nativeStream", "data": <NativeStreamStatus> }` on streaming state changes.

`HotspotStatus` carries `state` (off/on/inTransition), `ssid`, `passphrase`, `band`, `gatewayIp`,
`clientCount`/`maxClientCount`, `upstreamName`/`upstreamKind`, `canHostAp`, `capabilityDetail`.

## Native screen streaming

`backend/NativeStream/` serves Longwave's framed native-stream protocol (protocol v2) on
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
- **Settings** persist under `HKCU\SOFTWARE\Longwave\Companion` (token, enabled, input
  toggles).

Requires Windows 10 2004+ for Windows.Graphics.Capture and a hardware HEVC encoder
(NVIDIA/Intel/AMD — there is no software fallback yet).

## Behavior notes

- **SSID/passphrase:** SSID defaults to `Longwave-XXXX`; the passphrase is a freshly generated
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

**The backend and the UI both ship as `asInvoker`.** Administrator rights are needed by exactly one
feature — the Mobile Hotspot — and it asks for them at the moment you use it, not at launch.

Reading hotspot state needs no elevation: `CreateFromConnectionProfile`, operational state, client
count and `IsBandSupported` all answer at medium integrity, so the panel is populated and live with
no prompt. Starting, stopping or preparing the AP adapter does need it, so
`ElevatedTetheringProxy` re-launches this same executable as `--tether-host` through
ShellExecute `"runas"`. One consent prompt; that elevated child then owns the access point until the
backend exits, and stops an AP it started on the way out. Details and the reasoning in
`TetheringElevation.cs`.

This is not only about the prompt. Blanket elevation was actively harmful to the PCVR subsystem:
the OpenXR loader **ignores `XR_RUNTIME_JSON` in an elevated process**, so an elevated broker could
only be steered by the machine-wide registry default — the setting games want for themselves — and
every game had to be de-elevated by hand on the way out. Measured unelevated on the RTX host on
2026-07-28: `NvStreamManager`, `CloudXrService` and the session broker all run at medium integrity,
`ipc_cloudxr` is a per-user pipe, and the broker honours `XR_RUNTIME_JSON` over the registry.

`ConfigureAccessPointAsync` + `StartTetheringAsync` are confirmed to work **elevated in an
interactive session** (Session 1). Whether they work from a **Session-0 SYSTEM service** is still
untested — the validation hardware's only working path is Wi-Fi-Direct-GO, and the question is moot
until a SoftAP-capable driver is present. Microsoft's tethering samples run the API from an
interactive desktop app, and there are reports it fails under SYSTEM. The service path therefore
stays a documented, opt-in future step; re-run `spike/HotspotSpike.exe --start` under a SYSTEM
service to finalize it once capable hardware is available.

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

## Foveated Streaming (CloudXR) host

A port of Apple/NVIDIA's reference session-management host
(`spike/StreamingSession/StreamingSession-WindowsApp/`) into this companion's .NET 8 backend, so
the same PC that runs the hotspot can also be the **Apple Foveated-Streaming host** that streams
desktop OpenXR content to a Vision Pro over NVIDIA CloudXR.

### What it does

```
┌──────────────────────────── Windows host ─────────────────────────────┐
│  FoveatedHostService (lifecycle-managed like TetheringController)      │
│    ├── BonjourAdvertiser       _apple-foveated-streaming._tcp + TXT     │
│    │                           Application-Identifier=<visionOS bundle> │
│    ├── SessionManagementServer  length-prefixed-JSON TCP control proto  │
│    │                            (4-byte LE length + UTF-8 JSON, :55000) │
│    └── CloudXRController        NvStreamManager.exe + NvStreamManager-   │
│                                 Client.dll RPC (P/Invoke), QR {token,    │
│                                 digest} generation                      │
└──────────────────────────────────────────────────────────────┬────────┘
        mDNS discovery + TCP control + (CloudXR media)           │
                                                                 ▼
                                                  ┌────────────────────────┐
                                                  │  Vision Pro             │
                                                  │  discovers host, pairs  │
                                                  │  (QR), streams via CXR  │
                                                  └────────────────────────┘
```

- **Discovery (Bonjour/mDNS):** advertises `_apple-foveated-streaming._tcp` with a TXT record
  `Application-Identifier=<bundle id>`. The headset only surfaces hosts advertising **its** bundle
  id, so this defaults to the visionOS app id **`pro.longwave`** (overridable in the UI).
- **Session protocol (TCP, default port 55000, ProtocolVersion "1"):** a faithful port of the
  reference's length-prefixed-JSON server. Message dispatch + single-session state machine:
  `RequestConnection` → `AcknowledgeConnection` (carries `ServerID` + `CertificateFingerprint`;
  the fingerprint is **omitted** to force QR pairing or when CloudXR is absent),
  `RequestBarcodePresentation`/`AcknowledgeBarcodePresentation`, `SessionStatusDidChange`
  (WAITING/CONNECTING/CONNECTED/PAUSED/DISCONNECTED), `MediaStreamIsReady`,
  `RequestSessionDisconnect`. A stable `ServerID` is kept in `HKCU\SOFTWARE\CloudXR\ServerID` (same
  location as the reference) so a previously-paired headset skips the QR.
- **CloudXR:** launches/monitors `NvStreamManager.exe`, talks to it over the
  `NvStreamManagerClient.dll` RPC API, and on the WAITING transition starts the CXR service then
  sends `MediaStreamIsReady`. The pairing QR payload is `{"token":<clientToken>,"digest":<certFingerprint>}`,
  both minted by the Stream Manager from the client id.

### CloudXR-absent degradation (important)

The backend **builds and runs without the CloudXR SDK present.** All P/Invoke into
`NvStreamManagerClient.dll` is gated through `CloudXRInterop`, which loads the DLL **lazily and
explicitly** via `NativeLibrary.TryLoad` + a `DllImportResolver` — the `[DllImport]` entry points
are never JIT-resolved by a direct call, so a missing DLL can't throw `DllNotFoundException` at
load time. When the DLL is absent:

- `FoveatedStart` still succeeds: the host advertises over mDNS and runs the TCP protocol (so you
  can verify discovery/pairing wiring end-to-end), but every CloudXR operation is a safe no-op.
- `FoveatedStatus.cloudXrAvailable` is `false` with a human-readable `cloudXrDetail` ("CloudXR not
  installed (NvStreamManagerClient.dll not found near …)"), and the UI shows a warning banner.
  `runtimeRunning` and `gameRunning` expose the live CloudXR state used by the technical panel and
  the quit confirmation.
- Because no real cert fingerprint can be minted, `AcknowledgeConnection` omits the fingerprint,
  which forces the headset down the QR-pairing path (the QR payload is empty until the SDK is
  present, so streaming won't actually start — by design).

The DLL is searched next to the backend exe, in `SampleClient/`, in `Server/`, then on the OS
search path. The user (who has an RTX 3080) can install CloudXR and just press **Start** again — a
failed probe is re-attempted on each start.

### CloudXR SDK prerequisite

Two downloads from NVIDIA NGC (CloudXR **6.0.4+**, version pinned by `cloudxr-runtime.yaml`):

- **CloudXR Runtime** — the OpenXR runtime binaries (e.g. `CloudXR-6.0.4-Win64-sdk`).
- **CloudXR Stream Manager** — the stream-management service (e.g. `Stream-Manager-6.0.3-win64`).

Lay the files out next to the **published backend** (`resources/backend/` once packaged, or the
backend's `bin/.../publish/` in dev):

```
<backend dir>/
├── Server/
│   ├── releases/
│   │   └── 6.0.4/                 # contents of CloudXR-6.0.4-Win64-sdk/ (openxr_cloudxr.json, .dll, …)
│   ├── CloudXrService.exe         # Stream Manager: Server/
│   ├── NvStreamManager.exe        # Stream Manager: Server/
│   └── cloudxr-runtime.yaml       # Stream Manager: Server/
├── NvStreamManagerClient.dll      # Stream Manager: SampleClient/  ← the P/Invoke target
└── NvStreamManagerClient.h        # (reference only)
```

> The runtime **must** live in a version-named subfolder (`releases/6.0.4/`). The OpenXR active
> runtime is registered at `HKLM\SOFTWARE\Khronos\OpenXR\1\ActiveRuntime`; if it doesn't point at
> this runtime's `openxr_cloudxr.json`, set it (the reference app's "Fix" button did this — not yet
> ported here; do it manually for now).

### Testing with a Meta Quest now (before a Vision Pro)

CloudXR's runtime can serve a generic OpenXR client, so you can validate the **CloudXR media path**
on the RTX PC with a Quest as the client today (the Apple session-management + Bonjour layer is
Vision-Pro-specific and isn't exercised by a Quest):

1. Install the CloudXR Runtime + Stream Manager as above; point the active OpenXR runtime at
   `openxr_cloudxr.json`.
2. In `Server/cloudxr-runtime.yaml`, for a non-Vision-Pro client set `deviceProfile: auto-native`
   and `runtimeFoveation: false` (per NVIDIA's runtime-management docs — the default
   `apple-vision-pro` profile + foveation give a black screen on other clients).
3. Launch a desktop OpenXR app on the PC; connect the **CloudXR client app on the Quest** to the
   PC's IP. You're verifying GPU encode → CloudXR transport → headset decode.
4. Separately, verify the companion's session layer: press **Start PCVR** on the PCVR page,
   then on a Mac run `dns-sd -B _apple-foveated-streaming._tcp` (or any mDNS browser) and confirm
   the service appears with the `Application-Identifier` TXT — that proves Bonjour + the TCP server
   are live independent of any headset.

When the Vision Pro arrives, set the advertised bundle id to its Longwave build's id, and the
headset's discovery → RequestConnection → pairing-QR → MediaStreamIsReady flow drives CloudXR
automatically.

### Build / run / test on the RTX PC

```powershell
# Backend (restores Makaretu.Dns.Multicast.New + QRCoder NuGet packages)
cd CompanionWindows\backend
dotnet build -c Release
# self-contained publish (what the installer bundles); drop the CloudXR Server/ + DLL alongside
dotnet publish -c Release -r win-x64 --self-contained true `
  -o bin\Release\net8.0-windows10.0.19041.0\publish

# Electron app
cd ..\app
npm install
npm start
```

The app opens on **PCVR** with one **Start/Stop PCVR** action. The Options panel keeps PCVR services
enabled by default and contains the Local network/Tailscale choice plus advanced bundle id
(`pro.longwave`), port (`55000`), advertise IP, and QR settings. Technical state stays at
the bottom of the page. Pairing requests surface the current QR automatically. Closing the app
waits for the broker and CloudXR host to stop; if CloudXR reports an attached OpenXR game, the app
asks for confirmation before ending the session.

### Automated deploy from the Mac (`scripts/deploy-windows-companion.sh`)

Iterating by hand over SSH is slow, so the whole host-side setup is scripted. From the repo root:

```bash
scripts/deploy-windows-companion.sh                  # sync + publish + stage CloudXR + npm install + tasks
scripts/deploy-windows-companion.sh --no-build        # scripts/UI only (skip dotnet publish)
scripts/deploy-windows-companion.sh --status          # what is the host doing right now
scripts/deploy-windows-companion.sh --session start   # CloudXR runtime + OpenComposite, Sunshine off
scripts/deploy-windows-companion.sh --session stop    # restore SteamVR + Sunshine
```

It tars `CompanionWindows/` (no `bin`/`obj`/`node_modules`), scps it to `C:\dev\Longwave-companion`,
and runs `scripts/provision-pc.ps1` there. Everything is idempotent. The PC-side scripts:

| Script | Purpose |
|--------|---------|
| `scripts/provision-pc.ps1` | `dotnet publish`, stage the CloudXR `Server/` + `NvStreamManagerClient.dll`, `npm install`, write `tools/start-*.bat`, register the `Longwave-*` scheduled tasks, open the firewall ports. |
| `scripts/pcvr-session.ps1` | Flip the host between desktop and PCVR mode: `ActiveRuntime`, `openvrpaths.vrpath`, `SunshineService`. Snapshots the previous values under `HKCU\Software\Longwave\PcvrSession` so `-Mode stop` restores them. |
| `scripts/install-opencomposite.ps1` | Install OpenComposite. Sniffs the payload — the mirror currently serves a raw `vrclient_x64.dll` (`MZ`), not a zip. |
| `scripts/build-opencomposite.ps1` | Build the pinned OpenComposite source with Longwave's Index-trackpad action fix. Build x64, then pass its output to `install-opencomposite.ps1 -Arch x64 -Payload ...`; repeat for x86 when updating the 32-bit runtime. Requires the Visual C++ ATL component. |
| `scripts/foveated-ctl.ps1` | Drive PCVR from SSH without giving the elevated SSH session ownership of desktop processes. `start`/`stop`/`restart` and `restart-launch` use the Electron companion's local control pipe, so its supervisor stops the broker before CloudXR and waits for CloudXR IPC before restarting it; `restart-launch` then waits for headset `CONNECTED` before launching the title through the medium-integrity backend. `host-start`/`host-stop` are backend-only diagnostics and must not be used while the desktop supervisor owns the broker. `status -WaitSeconds N` watches backend state and prints the QR payload. |
| `scripts/capture-cloudxr-trace.ps1` | Capture WPR CPU stacks, scheduling, GPU activity, NVIDIA utilization, and matching broker metadata during a live Alyx session. |

**Keep these scripts pure ASCII.** They are copied to the PC as UTF-8 without a BOM, and
Windows PowerShell 5.1 reads a BOM-less file as ANSI: a single em dash inside a string
literal turns into two bytes, breaks the quote, and the script dies with
`Unexpected token ... The hash literal was incomplete` — a parse error nowhere near the
real problem. Cost an on-device debugging session once (2026-07-26).

Work is launched through **scheduled tasks**, not SSH: NvStreamManager's RPC TLS key pair is
DPAPI-protected, and a pubkey-auth SSH session has no unlocked DPAPI master key, so launching it
from SSH crash-loops on "Failed to load key pair". The tasks run in the logged-on interactive
session. Run **either** `Longwave-CompanionUI` (spawns its own backend) **or** `Longwave-Backend`
— never both; the backend now takes a `Global\` mutex and exits with code 2 if a second one starts.

#### Defects this shook out (2026-07-26)

The named-pipe path had never actually been exercised on the RTX host (the first live session used
`--foveated`, which serves no pipe). Four real bugs, all fixed:

- **Zero-sized pipe buffers.** `NamedPipeServerStreamAcl.Create(..., inBufferSize: 0, outBufferSize: 0, ...)`
  left the kernel with no pipe buffer, so a client connected, received the pushed snapshots, and
  then **blocked forever on its first write**. Now 64 KB in / 1 MB out — the out buffer is generous
  because pairing events carry the QR PNG as a base64 data URI.
- **Serial accept loop.** The server created one pipe instance and handled it to completion before
  creating the next, so the Electron UI locked out every other client for its whole lifetime.
  Connections are now served concurrently, each with its own writer; events broadcast to all.
- **Blocking hydration.** A new client was sent the hotspot status *before* the read loop started,
  and that WinRT tethering query never returns on a host with no tetherable adapter — so the client
  got no frame at all, not even a `Ping` reply. Hydration is now out-of-band and bounded (10 s), and
  requests dispatch concurrently so one slow method cannot stall a client's other calls.
- **Link-local IP auto-pick.** `ResolveIp` deprioritized CGNAT but not APIPA, and a downed Tailscale
  adapter sits at `169.254.x.x` — the host advertised a `169.254.83.107:55000` endpoint the headset
  could never reach. Link-local is now ranked below everything and never chosen.

Also: macOS `tar` emits AppleDouble `._foo.cs` sidecars that the C# compiler reads as source and
rejects with CS2015 — the deploy sets `COPYFILE_DISABLE=1` and sweeps them. And electron's
postinstall downloads its zip fine here but its unzip dies partway and still exits 0, so
`provision-pc.ps1` re-extracts `dist/` from the cached zip with `tar.exe`.

### Subsystem files

| File | Purpose |
|------|---------|
| `backend/Foveated/SessionMessages.cs` | Protocol DTOs (`RequestConnection`, `AcknowledgeConnection`, …), `SessionStatus`/`ProtocolConstants`, `BarcodePayload`, `SessionInformation`. PascalCase wire names via `[JsonPropertyName]`. |
| `backend/Foveated/BonjourAdvertiser.cs` | mDNS advertisement of `_apple-foveated-streaming._tcp` + `Application-Identifier` TXT (Makaretu.Dns.Multicast.New). |
| `backend/Foveated/SessionManagementServer.cs` | Length-prefixed-JSON TCP server + full message dispatch + single-session state machine (System.Text.Json). |
| `backend/Foveated/CloudXRInterop.cs` | `NvStreamManagerClient.dll` P/Invoke + **lazy guarded** DLL loading (`IsAvailable`/`EnsureLoaded`). |
| `backend/Foveated/CloudXRController.cs` | NvStreamManager process lifecycle, RPC orchestration, status poll, `{token,digest}` generation — all no-ops when unavailable. |
| `backend/Foveated/FoveatedHostService.cs` | Ties advertiser + TCP server + CloudXR together; start/stop, `FoveatedStatus` snapshot, QR PNG generation (QRCoder), `StatusChanged` event. |

## Companion to the visionOS app

To remove manual gateway entry, the visionOS Longwave app now **auto-pre-fills `192.168.137.1`**
in the connection form when it detects it's on a Windows ICS subnet (`192.168.137.0/24`) — a
lightweight alternative to mDNS. See `Longwave/Utilities/LocalNetwork.swift` and
`LongwaveTests/LocalNetworkTests.swift` (build/test on macOS with Xcode).

## Deferred (post-PoC)

- **mDNS advertising for VNC/Moonlight** (`_rfb._tcp` / `_nvstream._tcp`) + visionOS NWBrowser
  discovery — fuller auto-discovery than the ICS-subnet pre-fill above. (Note: mDNS advertising
  itself now exists in-tree for the Foveated host via `_apple-foveated-streaming._tcp`; this item
  is specifically about advertising the VNC/Moonlight services.)
- **Windows audio/inject companion** — port of `SystemAudioTap`/`CompanionInject`; the
  companion-token / TLS-PSK channel is **not** exercised in this PoC.
- **Captive-portal auto-auth** — the host completes the portal once in a browser; NAT'd clients
  ride along. Document, don't automate.
- **SoftAP-class adapter** for >2 clients, 5 GHz, and no cold-start retry.
```
