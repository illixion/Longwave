# VisionVNC

A native remote desktop and game streaming app for Apple Vision Pro, built in Swift with SwiftUI.

VisionVNC combines a full-featured **VNC viewer** with a **Moonlight game streaming** client in a single visionOS app. Connect to any VNC server for remote desktop access, or stream games and applications from a [Sunshine](https://github.com/LizardByte/Sunshine) / NVIDIA GameStream host with hardware-accelerated video decoding and low-latency input.

> [!TIP]
> **New: VisionVNC Windows Companion (Beta).** This Electron + .NET app for Windows includes a [Wi-Fi Hotspot](#visionvnc-windows-companion-beta) that gives the Vision Pro a direct NAT'd link even on café/hotel Wi-Fi, plus a Foveated Streaming (CloudXR) host for PCVR.

## Features

### VNC Remote Desktop
- Connect to any VNC server on your local network
- Auto-login with saved credentials (VNC password and macOS Screen Sharing username/password auth)
- Hardware and Bluetooth keyboard support with full key mapping
- Full on-screen keyboard of our own — modifier keys that actually work (Ctrl+G, ⌥⌘F…), function keys, navigation cluster, and clipboard paste
- Configurable quality presets (Low/Medium/High) with JPEG quality, compression level, and color depth tuning
- Trackpad Only mode — transparent input overlay for use on top of Mac Virtual Display

### Moonlight Game Streaming
- Stream games and desktop from a [Sunshine](https://github.com/LizardByte/Sunshine) or NVIDIA GameStream host
- Hardware-accelerated H.264, HEVC, and AV1 decoding via AVSampleBufferDisplayLayer
- HDR10 support with automatic tone mapping (HEVC Main 10 / AV1 Main 10 with PQ transfer function)
- Opus audio with stereo, 5.1, and 7.1 surround sound support
- Configurable resolution (720p to 4K), frame rate (30/60/120 FPS), and bitrate (0.5-150 Mbps)
- Bluetooth gamepad support (DualSense, Xbox, and more) with up to 4 controllers
- Relative mouse mode for games and absolute mode for desktop use
- Hardware and on-screen keyboard with Windows virtual key code mapping
- Live streaming statistics overlay (codec, FPS, RTT, decode time, dropped frames)
- PIN-based pairing with Sunshine servers (SHA-256 and legacy SHA-1)
- Session management — disconnect locally or quit the app on the server

### PCVR — Foveated Streaming (CloudXR)

- Play SteamVR and OpenXR titles from a Windows PC with an NVIDIA RTX card, in a fully immersive space on the Vision Pro
- **Foveated on the host, by your real gaze.** Your eye tracking is carried to the PC and the *game* renders foveated — full detail where you look, less work in the periphery. Stock CloudXR hands games no eye tracking at all, so they render uniformly and the GPU pays for pixels you cannot resolve; supplying it is why a given card holds a higher frame rate here
- **No IP to type** — the PC advertises itself over Bonjour and the headset finds it. Entering an address by hand is there as a fallback for networks that block discovery
- **Hands are the controller.** Hand tracking and pinch gestures reach the PC as a pair of Valve Index controllers; a paired Switch Pro or Quest controller is optional, and its motion is attributed to whichever hand is actually holding it
- **Your desktop, in VR** — put the PC's screen on a panel you can point at, click, and move like any other window, without leaving the game
- Wrist HUD on a raised palm: quit the running title, show the desktop, or switch between emulated controllers and bare hands
- **VRChat eye tracking** — opt in on the PC and the same gaze that foveates the render also drives your avatar's eyes, over VRChat's OSC eye-look override. Off by default, because it takes over the eye channel from any other OSC eye-tracking app
- **Stream quality lever** — Performance / Balanced / Quality on the PC. Each step asks for more pixels to render and encode, so stepping down is the first thing to try when a heavy title stutters
- **Remote play over Tailscale** — the companion can advertise its tailnet address instead of a LAN one, for a PC at home or a cloud GPU host; the headset connects by IP over Tailscale. Needs a direct WireGuard path (the companion warns when the connection is being relayed, which can't carry this much video)
- Game library browsed and launched from the headset

Requires the [VisionVNC Windows Companion](#visionvnc-windows-companion-beta) on the PC, and visionOS 26.4+. It's an optional build-time feature (`FOVEATED_ENABLED`), device-only.

**On GPUs:** NVIDIA lists RTX 40-series or newer as supported for CloudXR, and it will tell you so if you have less. A 30-series card genuinely works — this was developed against a 3080 — with less headroom, so expect to sit a stream-quality step lower than a supported card would.

### Audio Streaming
- Stream bit-exact, uncompressed system audio from your Mac via the bundled **VisionVNC Companion** menu bar app (separate macOS target in this project)
- Works around macOS forcing Spatial Audio on for Mac Virtual Display audio — playback through VisionVNC honors the per-app Spatial Audio setting
- Captures system audio with a Core Audio process tap — no virtual audio driver (BlackHole etc.) required
- Optional "Mute Mac output while streaming" so audio plays only through the Vision Pro
- Float32 PCM over TCP on the local network (~3 Mbps for stereo 48 kHz), no lossy codec in the chain

### Broadcast (Vision Pro → OBS / video calls)
- Stream your **Persona camera + microphone**, or **everything you see** (Mirror My View, via a ReplayKit broadcast extension that keeps running while the app is in the background), from the Vision Pro to your computer
- Lands in OBS as a low-latency (~300–500 ms) Browser Source — from there, OBS's Virtual Camera works in Google Meet, Zoom, etc.
- Hardware H.264 + native Opus encoding, hand-rolled RTSP/RTP — no third-party media libraries
- One-button server setup from the macOS Companion, paired to the headset via an AirDropped link
- Optional end-to-end TLS (RTSPS with certificate pinning) — works safely even without a VPN

### Shared
- Multi-window interface — remote desktop, stream view, keyboard, and server list as separate visionOS windows
- Saved connections with SwiftData persistence
- Per-connection settings for both VNC and Moonlight

## Requirements

- Apple Vision Pro or visionOS Simulator
- visionOS 26.0+
- Xcode 26.0+

## Setup

### VNC Dependencies

VisionVNC uses [RoyalVNCKit](https://github.com/royalapplications/royalvnc) for the VNC protocol implementation.

1. Clone this repository:
   ```bash
   git clone https://github.com/Illixion/VisionVNC.git
   cd VisionVNC
   ```

2. Clone the RoyalVNCKit dependency:
   ```bash
   mkdir -p repos
   git clone https://github.com/royalapplications/royalvnc.git repos/royalvnc
   ```

3. Change the RoyalVNCKit library type to static in `repos/royalvnc/Package.swift`:
   ```swift
   // Change .dynamic to .static
   .library(name: "RoyalVNCKit", type: .static, targets: ["RoyalVNCKit"]),
   ```

4. Apply the configurable quality patch:
   ```bash
   cd repos/royalvnc
   git apply ../../ci/patches/royalvnc-configurable-quality.patch
   cd ../..
   ```

### Moonlight Dependencies (Optional)

Moonlight streaming requires [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) and [Opus](https://opus-codec.org/). The `MOONLIGHT_ENABLED` compilation condition must be set in Xcode build settings to include Moonlight code.

1. Clone moonlight-common-c and apply patches:
   ```bash
   git clone https://github.com/moonlight-stream/moonlight-common-c.git repos/moonlight-common-c
   cp ci/deps/moonlight-common-c/Package.swift repos/moonlight-common-c/
   cd repos/moonlight-common-c
   git apply ../../ci/patches/moonlight-common-c-commoncrypto.patch
   git apply ../../ci/patches/moonlight-common-c-fec-fix.patch
   git apply ../../ci/patches/moonlight-common-c-audio-fec-fix.patch
   cd ../..
   ```

2. Clone Opus and apply the SPM wrapper patch:
   ```bash
   git clone https://github.com/xiph/opus.git repos/opus
   cp ci/deps/opus/Package.swift repos/opus/
   cp -r ci/deps/opus/include repos/opus/spm-include
   cp -r ci/deps/opus/spm-config repos/opus/
   cd repos/opus
   git apply ../../ci/patches/opus-spm-umbrella.patch
   cd ../..
   ```

3. In Xcode, add the local packages:
   - File -> Add Package Dependencies -> Add Local -> select `repos/moonlight-common-c`
   - File -> Add Package Dependencies -> Add Local -> select `repos/opus`

4. Add `MOONLIGHT_ENABLED` to your target's Swift Active Compilation Conditions in Build Settings.

### Building

Open `VisionVNC.xcodeproj` in Xcode, then add the local packages as described above. Build and run on Apple Vision Pro or the visionOS Simulator.

The project is **arm64-only** (`ARCHS = arm64` at the project level) — Apple deprecated x86_64 with macOS Tahoe. When building for the simulator from the command line, use a concrete destination (e.g. `-destination 'platform=visionOS Simulator,name=Apple Vision Pro'`) rather than a generic one.

### Building the Companion (macOS)

> Looking for the Windows side? See [VisionVNC Windows Companion (Beta)](#visionvnc-windows-companion-beta) below.

The **VisionVNCCompanion** scheme builds the macOS menu bar app that streams system audio to VisionVNC. It has no external dependencies, so it builds even without the `repos/` setup above. Select the `VisionVNCCompanion` scheme in Xcode and run, or from the command line:

```bash
xcodebuild -project VisionVNC.xcodeproj -scheme VisionVNCCompanion -configuration Release build
# Built product:
# ~/Library/Developer/Xcode/DerivedData/VisionVNC-*/Build/Products/Release/VisionVNCCompanion.app
```

(Add `-derivedDataPath build/dd` to get the app at `build/dd/Build/Products/Release/VisionVNCCompanion.app` instead.)

Requires macOS 14.2+. On first start of streaming, grant the **System Audio Recording** permission prompt (System Settings → Privacy & Security → Screen & System Audio Recording).

**Usage:**
1. Launch VisionVNCCompanion on the Mac (speaker icon in the menu bar) and enable **Stream system audio**
2. In VisionVNC on the Vision Pro, add an **Audio** connection pointing at your Mac's IP, port 4855
3. Spatialized Stereo will be off by default, since the Mac Virtual Display's audio stream is always forced into Spatialized Stereo, so if you ever need to stream 5.1/7.1 surround just use Mac VD audio streaming instead.

### Broadcast Setup (Vision Pro → OBS)

The Broadcast feature streams the Vision Pro's Persona camera or your full view into OBS on a computer, using [mediamtx](https://github.com/bluenviron/mediamtx) as the relay. Setup is three steps:

1. **Install the relay** on the Mac:
   ```bash
   brew install mediamtx
   ```
2. **Configure it** from the VisionVNC Companion: click the menu bar icon → **Open Companion Window…** → **Broadcast (OBS)**, and press **Set Up Broadcast Server**. This generates publish credentials and a TLS certificate, writes the mediamtx config (encrypted RTSPS ingest on port 8322; any pre-existing config is backed up as `mediamtx.yml.pre-visionvnc`), and restarts the service. Then press **AirDrop** next to it to send the pairing link to your Vision Pro — it auto-fills the server address (your Tailscale IP), credentials, and the pinned certificate in VisionVNC's Broadcast tab.
3. **Add the streams to OBS** — easiest automatically: in OBS, enable **Tools → WebSocket Server Settings → Enable WebSocket server** (Apply), press **Show Connect Info → Copy Password**, then press **Add Sources to OBS** in the same companion pane — it picks the password up from the clipboard (and remembers it; you can also paste it into the field manually). This creates "Vision Pro Camera" and "Vision Pro View" Browser Sources in the current scene with audio already routed into the OBS mixer — camera visible on top, view hidden (both are full-canvas, and an idle stream's error page would cover the other source; toggle the eye icons to switch). Pressing the button again resets this layout.

   Or manually, as Browser Sources:
   - Persona/camera broadcast: `http://127.0.0.1:8889/visionpro?controls=false&muted=false`
   - Mirror My View: `http://127.0.0.1:8889/visionpro-view?controls=false&muted=false`

   Keep `muted=false` (a muted page produces no audio at all) and check **"Control audio via OBS"** on each source so the stream's audio lands in the OBS mixer instead of playing on the desktop.

   Use **Start Virtual Camera** in OBS to feed the result into Google Meet, Zoom, etc.

On the headset, the Broadcast tab starts the camera stream; the **Mirror My View** button opens the system View Sharing picker, which streams everything you see — including while VisionVNC is in the background.

**Security:** the stream is end-to-end encrypted (RTSPS; the headset pins the companion-generated certificate, so no CA and no VPN are required), publishing requires the generated credentials, and playback is restricted to the Mac itself (`127.0.0.1`). Tailscale is still the recommended transport — the companion advertises the Mac's Tailscale IP in the pairing link — but with TLS active, any network path works.

## VisionVNC Windows Companion (Beta)

`CompanionWindows/` is a general-purpose Windows companion app with one Electron UI and elevated .NET backend. It currently provides two features:

- **Wi-Fi Hotspot** for **using a Vision Pro with a Windows machine in public** — cafés, hotels, conference Wi-Fi, anywhere the two devices can't reach each other on the shared network.
- **Foveated Streaming (CloudXR) host** that advertises this PC to Vision Pro, manages the foveated-streaming session, and drives the NVIDIA CloudXR runtime for desktop OpenXR content — including carrying the headset's real gaze through to the game, so rendering is foveated on the PC rather than uniform.

For Hotspot, normally VNC and Moonlight need both devices on the same LAN, and most public Wi-Fi blocks client-to-client traffic (AP isolation) — so streaming simply doesn't work. The companion turns the **Windows host into its own NAT'd Wi-Fi access point** that the Vision Pro joins directly. From the venue's perspective there's a single client (the Windows PC); the headset rides *behind the PC's NAT*, so it keeps internet **and** gets a direct, low-latency path to the local Sunshine/VNC server at the gateway (`192.168.137.1`). The visionOS app auto-fills that gateway as the host when it detects it's on such a network.

It's a standalone **Node + .NET** project (Electron UI over an elevated .NET backend using the Windows Mobile Hotspot API and CloudXR host components).

**Install:** download the latest installer for your CPU from the [Releases](../../releases) page and run it — no need to install toolchains or compile anything (which is a pain on Windows). Both architectures are built natively:
- `VisionVNCWindowsCompanion-…-x64-Setup.exe` — Intel / AMD PCs
- `VisionVNCWindowsCompanion-…-arm64-Setup.exe` — Windows on ARM (Snapdragon X-class laptops)

The installers are built by CI and ship with a **signed build-provenance attestation**, so you can prove the download was produced by this repo's workflow from a specific commit and wasn't tampered with:

```bash
gh attestation verify VisionVNCWindowsCompanion-<version>-<arch>-Setup.exe --repo illixion/VisionVNC
```

Prefer to build it yourself? See [`CompanionWindows/README.md`](CompanionWindows/README.md).

> ⚠️ **Beta quality — test before you rely on it.** This has been validated end-to-end on real hardware, but only with **one USB Wi-Fi adapter** (a TP-Link Archer T2U / RTL8811AU); it has **not** been tested across the wide variety of Wi-Fi chipsets and drivers out there. Whether it works on your machine depends entirely on your adapter's driver:
> - The host needs a Wi-Fi adapter whose driver can **host an AP** (SoftAP or Wi-Fi-Direct-GO). Many built-in laptop adapters are **station-only and cannot host at all** — in that case you'll need an inexpensive **USB Wi-Fi adapter**. Check with `netsh wlan show wirelesscapabilities`.
> - Sharing a **wired (Ethernet) upstream** is the most reliable setup. Sharing a Wi-Fi upstream over a *single* radio (STA + AP on one adapter) is unstable; the café Wi-Fi scenario realistically needs Ethernet or a second/dual-band adapter.
> - Treat it as something to **manually test on your specific hardware** before depending on it for a trip. See `CompanionWindows/spike/SPIKE-FINDINGS.md` for the full hardware/driver findings.

## Architecture

The app uses a multi-window SwiftUI architecture with two independent protocol paths sharing a common connection list and persistence layer:

```
VisionVNCApp
├── VNC Path
│   ├── VNCConnectionManager      — RoyalVNCKit bridge, @Observable
│   ├── RemoteDesktopView         — Framebuffer display + gesture input
│   └── KeyboardInputView         — Keyboard window (VirtualKeyboardView + VNCKeyboardSink)
│
├── Moonlight Path (#if MOONLIGHT_ENABLED)
│   ├── MoonlightConnectionManager — Session orchestrator, state machine
│   ├── NvHTTPClient              — GameStream HTTP/HTTPS API (NWConnection)
│   ├── NvPairingManager          — PIN-based challenge-response pairing
│   ├── CryptoManager             — X.509/PKCS#12/AES via CommonCrypto
│   ├── MoonlightVideoRenderer    — H.264/HEVC/AV1 via AVSampleBufferDisplayLayer + HDR
│   ├── MoonlightAudioRenderer    — Opus multistream via AVAudioEngine
│   ├── MoonlightGamepadManager   — GameController framework bridge
│   ├── MoonlightStreamBridge     — C callback marshalling to Swift
│   ├── MoonlightStreamView       — Stream display + gesture/mouse input
│   └── MoonlightKeyboardView     — Keyboard window (VirtualKeyboardView + MoonlightKeyboardSink)
│
├── Audio Path
│   ├── AudioStreamManager        — Stream state, @Observable
│   ├── AudioStreamReceiver       — NWConnection → AVAudioEngine playback
│   └── AudioStreamView           — Stream status window
│
├── Broadcast Path
│   ├── BroadcastManager          — Capture/encode/publish orchestrator, @Observable
│   ├── BroadcastCore/            — Shared pipeline: VideoToolbox H.264 + native Opus → RTP/RTSP(S)
│   ├── BroadcastExtension/       — ReplayKit upload extension ("Mirror My View", runs in background)
│   └── BroadcastView             — Broadcast tab: preview, settings, view-sharing picker
│
└── Shared
    ├── SavedConnection           — SwiftData model (VNC + Moonlight settings)
    ├── ConnectionListView        — Unified server list, routes by type
    └── ConnectionFormView        — Per-connection settings form

CompanionMac/ → VisionVNCCompanion (macOS menu bar app)
├── SystemAudioTap                — Core Audio process tap + aggregate device
├── AudioStreamServer             — TCP server, int24 PCM frames
├── BroadcastServerManager        — One-button mediamtx setup + pairing link + OBS provisioning
├── OBSWebSocketClient            — obs-websocket v5: creates the OBS Browser Sources
├── CompanionApp                  — Menu bar popover (quick audio controls)
└── CompanionWindowView           — Multi-pane companion window (token / broadcast / SSH / keyboard)

CompanionWindows/ (PoC, Node + .NET) — VisionVNC Windows Companion
├── backend/                      — .NET 8 worker: Hotspot AP+NAT, named-pipe RPC (open source, built by CI)
└── app/                          — Electron UI (Hotspot, Foveated Streaming, and Game library panels);
                                     downloads the closed-source Foveated Streaming (CloudXR) host on demand

VisionVNC-PCVR-Host/, SessionBroker/, OpenXRLayer/ — closed-source, private git submodules (no
                                     public source); the Foveated Streaming/CloudXR host + native
                                     OpenXR bridge the Electron UI fetches on demand, never bundled

Shared/AudioStreamProtocol.swift  — wire format, compiled into both visionOS + macOS targets
```

### How Moonlight Streaming Works

This app integrates the **moonlight-common-c** protocol library — the same C core used by [Moonlight Qt](https://github.com/moonlight-stream/moonlight-qt), [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios), and [Moonlight Android](https://github.com/moonlight-stream/moonlight-android). Rather than porting one of the full Moonlight client apps to visionOS (which would require rewriting their entire UI layer), VisionVNC embeds only the protocol library and provides native visionOS implementations of:

- **Video decoding** — `AVSampleBufferDisplayLayer` for hardware H.264/HEVC/AV1 decoding with native HDR10 support. Compressed video frames are enqueued directly to the display layer as `CMSampleBuffer`s — the layer handles decoding, HDR tone mapping, and rendering. AV1 bitstream parsing uses a custom OBU parser for sequence header extraction.
- **Audio decoding** — `opus_multistream_decode()` feeding `AVAudioEngine` with `AVAudioPlayerNode`
- **Crypto** — CommonCrypto and Security.framework replace OpenSSL for all pairing, TLS, and stream encryption operations
- **Networking** — `NWConnection` (Network.framework) replaces URLSession for HTTP, enabling custom TLS cert verification and client certificate mutual authentication with Sunshine's self-signed certs
- **Input** — Native `GameController` framework for gamepads, `UIKeyboardHIDUsage` capture for hardware keyboards, mapped to Windows VK codes

The moonlight-common-c library handles RTSP session negotiation, RTP stream demuxing, FEC error correction, and the control protocol. It communicates with Swift through C function pointer callbacks (video frames, audio samples, connection events) that are marshalled to Swift via a bridge layer with global renderer references.

### Patches Applied to moonlight-common-c

The dependencies require several patches for visionOS compatibility (applied automatically in CI, see `ci/patches/`):

| Patch | Purpose |
|-------|---------|
| `moonlight-common-c-commoncrypto.patch` | Replaces OpenSSL with CommonCrypto/Security.framework for AES-GCM encryption, SHA/HMAC operations, and random number generation. Avoids shipping a large OpenSSL binary on Apple platforms. |
| `moonlight-common-c-fec-fix.patch` | Fixes a crash in audio FEC (Forward Error Correction) recovery when packets arrive out of order |
| `moonlight-common-c-audio-fec-fix.patch` | Fixes compatibility with newer Sunshine server versions that changed audio FEC parameters |
| `royalvnc-configurable-quality.patch` | Adds configurable JPEG quality and compression levels to RoyalVNCKit (hardcoded at level 6), plus `pauseFramebufferUpdates()` API for trackpad-only mode |

Opus is wrapped as a local SPM package with a custom `module.modulemap` that exposes the multistream decoder API (`opus_multistream_decoder_create`, `opus_multistream_decode`) which is not included in Opus's default public headers.

## Contributing

Contributions are welcome! Please feel free to submit a pull request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## Third-Party Software

This project uses the following open-source libraries:

- [RoyalVNCKit](https://github.com/royalapplications/royalvnc) by Royal Apps — MIT License
- [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) by Moonlight Game Streaming Project — GPLv3 License
- [Opus](https://opus-codec.org/) by Xiph.Org Foundation — BSD 3-Clause License
- [ENet](http://enet.bespin.org/) (bundled with moonlight-common-c) — MIT License

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full license texts.

The Windows companion is a separate codebase with its own dependencies and its own notices —
see [CompanionWindows/THIRD_PARTY_NOTICES.md](CompanionWindows/THIRD_PARTY_NOTICES.md), which
also records what the optional PCVR download contains and what it deliberately does not.

## License

This project is licensed under the **MIT License** — see [LICENSE.txt](LICENSE.txt) for details.

**Moonlight support** is an optional build-time feature controlled by the `MOONLIGHT_ENABLED` compilation condition. When Moonlight is enabled, the resulting binary links against [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3) and [Opus](https://opus-codec.org/) (BSD 3-Clause), and the combined work falls under the **GPLv3**. When Moonlight is disabled (the default for the open-source build), no GPLv3 code is compiled or linked, and the application remains purely MIT-licensed.
