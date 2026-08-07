# Native Mac Streaming Roadmap

## Goal

Replace Mac Virtual Display for LAN and optional Tailscale use with a native,
encrypted Mac stream that supports transparent windows, remote input, and
eventually VMware Unity-style per-window visionOS presentation.

## Current Milestone: Transparent Desktop

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

## Phase 3: Unity-Style Per-Window Streaming

- Track ScreenCaptureKit windows by stable window identity and publish window
  inventory, title, owning app, frame, visibility, and lifecycle changes.
- Multiplex independent window streams over one authenticated session.
- Create value-typed visionOS windows per Mac window and preserve aspect ratio.
- Route focus and input to the correct Mac window.
- Handle child windows, sheets, popovers, minimized windows, app termination,
  Space changes, and display changes.
- Budget encoders dynamically: prioritize focused/visible windows, reduce FPS
  for background windows, and fall back to grouped composition when necessary.

Acceptance: opening, closing, moving, focusing, and interacting with common Mac
application windows behaves like Unity mode without orphaned visionOS scenes.

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
