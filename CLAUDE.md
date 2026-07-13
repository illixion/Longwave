# VisionVNC — Claude Code Context

## Overview

VisionVNC is a remote desktop and game streaming app for **visionOS** built in Swift. It supports VNC, Moonlight game streaming, system audio streaming, SSH terminal + remote agents, and RTSP broadcast:

1. **VNC** — Traditional remote desktop via [RoyalVNCKit](https://github.com/royalapplications/royalvnc) (MIT, pure Swift, local SPM)
2. **Moonlight** — Low-latency game streaming via [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) (GPLv3, C library) with H.264/HEVC/AV1 hardware decoding, HDR10, Opus audio
3. **Audio** — Uncompressed streaming from macOS Companion (`VisionVNCCompanion` target) with Music.app now-playing metadata + transport control
4. **SSH / Remote Agents** — Built-in SSH terminal ([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) MIT + [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) Apache-2.0) plus a Projects tab that drives Claude Code / GitHub Copilot / custom CLI agents over SSH (tmux-backed). Tokens injected per agent, per connection, from Vision Pro keychain (macOS Keychain unreachable over SSH).
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

**Audio session handling:** Audio receiver has two modes (Speaker/Music). Speaker is mixable (coexists with VoIP), Music is exclusive (Now Playing app). Don't add `MPNowPlayingInfoCenter` to Speaker mode — it forces interrupting session. On VoIP interruption, only a fresh receiver (not engine rebuild) recovers. Set `setActive(true)` on every engine build.

**Build arch settings:** visionOS targets are arm64-only (project setting). SPM packages don't inherit this — use concrete simulator destinations (`platform=visionOS Simulator,name=Apple Vision Pro`) or pass `ARCHS=arm64` on the xcodebuild line. macOS targets are universal (arm64 + x86_64); the Opus patch guards ARM NEON sources on x86_64.

**Window APIs:** Use `dismissWindow(id:)` (not `dismiss()`) for `WindowGroup`. `navigationTitle` requires `NavigationStack`. visionOS refuses to close the app's last window. The main window is value-typed with a single constant identity (`MainWindowID.shared`) so every `openWindow(id: "main", value:)` reactivates the one instance instead of spawning duplicates. Connection windows open as plain siblings (`openWindow(id:)`, **not** `pushWindow`) so the main window coexists and surfacing one never dismisses the other; on teardown a window unconditionally re-surfaces main (a no-op when it's already up).

**SwiftData migrations:** New non-optional properties need default values. Renamed columns need `@Attribute(originalName:)`. Missing either causes CoreData error 134110.

See [[KNOWN_CONSTRAINTS.md]] for detailed version of all gotchas (broadcast, Moonlight HDR, Copilot OAuth, etc.).

See [[API_REFERENCE.md]] for RoyalVNCKit and moonlight-common-c method signatures.
