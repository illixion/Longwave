# Longwave — Claude Code Context

## Overview

Longwave is a remote desktop and game streaming app for **visionOS** built in Swift. It supports VNC, Moonlight game streaming, system audio streaming, SSH terminal + remote agents, RTSP broadcast, and foveated PCVR streaming:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C library) with H.264/HEVC/AV1 hardware decoding, HDR10, Opus audio
3. **Audio** — Uncompressed streaming from macOS Companion (`LongwaveCompanion` target) with **system-wide** now-playing metadata + artwork + transport control. Read from the private MediaRemote framework via an Apple-signed perl host (`MediaRemoteHelper/`), so it covers every player — Apple Music streaming, Spotify, browser video — not just Music.app; AppleScript against Music.app remains the fallback. See `MediaRemoteHelper/README.md`.
4. **SSH / Remote Agents** — Built-in SSH terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT + [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) Apache-2.0) plus a Projects tab that drives Claude Code / GitHub Copilot / OpenAI Codex / custom CLI agents over SSH (tmux-backed). Tokens injected per agent, per connection, from Vision Pro keychain (macOS Keychain unreachable over SSH). Claude, Copilot and Codex all sign in **on the headset** — Claude through an in-app browser running its OAuth PKCE flow (`ClaudeOAuth`), Copilot through GitHub's device flow (`GitHubDeviceFlow`), Codex through the CLI's own ChatGPT device flow (`CodexOAuth`), delivered to the host as a session-only `auth.json` because the CLI reads ChatGPT credentials from no environment variable.
5. **Broadcast** — H.264 + native Opus RTP/RTSP to mediamtx via tab (foreground) and ReplayKit extension (backgrounded). One-button server setup from companion, OBS provisioning via obs-websocket.
6. **Foveated Streaming / PCVR** — receives immersive OpenXR content from an NVIDIA CloudXR host (Windows + RTX) via Apple's `FoveatedStreaming` framework (visionOS 26.4+). The game's own rendering is foveated **on the host** with VRS **fixed at the centre of each view**. Gaze-driven host foveation is planned through Apple's foveated streaming provider (visionOS 27); until then user-facing copy must not claim the PC renders by your gaze. Lives in its own **PCVR tab** (`PCVRTabView`, `PCVRHelpView`), not in the connection list — settings persist as one `ConnectionType.foveated` `SavedConnection` the tab owns. `FoveatedConnectionManager` + an `ImmersiveSpace(foveatedStreaming:)`. `FoveatedConnectionMode` offers Automatic (Bonjour) and By IP address only; Apple's `.remote` endpoint case is deliberately not exposed (its server list is baked into Info.plist at build time). Accompanied by a Windows CloudXR session-management host (`Longwave-PCVR-Host/`, closed-source, git submodule) and a Switch Pro + hand-gesture + tracked-controller → controller bridge (`Longwave/ControllerBridge/` → `OpenXRLayer/`; PSVR2 Sense and Quest Touch come from RAVEInput's `RAVESpatialAccessorySource`/`RAVEQuestBridgeSource` — a desk Quest streams to the **headset**, which aligns it to ARKit and forwards it, and the Info.plist's local-network string and `_controllerbridge._udp` Bonjour entry exist for that listener — an implicit OpenXR API layer on the host, also a closed-source git submodule alongside `SessionBroker/`) presenting emulated controllers — on VDXR, the OpenXR runtime games use on this host, the runtime itself presents them as Valve Index controllers fed by the host; on other runtimes the API layer presents them (Oculus Touch profile preferred so games use their Quest bindings, Valve Index as fallback; `LONGWAVE_CB_PROFILE` overrides). The host and controller-bridge internals are intentionally not detailed here — see the private submodule's docs below. None of the three closed-source submodules ship in the public Windows Companion installer; the Electron UI downloads and installs the matching bundle on demand from a GitHub Release asset (`pcvr-installer.js`, `scripts/package-pcvr-bundle.sh`) so there is one public download, not two.

**Clients**: the **visionOS app** (`Longwave/`) is the product; **LongwaveMac** (`LongwaveMac/`) and **LongwaveiOS** (`LongwaveiOS/`) are separate targets that reuse `Longwave/` + `Shared/` and supply their own scene graph. See "Platform clients" below.

**KVM dongle** (`Firmware/kvm-dongle/`, ESP-IDF + NimBLE, classic ESP32 over a CH340 UART bridge): a BLE HID keyboard + mouse + consumer-control device the Vision Pro pairs with like any Bluetooth keyboard, fed HID reports from the Mac over USB serial (`PROTOCOL.md`, 460800 baud — the CH340 cannot do 921600). It exists because visionOS has no input-injection API for apps; this is the only route for Mac → headset keyboard/pointer. `tools/kvmctl.py` drives it from the shell, and the macOS Companion's **KVM** tab (`CompanionMac/KVM*.swift`) is the real client: a CGEventTap swallows this Mac's keyboard, pointer and media keys and relays them as HID reports, with ⌃⌥⌘K toggling capture from either side. Three things bite. The report descriptor is frozen once shipped — visionOS caches it at pairing time. The headset subscribes to the report characteristics on its own schedule, so "connected and encrypted" does not mean input arrives: the subscription bits do, and they do not all arrive together. And ordering is the whole game on a keyboard, which is why the link is a serial `DispatchQueue` rather than an actor (an actor's reentrancy would let a release frame overtake its press) and why key reports queue whole while pointer motion coalesces.

**Companions** (host side): **macOS Companion** (`LongwaveCompanion`, `CompanionMac/`) — audio / now-playing / keyboard injection / SSH keys / the agent sandbox (Projects, schedules); **Longwave Companion** (`CompanionWindows/`, PoC) — Hotspot NAT for the headset and the CloudXR foveated streaming host.

## Editions

Three builds of one target, defined solely by `scripts/edition-settings.sh` — read it before assembling flags by hand, and put anything new in it rather than beside it:

| edition | identifier | conditions | ships |
|---|---|---|---|
| `oss` | `pro.longwave.oss` | — | unsigned IPA on GitHub (MIT) |
| `oss-moonlight` | `pro.longwave.oss` | `MOONLIGHT_ENABLED` | unsigned IPA on GitHub (GPLv3) |
| `appstore` | `pro.longwave.app` | `FOVEATED_ENABLED`, 26.4 | App Store only |

All three are called "Longwave"; the edition is how it is distributed, not a different product. `oss` and `oss-moonlight` share an identifier because they are the same app built twice; `appstore` differs so a sideloaded copy and an App Store install coexist.

**Every line of visionOS source here is MIT, PCVR included** — `Longwave/Foveated/`, `Longwave/ControllerBridge/` and the `Foveated*`/`PCVR*` views are public and compiled by public CI on every push. Do not describe PCVR as closed-source: only its **Windows host** halves are (the three private submodules), and the Xcode project does not reference them at all.

Why the two builds differ:
- Moonlight is absent from `appstore` because moonlight-common-c is GPLv3 and the GPL is incompatible with App Store terms.
- PCVR is absent from `oss` because **`com.apple.developer.foveated-streaming-session` is a paid-Apple-Developer-account capability** — a free-Apple-ID sideload cannot run it whatever the flags say. Secondary: 26.4 vs the 26.2 floor, and StoreKit needing an App Store receipt.

`LONGWAVE_BUNDLE_ID` and `LONGWAVE_DISPLAY_NAME` are **project-level** build settings that the app and the broadcast extension both derive from — override the one variable and the extension follows the app instead of being stranded under the old prefix. `LONGWAVE_APP_ENTITLEMENTS` is the opposite case: the **app target alone** reads it, so `appstore` can sign the app with `Longwave-Foveated.entitlements` (the foveated-streaming-session capability) without a command-line `CODE_SIGN_ENTITLEMENTS` also landing on the extension, whose App ID lacks it.

**Shipping the App Store edition:** `scripts/archive-appstore.sh` (archive + export, `--upload`, `--dry-run`, `--unsigned`) is the only path — build number `git rev-list --count HEAD`, team from the conf's `TEAM_ID` line only (never sourced), and it refuses on `PCVR_UNLOCKED`/`LONGWAVE_INTERNAL` in the resolved settings or a `check-app-strings.sh` hit. It is independent of the dev-deploy pipeline, which unlocks PCVR on purpose. The account-holder steps are in `docs/TESTFLIGHT_CHECKLIST.md`; reviewer text in `docs/APP_REVIEW_NOTES.md` (public — no internal features); `Configuration/Longwave.storekit` mirrors the two products for local StoreKit testing (select it in the scheme's Run → Options). Developer-only PCVR surfaces (hand-alignment tuning, the sent-skeleton overlay, plaintext bridge opt-in) are `#if DEBUG`.

**PCVR is the only paid thing.** Trial sessions run 20 minutes (`PCVRSessionLimiter`), warned at 5 min and 1 min by a banner entity in the immersive space, then the running title is stopped and the stream ends. $1.99/month or $24.99 once, via StoreKit 2 (`PCVRStore`, `PCVRPaywallView`). Three rules the code depends on: only `.connected` time counts; pausing *holds* the clock rather than rewinding it; and the clock never runs until StoreKit has answered (`unlock` is a double Optional so "nothing owned" and "not known yet" cannot be confused). All of it is inside `FOVEATED_ENABLED`, so the open-source editions contain no purchase code at all. Dev builds add `PCVR_UNLOCKED` (set in the local `build-signing.conf`, so `bas` sideloads carry it): a sideload has no receipt and would sit in trial forever, so the flag makes `PCVRStore` report the lifetime unlock — never ship it.

**Optional build features:** `MOONLIGHT_ENABLED` (off = pure VNC viewer) and `FOVEATED_ENABLED` (PCVR; default off, device-only, 26.4+ — effectively "this is the App Store edition").

See [[ARCHITECTURE.md]] for multi-window design, threading patterns, and data pipelines; `Longwave-PCVR-Host/docs/FOVEATED_STREAMING_ARCH.md` for the full PCVR design (CloudXR host, controller bridge, gesture input, OpenXR API layer, verification status). That document lives inside the private submodule along with `FOVEATED_STREAMING_PLAN.md` and `HOST_PROVISIONING.md` — a checkout without the submodule initialised simply won't have them.

## Platform clients

Three app targets share one source folder. `Longwave/` and `Shared/` are attached
to each as `PBXFileSystemSynchronizedRootGroup`s with a **membership exception
set** naming the files that target excludes — so they all compile into one
module and each platform's own shims are visible to shared views without the
shared code knowing they exist.

| target | platform | scene model | excluded |
|---|---|---|---|
| `Longwave` | visionOS 26.2+ | window per surface (`openWindow`) | — |
| `LongwaveMac` | macOS 14.2+ | `MacMainView` + AppKit input | the in-app SSH terminal, Broadcast, Unity per-window scenes, and every host feature (those are the Companion's) |
| `LongwaveiOS` | iOS/iPadOS 26+ | one window; `MobileRootView` tab shell | PCVR, Broadcast, Unity per-window scenes |

Moonlight and the Native desktop stream (with audio and remote input) are on
all three; PCVR is visionOS-only by entitlement, Broadcast by hardware, and
Unity (one scene per host window) because it is a spatial idea. The Native
receiver (`MacNativeStreamClient`, `MacNativeVideoRenderer`,
`MacNativeStreamManager`, `MacKeyCodeMap`, the keyboard sink) is platform-
neutral; only the views differ: `NativeStreamView` on visionOS,
`MacNativeStreamWindowView` on macOS (NSEvents, kVK keycodes verbatim, the
HID inverse for Windows hosts), `MobileNativeStreamView` on iOS (touch, zoom
and pan via `MobileViewport`, shared with the VNC view).

**LongwaveMac is a client only; the host side is the Companion's.** LongwaveMac compiles
`Longwave/` + `Shared/` + `LongwaveMac/` and nothing from `CompanionMac/`, so the two run as
separate processes and never both bind the streaming ports. Install both with
`scripts/install-companion.sh` (Companion) and `scripts/install-companion.sh full` (LongwaveMac). On first launch the Companion copies host settings it doesn't have yet (pairing token, broadcast/OBS
passwords, sandbox projects) from LongwaveMac's defaults domain (`LongwaveMacSettingsMigration`),
so a Mac that used LongwaveMac as its host keeps its paired headsets.

**Projects on the Mac runs agents as a separate local account, from the Companion.**
`MacProjectsView` (Companion → Projects…) drives the agent sandbox from `scripts/agent-sandbox/`
(hidden `longwave-agent` user, fixed-verb root helper run via `sudo -n`, golden-home resets):
agents launch over SSH to `127.0.0.1` with install.sh's ed25519 file key, tokens on the create
channel's stdin exactly as on the headset (the builders are shared through `AgentSessionCommands`
in `Shared/Agents/`), and attach in Terminal.app. Credentials sit on `SandboxAgentAccount`, an
`AgentCredentialHost` like `SavedConnection` but without SwiftData, so it never appears in a
connection list or backup. `SandboxSessionKeeper` logs the agent into a GUI session over loopback
Screen Sharing (visionOS simulators need one) — one attempt, no automatic retries, and never
abandoned before the first frame, since a half-finished login leaves an orphaned `loginwindow`
that has frozen the owner's menu bar. The Companion has no VNC viewer: Sandbox Desktop opens
`longwave://sandbox-desktop`, which LongwaveMac handles; the other way, LongwaveMac's Projects entry
opens `longwave-companion://projects`, which launches the Companion if needed and brings its Projects
window forward (`handlesExternalEvents` on that scene). Projects move through
`/Library/Longwave/exchange` (import = push, return = fetch only). See the sandbox bullets in
[[KNOWN_CONSTRAINTS.md]]; task worktrees, sync back, the Projects protocol and shared memory are
planned in [[AGENT_SANDBOX_PLAN.md]].
**Schedules** (`LocalScheduler`, `MacSchedulesView`) fire recurring headless runs into a sandbox
project — `claude -p` / `codex exec` / `copilot -p`, or a plain shell command — **only while the
Companion runs** (optional "Open at login"; no daemon). Runs never overlap, obey a daily cap and a
runtime cap (the run's tmux session is killed), can reset the sandbox first, stay attachable while
running, and land as a transcript under `~/Library/Application Support/Longwave/runs/` plus a
notification. The prompt rides the create channel's stdin like the tokens. The agent can't schedule
itself (cron/at denied, Claude's self-scheduling tools denied — the tab warns if that deny list is
missing). Pure rules in `AgentSchedule` (tested); schedules live in their own SwiftData store.

**The scene graph is what does not port.** visionOS puts the desktop, every
terminal, every keyboard and the audio player in their own window; iPhone has
one. So `MobileRootView` drives presentation off *manager state* — a connection
going active, a new SSH session appearing — rather than off the button that was
pressed. Shared views keep calling `openWindow(id:)`, which is a no-op in a
single-scene app, and still end up with the right surface. Adding a shared view
that opens a window therefore needs no iOS change; adding one that *is* a window
does.

**Native sessions are per connection, like Moonlight's.** `MacNativeSessionStore`
keys one `MacNativeStreamManager` per saved connection and every Native scene —
the stream window, Unity Controls, the keyboard, each per-window scene — is
value-typed by `MacNativeSessionID`, so two hosts stream side by side. The
companion hosts match: a hello *joins* the viewer set instead of replacing it,
with one capture and one encode per stream fanned out and subscriptions
reference-counted. Audio is per session too — one `AudioStreamManager` each,
with its own target, volume, mode and live toggle — and the streams mix. The
one thing that cannot be shared is **Music mode**, which takes the audio
session exclusively and owns the app's single Now Playing entry: the manager
grants it to one player and runs every other one in Speaker mode, and
`AudioSessionCoordinator` resolves the process-wide `AVAudioSession` from the
whole set rather than letting the last receiver to start win. See the Native
and audio bullets in [[KNOWN_CONSTRAINTS.md]].

**Guards say what they mean.** SSH and the terminal settings read `!os(macOS)`,
not `os(visionOS)` — the Mac client is the one that drops them. Reach for
`os(visionOS)` only for something the other platforms genuinely lack, and check
the SDK before assuming: `setIntendedSpatialExperience` and
`setIsNowPlayingCandidate` sit inside `#if TARGET_OS_VISION` and are marked
`API_UNAVAILABLE(ios, …)`, so the Spatial Audio row is visionOS-only even though
iOS *has* spatial audio. `canImport(UIKit)` is the wrong guard for those: iOS
imports UIKit and has neither call.

**A local SPM package must declare iOS explicitly.** An omitted platform is not
an excluded one — SwiftPM substitutes its own ancient default floor, and
`RAVESDK`/`RAVEEngine` then failed an iOS build on "'Color' is only available in
iOS 13.0 or newer" and `OSSignposter` (iOS 15), versions nothing here targets.
Both now list `.iOS(.v26)`.

**Deploying to a phone or iPad.** `~/bin/build-and-sign` reads this repo's
gitignored `scripts/build-signing.conf`, which maps `PLATFORM` to a scheme —
because the clients are **separate targets**, not one target with several
destinations, so building `Longwave` for `generic/platform=iOS` fails on
supported platforms rather than producing an iOS app. `PLATFORM=iPad` is an
alias for the same iOS build sent to the iPad. Two things bite: the iOS and
macOS targets bake `MOONLIGHT_ENABLED` (and the moonlight-common-c + Opus links)
into their own build settings, so it is the visionOS scheme alone that takes the
flag on the command line — and `FOVEATED_ENABLED`/`XROS_DEPLOYMENT_TARGET` mean
nothing to the iOS target — so both the repo conf and `~/Projects/appstore`'s
`config.json` scope their build settings per platform. Consequently there is no
MIT edition of the iOS or macOS client: both link GPLv3 moonlight-common-c.

**Moonlight on a phone** is `MobileMoonlightStreamView` (touch model + chrome
over the same session objects); the shared `MoonlightStreamView` is excluded
from the iOS target because it is built around gaze, an ornament and its own
window. `MobileRootView` presents the stream as a full-screen cover off
`MoonlightSessionStore.activeSession`, one at a time, since the pairing sheet's
`openWindow(id: "moonlight-stream")` is a no-op there.

## Build Configuration

- **Platform:** visionOS 26.2+, Swift 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types implicitly @MainActor)
- **RoyalVNCKit:** Local SPM from `repos/royalvnc/` with local mods (static linking, JPEG quality/compression, framebuffer pause/resume, no clipboard polling on iOS). **Re-export the patch after edits** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-longwave.patch` — or CI builds fail.
- **Dependencies:** moonlight-common-c, Opus (local SPM packages in `repos/`, wrapped in `ci/deps/`). `MOONLIGHT_ENABLED` compilation condition gates all Moonlight code.
- **FOVEATED_ENABLED:** gates all Foveated/PCVR code (default off, device-only). Build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FOVEATED_ENABLED'` + `XROS_DEPLOYMENT_TARGET=26.4` — **keep `$(inherited)`** or swift-crypto's BoringSSL exclusion breaks. Simulator uses `Foveated/FoveatedStreamingMock.swift`; runtime needs the `com.apple.developer.foveated-streaming-session` entitlement.
- **CI:** Builds all three editions on one runner (`.github/workflows/build.yml`) and publishes two: MIT IPA (moonlight/opus stubbed), Pro compile-check (built and discarded — a sideloaded Pro has no receipt, so its PCVR would sit in trial forever, but PCVR is a lot of code no other edition compiles), then Moonlight IPA (real deps). Local builds use `scripts/setup-deps.sh` (idempotent, applies six CI patches).
- **bash 3.2 on the runners:** no `mapfile`. Read `edition-settings.sh` output with a `while IFS= read -r` loop, and into an array — several values contain spaces.

See [[FILE_STRUCTURE.md]] for directory layout and [[KNOWN_CONSTRAINTS.md]] for build gotchas (arch settings, SwiftData migrations, window APIs).

## Testing

Unit tests in `LongwaveTests/` (XCTest, visionOS, run locally — no CI test job):

```
xcodebuild test -scheme LongwaveTests -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5'
```

Coverage: `TextDiff`, `CompanionInjectProtocol`, `SavedConnection` SSH env parsing + per-agent token resolution, `PCVRSessionLimiter` and the PCVR gesture input (`GameInput` decoding back-compat, mapping precedence, `GestureTurn`, `PCVRGestureArbiter`) — add `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FOVEATED_ENABLED' XROS_DEPLOYMENT_TARGET=26.4` and `-collect-test-diagnostics never`, since those tests are gated with the feature. `PBXFileSystemSynchronizedRootGroup`, so new `.swift` files auto-compile — no pbxproj edits needed. **Don't pass `CODE_SIGNING_ALLOWED=NO` to the test run**: the `SavedConnectionCredentialTests`/`SavedConnectionEnvTests` classes store tokens in the keychain, which an unsigned simulator bundle cannot reach, and all 30 of them fail with `nil` tokens while everything else passes.

## Critical Gotchas

**RoyalVNCKit patch sync:** After editing `repos/royalvnc/`, **re-export the patch** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-longwave.patch` — or CI builds fail to compile.

**SSH tokens:** macOS Keychain is unreachable over SSH. Solution: tokens stored in Vision Pro keychain (per-agent, per-connection) and delivered on the **stdin** of a separate non-PTY create channel (`SSHTerminalManager.agentLaunch`), never on a command line — argv is world-readable via `ps`. No `sshd_config` changes needed. See the SSH section of [[KNOWN_CONSTRAINTS.md]].

**Claude OAuth is an unsupported surface.** `ClaudeOAuth` drives Claude Code's own authorization-code + PKCE flow so the headset can mint a full-scope `CLAUDE_CODE_OAUTH_TOKEN` itself. This replaced sending the user to `claude setup-token`, which requests `user:inference` **only** — without `user:profile` an agent can't read the account's model entitlements. Every wire constant in `ClaudeOAuth.Constants` (client id, authorize/token URLs, scope list) was extracted from the installed `claude` binary, **not** a published spec, so treat upstream CLI updates as able to break it; re-extract with `strings -n 6 <binary> | grep -oE '.{600}CLIENT_ID:"[0-9a-f-]{36}".{500}'`. Three consequences worth remembering: the token endpoint takes a **JSON** body (a form body is rejected); refreshes must re-send the full `scope` list or the new token silently loses `user:profile`; and **the token by itself is not enough** — an env-var session assumes `user:inference` with no plan unless `CLAUDE_CODE_OAUTH_SCOPES` and `CLAUDE_CODE_SUBSCRIPTION_TYPE` accompany it (the latter fetched from `/api/oauth/profile`), otherwise the CLI reports the plan as "Claude API" and demands usage credits for models the subscription already covers. Full-scope tokens are short-lived (~8h) and a custom `expires_in` must **never** be sent — the server answers `400 custom expires_in not allowed for scope user:mcp_servers`, so asking for a longer token breaks sign-in outright rather than just being ignored. Instead `resolvedSSHEnvironmentRenewingCredentials(for:)` refreshes immediately before each launch and the tmux idle reaper clears sessions that outlive one. The sign-in sheet also watches the clipboard, because Claude's login emails a code *and* a magic link and neither can reach an embedded web view on its own — see the idle-teardown and login bullets in [[KNOWN_CONSTRAINTS.md]]. The login sheet shows the scopes the server actually granted, so a silent downgrade is visible rather than surfacing later as a permission error.

**Audio session handling:** Audio receiver has two modes (Speaker/Music). Speaker is mixable (coexists with VoIP), Music is exclusive (Now Playing app). Don't add `MPNowPlayingInfoCenter` to Speaker mode — it forces interrupting session. On VoIP interruption, only a fresh receiver (not engine rebuild) recovers. Set `setActive(true)` on every engine build.

**Build arch settings:** visionOS targets are arm64-only (project setting). SPM packages don't inherit this — use concrete simulator destinations (`platform=visionOS Simulator,name=Apple Vision Pro`) or pass `ARCHS=arm64` on the xcodebuild line. macOS targets are universal (arm64 + x86_64); the Opus patch guards ARM NEON sources on x86_64.

**Window APIs:** Use `dismissWindow(id:)` (not `dismiss()`) for `WindowGroup`. `navigationTitle` requires `NavigationStack`. visionOS refuses to close the app's last window. The main window is value-typed with a single constant identity (`MainWindowID.shared`) so every `openWindow(id: "main", value:)` reactivates the one instance instead of spawning duplicates. Connection windows open as plain siblings (`openWindow(id:)`, **not** `pushWindow`) so the main window coexists and surfacing one never dismisses the other; on teardown a window unconditionally re-surfaces main (a no-op when it's already up). Teardown must go through `WindowSessionRegistry.closeAfterSurfacingMain(using:_:)` — `openWindow` is async, so a `dismissWindow` in the same turn can still be evaluated as "closing the last window" and silently dropped; the helper waits for the main window's `onAppear` first.

**Windows release signing is SSHSIG, and two keys are pinned.** CI publishes; a human then runs
`scripts/bless-release.sh`, which hashes every asset on the release into one `SHA256SUMS` and
signs it with `ssh-keygen -Y sign -n file`. `CompanionWindows/app/src/release-signers` pins the
everyday YubiKey **and an offline backup** — both from the first release that shipped the file,
because a recovery key added after the key it recovers from is worthless (nothing installed
would trust it). `bless-release.sh --key-file <offline key>` is the drill. The Companion's
updater (`src/updater.js`) is notify-only and refuses any release without a valid manifest —
`electron-updater` is deliberately absent, since with no code-signing cert it verifies nothing
on Windows and would run an unverified `.exe`. `scripts/verify-release.sh` is the same check for
humans. Two traps: `ssh-keygen -Y sign` **silently keeps an existing `<file>.sig`** and still
exits 0, so always `rm -f` first; and CI tags (`0.1.0-<sha8>`) are **not orderable**, so "is
there something newer" must come from GitHub's release timestamps, never from comparing tags.

**Whoever lays the LibOVR shim down owns `LIBOVR_DLL_DIR`.** VDXR reaches the PCVR stack through
a LibOVR-shaped shim it finds only via that user-scope registry value; without it every OpenXR
and OpenVR title fails `xrGetSystem` with `XR_ERROR_FORM_FACTOR_UNAVAILABLE` behind a log line
reading "Virtual Desktop Server is not running" — which names neither the variable nor the
directory. Nothing set it until 2026-08-23 (a hand-set value, orphaned by the
`VisionVNC-bridge` → `Longwave-bridge` rename). Now `provision-pc.ps1` writes it for a dev
checkout and `pcvr-installer.js`'s `registerShimDirectory()` for a downloaded bundle. Both
bitnesses must be present (`LibOVRRT64_1.dll` + `LibOVRRT32_1.dll`, the latter from
`cmake -B build32 -A Win32`): a missing 32-bit shim fails identically and only for 32-bit titles.

**The headset microphone reaches a PCVR game only through NVIDIA's virtual audio driver.** visionOS
forwards the mic for every foveated session on its own; `FoveatedStreamingSession` has no microphone
API (a toggle bound to a mock-only `isMicrophoneEnabled` shipped for a while and did nothing). On the
PC, `micStreaming: true` in `cloudxr-runtime.yaml` makes the runtime create a mic stream, but it is
pushed into the capture pin of the `CloudXRVirtualAudioDriver` (`nvcloudxrvad`, "NVIDIA CloudXR",
HWID `USB\VID_0959&PID_9004`) and nowhere else. The signature of the driver being absent is
`nvAudCapRegisterEndpoint failed (13)` at runtime start and `total bytes captured: 0` at teardown in
`cxr_server.*.log`, with no error anywhere else. It is a root-enumerated device, so `pnputil
/add-driver` alone does nothing: `CompanionWindows/scripts/install-cloudxr-audio-driver.ps1` creates
the node and binds the INF (the Companion's PCVR tab and `provision-pc.ps1` both call it), the host
reports `microphone` on `/info`, and the PCVR tab relays it. V.A.C. or other virtual cables are not a
substitute — nothing feeds them.

**The Native stream's virtual display is Mac Virtual Display's own mechanism, unentitled.** Mac VD is
not Universal Control.app (that process only does cross-device HID); the display belongs to
`SidecarDisplayAgent`, which creates a `CGVirtualDisplay` and sets `DisplayExclusiveMode = 1` on the
descriptor via `setDisplayInfoValue:forKey:`, whereupon WindowServer disconnects every physical display
("Disconnecting display N due to exclusive display") and reconnects them when the display is released
or its process dies. Verified 2026-09-22 on macOS 27 from an unentitled process, both plain and
exclusive — `CompanionMac/MacNativeVirtualDisplay.swift` does exactly this. The classes are SPI with no
headers, so it goes through the ObjC runtime: KVC for properties, IMP casts for `alloc`/`init…`/
`applySettings:` (plain `perform` cannot express init ownership or a `BOOL` return). Two traps: the
display must be online (`CGDisplayIsOnline`) *and* listed by `SCShareableContent` before capture, which
lags by a few hundred ms — retry, never fall back to the main display; and **removals are deferred while
any exclusive display is active**, so a release test run while Mac VD is connected looks like a leak.
Hold `kIOPMAssertPreventUserIdleDisplaySleep` for the display's lifetime, as the agent does, or the
Mac sleeps its only display and capture stops.

**SwiftData migrations:** New non-optional properties need default values. Renamed columns need `@Attribute(originalName:)`. Missing either causes CoreData error 134110.

See [[KNOWN_CONSTRAINTS.md]] for detailed version of all gotchas (broadcast, Moonlight HDR, Copilot OAuth, etc.).

See [[API_REFERENCE.md]] for RoyalVNCKit and moonlight-common-c method signatures.
