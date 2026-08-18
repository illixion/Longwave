# MediaRemote helper

Reads the **system-wide Now Playing state** — the data behind the macOS menu bar
widget — for any player: Music.app (local files *and* Apple Music streaming),
Spotify, video in Safari/Chrome/Firefox, podcasts. Title, artist, album,
duration, elapsed time, and artwork, plus transport control.

This exists because the AppleScript path in `CompanionMac/MusicAppBridge.swift`
can't do it. AppleScript sees only Music.app, and
`data of artwork 1 of current track` returns **nothing** for anything streamed
from Apple Music, because Music only exposes artwork bytes for tracks backed by a
local file. That is the gap this closes.

## Why a separate process, and why perl

The metadata lives in the private `MediaRemote.framework`. Since **macOS 15.4**
it answers only processes whose code-signing identifier begins with
`com.apple.`. Everyone else gets silence — verifiably so:

```
mediaremoted: Response: handlePlaybackQueueRequest<… plainhost-23927 …> returned with error
  <Error Domain=kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted">
```

`/usr/bin/perl` is an Apple platform binary whose signing identifier is
`com.apple.perl`, so it passes that check:

```
mediaremoted: Adding client <MRDMediaRemoteClient …, bundleIdentifier = com.apple.perl, …, entitlements=512>
```

So Longwave spawns perl, perl loads `longwave-mediaremote.dylib`, and the dylib
streams newline-delimited JSON back over a pipe. **Longwave itself never loads
this dylib and never links MediaRemote** — there is no private-framework load
command in any shipped Longwave binary.

There is no entitlement, TCC permission, or user-grantable setting that would
let the app read this directly. Screen Recording would only allow scraping
pixels of the widget, which is not metadata.

## The gotcha that will cost you an afternoon

The entry point **must be invoked as an XS sub after `dl_load_file` returns**:

```perl
my $handle  = DynaLoader::dl_load_file($lib, 0);
my $address = DynaLoader::dl_find_symbol($handle, "longwave_mediaremote_stream");
DynaLoader::dl_install_xsub("main::entry", $address);
main::entry();
```

Doing the work in a library constructor instead *looks* like it should be
equivalent and fails in a maximally confusing way. A constructor runs while dyld
still holds the loader lock, and MediaRemote's reply path lazily loads further
images — so every completion block deadlocks and is never called.

The symptom is indistinguishable from a permissions failure: the request reaches
`mediaremoted`, the log shows it succeeding in under a millisecond, and your
callback simply never fires. `MRMediaRemoteGetNowPlayingApplicationIsPlaying`
*does* still answer (it needs no further image loads), which makes it look like
the framework is working and only the metadata is being withheld.

Also note `MRMediaRemoteGetNowPlayingInfoWithOptionalArtwork` — the signature is
not `(queue, BOOL, block)`; guessing it segfaults the host.

## Layout

| Path | Role |
|---|---|
| `longwave-mediaremote.m` | The helper. Deliberately **not** in any Xcode target — a `.m` inside `CompanionMac/` would be auto-compiled into the app by the synchronized folder group. |
| `scripts/build-mediaremote-helper.sh` | Builds the universal dylib and signs it. |
| `CompanionMac/MediaRemoteBridge.swift` | Spawns perl, parses the stream, restarts on failure. |
| `CompanionMac/NowPlayingCoordinator.swift` | Chooses between this and the AppleScript fallback. |

The build runs as a `Build MediaRemote Helper` script phase on both
`LongwaveCompanion` and `LongwaveMac`, landing the dylib in
`Contents/Resources/`. It stages into `mktemp -d` rather than building in place
because `ENABLE_USER_SCRIPT_SANDBOXING` makes *only declared outputs* writable —
not even `DERIVED_FILE_DIR` — and `codesign` writes a `<name>.cstemp` sibling
before renaming.

## Failure handling

This rides on a private framework, so it is expected to break eventually.
Everything degrades to `MediaRemoteBridge.isAvailable == false` and
`NowPlayingCoordinator` falls back to AppleScript:

- `/usr/bin/perl` missing. Apple deprecated the bundled scripting runtimes in
  macOS 10.15; if perl is ever removed, this is the path that catches it.
- The dylib missing from the bundle.
- The helper exiting with status 2 (MediaRemote unreachable), or crashing more
  than three times.
- No `ready` line within five seconds.

The coordinator arbitrates on **content**, not on a capability probe: whichever
backend actually reports a track wins. With nothing playing anywhere, a
working-but-idle MediaRemote and a MediaRemote that Apple has broken are
genuinely indistinguishable, so there is nothing to probe for — but comparing
what each backend reports makes the question moot.

## Verifying by hand

```sh
scripts/build-mediaremote-helper.sh /tmp/lw-mr.dylib
/usr/bin/perl -e '
  require DynaLoader;
  my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die "load\n";
  my $s = DynaLoader::dl_find_symbol($h, $ARGV[1]) or die "sym\n";
  DynaLoader::dl_install_xsub("main::go", $s); main::go();
' /tmp/lw-mr.dylib longwave_mediaremote_stream
```

Expect `{"ready":true,"v":1}` followed by one payload per change. Play something
in a browser to confirm it isn't just reading Music.app. To watch the permission
check itself:

```sh
log show --last 2m --predicate 'process == "mediaremoted"' --style compact --debug
```

## Credit

The insight that MediaRemote gates on an `com.apple.` signing identifier, and
that an Apple-signed script interpreter can therefore host the read, comes from
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
(BSD 3-Clause) and the investigation linked from it. No code from that project
ships here — this helper is our own and speaks its own protocol — but it saved a
lot of guessing and deserves the credit.
