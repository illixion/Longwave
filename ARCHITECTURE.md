# VisionVNC Architecture

## Multi-Window Design

Seven `WindowGroup` scenes in `VisionVNCApp` (two conditionally compiled):

1. **Main window** (`id: "main"`) — `MainView` with a bottom-ornament tab bar: **Connections** (`ConnectionListView`, SwiftData-backed server list), **Settings** (`SettingsView`, new-connection defaults via `@AppStorage`/`ConnectionDefaults`), **Console** (`ConsoleView`, in-app log viewer)
2. **Console** (`id: "console"`) — pop-out `ConsoleView`, 760x480
3. **Audio Stream** (`id: "audio-stream"`) — `AudioStreamView` mini player, 400x540
4. **Remote Desktop** (`id: "remote-desktop"`) — `RemoteDesktopView` for VNC, 1280x800 default
5. **Keyboard** (`id: "keyboard"`) — `KeyboardInputView` for VNC, 500x400
6. **Moonlight Stream** (`id: "moonlight-stream"`) — `MoonlightStreamView`, 1920x1080 default (`#if MOONLIGHT_ENABLED`)
7. **Moonlight Keyboard** (`id: "moonlight-keyboard"`) — `MoonlightKeyboardView`, 500x450 (`#if MOONLIGHT_ENABLED`)

`VNCConnectionManager`, `AudioStreamManager`, and `MoonlightConnectionManager` are injected via `.environment()`. Connection type routing happens in `ConnectionListView` — VNC/audio connections open their windows as plain siblings (`openWindow(id:)`), Moonlight presents `MoonlightPairingView` as a sheet which opens the stream window on launch.

**Window navigation:** connection windows open as sibling windows (`openWindow(id:)`) so the main window stays open alongside — surfacing one window never dismisses the other. The main window is value-typed with a single constant identity (`MainWindowID.shared`); every `openWindow(id: "main", value:)` reactivates that one instance rather than spawning a duplicate. Sub-windows carry a Home ornament (`.homeOrnament()`, bottom-front) that opens `id: "main"` — needed because visionOS reopens the last-used window on app launch. The audio mini player instead has home + reload buttons in its utility row (the ornament overlapped its transport controls).

## Key Types — VNC

| Type | Role |
|------|------|
| `VNCConnectionManager` | `@Observable` + `NSObject` + `VNCConnectionDelegate`. Bridge between RoyalVNCKit and SwiftUI. Manages connection lifecycle, CADisplayLink-throttled rendering, credential flow, and input forwarding. |
| `GestureTranslator` | Aspect-ratio-aware coordinate conversion from view space to VNC framebuffer coordinates. |

## Key Types — Moonlight

| Type | Role |
|------|------|
| `MoonlightConnectionManager` | `@Observable`. Central orchestrator — state machine (idle → connecting → pairing → ready → streaming), owns all sub-components, manages CADisplayLink for frame delivery. |
| `NvHTTPClient` | GameStream HTTP/HTTPS client using `NWConnection` (Network.framework). Talks to Sunshine's XML API for server info, app list, launch/resume/quit. Bypasses ATS via custom TLS with client cert mutual auth. |
| `NvPairingManager` | Challenge-response pairing handshake. Derives AES key from PIN+salt, exchanges encrypted challenges, verifies RSA signatures. Supports SHA-256 (server gen >= 7) and SHA-1 (legacy). |
| `CryptoManager` | RSA 2048 key pair generation (Keychain-backed), self-signed X.509 cert builder (ASN.1 DER), PKCS#12 packaging for TLS client identity, AES-128-ECB for pairing. All via CommonCrypto/Security.framework — no OpenSSL. |
| `MoonlightVideoRenderer` | H.264/HEVC/AV1 video via `AVSampleBufferDisplayLayer`. Processes Annex B NAL units (H.264/HEVC) or OBUs (AV1) from moonlight-common-c, extracts parameter sets, creates `CMVideoFormatDescription` with HDR metadata extensions (MDCV/CLL), and enqueues `CMSampleBuffer`s to the display layer which handles hardware decoding and HDR rendering. |
| `MoonlightAudioRenderer` | Opus multistream decoding → `AVAudioEngine` + `AVAudioPlayerNode`. Supports stereo, 5.1, and 7.1 channel configs. Can be muted (decoder still runs for protocol, but AVAudioEngine skipped). |
| `MoonlightStreamBridge` | C callback marshalling layer. Global `nonisolated(unsafe)` references to active renderers/delegate, with C-compatible callback functions that forward to Swift. |
| `MoonlightGamepadManager` | `GameController` framework bridge for up to 4 Bluetooth gamepads (DualSense, Xbox, etc.). Maps analog sticks, triggers, DPAD, and buttons with optional A/B X/Y swap. |
| `MoonlightKeyCodes` | Mapping tables from `UIKeyboardHIDUsage` → Windows Virtual Key codes (VK_*), used for keyboard input to the stream. |
| `MoonlightModels` | Data types: `ServerInfo`, `MoonlightApp`, `MoonlightStreamConfig`, `StreamStats`. |

## Key Types — Audio Streaming

| Type | Role |
|------|------|
| `AudioStreamProtocol` / `AudioStreamHeader` | Wire format **v6** (in `Shared/`, compiled into both targets). TCP: 16-byte header (magic `VVAS`, version=6, channels, Float64 sample rate), then typed length-prefixed frames `[UInt32 len][UInt8 type][payload]`: `pcm` 0x00 (interleaved **signed int24**, little-endian, 3 bytes/sample — see `PCM24`; v6 replaced the Float32 wire format for a 25% bandwidth cut, decoded back to Float32 for AVAudioEngine at the receiver), `nowPlaying` 0x01 (JSON), `artwork` 0x02 (scaled JPEG, sent before its matching nowPlaying), `command` 0x03 (JSON, client→server), `udpHello` 0x06 / `keepAlive` 0x07 (low-latency UDP path). Little-endian. Default port 4855. Version mismatch hard-fails at header parse (both apps released together). |
| `NowPlayingInfo` / `MediaCommand` (Shared) | Codable payloads: track metadata snapshot (elapsed extrapolated client-side while playing, `artworkID` = Music persistent ID) and transport commands (play/pause/toggle/next/previous). |
| `AudioStreamManager` (visionOS) | `@Observable` MainActor state holder; owns an `AudioStreamReceiver`. Persists last connection (UserDefaults) and auto-reconnects on space restoration / scenePhase activation (`ensureConnected()`, 2.5 s data-activity health probe) with capped-backoff retry on drops; immediate reload on `.reloadRequested` (audio session lost). `userDisconnect()` clears persistence; window close uses a 2 s grace teardown. |
| `AudioStreamReceiver` (visionOS) | `@unchecked Sendable`, off-main NWConnection receive loop → AVAudioEngine/AVAudioPlayerNode. Prebuffers 4 frames before `play()` to absorb jitter. Local mute drops PCM (no backlog). Observes audio-session interruption/engine-config-change/silence-hint and emits `.reloadRequested`. |
| `SystemAudioTap` (macOS) | Core Audio process tap (`CATapDescription` global stereo mixdown, macOS 14.2+) hosted in a private aggregate device; IOProc converts the tap's Float32 to interleaved int24 (the wire format) before delivery. `muteSystemOutput` uses `.muted` tap behavior — silences local/Sidecar output while capturing (the whole point: only the streamed copy is audible). Mute change requires tap restart. No BlackHole/virtual driver needed. Requires TCC "System Audio Recording" (NSAudioCaptureUsageDescription). |
| `AudioStreamServer` (macOS) | NWListener TCP server, **single client (newest-wins: new connection displaces the old)**, per-client backpressure: PCM frames dropped for a client >200 KB behind (latency cap). Metadata/artwork frames bypass the cap and are replayed to newly connected clients after the header. Inbound loop parses `command` frames → `onCommand`. |
| `AudioStreamerController` (macOS) | `@Observable` orchestrator behind the `MenuBarExtra` UI in `CompanionApp`. Tap starts **unmuted**; restarts muted on the 0→1 client edge and unmuted on 1→0 (mute only while someone is listening). |
| `MusicAppBridge` (macOS) | Music.app metadata + control via public APIs only: `DistributedNotificationCenter` `com.apple.Music.playerInfo` (event-driven) + `NSAppleScript` one-shots for artwork (≤600 px JPEG, on track change), player position, and transport. Every script call is guarded by an `NSRunningApplication` check. Needs `NSAppleEventsUsageDescription` / one-time Automation TCC. |

## Shared Types

| Type | Role |
|------|------|
| `SavedConnection` | `@Model` (SwiftData). Persists hostname, port, label, connection type, quality settings. Extended with ~15 Moonlight-specific optional properties (bitrate, FPS, resolution, codec, audio config, touch mode, etc.). Server cert and UUID stored in UserDefaults (binary data not suitable for SwiftData). |
| `ConnectionType` | Enum: `.vnc` / `.moonlight` (conditionally compiled) / `.audio`. Discriminates routing and form fields. |
| `ConnectionDefaults` | UserDefaults-backed new-connection defaults (VNC quality/touch mode, ports, Moonlight video/audio/input), edited in the Settings tab and seeded into `ConnectionFormView` for new connections. |

## Moonlight Connection State Machine

```
idle → connecting → fetchingServerInfo → pairing(pin:) → paired → fetchingApps → ready → launching → streaming
                                                                                                         ↓
Any state can transition to: error(String)                                                         stopStreaming → idle
```

## Threading Patterns

**VNC:** Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, all VNCConnectionDelegate methods must be `nonisolated` with `Task { @MainActor in }` dispatching. RoyalVNCKit is imported with `@preconcurrency import RoyalVNCKit`.

**Moonlight:** moonlight-common-c fires C callbacks on background threads. The bridge uses global `nonisolated(unsafe)` pointers to renderers (only one stream active at a time). Hot paths (video sample buffer creation, audio decode) stay on the callback thread for performance. State updates marshal to MainActor via `Task { @MainActor in }`. Renderers are `@unchecked Sendable` — they contain unsafe pointers (AVSampleBufferDisplayLayer, Opus decoder) accessed from the callback thread.

## Video Pipeline (Moonlight)

```
moonlight-common-c (C, background thread)
  → drSubmitDecodeUnit(DECODE_UNIT*)
    → MoonlightVideoRenderer.submitDecodeUnit()
      → H.264/HEVC: Extract Annex B NAL units, detect SPS/PPS/VPS, convert to AVCC (4-byte length prefix)
      → AV1: Concatenate OBU data, parse sequence header on IDR for format description
      → Create/update CMVideoFormatDescription (with HDR MDCV/CLL extensions if active)
      → Create CMSampleBuffer with PTS from rtpTimestamp (90kHz timescale)
      → AVSampleBufferDisplayLayer.enqueue() — layer handles hardware decode + display + HDR tone mapping
        → VideoDisplayView (UIViewRepresentable) hosts the layer in MoonlightStreamView
```

## Audio Pipeline (Moonlight)

```
moonlight-common-c (C, background thread)
  → arDecodeAndPlaySample(sampleData, sampleLength)
    → MoonlightAudioRenderer.decodeAndPlaySample()
      → opus_multistream_decode() → Int16 PCM
        → AVAudioPCMBuffer → AVAudioPlayerNode.scheduleBuffer()
```

## Framebuffer Rendering (VNC)

`CADisplayLink` throttles framebuffer updates at 30-90 FPS (preferred 60). The delegate sets `pendingImageUpdate = true` on each framebuffer update, and the display link callback reads `framebuffer.cgImage` only when the flag is set.

## Credential Flow (VNC)

1. `connect()` stores username/password temporarily
2. When the delegate's `credentialFor` callback fires, auto-submits stored credentials if available (supports both VNC password-only and ARD username+password auth)
3. Falls back to presenting `CredentialPromptView` as a sheet if no stored credentials

## Keyboard Input

**VNC:**
- `HardwareKeyboardView` — `UIViewRepresentable` wrapping `KeyCaptureView` that overrides `pressesBegan`/`pressesEnded` to intercept hardware/Bluetooth keyboard events. Maps `UIKeyboardHIDUsage` → X11 KeySymbol-based `VNCKeyCode`.
- `KeyboardInputView` — Separate window with soft keyboard controls.

**Moonlight:**
- `MoonlightHardwareKeyboardView` — Same pattern but maps `UIKeyboardHIDUsage` → Windows VK codes via `MoonlightKeyCodes`, sends via `LiSendKeyboardEvent()`.
- `MoonlightKeyboardView` — Separate window with soft keyboard, modifier toggles, special keys, function keys. Text input sends character-by-character key events.

## Mouse/Gesture Input (Moonlight)

Two modes controlled by `SavedConnection.moonlightTouchMode`:
- **Relative** (default, for games): Drag gestures send incremental mouse deltas via `LiSendMouseMoveEvent()`
- **Absolute** (for desktop): Tap/drag positions mapped to stream resolution via `LiSendMousePositionEvent()`

Gestures: single tap = left click, double tap = right click, two-finger press-and-hold = right click, scroll wheel via `LiSendScrollEvent()`.

## Gamepad Input (Moonlight)

`MoonlightGamepadManager` uses `GameController` framework. Supports up to 4 Bluetooth controllers. Maps GCExtendedGamepad inputs to `LiSendMultiControllerEvent()` with button flags, trigger pressure, and analog stick values. Optional A/B X/Y swap for Nintendo layout.

## Window Lifecycle

- Closing the remote desktop / stream window triggers `onDisappear` which disconnects and closes the keyboard window. The audio window instead uses a 2 s grace teardown (visionOS fires transient onDisappear during space restoration).
- Pressing Disconnect immediately closes the windows; server-initiated VNC disconnect auto-closes after 1 second
- Uses `dismissWindow(id:)` (not `dismiss()`) for proper `WindowGroup` window management
- **visionOS refuses to programmatically close the app's last window.** Connection windows open as siblings, so before dismissing one a window unconditionally re-surfaces the main window via `openWindow(id: "main", value: MainWindowID.shared)`. That's a no-op when main is already open (value-matching reactivates the single instance) and correctly restores it after a space-restoration relaunch brought back only a sub-window. (Earlier this used `pushWindow` + an `openedViaPush` flag; pushing buried main in a back-stack, and reactivating it popped the pushed window off the stack — closing the connection's window and tearing down the session.)
- Moonlight disconnect offers choice: end session on server (quit app) or keep running (local disconnect only)

## Moonlight Networking Details

**NvHTTPClient** uses `NWConnection` (Network.framework) instead of `URLSession` because:
- Sunshine uses self-signed TLS certs — `NWConnection` allows custom cert verification without ATS exceptions
- Mutual TLS authentication requires presenting client identity (PKCS#12) during handshake
- HTTP/1.1 requests are manually constructed and responses parsed (strip headers, extract XML body)

**XML Parsing:** Three `NSXMLParser` subclasses handle different response formats — flat key-value (server info), display mode lists, and app lists with HDR flags.

**Audio config encoding** for the `/launch` request: `((channelMask) << 16) | (channelCount << 8) | 0xCA` — e.g., stereo = `0x302CA`, 5.1 = `0x3F06CA`.
