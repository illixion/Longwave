# Longwave File Structure

```
Longwave/
├── LongwaveApp.swift                  — App entry and multi-window scene registration
├── Models/
│   └── SavedConnection.swift           — SwiftData model, ConnectionType, Moonlight settings enums
├── ViewModels/
│   ├── VNCConnectionManager.swift      — VNC connection bridge, @Observable
│   ├── AudioStreamManager.swift        — Audio manager + AudioStreamReceiver (reconnect, mute, now-playing)
│   ├── MacNativeStreamManager.swift    — Native stream lifecycle, per-window sessions, transparent display layer
│   ├── LogStore.swift                  — OSLogStore poller backing the Console tab/window
│   └── MoonlightConnectionManager.swift — Moonlight orchestrator, state machine, @Observable
├── Views/
│   ├── MainView.swift                  — Main window: ornament tab bar (Connections/Settings/Console)
│   ├── ConnectionListView.swift        — Server list, routes by connection type (pushWindow)
│   ├── ConnectionFormView.swift        — Add/edit form, seeded from ConnectionDefaults
│   ├── SettingsView.swift              — New-connection defaults (@AppStorage)
│   ├── ConsoleView.swift               — Log viewer (tab + "console" pop-out window)
│   ├── AudioStreamView.swift           — Audio mini player (album art, transport, mute, utility row)
│   ├── NativeStreamView.swift          — Transparent desktop scene + manual per-window picker
│   ├── MacNativeUnityControlView.swift — Unity inventory reconciler, scene switcher, desktop/session controls
│   ├── NativeWindowStreamView.swift    — One chrome-free scene per streamed host window (Unity-style)
│   ├── HomeOrnamentModifier.swift      — Home ornament for sub-windows (opens id "main")
│   ├── RemoteDesktopView.swift         — VNC framebuffer display + gestures + toolbar
│   ├── VirtualKeyboardView.swift       — Our own on-screen key grid + modifier latches
│   ├── KeyboardInputView.swift         — VNC keyboard window (key grid, route picker, dictation)
│   ├── HardwareKeyboardView.swift      — VNC hardware keyboard capture (UIViewRepresentable)
│   ├── CredentialPromptView.swift      — VNC auth prompt sheet
│   ├── ThirdPartyNoticesView.swift     — Parses THIRD_PARTY_NOTICES.md by H2 headings
│   ├── MoonlightPairingView.swift      — Pairing flow, PIN display, app picker, launch
│   ├── MoonlightStreamView.swift       — Stream display, gesture input, controls ornament
│   ├── MoonlightKeyboardView.swift     — Moonlight keyboard window (key grid, Ctrl+Alt+Del)
│   ├── MoonlightHardwareKeyboardView.swift — Moonlight hardware keyboard capture
│   └── StreamStatsOverlay.swift        — Live stats HUD (codec, FPS, RTT, decode time, drops)
├── Foveated/                           — PCVR, all of it behind FOVEATED_ENABLED (= the Pro edition)
│   ├── FoveatedEndpoint.swift          — Endpoint validation and mode → endpoint mapping
│   ├── FoveatedStreamingMock.swift     — Stand-in session for the simulator (no framework there)
│   ├── PCVRStore.swift                 — StoreKit 2 entitlements: $1.99/mo or $24.99 once
│   └── PCVRSessionLimiter.swift        — 20-minute trial clock, warnings, and the cutoff
├── MacNative/
│   ├── MacNativeStreamClient.swift     — TLS-PSK framed native stream receiver
│   └── MacNativeVideoRenderer.swift    — hvc1 (±alpha) format reconstruction and display
├── Moonlight/
│   ├── MoonlightStreamBridge.swift     — C callback → Swift marshalling, global renderer refs
│   ├── MoonlightVideoRenderer.swift    — AVSampleBufferDisplayLayer H.264/HEVC/AV1 + HDR
│   ├── MoonlightAudioRenderer.swift    — Opus multistream → AVAudioEngine
│   ├── MoonlightGamepadManager.swift   — GameController framework → LiSendMultiControllerEvent
│   ├── MoonlightKeyCodes.swift         — UIKeyboardHIDUsage → Windows VK code mapping
│   ├── MoonlightModels.swift           — ServerInfo, MoonlightApp, StreamConfig, StreamStats
│   ├── NvHTTPClient.swift              — GameStream HTTP API (NWConnection, XML parsing)
│   ├── NvPairingManager.swift          — Challenge-response pairing handshake
│   └── CryptoManager.swift             — X.509, PKCS#12, AES-128-ECB, RSA (CommonCrypto)
├── Utilities/
│   ├── AppLog.swift                    — os.Logger per category + Logger.line() helper
│   ├── ConnectionDefaults.swift        — UserDefaults keys/getters for new-connection defaults
│   ├── GitHubDeviceFlow.swift          — GitHub OAuth device flow → Copilot token (in-app, no Mac involvement)
│   ├── ClaudeOAuth.swift               — Claude Code OAuth PKCE flow → full-scope token (constants extracted from the CLI binary)
│   ├── ClaudeCredentialStore.swift     — Keychain home for the Claude credential bundle + refresh-before-launch
│   ├── VirtualKeyboard.swift           — On-screen keyboard model: keys, US layout, modifier latches
│   ├── VNCVirtualKeyboardSink.swift    — Key + modifiers → VNC keysyms (pure `events()`, unit-tested)
│   ├── MoonlightVirtualKeyboardSink.swift — Key + modifiers → Windows VK codes + modifier mask
│   ├── SSHVirtualKeyboardSink.swift    — Key + modifiers → PTY bytes (⌃G → 0x07), unit-tested
│   └── GestureTranslator.swift         — View-to-framebuffer coordinate mapping (VNC)
├── Assets.xcassets/                    — App icon (solidimagestack, 1024x1024 @2x)
└── Info.plist                          — NSLocalNetworkUsageDescription, multi-scene

Shared/                                 — compiled into BOTH targets (visionOS app + macOS companion)
├── AudioStreamProtocol.swift           — Wire protocol v6 (int24 PCM via PCM24), NowPlayingInfo, MediaCommand
├── MacNativeStreamProtocol.swift       — Native stream framing: v2 capabilities, window inventory, multiplexed streams, input
├── MacNativeVideoCapability.swift      — Hardware HEVC 4:2:2 decode probe (drives the desktop stream's chroma)
├── MacNativeStreamCrypto.swift         — Domain-separated native-stream TLS-PSK parameters
└── BroadcastSetupURL.swift             — longwave://…/setBroadcastServer pairing payload (host/creds/cert fingerprint)

LongwaveiOS/                            — iPhone/iPad client (LongwaveiOS target); reuses Longwave/ +
│                                         Shared/ via a membership exception set. No Moonlight (its
│                                         deps aren't linked), no PCVR (visionOS entitlement), no
│                                         Broadcast (a visionOS extension capturing a room).
├── MobileApp.swift                     — @main; one WindowGroup instead of visionOS's scene-per-surface
├── MobileAppDelegate.swift             — Local Network prompt + TextInputActivity (no window summoning)
├── MobileRootView.swift                — Five-tab shell; presents covers off manager state, since shared
│                                         views' openWindow(id:) calls are no-ops in a single-scene app
├── MobileRemoteDesktopView.swift       — Touch VNC: fit/zoom/pan, absolute + relative pointer mapping
├── MobilePointerSurface.swift          — UIKit recognizers (SwiftUI can't tell 1 finger from 2):
│                                         tap/2-finger tap/drag/2-finger scroll/pinch/3-finger pan
├── MobileKeyboardAccessory.swift       — Modifier strip over the system keyboard; resolves a typed
│                                         glyph back to its physical key so ⌃/⌥/⌘ can apply to it
├── MobileVirtualKeyboardSheet.swift    — Scales the shared ANSI grid to a portrait width
├── MobileAudioView.swift               — Audio tab: shared player panel minus the window-only chrome
├── Assets.xcassets/                    — iOS AppIcon (appiconset; the visionOS icon is layered) + accent
└── Info.plist                          — Single-scene, landscape allowed, background audio

BroadcastCore/                          — compiled into BOTH the app and the broadcast extension
├── BroadcastShared.swift               — app-group config/keychain bridge + broadcastLog (AppLog is app-only)
├── RTPPacketizer.swift                 — RTP/RTCP framing, H.264 RFC 6184 + Opus RFC 7587 (unit-tested)
├── SDPBuilder.swift                    — ANNOUNCE SDP from live SPS/PPS (unit-tested)
├── RTSPPublisher.swift                 — RTSP record client over NWConnection, interleaved RTP, Basic auth
├── BroadcastVideoEncoder.swift         — VTCompressionSession H.264 (realtime, no B-frames, 1 s GOP)
└── BroadcastAudioEncoder.swift         — AVAudioConverter → native Opus (PCM-buffer + CMSampleBuffer entry points)

BroadcastExtension/                     — LongwaveBroadcast target (ReplayKit broadcast upload extension)
└── SampleHandler.swift                 — Mirror My View + mic → BroadcastCore pipeline → mediamtx

CompanionMac/                           — macOS menu bar companion target (LongwaveCompanion)
├── CompanionApp.swift                  — MenuBarExtra (slim quick-controls popover) + Settings scene + AudioStreamerController
├── CompanionWindowView.swift           — multi-pane companion window (sidebar + grouped forms: audio/token/broadcast/SSH/keyboard); Settings scene keeps the app menu-bar-only (no auto-open at launch), activation policy flips .regular↔.accessory with the window
├── AudioStreamServer.swift             — Single-client TCP server, metadata replay, command rx
├── MacNativeStreamingController.swift  — Enable state, capture/server lifecycle, takeover notifications
├── MacNativeStreamServer.swift         — Single authenticated newest-viewer-wins server + Bonjour
├── MacNativeScreenCapture.swift        — Whole-display ScreenCaptureKit capture (opaque)
├── MacNativeWindowStreams.swift        — Per-window streamers + inventory coordinator (Unity-style)
├── MacHEVCEncoder.swift                — Realtime VideoToolbox HEVC encoder (alpha for windows, opaque for the desktop)
├── MacNativeStreamNotifications.swift  — Foreground-capable connection/takeover notifications
├── SystemAudioTap.swift                — Core Audio process tap
├── NowPlayingCoordinator.swift         — Single now-playing source: prefers MediaRemote, falls back to AppleScript (arbitrates on which backend reports a track)
├── MediaRemoteBridge.swift             — System-wide now playing via the perl-hosted helper (spawn/parse/restart) — every player, artwork included
├── MusicAppBridge.swift                — Fallback: Music.app only, metadata/control (notifications + AppleScript); no artwork for Apple Music streaming
├── NowPlayingArtwork.swift             — Shared artwork scaling/JPEG re-encode (≤600 px)
├── BroadcastServerManager.swift        — one-button mediamtx setup (cert/password gen, managed config, brew restart, pairing URL) + one-click OBS scene provisioning
├── OBSWebSocketClient.swift            — minimal obs-websocket v5 client (Hello/Identify challenge auth, Browser Source create/update + visibility/stacking enforcement)
└── Info.plist                          — NSAudioCaptureUsageDescription, NSAppleEventsUsageDescription

MediaRemoteHelper/                      — system-wide now-playing reader, loaded by /usr/bin/perl (NOT in any Xcode target)
├── longwave-mediaremote.m               — dlopens MediaRemote, streams NDJSON metadata + artwork; XS entry points
└── README.md                            — why the perl host is required, and the dyld-loader-lock trap

CompanionWindows/                       — Longwave Companion (PoC; separate Node + .NET codebase)
├── backend/                            — .NET 8 worker: Hotspot AP+NAT and native window/desktop streaming, via an ACL'd named-pipe JSON-RPC server (the Foveated/CloudXR host is a separate process — see Longwave-PCVR-Host/)
├── app/                                — Electron UI: Hotspot status / "Join from Vision Pro", plus PCVR and Game library panels that download the closed-source host on demand
├── spike/                              — Step-1 capability spike + SPIKE-FINDINGS.md (decision record)
└── README.md                           — build/run/architecture/protocol

LongwaveTests/                         — app-hosted XCTest target (run locally, no CI)
├── TextDiffTests.swift                 — keyboard common-prefix diff
├── CompanionInjectProtocolTests.swift  — inject framing / drain / backspace
├── SavedConnectionEnvTests.swift       — SSH env parsing + name validation
├── SavedConnectionNativeTests.swift    — Native Unity persistence defaults
├── MacNativeStreamProtocolTests.swift  — Native hello/video framing and partial-frame draining
├── LocalNetworkTests.swift             — Windows-ICS subnet inference for host auto-prefill
└── PCVRSessionLimiterTests.swift       — Trial clock edges (needs FOVEATED_ENABLED to compile)


scripts/
├── edition-settings.sh                 — The ONLY definition of oss / oss-moonlight / pro
├── setup-deps.sh                       — Clone+patch repos/ deps (local Moonlight builds)
├── build-and-sign.sh                   — Config-driven device build/sign/deploy (build-signing.conf, gitignored)
├── install-companion.sh                — Build the macOS companion + install to /Applications (quit/relaunch)
├── build-mediaremote-helper.sh          — Universal build+sign of MediaRemoteHelper/ (script phase on both mac targets)
└── release.sh                          — Local Moonlight-enabled GitHub release (gh CLI)

ci/
├── deps/
│   ├── moonlight-common-c/Package.swift — SPM wrapper (MoonlightCommonC + enet targets)
│   └── opus/
│       ├── Package.swift               — SPM wrapper for Opus C library
│       ├── include/module.modulemap    — Exposes multistream API
│       └── spm-config/config.h         — Build configuration
├── patches/
│   ├── royalvnc-longwave.patch              — Static linking + Longwave API additions (KEEP IN SYNC with repos/royalvnc)
│   ├── moonlight-common-c-commoncrypto.patch — Replace OpenSSL with CommonCrypto
│   ├── moonlight-common-c-fec-fix.patch      — Audio FEC crash fix
│   ├── moonlight-common-c-audio-fec-fix.patch — Newer Sunshine compat
│   ├── opus-spm-umbrella.patch               — Multistream header exposure
│   └── opus-x86_64-universal.patch           — ARM NEON sources no-op on x86_64 (universal macOS targets)
```
