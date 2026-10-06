# Apple Watch Roadmap

## Goal

A watchOS client that shows the Mac's desktop (view-only: drag to pan, Digital
Crown to zoom), plays the Mac's audio, and plays video from the Mac — a
window, a display region, or a media file — so the watch can do what
WatchTube did, with the Mac doing the fetching and transcoding.

## Status

- Phase 0 (device measurements): **not started** — deferred to the first
  hardware session; the design below works whichever way they come out.
- Phase 1 (desktop glance over HTTP): **implemented, simulator-verified
  2026-10-07** — Ultra 4 sim against the installed Companion: the full
  display at zoom 1, Crown zoom re-cropped sharp by the Mac, drag pans.
  Not yet: iPhone → watch pairing (WatchConnectivity sender in LongwaveiOS,
  and embedding the watch app, which `build-and-sign` must then re-sign), and
  watch viewers in the Companion's viewer list. Seeded from launch arguments
  meanwhile.
- Native stream `stillsOnly` mode (the Phase 2 fast lane, Mac side):
  **implemented, untested** — no client uses it yet.
- Phases 2–4: planned.

## The constraint that shapes everything

watchOS splits networking in two ([TN3135]):

- **High-level** — `URLSession` HTTP(S), and `AVPlayer`. Always allowed, but
  the *system* picks the route: through the paired iPhone (Bluetooth, or the
  companion link over Wi-Fi) when it is around, the watch's own Wi-Fi or
  cellular when it is not. There is no way to require Wi-Fi.
- **Low-level** — Network framework, `URLSessionWebSocketTask`/`StreamTask`,
  Bonjour. **Blocked** (`NWConnection` sits in `.waiting(ENETDOWN)`) except for
  an audio app *while actively streaming audio*, a CallKit call, or a
  DeviceDiscoveryUI listener for tvOS. Under the exception the connection can
  require `.wifi`.
- **The simulator allows everything**, so nothing here is proved until it
  runs on a watch.

Audio output is model dependent: a Series 6 plays long-form audio only to
Bluetooth headphones; an Ultra 3 plays any media app through its speaker
(reported by the user, 2026-10-07). So "audio streaming is active" is
reachable without headphones on current hardware, not on older.

Two lanes follow from that:

| lane | transport | route | when |
|---|---|---|---|
| **any-route** | HTTP via `URLSession` / `AVPlayer` | whatever the system picks — often the phone over Bluetooth | always available |
| **fast** | TLS-PSK over `NWConnection`, `requiredInterfaceType = .wifi` | the watch's own Wi-Fi | only while the app is streaming audio |

Everything must work on the any-route lane; the fast lane is an upgrade, never
a requirement.

## What the watch cannot use, and what replaces it

- **No VideoToolbox, no `AVSampleBufferDisplayLayer`** in the watchOS SDK, so
  the Native stream's HEVC renderer cannot be reused. Desktop → JPEG stills
  (ImageIO decodes them); video → H.264 HLS into `AVPlayer`, which decodes in
  hardware. That is how WatchTube plays video too (an HLS URL handed straight
  to `AVPlayer`), checked in its source 2026-10-07.
- **No `AVAssetResourceLoader`** on watchOS, so `AVPlayer` cannot be given a
  custom trust policy, auth headers or a key-delivery delegate. HLS from the
  Mac is therefore plain HTTP with signed URLs (see Security), or HTTPS only
  when the Mac has a publicly trusted certificate.

## Phase 0 — measure on hardware

One session on a real watch (Ultra 3, and a Series 6 if available), iPhone
nearby and then out of range (iPhone Wi-Fi *and* Bluetooth off in Settings,
not Control Center — TN3135):

1. Still throughput and latency over `URLSession` on each route.
2. Does `NWConnection` to the Mac become `.ready` while PCM is playing, does
   `requiredInterfaceType = .wifi` hold, and what does `NWPath` report?
3. `AVPlayer` HLS start-up time and steady-state latency, 1 s vs 2 s segments,
   and LL-HLS if Phase 3 has it by then.
4. Battery drain per 10 minutes for each.

The answers move defaults (still size, frame interval, segment length), not
the architecture.

## Phase 1 — desktop glance (any-route lane)

**Watch** (`LongwaveWatch/`, new target, embedded in LongwaveiOS):
- Host + token arrive from the iPhone over WatchConnectivity (LongwaveiOS
  sends its Native connections), or from launch arguments
  (`-watchHost`/`-watchToken`) in the simulator. Token in the keychain.
- One screen: the latest still, aspect-fit. Drag pans and the Crown zooms *the
  current picture at once* (local transform, so it feels instant over a slow
  link), then the watch asks for that viewport and the sharper still replaces
  the magnified one.

**Mac** (`CompanionMac/MacWatchServer.swift`, new port 4858):
- A small HTTP/1.1 server on `NWListener`. `GET /v1/still?…viewport…&after=<seq>`
  long-polls: it answers as soon as there is a picture newer than `after` or
  the viewport changed, else after 10 s with 204. One request in flight per
  watch is the pacing — no acks, no push.
- Pictures come from the existing desktop capture: `MacNativeScreenCapture`
  hands its pixel buffers to `MacNativeStillEncoder` (crop *before* scale,
  JPEG), and encoding is skipped entirely while no HEVC viewer is connected.
- The listener starts with the Native stream and only serves while it is on.

**Security**: requests are authenticated and responses sealed at the app
layer, because there is no TLS-PSK in `URLSession` and no CA to pin against:
- Key = HKDF-SHA256(token, salt `Longwave-Watch-v1`).
- Request: `Authorization: LW1 <unix-ms>.<nonce>.<HMAC(method, path, ms, nonce)>`;
  the Mac rejects >30 s skew and replayed nonces.
- Response body: AES-GCM sealed box; the request's nonce is the AAD so a
  response can't be replayed onto another request.

## Phase 2 — audio, and the fast lane

- **Audio**: the existing PCM stream (`AudioStreamProtocol`, TCP only — no
  DTLS lane, PCM24 is ~2.3 Mbps). AVAudioEngine under a
  `.playback`/`.longFormAudio` session activated with `activate(options:)`.
  Now Playing from the existing metadata frames; play/pause/next back to the
  Mac as `command` frames.
- **Fast lane**: while audio plays, the desktop moves from HTTP onto a Native
  stream connection in `stillsOnly` mode (already implemented on the Mac:
  `stillViewport`/`stillFrame`, paced by `frameAck`), with
  `requiredInterfaceType = .wifi`. Audio stopping drops it back to HTTP. If
  Phase 0 shows the fast lane is no faster on Wi-Fi, delete it.

## Phase 3 — video

The watch picks *what* to watch; the Mac turns it into HLS:
- **Sources**: a window (the existing window inventory), a display region, or a
  local media file. Window and region use a dedicated ScreenCaptureKit stream
  with `capturesAudio` scoped to the window's app, so picture and sound come
  from one clock.
- **Encode**: VideoToolbox H.264 Main at watch resolution (e.g. 396×224 for
  16:9, 24–30 fps, 400–800 kbps), AAC-LC 128 kbps.
- **Package**: `AVAssetWriter` with `outputFileTypeProfile = .mpeg4AppleHLS`
  and `preferredOutputSegmentInterval` (1–2 s); its delegate hands over fMP4
  segments and the server writes a rolling playlist. LL-HLS (partial segments)
  later, if Phase 0 says start-up or latency hurts.
- **Serve**: same HTTP server, signed URLs (`/v1/hls/<session>/<file>?exp=…&sig=…`),
  short-lived and bound to one session.
- **Watch**: `VideoPlayer` over `AVPlayer`, Now Playing and background audio
  for free. Seeking only within the live window.
- **Media files** (later): the same packager fed by `AVAssetReader` instead of
  capture, so a file plays at its own pace with real seeking.

**Security caveat**: HLS segments travel as plaintext HTTP on the LAN (signed,
so nobody else can *request* them, but anyone sniffing the network can read
them). Wi-Fi encryption and the Bluetooth link's own encryption are the only
protection. Use HTTPS automatically when the Mac has a publicly trusted
certificate (a `tailscale cert` for its ts.net name).

## Phase 4 — polish

- Complication / Smart Stack widget: last still of the desktop.
- A "Watch on Apple Watch" action in the Companion menu for the frontmost
  window.
- Remote input, if wanted: a tap becomes a click through the existing
  `mouseDown`/`mouseUp` frames (fast lane) or an HTTP POST (any-route).

## Distribution

- The watch app is embedded in LongwaveiOS, and LongwaveiOS links GPLv3
  moonlight-common-c, so there is no App Store path for it as things stand. An
  App Store build needs either an MIT iOS edition or an independent watch app.
- WatchTube was rejected from the App Store; its reason is not known here.
  Present this feature as "your Mac's screen and media", never as a client for
  any third-party video service.

[TN3135]: https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos
