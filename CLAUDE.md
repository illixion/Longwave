# VisionVNC — Claude Code Context

## Overview

VisionVNC is a remote desktop and game streaming app for **visionOS** built in Swift. It supports VNC, Moonlight game streaming, system audio streaming, SSH terminal + remote agents, and RTSP broadcast:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C library) with H.264/HEVC/AV1 hardware decoding, HDR10, Opus audio
3. **Audio** — Uncompressed streaming from macOS Companion (`VisionVNCCompanion` target) with Music.app now-playing metadata + transport control
4. **SSH / Remote Agents** — Built-in SSH terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT + [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) Apache-2.0) plus a Projects tab that drives Claude Code / GitHub Copilot / custom CLI agents over SSH (tmux-backed). Tokens injected per agent, per connection, from Vision Pro keychain (macOS Keychain unreachable over SSH). Claude and Copilot both sign in **on the headset** — Claude through an in-app browser running its OAuth PKCE flow (`ClaudeOAuth`), Copilot through GitHub's device flow (`GitHubDeviceFlow`).
5. **Broadcast** — H.264 + native Opus RTP/RTSP to mediamtx via tab (foreground) and ReplayKit extension (backgrounded). One-button server setup from companion, OBS provisioning via obs-websocket.

**Moonlight** is optional (controlled by `MOONLIGHT_ENABLED` compilation condition). When disabled, the app is a pure VNC viewer.

See [[ARCHITECTURE.md]] for multi-window design, threading patterns, and data pipelines.

## Build Configuration

- **Platform:** visionOS 26.2+, Swift 5.0
- **SWIFT_DEFAULT_ACTOR_ISOLATION:** MainActor (all types implicitly @MainActor)
- **RoyalVNCKit:** Local SPM from `repos/royalvnc/` with local mods (static linking, JPEG quality/compression, framebuffer pause/resume). **Re-export the patch after edits** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-visionvnc.patch` — or CI builds fail.
- **Dependencies:** moonlight-common-c, Opus (local SPM packages in `repos/`, wrapped in `ci/deps/`). `MOONLIGHT_ENABLED` compilation condition gates all Moonlight code.
- **CI:** Builds two IPAs on one runner (`.github/workflows/build.yml`): MIT IPA (moonlight/opus stubbed), then Moonlight IPA (with real deps + MOONLIGHT_ENABLED). Local builds use `scripts/setup-deps.sh` (idempotent, applies six CI patches).

See [[FILE_STRUCTURE.md]] for directory layout and [[KNOWN_CONSTRAINTS.md]] for build gotchas (arch settings, SwiftData migrations, window APIs).

## Testing

Unit tests in `VisionVNCTests/` (XCTest, visionOS, run locally — no CI test job):

```
xcodebuild test -scheme VisionVNCTests -destination 'platform=visionOS Simulator,name=Apple Vision Pro,OS=26.5'
```

Coverage: `TextDiff`, `CompanionInjectProtocol`, `SavedConnection` SSH env parsing + per-agent token resolution. `PBXFileSystemSynchronizedRootGroup`, so new `.swift` files auto-compile — no pbxproj edits needed.

## Critical Gotchas

**RoyalVNCKit patch sync:** After editing `repos/royalvnc/`, **re-export the patch** — `cd repos/royalvnc && git diff 337197a > ../../ci/patches/royalvnc-visionvnc.patch` — or CI builds fail to compile.

**SSH tokens:** macOS Keychain is unreachable over SSH. Solution: tokens stored in Vision Pro keychain (per-agent, per-connection) and injected inline into the tmux launch command. No `sshd_config` changes needed.

**Claude OAuth is an unsupported surface.** `ClaudeOAuth` drives Claude Code's own authorization-code + PKCE flow so the headset can mint a full-scope `CLAUDE_CODE_OAUTH_TOKEN` itself. This replaced sending the user to `claude setup-token`, which requests `user:inference` **only** — without `user:profile` an agent can't read the account's model entitlements. Every wire constant in `ClaudeOAuth.Constants` (client id, authorize/token URLs, scope list) was extracted from the installed `claude` binary, **not** a published spec, so treat upstream CLI updates as able to break it; re-extract with `strings -n 6 <binary> | grep -oE '.{600}CLIENT_ID:"[0-9a-f-]{36}".{500}'`. Two consequences worth remembering: the token endpoint takes a **JSON** body (a form body is rejected), and refreshes must re-send the full `scope` list or the new token silently loses `user:profile`. Full-scope tokens are short-lived (~8h — the server restricts long-lived tokens to inference-only), so `resolvedSSHEnvironmentRenewingCredentials(for:)` refreshes immediately before each launch and the tmux idle reaper clears sessions that outlive one. The sign-in sheet also watches the clipboard, because Claude's login emails a code *and* a magic link and neither can reach an embedded web view on its own — see the idle-teardown and login bullets in [[KNOWN_CONSTRAINTS.md]]. The login sheet shows the scopes the server actually granted, so a silent downgrade is visible rather than surfacing later as a permission error.

**Audio session handling:** Audio receiver has two modes (Speaker/Music). Speaker is mixable (coexists with VoIP), Music is exclusive (Now Playing app). Don't add `MPNowPlayingInfoCenter` to Speaker mode — it forces interrupting session. On VoIP interruption, only a fresh receiver (not engine rebuild) recovers. Set `setActive(true)` on every engine build.

**Build arch settings:** visionOS targets are arm64-only (project setting). SPM packages don't inherit this — use concrete simulator destinations (`platform=visionOS Simulator,name=Apple Vision Pro`) or pass `ARCHS=arm64` on the xcodebuild line. macOS targets are universal (arm64 + x86_64); the Opus patch guards ARM NEON sources on x86_64.

**Window APIs:** Use `dismissWindow(id:)` (not `dismiss()`) for `WindowGroup`. `navigationTitle` requires `NavigationStack`. visionOS refuses to close the app's last window. The main window is value-typed with a single constant identity (`MainWindowID.shared`) so every `openWindow(id: "main", value:)` reactivates the one instance instead of spawning duplicates. Connection windows open as plain siblings (`openWindow(id:)`, **not** `pushWindow`) so the main window coexists and surfacing one never dismisses the other; on teardown a window unconditionally re-surfaces main (a no-op when it's already up). Teardown must go through `WindowSessionRegistry.closeAfterSurfacingMain(using:_:)` — `openWindow` is async, so a `dismissWindow` in the same turn can still be evaluated as "closing the last window" and silently dropped; the helper waits for the main window's `onAppear` first.

**SwiftData migrations:** New non-optional properties need default values. Renamed columns need `@Attribute(originalName:)`. Missing either causes CoreData error 134110.

See [[KNOWN_CONSTRAINTS.md]] for detailed version of all gotchas (broadcast, Moonlight HDR, Copilot OAuth, etc.).

See [[API_REFERENCE.md]] for RoyalVNCKit and moonlight-common-c method signatures.
