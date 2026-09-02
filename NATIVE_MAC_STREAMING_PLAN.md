# Native Streaming Roadmap

## Goal

Replace Mac Virtual Display for LAN and optional Tailscale use with a native,
encrypted host stream that carries the host's whole desktop, supports remote
input, and offers Unity-style per-window visionOS presentation — on macOS and
Windows hosts.

## Status

- Full desktop milestone: **implemented** (see below). Was a transparent
  application-window composition; now the complete display.
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

## First Milestone: Full Desktop

Implemented:

- ScreenCaptureKit capture of the entire Mac display: desktop picture, menu bar,
  Dock, Stage Manager strip, notifications, menus and every window.
- Native (Retina) capture scale, capped so the long edge stays within 4096 px,
  with the bitrate scaled to the encoded area. Stream coordinates are therefore
  **pixels, not points** — the host divides by the stream's pixels-per-point
  before injecting a `CGEvent`, exactly as per-window streams already did.
- Realtime VideoToolbox HEVC encoding, opaque (`kCMVideoCodecType_HEVC`).
- Exact CoreMedia format-description transport, so the receiver rebuilds the
  format the encoder actually produced rather than approximating it.
- Opaque visionOS playback in a single value-typed window, corner-rounded so the
  display reads as a panel rather than a pasted-in rectangle.
- Domain-separated encrypted transport on port 4857.
- One authenticated viewer at a time; a new viewer replaces the previous one.
- macOS connection/takeover notifications.
- Manual LAN, hostname, IP, or Tailscale addressing and Bonjour advertisement.

### Why it stopped being transparent

The first implementation composited only visible application windows over a
clear background and shipped it as HEVC-with-alpha, so the wallpaper's place
showed the real room. It looked striking and cost too much: the menu bar and
Dock were not in the frame at all, so nothing reachable only through them —
menu-bar menus, menu-bar extras, Mission Control, the desktop itself — could be
used from the headset. `MacNativeStreamProtocol.HelloAck.supportsTransparentDesktop`
is now `false` on every host and kept only so older clients still decode the ack.

The alpha-preserving presentation was not lost, it moved: a **per-window** stream
(Phase 3) is exactly one Mac window, rounded, shadowed and vibrant, composited
over passthrough in its own chrome-free scene. That is where a floating Mac
window belongs; the desktop stream is the desktop.

### Device Gate

Verify on a physical Vision Pro:

1. The first frame appears and remains low latency.
2. Wallpaper, menu bar and Dock are all present, and menu-bar text is sharp
   (the stream is Retina — if it looks soft, `pointPixelScale` came back 1).
3. Clicks land where they are aimed, including near the right and bottom edges
   — a missed pixels-to-points divide shows up as a 2x offset that grows with
   distance from the display's origin.
4. Menu-bar and Dock menus open and can be clicked through.
5. Window resizing preserves aspect ratio; letterboxing is black, not garbage.
6. A second authenticated viewer replaces the first and both UIs report it.
7. Capture or decoder failures close the session with a useful error.
8. A per-window stream still preserves alpha (rounded corners, shadow, vibrancy).

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

## Phase 2: Complete Desktop Surfaces — implemented

The full-desktop milestone above subsumed this. Opaque whole-display capture *is*
the desktop stream, so Dock, Menu Bar, menus and transient system UI are all in
frame and there is no mode to switch between and no separate Chrome stream to
build. Companion audio is linked to Native connections (the `supportsAudioStream`
capability plus the Audio toggle in the Native window and Unity Controls).

Not done, and deliberately: there is no way to get the old transparent
composition back. If a use case for it reappears it should return as a *filtered*
stream alongside the desktop, not as a mode that replaces it.

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
- Unity Controls carries the whole session: desktop toggle, pointer mode,
  keyboard, audio, the audio mini-player pop-out, and the window chips. It has
  to — a Unity session's desktop scene is usually closed, and it is the only
  window with an ornament-free path to any of that.
- Focus/input routing to the correct host window, raising it first when a
  click would land on an occluding window.
- Sheets/child windows are captured into their parent stream
  (`includeChildWindows`); app termination and Space changes end the stream
  cleanly via the inventory poll.
- Idle sessions cost close to nothing: with no window streaming, the inventory
  poll drops to 5 s and `isFocused` changes coalesce to one republish per 5 s,
  so a session that is only carrying audio is not enumerating windows every
  second or pushing a fresh inventory on every ⌘-Tab. Nothing else on the
  connection ticks — the native stream and injection channels are purely
  event-driven, with no heartbeat of their own.

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
