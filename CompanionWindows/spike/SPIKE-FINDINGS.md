# Step-1 Spike Findings — Mobile Hotspot (`NetworkOperatorTetheringManager`)

Run on `DESKTOP-P4IMVMA`, Windows 10 Pro 22H2 (build 19045), 2026-06-08.

## What was tested

A minimal .NET 8 console (`CompanionWindows/spike/`) that walks the full Mobile
Hotspot path: `GetInternetConnectionProfile` → `GetTetheringCapabilityFromConnectionProfile`
→ `CreateFromConnectionProfile` → `ConfigureAccessPointAsync` → `StartTetheringAsync`,
printing the execution context (elevation, session id) and the live capability/state.

## Results

| Question (from plan Step 1)                | Answer |
|--------------------------------------------|--------|
| (a) Works **elevated**?                    | API reachable & `Configure` succeeds elevated in Session 1. `Start` blocked only by hardware (see below). |
| (b) Works under **SYSTEM / Session 0**?    | **Not reached** — blocked earlier by the hardware limit. The SSH shell here runs in **Session 1 (interactive), elevated**, so the Session-0 question is still open and must be settled on SoftAP-capable hardware. |
| (c) **SoftAP / STA+AP** on this adapter?   | **NO — the adapter cannot host an AP at all.** |

### Execution context observed
- Identity `DESKTOP-P4IMVMA\Ixion`, **Elevated = True**, **Session ID = 1** (interactive).
- Upstream internet profile: **`Ethernet 2`** (Realtek USB GbE, IANA type 6). Wi-Fi profile
  `🐈` also present (5 GHz, WPA3-Personal, ch 44).
- `GetTetheringCapabilityFromConnectionProfile(Ethernet 2)` → **`Enabled`**.
- `CreateFromConnectionProfile` → OK. `MaxClientCount = 8`.
- `ConfigureAccessPointAsync(SSID=Longwave-xxxx, 8-char pass)` → **OK**.
- `StartTetheringAsync` → **`WiFiDeviceOff`** (no exception; operation-result status).

### Root cause — `netsh wlan show wirelesscapabilities`
```
Soft AP                                 : Not supported
Wi-Fi Direct Device                     : Not supported
Wi-Fi Direct GO                         : Not supported
P2P Max Mobile AP Clients               : 0
Number of Concurrent Channels Supported : 0
```
And `netsh wlan show drivers` → `Hosted network supported : No`.

The **Broadcom 802.11ac** adapter (firmware `9.180.6`, Jan 2022) exposes **Station mode only**.
It supports neither the legacy Hosted Network nor the modern WiFiDirect-GO SoftAP that
Windows Mobile Hotspot is built on. `WiFiDeviceOff` is the tethering stack's way of saying
"no radio is available to host the AP" — it is **not** a STA+AP concurrency problem
(disconnecting the STA does not help) and **not** an elevation/session problem.

## Conclusion / decision

The Mobile Hotspot **software path is correct and the API activates** (configure works,
capability is `Enabled`) — but this machine has **no SoftAP-capable Wi-Fi radio**, so the
hotspot cannot be brought up here. Per the plan's Risks section, the documented fallback is
**a second USB Wi-Fi adapter that supports SoftAP** (or a host whose built-in Wi-Fi supports
it). The product code must therefore **detect this capability up front and surface a clear
"this adapter can't host a hotspot" message** instead of a raw `WiFiDeviceOff`.

This does not change the **elevation shape** decision yet (question (b) is still open); it must
be re-run on SoftAP-capable hardware to confirm whether `StartTetheringAsync` works under a
Session-0 SYSTEM service or must be marshalled to an interactive-session helper.

## Update — second adapter (TP-Link USB) tested

A **TP-Link Archer T2U-series USB adapter** (`VID_2357&PID_010C`, Realtek RTL8811AU/AC600)
was added and the Broadcom disabled so it was the only Wi-Fi radio. `StartTetheringAsync`
**still returned `WiFiDeviceOff`.** Diagnosis:

- WinRT `Radio.GetRadiosAsync()` → `Wi-Fi 2 (TP-Link): State=On` (radio is on, not soft-blocked).
- `Microsoft-Windows-WLAN-AutoConfig/Operational` event log at the moment of the call:
  - `8005 — WLAN AutoConfig service has begun starting the hosted network`
  - `8007 — WLAN AutoConfig service has **failed** to start the hosted network`
- `netsh wlan show wirelesscapabilities` for the TP-Link: `Soft AP: Not supported`,
  `Wi-Fi Direct GO: Supported`, `P2P Max Mobile AP Clients: 2`, `P2P GO on 5 GHz: Not Supported`.
- The TP-Link runs the **in-box Microsoft driver** `netrtwlanu.inf` v`1030.38.712.2019`.

**Root cause:** `NetworkOperatorTetheringManager` drives the AP through the WLAN
**hosted-network / SoftAP** function. The in-box Microsoft Realtek driver exposes only
Station + Wi-Fi-Direct-GO, **not** SoftAP, so the hosted-network start fails → `WiFiDeviceOff`.
The RTL8811AU silicon can do AP mode; the **vendor (TP-Link/Realtek) driver** is required to
surface SoftAP. Installing it typically needs a reboot (deferred — would interrupt the session).

### Net effect on the plan
- The **software/API path is validated** (capability `Enabled`, `Configure` OK, elevated
  Session-1 OK). The blocker is purely **driver SoftAP exposure**.
- Action taken in the product: the backend **probes SoftAP capability up front** and returns a
  precise `AdapterCannotHostAp` error (with the `WiFiDeviceOff` / hosted-network detail) instead
  of a raw status — exactly the "detect and message clearly when unsupported" the plan calls for.
- Question (b) — Session-0/SYSTEM — remains **unverified** (no live AP to test against). The
  backend is therefore built host-agnostic (runs as a Windows Service **or** an elevated
  interactive-session helper) and the PoC defaults to the **elevated interactive-session helper**
  to side-step the documented Session-0 tethering risk. Re-run the spike's start path under a
  SYSTEM service once a SoftAP-capable driver is present to finalize the elevation shape.

## Update — STA+AP concurrency (Wi-Fi upstream): NOT RELIABLE on this adapter

Tested whether the TP-Link can stay connected to Wi-Fi **and** host the AP on the one radio
(the café scenario — re-share the venue Wi-Fi, no Ethernet):

- TP-Link joined a 2.4 GHz WPA2 network (`TestNet`, **channel 1**), IP `192.168.2.3`; host had
  internet over Wi-Fi.
- `StartHotspot` sharing the **Wi-Fi (TestNet) upstream** → reported `success`, AP up at
  `192.168.137.1`, and for the first ~20 s the STA link **stayed connected** (host kept pinging
  `192.168.2.1`). Encouraging at first glance.
- **But it collapses:** within ~30 s the **STA link drops** (goes to `disconnected` / APIPA),
  killing the upstream and DHCP. A device that joined the AP got **no internet and could not even
  ping the gateway** `192.168.137.1` — and the drop reproduced on every attempt.

**Verdict:** the single **2.4 GHz radio with `Number of Concurrent Channels Supported: 1`** can
bring STA and AP up momentarily but **cannot sustain** them together — the station association
collapses under the AP. **Single-adapter Wi-Fi re-sharing does not work on this hardware.** The
café scenario needs one of: **Ethernet upstream** (pure AP — validated working end-to-end), a
**dual-band / true-concurrency adapter**, or a **second Wi-Fi adapter** (one STA, one AP).
(An earlier note in this file claimed STA+AP "works"; that was based only on the first-20 s
snapshot and is corrected here.)

**Adapter-stuck quirk also seen:** after a tethering session the TP-Link sometimes can't scan or
re-associate as a STA until a disable/enable cycle.

**Adapter-reset quirk:** after a tethering session the TP-Link got stuck unable to scan as a STA
(`netsh wlan show networks` returned nothing, `WlanGetAvailableNetworkList error 13`) until a
**disable/enable cycle** of the adapter. Relevant if a user stops the hotspot and wants normal
Wi-Fi back on the same adapter — the product should reset the adapter on stop (TODO).

## Correction — multi-adapter selection is NOT the problem (cold-start is)

An earlier read of this spike assumed that with both Wi-Fi adapters enabled, Windows picked the
**incapable Broadcom** to host and that **disabling it** was the fix. Direct re-testing disproves
that:

- **Both adapters enabled, both idle** → AP started first-try on the capable TP-Link.
- **Broadcom enabled and connected as a STA (TestNet, ch 1), TP-Link idle** → `StartTetheringAsync`
  → **`Success` on the first attempt** (backend log, no retry), AP hosted on the TP-Link, and the
  **Broadcom's STA link survived**. Windows chose the capable radio unprompted.

So Windows' adapter selection prefers a SoftAP/GO-capable radio; a wrong-adapter pick could **not
be reproduced**. The initial post-plug-in failures were the TP-Link's **cold-start warm-up**
(`WiFiDeviceOff` on the first 1–2 attempts, then success — the retry now absorbs this), and the
"disable the Broadcom" step that appeared to fix things was a **misattribution** (the radio had
simply warmed up). The guided adapter-disable feature remains as a rare fallback, not a routine
requirement.

## Reliability experiments (follow-up) — single-radio re-share is a dead end here

Tried to make single-adapter STA+AP hold; results:

| Experiment | Result |
|---|---|
| Share **Ethernet** while TP-Link is STA on Wi-Fi | **STA stable >100 s** — the radio sustains STA + AP beaconing fine when it isn't NAT-ing its own uplink. |
| Share the **STA's own Wi-Fi**, band = `auto` | STA collapses ~30 s. |
| Share the **STA's own Wi-Fi**, band forced `2.4` (match STA ch 1) | STA collapses ~30–45 s — **band/channel is not the fix**. |
| Adapter power-save tuning | Driver exposes **no** power/roam knobs (only "Bandwidth") — nothing to tune. |
| **Two adapters**: Broadcom = STA upstream, TP-Link = pure AP | **Inconclusive/negative** — Broadcom STA also dropped ~40 s. Confounded by (a) the Broadcom having multiple auto-connect profiles (roamed off TestNet) and (b) likely **2.4 GHz co-channel interference** between the two close-by radios (TP-Link GO is 2.4-only, forced onto the STA's band). |

**Conclusion:** a single cheap 2.4 GHz USB radio **cannot** reliably re-share the Wi-Fi it's
connected to (the STA association dies under the AP-forwarding load, ~30–45 s, untunable). The
proven path is **Ethernet upstream**. A second adapter *can* work in principle but needs the
**upstream STA and the AP on different bands** (e.g. a dual-band adapter doing 5 GHz STA + 2.4 GHz
AP, or vice-versa) to avoid co-channel self-interference — not achievable with this 2.4-only dongle.

**Driver fragility warning:** heavy start/stop/roam cycling **wedged the WLAN stack** — `icssvc`
and `WlanSvc` hung in `StopPending`, the TP-Link USB driver returned "Generic failure" to a PnP
restart, and the adapters couldn't scan. Recovery required killing the (dedicated) `icssvc`
svchost and ultimately a **reboot** (or unplugging the USB adapter). The product should avoid
rapid start/stop cycling and treat a wedged adapter as "needs reset/reboot".

## How to re-run
```powershell
cd CompanionWindows\spike
dotnet build -c Release
.\bin\Release\net8.0-windows10.0.19041.0\HotspotSpike.exe              # dry capability probe
.\bin\Release\net8.0-windows10.0.19041.0\HotspotSpike.exe --start --duration 90   # bring AP up 90s
```
The console also doubles as a standalone capability checker for any future adapter.
