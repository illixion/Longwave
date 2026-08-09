# Longwave — Claude Code Context

## Overview

Longwave is a remote desktop and game streaming app for **visionOS** built in Swift. It supports VNC, Moonlight game streaming, system audio streaming, SSH terminal + remote agents, RTSP broadcast, and foveated PCVR streaming:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C library) with H.264/HEVC/AV1 hardware decoding, HDR10, Opus audio
3. **Audio** — Uncompressed streaming from macOS Companion (`LongwaveCompanion` target) with Music.app now-playing metadata + transport control
4. **SSH / Remote Agents** — Built-in SSH terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT + [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) Apache-2.0) plus a Projects tab that drives Claude Code / GitHub Copilot / custom CLI agents over SSH (tmux-backed). Tokens injected per agent, per connection, from Vision Pro keychain (macOS Keychain unreachable over SSH). Claude and Copilot both sign in **on the headset** — Claude through an in-app browser running its OAuth PKCE flow (`ClaudeOAuth`), Copilot through GitHub's device flow (`GitHubDeviceFlow`).
5. **Broadcast** — H.264 + native Opus RTP/RTSP to mediamtx via tab (foreground) and ReplayKit extension (backgrounded). One-button server setup from companion, OBS provisioning via obs-websocket.
6. **Foveated Streaming / PCVR** — receives immersive OpenXR content from an NVIDIA CloudXR host (Windows + RTX) via Apple's `FoveatedStreaming` framework (visionOS 26.4+). Foveation happens **on the host, driven by real gaze** — not on device: the game itself renders foveated (gaze-driven VRS), which stock CloudXR cannot do because it hands games no eye tracking at all. Say this correctly in user-facing copy; it is the feature's differentiator. Lives in its own **PCVR tab** (`PCVRTabView`, `PCVRHelpView`), not in the connection list — settings persist as one `ConnectionType.foveated` `SavedConnection` the tab owns. `FoveatedConnectionManager` + an `ImmersiveSpace(foveatedStreaming:)`. `FoveatedConnectionMode` offers Automatic (Bonjour) and By IP address only; Apple's `.remote` endpoint case is deliberately not exposed (its server list is baked into Info.plist at build time). Accompanied by a Windows CloudXR session-management host (`Longwave-PCVR-Host/`, closed-source, git submodule) and a Switch Pro + hand-gesture → controller bridge (`Longwave/ControllerBridge/` → `OpenXRLayer/`, an implicit OpenXR API layer on the host, also a closed-source git submodule alongside `SessionBroker/`) presenting emulated Valve Index controllers; transport is the session MessageChannel (opaque data channel), UDP `cb_input_state_t` as fallback. A physical controller's IMU is attributed to whichever hand is holding it (client-side correlation of angular speeds) and drives grip velocity plus dead-reckoning through hand-tracking dropouts. Real gaze — unreachable through any OpenXR API on this runtime, so read out of `CloudXrService` — drives gaze-driven VRS, reaches games as `XR_EXT_eye_gaze_interaction` (primarily by feeding VDXR's own implementation through Virtual Desktop's `BodyState`; the API layer publishes the extension itself as a fallback), and, opt-in, drives VRChat's OSC eye-look override. None of the three closed-source submodules ship in the public Windows Companion installer; the Electron UI downloads and installs the matching bundle on demand from a GitHub Release asset (`pcvr-installer.js`, `scripts/package-pcvr-bundle.sh`) so there is one public download, not two.

**Companions** (host side): **macOS Companion** (`LongwaveCompanion`, `CompanionMac/`) — audio / now-playing / keyboard injection / SSH keys; **Longwave Companion** (`CompanionWindows/`, PoC) — Hotspot NAT for the headset and the CloudXR foveated streaming host.

**Optional build features:** `MOONLIGHT_ENABLED` (off = pure VNC viewer) and `FOVEATED_ENABLED` (PCVR; default off, device-only, 26.4+).

See [[ARCHITECTURE.md]] for multi-window design, threading patterns, and data pipelines; `Longwave-PCVR-Host/docs/FOVEATED_STREAMING_ARCH.md` for the full PCVR design (CloudXR host, controller bridge, gesture input, OpenXR API layer, verification status). That document lives inside the private submodule along with `FOVEATED_STREAMING_PLAN.md` and `HOST_PROVISIONING.md` — a checkout without the submodule initialised simply won't have them.

## Build Configuration

- **Platform:** visionOS 26.2+, Swift 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types implicitly @MainActor)
- **RoyalVNCKit:** Local SPM from `repos/royalvnc/` with local mods (static linking, JPEG quality/compression, framebuffer pause/resume). **Re-export the patch after edits** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-longwave.patch` — or CI builds fail.
- **Dependencies:** moonlight-common-c, Opus (local SPM packages in `repos/`, wrapped in `ci/deps/`). `MOONLIGHT_ENABLED` compilation condition gates all Moonlight code.
- **FOVEATED_ENABLED:** gates all Foveated/PCVR code (default off, device-only). Build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FOVEATED_ENABLED'` + `XROS_DEPLOYMENT_TARGET=26.4` — **keep `$(inherited)`** or swift-crypto's BoringSSL exclusion breaks. Simulator uses `Foveated/FoveatedStreamingMock.swift`; runtime needs the `com.apple.developer.foveated-streaming-session` entitlement.
- **CI:** Builds two IPAs on one runner (`.github/workflows/build.yml`): MIT IPA (moonlight/opus stubbed), then Moonlight IPA (with real deps + MOONLIGHT_ENABLED). Local builds use `scripts/setup-deps.sh` (idempotent, applies six CI patches).

See [[FILE_STRUCTURE.md]] for directory layout and [[KNOWN_CONSTRAINTS.md]] for build gotchas (arch settings, SwiftData migrations, window APIs).

## Testing

Unit tests in `LongwaveTests/` (XCTest, visionOS, run locally — no CI test job):

```
xcodebuild test -scheme LongwaveTests -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5'
```

Coverage: `TextDiff`, `CompanionInjectProtocol`, `SavedConnection` SSH env parsing + per-agent token resolution. `PBXFileSystemSynchronizedRootGroup`, so new `.swift` files auto-compile — no pbxproj edits needed.

## Critical Gotchas

**RoyalVNCKit patch sync:** After editing `repos/royalvnc/`, **re-export the patch** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-longwave.patch` — or CI builds fail to compile.

**SSH tokens:** macOS Keychain is unreachable over SSH. Solution: tokens stored in Vision Pro keychain (per-agent, per-connection) and injected inline into the tmux launch command. No `sshd_config` changes needed.

**Claude OAuth is an unsupported surface.** `ClaudeOAuth` drives Claude Code's own authorization-code + PKCE flow so the headset can mint a full-scope `CLAUDE_CODE_OAUTH_TOKEN` itself. This replaced sending the user to `claude setup-token`, which requests `user:inference` **only** — without `user:profile` an agent can't read the account's model entitlements. Every wire constant in `ClaudeOAuth.Constants` (client id, authorize/token URLs, scope list) was extracted from the installed `claude` binary, **not** a published spec, so treat upstream CLI updates as able to break it; re-extract with `strings -n 6 <binary> | grep -oE '.{600}CLIENT_ID:"[0-9a-f-]{36}".{500}'`. Three consequences worth remembering: the token endpoint takes a **JSON** body (a form body is rejected); refreshes must re-send the full `scope` list or the new token silently loses `user:profile`; and **the token by itself is not enough** — an env-var session assumes `user:inference` with no plan unless `CLAUDE_CODE_OAUTH_SCOPES` and `CLAUDE_CODE_SUBSCRIPTION_TYPE` accompany it (the latter fetched from `/api/oauth/profile`), otherwise the CLI reports the plan as "Claude API" and demands usage credits for models the subscription already covers. Full-scope tokens are short-lived (~8h) and a custom `expires_in` must **never** be sent — the server answers `400 custom expires_in not allowed for scope user:mcp_servers`, so asking for a longer token breaks sign-in outright rather than just being ignored. Instead `resolvedSSHEnvironmentRenewingCredentials(for:)` refreshes immediately before each launch and the tmux idle reaper clears sessions that outlive one. The sign-in sheet also watches the clipboard, because Claude's login emails a code *and* a magic link and neither can reach an embedded web view on its own — see the idle-teardown and login bullets in [[KNOWN_CONSTRAINTS.md]]. The login sheet shows the scopes the server actually granted, so a silent downgrade is visible rather than surfacing later as a permission error.

**Audio session handling:** Audio receiver has two modes (Speaker/Music). Speaker is mixable (coexists with VoIP), Music is exclusive (Now Playing app). Don't add `MPNowPlayingInfoCenter` to Speaker mode — it forces interrupting session. On VoIP interruption, only a fresh receiver (not engine rebuild) recovers. Set `setActive(true)` on every engine build.

**Build arch settings:** visionOS targets are arm64-only (project setting). SPM packages don't inherit this — use concrete simulator destinations (`platform=visionOS Simulator,name=Apple Vision Pro`) or pass `ARCHS=arm64` on the xcodebuild line. macOS targets are universal (arm64 + x86_64); the Opus patch guards ARM NEON sources on x86_64.

**Window APIs:** Use `dismissWindow(id:)` (not `dismiss()`) for `WindowGroup`. `navigationTitle` requires `NavigationStack`. visionOS refuses to close the app's last window. The main window is value-typed with a single constant identity (`MainWindowID.shared`) so every `openWindow(id: "main", value:)` reactivates the one instance instead of spawning duplicates. Connection windows open as plain siblings (`openWindow(id:)`, **not** `pushWindow`) so the main window coexists and surfacing one never dismisses the other; on teardown a window unconditionally re-surfaces main (a no-op when it's already up). Teardown must go through `WindowSessionRegistry.closeAfterSurfacingMain(using:_:)` — `openWindow` is async, so a `dismissWindow` in the same turn can still be evaluated as "closing the last window" and silently dropped; the helper waits for the main window's `onAppear` first.

**SwiftData migrations:** New non-optional properties need default values. Renamed columns need `@Attribute(originalName:)`. Missing either causes CoreData error 134110.

See [[KNOWN_CONSTRAINTS.md]] for detailed version of all gotchas (broadcast, Moonlight HDR, Copilot OAuth, etc.).

See [[API_REFERENCE.md]] for RoyalVNCKit and moonlight-common-c method signatures.
