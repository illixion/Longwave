#!/usr/bin/env bash
#
# Build the closed-source PCVR bundle (LongwavePCVRHost.exe + the SessionBroker/OpenXRLayer
# native binaries + the CloudXR SDK redistributable + the PCVR/Games UI, minified) and attach
# it as an asset to a GitHub release CI already created for the public app.
#
# This is the "compile the PCVR component on my own laptop and attach it to the release" half
# of the split: GitHub CI builds and publishes the public installer from public source; this
# script never runs in CI (there is no public source for it to build from) and is meant to be
# run by hand, from a machine with the private submodules checked out. The native cross-build
# runs on a Windows-on-ARM VMware Fusion VM local to this Mac (see LONGWAVE_PC_HOST below) —
# validated end-to-end in Phase 0 of the installer plan (real SessionBroker/OpenXRLayer builds,
# genuine x64 PE output via dumpbin). Never point this at a machine outside your own trust
# boundary: it receives the private submodule source over scp and returns built binaries that
# get GPG-signed and shipped, with no build step re-verified afterward.
#
# The running app asks GitHub for an asset on *its own build's release tag* (see
# CompanionWindows/app/src/pcvr-installer.js) — never /releases/latest — because the tag is
# the only thing that guarantees the pipe protocol on both ends matches. So this script always
# uploads to a specific existing tag, never creates one.
#
#   scripts/package-pcvr-bundle.sh                       # auto-detects the latest CI release tag
#   scripts/package-pcvr-bundle.sh --tag 0.1.0-abc12345  # target a specific release
#   scripts/package-pcvr-bundle.sh --no-build-native     # reuse whatever's already built on the VM
#   scripts/package-pcvr-bundle.sh --stage-only          # build + zip locally, skip gh release upload
#
# The zip is detached-signed with the Ixion YubiKey OpenPGP key (ed25519, card serial 13655979)
# before upload — this is the one step in the whole script that pauses for you: gpg's pinentry
# will ask for the card PIN and a physical touch. The app verifies the signature with the public
# half of that same key, committed at CompanionWindows/app/src/pcvr-signing-key.asc, so nobody
# needs gpg installed to check it — see pcvr-installer.js's verifyGpgSignature().
#
# Requires: Longwave-PCVR-Host/, SessionBroker/, OpenXRLayer/ submodules checked out locally;
# `gh` authenticated against this repo; SSH access to the build VM (ssh-exec, see ~/CLAUDE.md);
# esbuild installed under CompanionWindows/app/node_modules (npm install there); the signing
# YubiKey plugged in.

set -euo pipefail

# Windows-on-ARM VMware Fusion VM on this Mac — see ~/.ssh/config's `winvm` entry. Override
# with LONGWAVE_PC_HOST if you ever build on the real gaming PC again (LONGWAVE_CLOUDXR_SDK's
# default below assumes whichever host you point this at has the CloudXR SDK staged already).
HOST="${LONGWAVE_PC_HOST:-winvm}"
BRIDGE_WIN='C:\dev\Longwave-bridge'
# Where the NGC-downloaded CloudXR SDK is hand-staged on the host (matches provision-pc.ps1's
# own default) — third-party redistributable, not built, just copied along.
CLOUDXR_SDK_WIN="${LONGWAVE_CLOUDXR_SDK:-C:\\Users\\Ixion\\cloudxr-stream-manager_v6.1.0\\extracted}"
# The signing key's fingerprint, not its secret material — the private key never leaves the
# YubiKey. Matches CompanionWindows/app/src/pcvr-signing-key.asc.
GPG_KEY="${LONGWAVE_GPG_KEY:-4C7C68975127BCF9}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PROJ="$REPO_ROOT/Longwave-PCVR-Host/Host.csproj"

TAG=""
NO_BUILD_NATIVE=0
STAGE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              TAG="${2:?--tag needs a value}"; shift ;;
    --no-build-native)  NO_BUILD_NATIVE=1 ;;
    --stage-only)       STAGE_ONLY=1 ;;
    --host)             HOST="${2:?--host needs a value}"; shift ;;
    -h|--help)          sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

SSH_EXEC="$HOME/.claude/bin/ssh-exec"
ps_exec() {
  local desc="$1" timeout="$2" script="$3"
  "$SSH_EXEC" exec --host "$HOST" --powershell --desc "$desc" --timeout "$timeout" --command "$script"
}

[[ -f "$HOST_PROJ" ]] || { echo "error: $HOST_PROJ not found — is the Longwave-PCVR-Host submodule checked out?" >&2; exit 1; }

if [[ -z "$TAG" ]]; then
  echo "==> no --tag given, using the latest GitHub release"
  TAG="$(cd "$REPO_ROOT" && gh release list --limit 1 --json tagName -q '.[0].tagName')"
  [[ -n "$TAG" ]] || { echo "error: could not determine a release tag from gh release list" >&2; exit 1; }
fi
echo "==> targeting release tag: $TAG"

STAGE="$(mktemp -d -t longwave-pcvr-bundle)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/host" "$STAGE/bridge"

# ------------------------------------------------------------------ .NET host (built locally)
echo "==> publishing LongwavePCVRHost (win-x64, self-contained)"
dotnet publish "$HOST_PROJ" -c Release -r win-x64 --self-contained true -o "$STAGE/host"

# Symbols stay at home. A .NET assembly is IL and decompiles readably either way,
# but the PDB is what turns that output back into something with the original
# local variable names and line numbers — the difference between reading
# generated code and reading ours. Not shipping it costs only the line numbers in
# a stack trace from a user's machine, and the build that produced the assembly
# still has the PDB if one ever needs symbolicating.
#
# The native side needs no equivalent: the bridge files are copied by name below,
# and no .pdb is on that list.
find "$STAGE/host" -name '*.pdb' -delete
echo "    stripped $(find "$STAGE/host" -name '*.pdb' | wc -l | tr -d ' ') remaining .pdb (expect 0)"

# ------------------------------------------------------------------ native build (on the PC)
if [[ "$NO_BUILD_NATIVE" == 0 ]]; then
  echo "==> syncing SessionBroker/ + OpenXRLayer/ source to $HOST"
  for dir in SessionBroker OpenXRLayer; do
    TAR="$STAGE/$dir.tar"
    COPYFILE_DISABLE=1 tar -cf "$TAR" -C "$REPO_ROOT" \
      --exclude='._*' --exclude='build' --exclude='build-hxr' --exclude='.git' \
      "$dir"
    scp -q "$TAR" "$HOST:C:/Windows/Temp/longwave-$dir.tar"
  done

  ps_exec 'unpack native source' 120 "
\$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path '$BRIDGE_WIN' | Out-Null
foreach (\$dir in @('SessionBroker', 'OpenXRLayer')) {
  \$target = Join-Path '$BRIDGE_WIN' \$dir
  # tar -x merges into an existing tree rather than replacing it, so a source file
  # renamed or deleted upstream would otherwise linger in the build forever.
  if (Test-Path \$target) {
    Get-ChildItem \$target -Exclude 'build','build-hxr','openxr-sdk-source' |
      Remove-Item -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path \$target | Out-Null
  Push-Location \$target
  tar.exe -xf \"C:/Windows/Temp/longwave-\$dir.tar\" --strip-components=1
  if (\$LASTEXITCODE -ne 0) { throw \"tar extract failed for \$dir\" }
  Pop-Location
  Remove-Item \"C:/Windows/Temp/longwave-\$dir.tar\" -Force
}
'synced'
"

  # A stale exe from a previous build silently reporting success is a known trap here
  # (nmake won't re-link if CMake thinks nothing changed) — delete the two real deliverables
  # first so their re-appearance is proof the build actually ran.
  #
  # NMake Makefiles, not the multi-config VS generator, because winvm only has VS Build
  # Tools (no full IDE) — this is the exact toolchain/env validated in the installer plan's
  # Phase 0 spike: MSVC's Hostarm64\x64 cross-compiler + cppwinrt on INCLUDE + the SDK's
  # bin\<ver>\arm64 on PATH for rc.exe. Single-config, so CMAKE_BUILD_TYPE is set once at
  # configure time rather than passed as --config at build time.
  echo "==> building SessionBroker + OpenXRLayer (Release) on $HOST"
  ps_exec 'build broker + layer' 900 "
\$ErrorActionPreference = 'Stop'
\$msvc = (Get-ChildItem 'C:\\BuildTools\\VC\\Tools\\MSVC' -Directory | Select-Object -First 1).FullName
\$sdk = 'C:\\Program Files (x86)\\Windows Kits\\10'
\$sdkver = (Get-ChildItem \"\$sdk\\Include\" -Directory | Select-Object -Last 1).Name
\$env:PATH = \"\$msvc\\bin\\Hostarm64\\x64;\$sdk\\bin\\\$sdkver\\arm64;C:\\Program Files\\CMake\\bin;\$env:PATH\"
\$env:INCLUDE = \"\$msvc\\include;\$sdk\\Include\\\$sdkver\\ucrt;\$sdk\\Include\\\$sdkver\\shared;\$sdk\\Include\\\$sdkver\\um;\$sdk\\Include\\\$sdkver\\winrt;\$sdk\\Include\\\$sdkver\\cppwinrt\"
\$env:LIB = \"\$msvc\\lib\\x64;\$sdk\\Lib\\\$sdkver\\ucrt\\x64;\$sdk\\Lib\\\$sdkver\\um\\x64\"

Remove-Item '$BRIDGE_WIN\\SessionBroker\\build\\LongwaveSessionBroker.exe' -Force -ErrorAction SilentlyContinue
Remove-Item '$BRIDGE_WIN\\OpenXRLayer\\build\\LongwaveControllerBridgeLayer.dll' -Force -ErrorAction SilentlyContinue

foreach (\$dir in @('SessionBroker', 'OpenXRLayer')) {
  \$build = Join-Path '$BRIDGE_WIN' \"\$dir\build\"
  \$src = Join-Path '$BRIDGE_WIN' \$dir
  # Configure once, then just build — a stale CMakeCache.txt from a differently-shaped source
  # tree (e.g. re-synced after a rename) is exactly the kind of thing worth a fresh configure,
  # so wipe and reconfigure rather than trust an existing cache blindly.
  if (Test-Path (Join-Path \$build 'CMakeCache.txt')) { Remove-Item \$build -Recurse -Force }
  New-Item -ItemType Directory -Force -Path \$build | Out-Null
  Push-Location \$build
  cmake -G 'NMake Makefiles' -DCMAKE_BUILD_TYPE=Release \$src
  if (\$LASTEXITCODE -ne 0) { throw \"CMake configure failed for \$dir\" }
  nmake
  if (\$LASTEXITCODE -ne 0) { throw \"nmake build failed for \$dir\" }
  Pop-Location
}

foreach (\$f in @(
  '$BRIDGE_WIN\\SessionBroker\\build\\LongwaveSessionBroker.exe',
  '$BRIDGE_WIN\\OpenXRLayer\\build\\LongwaveControllerBridgeLayer.dll'
)) {
  if (-not (Test-Path \$f)) { throw \"expected build output missing: \$f\" }
}
'built'
"
else
  echo "==> --no-build-native: reusing whatever is already built on $HOST"
fi

# scp (unlike the PowerShell strings above) will not take a Windows backslash path — same
# gotcha deploy-windows-companion.sh already works around. Forward-slash mirrors of the two
# backslash vars, for scp remote paths only.
BRIDGE_FS="${BRIDGE_WIN//\\//}"
CLOUDXR_SDK_FS="${CLOUDXR_SDK_WIN//\\//}"

# ------------------------------------------------------------------ collect artifacts back
# NMake Makefiles is a single-config generator, so build outputs land straight in build/ —
# no Release/ subfolder, unlike the multi-config VS generator this script used before.
echo "==> collecting artifacts from $HOST"
for f in LongwaveSessionBroker.exe LibOVRRT64_1.dll sidecar.dll sidecar_inject.exe; do
  scp -q "$HOST:$BRIDGE_FS/SessionBroker/build/$f" "$STAGE/bridge/$f"
done
for f in LongwaveControllerBridgeLayer.dll XR_APILAYER_ILLIXION_controller_bridge.json; do
  scp -q "$HOST:$BRIDGE_FS/OpenXRLayer/build/$f" "$STAGE/bridge/$f"
done

# install-layer.ps1 is a source file, not a build output — it never lands in build/Release/,
# so it has to come from the local checkout rather than off the PC (pcvr-installer.js's
# installApiLayerElevated() looks for it next to the DLLs it registers).
cp "$REPO_ROOT/OpenXRLayer/scripts/install-layer.ps1" "$STAGE/bridge/install-layer.ps1"

echo "==> collecting the CloudXR SDK redistributable from $HOST"
mkdir -p "$STAGE/host/Server"
scp -qr "$HOST:$CLOUDXR_SDK_FS/Server/*" "$STAGE/host/Server/"
scp -q  "$HOST:$CLOUDXR_SDK_FS/SampleClient/NvStreamManagerClient.dll" "$STAGE/host/NvStreamManagerClient.dll"

# ------------------------------------------------------------------ PCVR/Games UI (minified)
# The Electron-side PCVR and Game library pages (Longwave-PCVR-Host/ui/) are as closed-source
# as the rest of this bundle — they talk to backend RPCs that only make sense with the PCVR
# host installed, and their markup itself describes PCVR internals (session/host-status
# fields, quality presets, etc). The public Companion app (CompanionWindows/app) only ships a
# generic <webview> + pcvr-module:// loader (see main.js) that knows nothing PCVR-specific;
# this is where the actual page content gets built and dropped into the bundle it downloads.
#
# Minified (not just copied) so a browsable download doesn't hand out readable source for
# free — same anti-RE reasoning as the native side, applied to the one JS/HTML/CSS surface in
# this bundle. esbuild lives in CompanionWindows/app's devDependencies; run from there so it
# resolves without a second install.
echo "==> minifying the PCVR/Games UI"
UI_SRC="$REPO_ROOT/Longwave-PCVR-Host/ui"
UI_OUT="$STAGE/host/ui"
mkdir -p "$UI_OUT"
(cd "$REPO_ROOT/CompanionWindows/app" && npx --no-install esbuild \
  "$UI_SRC/pcvr.js" "$UI_SRC/games.js" "$UI_SRC/shared.js" \
  --minify --outdir="$UI_OUT" --charset=utf8)
for f in pcvr.html games.html styles.css; do
  # esbuild's --loader=copy would also do this, but keeping HTML/CSS a plain cp is one fewer
  # thing that could silently transform markup a browser depends on rendering byte-for-byte.
  cp "$UI_SRC/$f" "$UI_OUT/$f"
done
echo "    $(find "$UI_OUT" -type f | wc -l | tr -d ' ') files, $(du -sh "$UI_OUT" | cut -f1)"

# ------------------------------------------------------------------ copyleft guard
# This bundle is closed-source on purpose. A GPL component inside it would make the whole
# thing a GPL combined work and its source disclosable, which defeats the point entirely —
# and the two components most likely to drift in here are both one careless `cp` away:
#
#   * OpenComposite (GPL-3.0) is installed on the host by install-opencomposite.ps1 and
#     lives a couple of directories from the broker. Bundling it would be the obvious
#     "reduce setup friction" shortcut, and it is exactly the wrong one.
#   * OpenPGP.js (LGPL-3.0+) belongs to the open-source Electron app, which is where the
#     LGPL is comfortable. It has no business in a closed binary bundle.
#
# Cheaper to fail here than to find out after a release. See
# CompanionWindows/THIRD_PARTY_NOTICES.md for what each of these is and why.
echo "==> checking the staged bundle for copyleft artifacts"
COPYLEFT_HITS=""
while IFS= read -r found; do
  COPYLEFT_HITS+="    $found"$'\n'
done < <(find "$STAGE" \( \
      -iname 'vrclient*.dll' -o -iname 'openvr_api*.dll' -o -iname 'opencomposite*' \
      -o -iname '*.asar' -o -iname 'openpgp*' -o -name 'node_modules' \
    \) -print | sed "s|^$STAGE/||")
if [[ -n "$COPYLEFT_HITS" ]]; then
  echo "error: copyleft (or app-only) artifacts found in the PCVR bundle staging tree:" >&2
  printf '%s' "$COPYLEFT_HITS" >&2
  echo "Remove them, or move the feature that needs them into the open-source app." >&2
  exit 1
fi
echo "    clean"

# ------------------------------------------------------------------ zip + checksum + signature
ASSET="Longwave-PCVR-Bundle-win-x64.zip"
ZIP="$STAGE/$ASSET"
echo "==> zipping bundle"
(cd "$STAGE" && zip -qr "$ASSET" host bridge)
shasum -a 256 "$ZIP" | awk '{print $1"  '"$ASSET"'"}' > "$ZIP.sha256"
echo "    $(du -h "$ZIP" | cut -f1)  $ASSET"
echo "    $(cat "$ZIP.sha256")"

# The one step in this whole script that pauses for a human: gpg's pinentry will pop up
# asking for the card PIN and a touch. Runs in the foreground on purpose — a backgrounded
# gpg can't raise that prompt at all.
echo "==> signing with GPG key $GPG_KEY (check for a PIN/touch prompt)"
gpg --local-user "$GPG_KEY" --detach-sign --armor --output "$ZIP.asc" "$ZIP"
echo "    $ZIP.asc"

if [[ "$STAGE_ONLY" == 1 ]]; then
  FINAL_DIR="$REPO_ROOT/.pcvr-bundle-out"
  mkdir -p "$FINAL_DIR"
  cp "$ZIP" "$ZIP.sha256" "$ZIP.asc" "$FINAL_DIR/"
  echo "==> --stage-only: left the bundle in $FINAL_DIR (not uploaded)"
  exit 0
fi

# ------------------------------------------------------------------ attach to the release
echo "==> uploading to release $TAG"
(cd "$REPO_ROOT" && gh release upload "$TAG" "$ZIP" "$ZIP.sha256" "$ZIP.asc" --clobber)

echo
echo "Done. $ASSET (+ .sha256, .asc) is now attached to release $TAG."
echo "An app built from that same release will offer it under PCVR -> Download & install."
