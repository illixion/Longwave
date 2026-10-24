# Native Stream Protocol v3

Design for the third version of the Native stream: a game-grade, cross-platform
protocol, served by one portable Swift host core, that makes Longwave's own
stream good enough to retire Moonlight/Sunshine for Windows and Linux hosts.

Written 2026-10-04. Nothing here is implemented yet. Facts carry a link or a
file reference; anything that is a judgement says so. The verified/inferred split
is kept explicit in [Risks and open questions](#9-risks-and-open-questions).

## Status

- **Design: proposed.** Phase 0 (measurement) can start from this document.
- **Phase 2 go/no-go spike: GO** (2026-10-04). A Swift executable on
  `gaming-pc` captured the real 1440p desktop (WGC and DXGI duplication),
  encoded HEVC with NVENC straight from the GPU texture, and streamed it over
  UDP to a Swift receiver on the Mac, through a C-ABI shim that SwiftPM builds.
  Results, workarounds and what is still open:
  [Phase 2 spike result](#phase-2-spike-result-2026-10-04-go).
- The v2 protocol (`Shared/MacNativeStreamProtocol.swift`) stays the shipping
  protocol, and remains served until every client in the field speaks v3.
- **PCVR and depth are in scope (2026-10-12).** v3 is also the wire for
  native PCVR (§4.7), so the protocol is stress-tested by a 90 Hz stereo
  stream from its first build rather than retrofitted. It also carries an
  optional depth stream that turns a flat game into 3D on the headset (§4.8).
  Both rest on two general mechanisms, frame side data and auxiliary streams
  (§4.2), which land in Phase 1 with the core.
- **`StreamWire` built (2026-10-12).** The wire types of §4
  exist as a Foundation-free module in `Packages/LongwaveStream`, with golden
  byte vectors (the interop reference for the C++ side) and a fuzzed decoder.
  Writing them down settled the encoding details §4 left open, and each is
  noted in place, marked 2026-10-12. Questions that need measurement or a
  design decision are §9 items 19–21.
- **External frame sources: built and measured (2026-10-12).** The
  cross-process handoff that both of those use on Windows added 0.007 ms at
  p99 at 90 Hz (pass mark 1 ms). See §7.2 and open question 18.
- **`StreamFEC` built (2026-10-24).** Reed–Solomon over the vendored cm256
  (`Sources/CCM256`, two portability patches listed in its README), the §4.2
  block layout, and the sharder that turns a frame payload into shards
  with parity. Tested on arm64 and on x86-64 under Rosetta, with a golden
  parity vector. First of the Phase 1 core modules.
- **Frame assembler built (2026-10-24),** in `StreamPlayout`. It collects shards
  per block, rebuilds with FEC as soon as any k arrive, and delivers frames
  strictly in frame-number order. A finished frame waits behind an earlier
  incomplete one until that one completes or times out. Each frame is marked
  with whether its `referenceDistance` chain is intact, with long-term
  references kept beyond the history window. After the reorder window it lists
  NACK candidates (the missing data shard indices, a whole block, or a whole
  frame). It gives up a frame after a timeout, and a run of lost frames, or a
  jump far ahead, as a single event. Buffered bytes are capped. Tested with a
  soak at 15% loss with reordering and resends.
- **`StreamCrypto` built (2026-10-24).** The Noise_NNpsk0 handshake, per-device
  PSKs and key IDs, AEAD transport records with key phases, the 2048-packet
  replay window, and a filter for replayed initiations. The Noise layer passes
  every published NN-family vector. The Longwave framing is pinned by golden
  bytes from an independent Python implementation. The wire details are under
  [Handshake and record encoding](#handshake-and-record-encoding-2026-10-24),
  which also corrects AES-GCM's rekey interval to 2^23 packets. The
  `CompanionPairing.swift` move to this module waits until the app links the
  package. StreamWire, StreamFEC, StreamPlayout and StreamCrypto pass their
  tests on x64 Windows too (147 tests, Swift 6.2.4, swift-crypto on BoringSSL).
- **Transport and simulator built (2026-10-24).**
  - **Wire:** the transport frame bodies, including a new NACK frame (0x09),
    are in `StreamWire`, documented under the transport frame bodies of §4.1.
  - **`StreamTransport`:** the reliable channels (offset ACKs, timeout and
    reordering loss detection), RTT, clock sync, the pacer, and FEEDBACK
    generation with the sender's packet log. `TransportSession` ties them to
    `StreamCrypto`. A client connector retries with backoff, and a host
    endpoint accepts, routes, follows roaming clients, and supersedes a
    device's session only after key confirmation.
  - **`StreamSim`:** links with delay, jitter, a bottleneck queue, random and
    Gilbert–Elliott loss, and the headset's Wi-Fi stalls.
  - **Simulated tests:**
    - The handshake completes at 25% loss each way.
    - 2,000 input events cross 10% loss, jitter and stalls exactly once and in
      order.
    - 300 frames of 60 fps video with FEC and NACK arrive byte for byte at 2%
      and 10% loss.
    - The client knows the host's clock to under 0.4 ms.
  - **Not yet:** the Mac host and client wiring. The hello and hello-ack
    contents (§4.6) and DPLPMTUD (§3, "Packet size") were added later the same
    day.
- **Rate controller built (2026-10-24),** in `StreamTransport`: GCC's
  delay-based loop with four additions for this product, loss turned into FEC,
  and probing. Design and simulated results are under
  [Implementation](#implementation-2026-10-24) in §6.2.
- **First Mac host and client wiring (2026-10-24), behind two settings.**
  - **Companion:** with its Native v3 setting on, it serves the desktop
    stream on UDP 4857 beside v2 (`MacNativeV3Server`).
  - **Clients:** with theirs on, they try v3 first, falling back to v2 after 2 s
    or a refused port (`MacNativeV3Link`, inside `MacNativeStreamClient`).
  - **What v3 carries:** the desktop, remote input (as input events and pointer
    STATE), the display choice and remote-control status. Window streams,
    stills and audio stay on v2.
  - **Shared parts:** the package gained `StreamHost.VideoStreamSender` (one
    viewer's frames, FEC, pacing and NACK resends, gated on its rate
    controller) and `StreamPlayout.VideoStreamReceiver` (decodable frames
    only, NACKs, recovery requests).
  - **Encoder:** it runs at the lower of v2's rate and the slowest v3
    viewer's budget.
  - **Recovery:** it is IDR, at most one per 250 ms. VideoToolbox can't
    invalidate a reference, and LTR is untested.
  - **Simulated end to end on a 20 Mbit/s link:** every decoded frame was byte
    for byte at 0, 2 and 10% loss. The rate climbed to 15–16 Mbit/s at 0–2%
    loss and held 6.4 Mbit/s at 10%. A 300 ms outage recovered with one key
    frame.
  - **Credentials:** only per-device credentials get a v3 key. The shared
    token has no device ID for the host to look up.
  - **Not yet:** the `ns=3` TXT record and a clean device-test pass.
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
6. **Ready for PCVR and 3D from the start.** The same transport carries a
   stereo PCVR stream (head pose up, frames with their render pose down) and a
   depth stream beside a flat game's video. Neither gets a protocol of its own.

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
- The PCVR OpenXR side. v3 defines the PCVR stream on the wire (§4.7), and
  the public Windows host encodes and sends it. The OpenXR compositor that
  renders the eye images and hands them over (§7.2, external frame source)
  is private, as is its plan (`Longwave-PCVR-Host/docs/NATIVE_PROVIDER_PLAN.md`).
  CloudXR stays the shipping PCVR path until the v3 path passes that plan's gates.
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
  *Corrected 2026-10-24:* AES-256-GCM rekeys every **2^23** packets, its
  confidentiality limit in RFC 9001 §6.6. At about 10,000 packets/s (PCVR at
  ~100 Mbit/s) that is every 14 minutes. ChaCha20-Poly1305 keeps 2^32. Both
  also rekey hourly. Details in "Handshake and record encoding" below.
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
  *Built 2026-10-24* (`PathMTUSearch`, driven by `TransportSession`):
  - **Probes and ceiling.** Each side probes its own send direction. A probe
    is a PING padded to the candidate size, and its PONG is the
    acknowledgement. The ceiling is the hello-ack's `maxUDPPayload`, set with
    `setPathCeiling`.
  - **Search.** It tries the ceiling first, then bisects to within 16 bytes.
    Each size gets RFC 8899's three probes, 1 s apart. On the LAN that settles
    in one round trip; on a 1252-byte Tailscale path it takes about 9 s, while
    media runs at 1200 meanwhile.
  - **Black holes and growth.** The confirmed size is re-probed every 10 s.
    Three losses in a row mean a black hole: media drops back to 1200 and the
    search restarts. A search that stopped under the ceiling looks upward
    again after 10 minutes (PMTU_RAISE_TIMER).
  - **Roaming.** The host restarts its search when a confirmed client roams.
  - **What uses the probed size.** Only media (`sealVideo`/`sealAudio`, and
    shards sized from `udpPayload`). Reliable data, ACKs and FEEDBACK always
    use 1200 bytes, so a black hole can't stall control. Media seals up to the
    ceiling, so a frame sharded just before a black hole is found still goes
    out, though it may not arrive.
  - **Lost probes aren't congestion.** They are marked in the sent log, and
    the rate controller doesn't count them as loss.
- **Encryption is always on.** Sunshine leaves media unencrypted on LAN by
  default and moonlight-qt opts in only with CPU AES acceleration [M1][M3];
  every host and client here has AES hardware, and the Companion's token-gated
  model has always meant encrypted, so v3 doesn't offer a plaintext mode.
- **QoS marking.** Media and input marked for WMM video/voice: on Apple via
  `NWParameters.serviceClass` (`.interactiveVideo` already used by v2),
  Linux via `IP_TOS`/`SO_PRIORITY`, Windows via qWAVE (`QOSAddSocketToFlow`),
  since Windows ignores `IP_TOS` set directly by applications.

### Handshake and record encoding (2026-10-24)

Fixed when `StreamCrypto` was built. The code is the reference, together with
the golden bytes in `StreamCryptoTests/SecureSessionTests.swift`. Those come
from `StreamCryptoTests/Reference/ns3_reference.py`, an independent
implementation on pyca/cryptography that first checks itself against the
published NNpsk0 vector. The Noise layer passes all five published NN-family
vectors (cacophony and snow).

- **Packet kinds.** The low four bits of byte 0 give the kind: 1 is the
  initiation, 2 the response, 3 a transport packet. Bit 4 is the key phase,
  set only on transport packets. Bits 5 to 7 are reserved and must be zero.
  Anything else is dropped without a reply.
- **Initiation:** `0x01 | major u8 (3) | key ID [8] | e [32] | sealed(sender
  index u32 | cipher offer u8 | hello)`. This is Noise message 1. The
  protocol major is byte 1, which corrects §4.6's "first byte". The cipher
  offer is a bitmask: bit 0 is AES-256-GCM, bit 1 ChaCha20-Poly1305.
- **Response:** `0x02 | receiver index u32 | e [32] | sealed(sender index u32 |
  cipher u8 | hello-ack)`. This is Noise message 2.
- **Prologue:** `"Longwave-NS3"` followed by the initiation's first 10 bytes.
  The major and key ID travel in the clear but are still authenticated.
- **Connection IDs.** Each side picks its own random index and states it inside
  its sealed part, so a forged ID can't redirect the session. Transport packets
  carry the receiver's index.
- **Size.** Both handshake packets fit 1200 bytes. That leaves 1137 bytes for
  the hello and 1142 for the hello-ack.
- **Record keys.** Generation 0 of each direction is `HKDF-SHA256(split key,
  info: "Longwave-NS3 record " + cipher name)`. The cipher names are
  `AES-256-GCM` and `ChaCha20-Poly1305`, so a key is bound to its cipher.
  Generation n+1 is `HKDF-SHA256(key n, info: "Longwave-NS3 rekey")`.
- **Nonce.** 32 zero bits, then the packet number, little-endian, for both
  ciphers. Noise itself writes AES-GCM nonces big-endian, but records aren't
  Noise transport messages. The AAD is the 13-byte header.
- **Rekeying.** Each direction rekeys on its own: after `packetsPerKey` packets
  (2^23 for AES-GCM, 2^32 for ChaCha20-Poly1305) or one hour. The sender flips
  the key phase bit. The receiver keeps the previous key for packets reordered
  across the switch, and drops it once the replay window has moved past the
  switch point.
- **Limits.** A receiver counts forgeries, one per packet however many keys it
  was tried with. At RFC 9001's integrity limit (2^52 for AES-GCM, 2^36 for
  ChaCha20-Poly1305) the session ends.
- **Retries and replays.** A client that gets no response sends a new
  initiation with a fresh ephemeral key; it never resends the old one. The host
  remembers recent initiations by their ephemeral key
  (`InitiationReplayFilter`, 2 minutes). For an exact repeat it resends its
  cached response and builds no second session. A session made from an
  initiation runs alongside any existing session for that device. It replaces
  the old one only when its first transport packet authenticates, which only
  the real client can send. So a replayed initiation can't end a live session.

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
      ├─ VIDEO     one video shard (§4.2)
      ├─ AUDIO     one audio shard (§4.4)
      ├─ STATE     unreliable latest-wins snapshot (pointer position, gamepad, head pose)
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

**Encoding rules** (fixed when `StreamWire` was built, 2026-10-12; the code and
its golden byte vectors in `StreamWireTests` are the reference):

- **Byte order and numbers.** Every multi-byte field is little-endian. The one
  exception is inside an access unit, where NAL length prefixes stay
  big-endian as AVCC/HVCC define them. Floats are IEEE 754 binary32, and NaN or
  infinity are rejected wherever a value must be finite.
- **`varint`** is unsigned LEB128, at most 3 bytes (0…2,097,151), and must be
  minimal. A non-canonical varint is rejected, so every value has exactly one
  encoding.
- **Frame types:** PADDING 0x00, CTRL 0x01, ACK 0x02, VIDEO 0x03, AUDIO 0x04,
  STATE 0x05, FEEDBACK 0x06, PING 0x07, PONG 0x08, NACK 0x09 (added 2026-10-24).
  The design's single MEDIA
  type is split in two, so the frame type says which shard header follows.
  PADDING is the one frame without a length: a single 0x00 byte. A run of zero
  bytes is then valid padding of exactly its size, which is what a PMTU probe
  needs (QUIC's rule).
- **Malformed datagrams are dropped whole.** That covers a truncated frame, a
  bad varint, or a second media frame. Such a datagram passed AEAD, so the peer
  has a bug and nothing in it can be trusted.
- **Strict fixed fields, open extension points.** Reserved bits and unknown
  values in fixed fields are rejected. New flag bits arrive with a capability,
  so a receiver never sees bits it doesn't know. Extension happens only in the
  open places: unknown frame types, message types, side data types,
  `formatDescription` extensions and STATE kinds are skipped. A known TLV value
  longer than its defined size is accepted, and the extra bytes (fields a
  later revision appended) are ignored.
- **Reliable-channel messages** have the same shape as frames: `type u8 |
  length varint | body`, with the body ≤ 1 MiB (bigger payloads are chunked on
  channel 2). One type namespace covers all three channels: control
  0x20–0x3F (`formatDescription` = 0x20), input events 0x40–0x5F, host input
  feedback 0x60–0x6F. An unknown message type is skipped. A bad length ends
  the session, because a byte stream can't resynchronise after one.

**Transport frame bodies** (fixed 2026-10-24 with `StreamTransport`; reference:
`StreamWire/TransportFrames.swift` and the golden vectors in
`TransportFrameTests`). They are fixed structures, decoded strictly, with no
trailing bytes. New fields come as new frame types.

- **CTRL:** `channel u8 | offset u64 | data`. Each channel is one byte stream
  from offset 0 (control 0, input 1, bulk 2), carrying the reliable messages
  above. A resend repeats the same bytes at the same offset. Data is at least
  one byte.
- **ACK:** `channel u8 | ackDelay varint µs | cumulative u64 | count u8 |
  count × (gap varint, length varint)`. `cumulative` is the next offset the
  receiver needs. The ranges are the bytes held above it, ascending, each
  starting `gap` (≥ 1) after the previous end, so they never touch and the
  encoding is unique. At most 32 ranges. One ACK frame per channel.
  Acknowledging by stream offset, not by packet number, keeps retransmission
  independent of which datagram carried the bytes.
- **PING:** `id u32 | sendTime u64`. **PONG:** `id u32 | pingSendTime u64 |
  receiveTime u64 | sendTime u64`. Each time is in its sender's own monotonic
  ns, which together with the PONG's arrival gives the four NTP timestamps
  of §5. Either side may ping.
- **FEEDBACK:** `reportSequence u16 | basePacketNumber u64 | referenceTime u64
  µs | runCount varint | runs | arrival deltas | streamCount u8 | stream
  status`.
  - **Runs** cover consecutive packet numbers. Each run is `length << 3 |
    received << 2 | ECN`, with neighbouring runs different.
  - **Arrival deltas:** one zigzag varint per received packet, in µs of the
    receiver's clock, in packet-number order. They're signed, because Wi-Fi
    reorders. A delta must fit ±1.05 s, so a report spanning a longer silence
    is split.
  - **Size:** at most 65,536 packets per report, which bounds what a decoder
    allocates, since lost runs cost no bytes.
  - **Stream status:** `streamID u32 | lastDecodableFrame u32 | framesLost
    u32 | lateness p50/p95/p99 varint µs`.
- **NACK:** `streamID u32 | frameNumber u32 | scope u8`, then nothing for a
  whole frame (scope 0), `block u8` for a whole block (scope 1), or `block u8 |
  needed u8 | count u8 | data shard indices ascending` (scope 2). This is the
  assembler's `MissingShards`, one frame or block per NACK, gated on the
  `nack` capability.
- **Coalescing with media** (open question 20, decided): small frames ride
  only in non-media datagrams. Media shards keep the full shard size. ACKs,
  FEEDBACK, PINGs and control data go together in their own datagrams, which on
  a LAN costs nothing that matters.

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

*Layout (2026-10-12).* The message is a 22-byte core, then the configuration
blob, then extension blocks:

- **Core:** streamID u32, firstFrameNumber u32, codec u8 (HEVC 1, H.264 2,
  AV1 3), formatKind u8, width u16, height u16, bitDepth u8, chromaFormat u8,
  primaries u8, transfer u8, matrix u8, fullRange u8, then configLength u16
  and the configuration.
  - formatKind keeps v2's values: 0 is the CoreMedia ImageDescription, and 1
    is Annex-B parameter sets, now for HEVC or H.264. 2 is new: an AV1
    sequence header.
  - Width and height are the displayed (cropped) picture size.
  - Colour is three ITU-T H.273 code points plus the range flag. VideoToolbox,
    NVENC, AMF and VAAPI all map those directly.
- **Extension blocks** are `type u8 | length u16 | body`. Each type appears at
  most once, and unknown types are skipped. Types:
  1. mastering display: ST 2086, in the HEVC SEI's order and units;
  2. content light level;
  3. side data types: the declared types, strictly ascending;
  4. auxiliary: role and primaryStreamID;
  5. PCVR layout (§4.7);
  6. depth encoding (§4.8).

A receiver keeps the current format and the one before it for each stream. It
decodes a frame against the newest format whose first frame is not after the
frame's number. A new format must start at a newer frame number than the
format it replaces.

**Shard header** (inside the sealed VIDEO frame, 24 bytes):

| field | size | notes |
|---|---|---|
| streamID | 4 | |
| frameNumber | 4 | per stream, wraps |
| captureTime | 8 | host monotonic ns (§5), same for all shards of a frame |
| flags | 1 | key 0x01, recovery 0x02 (first frame after invalidation), LTR-marked 0x04, last-block 0x08, discardable 0x10 (not a reference); bits 5–7 reserved |
| block | 1 | FEC block index within the frame |
| blockCount | 1 | ≥ 1 |
| shardIndex | 1 | index in the block, data shards first |
| dataShards | 1 | k ≥ 1 |
| parityShards | 1 | m, with k + m ≤ 255 |
| referenceDistance | 2 | frameNumber minus the frame this one predicts from; 0 = intra |

`referenceDistance` is what lets the receiver tell, *before* decoding, whether a frame is
decodable given what it has — the receiver knows exactly which frames are
damaged and asks for invalidation of exactly those (§6.3).

*Changed 2026-10-12:* the design first had `refFrame`, the low 16 bits of the
reference, with 0xFFFF for intra. That sentinel collides with a real frame
number every 65,536 frames, so the field is a distance instead. It wraps
cleanly and is unambiguous. A reference more than 65,535 frames back needs an
IDR or a fresh LTR. Consistency rules the decoder enforces:

- last-block is set exactly when `block == blockCount − 1`, which duplicates
  information the other fields already give;
- a key frame has distance 0;
- discardable and LTR-marked never appear together.

One field means one reference. The check is only exact if encoders run with a
single reference frame (NVENC `numRefL0 = 1`, or LTR-only prediction). With
NVENC's default of several references, the receiver's decodability check is
optimistic.

**Packetization.** The bytes split into shards are the **frame payload**:

```
contentLength u32 | sideDataLength u16 | side data items | access unit | zero padding
```

The access unit is length-prefixed NAL units as in v2, or AV1 OBUs.
`contentLength` counts everything after itself up to the padding.

- **Why the length is in the payload.** The shard header has no room for an
  extension, and a data shard rebuilt from parity must carry the true length
  too. Only the payload is FEC-protected.
- **The side data section is always present**, with length 0 when a frame has
  none. Parsing then never depends on the format message, and a frame without
  side data costs 6 bytes.
- **Shard size.** All data shards are the same size: the UDP payload minus
  56 bytes. That is the outer header (13), the AEAD tag (16), the frame type
  and length (3) and the shard header (24). It comes to 1144 bytes at the
  default 1200 and 1396 at 1452 (`DatagramLayout`). The design's
  "payload − 24" left out the other 32 bytes.
- **Blocks.** Frames bigger than one block are split into several blocks of
  ≤ 255 total shards each.

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

*Measured from what, decided 2026-10-24:* the window runs from the arrival of a
shard **sent after** the gap, never from the frame's first shard. Shards leave
in order (frame, block, index), and a paced frame takes several ms to leave
the host, 12 ms for 40 KB at 4 MB/s. So counting from the first shard NACKed
shards that hadn't been sent yet. In the simulator that resent 6,236 shards
at 2% loss instead of 131. A frame that has been quiet for three reorder windows
(6 ms) counts as fully sent, so loss at its tail is reported without waiting
for the next frame.

**Frame side data.** Some streams need per-frame facts that the receiver must
apply to exactly that picture: the pose a PCVR frame was rendered from, or a
depth frame's near and far planes. They travel **inside the frame payload**, as
a small TLV record (`type u8 | length u16 | value`) ahead of the first NAL
unit, when the stream's `formatDescription` declares `sideData` with the types
it uses. Putting them in the payload, not a separate message, means FEC and
NACK protect them, they can't be paired with the wrong frame, and the 24-byte
shard header stays the same for every stream. Unknown types are skipped by
length. Types: `renderPose` and `foveation` (§4.7), `depthRange` (§4.8), with
more added append-only.

*Encoding (2026-10-12).* Items sit in the payload's side data section above,
so a parser never has to guess where TLVs end and NAL units begin. The design
left that boundary open. Type numbers: renderPose 1 (102 bytes), foveation 2
(20 bytes), depthRange 3 (13 bytes). Each known type appears at most once per
frame. The format's declared types bound what a frame may carry:

- an item whose type isn't declared is an error;
- a PCVR frame must carry renderPose, plus foveation with the current epoch
  when the stream is warped;
- a depth frame must carry depthRange.

**Auxiliary streams.** A stream can be an auxiliary of another: its
`formatDescription` names a `primaryStreamID` and a `role` (`alpha`, `depth`).
An auxiliary frame uses the same `frameNumber` and `captureTime` as the primary
frame it belongs to, so the receiver pairs them by number, with no extra field.
It gets its own FEC blocks, NACKs and recovery, and the rate controller budgets
it as a share of its primary. A receiver that doesn't announce the role's
capability never subscribes to it. If an auxiliary frame is missing, the receiver
shows the primary frame with the last good auxiliary, and treats a primary
frame without one as normal. Alpha (`alphaVideo`) and depth (`depthVideo`, §4.8)
are the first two roles.

*Rules (2026-10-12)*, enforced by `StreamFormatTable`:

- **Roles.** Role numbers: alpha 1, depth 2.
- **Announcement order.** The primary's format must arrive before its
  auxiliary's.
- **No chains.** An auxiliary's primary can't itself be an auxiliary.
- **One per role.** A primary has at most one auxiliary per role.
- **Fixed roles.** A stream keeps its role and primary for its lifetime.
- **Removal.** Ending a primary ends its auxiliaries.
- **One auxiliary frame for every primary frame** while the auxiliary is
  subscribed. When there is nothing to send (a cutscene with no depth), the
  auxiliary frame has an empty access unit and only side data, so it costs a
  shard or two. A gap in an auxiliary's frame numbers then always means loss,
  and the receiver can NACK it. Without this rule, a missing auxiliary frame
  could mean "lost" or "never sent", and the NACK logic couldn't tell which.
- **Stream IDs** are window IDs on the primary side, so an auxiliary needs an
  ID no window will ever have. That is open: the host must allocate auxiliary
  IDs from a range it never hands to windows. Decoupling stream IDs from
  window IDs altogether would be cleaner.

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
  snapshot costs at most one interval. With `pcvr`, a **head pose** snapshot is
  sent at the display rate instead, with no idle interval (§4.7).
- **Every input carries the client's estimate of host time** when it was
  generated (§5), so the host can log input latency and order input against the
  frame the user was looking at.
- **Host → client:** rumble (two motors, plus trigger rumble), LED/light-bar,
  adaptive-trigger hints, cursor shape/visibility (so the client can draw the
  cursor locally when the stream doesn't), and the v2 `mouseStatus`/
  `keyboardStatus` capability states.

*Encoding (2026-10-12; field tables in `InputEvents.swift` and
`StateSnapshots.swift`):*

- **Event message types:** keyDown 0x40, keyUp 0x41, mouseDown 0x42,
  mouseUp 0x43, scroll 0x44, textInput 0x45, focusWindow 0x46,
  gamepadConnected 0x47, gamepadDisconnected 0x48, releaseAll 0x49.
- **Event bodies** start with `hostTime u64`.
  - Keys carry `keyCode u16` and `modifiers u32`: v2's bits, plus `function`
    as bit 5.
  - Mouse buttons carry streamID and position as well as the button (left,
    right, middle, back, forward). A click then lands where it was made even
    if the pointer STATE before it was lost.
  - Scroll carries line deltas (i16) and precise deltas (i32, 1/120 notch).
  - Text is 1–4096 bytes of valid UTF-8.
  - Gamepads are indexed 0–15.
- **Host → client message types:** rumble 0x60, lightBar 0x61,
  triggerEffect 0x62 (up to 32 effect bytes in DualSense format), cursor 0x63,
  controlStatus 0x64. Rumble carries a duration, and the client stops when it
  runs out unless the host sends again, so a lost session can't leave a pad
  buzzing.
- **STATE frame header** (14 bytes): `kind u8 | source u8 | sequence u32 |
  hostTime u64`. Latest wins per (kind, source), compared as RFC 1982 serial
  numbers. Kinds: pointerAbsolute 1, pointerRelative 2, gamepad 3, headPose 4.
  Unknown kinds are skipped. `source` is the gamepad index for pads and 0 for
  every other kind.
- **Relative pointer** is sent as running totals since the session started,
  in 1/256 pixel, wrapping. The host applies the difference from the last
  total it saw. "Accumulated since the last ack" needed an ack and per-ack
  state; a running total survives any loss with neither.
- **Gamepad snapshot:**
  - buttons u32, named by position (south, east, west, north, then
    shoulders, sticks, menu, view, home, d-pad, share, touchpad click and
    four paddles);
  - four i16 stick axes with +Y up, and two u16 triggers;
  - a sections byte, followed by optional motion (gyro rad/s and accel in g,
    f32) and an optional two-contact touchpad.

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

*Header details (2026-10-12):*

- **`channelID`:** 0 is the bed; 1–65535 are spatial object IDs.
- **`flags`:** bits 0–2 are `fecIndex`, bit 3 is `discontinuity` (the host
  restarted or dropped on purpose, so a jump in `firstSample` isn't loss), and
  bit 4 is `inBandFEC` (the Opus packet carries LBRR). Bits 5–7 are reserved.
- **`codec`:** Opus 1, PCM24 2. Codecs are negotiated, so an unknown codec
  is an error rather than something to skip.
- **`frameSamples`:** 1–5760 (120 ms at 48 kHz).
- **FEC group shape** is fixed in v3.0 at 4 data plus 2 parity. `fecIndex`
  0–3 marks data and 4–5 parity, and a parity packet's `firstSample` is that
  of its group's first data packet.
- **Open, for StreamFEC:** RS needs equal-size shards, and a rebuilt data
  packet needs its header fields and true length. So the FEC must cover each
  data packet's header and a u16 length along with the payload, zero-padded
  to the group's longest. The 16-byte header has no field that would make
  that implicit.

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
object metadata to a capturing process. *Measured since (§9 risk 7):* no driver
is needed. A component loaded into the game wraps its `ISpatialAudioClient`
and receives the bed (and any objects) before Windows renders them; Cyberpunk
2077 sends a 7.1.4 bed and no objects. Loading that component is only safe in
games without anti-cheat, so it happens only when the user starts the game
through Longwave (§7.6); every other game gets WASAPI process loopback, at most
7.1. The protocol slot costs nothing until a host announces the capability; the
Moonlight-side `MoonlightSoundStage` work already proves the client can place
channel beds as virtual speakers.

### 4.5 Control, clipboard, inventory

Reliable channel 0, binary-framed messages with a type byte. The v2 JSON bodies
(`WindowInventory`, `DisplayList`, `VirtualDisplayChange`) stay JSON inside the
message: they are small, rare and already have Codable models on both ends —
swift-foundation's `JSONEncoder` exists on Linux and Windows. Hot-path messages
(input, feedback, shard headers) are fixed binary.

*Type numbers (2026-10-24, `StreamWire/Messages.swift`):* `formatDescription`
0x20; `recoveryRequest` 0x21 (`streamID u32 | firstLostFrame u32`, client to
host, the first damaged frame of §6.3); `bye` 0x22 (a UTF-8 reason, possibly
empty); the JSON bodies `displayList` 0x23, `selectDisplay` 0x24 (the display
id as UTF-8), `virtualDisplayChange` 0x25 and `windowInventory` 0x26. A
`formatDescription` applies from its `firstFrameNumber`. Each viewer's frames
are numbered from its own first key frame, so a client holds frames that
arrive before their format and applies the format at that number.

New in v3: `clipboard` (text, UTF-8, and PNG images up to 8 MB on bulk channel
2, chunked like VVAS artwork), `streamConfig` (client asks for resolution/FPS
caps, HDR on/off, codec preference per stream), `stats` (§6, for the
diagnostics overlay), and `bye` with a reason.

### 4.6 Versioning, capability negotiation, v2 compatibility

- The handshake's protocol major (3) is the initiation's second byte (section 3,
  "Handshake and record encoding"). Within v3, features are
  **capabilities**: the client lists what it supports, the host answers with the
  intersection. Initial set: `windowStreams`, `alphaVideo`, `hevc422`,
  `hevc10bitHDR`, `av1`, `h264`, `ltrRecovery`, `rfiRecovery`, `nack`,
  `audioOpus`, `audioPCM24`, `audioMultichannel`, `spatialObjects`, `gamepad`,
  `relativePointer`, `clipboard`, `virtualDisplay`, `localCursor`,
  `sideData`, `depthVideo`, `pcvr`, `gaze`.
  Unknown capabilities are ignored, never fatal.
  *Encoding (2026-10-12):*
  - **Bit numbers** follow the list order: `windowStreams` = 0 through
    `gaze` = 21, append-only.
  - **Wire form:** `byteCount u8 | bitmap`, where bit n of byte n/8 is
    capability n, up to 256 capabilities. Senders write the shortest bitmap.
    Receivers accept trailing zero bytes and unknown bits.
  - **Negotiation** takes the intersection, restricted to capabilities the
    build knows. It then drops any capability whose requirements didn't
    survive: `depthVideo` and `pcvr` need `sideData`, and `gaze` needs
    `pcvr`.
- **Hello and hello-ack (2026-10-24)** (`StreamWire/Hello.swift`). These are
  the handshake payloads: v2's JSON `Hello` and `HelloAck`, now binary. Each has
  a fixed core followed by items (`type u8 | length u16 | value`, as in side
  data), so a later field is a new item that an older peer skips. Little-endian,
  like the rest of the wire.
  - **Hello**, in Noise message 1:
    `minor u8 (0) | capabilities | platform u8 | maxUDPPayload u16 | intent u8`.
    Items: 1 = device name, 2 = software version.
  - **Hello-ack**, in Noise message 2:
    `minor u8 | capabilities (negotiated) | platform u8 | keyCodeSpace u8 | grants u16 | maxUDPPayload u16`.
    Items: 1 = host name, 2 = software version.
  - **Field values:**
    - `platform`: 0 unspecified, 1 visionOS, 2 iOS, 3 macOS, 4 watchOS,
      5 Windows, 6 Linux, 7 Android. Open-ended: unknown values decode.
    - `intent`: bit 0 screen (v2's `wantsScreen`), bit 1 audio, bit 2
      stills only (v2's `stillsOnly`).
    - `keyCodeSpace`: 0 macOS virtual key codes, 1 HID usages. Any other value
      is invalid.
    - `grants`: bit n is `CompanionGrant` case n (screen, audio, input,
      projects, sshKey).
    - Names and versions: valid UTF-8, 1–64 and 1–32 bytes.
  - **Rules:**
    - Unknown intent and grant bits are kept. The minor version is
      informational; capabilities gate behaviour.
    - The ack's `maxUDPPayload` is the smaller of the two sides' values, and is
      the ceiling DPLPMTUD probes towards.
    - The client re-negotiates against what it offered, so a host can't switch
      on a capability the client never listed.
    - A host that won't serve a paired device still answers, with no grants
      (`refused`), so the client can say why instead of timing out.
    - v2's `decodesHEVC422` is the `hevc422` capability, and `acksFrames` is
      replaced by FEEDBACK. `identity` isn't needed, because the per-device PSK
      already proves which device is connecting.
  - **Size:** the largest possible hello is under 200 bytes, against the
    1,137 the initiation allows. It is sealed under the PSK but, like all of
    Noise message 1, has no forward secrecy, so it carries nothing more
    sensitive than the device name.
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

### 4.7 PCVR profile

A PCVR session is a v3 session whose client announces `pcvr` and the host
accepts it. Everything below is ordinary v3 (transport, FEC, NACK, recovery,
rate control, audio). The profile only adds what VR needs on top. It is defined
here, in public, because the visionOS receiver that implements it is MIT like
the rest of the app. The host side is in the private PCVR docs.

**Why now, before the provider entitlement.** visionOS 27's foveated-streaming
provider extension gives a provider two things nothing else does: the wearer's
**gaze** (`latestFocusRegion`), and the system's session plumbing (QR pairing
with a remembered certificate, connection states, input grants, decode memory
charged to the host app). Neither is needed to move VR frames. A normal app
`ImmersiveSpace` with a CompositorServices layer gets predicted head poses from
ARKit, per-eye Metal drawables and the system compositor's late reprojection,
with no special entitlement (ALVR's visionOS client works this way). So the
profile is built and stress-tested now, with foveation fixed at the view centre
(what PCVR does today), and gaze is a field that starts carrying data when the
entitlement arrives.

**Uplink: head pose (STATE).** At the display rate: sequence number, the
display time it was predicted for (host clock, §5), the head pose in the
immersive space plus the space epoch (bumped on recentre), per-eye offsets
when IPD changes, the `frameNumber` and present time of the last frame shown
(motion-to-photon, measured on every frame), and a gaze sample (direction,
distance, timestamp, valid flag) that stays invalid unless `gaze` was
negotiated. Hands and controllers keep their existing paths for now.

*Encoding (2026-10-12).*

- **Conventions** are OpenXR's, which the host's frame source speaks and
  which agree with ARKit: metres, right-handed, +Y up, −Z forward.
  - A pose is the orientation quaternion (x, y, z, w) followed by the position
    (x, y, z), `XrPosef`'s field order.
  - A field of view is four signed angles in radians (left, right, up, down),
    `XrFovf`.
  - Everything is binary32 with no quantisation, which costs ~16 KB/s of
    uplink at 90 Hz.
  - Quaternions must be unit length within 1%, and FOV angles must lie inside
    ±π/2 with left < right and down < up.
- **The head-pose snapshot** is 164 bytes after the STATE header:
  - displayTime u64, spaceEpoch u16, flags u16 (bit 0 gaze valid, bit 1
    presented frame valid);
  - the head pose;
  - for each eye, its pose relative to the head plus its field of view;
  - presented frameNumber u32 and present time u64;
  - gaze direction (unit vector in head space), distance f32 (0 when
    unknown), and sample time u64.
- **Fields whose flag is clear must be all zero.** No stale gaze leaks, and
  every value has one encoding.
- **Deviation:** eye offsets and fields of view ride in *every* snapshot, not
  only when IPD changes. A STATE frame can be lost, and a change sent only
  once would then never arrive. The host also needs the headset's per-eye
  projection to render at all, which the design didn't carry.

**Video.** One stream, both eyes side by side, HEVC Main10, 90–120 fps. Its
`formatDescription` gives the layout, the per-eye render and wire sizes, and
the foveation warp's parameter block. Side data on every frame:

- `renderPose`: the pose sequence number it was rendered from, each eye's
  render pose and field of view, and the display time it was rendered for.
  The receiver needs this for reprojection: it shows the frame where it was
  rendered, not where the head is now.
- `foveation`: the warp centre per eye, and a parameter-block epoch. The
  receiver's unwarp must use exactly the parameters the encoder used, and
  logs a mismatch rather than drawing a slightly wrong image.

*Encoding (2026-10-12):*

- **PCVR format block:**
  - layout u8 (side by side = 1: left eye in the left half, no gap, so the
    picture width is exactly twice the per-eye wire width);
  - per-eye render size and wire size (u16 × 4);
  - foveation epoch u32;
  - warp kind u8 and the warp's parameters.
- **Warp kinds.** Kind 0 is none, where render size must equal wire size.
  Kind 1 is an axis-aligned centre-plus-edges warp, the shape ALVR's foveated
  encoding uses. Its parameters are four f32: centre size x and y (the
  fraction of each axis kept at full density, in (0, 1]) and edge ratio x and
  y (≥ 1). An unknown warp kind makes the format undecodable, because the
  receiver couldn't invert the warp.
- **`renderPose`** (102 bytes): poseSequence u32, spaceEpoch u16 (so a
  recentre between pose and render can't misproject), displayTime u64, then
  each eye's pose and field of view in the immersive space.
- **`foveation`** (20 bytes): parameterEpoch u32, then each eye's warp centre
  as a normalised (x, y) in [0, 1], with (0, 0) at the top left.

**Receiver.** Decode is the existing VideoToolbox path. Unwarp and
reprojection are Metal that produces a texture for each eye, presented by a
thin layer: CompositorServices in the app now, and whatever the provider
extension's `immersiveScene` allows later (a RealityKit `LowLevelTexture` if
CompositorServices isn't available there). Keeping the presenter thin is what
makes the extension a second shell around the same receiver instead of a
rewrite.

**Host.** The public Windows host (§7) serves PCVR like any other stream. The
eye images come from an external frame source (§7.2): a private OpenXR
compositor hands each composited frame over as shared GPU textures, and gets
head poses, gaze and pacing back through a shared section. The foveation warp,
the encoder, the transport and audio are all in the public host. The warp is
half of a matched pair with the headset's unwarp, so both halves sit in public
code and share one parameter block and one set of tests.

**Pacing.** The client reports its display refresh in the handshake and on
every change. In game-mode playout (§5) a frame that misses its display slot is
dropped, never queued: in VR a late frame is worse than a repeated one, which
the compositor's reprojection covers.

**What the entitlement adds later.** The gaze sample becomes valid, the warp
centre follows it, and the system's QR pairing can replace v3's own enrollment
for provider sessions. The wire format doesn't change.

### 4.8 Depth for flat games (3D on the headset)

A flat game becomes 3D on the headset when the host sends its depth buffer
beside the picture and the headset does the stereo work. Reading the game's
depth is more accurate and much cheaper than estimating it (the
Depth Anything route used for movies), and unlike rendering each eye in turn
(R.E.A.L.-style mods) the PC renders the game once. The result is a 3D screen,
not VR.

- **Source.** An in-game component, loaded only when the game is started
  through Longwave (§7.6), reads the depth buffer at present time and hands
  the host the frame and its depth as shared GPU textures stamped with one
  frame number, through the external frame source contract (§7.2). It is built on ReShade's add-on API (BSD-3): that covers
  D3D9–12, OpenGL and Vulkan and already solves picking the right depth buffer.
  Some tuning per game is expected (reversed Z, near/far), kept as profiles
  in the game library. Games not started through Longwave are captured as
  usual, with no depth.
- **Wire.** An auxiliary stream (§4.2) with `role = depth`, `depthVideo`
  capability. The host converts depth to inverse depth (stereo disparity is
  proportional to it, so precision lands where it is visible), quantises it
  to 10 bits, and encodes it as luma in HEVC Main10 at half or quarter the
  picture's resolution (NVENC has no 4:0:0, so chroma is flat and costs almost
  nothing). Each depth frame carries `depthRange` side data: near, far and the
  profile's suggested convergence. The headset therefore needs no per-game
  knowledge.
  *Encoding (2026-10-12):*
  - **Depth format block:** encoding kind u8 and value bits u8 (at most the
    stream's bit depth).
  - **Kind 1, inverse linear:** `v = round((1/z − 1/far) / (1/near − 1/far) ×
    (2^bits − 1))`, in full-range luma. Near maps to the maximum value and far
    to 0, so an infinite far plane, common with reversed Z, works.
  - **`depthRange`** (13 bytes): flags u8 (bit 0 = empty), then near, far and
    convergence as f32 metres. The constraints are 0 < near < far, far may be
    +∞, and convergence 0 means no suggestion. An empty frame has all three
    at zero.
- **Headset.** First choice: a grid mesh in RealityKit, displaced by the depth
  map and textured with the frame, so RealityKit renders each eye itself and
  the user gets correct stereo plus parallax as the head moves. Gaps behind
  objects become stretched triangles, which can be softened. Cheaper
  alternative: a Vergence warp into a side-by-side texture on the existing
  stereo player. With no depth stream (cutscenes, games with anti-cheat, the
  Mac desktop), Depth Anything on the headset's Neural Engine is the fallback.
- **Pre-rendered cutscenes** have no depth buffer (the component sees a
  cleared or constant one). It marks those frames empty in `depthRange`, and
  the headset switches to estimated depth until real depth returns, rather
  than showing a flat plane.
- **Reference rig.** ReShade with SuperDepth3D is installed in Cyberpunk 2077
  on the test PC as a quality reference. SuperDepth3D's licence forbids
  redistribution, so nothing of it ships.

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

#### Implementation (2026-10-24)

`GCCRateController` (`StreamTransport/RateController.swift`, behind the
`SendRateController` protocol) takes each report's `SentPacketLog` results and
gives a `SendBudget`: the total in bytes/s, the FEC ratio, `pacingRate`
(1.5×), and `mediaRate(audio:)`. The last is the encoder's bitstream rate once
audio, parity and each shard's datagram overhead are taken out. The
delay-based parts (`DelayBasedEstimator.swift`) follow libwebrtc's current
code and constants:
- 5 ms send groups, with its burst rule.
- A trendline over 20 groups, scaled by 4 × the delta count (capped at 60).
- An adaptive threshold starting at 12.5 ms, clamped to 6–600.
- AIMD: grow 8 %/s far from the last overuse rate and about a packet per
  RTT + 100 ms near it, cut to 0.85 × the 250 ms receive rate, and never grow
  past 1.5 × what gets through.

The simulator found four places where GCC alone falls short, and each now has
an addition:
- **Wi-Fi stalls.** A stall holds packets and releases them together, which
  GCC reads as a 100 ms jump in delay and then a draining queue, and it cuts
  the rate. With stalls every 2–4 s that held the rate at 42% of the link.
  `StallFilter` now drops the pair of deltas a held-and-released burst
  produces: a jump in one group that no queue could build without sending at
  7× the link, followed by a released burst. A jump with no release after it is
  a real collapse and goes through.
- **Slow overshoot.** Near the link, additive growth overshoots by 1–2 %. That
  slope sits below the threshold floor, so the queue grew by 8 ms every 500 ms
  without limit. The relearned baseline is now `QueueDelayEstimator`: the
  lowest one-way delay over the last 10 s, in 1 s buckets. A smoothed queue
  above `queueDelayCeiling` (20 ms) counts as overuse.
- **Slow drain.** When the link halved, the 0.85 × cut drained the 140 ms
  queue built during detection at about 0.13 MB/s, which took 2 s. A *drain
  allowance* now holds the budget under the estimate in proportion to the
  queue above half the ceiling, aiming to clear it in 250 ms, and shrinks as
  the queue empties. The estimate itself isn't cut further, because GCC
  regrows only additively near the link.
- **Probe self-overuse.** A probe at 2–3× the link builds its own 16–38 ms
  queue. GCC then cut on a 250 ms receive rate that still covered the slow
  start, and fell back to 1.3 MB/s. Overuse in the 250 ms after a probe is now
  ignored unless the queue is past twice the ceiling.

Loss and probing:
- **Loss:** measured over 100 ms windows, with a late arrival taking its
  reported loss back (`SentPacketLog.Entry.reportedLost`). It sets the FEC
  ratio, 2 × loss + 5%, clamped to 5–50%.
- **Cuts above 10% loss:** these follow libwebrtc's loss-based v1, by half the
  loss fraction every 300 ms + RTT, but stop at half the delay-based estimate.
  libwebrtc's version compounds to the minimum while loss lasts, which random
  Wi-Fi loss always triggers.
- **Probes** are padding datagrams (`sealPadding`, tagged with their cluster
  in the sent log). Start-up probes at 3 × the start rate, then 2 × each result
  while the link takes more than 70% of it. A sender under half the estimate
  for 1 s probes at 2× every 5 s. Results follow libwebrtc's
  `ProbeBitrateEstimator`, but count every packet the link carried during the
  burst, since interleaved media shared it.

Simulated results, all at a 20 Mbit/s bottleneck from a 4 Mbit/s start
(`RateControlSimulationTests`):

| case | budget / goodput (% of link) | queue p95 |
|---|---|---|
| LAN, seconds 1–3 | 85 / 89 | 7.3 ms |
| LAN, steady state | 93 / 96 | 13 ms |
| Tailscale-like (10 ms base, 3 ms jitter) | 92 / 94 | 10 ms |
| link halves at 15 s | 90 / 95 of the new rate, drained 0.5 s after | 8.7 ms |
| stalls every 2–4 s | 92 / 94 | 8.9 ms |
| 5% random loss | 90 / 89, FEC 0.15 | 7.8 ms |
| 15% random loss | 53 / 48, FEC 0.32 | 3.1 ms |
| still desktop then motion | estimate held at 95% by probes; motion 85 / 89 | 7.3 ms |

Most of the steady queue (5–9 ms) is each frame's own burst at the 1.5×
pacing rate, not standing queue. Not done yet:
- The encoder side of §6.3: frame rate and resolution steps.
- The pacer's stale-parity drop.
- ECN.
- A recorded-trace comparison against SCReAMv2.

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

**Channels (proposed 2026-10-07, replaces "one encode per stream").** A viewer
subscribes to a *channel*, not to a stream: the host's capture of a source
(desktop, window) at one resolution and codec. Viewers asking for the same
thing share a channel; one asking for something different gets its own encode.
The headset, an iPad and an Apple Watch on the same desktop then each get a
picture sized for them, and none is paced by another. Rules:

- **One capture, many encodes.** A source is captured once, at the largest
  size any of its channels needs, and downscaled on the GPU per channel
  (`VTPixelTransferSession`). Never a second ScreenCaptureKit stream of the
  same display.
- **Resolutions snap to a ladder**: native, ½, ¼ and a small tier around
  400 px for the watch. Five viewers asking for five slightly different sizes
  get one channel, not five sessions.
- **Frame rate is not part of a channel.** A channel encodes at the rate its
  fastest viewer wants. Slower viewers get frames dropped at the pacer. That is
  only safe for frames nothing references, so channels encode with **temporal
  layers** (`kVTCompressionPropertyKey_BaseLayerFrameRateFraction`): a 30 fps
  viewer of a 60 fps channel takes the base layer only. Unverified: whether the
  hardware encoder keeps hardware with layers on, or falls back to software as
  it does for low-latency rate control (see risk 14).
- **Encoders are allocated by pixel rate, not by count.** VideoToolbox has no
  "how many engines" API, and one engine runs many sessions time-sliced. The
  limit is throughput: one 4K60 HEVC stream already costs ~15 ms of every
  16.7 ms frame on an M1 ([[vt-hevc-encode-latency-benchmarks]]). So the host
  ranks channels by pixels per second. The largest go to the media engines
  (`AppleAVE2Driver` instances: one on an M1, two on an M2 Max) while the
  measured per-frame encode time stays inside the frame budget, and the rest go
  to the software encoder.
- **Small channels belong on the CPU anyway.** A watch-sized H.264 channel is
  about 1/40 of a 4K frame's pixels, cheap in software, and keeps the engine
  free for the channels that need it. Always check
  `UsingHardwareAcceleratedVideoEncoder` after creating a session rather than
  assuming what was asked for.
- **A codec is part of a channel**, picked from the viewer's capabilities
  (HEVC 4:2:2 for a headset that decodes it, H.264 for a watch if that is all
  it can do).

Within one channel the encode is still shared, so viewers on different links
can't each get their own bitrate. Rules:

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
                           sans-I/O: datagrams and a ns `now` in, datagrams and
                           a wake time out (as built 2026-10-24, §7.5)
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

**External frame sources** (added 2026-10-12). Besides WGC and duplication,
the shim accepts frames from another process through a small public contract,
`lw_frame_source.h`: a ring of shared D3D11 textures (NT handles) with a shared
fence, each frame tagged with its frame number and the side data to send
(§4.2); a seqlocked shared section going back, with head pose, gaze and pacing
for producers that need them; attach/detach and stats. Producer and host must
share an adapter (checked by LUID), and the handoff is GPU-only, with no CPU copy
or readback. Two producers use it:

- the **depth component** inside a flat game (§4.8): picture and depth, one
  frame number;
- the **PCVR compositor** (§4.7), which is private: composited eye images with
  their render poses, and head poses and pacing back.

The contract is how the public/private line stays at the module boundary.
Everything that streams is public and in this host. The private side only
produces frames and never links the core. The cost is one cross-process GPU
handoff per frame: *measured* at under 0.01 ms p99 added at 90 Hz
(open question 18, and the result below).

*Built (2026-10-12), in `Packages/LongwaveStream`:*

- `CFrameSourceCore/include/lw_frame_source_layout.h` is the contract: one
  named section (9,280 bytes, `LW_FS_VERSION` 2, layout `static_assert`ed) with
  the attach handshake, up to eight slots (state word, fence value, frame
  number, submit time, up to 1 KB of opaque side-data TLVs each) and a
  seqlocked host state (head pose with display time and space epoch, eye
  offsets and fields of view, gaze with a valid flag, refresh rate, next frame
  start). Its conventions are StreamWire's (§4.7): poses laid out as `XrPosef`
  (orientation, then position), fields of view as `XrFovf` (signed angles in
  radians, left and down negative), and a u32 pose sequence compared with
  wrap-aware serial-number order (`lw_fs_serial_newer`, StreamWire's
  `SerialNumber.isNewer`). Version 2 made those changes; version 1 had
  position-first poses, tangent fields of view and a u64 sequence. The layout (one texture, side by side, or one per eye, plus an
  optional depth texture) and the formats are declared at attach.
  `CFrameSourceCore` also holds every state transition, portable, so its tests
  run on the Mac as well as Windows.
- `CStreamWin/include/lw_frame_source.h` has the two APIs.
  `lw_frame_producer_*` is what a game component or a compositor links: no
  Swift runtime, four C++ files. `lw_frame_source_*` is the host side.
  It delivers each frame as an ordinary `lw_frame` whose texture *is* the
  shared slot texture, so it goes to `lw_encoder_encode` exactly like a WGC
  frame (`ExternalFrameSource` in `StreamHostWindows` on the Swift side).
- The host creates the textures and the fence on its own device. They are
  `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` textures and a `D3D11_FENCE_FLAG_SHARED`
  `ID3D11Fence`. The producer opens them on its device; the host waits for the
  fence value on the CPU (`SetEventOnCompletion`) before encoding.
- *Handles, not names, for GPU objects.* D3D11 can open a shared texture by
  name but has no way to open a shared fence by name (only D3D12 does). So the
  host duplicates every handle into the producer's process and writes the
  values into the section. Only the section and two events are named
  (`Local\lw_frame_source.<channel>`, `.host`, `.producer`). Their security
  descriptor is explicit:
  `O:<host user>D:P(A;;GA;;;SY)(A;;GA;;;<host user>)S:(ML;;NW;;;LW)`, plus
  optionally one more account. The low mandatory label lets a producer at
  medium or low integrity open what an elevated host created. The owner lets a
  restarted host tell its own section from a squatter's.
- *Latest wins, in order.* With no free slot the producer reclaims its oldest
  frame the host hasn't taken. The host takes the newest ready frame and drops
  older ones. A frame older than the last one taken is never delivered: the
  concurrent ring test caught exactly that reordering, once in about 25 runs,
  before the fix. Every transition is one compare-and-swap on a word that
  carries the attach generation, so a stale frame or detach can't touch a
  newer ring.
- *Lifetimes.* The host waits on the producer's process handle, so a producer
  crash ends its attach at once. The producer holds a `SYNCHRONIZE` handle to
  the host, so it sees a host crash on its next acquire and attaches again.
  `lw_frame_source_stop` may be called from the frame callback, which runs on
  the source's own thread; a Swift handler that drops the last reference to
  the source does the same. The call then returns at once, no callback follows
  the current one, and the thread finishes the teardown itself. Joining from
  that thread would have thrown across the C ABI.
- *The host trusts nothing in the section.* A producer, possibly at a lower
  integrity level, can write any byte of it, bypassing the producer API's
  checks. So the host keeps its own copies of the validated format, the slot
  count, the generation counter and the ring position (`lw_fs_host_ring`). It
  reads each producer-written field once (`lw_fs_host_snapshot`) and copies the
  side data into the frame. These are producer faults: the frame is dropped,
  that producer's attach ends, and `producer_faults` counts it.
  - a side data size over 1 KB;
  - a fence value no higher than the last delivered frame's;
  - a submit sequence more than `lw_fs_sequence_window` ahead of the last
    frame taken. The window is the slot count, plus 64, plus 10 per
    millisecond since that take, which is ten times any display-paced
    producer. Without the bound, one forged huge sequence froze delivery for
    the rest of the attach;
  - the fence forced to `UINT64_MAX`, the value D3D also uses for a removed
    device. The host tells the two apart by asking its own device
    (`GetDeviceRemovedReason`). If the host's device really was removed, that
    is `host_device_lost`, not a fault.
  - a fence that hasn't moved through 3 consecutive 1 s timeouts. A single
    timeout only drops that frame, and the attach carries on. A game stalling
    on shader compiles or level loads delays its next submit, never a fence
    value it already submitted. And Windows resets a GPU stuck on one piece of
    work past TdrDelay (2 s by default), so after 3 s an honest producer's
    fence has moved or its device was reset.

  A code review found that version 1 copied `side_data_size` bytes straight
  from the slot, so a rogue producer could make the host read gigabytes past
  the mapped view. Version 1 also took its slot count from the section, so a
  producer could point the host at slots that have no textures. A second
  review found the fence and sequence cases above.

*Measured (2026-10-12, `gaming-pc`: Windows 10 22H2, RTX 3080 on driver 610.88,
hardware GPU scheduling off (registry default), both processes in the
console session, 90 Hz, 60–70 s per run, first second dropped):* the
synthetic producer (`frame-source-spike produce`, spike-only) draws a panning
noise picture with its frame number into the ring. The host
(`frame-source-spike consume`) waits on the fence and encodes it with the
Phase 2 encoder settings (HEVC, P1, ultra-low latency, 50 Mbit/s CBR, async).
The baseline (`inprocess`) draws the same picture into a texture of the same
description on the host's own device, waits on a local fence and encodes it
the same way: everything but the handoff. "Load" is a third process holding the
GPU at about 70% (`gpu-load`), which raises clocks the way a game does.

| run (p50 / p99, ms) | present → fence reached | present → encode start | present → encoded |
|---|---|---|---|
| 1440p, idle GPU, in-process | 1.247 / 2.727 | 1.262 / 2.751 | 7.887 / 13.699 |
| 1440p, idle GPU, cross-process | 1.142 / 2.175 | 1.154 / 2.666 | 7.936 / 13.734 |
| 1440p, load, in-process | 0.471 / 0.997 | 0.485 / 1.013 | 3.556 / 4.615 |
| 1440p, load, cross-process | 0.470 / 1.006 | 0.485 / 1.020 | 3.543 / 4.607 |
| 3840×1920, load, in-process | 0.517 / 1.040 | 0.532 / 1.055 | 5.702 / 6.896 |
| 3840×1920, load, cross-process | 0.521 / 1.049 | 0.534 / 1.063 | 5.649 / 6.812 |

- **The handoff costs nothing measurable.** Present to encode start differs by
  +0.007 ms (1440p) and +0.008 ms (3840×1920) at p99 under load, against a pass
  mark of 1 ms. Idle runs are noisier than that in both directions. The
  host's wake-up after the producer's submit takes 8 µs p50 and 14 µs p99.
  "Fence reached" is dominated by the GPU executing the producer's own drawing
  (a 15–30 MB copy here), which is the same in both columns.
- Producer CPU per frame: acquire 1 µs, submit (fence signal, flush, publish)
  60 µs p50 and 76 µs p99, almost all of it the `Flush`. Attach takes about
  2 ms, a reattach under 1 ms.
- *Checks that pass:* every frame's picture, depth texture (R32_FLOAT holding
  the frame number) and side data read back and matched its slot (1,070 of
  1,070 in a 12 s run, `--verify`). A WARP-adapter producer is refused with
  `LW_FS_REFUSE_ADAPTER`. When the host held every frame for 2 s the producer
  got `LW_E_BUSY` 179 times (2 s at 90 Hz), then carried on in the same attach.
  A producer killed mid-stream was detected at once and a new one attached as
  generation 2. A host stopped, or killed and restarted at once, was seen by
  the producer within a frame, and it re-attached. NVENC registers and encodes
  the shared texture with no change to the encoder.
  `FrameSourceCoreTests` (30) pass on the Mac and on the PC.
  `StreamHostWindowsTests` (16 cases in one process) passes on the PC. Its
  cases include a forged side data size, a raised slot count, a single and a
  persistent fence stall, the fence forced to `UINT64_MAX`, a forged
  sequence, and stopping from the callback; 52 of 52 tests in all. The same
  scenarios also passed through the C API on `winvm`'s VMware GPU, and the
  Windows C++ compiles with MSVC as well as clang.
- *With a real game sharing the GPU* (Cyberpunk 2077 running on the PC during
  a later 40 s run, plus the load process): both columns slow alike,
  in-process 2.689 ms and cross-process 2.684 ms p99 present → encode start.
  The handoff stays invisible; the game's contention sets the number.
- *Not measured or not verified:* hardware-accelerated GPU scheduling on;
  Windows 11; a real game as the producer (the depth component and its
  per-frame `Flush` in a game's render thread); a producer at a different
  integrity level from the host, and a host running as SYSTEM with
  `producer_sid` (the descriptor is built for both; only same-user,
  same-integrity runs happened); D3D12 or Vulkan producers (they can open the
  same NT handles, but no producer library exists for them); formats other
  than BGRA8 into the encoder (NVENC takes BGRA8 today, so 10-bit, HDR and
  depth need a conversion pass first); TDR and device removal mid-stream,
  including whether a *producer's* device removal can make the shared fence
  read `UINT64_MAX` on the host (it would count as a producer fault).
  `lw_capture_stop` has the stop-from-callback hazard the frame source had.
  Called from a capture callback, it joins its own thread (DXGI
  duplication) and takes the delivery mutex that the running callback
  already holds. It isn't fixed yet.

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
WGC's `MinUpdateInterval` exists only from SDK 26100 / Windows 11 24H2 [W6]
— but *measured in the Phase 2 spike* it isn't needed to go above 60 Hz: on
Windows 10 22H2, WGC delivered every composition of a 180 Hz panel (1,440
frames in 8 s). Both backends sit behind the shim (`LW_CAPTURE_WGC`,
`LW_CAPTURE_DDA`) at near-equal latency (§8). DXGI duplication stays the
fallback for the desktop stream, and may be the better default on Windows 10:
WGC there always draws a yellow border round the captured monitor
(`IsBorderRequired` is Windows 11 API; documented, not yet observed here),
while duplication has no border but doesn't draw the cursor.

**Virtual gamepads on Windows** need a driver. ViGEmBus — what Sunshine uses —
was archived on 2023-11-02; existing installs keep working but nothing
maintains it, and its announced successor hasn't shipped [W8].

*Decision (2026-10-04):* our own **user-mode (UMDF2) driver on the inbox
Virtual HID Framework**, presenting an Xbox Series pad (Windows' `xinputhid`
makes it visible to XInput) and a DualSense (adaptive triggers, gyro,
touchpad), with rumble and trigger effects returned as HID output reports.
Being user-mode, a bug in our code can't blue-screen the PC. The kernel stack
it drives can, though: see the sleep note below. libvirtualgamepad (MIT) is
the reference. ViGEmBus 1.22, already signed by its author and already shipped
opt-in by the PCVR host, is the fallback behind the same `lw_gamepad_*` API.

*Distribution without certificates.* Longwave does not buy signing
certificates: Windows code ships as MIT source that users review, build and
run themselves, and the driver follows the same rule. Only kernel binaries
need Microsoft's signature; a UMDF package needs a catalog signed by a
certificate the machine trusts. So the driver's build script creates a
certificate **on the user's machine** at install time, signs the catalog,
adds the certificate to that machine's Root and TrustedPublisher stores, and
**deletes the private key** — no key exists afterwards that could sign
anything else, and uninstall removes the certificate. This is the pattern
HIDMaestro uses, minus its one weakness (a long-lived key). Test-signing
mode is never used: it weakens the whole machine and anti-cheat refuses it.

*Verified on Windows 10 22H2 (2026-10-04, `gaming-pc`, Secure Boot on, test
signing off; `CompanionWindows/spike/vhf-gamepad`):* the package installs
silently and loads. Windows' own install log records "signed with an
Authenticode catalog from a trusted publisher", signer score Authenticode, and
the device is OK in `WUDFHost.exe`. Both halves of the trust are needed:
an unsigned catalog is refused ("Code Integrity is enforced"), and a
certificate in Root but not TrustedPublisher is refused when nobody can be
prompted. Signing uses only inbox PowerShell (`New-SelfSignedCertificate`,
`Set-AuthenticodeSignature`), so the machine that installs needs no SDK. The
key's deletion is checked three ways. Windows also files a copy of the public
certificate in `LocalMachine\CA`, which uninstall must remove. Once a package is
in the driver store it keeps loading after the certificate expires (signatures
are checked at import only), so the certificate gets a 10-year life; with the
key gone that costs nothing. The spike's driver is a ~600-line rewrite of
libvirtualgamepad's (Xbox Series + DualSense). Its report encoders are vendored
unchanged, and it carries its own interface GUID and hardware ID so it can't
collide with Vibeshine's. Functionally: XInput, Windows.Gaming.Input and SDL3
see the pads, with exact values; rumble, impulse triggers, DualSense gyro and
lightbar round-trip; killing the feeder removes its pads within ~15 ms; 2,000
create/destroy cycles showed no leak; and the signed-in user drives pads
without admin.
*Verified on Windows 11 26H2 (2026-10-04, fresh unattended install in a Hyper-V
VM on `gaming-pc`, Secure Boot on, test signing off, Memory Integrity not
running):* with Smart App Control in **evaluation** (its out-of-box state) or
**off**, the same package installs silently and every check passes. The driver
comes back by itself after a reboot. A driver installed during evaluation kept
working after SAC was switched **on**. With SAC **on**, a fresh build is a
gamble. SAC ignores the locally trusted signature: blocked files are logged as
unsigned (`Validated Signing Level=1`, event 3077). Each file stands or falls by
Microsoft's cloud verdict. One of two fresh builds of the same source had its
test feeder blocked; the other ran completely. The UMDF DLL inside
`WUDFHost.exe` was never blocked. Evaluation mode emitted no audit (3076) events
that would have predicted the block. So SAC is the remaining risk (§9 risk 8),
and it falls on our user-mode **executables** (the host, helpers), not on the
driver.

*Sleep (verified 2026-10-05, Windows 11 bare metal, S3):* the first driver
blue-screened the PC (0x9F, `vhf.sys`) whenever it slept with a pad present,
even an idle one. For each pad, Microsoft's VhfUm keeps one request waiting in
`vhf.sys`, and `vhf.sys` won't power down while it waits. The driver now
deletes every pad in `EvtDeviceD0Exit`, before `vhf.sys` gets the power IRP,
and refuses VHF work until D0Entry. Idle pads, churn and suspend-aware runs
all sleep and resume cleanly since. **What the host must do:** treat
`ERROR_DEVICE_REMOVED` (1617) on any pad request as "lost to a power-down"
(destroy that id, then create it again). Treat `ERROR_NOT_READY` (21) as "the
device is powered down; retry shortly". Optionally, as defence in depth,
destroy pads on `PBT_APMSUSPEND` and recreate them on
`PBT_APMRESUMEAUTOMATIC` (`PowerRegisterSuspendResumeNotification`), but never
rely on that notification alone. XInput reads zeros for every pad, virtual or
physical, while the console session is locked, which it is after a wake until
someone signs in. Details: `CompanionWindows/spike/vhf-gamepad/README.md`,
"Sleep and power".

**Controller layering.** One pad pipeline with two possible inputs and one
output, so a second input source never means a second driver. It serves every
consumer, not only the stream: the Native/v3 host, and PCVR, where a game with
only Xbox controller support gets the controller paired to the headset as a
virtual pad (today the PCVR session broker's ViGEmBus Xbox 360 mode, to move
onto this driver). The sleep fix above therefore protects PCVR sessions too.

- *Inputs.* The headset bridge (the client's GameController devices: Xbox,
  DualSense, Switch Pro, with gyro, accelerometer and battery where visionOS
  exposes them) is the product path. A *local* input, a physical controller on
  the PC read through SDL3 (zlib), which already speaks the Switch Pro,
  Joy-Con, DualShock 4, DualSense and Xbox protocols including IMU calibration
  and HD-rumble encoding, can be added later as a small extra. It is not a
  Steam Input replacement: per-game profiles, remapping UI and gyro-to-mouse
  are a separate product and out of scope. Hiding the physical device from
  games that read it natively needs a kernel filter (HidHide); without one,
  SDL-aware games see both, and XInput games, which never see a Switch Pro,
  are unaffected.
- *Output.* The VHF driver with per-session profiles: **Xbox Series** (XInput
  games), **DualSense** (PlayStation-aware games, Steam gyro), and later **Switch
  Pro** (emulators, Steam gyro with Nintendo layout) and DualShock 4.
  Upstream libvirtualgamepad already implements the Switch Pro handshake,
  subcommands, calibration flash, IMU reports and battery, so the plan is to
  consume upstream rather than grow our reduced copy, contributing back the
  sleep fix and a two-band rumble feedback event (upstream reduces Switch HD
  rumble to amplitude; the client maps low and high bands onto two CoreHaptics
  continuous events per side, an approximation, since CoreHaptics cannot replay
  the Pro's waveform exactly).

**Process model:** the Electron Companion and its C# backend stay — they own
Hotspot NAT, PCVR install/supervision and the UI. The C# backend launches and
supervises `longwave-host.exe` (as it supervises other processes), talks to it
over the existing named-pipe RPC style for enable/token/status, and its own
Native stream is retired once the Swift host reaches parity (§8). The Swift
runtime DLLs ship next to `longwave-host.exe` in the companion's installer
(measured in the Phase 2 spike: 13 DLLs, 13.6 MB, beside a 3.9 MB stripped
exe; the 6.2.4 Windows SDK ships no static runtime, so they can't be linked in).

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
  *As built (2026-10-24):* the transport is **sans-I/O** rather than behind
  socket and clock protocols. Each piece is a state machine that takes
  datagrams and a nanosecond `now`, and returns datagrams and a next wake
  time. The owner runs the socket and the timer. On the app side that is a
  thin Network.framework driver; in tests it's a loop over `SimNetwork`. That
  removed the `DatagramSocket`/`MonotonicClock`/`Timer` seam from the package.
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

### 7.6 Windows: launching games

The tray menu gets **Launch game…**, the one way a game gets Longwave's
in-process extras. Starting the game ourselves is what makes them safe to
offer: the user chose it, we know which title it is before it runs, and
nothing is ever loaded into a process that is already running.

- **What it does.** Picks a game (the PCVR library's titles when the PCVR host
  is installed, or any executable or shortcut), then starts it unelevated with
  the title's optimised launch profile if one exists, through the PCVR host
  when a PCVR session is on, so the title runs in VR, and with the game audio
  component when the title qualifies (below). Without PCVR it is a plain
  launch plus whatever applies.
- **First use asks.** A message box says what the launch does: profile, PCVR
  routing, and loading Longwave's audio component into games without
  anti-cheat, and that games with anti-cheat are started without it. It has
  Yes/No and a "Don't ask again" checkbox. Declining launches nothing.
- **Which titles get the audio component.** Only titles with no anti-cheat. The
  launcher refuses to load it when the install shows an anti-cheat (Easy
  Anti-Cheat, BattlEye, Vanguard, Ricochet, nProtect, PunkBuster, XIGNCODE,
  FACEIT and similar files or services), and starts such games without it.
  The component is loaded at process start (created suspended, loaded,
  resumed), never written into the game's folder, so Steam's file
  verification and game updates are unaffected. It starts as an allowlist
  (Cyberpunk 2077 first), not a guess. Every other game's audio is WASAPI
  process loopback, at most 7.1.
- **The depth component (§4.8)** follows the same rules: the same anti-cheat
  refusal, loaded at process start, never written into the game folder, an
  allowlist starting with Cyberpunk 2077, and one more line in the consent
  text. It is a ReShade add-on, so the launch loads ReShade and the add-on
  together, and it also supplies the frame itself (frame and depth with one
  frame number), so a depth-enabled game skips WGC. Whether ReShade's own
  launch-time loading fits the suspended-start flow, or the two components
  should load as one, is open question 15.
- **One public library (2026-10-05).** Launching is backed by the Companion's
  game library, which moved from the closed PCVR host to public code and now
  covers flat games too: Steam discovery with each title's kind (VR / flat /
  both from `appinfo.vdf`, user-overridable), custom entries, art, optimised
  profiles, last played and the headset-exposure set, in a public Games tab
  (grid and windowed list). The PCVR host keeps only the CloudXR-specific
  start of a VR title (`GamesLaunchResolved`) and relays the headset's library
  requests to the public backend, so the headset protocol is unchanged. Only
  VR-capable titles are exposed to the PCVR gallery for now; exposing flat
  titles to a Native/v3 "launch from headset" is the obvious next use.
- **Shortcuts.** The Companion exe takes a game itself (`--launch "<path>"`, or
  a bare path, which is what dropping a game on the exe passes) and does what
  Launch game… does for a browsed file, without the picker; a running instance
  takes the request over. `--launch-title <id>` names a library title; the
  Games tab and the picker write such shortcuts.
- **Order of work.** The menu, the consent box, launching, profiles and PCVR
  routing need nothing new and come first (phase 1, built 2026-10-05: the
  consent text's effect list in `game-launcher.js` is where the audio sentence
  goes). The audio component waits for the
  v3 audio channel (§4.4): today nothing could carry its 12 channels to the
  headset, since Moonlight stops at 8.

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
  in use). *Answered by the Phase 2 spike, 2026-10-04: it works* (cut-stream
  test in the spike result below).

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
- Frame side data and auxiliary streams (§4.2) in `StreamWire` and the frame
  assembler from the start, with the PCVR head-pose STATE snapshot (§4.7).
  *`StreamWire` done 2026-10-12* (frames, shard headers, format, side data,
  input, STATE including the head pose, capabilities). *`StreamFEC` and the
  frame assembler (`StreamPlayout`) done 2026-10-24. `StreamCrypto`,
  `StreamTransport` with the GCC rate controller, and `StreamSim`, done
  2026-10-24.*
  The simulator gets a 90 Hz stereo profile (a large frame every 11 ms and a
  pose snapshot uplink at the same rate) beside the desktop and game profiles,
  so loss and recovery are tuned against the hardest stream from day one.

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

#### Phase 2 spike result (2026-10-04): GO

**Verdict: go.** Swift can be the Windows host. Every gate item worked on
`gaming-pc`, and nothing hit a wall that the C++ fallback would avoid. Code:
`Packages/LongwaveStream` — `CStreamWin` (the C ABI, `include/lw_stream.h`) and
`StreamHostWindows` (its Swift wrappers) are meant to be kept;
`StreamSpikeWire`, `longwave-host-spike` and `stream-spike-receiver` are
spike-only. `scripts/windows.ps1` builds, tests and packages on the PC.

Set-up: Windows 10 22H2 (19045), RTX 3080 on driver 610.88 (NVENC API 13.1),
Swift 6.2.4 (its clang is 19.1.5), VS 2022 Build Tools 14.44, Windows SDK
26100. Encoder settings throughout: HEVC Main, NVENC P1 with ultra-low-latency
tuning, CBR 50 Mbit/s, one-frame VBV, no B-frames, infinite GOP with an IDR
only on request.

How the spike differs from the gate as written: the Phase 1 core doesn't exist
yet, so a throwaway packetizer carried the pictures (28-byte header,
1,200-byte datagrams, no FEC, no encryption), and the client was a Swift
receiver on the Mac writing an elementary stream that VideoToolbox decoded
(through ffmpeg), not Longwave itself. Those are integration steps, not
feasibility questions.

*Measured (facts).* "Capture" is the earlier of the OS's timestamp and the
moment the shim got the frame (see workaround 2); "encoded" is the bitstream
locked in system memory. The encode itself is all but ~0.1 ms of each figure:
the GPU copy out of the OS's texture and the hand-off to the encode thread
take under 0.02 ms.

| Source (all 120 fps out) | capture→encoded p50 / p95 / p99, ms |
|---|---|
| Real 2560×1440 desktop (180 Hz panel), WGC, GPU otherwise idle | 4.23 / 4.59 / 4.64 |
| same, GPU held at game clocks by a load generator | 3.02 / 4.24 / 4.62 |
| Real desktop, DXGI duplication, idle | 4.83 / 5.20 / 5.28 |
| same, game clocks | 3.47 / 4.87 / 5.22 |
| Synthetic 1440p, fresh noise every frame (encoder worst case), game clocks | 2.91 / 4.32 / 4.42 |
| same, GPU 100% busy (contention with a game) | 3.81 / 4.44 / 4.47 |
| Synthetic 1440p panning, preset P4, game clocks | 5.73 / 7.13 / 7.18 |
| Synthetic 3840×2160 at 60 fps, panning, game clocks | 6.08 / 7.27 / 7.44 |

- Network: over wired LAN to the Mac, 1,200 of 1,200 pictures arrived at
  48.7 Mbit/s with no loss, and decode clean in VideoToolbox. On loopback,
  capture→received was p50 4.52 ms with the GPU idle.
- CPU: the whole host process used 0.1–0.9% of the 12 logical CPUs (1–11% of
  one core) at 1440p120, including ~5,000 datagrams/s and, in most runs, the
  in-process test receiver.
- Recovery: IDR on request works. So does `NvEncInvalidateRefFrames`: with the
  two invalidated pictures cut out of the stream, all 361 later pictures
  decoded bit-identical to the uncut stream, while cutting two ordinary
  pictures instead broke decoding ("Could not find ref"). The encoder reports
  reference invalidation, intra refresh and 7 LTR frames.
- Audio: WASAPI loopback of a 7.1 endpoint (Steam Streaming Speakers) gave 8
  channels of 48 kHz float, mask 0x63F; a distinct test tone per channel came
  back on its own index, and macOS reads the WAV as 7.1.
- swift-crypto 4.5.2 builds on x64 Windows (its BoringSSL compiles with the
  toolchain's clang) and passes the RFC 7748 X25519, RFC 8439
  ChaCha20-Poly1305 and RFC 5869 HKDF vectors, under `swift test` and inside
  the packaged exe. Release ChaChaPoly seals a 1,200-byte datagram in 3.8 µs
  (313 MB/s on the Ryzen 5600X): about 4% of one core at 100 Mbit/s.
- Packaging: the exe plus 13 DLLs from the toolchain's runtime folder ran from
  a fresh folder with `PATH` cut down to Windows' own directories. swiftCore
  5.8 MB, FoundationEssentials 5.3 MB (pulled in by swift-crypto; there is no
  `Foundation.dll` and none of ICU's 35 MB), swift_RegexParser 0.95 MB,
  swift_StringProcessing 0.66 MB, MSVCP140 0.56 MB, dispatch 0.23 MB,
  swiftDispatch 0.15 MB, VCRUNTIME140 0.12 MB, and under 0.06 MB each:
  swiftSynchronization, VCRUNTIME140_1, swiftCRT, swiftWinSDK, BlocksRuntime.
  17.5 MB in all with a stripped 3.9 MB exe, 6.1 MB zipped. Everything else
  it links (d3d11, dxgi, avrt, ws2_32, the api-ms-win-* set) is part of Windows.

*What worked first time:* SwiftPM compiled the C++20 shim, C++/WinRT headers
included, with Swift's clang against MSVC's STL and the Windows SDK, with no
compiler workaround. Importing the flat C header, C callbacks into Swift
through `Unmanaged` contexts, `Synchronization.Mutex`/`Atomic`, Dispatch queues
and semaphores, Winsock through `import WinSDK`, and `swift test` (XCTest) all
worked as on the Mac.

*What needed a workaround (each fix is in the code):*
1. DXGI duplication with a blocking `AcquireNextFrame(100 ms)` stalled NVENC on
   the same D3D11 device until the next desktop update: 18.8 fps and 25–50 ms
   encodes. Polling with a zero timeout and a 0.5 ms high-resolution timer
   sleep fixed it.
2. WGC's `SystemRelativeTime` lands about one refresh *after* the frame reaches
   us (−13 to −15 ms at 60 Hz, −4.6 ms at 180 Hz), apparently the vblank it was
   composed for. Capture time is taken as the earlier of the two stamps.
3. Encode latency follows the GPU's clocks. With only the stream running, the
   driver sits in P3–P8 and NVENC takes 4–6 ms at 1440p; at game clocks it
   takes ~3 ms. Phase 0's Moonlight comparison must be made with a game
   running. Whether the host should hold clocks up itself is open: Sunshine's
   way is a driver-profile setting, which changes the user's driver settings.
4. SwiftPM's release build embeds DWARF in the `.exe` on Windows (15.5 MB of
   19.3 MB); `windows.ps1 -Strip` (`-Xswiftc -gnone -Xcc -g0 -Xcxx -g0`)
   removes it. `--static-swift-stdlib` is accepted and silently ignored, since
   the 6.2.4 SDK ships no static runtime.
5. Audio endpoint *indices* change when devices come and go (the monitor
   waking added its DisplayPort audio), so endpoints must be chosen by ID. By
   index, the spike once played its test tone on the wrong device.
6. Swift-on-Windows papercuts, none blocking: `WinSDK` imports `WS_POPUP` as
   `UInt32` but `WS_VISIBLE` as `Int32`; GDI handle types need `OpaquePointer`
   casts; socket lengths are `Int32` on Windows but `socklen_t` elsewhere;
   `String(format:)` needs Foundation (a `vsnprintf` helper avoids it); `fopen`
   warns as deprecated.

*The shim API to keep* is `lw_stream.h` as built: `lw_device` (one D3D11
device for capture and encode); `lw_capture` (WGC or duplication, handing out
frames as BGRA texture handles from a shim-owned ring that the consumer
releases); `lw_encoder` (synchronous encode of a texture with a force-IDR flag,
`invalidate`, `set_bitrate`); `lw_audio_loopback`; monitor and endpoint
listing; QPC time. Its spike-only parts (`lw_capture_start_synthetic`,
`lw_spike_gpu_load_*`, `lw_audio_play_test_tones`) are marked as such. NVENC's
async completion-event wait gave the same latency as blocking in the lock call
with less CPU, so make it the default.

*Inference, not measured:* WGC draws the yellow capture border on Windows 10;
duplication's missing cursor means the shim must draw the pointer; capturing
the secure desktop (UAC prompts, lock screen) needs a SYSTEM-level helper in
the user's session, which is how Sunshine runs; HDR needs `DuplicateOutput1`
or FP16 capture and a 10-bit encode path; a 120 Hz display mode itself wasn't
tested (120 fps was decimated from 180 Hz, since display settings were
off-limits).

*The fallback, evaluated:* a C++ host process would save the 13.6 MB of Swift
runtime and the WinSDK papercuts. It would cost a second implementation of
everything above the shim (transport, FEC, crypto on another library, rate
control, playout), held to the Swift core by test vectors. Nothing in the
spike justifies that, so it stays a fallback only.

*Next:* build the Phase 1 core and put `StreamHostWindows` behind its
`CaptureSource`/`VideoEncoder`/`AudioSource` protocols. Harden the shim:
recovery from device removal (TDR) and display-mode changes, the cursor for
duplication, window capture, HDR, scaling when the encode size differs from
the capture size, AMF/Media Foundation behind the same `lw_encoder` API, and
CodeView PDBs for crash symbols. Add a Windows CI job like Oneiros', and
settle the clock question (workaround 3).

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
- **3D for flat games (§4.8):** the depth component through Launch game…
  (Cyberpunk 2077 first), the `depthVideo` stream, the displaced-mesh renderer
  on the headset, then Depth Anything as the fallback. Gate: Cyberpunk on the
  headset matches the SuperDepth3D reference rig with no extra PC frame time
  beyond the depth copy and its encode.
- **PCVR over v3 (§4.7):** the CompositorServices receiver and the head-pose
  uplink, against the host work in the private `NATIVE_PROVIDER_PLAN.md`. Its
  phases and gates live there; this roadmap only owns the wire.

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
- Phase 2 spike, 2026-10-04 (`Packages/LongwaveStream`, results in §8): Swift
  6.2.4 builds a C++/WinRT shim and drives WGC and DXGI capture, NVENC and
  WASAPI on `gaming-pc`. The real 1440p desktop at 120 fps measured
  capture→encoded p50 3.0 ms at game clocks and 4.2 ms with the GPU idle.
  `NvEncInvalidateRefFrames` works on the RTX 3080, swift-crypto 4.5.2 passes
  RFC vectors on x64 Windows, and the runtime ships as 13 DLLs (13.6 MB).
- The Static Linux SDK has no dynamic linking [S2].
- Sunshine: 20% default FEC, ≤ 255 shards/block, ≤ 4 blocks/frame, min 2 parity,
  RFI for NVENC only, 64 KB / 64-packet send batches, media encryption off on LAN
  by default [M1][M4]. Moonlight: 1392/1024-byte packets, audio RS 4+2 with
  5 ms Opus [M2][M3].
- ViGEmBus archived 2023-11-02 [W8].
- A UMDF2 + VHF virtual gamepad needs no paid certificate on Windows 10 22H2
  with Secure Boot on and test signing off. Measured 2026-10-04 on `gaming-pc`
  (`CompanionWindows/spike/vhf-gamepad`, `evidence/` log). The catalog is
  signed at install with a self-signed certificate that's trusted in
  LocalMachine Root + TrustedPublisher and whose key is then destroyed; the
  install is silent and the device is OK. Negative controls: an unsigned
  catalog gives `0xE0000247`, Root-only trust gives `0xE0000242` (would
  prompt). The Xbox Series pad is XInput-visible through the inbox
  `xinputhid`; Windows.Gaming.Input sees it, input only for the foreground
  process; SDL3 identifies the DualSense as PS5 with exact gyro. Rumble,
  impulse triggers and lightbar reach the driver; the pads die with their
  feeder; 2,000 create/destroy cycles showed no leak.
- The same package on Windows 11 26H2 build 26300 (Hyper-V VM, fresh install,
  Secure Boot on, 2026-10-04, `evidence/win11-hyperv-vm-*`) installs silently
  and passes everything with Smart App Control in evaluation or off, including
  after a reboot. With SAC on, blocks are 3077 events from policy
  `VerifiedAndReputableDesktop`, with the locally signed file at `Validated
  Signing Level=1`, i.e. treated as unsigned. Of two fresh builds, one had
  `lwpad-test.exe` blocked and one ran fully; the driver DLL was never blocked.
  Evaluation mode logged no 3076 for files SAC-on later blocked. With a stale
  Defender (cloud answering HTTP 426) SAC-on allowed every unknown file.
  Windows.Gaming.Input vibration from an *elevated* process doesn't reach the
  device on this build; unelevated it does.

### Inference and open questions

1. **The headset's Wi-Fi may set the floor, not the protocol.** If the 60–180 ms
   stalls also hit a constantly streaming flow, no FEC or rate control fixes
   them (the data is late, not lost) and Moonlight suffers equally. Phase 0
   measures this first; the latest-wins playout in §5 limits the damage to a
   freeze rather than accumulated lag. The stalls are the radio leaving for
   AWDL. The user-side mitigation is turning off Handoff, AirDrop and Location
   Services, then the 5 GHz network on AWDL's channel (44 EU, 149 US); Vision Pro
   has no 6 GHz radio. Phase 0 should measure with and without these, so the
   baseline isn't polluted by a fixable setting.
2. **Swift on Windows for a media host.** *The Phase 2 spike passed on
   2026-10-04* (§8). What's left is breadth, not feasibility: HDR, the cursor
   under duplication, the secure desktop, AMF/Media Foundation, device-loss
   recovery, and a long soak.
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
   frame parser. *`StreamWire`'s decoders are fuzzed with seeded mutations from the
   start (2026-10-12).*
5. **Network.framework UDP throughput on visionOS.** At 100 Mbps and 1200-byte
   payloads that's ~10 k datagrams/s; per-datagram callbacks may cost real CPU on
   the client. Measure in Phase 1; `NWConnection.batch` and multi-message
   receive are the levers, BSD sockets the fallback.
6. **NACK vs FEC balance** on the real AP is an empirical question for the
   simulator and Phase 1.
7. **Spatial audio from Windows games needs no driver.** Measured 2026-10-04
   with `CompanionWindows/spike/spatial-audio-probe` (an ASI plugin hooking
   `IMMDevice::Activate` and wrapping `ISpatialAudioClient` in-process):
   Cyberpunk 2077 2.31 with Windows Sonic on asks for a **7.1.4 static bed**
   (`StaticObjectTypeMask` 0x1FFE) and **zero dynamic objects** (max 0), even
   with 111 available, and fills all twelve bed channels in gameplay. So the
   capturable ceiling for this game is a 12-channel bed, which the hook gets
   un-rendered (before Sonic binauralizes it). Becoming a system-wide spatial
   format provider is the only partner-gated route, and it isn't needed. Other
   titles may use dynamic objects; the object channel in §4 stays optional.
8. **Virtual gamepads on Windows**: decided on a UMDF2 + VHF driver with a
   locally generated, key-destroyed certificate (§7.2). *Verified on Windows 10
   22H2 and Windows 11 26H2, Secure Boot on:* silent install, driver loads and
   survives a reboot, games' input APIs see the pads (facts list above).
   *Verified:* Smart App Control does **not** accept a locally trusted root.
   With SAC on, a fresh user build can have an executable blocked (seen once
   in two builds), and evaluation mode gives no warning. *Inference:* SAC is
   per-file, depends on cloud reputation, and changes over time. It threatens
   the host and helper executables more than the driver DLL (never blocked in
   any run). A user who installed during evaluation probably keeps working
   until the next rebuild. No free fix is known: SAC has no per-app exception,
   so the options are documenting "turn SAC off" (on this build Windows
   Security still lets the user turn it back on), or reputation, which in
   practice means the paid certificate this design avoids. Building is
   unaffected; only running is. *Fixed:* sleeping with a pad present
   blue-screened the PC through `vhf.sys`; the driver now deletes pads on every
   power-down and the host recreates them (§7.2). *Open:* feature updates, real games, Steam
   Input, and Vanguard-class anti-cheat, which is reported to reject any
   virtual pad.
9. **Anti-cheat** is three separate risks, none tested yet:
   - *Virtual pads.* Games may refuse controllers they can identify as virtual,
     because of aim-assist abuse (Cronus, XIM, mouse-to-controller
     converters). Mainstream titles behind Easy Anti-Cheat and BattlEye have
     accepted ViGEmBus pads for years (Sunshine, Parsec, DS4Windows), and
     Steam Remote Play uses its own virtual pad; Vanguard is reported to reject
     them, though Valorant has no PC controller support anyway. Ours is
     identifiable as virtual by design (parent `Root\LongwaveVirtualGamepad`;
     XInput itself can't tell), and ships no kernel driver, so it can't land
     on a vulnerable-driver blocklist as ViGEmBus could. Using a virtual pad is
     not cheating; bans come from macros and injection.
   - *Injected keyboard and mouse.* `SendInput` input is flagged as injected
     and some games, especially with kernel anti-cheat, ignore it — a
     functionality problem Moonlight/Sunshine users already meet, not a ban
     risk. The fix, if needed, is a VHF keyboard and mouse beside the pads.
   - *Code in the game's process* (the game audio component, §7.6) is the
     real ban risk in anything with anti-cheat. Hence: only through Launch
     game…, only titles with no anti-cheat, an allowlist first, never into a
     running process; everything else uses process loopback.
   *Test before relying on either:* one Easy Anti-Cheat and one BattlEye title
   the user owns, pad only (input works, nothing flagged), one with Steam Input
   running (does Steam grab or double the pad), and mouse injection in the
   same titles. The audio component is never run in any of them.
10. **Multi-viewer on one encoder** forces the slowest viewer's bitrate on
    everyone; simulcast is only partly possible on single-engine Macs.
    Channels (§6.5) narrow this to viewers *of the same channel*.
11. **swift-crypto on x64 Windows** isn't claimed by its README [S1]. *Closed
    2026-10-04:* 4.5.2 builds there and passes the RFC 7748, 8439 and 5869
    vectors (Phase 2 spike), so no CNG fallback is needed.
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
14. **Temporal layers on the hardware encoder are unverified.** If
    `BaseLayerFrameRateFraction` drops HEVC or H.264 to software, the way
    `EnableLowLatencyRateControl` does, a slower viewer needs its own
    frame-rate channel on single-engine Macs instead of a dropped layer.
    Measure it with the same harness as the encode-latency numbers.
15. **ReShade under Launch game….** Unverified whether ReShade's launch-time
    loading works with the created-suspended start the audio component uses,
    or whether one loader should bring in both. Also unverified: which ReShade
    build we need (the standard build is understood to withhold depth when it
    sees network traffic, and the full add-on build is meant for single-player
    games only), and how much the depth copy costs at 1440p.
16. **CompositorServices inside the provider extension.** Unknown until the
    entitlement is granted. If the extension can only present through
    RealityKit, the PCVR receiver's thin presenter (§4.7) gets a RealityKit
    implementation. Decode, unwarp and reprojection are unaffected.
17. **Reprojection without CloudXR's.** The compositor corrects rotation when
    each frame is submitted with its true render pose. Translation since render
    and late frames are ours to handle. That is the hard part of the PCVR
    profile, and the reason to stress-test it early, not a reason to wait.
18. **Cost of the external frame source handoff.** *Answered (2026-10-12):
    negligible.* Built as `lw_frame_source.h` and measured on `gaming-pc`
    against an in-process baseline in the same harness (§7.2). At 90 Hz, with a
    game-like GPU load, it added 0.007 ms at p99 between the producer's submit
    and the encode start, at 1440p and at 3840×1920 alike, against a 1 ms pass
    mark. The DLL-in-producer fallback isn't needed. Still open: HAGS on,
    Windows 11, a real game as the producer, and mixed integrity levels
    (listed under the §7.2 result).
19. **Packet rate and pacing at 90 Hz stereo** (arithmetic from the shard
    layout, 2026-10-12). Assume a 3840×1920 HEVC stream at 150 Mbps and 90 fps.
    - **Frame size:** about 208 KB per frame, which is 183 data shards of
      1144 bytes. With 20% FEC that makes 220 datagrams per frame and
      ~20,000 datagrams/s, twice the figure in risk 5. At 200 Mbps a frame no
      longer fits one 255-shard block.
    - **Pacing:** the pacer's 1.5× budget (§6.4) spends ~7 ms of the 11 ms
      frame interval sending one frame. That adds the same to motion-to-photon
      for the last shard. PCVR probably needs a pacing factor of its own, and
      the 1452-byte LAN payload (18% fewer datagrams) matters more here than
      for the desktop.
    - **Header overhead** is 56 of 1200 bytes (4.7%), acceptable.
    - The headset's receive cost at 20 k datagrams/s is the number to measure
      first.
20. **Coalescing with media is unspecified.** *Decided (2026-10-24): small
    frames ride only in non-media datagrams; see the transport frame bodies in
    §4.1.* §4.1 lets an ACK or FEEDBACK
    ride on any outgoing packet, but a media shard fills its datagram to the
    byte, because FEC needs equal shard sizes. Either the packetizer reserves
    headroom in every media datagram (and the shard size shrinks by it), or
    small frames ride only in non-media datagrams. Media is mostly host →
    client, so this mainly decides how the host acks the client's input
    channel.
21. **The gaze sample's shape is a guess.** The provider API exposes a focus
    *region* (`latestFocusRegion`), not necessarily a direction and distance.
    Gaze is capability-gated and a new STATE kind costs nothing, so the shape
    should be confirmed against the real API before anything depends on it.

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
