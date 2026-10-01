# Longwave File Structure

```
Longwave/
├── LongwaveApp.swift                  — App entry and multi-window scene registration
├── Models/
│   └── SavedConnection.swift           — SwiftData model, ConnectionType, Moonlight settings enums
├── ViewModels/
│   ├── VNCConnectionManager.swift      — VNC connection bridge, @Observable
│   ├── AudioSessionCoordinator.swift   — Resolves the one process AVAudioSession across live receivers
│   ├── AudioStreamManager.swift        — Audio manager + AudioStreamReceiver (reconnect, mute, now-playing, Music-mode arbitration)
│   ├── MacNativeStreamManager.swift    — Native stream lifecycle, per-window sessions, display layer (all clients)
│   ├── MacNativeSessionStore.swift     — One Native session per saved connection; scene keys, per-session audio player
│   ├── MoonlightConnectionManager.swift — Moonlight orchestrator for one session, state machine, @Observable
│   └── MoonlightSessionStore.swift     — One Moonlight session per linked library copy; picks the session for a row, mirrors input focus
├── Views/
│   ├── MainView.swift                  — Main window: ornament tab bar (Connections/Settings/Console)
│   ├── ConnectionListView.swift        — Server list, routes by connection type (pushWindow)
│   ├── ConnectionFormView.swift        — Add/edit form, seeded from ConnectionDefaults
│   ├── SettingsView.swift              — New-connection defaults (@AppStorage)
│   ├── ConsoleView.swift               — Log viewer (tab + "console" pop-out window)
│   ├── AudioStreamView.swift           — Audio mini player (album art, transport, mute, utility row)
│   ├── NativeStreamView.swift          — visionOS desktop scene + manual per-window picker (Mac: LongwaveMac/MacNativeStreamWindowView, iOS: LongwaveiOS/MobileNativeStreamView)
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
│   ├── MacNativeStreamClient.swift     — TLS-PSK framed native stream receiver (all clients)
│   └── MacNativeVideoRenderer.swift    — hvc1 (±alpha) format reconstruction and display (all clients)
├── Moonlight/
│   ├── MoonlightLibrary.swift          — One linked copy of moonlight-common-c (slot, entry-point table, callback state) + MoonlightInputFocus
│   ├── MoonlightLibrarySlot0.swift     — Entry points of the unprefixed copy (Slot1/Slot2: the ml1_/ml2_ copies, raw pointers)
│   ├── MoonlightStreamBridge.swift     — C callback → Swift marshalling, one callback set per copy
│   ├── MoonlightVideoRenderer.swift    — AVSampleBufferDisplayLayer H.264/HEVC/AV1 + HDR
│   ├── MoonlightAudioRenderer.swift    — Opus multistream → AVAudioEngine
│   ├── MoonlightGamepadManager.swift   — GameController framework → LiSendMultiControllerEvent
│   ├── MoonlightKeyCodes.swift         — UIKeyboardHIDUsage → Windows VK code mapping
│   ├── MoonlightModels.swift           — ServerInfo, MoonlightApp, StreamConfig, StreamStats
│   ├── NvHTTPClient.swift              — GameStream HTTP API (NWConnection, XML parsing)
│   ├── NvPairingManager.swift          — Challenge-response pairing handshake
│   └── CryptoManager.swift             — X.509, PKCS#12, AES-128-ECB, RSA (CommonCrypto)
├── Utilities/
│   ├── AppLog.swift                    — DebugLogger per category + DebugTrace.configure at launch
│   ├── ConnectionDefaults.swift        — UserDefaults keys/getters for new-connection defaults
│   ├── VirtualKeyboard.swift           — On-screen keyboard model: keys, US layout, modifier latches
│   ├── VNCVirtualKeyboardSink.swift    — Key + modifiers → VNC keysyms (pure `events()`, unit-tested)
│   ├── MoonlightVirtualKeyboardSink.swift — Key + modifiers → Windows VK codes + modifier mask
│   ├── SSHVirtualKeyboardSink.swift    — Key + modifiers → PTY bytes (⌃G → 0x07), unit-tested
│   ├── GestureTranslator.swift         — View-to-framebuffer coordinate mapping (VNC)
│   ├── MacKeyCodeMap.swift             — HID usage ↔ macOS virtual keycode tables (raw ints, UIKit adapters) for the Native keyboard channel
│   ├── MacNativeVirtualKeyboardSink.swift — Key + modifiers → Native key frames, or text over the inject channel
│   └── DeviceName.swift                — The name a client introduces itself with (UIDevice / Host)
├── Assets.xcassets/                    — App icon (solidimagestack, 1024x1024 @2x)
└── Info.plist                          — NSLocalNetworkUsageDescription, multi-scene

Shared/                                 — compiled into every app target (visionOS, iOS, LongwaveMac, Companion)
├── AudioStreamProtocol.swift           — Wire protocol v6 (int24 PCM via PCM24), NowPlayingInfo, MediaCommand
├── MacNativeStreamProtocol.swift       — Native stream framing: v2 capabilities, window inventory, multiplexed streams, input
├── MacNativeVideoCapability.swift      — Hardware HEVC 4:2:2 decode probe (drives the desktop stream's chroma)
├── MacNativeStreamCrypto.swift         — Domain-separated native-stream TLS-PSK parameters
├── BroadcastSetupURL.swift             — longwave://…/setBroadcastServer pairing payload (host/creds/cert fingerprint)
├── PlatformGlass.swift                 — platformGlassBackground(): visionOS/iOS glass, no-op on macOS
└── Agents/                             — CLI agents and the Mac sandbox, platform-neutral (the Companion compiles these too)
    ├── SSHAgent.swift                  — Claude / Copilot / Codex / Custom: commands, default and sandbox flags, env names, setup copy
    ├── AgentCredentialHost.swift       — Per-agent tokens + Claude/Codex credentials → session environment (SavedConnection and the Companion's sandbox account conform)
    ├── AgentSetupSheet.swift           — Per-agent sign-in sheet (in-app Claude OAuth, device flows, paste), generic over the host
    ├── ClaudeLoginWebView.swift        — Embedded Claude consent page + clipboard watch for the emailed code
    ├── GitHubDeviceFlow.swift          — GitHub OAuth device flow → Copilot token (in-app, no Mac involvement)
    ├── ClaudeOAuth.swift               — Claude Code OAuth PKCE flow → full-scope token (constants extracted from the CLI binary)
    ├── ClaudeCredentialStore.swift     — Keychain home for the Claude credential bundle + refresh-before-launch
    ├── CodexOAuth.swift                — Codex CLI's ChatGPT device sign-in → session-only auth.json (constants from openai/codex source)
    ├── CodexCredentialStore.swift      — Keychain home for the Codex credential (rotating refresh token stays on device)
    ├── AgentSessionCommands.swift      — tmux create/attach, stdin env payload, reaper, discovery builders (shared with the Mac, which lacks SSHTerminalManager)
    ├── LocalSandbox.swift              — Mac agent sandbox: helper argv + status JSON, exchange import/fetch, clone script, Terminal attach (pure, tested)
    ├── OpenSSHPrivateKey.swift         — Unencrypted OpenSSH ed25519 key file → NIOSSHPrivateKey (the Mac's sandbox key)
    ├── AgentSchedule.swift             — Scheduled runs: cadence/next-fire, overlap + daily cap, runtime cap, headless pane command, progress/transcript parsing (pure, tested)
    ├── SSHConnection.swift             — swift-nio-ssh PTY session + one-shot command runner (stdin + EOF for the create channel)
    ├── KeychainStore.swift             — Generic-password keychain helper for small secrets
    └── Pasteboard.swift                — UIPasteboard / NSPasteboard text copy

LongwaveiOS/                            — iPhone/iPad client (LongwaveiOS target); reuses Longwave/ +
│                                         Shared/ via a membership exception set. Moonlight included
│                                         (MOONLIGHT_ENABLED is baked into the target). No PCVR
│                                         (visionOS entitlement), no Broadcast (a visionOS extension
│                                         capturing a room).
├── MobileApp.swift                     — @main; one WindowGroup instead of visionOS's scene-per-surface
├── MobileAppDelegate.swift             — Local Network prompt + TextInputActivity (no window summoning)
├── MobileRootView.swift                — Five-tab shell; presents covers off manager state, since shared
│                                         views' openWindow(id:) calls are no-ops in a single-scene app
├── MobileRemoteDesktopView.swift       — Touch VNC: absolute + relative pointer mapping over MobileViewport
├── MobileNativeStreamView.swift        — Touch Native desktop stream: same touch model, both keyboard channels, audio sheet
├── MobileViewport.swift                — Zoom/pan + view↔surface mapping shared by the VNC and Native views (render == hit-test)
├── MobileMoonlightStreamView.swift     — Touch Moonlight: direct/touchpad pointer, two-finger scroll, keyboard strip, stats
├── MobilePointerSurface.swift          — UIKit recognizers (SwiftUI can't tell 1 finger from 2):
│                                         tap/2-finger tap/drag/2-finger scroll/pinch/3-finger pan
├── MobileKeyboardAccessory.swift       — Modifier strip over the system keyboard; resolves a typed
│                                         glyph back to its physical key so ⌃/⌥/⌘ can apply to it
├── MobileStreamChrome.swift            — The bottom capsule shared by all three streams: 44-pt hit
│                                         targets, swallows taps between buttons (else they zoom)
├── MobileVirtualKeyboardSheet.swift    — Scales the shared ANSI grid to a portrait width
├── MobileAudioView.swift               — Audio tab: shared player panel minus the window-only chrome
├── Assets.xcassets/                    — iOS AppIcon (appiconset; the visionOS icon is layered) + accent
└── Info.plist                          — Single-scene, landscape allowed, background audio

CompanionMac/Projects/                  — The Companion's Projects window: agents run as the local
│                                         sandbox account (scripts/agent-sandbox), attached in Terminal.app
├── MacProjectsView.swift               — Sandbox status/actions, onboarding, agent sign-in, projects, sessions, firewall
├── LocalSandboxController.swift        — `sudo -n longwave-sandbox …`, keychain password, SSH runner, import/fetch/launch
├── FullDiskAccessAssistant.swift       — Opens the FDA pane with a floating panel of the app icon to drag into the list
├── SandboxAgentAccount.swift           — The sandbox's AgentCredentialHost (keychain tokens, UserDefaults settings, no SwiftData)
├── SandboxSessionKeeper.swift          — Headless loopback ARD VNC login → persistent GUI session (one attempt, never abandoned)
├── LocalScheduler.swift                — Fires schedules while the app runs: reset, headless run, monitor, transcript, notification
├── ScheduleModels.swift                — `ScheduledRun` / `RunRecord` SwiftData models in their own Schedules.store
└── MacSchedulesView.swift              — Schedules section, run history, editor sheet, `PlainTextEditor`

BroadcastCore/                          — compiled into BOTH the app and the broadcast extension
├── BroadcastShared.swift               — app-group config/keychain bridge + broadcastLogger (AppLog is app-only)
├── RTPPacketizer.swift                 — RTP/RTCP framing, H.264 RFC 6184 + Opus RFC 7587 (unit-tested)
├── SDPBuilder.swift                    — ANNOUNCE SDP from live SPS/PPS (unit-tested)
├── RTSPPublisher.swift                 — RTSP record client over NWConnection, interleaved RTP, Basic auth
├── BroadcastVideoEncoder.swift         — RTP shape of RAVESDK's RAVEH264Encoder: NAL split + in-band SPS/PPS on IDRs
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
├── AgentScheduleTests.swift            — Schedule cadence (DST, weekdays), overlap/daily cap, runtime cap, no prompt/token in argv
└── PCVRSessionLimiterTests.swift       — Trial clock edges (needs FOVEATED_ENABLED to compile)


scripts/
├── edition-settings.sh                 — The ONLY definition of oss / oss-moonlight / pro
├── setup-deps.sh                       — Clone+patch repos/ deps (local Moonlight builds)
├── verify-moonlight-instances.sh       — Checks the built objects: every copy fully prefixed, rename list complete (--regenerate)
├── build-and-sign.sh                   — Config-driven device build/sign/deploy (build-signing.conf, gitignored)
├── install-companion.sh                — Build the macOS companion + install to /Applications (quit/relaunch)
├── build-mediaremote-helper.sh          — Universal build+sign of MediaRemoteHelper/ (script phase on both mac targets)
└── release.sh                          — Local Moonlight-enabled GitHub release (gh CLI)

ci/
├── deps/
│   ├── moonlight-common-c/Package.swift — SPM wrapper (MoonlightCommonC + enet, plus the prefixed MoonlightCommonC1/2 copies)
│   ├── moonlight-common-c/make-instances.sh — Lays the prefixed copies out in a checkout (shims that #include the real sources)
│   ├── moonlight-common-c/ml_redefine_symbols.h — Generated `#pragma redefine_extname` list, one line per external symbol
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
