# Native Stream Protocol v3

Design for the third version of the Native stream: a game-grade, cross-platform
protocol, served by one portable Swift host core, that makes Longwave's own
stream good enough to retire Moonlight/Sunshine for Windows and Linux hosts.

Written 2026-10-04. Nothing here is implemented yet. Facts carry a link or a
file reference; anything that is a judgement says so. The verified/inferred split
is kept explicit in [Risks and open questions](#9-risks-and-open-questions).

## Status

- **Design: proposed.** Phase 0 (measurement) can start from this document.
- The v2 protocol (`Shared/MacNativeStreamProtocol.swift`) stays the shipping
  protocol, and remains served until every client in the field speaks v3.
- Builds on [[NATIVE_MAC_STREAMING_PLAN.md]]. That plan's Phase 4 (discovery,
  pinned identities) and Phase 5 (adaptive bitrate, congestion feedback,
  latency measurement) are absorbed here rather than built on v2.

## 1. Goals, non-goals, success metrics

### Goals

1. **Game-grade on Wi-Fi.** Interactive latency comparable to Moonlight on the
   same client, host and access point, with loss handled by forward error
   correction and reference invalidation instead of retransmission stalls.
2. **One host implementation.** A portable Swift core (session, transport, FEC,
   rate control, clocking, viewer fan-out) shared by the macOS, Windows and Linux
   hosts, with platform work confined to thin capture/encode/audio/input shims.
3. **One protocol for every client.** The existing visionOS/iOS/macOS receiver
   (`MacNativeStreamClient`, `MacNativeVideoRenderer`, `MacNativeStreamManager`)
   keeps one code path for every host.
4. **Audio and video on one clock.** Audio, video and input stamped against the
   host's monotonic clock, with a bounded, measured A/V skew.
5. **Keep what works:** versioned framing and capability negotiation, Unity
   per-window streams, multi-viewer fan-out, the X25519 commit-reveal pairing and
   knock gate, PSK-rooted authentication, and the audio receiver's sample-index
   stamping and drift correction.

The north star is Windows and Linux hosts, where Moonlight is the incumbent. On
the Mac, v3 replaces v2 because a single protocol is cheaper than two, not
because the Mac needs to beat Moonlight. No Mac host for Moonlight exists anyway.

### Non-goals

- Interoperating with GameStream, Sunshine or Moonlight clients. v3 is a
  clean-room design; Sunshine and moonlight-common-c are GPLv3, and the
  visionOS source is MIT. Their *design* is studied below; no code, constants
  table or header layout is copied.
- WAN/Internet streaming through NAT (no STUN/TURN/relay). LAN, routed LAN and
  Tailscale are in scope; Tailscale's 1280-byte MTU sets the default packet size.
- Browser clients or WebRTC compatibility.
- PCVR. That has its own path (CloudXR today, a visionOS 27 foveated-streaming
  provider later); see `Longwave-PCVR-Host/docs/`. v3's transport may be reused
  there later, but nothing here depends on it.
- Replacing the Companion's audio-only Music mode on day one. The VVAS audio
  stream (`Shared/AudioStreamProtocol.swift`, port 4855) keeps serving
  audio-only connections until v3's audio channel has matched it.

### Success metrics

Each metric names its measurement method. All are compared against a
**Moonlight baseline on the same client, host and AP**, taken in Phase 0.

| Metric | Target | How it is measured |
|---|---|---|
| Glass-to-glass latency, 1080p/1440p game at 120 fps, NVENC host, Wi-Fi client, p50 | ≤ Moonlight's p50 + 2 ms; absolute aim ≤ 25 ms | 240 fps camera on a flashing test pattern, host monitor and client screen in one shot (Mac/iPad clients). Plus in-band capture→present stamps (§5) on every client, including Vision Pro, where a camera can't see the display |
| Same at p99 | ≤ Moonlight's p99 | In-band stamps over a 10-minute session |
| Mac desktop, 4K-class virtual display, 60 fps, p50 | ≤ v2 today minus the TCP queueing (target ≤ 35 ms; the M1 encode alone is ~12–15 ms, [[vt-hevc-encode-latency-benchmarks]]) | In-band stamps; `Desktop latency` log line today |
| Random loss | No visible artefact at 2% uniform loss; playable (no freeze > 100 ms) at 10% | Impairment simulator (§7) and `tc netem`/Network Link Conditioner on the real link |
| Burst loss | A burst of ≤ 20% of one frame's packets is repaired by FEC with no artefact | Simulator Gilbert–Elliott model |
| Recovery after unrepairable loss | Clean picture within 1 RTT + 2 frames via reference invalidation; ≤ 100 ms via IDR fallback | Simulator plus the in-band frame log |
| Wi-Fi delivery stall (60–180 ms, measured on the headset, `KNOWN_CONSTRAINTS.md` audio section) | Video resumes at *live* within one frame of the stall ending, never by playing the backlog | Replay of the measured stall pattern in the simulator; ping trace alongside a real session |
| A/V skew, game mode | Audio never leads video; audio lags video by ≤ 50 ms p95 | Host-clock stamps on both; receiver logs presentation time of each |
| Input → host injection, p50 | ≤ one-way network delay + 2 ms | Client stamps every input with its host-clock estimate; host logs injection time |
| Bitrate convergence | Reaches 90% of available capacity within 5 s; backs off within 2 feedback intervals of queue growth | Simulator with a bottleneck rate step; real link with a competing download |

The 2 ms margins are judgement: a portable core adds a little (an extra copy,
a less specialised socket path) and the goal is parity, not a regression hidden
by noise.

## 2. Assessment of v2

Evidence-based, with what the established assessment got right and what it
missed.

**One TLS-over-TCP connection carries everything.** Video, input, control,
inventory and acks share one `NWConnection` with TLS 1.2 PSK
(`MacNativeStreamCrypto.tlsTCPParameters`, `MacNativeStreamServer`). A lost
Wi-Fi frame stalls every byte behind it until TCP retransmits, so a pointer move
waits behind a 500 KB video frame, and input inherits video's loss. The v2 design
assumes losslessness: the Mac encoder sets `MaxKeyFrameIntervalDuration` to
3600 s and relies on refinement frames of an unchanged picture
(`MacHEVCEncoder.swift`, comments at `dataRateLimits` and the key-frame
interval) — correct on TCP, and something v3 has to replace with explicit
recovery, because on UDP any lost refinement frame corrupts the reference chain.

**Loss recovery is drop-then-IDR.** When a viewer falls behind
(`maxInFlightFrames = 3`, `maxPendingBytes`), `deliver` drops the frame, marks
the stream `awaitingKeyFrame` and asks the encoder for a key frame
(`MacNativeStreamServer.deliver`). A full-screen IDR on a Retina desktop is the
largest frame there is, sent at the moment the link is weakest.

**There *is* congestion feedback — but only on the Mac desktop stream.** The
established assessment said adaptive bitrate was unstarted. It isn't, quite:
acking viewers send `frameAck` (0x58) on arrival
(`MacNativeStreamClient`, the `windowVideoFrame` case); the host holds the newest
captured frame while two are unacked (`maxUnackedFrames`, the desktop gate),
measures send-to-ack time, and `MacNativeScreenCapture` cuts the bitrate by 30%
on drops and 15% when send-to-ack exceeds the link's own baseline by 15 ms,
recovering 20% per check after 5 s clean (`linkCongested`, `linkLatency`,
`recoverBitrate`). That is a frame-granular, delay-based controller and a good
seed. Its limits: it only covers the desktop stream; it measures whole-frame
round trips through TCP (so retransmission and receive-window effects pollute
it); it never raises the rate above the area-based target; and per-window streams
and the Windows host have nothing (`NativeStreamingService.cs` sets a fixed
bitrate, 1 s key-frame spacing, no `frameAck`, no `requestKeyFrame`).

**No FEC, no pacing.** Frames go to the socket whole; TCP and the Wi-Fi driver
decide the burst shape.

**Audio is a separate protocol on a separate clock.** VVAS (`AudioStreamProtocol`
v8) runs on its own port with its own TLS/DTLS, stamps PCM with the Mac's IO
device sample index (`PCMStamp`), and the receiver plays it against a cushion of
40–400 ms that is sized from measured stalls and never decays within a session
(`AudioStreamManager.swift`, the cushion and drift section; `KNOWN_CONSTRAINTS.md`
audio bullets). Video is presented immediately (`kCMSampleAttachmentKey_DisplayImmediately`
in `MacNativeVideoRenderer`). Nothing relates the two clocks, so audio trails
video by whatever the cushion is. The Windows host serves no audio at all
(`supportsAudioStream` is false).

**Two host implementations, no Linux.** Swift on the Mac (`CompanionMac/`), C#
on Windows (`CompanionWindows/backend/NativeStream/`, BouncyCastle TLS-PSK,
Windows.Graphics.Capture, the hardware HEVC MFT through Media Foundation,
SendInput). Every protocol feature has to be built twice, and the Windows host
has already fallen behind (no acks, no key-frame requests, no display list, no
audio).

**No forward secrecy.** `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8) is a pure-PSK
suite: a leaked companion token decrypts every recorded session. One token per
Companion also means one headset can't be revoked without re-pairing all of them.

**Strengths worth keeping, verified in code:**

- Versioned framing with a v1 fallback path that has actually been exercised
  (`Hello.protocolVersion`, `decodeHelloAck` returning nil for v1).
- Capability flags rather than platform checks (`HelloAck.keyCodeSpace`,
  `supportsWindowStreams`, `supportsAudioStream`, `decodesHEVC422`).
- Multi-viewer fan-out with one capture/encode per stream and reference-counted
  subscriptions; LCD chroma negotiation.
- Unity per-window streams with alpha.
- Discovery and pairing that open no port until a paired headset knocks
  (`Shared/CompanionPairing.swift`, `CompanionMac/CompanionPresence.swift`).
- The audio receiver's machinery: media-clock lateness percentiles, held lead,
  ±1-frame drift correction, holes/out-of-order accounting.
- Format-exact transport of CoreMedia descriptions (alpha metadata survives).

## 3. Transport and security

### Decision: one UDP port, own secure datagram layer, own reliability

v3 runs over **plain UDP on one port (4857/udp)**, with a small Longwave
transport on top: a Noise-based handshake keyed by the pairing secret, per-packet
AEAD, a connection ID for roaming, a reliable ordered sub-channel for control and
input events, and unreliable channels for media. Congestion control is ours,
media-aware, and the *only* controller on the flow.

This is the shape the incumbents chose: Sunshine/Moonlight send video and audio
as raw UDP with Reed–Solomon FEC and run control over ENet, a reliable-UDP
library [M1][M2]; Parsec's BUD is UDP with its own reliability, DTLS 1.2 and a
custom delay-sensing congestion controller coupled to the encoder [P1]; Steam
Remote Play runs over Valve's own UDP networking-sockets layer with
fragmentation and channel management [P2]. It is not the shape the established
assessment proposed; the reasoning follows.

### Alternatives considered

**QUIC (Network.framework on Apple, MsQuic on Windows/Linux).** Attractive: one
port, streams without head-of-line blocking, datagrams (RFC 9221), migration,
battle-tested loss recovery, TLS 1.3. Rejected as the media transport, for four
reasons:

1. **Its congestion controller would fight ours.** RFC 9221 datagrams "employ
   the QUIC connection's congestion controller" but are never retransmitted
   [R1]. A media sender must own its send rate (encoder bitrate, FEC ratio,
   pacing); a loss-based Cubic/NewReno controller underneath treats random Wi-Fi
   loss as congestion and shrinks the window, and a datagram that doesn't fit is
   queued (latency) or dropped by the stack (loss we didn't choose). No stack on
   our platforms lets us switch it off: Network.framework exposes no
   congestion-control setting at all (`quic_options.h` in the macOS 27 SDK; the
   iOS 26 `QUIC` builder likewise [R2]); MsQuic offers Cubic, or BBR behind a
   preview flag, with no disable and no custom-controller hook [R3]. The
   RTP-over-QUIC draft names the same conflict, warns against stacking two
   controllers, and can only recommend a media-friendly controller *inside* the
   QUIC stack [R4] — which only a stack we control can provide.
2. **Three QUIC stacks, three behaviours.** Network.framework's QUIC on clients
   and the Mac, MsQuic over Schannel on Windows (Windows 11 / Server 2022 only;
   an OpenSSL build for Windows 10) and over quictls on Linux [R3]. Each has its
   own pacing, ACK policy, datagram queueing and loss detection, none tuned for
   a 16 ms frame deadline and none runnable in the deterministic simulator of §7.
   Network.framework also allows **one datagram flow per connection**
   (`nw_quic_set_stream_is_datagram`), and Apple DTS has said it doesn't expect
   datagrams to improve throughput, with a known `ECANCELED` bug when sending
   datagrams through `NWConnectionGroup` from several threads [R5].
3. **Identity.** QUIC requires TLS 1.3, and Apple supports TLS-PSK only for
   TLS 1.2 — DTS: "to work with QUIC you need to use standard TLS, that is, your
   server must have a digital identity" [R6]; MsQuic has no external-PSK support
   either (open issue) [R3]. So QUIC means a self-signed host certificate pinned
   at pairing (pinning works: `verify_block` / `certificateValidator`, MsQuic's
   `PEER_CERTIFICATE_RECEIVED` [R3][R6]) plus a separate client proof. Doable —
   it is v2's planned Phase 4 — but more machinery than the identity model needs.
4. **Swift interop on Windows/Linux.** MsQuic is C and callable from Swift, but
   the only Swift binding is Apple-only [R3], and Apple's own pure-Swift
   `swift-nio-quic` (open-sourced June 2026) is 0.1.0, API-unstable and lists no
   Windows support [R7].

QUIC stays a fallback: if the custom transport's reliability layer turns out to
be a bug farm, the control/input half (not media) could move to QUIC streams
while media stays on raw UDP. That split costs a second handshake and is not the
plan.

**UDP + DTLS 1.2 PSK** (what VVAS audio uses today). Keeps the existing identity
model and is supported by Network.framework, but not by schannel (no PSK
suites — the reason the Windows host uses BouncyCastle,
`NATIVE_MAC_STREAMING_PLAN.md` Windows section). It also gives no forward
secrecy, no connection ID (an AP or interface change kills the session), and a
DTLS record per datagram is the same per-packet AEAD we'd write ourselves, with a
handshake we can't run in a simulator.

**RTP/RTCP + SRTP (WebRTC-style).** Good congestion-control literature (GCC,
transport-wide CC) that we borrow from regardless. The packet formats don't buy
interoperability we want (non-goal), and SRTP keying needs DTLS-SRTP or SDES.

**Why the custom layer is affordable.** The parts that are hard in QUIC —
connection establishment over the Internet, flow control across thousands of
streams, 0-RTT, version negotiation with middleboxes — are not needed on a LAN
with one peer. What remains is a ~1-RTT handshake from a vetted pattern, AEAD
records with a replay window (WireGuard's design), a selective-ACK reliable
channel carrying a few KB/s, and the media path that every option would make us
write anyway.

### Handshake and keys

- **Pattern: `Noise_NNpsk0_25519_ChaChaPoly_SHA256`** (Noise Protocol Framework,
  revision 34), implemented on swift-crypto (`import Crypto`), which is CryptoKit
  on Apple platforms and BoringSSL-backed elsewhere (X25519, HKDF, AES-GCM,
  ChaCha20-Poly1305 all present [S1]; its README names Linux and **ARM64**
  Windows, so x64 Windows is a Phase 2 spike item — fallback is the same four
  primitives from Windows CNG behind the C shim). Ephemeral X25519 on both
  sides gives forward secrecy; the PSK authenticates both sides and is mixed in
  before the first message, so a peer without it can't get a response.
  Implemented exactly to the spec and checked against the published Noise test
  vectors — this is the one place no invention is allowed.
- **Per-device PSK.** Today one Companion token serves every paired headset.
  v3 derives a per-device key at both ends:
  `psk = HKDF-SHA256(token, salt: "Longwave-NS3-PSK", info: headsetID)`.
  Already-paired devices migrate with no re-pairing, and a later pairing revision
  can switch to independently random per-device secrets so a single device is
  revocable (the Phase 4 goal) — the handshake doesn't change.
- **Key ID.** The first handshake packet carries an 8-byte key identifier,
  `HMAC(psk, "kid")[0..8]`, so a host with several paired devices picks the PSK
  without trial decryption. It is as linkable as the `hs` key the knock already
  advertises in TXT, so it leaks nothing new.
- **Payload of the handshake messages** (encrypted by Noise): the hello and
  hello-ack — protocol version, capability set, device name, platform,
  keycode space — the content of v2's JSON `Hello`/`HelloAck`, now binary
  (§4.6).
- **Session keys.** Noise's split yields one key per direction; records use
  AES-256-GCM where the hardware accelerates it (Apple silicon, x86 AES-NI —
  the host picks and states it in the ack) and ChaCha20-Poly1305 otherwise,
  with the 64-bit packet number as nonce. Rekey every 2^32 packets or 1 hour.
- **Later: static keys.** When pairing is revised to exchange long-term X25519
  keys (they would ride inside the already-sealed `PairingGrant`), the pattern
  becomes `Noise_IKpsk2` — WireGuard's — which adds identity hiding and makes a
  stolen token insufficient alone. Not needed for v3.0.

### Records, replay, roaming

- **Outer header (cleartext, authenticated as associated data):**
  1 byte type/flags, 4-byte receiver connection ID, 8-byte packet number.
  Packet numbers are never reused; a sliding 2048-packet replay window (as in
  WireGuard and DTLS) rejects duplicates.
- **Roaming.** The host updates the peer's address on any authenticated packet
  from a new one (WireGuard's rule). Switching APs, Wi-Fi → Ethernet on a Mac
  client, or a Tailscale path change keeps the session. The client probes with a
  `PING` after a path change (`NWPathMonitor`), so the host learns the new
  address within one RTT rather than at the next media packet.
- **DoS and stealth.** The host answers nothing that fails the PSK check, so the
  port is silent to an unpaired scanner and can't be used for amplification. The
  knock gate stays in front of it: the UDP socket is only bound while a paired
  headset knocks or "Allow connections by address" is on, exactly as the TCP
  listener is today (`CompanionPresence.setOpen`).
- **Packet size.** Default UDP payload 1200 bytes (fits Tailscale's 1280 MTU
  and IPv6 minimum with headers). On a direct LAN path the session probes up to
  1452 with padded `PING`s (DPLPMTUD, RFC 8899) and uses the largest that gets
  through, re-probing after a path change. For comparison, moonlight-qt uses
  1392-byte video packets on-link and 1024 for remote/VPN paths [M3].
- **Encryption is always on.** Sunshine leaves media unencrypted on LAN by
  default and moonlight-qt opts in only with CPU AES acceleration [M1][M3];
  every host and client here has AES hardware, and the Companion's token-gated
  model has always meant encrypted, so v3 doesn't offer a plaintext mode.
- **QoS marking.** Media and input marked for WMM video/voice: on Apple via
  `NWParameters.serviceClass` (`.interactiveVideo` already used by v2),
  Linux via `IP_TOS`/`SO_PRIORITY`, Windows via qWAVE (`QOSAddSocketToFlow`),
  since Windows ignores `IP_TOS` set directly by applications.

### Discovery and pairing

Unchanged in substance. `_longwave-mac._tcp` gains TXT key `ns=3` when the host
serves v3 (plus `ns=2` while it also serves v2); the client picks v3 when both
sides can. The knock tag, pairing exchange and `PairingGrant` are reused as is
and move into the core package (§7) so the Windows and Linux hosts get pairing
too — the Windows host has none today.

## 4. Wire format

### 4.1 Layers

```
UDP datagram
└─ outer header: type | conn-id | packet-number          (AAD)
   └─ AEAD-sealed body: one or more frames, each [type u8 | length varint | body]
      ├─ CTRL      reliable ordered bytes, channel 0 (control) / 1 (input events) / 2 (bulk: clipboard, artwork)
      ├─ ACK       selective ack ranges for the reliable channels
      ├─ MEDIA     one video or audio shard (§4.2, §4.4)
      ├─ STATE     unreliable latest-wins snapshot (pointer position, gamepad)
      ├─ FEEDBACK  receive report for rate control (§6)
      ├─ PING/PONG clock sync and liveness (§5)
      └─ PADDING
```

Small frames coalesce into one datagram (an ACK and a FEEDBACK ride on any
outgoing packet). Media shards never share a datagram with each other, so FEC
shard boundaries equal packet boundaries.

The reliable channel is deliberately simple: byte-stream per channel, selective
ACKs, retransmit after `smoothed RTT + 4×rttvar` (min 5 ms on LAN), no
congestion window of its own — its traffic is accounted against the media rate
controller's budget. Three channels so a clipboard image can't sit in front of a
key-up. This is ENet's design point in our own framing.

### 4.2 Video

**Stream identity.** `streamID: u32` exactly as v2 — 0 is the desktop, nonzero
is a window ID (CGWindowID / HWND low 32 bits / Wayland toplevel handle). Unity
per-window streams are simply more stream IDs; nothing in the transport is
desktop-specific.

**Format.** A `formatDescription` control message per stream (reliable, channel
0) carries v2's `FormatKind` blob (CoreMedia image description from Apple
hosts, Annex-B parameter sets from others) plus a new `codec` field (HEVC, H.264,
AV1) and colour info (BT.709 SDR, BT.2020 PQ/HLG with mastering metadata).
Bumping the format is a reliable message *and* stamped with the first
`frameNumber` it applies to, so a reordered shard can't be decoded against the
wrong parameter sets.

**Shard header** (inside the sealed MEDIA frame, 24 bytes):

| field | size | notes |
|---|---|---|
| streamID | 4 | |
| frameNumber | 4 | per stream, wraps |
| captureTime | 8 | host monotonic ns (§5), same for all shards of a frame |
| flags | 1 | key, recovery (first frame after invalidation), LTR-marked, last-block, discardable (not a reference) |
| block | 1 | FEC block index within the frame |
| blockCount | 1 | |
| shardIndex | 1 | index in the block, data shards first |
| dataShards | 1 | k |
| parityShards | 1 | m |
| refFrame | 2 | low 16 bits of the frame this one predicts from, 0xFFFF for intra |

`refFrame` is what lets the receiver tell, *before* decoding, whether a frame is
decodable given what it has — the receiver knows exactly which frames are
damaged and asks for invalidation of exactly those (§6.3).

**Packetization.** An encoded frame (length-prefixed NAL units, as v2) is split
into equal-size data shards of `payload − 24` bytes, the last zero-padded with
the true length in its header extension. Frames bigger than one block are split
into several blocks of ≤ 255 total shards each.

**FEC.** Systematic Reed–Solomon (Cauchy matrix) over GF(2^8), per block: `k`
data shards plus `m = max(minParity, ceil(k × fecRatio))` parity shards, where
`fecRatio` is chosen by the rate controller from measured loss (§6.2), starting
at 10%, clamped to [5%, 50%], and `minParity` is 2 for small frames (a 3-shard
P-frame with 10% would otherwise get no protection). Data shards are sent first,
so a clean link decodes as soon as the data arrives; parity is only used when
something is missing.

Why RS and not something newer: it is optimal (any k of k+m shards decode),
royalty-free in the Cauchy form (longhair/cm256's author states as much [F2]),
and fast enough: O(k·m) per block, with table-driven SIMD (SSSE3 `pshufb`, NEON
`tbl`) well under a millisecond per frame at 100 Mbps and 10–20% parity
(judgement, to be benchmarked). Library choice in §7. RaptorQ is avoided:
Qualcomm's IPR declarations offer FRAND terms tied to wireless-WAN devices, not
a royalty-free licence [F4].

Sunshine's numbers, for calibration: 20% FEC by default, ≤ 255 shards per
block, at least 2 parity shards per frame (the client asks for it), at most 4
blocks per frame — a frame needing more gets *no* FEC [M1][M2]. v3 differs on
the last point on purpose: a Retina desktop's refinement frames routinely exceed
4 full blocks, and leaving the biggest frames unprotected is backwards. The
block-count field is 8 bits.

**Large frames.** Mac desktop refinement frames measured 470–850 KB
(`MacHEVCEncoder.dataRateLimits` comment) — up to ~700 shards, three blocks.
That's fine for RS-per-block, but it is also a burst the pacer must spread
(§6.4), and a reason the desktop's FEC ratio can sit lower than a game's: a
damaged refinement frame can simply be skipped if it is marked discardable.

**Retransmission (NACK) as well as FEC.** On a LAN the RTT (2–5 ms) is a
fraction of a 16 ms frame budget, so a receiver missing more shards than parity
covers sends a NACK for the specific shards immediately, and the host resends
them if the frame is still within its deadline (capture time + target latency −
RTT). FEC handles the common case without a round trip; NACK rescues the tail
without the bandwidth cost of provisioning FEC for the worst burst. Moonlight
uses FEC only; this is a deliberate difference, to be validated in Phase 1
against the simulator.

**Reordering is not loss.** Wi-Fi reorders. The receiver waits a reorder window
(max(2 ms, ¼ frame interval), adapted to the observed out-of-order depth) before
treating a shard as missing. moonlight-common-c learned the same lesson: once it
sees out-of-order packets it stops speculative recovery requests for five
minutes [M2].

### 4.3 Input

- **Events** (reliable, channel 1): key down/up (keycode in the host's
  announced `keyCodeSpace` — `macVirtual` or `hidUsage`, as v2 — plus
  modifiers), mouse button down/up, scroll (now with a high-resolution delta in
  1/120ths of a notch, alongside the line delta), text input (UTF-8),
  focus-window, gamepad connect/disconnect, and **release-all** (sent on focus
  loss and reconnect; v2 does this host-side on disconnect only).
- **State** (unreliable, STATE frames, latest wins by per-source sequence
  number): absolute pointer position per stream (v2's `windowMouseMove`), relative
  pointer motion accumulated since the last ack (for pointer-lock games; summed,
  so loss can't drop motion), and gamepad snapshots (buttons bitmask, two sticks,
  two analog triggers, optional gyro/accelerometer and touchpad). State is
  re-sent every 8 ms while changing and every 100 ms while idle, so a lost
  snapshot costs at most one interval.
- **Every input carries the client's estimate of host time** when it was
  generated (§5), so the host can log input latency and order input against the
  frame the user was looking at.
- **Host → client:** rumble (two motors, plus trigger rumble), LED/light-bar,
  adaptive-trigger hints, cursor shape/visibility (so the client can draw the
  cursor locally when the stream doesn't), and the v2 `mouseStatus`/
  `keyboardStatus` capability states.

### 4.4 Audio

**Channel.** One `audio` media channel per session, on the same session as the
video (no second port), stamped against the same host clock.

**Codec.** Opus for everything by default: low latency (5 ms or 10 ms frames),
built-in packet-loss concealment and in-band FEC, BSD-licensed (libopus is
already vendored in `repos/` for Moonlight, and the BSD licence is compatible
with the MIT edition). Multichannel uses Opus multistream with mapping family 1
up to 7.1 and family 255 (application-defined) for **7.1.4 = 12 channels** as
6 coupled + 0 mono streams (bed order announced in the format message). An
optional **PCM24** codec (`PCM24` from VVAS, unchanged) remains for stereo Music
mode on a LAN where the user wants lossless.

**Shard header** (16 bytes): `channelID u16`, `flags u8`, `codec u8`,
`firstSample u64` (the VVAS `PCMStamp` idea, generalised — the host's audio
device sample index, continuous through silence suppression, holes and drops),
`frameSamples u16`, `fecGroup u16`. The format message maps sample index to host
monotonic time (§5), so audio and video share a clock without stamping every
packet twice.

**FEC.** Audio packets are tiny and late audio is useless, so: RS across groups
of 4 data packets with 2 parity (same RS code as video; the same grouping
Moonlight uses with 5 ms Opus packets [M2]), plus Opus in-band FEC
(LBRR) when the measured loss is above 1%. A lost 5 ms packet is concealed by
Opus PLC rather than spliced, and counted as a hole — the receiver's existing
accounting (`holes`, `ooo`, `late` percentiles) applies unchanged.

**Spatial objects (optional, capability-gated).** A `spatialObjects` capability
adds an object channel: each active object is a mono Opus stream (`objectID`),
plus OBJMETA frames at the audio frame rate: `objectID`, `firstSample`,
position (x, y, z in metres, listener-relative, right-handed, −Z forward),
gain, spread, and an end flag. The client renders objects with RAVESpatialAudio
/ `RAVEPhaseStage` alongside the bed. Whether a Windows host can obtain objects
at all is **unverified**. `ISpatialAudioClient` takes a bed of up to 8.1.4.4
plus dynamic objects (Atmos over HDMI: 7.1.4 + 20 objects on recent builds)
[W5], but the objects go to the endpoint's spatial renderer, and WASAPI
loopback captures the mixed engine output [W4]; nothing documented exposes
object metadata to a capturing process, so the likely route is a virtual audio
endpoint that *is* the spatial renderer (a driver). The protocol slot costs nothing until a host
announces the capability; the Moonlight-side `MoonlightSoundStage` work already
proves the client can place channel beds as virtual speakers.

### 4.5 Control, clipboard, inventory

Reliable channel 0, binary-framed messages with a type byte. The v2 JSON bodies
(`WindowInventory`, `DisplayList`, `VirtualDisplayChange`) stay JSON inside the
message: they are small, rare and already have Codable models on both ends —
swift-foundation's `JSONEncoder` exists on Linux and Windows. Hot-path messages
(input, feedback, shard headers) are fixed binary.

New in v3: `clipboard` (text, UTF-8, and PNG images up to 8 MB on bulk channel
2, chunked like VVAS artwork), `streamConfig` (client asks for resolution/FPS
caps, HDR on/off, codec preference per stream), `stats` (§6, for the
diagnostics overlay), and `bye` with a reason.

### 4.6 Versioning, capability negotiation, v2 compatibility

- The handshake's first byte is the protocol major (3). Within v3, features are
  **capabilities**: the client lists what it supports, the host answers with the
  intersection. Initial set: `windowStreams`, `alphaVideo`, `hevc422`,
  `hevc10bitHDR`, `av1`, `h264`, `ltrRecovery`, `rfiRecovery`, `nack`,
  `audioOpus`, `audioPCM24`, `audioMultichannel`, `spatialObjects`, `gamepad`,
  `relativePointer`, `clipboard`, `virtualDisplay`, `localCursor`.
  Unknown capabilities are ignored, never fatal.
- Message and frame types are append-only; a receiver skips unknown frame types
  by their length.
- **v2 coexistence.** Hosts serve TCP 4857 (v2) and UDP 4857 (v3) at once,
  sharing one capture/encode per stream: the fan-out layer (§7) gives a v2 viewer
  the same encoded frames over its TCP socket — the frames a v3 viewer gets in
  shards. A v2 viewer on a stream forces IDR-based recovery on that stream
  (it can't use LTR acks); that is acceptable during migration.
- **Client choice.** A v3 client connects v3 if the TXT says `ns=3` or if a v3
  handshake answers within 500 ms; otherwise v2. Manual-address connections try
  v3 first, then v2.
- **Retirement.** v2 is removed from hosts one release after every client
  shipping on the App Store and GitHub speaks v3 — the Windows companion and the
  App Store edition release independently of each other, so the window is
  calendar-based (≥ 3 months), not "next release".

## 5. Clock model and A/V sync

**One host clock.** Every timestamp on the wire is host monotonic nanoseconds:
`mach_continuous_time` converted on macOS, `QueryPerformanceCounter` on Windows,
`CLOCK_MONOTONIC` on Linux, behind one `HostClock` seam in the core. Capture
APIs report their own times; shims convert at the source:
ScreenCaptureKit's `SCStreamFrameInfo.displayTime` (mach time), WGC's
`Direct3D11CaptureFrame.SystemRelativeTime` (QPC), PipeWire's buffer
`spa_meta_header.pts` (CLOCK_MONOTONIC on current versions; verify per
compositor), WASAPI's `IAudioCaptureClient::GetBuffer` QPC position, Core
Audio's `AudioTimeStamp.mHostTime`.

**Audio's clock is a sample index, mapped.** As in VVAS v8, audio shards carry
the device sample index. The host sends `audioAnchor(sampleIndex, hostTime)`
every second on the control channel — a linear map that also captures the
audio device's drift against the host clock.

**Receiver clock estimation.** PING/PONG every 250 ms (and on demand after a
path change), NTP-style four timestamps. The receiver keeps the minimum-RTT
samples from a sliding 10 s window and fits `hostTime ≈ a + b·localTime` by
least squares on those — offset from `a`, drift (ppm) from `b`. The min-RTT
filter matters on Wi-Fi: the headset's delivery stalls (§9) inflate RTT for
whole stretches, and only the fastest exchanges are near-symmetric.

**Video playout: latency-first, with a floor.**

- **Game mode (default for games):** decode on arrival, present at the next
  vsync — today's `DisplayImmediately`. A frame that arrives later than a newer
  decodable one is decoded (to keep references) but not displayed. After a Wi-Fi
  stall, the burst is decoded as fast as the decoder allows and only the newest
  is shown: video jumps to live rather than replaying the backlog — the explicit
  answer to the stalls `KNOWN_CONSTRAINTS.md` documents for audio.
- **Smooth mode (desktop video, films):** the receiver holds a small playout
  target (p95 of measured lateness over the last 10 s, held like the audio
  cushion), presents each frame at `captureTime + offset + target`, and lets
  `AVSampleBufferDisplayLayer`'s timebase do the scheduling. This trades a few
  ms for even cadence.

**Audio playout follows video, not the other way round.** Audio's target lead is
`max(audioJitterNeed, videoGlassLatency − audioPathLatency)`, so in game mode
the audio comes out no earlier than its picture. The bound: audio never leads,
and lags by at most 50 ms p95 (ITU-R BT.1359 puts the detectability threshold
for audio-late at roughly 125 ms and audio-early at roughly 45 ms; aiming well
inside the asymmetric window costs nothing). Where the audio cushion has grown
past that (a bad stretch of Wi-Fi), the skew is reported rather than "fixed" by
delaying video, because in a game a late picture is worse than a late sound.

**Generalising the existing controller.** The VVAS receiver's logic
(`AudioStreamManager.swift`, cushion/drift section) moves into the core as a
`PlayoutController` over abstract media units, with three parts:

1. **Lateness measurement against the media clock** — each unit's arrival minus
   its stamped host time (converted through the clock estimate), tracked as
   p50/p95/p99/max per window. This replaces both audio's per-stream jitter
   reasoning and v2's send-to-ack latency.
2. **A held target** — rises to the measured need × 1.3 immediately, never decays
   within a session, remembered per host (`AudioLeadMemory` generalised). The
   measured headset stalls are why this rule exists; it carries over unchanged.
3. **Drift correction** — moves from per-stream ±1-sample nudging to the shared
   clock estimate. Audio still applies the correction by resampling ±1 sample
   per N buffers (inaudible, as today); video has nothing to resample and simply
   follows the corrected clock.

Audio rendering (AVAudioEngine/PHASE, the session coordinator, Music/Speaker
modes) stays client-side Apple code. Only the controller logic moves.

## 6. Rate control and congestion

### 6.1 Feedback

The receiver sends a FEEDBACK frame every 20 ms (and immediately on detecting a
loss) with, per received packet since the last report, `(packet number,
arrival time in receiver µs, ECN bits)` compressed as run-length deltas — the
transport-wide congestion-control design from WebRTC [C2], with RFC 8888's ECN
field [C3], applied to every packet of the session (video, audio, control)
since they share one bottleneck. libwebrtc defaults to 100 ms (bounded 50–250,
sized to 5% of bandwidth) because it runs on thin WAN uplinks [C2]; on a LAN at
tens of Mbps, 50 reports/s is ~0.1% overhead and buys a faster reaction. It also
carries per-stream frame status: last fully decodable frame, frames lost
beyond FEC, and the current playout lateness percentiles.

v2's `frameAck` is subsumed: "frame N arrived" is derivable from shard arrivals,
and the desktop gate becomes the general pacer below.

### 6.2 Estimator

On the host, per viewer, a controller modelled on Google Congestion Control:

- **Delay-based:** trendline filter over the one-way delay gradient of packet
  groups (arrival-time deltas minus send-time deltas, grouped per 5 ms burst),
  with an adaptive threshold (GCC starts at 12.5 ms); overuse cuts to 0.85× the
  measured receive rate, normal increases multiplicatively (8%/s) far from the
  last overuse rate and additively near it [C1]. Current libwebrtc uses a
  trendline estimator in place of the draft's Kalman filter [C1].
- **Loss-based:** loss alone doesn't cut the rate below 10% loss — on Wi-Fi it
  is mostly not congestion. Instead loss raises the **FEC ratio**
  (`fecRatio ≈ 2 × smoothed loss + 5%`, clamped), and the total
  (media + FEC + audio) stays under the delay-based estimate. Above 10%, the
  media rate is cut as well.
- **Probing:** when the encoder is under target because the scene is static
  (a still desktop), the estimator doesn't grow from nothing; it probes with
  padding/FEC bursts at 2× the current estimate for 20 ms every few seconds,
  as GCC does, so the first motion after a still moment has an accurate
  rate.
- **Seeded by v2's lesson:** the baseline is relearned (it follows the minimum
  recent delay, creeping up slowly), so Tailscale's 6–15 ms idle isn't mistaken
  for queueing — the bug the current `linkLatency` comment records.

SCReAMv2 (draft-ietf-ccwg-rfc8298bis, 2026, obsoleting RFC 8298) is the
alternative to evaluate in the simulator: more rate-based than the original,
L4S-aware, with a 60 ms–400 ms delay target and AR/VR goggles among its stated
use cases [C4]. Its delay target is looser than ours, so it is a candidate for
the L4S path rather than the default. ECN is reachable without QUIC:
Network.framework marks and reads it per packet on UDP (`nw_ip_ecn_flag_t`,
`ip_options.h`), and Linux/Windows sockets expose `IP_TOS`/`IP_ECN`. Apple
ships L4S in its own stacks from iOS 17 [C5], and GeForce NOW demonstrated an
L4S build in 2022 [P3] — so an L4S-marking AP (none here today) is a plausible
later win. The estimator sits behind one protocol in the core, so GCC-style and
SCReAMv2 can be compared on recorded traces before choosing.

### 6.3 Encoder actions and recovery

The estimator's output is a **total send budget**; an allocator turns it into:

1. **Bitrate per stream:** priority desktop/game > focused Unity window >
   others (the "focus-based FPS tiering" v2 left as follow-up), minus audio and
   FEC overhead. Applied live (`setLiveBitrate` on VT; NVENC
   `nvEncReconfigureEncoder` without IDR; VAAPI rate-control reconfigure).
2. **Frame rate:** step 120 → 60 → 30 when the bitrate per frame falls below a
   quality floor for 3 s (and v2's existing encode-time step-down stays).
3. **Resolution:** step down by 2/3 only when sustained (10 s) below the floor at
   the lowest FPS step; costs a new format and an IDR, so it is rare and
   hysteretic. The client scales back up for display, as it does for letterboxed
   streams now.

**Loss recovery, cheapest first:**

1. FEC repairs it (no signalling).
2. NACK + resend inside the frame deadline (LAN only, §4.2).
3. **Reference invalidation:** the receiver reports the first damaged frame;
   the host makes the encoder stop referencing it. The next frame predicts from
   a frame the receiver is known to have, so recovery costs about one P-frame
   instead of an IDR. The receiver meanwhile shows the last good picture (game
   mode) or decodes through (desktop, where a brief smear beats a freeze —
   selectable). Per encoder:
   - **NVENC:** `NvEncInvalidateRefFrames` per damaged frame, gated on
     `NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION`; falls back to IDR when the
     damage reaches past the DPB (Sunshine uses 5 refs for H.264/HEVC) [W1][M1].
     Forum reports say it misbehaves on some GPUs [W1] — verify on the 3080.
   - **AMF:** LTR slots with `MarkCurrentWithLTRIndex` /
     `ForceLTRReferenceBitfield` [W2]. **QSV/oneVPL:** reference-list control
     with `RejectedRefList`/`LongTermRefList` [W3]. Sunshine implements
     invalidation for NVENC only and sends IDRs for every other encoder [M1], so
     this is ground v3 can gain on AMD/Intel hosts.
   - **VideoToolbox:** no invalidate call; `EnableLTR` with
     `AcknowledgedLTRTokens` and `ForceLTRRefresh` (macOS 12+, in the macOS 27
     SDK) — the client acks LTR tokens, and a forced refresh predicts from an
     acknowledged LTR, or is an IDR if there is none. Whether it works on the
     *hardware* HEVC encoder is open (§9, risk 3).
   - **VAAPI:** per driver; IDR until proven.
4. **IDR** when the encoder can't invalidate, when no acknowledged reference is
   left, or when a format changes. Rate-limited to one per 250 ms per stream.
   Intra refresh (NVENC) is the alternative for a host whose IDRs are too big
   to send in one frame time: it spreads the refresh over N frames.

**Desktop stream policy changes:** v2's "no scheduled key frames, refine a still
picture forever" stays, but only together with LTR acks: refinement frames are
marked discardable where the encoder allows, and every N seconds of stillness one
refined frame is made an LTR so recovery has a sharp anchor.

### 6.4 Pacing

Each frame's shards leave through a token-bucket pacer at 1.5× the current
budget (bursting up to ~4 ms of data), not all at once: a 500 KB frame dumped
into a Wi-Fi driver queue is where v2's latency spikes come from (inference;
Phase 0 confirms with a trace). Socket writes are batched (`sendmmsg`/UDP GSO on
Linux, `WSASendMsg` with USO on Windows, `NWConnection.batch` on Apple), kept
under 64 KB and 64 segments per batch — Sunshine's limits, because larger
Windows batches bypass `SO_SNDBUF` and GSO caps at 64 [M1]. Audio and
input/control bypass the pacer queue (strict priority) but count against the
budget. The pacer also replaces v2's desktop gate: if a frame's shards haven't
all left before the next frame is ready, the older frame's remaining *data*
shards still go (references need them) but its unsent parity is dropped and the
estimator is told the encoder is outrunning the link.

### 6.5 Multi-viewer fan-out

One encode per stream is shared, so viewers on different links can't each get
their own bitrate. Rules:

- The stream's encoder bitrate is the **minimum** of its viewers' allocations,
  floored at a quality minimum; a viewer whose estimate is under that floor
  for 10 s is moved to a reduced-rate second encode if the encoder budget allows
  (simulcast-of-one, NVENC and the M2 Max's second engine can afford it; the
  M1's single engine can't), else it gets frame-dropping at the pacer.
- **FEC is per viewer**: parity is computed per viewer from the shared data
  shards, sized by that viewer's loss. RS encode is cheap enough to do N times.
- **Recovery is shared:** one viewer's invalidation changes the bitstream for
  all. Invalidation costs a P-frame, so that is acceptable; IDR requests from
  any viewer are rate-limited across the stream.
- LTR acknowledgement must be the intersection: a reference is only "known
  good" once **every** viewer of the stream has it.

## 7. Code architecture

### 7.1 Package

`~/Projects/Longwave/Packages/LongwaveStream/` — an app-local SwiftPM package
(the portfolio rule: one app needs it, so not RAVE; and never a third RAVE
package). It sits at the **repo root's** `Packages/`, not inside the `Longwave/`
source folder: that folder is a `PBXFileSystemSynchronizedRootGroup`, so Swift
files placed under it would be compiled straight into the app target.

```
Packages/LongwaveStream/
  Package.swift            platforms: .visionOS(.v26), .iOS(.v26), .macOS(.v14);
                           builds on Linux and Windows (no platform gate there)
  Sources/
    StreamWire/            frames, shard headers, messages, capability set,
                           v2 compat codecs (MacNativeStreamProtocol moves here)
    StreamCrypto/          Noise NNpsk0, AEAD records, replay window, key IDs;
                           knock tag + PairingExchange (moved from Shared/CompanionPairing.swift)
    StreamFEC/             Reed–Solomon (see below)
    StreamTransport/       session state machine, reliable channels, ACK/NACK,
                           pacer, congestion estimator, clock sync; I/O and time
                           via protocols (DatagramSocket, MonotonicClock, Timer)
    StreamPlayout/         PlayoutController (lateness, held target, drift),
                           frame assembler (shards → decodable frames), recovery logic
    StreamHost/            viewer set, subscriptions, fan-out, rate allocator,
                           encoder policy; protocols CaptureSource, VideoEncoder,
                           AudioSource, InputSink, DisplayProvider, WindowInventory
    StreamHostWindows/     Swift side of the Windows shims (only built on Windows)
    CStreamWin/            C/C++ shim: WGC + D3D11, NVENC/AMF/MF, WASAPI, SendInput,
                           virtual gamepad, qWAVE
    StreamHostLinux/       Swift side of the Linux shims (only built on Linux)
    CStreamLinux/          C shim: portal + PipeWire, VAAPI/NVENC, uinput
    longwave-host/         executable for Windows/Linux (headless daemon + CLI)
    StreamSim/             deterministic network simulator (test support)
  Tests/                   per-module unit tests; Sim-driven integration tests
```

**What stays in the app targets.** Everything Apple-UI or Apple-media:
`MacNativeVideoRenderer`, `MacNativeFrameSurface`, `MacNativeStreamManager` and
the views; the Mac host's ScreenCaptureKit/VideoToolbox/CGEvent/CGVirtualDisplay
code in `CompanionMac/`, which is rewired to implement the `StreamHost`
protocols. A `DatagramSocket` implementation over Network.framework lives in the
app targets (`Shared/`), so the package itself has no Network.framework
dependency and builds identically everywhere.

**What moves out of `Shared/`:** `MacNativeStreamProtocol.swift` (to
`StreamWire`, kept for v2), `CompanionPairing.swift` (to `StreamCrypto`),
`MacNativeStreamCrypto.swift` (stays in `Shared/` as the v2 TLS parameters
until v2 is retired), and the PCM24/stamp logic from `AudioStreamProtocol.swift`
(to `StreamWire`; VVAS keeps importing it).

**CryptoKit → swift-crypto.** Shared code switches `import CryptoKit` to
`import Crypto`; on Apple platforms swift-crypto re-exports CryptoKit, so the
binary there doesn't change.

**FEC library.** Vendor **cm256** (BSD-3, GF(2^8) Cauchy, k+m ≤ 256, SIMD
kernels) as a C target, with **Leopard-RS** (BSD-3, same author, GF(2^8) up to
256 shards and GF(2^16) beyond) as the alternative if a single large block per
desktop frame benchmarks better than several 255-shard blocks [F1][F2]. No Swift
RS implementation exists to adopt [F3]; writing one is possible but the C
libraries already carry tuned SSSE3/AVX2/NEON paths. BSD-3 is compatible with
the MIT edition (add to `THIRD_PARTY_NOTICES.md`). The core's API is
`encode(data shards) → parity` and `reconstruct(any k) → data`, tested against
the library-independent property "any k of k+m reconstruct". (ISA-L, also
BSD-3, is x86-centric and heavier than needed.)

### 7.2 Windows: C shims, Swift core

The Windows host is the Swift core calling a **C ABI** shim, not Swift talking to
COM. The shim is a C++ static library exposing plain C functions and
callbacks — `lw_capture_start(monitor|hwnd, cb)`, `lw_encoder_create(params)`,
`lw_encoder_encode(texture, flags)`, `lw_encoder_invalidate(frames)`,
`lw_audio_loopback_start(cb)`, `lw_input_inject(event)`,
`lw_gamepad_create(kind)` — with frames passed as opaque D3D11 texture handles
and encoded output as byte buffers. Swift imports it through a module map.

Why: Swift on Windows is proven here only for headless engine code (Oneiros'
engine suite on Swift 6.2.4 on `gaming-pc`; its
portability plan notes nothing about COM, WinRT, Media Foundation, WASAPI or
D3D). Swift has no first-class COM interop today — vtables and refcounts are
hand-written, and an `@COM` design was only pitched in April 2026 [S3];
swift-winrt exists and is maintained [S4], but WGC, NVENC and WASAPI are COM or
plain C, not WinRT-first. C++ is the language these APIs are documented, sampled
(`robmikh/Win32CaptureSample` for WGC [W6]) and debugged in;
the existing C# `GraphicsCapture.cs`/`VideoEncodePipeline.cs`/`InputInjector.cs`
are the reference for which calls work on this machine. A C ABI keeps Swift's
C++ interop (which is newer on Windows) out of the critical path, and the same
pattern serves Linux.

**Encoder choice on Windows:** NVENC directly through the NVENC SDK headers
(it is the encoder on the user's RTX 3080, and it has reference invalidation,
LTR, intra refresh and an ultra-low-latency tuning preset [W1]), with AMF and
Media Foundation as fallbacks. The C# host's MF-only path can't invalidate
references (MF's `CODECAPI_AVLowLatencyMode` only removes reordering delay [W7]).

**Capture on Windows:** WGC, as the C# host already uses (`CreateForMonitor` /
`CreateForWindow` via `IGraphicsCaptureItemInterop` [W6]) — it is the only API
that captures single windows, which Unity streams need. Two caveats: Sunshine
still calls WGC "beta" and DXGI Desktop Duplication "well-supported" [M4], and
WGC's `MinUpdateInterval` (needed above 60 Hz) exists only from SDK 26100 /
Windows 11 24H2 [W6]. DXGI duplication stays the fallback for the desktop
stream.

**Virtual gamepads on Windows** need a driver. ViGEmBus — what Sunshine uses —
was archived on 2023-11-02; existing installs keep working but nothing
maintains it, and its announced successor hasn't shipped [W8]. Phase 3 decides
between shipping ViGEmBus as is, a Virtual HID Framework driver of our own, or
the successor if it appears.

**Process model:** the Electron Companion and its C# backend stay — they own
Hotspot NAT, PCVR install/supervision and the UI. The C# backend launches and
supervises `longwave-host.exe` (as it supervises other processes), talks to it
over the existing named-pipe RPC style for enable/token/status, and its own
Native stream is retired once the Swift host reaches parity (§8). The Swift
runtime DLLs ship next to `longwave-host.exe` in the companion's installer
(redistribution of the Swift runtime on Windows is a Phase 3 spike item).

### 7.3 Linux

`longwave-host` as a systemd user service.

- **Capture:** xdg-desktop-portal ScreenCast + PipeWire (DMA-BUF where
  offered) on GNOME and KDE Wayland. The portal can create a **virtual
  monitor** (source type `VIRTUAL`) — the Linux counterpart of the Mac's
  `CGVirtualDisplay` — and since version 4 hands back a `restore_token` so
  consent is asked once, not per session [L1]. GNOME's Mutter also has a
  headless backend and `RecordVirtual` virtual monitors [L3]. wlroots
  compositors via `ext-image-copy-capture-v1` (the upstreamed screencopy) [L4];
  KMS grab as an opt-in fallback for headless boxes (needs `CAP_SYS_ADMIN`);
  X11 last. Sunshine's backend list (`nvfbc`, `wlr`, `kms`, `kwin`, `x11`) is
  the map of what exists [M4].
- **Encode:** VAAPI (AMD/Intel) or NVENC (NVIDIA); Vulkan Video encode (H.264,
  H.265, AV1 since Vulkan 1.3.302) as a later single path [L5].
- **Input:** uinput for keyboard and mouse and uinput/uhid for gamepads, with
  a udev rule the installer adds (Sunshine's grants `/dev/uinput` and
  `/dev/uhid` to the `input` group with `uaccess`) [L6]. **inputtino** (MIT)
  already emulates Xbox, PlayStation (DualSense with gyro, touchpad, adaptive
  triggers) and Nintendo pads this way and is a candidate dependency for the C
  shim [L7]. Where uinput isn't allowed, the RemoteDesktop portal with libei
  (`ConnectToEIS`, portal v2) [L2].
- **Audio:** PipeWire monitor of the default sink.
- **Packaging:** not a Swift static-SDK binary — the static Linux SDK has no
  dynamic linking at all, so it can't `dlopen` libva, NVENC or PipeWire [S2].
  It ships dynamically linked (glibc toolchain), built per target distro or as
  a Flatpak.

### 7.4 Logging off Apple

All logging goes through `DebugLogger` (portfolio rule). DebugTrace is
Apple-only today (`import os` in `DebugLogger.swift`, `DebugSurface.swift`;
platforms list has no Linux/Windows). The Oneiros portability plan already
decided the direction: provide a portable implementation **in DebugTrace**,
privacy labels preserved — not a private copy of the logging logic.

Concretely: `DebugLogger`/`DebugLogMessage` gain a `#if canImport(os)` split.
On Apple, unchanged. Elsewhere, the same API writes to an in-memory ring (the
"no disk" rule from `debug-logs-privacy-no-disk`) plus stderr, with
`.private` values redacted and `mask: .hash` hashing exactly as on Apple; the
Windows build can add an ETW sink later. The trace zip and `DebugTraceServer`
stay Apple-only until a Windows/Linux need appears. This is a small, separate
change to DebugTrace and lands before the core's first non-Apple build.

### 7.5 Testing

- **Unit tests per module**, running under `swift test` on macOS, Linux (CI
  container) and Windows (`gaming-pc`, via `ssh-exec -P`).
- **Deterministic simulator (`StreamSim`).** The transport only sees
  `DatagramSocket`, `MonotonicClock` and `Timer`, so a test can run a host and
  a client session in one process on virtual time, with a link model between
  them: bottleneck rate and queue, propagation delay, jitter, reordering,
  uniform and Gilbert–Elliott loss, and a **Wi-Fi stall model** fitted to the
  measured headset behaviour (60–180 ms holds in 20–40 s stretches). Seeds make
  failures reproducible. Media is synthetic (frames with realistic size
  distributions from recorded traces). Assertions are the §1 metrics.
- **Recorded-trace replay.** Phase 0 records packet timing from real sessions
  (Moonlight and v2 on the user's Wi-Fi 7 AP, the Grandstream GWN7665); the
  simulator replays them against candidate estimators and FEC policies.
- **Loopback integration.** Real sockets on localhost with an impairment shim
  (drop/delay/reorder in the `DatagramSocket` wrapper), real encoders, a
  headless client that decodes and checks frame integrity (the host draws a
  frame-number barcode into a corner of synthetic capture content).
- **Real-world A/B.** The same game, client and AP, alternating Moonlight and
  v3 sessions, metrics from §1. The comparison that decides Moonlight's
  retirement.

## 8. Phased roadmap

Effort is calendar time for one engineer working mostly on this, and is a rough
judgement.

### Phase 0 — measurement harness and baseline (2–3 weeks)

- In-band timing on v2: add capture-time → receive → decode → present logging
  on the client (`MacNativeVideoRenderer`, the surface decoder), plus a PING
  clock estimate over the existing TCP control path. Display it in the stream
  stats overlay and log it.
- Glass-to-glass rig: a test-pattern app on the host (frame counter + flashing
  patch), a 240 fps camera, a script that extracts latency from the video.
  Covers Mac and iPad clients; Vision Pro relies on in-band numbers.
- Characterise the headset's Wi-Fi: idle ping vs ping under a 60 fps / 50 Mbps
  UDP stream (does constant traffic suppress the 60–180 ms stalls?), on the
  Wi-Fi 7 AP, with the Mac host wired; and once more with
  `includePeerToPeer` on, Mac host on Wi-Fi (risk 12).
- Baseline Moonlight (Sunshine on `gaming-pc`) on the same clients: its stats
  overlay plus the camera rig.
- Benchmark VideoToolbox LTR on the hardware HEVC encoder (does `EnableLTR`
  work without low-latency rate control, which returns a software encoder —
  [[vt-hevc-encode-latency-benchmarks]]?).
- Check `NvEncInvalidateRefFrames` on the RTX 3080 with a minimal NVENC harness
  (Sunshine on the same box exercises it already; its log says whether RFI is
  in use).

Exit: a table of v2 and Moonlight latency (p50/p95/p99), loss behaviour and
stall behaviour on three links (Wi-Fi 7 AP, Tailscale, impaired); recorded
traces committed for the simulator; the LTR and NVENC-invalidation answers.

### Phase 1 — core package and v3 on the Mac host (6–8 weeks)

- DebugTrace portable logging seam (§7.4).
- `LongwaveStream` package: wire, crypto (Noise + test vectors), FEC,
  transport, playout, host, simulator.
- Mac host: `CompanionMac` implements `CaptureSource`/`VideoEncoder`/`AudioSource`
  /`InputSink`; v3 served on UDP 4857 beside v2, behind a Companion setting.
- Client: v3 path in `MacNativeStreamClient` behind the `ns=3` capability, same
  renderer; audio over v3 into the existing receiver via `PlayoutController`.
- LTR recovery if Phase 0 says it works on hardware HEVC; IDR otherwise.

Exit: v3 meets or beats v2 on every Phase 0 metric for the Mac desktop and
Unity windows; simulator suite green at 2%/10% loss and the stall model; a week
of daily use without falling back.

### Phase 2 — Windows Swift host (8–10 weeks, starting with a 2-week go/no-go spike)

Moved ahead of Linux: the gaming PC is Windows, Sunshine runs there today, and
Moonlight replacement is the north star.

- **Spike (gate):** `longwave-host.exe` built with the Swift toolchain on
  `gaming-pc` capturing with WGC, encoding with NVENC, through the C shim, into
  the Phase 1 core; streaming to a real client. Also: Swift runtime
  redistribution in the installer. **If this fails**, the fallback is a C++
  host process implementing the same v3 wire format against the core's test
  vectors and simulator traces — a second implementation, but a native one —
  and the decision is recorded.
- Parity with the C# host: desktop and per-window streams, HID keycodes,
  display list, pairing (which the C# host lacks), audio (which it also lacks:
  WASAPI loopback).
- C# backend supervises the Swift host; the C# Native stream is switched off
  behind a setting, then removed.

Exit: everything the C# Native host did, plus audio, acks and recovery;
latency within Phase 0's Moonlight numbers + 5 ms on the same machine.

### Phase 3 — game-grade features (6–8 weeks, overlaps Phase 2's tail)

- Gamepads: client `GameController` → STATE frames; host virtual gamepad
  (Windows driver choice in §9; Linux uinput). Rumble back.
- Relative pointer / pointer lock for games (the open item from
  [[native-mouse-bridge-and-vd-settings-2026-10-03]]).
- 120 fps game streams; HDR10 (HEVC Main10 PQ with mastering metadata) end to
  end; AV1 where both ends have hardware.
- Multichannel audio up to 7.1.4 through Opus multistream into the client's
  sound stage (`RAVEPhaseStage`, as Moonlight surround already does); spatial
  objects if the Windows investigation finds a source.
- **Retire Moonlight on Windows** when, on the same client and AP, v3's latency
  is within the §1 margins of Moonlight's, loss handling is at least as good, and
  the user has played on it for two weeks without reaching for Moonlight.
  "Retire" means the docs and UI recommend v3; the Moonlight edition stays
  buildable for hosts that only run Sunshine.

### Phase 4 — Linux host (4–6 weeks)

- Portal + PipeWire capture, VAAPI/NVENC, uinput, PipeWire audio, packaged
  for one distro first.
- Exit: the Phase 2 exit criteria on a Linux box with an AMD or NVIDIA GPU.

Linux comes last only because no machine here needs it today; the core makes it
mostly shim work. If a Linux gaming box appears, it can swap with Phase 3.

### Phase 5 — retirement

- Remove the C# Native stream and its BouncyCastle TLS-PSK.
- Remove v2 from hosts after the coexistence window (§4.6).
- Fold VVAS audio-only connections into v3 if v3's audio has matched Music mode
  (metadata, artwork, transport control move to control/bulk channels).

## 9. Risks and open questions

### Verified facts (with sources)

- v2 structure, pacing, ABR and recovery: the files cited in §2.
- Headset Wi-Fi stalls of 60–180 ms in 20–40 s stretches, present with no stream
  running (visionOS 27): `KNOWN_CONSTRAINTS.md`, audio bullets.
- VideoToolbox HEVC encode latency and that low-latency rate control yields a
  software encoder: [[vt-hevc-encode-latency-benchmarks]] (measured 2026-10-02).
- `kVTCompressionPropertyKey_EnableLTR`, `AcknowledgedLTRTokens`,
  `ForceLTRRefresh` exist (macOS 12 / iOS 15 / visionOS 1): macOS 27 SDK
  `VTCompressionProperties.h`.
- Network.framework QUIC exposes no congestion-control option and allows one
  datagram flow per connection; Network.framework can set ECN per packet:
  macOS 27 SDK `quic_options.h`, `ip_options.h`.
- Apple supports TLS-PSK only with TLS 1.2, so QUIC on Apple needs a
  certificate identity [R6]; matches `Shared/AudioCrypto.swift`'s observation.
- MsQuic: Cubic or preview BBR, no disable, no PSK, cert pinning via
  `PEER_CERTIFICATE_RECEIVED` [R3]. RFC 9221 datagrams are congestion-controlled
  [R1].
- Swift 6.2.4 on `gaming-pc` runs Oneiros' headless engine tests:
  Oneiros' `Docs/PORTABILITY_PLAN.md`.
  No first-class COM interop in Swift [S3].
- The Static Linux SDK has no dynamic linking [S2].
- Sunshine: 20% default FEC, ≤ 255 shards/block, ≤ 4 blocks/frame, min 2 parity,
  RFI for NVENC only, 64 KB / 64-packet send batches, media encryption off on LAN
  by default [M1][M4]. Moonlight: 1392/1024-byte packets, audio RS 4+2 with
  5 ms Opus [M2][M3].
- ViGEmBus archived 2023-11-02 [W8].

### Inference and open questions

1. **The headset's Wi-Fi may set the floor, not the protocol.** If the 60–180 ms
   stalls also hit a constantly streaming flow, no FEC or rate control fixes
   them (the data is late, not lost) and Moonlight suffers equally. Phase 0
   measures this first; the latest-wins playout in §5 limits the damage to a
   freeze rather than accumulated lag.
2. **Swift on Windows for a media host is unproven.** Mitigated by the C-ABI
   shim design and the Phase 2 go/no-go spike with a named fallback.
3. **VideoToolbox LTR on hardware HEVC is unverified, and doubtful.** LTR was
   introduced with VideoToolbox's low-latency mode, which WWDC21 described as
   H.264-only [V1]; the SDK header's "cloud gaming" recipe pairs them; and our
   measurements show low-latency rate control returns a *software* encoder for
   HEVC. If LTR needs that mode, Mac hosts recover with IDRs (as today) and the
   desktop leans on NACK — acceptable, since the Mac is not where Moonlight is
   being replaced.
4. **Custom transport risk.** Owning reliability and crypto framing means owning
   their bugs. Mitigations: Noise exactly to spec with test vectors; WireGuard's
   replay/roaming rules; the simulator exercising every loss path; fuzzing the
   frame parser.
5. **Network.framework UDP throughput on visionOS.** At 100 Mbps and 1200-byte
   payloads that's ~10 k datagrams/s; per-datagram callbacks may cost real CPU on
   the client. Measure in Phase 1; `NWConnection.batch` and multi-message
   receive are the levers, BSD sockets the fallback.
6. **NACK vs FEC balance** on the real AP is an empirical question for the
   simulator and Phase 1.
7. **Spatial audio objects** from Windows games may be unobtainable without
   being the system's spatial audio renderer.
8. **Virtual gamepads on Windows** need a driver, and the de-facto one is
   unmaintained (§7.2).
9. **Anti-cheat** may reject injected input or virtual pads in some games;
   Sunshine faces the same.
10. **Multi-viewer on one encoder** forces the slowest viewer's bitrate on
    everyone; simulcast is only partly possible on single-engine Macs.
11. **swift-crypto on x64 Windows** isn't claimed by its README [S1]; CNG
    fallback in the shim.
12. **Mac Virtual Display's transport is unknown.** Reports say it uses a
    direct device-to-device link that needs no Wi-Fi network [P4]; Apple
    publishes nothing. If that link is what lets Mac VD dodge the headset's
    Wi-Fi stalls, no app protocol can match it, and v3 on the Mac competes on
    features rather than raw latency. (The "AWDL peer-to-peer not enabled" item
    in [[native-mac-vd-parity-2026-10-02]] is the one lever an app has:
    `NWParameters.includePeerToPeer`. Worth a Phase 0 measurement.)
13. **WMM limits.** Vendor material reports WMM video/voice queues degrading
    with more than one or two active users [C6]; marking helps on a quiet AP,
    not a busy one.

### Sources

Fetched 2026-10-04 unless noted. Design facts only; no GPL code was read for
reuse.

- [M1] Sunshine `src/stream.cpp`, `src/video.cpp`, `src/nvenc/nvenc_base.cpp` —
  https://github.com/LizardByte/Sunshine (master)
- [M2] moonlight-common-c `src/Video.h`, `RtpVideoQueue.c`, `VideoDepacketizer.c`,
  `ControlStream.c`, `RtpAudioQueue.h`, `SdpGenerator.c`, `Limelight.h` —
  https://github.com/moonlight-stream/moonlight-common-c (master)
- [M3] moonlight-qt `app/streaming/session.cpp` —
  https://github.com/moonlight-stream/moonlight-qt
- [M4] Sunshine configuration docs —
  https://github.com/LizardByte/Sunshine/blob/master/docs/configuration.md
- [P1] Parsec, "A networking protocol built for the lowest latency interactive
  game streaming" — https://parsec.app/blog/a-networking-protocol-built-for-the-lowest-latency-interactive-game-streaming-1fd5a03a6007
- [P2] Ricotta, "Bug hunting in Steam Remote Play", SSTIC 2023 —
  https://www.sstic.org/media/SSTIC2023/SSTIC-actes/bug_hunting_in_steam_remote_play/SSTIC2023-Article-bug_hunting_in_steam_remote_play-ricotta.pdf
- [P3] CableLabs, L4S interop (2022) — https://www.cablelabs.com/blog/l4s-interop-lays-groundwork-for-10g-metaverse
- [P4] UploadVR on visionOS 2.2 Mac Virtual Display (2024) —
  https://www.uploadvr.com/visionos-2-2-ultrawide-mac-virtual-display/
- [R1] RFC 9221, QUIC DATAGRAM — https://www.rfc-editor.org/rfc/rfc9221.html
- [R2] Network `QUIC` (iOS 26) — https://developer.apple.com/documentation/network/quic
- [R3] MsQuic `QUIC_SETTINGS`, platforms, `msquic.h` —
  https://microsoft.github.io/msquic/msquicdocs/docs/api/QUIC_SETTINGS.html,
  https://github.com/microsoft/msquic; Swift wrapper https://github.com/team-unstablers/swift-msquic
- [R4] draft-ietf-avtcore-rtp-over-quic-14 —
  https://datatracker.ietf.org/doc/html/draft-ietf-avtcore-rtp-over-quic
- [R5] Apple Developer Forums 766220 (QUIC datagrams) —
  https://developer.apple.com/forums/thread/766220
- [R6] Apple Developer Forums 768961 and 688508 (TLS 1.3 PSK, QUIC identity) —
  https://developer.apple.com/forums/thread/768961
- [R7] swift-nio-quic — https://github.com/apple/swift-nio-quic
- [C1] draft-ietf-rmcat-gcc-02 — https://datatracker.ietf.org/doc/html/draft-ietf-rmcat-gcc-02;
  libwebrtc goog_cc — https://webrtc.googlesource.com/src/+/refs/heads/main/modules/congestion_controller/goog_cc/
- [C2] draft-holmer-rmcat-transport-wide-cc-extensions-01 —
  https://datatracker.ietf.org/doc/html/draft-holmer-rmcat-transport-wide-cc-extensions-01;
  libwebrtc feedback generator — https://webrtc.googlesource.com/src/+/refs/heads/main/modules/remote_bitrate_estimator/transport_sequence_number_feedback_generator.cc
- [C3] RFC 8888 — https://www.rfc-editor.org/rfc/rfc8888.html
- [C4] SCReAMv2, draft-ietf-ccwg-rfc8298bis-screamv2 —
  https://datatracker.ietf.org/doc/draft-ietf-ccwg-rfc8298bis-screamv2/
- [C5] WWDC23 "Reduce network delays with L4S" —
  https://developer.apple.com/videos/play/wwdc2023/10004/
- [C6] Excentis on L4S over Wi-Fi (vendor material) —
  https://www.excentis.com/test-every-aspect-of-user-experience-with-excentis
- [F1] Leopard-RS — https://github.com/catid/leopard
- [F2] cm256 / longhair — https://github.com/catid/cm256, https://github.com/catid/longhair
- [F3] (search result) no Swift Reed–Solomon package found, 2026-10-04
- [F4] Qualcomm IPR declarations on RFC 6330 —
  https://datatracker.ietf.org/ipr/2554/, https://datatracker.ietf.org/ipr/1958
- [S1] swift-crypto — https://github.com/apple/swift-crypto
- [S2] Static Linux SDK — https://www.swift.org/documentation/articles/static-linux-getting-started.html
- [S3] "A vision for COM interoperability in Swift" (pitch, 2026-04-15) —
  https://forums.swift.org/t/pitch-a-vision-for-com-interoperability-in-swift/86049
- [S4] swift-winrt — https://github.com/thebrowsercompany/swift-winrt
- [W1] NVENC API headers (13.1) —
  https://github.com/FFmpeg/nv-codec-headers/blob/master/include/ffnvcodec/nvEncodeAPI.h;
  invalidation reports — https://forums.developer.nvidia.com/t/nvsdk-nvencinvalidaterefframes-not-works/228680
- [W2] AMF `VideoEncoderVCE.h` —
  https://github.com/GPUOpen-LibrariesAndSDKs/AMF/blob/master/amf/public/include/components/VideoEncoderVCE.h
- [W3] oneVPL `mfxstructures.h` — https://github.com/intel/libvpl/blob/main/api/vpl/mfxstructures.h
- [W4] WASAPI loopback recording —
  https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording
- [W5] Spatial sound (ISpatialAudioClient) —
  https://learn.microsoft.com/en-us/windows/win32/coreaudio/spatial-sound
- [W6] `IGraphicsCaptureItemInterop` —
  https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nf-windows-graphics-capture-interop-igraphicscaptureiteminterop-createforwindow;
  `MinUpdateInterval` — https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.minupdateinterval;
  sample — https://github.com/robmikh/Win32CaptureSample
- [W7] `CODECAPI_AVLowLatencyMode` —
  https://learn.microsoft.com/en-us/windows/win32/medfound/codecapi-avlowlatencymode
- [W8] ViGEm end of life — https://docs.nefarius.at/projects/ViGEm/End-of-Life/
- [L1] ScreenCast portal — https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html
- [L2] RemoteDesktop portal — https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html
- [L3] Phoronix, GNOME 40 headless/virtual monitors — https://www.phoronix.com/news/GNOME-40-Headless-Virtual
- [L4] Phoronix, Wayland merges screen-capture protocols — https://phoronix.com/news/Wayland-Merges-Screen-Capture
- [L5] Khronos, Vulkan Video AV1 encode — https://www.khronos.org/blog/khronos-announces-vulkan-video-encode-av1-encode-quantization-map-extensions
- [L6] Sunshine udev rule — https://github.com/LizardByte/Sunshine/blob/master/src_assets/linux/misc/60-sunshine.rules
- [L7] inputtino — https://github.com/games-on-whales/inputtino
- [V1] WWDC21 "Explore low-latency video encoding with VideoToolbox" —
  https://developer.apple.com/videos/play/wwdc2021/10158/
