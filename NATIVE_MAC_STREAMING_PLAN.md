# Native Streaming Roadmap

## Goal

Replace Mac Virtual Display for LAN and optional Tailscale use with a native,
encrypted host stream that supports transparent windows, remote input, and
Unity-style per-window visionOS presentation — on macOS and Windows hosts.

## Status

- Transparent desktop milestone: **implemented** (see below).
- Phase 1 (mouse/keyboard control): **implemented** — pointer/scroll/key
  frames, CGEvent injection behind Accessibility, independent mouse and
  keyboard-shortcut toggles, drag synthesis, double/triple-click detection.
- Phase 3 (per-window streaming): **implemented, v1 scope** — protocol v2
  multiplexes a published window inventory and per-window HEVC-alpha streams
  over the one authenticated session; each streamed window is its own
  chrome-free visionOS scene; input routes through the window's live frame
  with raise-before-click. Encoder budget is a flat 6-stream cap with
  area-scaled bitrate (no focus-based FPS tiering yet); minimized/other-Space
  windows end their stream rather than pausing it.
- **Windows host: implemented** — the Windows companion backend serves the
  same protocol on the same port (BouncyCastle TLS-PSK, Windows.Graphics.
  Capture, hardware HEVC MFT, SendInput with HID-usage keycodes), integrated
  into the Electron app with a Screen Streaming card (enable, token, input
  toggles). Desktop is opaque (`hevcParameterSets` format kind); per-window
  streams work the same way. Verified end-to-end against a Network.framework
  client on the RTX 3080 host. Intended to double as Desktop View for PCVR
  mode once merged into `appstore/pcvr`.

## First Milestone: Transparent Desktop

Implemented:

- ScreenCaptureKit composition of visible Mac application windows over clear.
- Realtime VideoToolbox HEVC-with-alpha encoding.
- Exact CoreMedia format-description transport so alpha metadata survives.
- Transparent visionOS playback in a single value-typed window.
- Domain-separated encrypted transport on port 4857.
- One authenticated viewer at a time; a new viewer replaces the previous one.
- macOS connection/takeover notifications.
- Manual LAN, hostname, IP, or Tailscale addressing and Bonjour advertisement.

### Device Gate

Before adding input or splitting streams, verify on a physical Vision Pro:

1. The first frame appears and remains low latency.
2. Wallpaper and empty desktop regions reveal the real environment.
3. Rounded corners, shadows, and translucent/vibrant content preserve alpha.
4. Window resizing preserves aspect ratio without opaque backing.
5. A second authenticated viewer replaces the first and both UIs report it.
6. Capture or decoder failures close the session with a useful error.

If `AVSampleBufferVideoRenderer` does not preserve alpha on device, prototype a
VideoToolbox decompression session feeding Metal/RealityKit before continuing.

## Phase 1: Mouse and Keyboard Control

- Extend the framed protocol with versioned pointer, scroll, button, key, and
  text events.
- Map absolute pointer coordinates through the displayed content rectangle to
  Mac display coordinates.
- Inject events with CoreGraphics on the companion under Accessibility TCC.
- Support hardware keyboards and the existing virtual keyboard model.
- Add an explicit per-session control toggle and show control state in the Mac
  notification/UI.
- Release held buttons and modifiers on disconnect or viewer takeover.

Acceptance: Finder, window dragging/resizing, scrolling, shortcuts, text entry,
and takeover cleanup all work without stuck input.

## Phase 2: Complete Desktop Surfaces

- Add an opaque raw-display mode for workflows that need every system surface.
- Add a dedicated Mac Chrome stream/window for Dock, Menu Bar, menus, and
  transient system UI omitted from the transparent desktop composition.
- Let users switch between transparent desktop, opaque display, and Chrome
  surfaces without reconnecting.
- Link the existing companion audio stream to Native Mac connections.

Acceptance: users can reach Dock/Menu Bar and choose full-fidelity opaque
capture when transparency is not appropriate.

## Phase 3: Unity-Style Per-Window Streaming — implemented (v1 scope)

Done:

- Stable window identity (CGWindowID / HWND low 32 bits) with a 1 s inventory
  publisher (title, owning app, point size, focus) pushed as `windowList`.
- Independent window streams multiplexed over the one authenticated session
  (`windowStreamStart/Stop`, per-stream format descriptions and video frames,
  `windowClosed`, `focusWindow`, per-window mouse frames).
- One chrome-free value-typed visionOS scene per streamed window (aspect-fit,
  no ornament); the Native window doubles as the controller (window picker +
  audio + session controls); scenes self-dismiss on host-side close and
  resubscribe after transient scene teardowns and reconnects.
- Focus/input routing to the correct host window, raising it first when a
  click would land on an occluding window.
- Sheets/child windows are captured into their parent stream
  (`includeChildWindows`); app termination and Space changes end the stream
  cleanly via the inventory poll.

Remaining (follow-up):

- Minimized windows end their stream instead of pausing/thumbnails.
- Encoder budgeting is a flat 6-stream cap with area-scaled bitrate — no
  focus-based FPS tiering or grouped-composition fallback yet.
- No dedicated child-window/popover scenes.

## Windows Host — implemented

The Windows companion backend (`CompanionWindows/backend/NativeStream/`)
serves the same wire protocol on port 4857: TLS 1.2 PSK via BouncyCastle
(SChannel exposes no PSK suites), Windows.Graphics.Capture sources (primary
monitor = stream 0, `CreateForWindow` per window), a GPU-only encode path
(hardware HEVC MFT, ARGB32 direct input where the driver allows, Video
Processor MFT fallback), Annex-B repacked to length-prefixed NALs with
VPS/SPS/PPS as the `hevcParameterSets` format kind, and SendInput injection
from raw HID usages. Opaque desktop (no alpha), remote control on by default
(the token is the consent gate). Enable/token/input toggles live in the
Electron app's Screen Streaming card and the `NativeStream*` pipe RPCs.

## Phase 4: Discovery and TLS 1.3 Identities

- Add Bonjour browsing and one-tap host selection to the connection form.
- Replace external TLS 1.2 PSK with TLS 1.3 pinned companion identities.
- Pair the headset and Mac using the existing companion trust flow, with
  certificate rotation and explicit device revocation.
- Preserve manual addresses for routed LANs and Tailscale.

Acceptance: first connection is discoverable and pairable without typing a
token, subsequent connections authenticate with pinned identities, and revoked
devices cannot displace the active viewer.

## Phase 5: Performance and Productization

- Add adaptive bitrate, frame pacing, congestion feedback, and resolution/FPS
  controls.
- Measure capture, encode, network, decode, and presentation latency separately.
- Add reconnect/resume behavior, connection diagnostics, and sustained-session
  memory/thermal testing.
- Add notification actions for Disconnect and Disable Control.
- Expand protocol tests and add loopback takeover/keyframe integration tests.

Acceptance: stable multi-hour use on LAN, bounded latency under congestion, and
actionable diagnostics when capture, transport, or decoding fails.
