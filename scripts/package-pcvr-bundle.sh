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
# The bundle is not signed on its own. Once uploaded, this script calls
# scripts/bless-release.sh, which re-signs the release's SHA256SUMS so that one signature covers
# this bundle and every other asset on the release — that step is the one that pauses for you,
# asking for the signing key's PIN and a physical touch. See release-trust.js for how the app
# verifies it, and bless-release.sh for what to do if that key is ever lost.
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
# Where the NGC-downloaded CloudXR SDK is hand-staged on the host (matches
# provision-pc.ps1's own default) — resolved after --host is parsed because the default
# winvm and the gaming PC use different Windows profile names.
CLOUDXR_SDK_WIN="${LONGWAVE_CLOUDXR_SDK:-}"
VIGEMBUS_VERSION="1.22.0"
VIGEMBUS_ASSET="ViGEmBus_1.22.0_x64_x86_arm64.exe"
VIGEMBUS_SHA256="89220a7865076b342892f98865f3499fb7c4cfd673159e89d352c360fd014c6a"
VIGEMBUS_URL="https://github.com/nefarius/ViGEmBus/releases/download/v${VIGEMBUS_VERSION}/${VIGEMBUS_ASSET}"

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

if [[ -z "$CLOUDXR_SDK_WIN" ]]; then
  if [[ "$HOST" == "winvm" ]]; then
    CLOUDXR_SDK_WIN='C:\Users\Username\cloudxr-stream-manager_v6.1.0\extracted'
  else
    CLOUDXR_SDK_WIN='C:\Users\Ixion\cloudxr-stream-manager_v6.1.0\extracted'
  fi
fi

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

# ------------------------------------------------------------------ native build (on the PC)
if [[ "$NO_BUILD_NATIVE" == 0 ]]; then
  echo "==> syncing SessionBroker/ + OpenXRLayer/ + Longwave-PCVR-Host/ source to $HOST"
  for dir in SessionBroker OpenXRLayer Longwave-PCVR-Host; do
    TAR="$STAGE/$dir.tar"
    COPYFILE_DISABLE=1 tar -cf "$TAR" -C "$REPO_ROOT" \
      --exclude='._*' --exclude='build' --exclude='build-hxr' --exclude='.git' \
      --exclude='bin' --exclude='obj' \
      "$dir"
    scp -q "$TAR" "$HOST:C:/Windows/Temp/longwave-$dir.tar"
  done

  ps_exec 'unpack native source' 120 "
\$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path '$BRIDGE_WIN' | Out-Null
foreach (\$dir in @('SessionBroker', 'OpenXRLayer', 'Longwave-PCVR-Host')) {
  \$target = Join-Path '$BRIDGE_WIN' \$dir
  # tar -x merges into an existing tree rather than replacing it, so a source file
  # renamed or deleted upstream would otherwise linger in the build forever.
  if (Test-Path \$target) {
    Get-ChildItem \$target -Exclude 'build','build-hxr','openxr-sdk-source','bin','obj' |
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
  # One remote call per project. ssh-exec carries PowerShell through Windows OpenSSH as
  # UTF-16LE Base64, whose cmd.exe wrapper has an 8191-character ceiling; combining both
  # projects crossed it before PowerShell could start.
  for dir in SessionBroker OpenXRLayer; do
    echo "==> building $dir (Release) on $HOST"
    ps_exec "build $dir" 900 "
\$ErrorActionPreference = 'Stop'
\$msvc = (Get-ChildItem 'C:\\BuildTools\\VC\\Tools\\MSVC' -Directory | Select-Object -First 1).FullName
\$sdk = 'C:\\Program Files (x86)\\Windows Kits\\10'
\$sdkver = (Get-ChildItem \"\$sdk\\Include\" -Directory | Select-Object -Last 1).Name
\$env:PATH = \"\$msvc\\bin\\Hostarm64\\x64;\$sdk\\bin\\\$sdkver\\arm64;C:\\Program Files\\CMake\\bin;\$env:PATH\"
\$env:INCLUDE = \"\$msvc\\include;\$sdk\\Include\\\$sdkver\\ucrt;\$sdk\\Include\\\$sdkver\\shared;\$sdk\\Include\\\$sdkver\\um;\$sdk\\Include\\\$sdkver\\winrt;\$sdk\\Include\\\$sdkver\\cppwinrt\"
\$env:LIB = \"\$msvc\\lib\\x64;\$sdk\\Lib\\\$sdkver\\ucrt\\x64;\$sdk\\Lib\\\$sdkver\\um\\x64\"
\$src = Join-Path '$BRIDGE_WIN' '$dir'
\$build = Join-Path \$src 'build'
if (Test-Path (Join-Path \$build 'CMakeCache.txt')) { Remove-Item \$build -Recurse -Force }
New-Item -ItemType Directory -Force -Path \$build | Out-Null
Push-Location \$build
cmake -G 'NMake Makefiles' -DCMAKE_BUILD_TYPE=Release \$src
if (\$LASTEXITCODE -ne 0) { throw 'CMake configure failed for $dir' }
nmake
if (\$LASTEXITCODE -ne 0) { throw 'nmake build failed for $dir' }
Pop-Location
'built $dir'
"
  done

  # Third call rather than a fourth section of the second, for the same 8191-char reason
  # documented below. The 32-bit shim needs a different toolchain than everything above it --
  # Hostarm64\x86 rather than Hostarm64\x64, and lib\x86 rather than lib\x64 -- so folding it
  # into the x64 block would mean mutating INCLUDE/LIB halfway through and hoping CMake's
  # cached compiler probe noticed. A separate build32/ configure with its own environment is
  # both shorter and honest about being a second toolchain.
  #
  # Shipped because a missing 32-bit shim is invisible until someone launches a 32-bit title:
  # VDXR-32 then fails xrGetSystem with XR_ERROR_FORM_FACTOR_UNAVAILABLE, exactly as a missing
  # 64-bit shim does for everything else, and the error names neither the bitness nor the file.
  # It was absent from this bundle, and from the RTX host, until 2026-08-23.
  echo "==> building the 32-bit LibOVR shim on $HOST"
  ps_exec 'build 32-bit shim' 600 "
\$ErrorActionPreference = 'Stop'
\$msvc = (Get-ChildItem 'C:\\BuildTools\\VC\\Tools\\MSVC' -Directory | Select-Object -First 1).FullName
\$sdk = 'C:\\Program Files (x86)\\Windows Kits\\10'
\$sdkver = (Get-ChildItem \"\$sdk\\Include\" -Directory | Select-Object -Last 1).Name
\$env:PATH = \"\$msvc\\bin\\Hostarm64\\x86;\$sdk\\bin\\\$sdkver\\arm64;C:\\Program Files\\CMake\\bin;\$env:PATH\"
\$env:INCLUDE = \"\$msvc\\include;\$sdk\\Include\\\$sdkver\\ucrt;\$sdk\\Include\\\$sdkver\\shared;\$sdk\\Include\\\$sdkver\\um;\$sdk\\Include\\\$sdkver\\winrt;\$sdk\\Include\\\$sdkver\\cppwinrt\"
\$env:LIB = \"\$msvc\\lib\\x86;\$sdk\\Lib\\\$sdkver\\ucrt\\x86;\$sdk\\Lib\\\$sdkver\\um\\x86\"
\$src = Join-Path '$BRIDGE_WIN' 'SessionBroker'
\$build = Join-Path \$src 'build32'
if (Test-Path (Join-Path \$build 'CMakeCache.txt')) { Remove-Item \$build -Recurse -Force }
New-Item -ItemType Directory -Force -Path \$build | Out-Null
Push-Location \$build
cmake -G 'NMake Makefiles' -DCMAKE_BUILD_TYPE=Release \$src
if (\$LASTEXITCODE -ne 0) { throw 'CMake configure (Win32) failed' }
nmake LibOVRRT32_1
if (\$LASTEXITCODE -ne 0) { throw 'nmake build (32-bit shim) failed' }
Pop-Location
\$dll = Join-Path \$build 'LibOVRRT32_1.dll'
if (-not (Test-Path \$dll)) { throw \"expected 32-bit shim missing: \$dll\" }
\$fs = [System.IO.File]::OpenRead(\$dll); \$br = New-Object System.IO.BinaryReader(\$fs)
\$fs.Position = 0x3C; \$peOff = \$br.ReadInt32(); \$fs.Position = \$peOff + 4
\$machine = \$br.ReadUInt16(); \$br.Close(); \$fs.Close()
if (\$machine -ne 0x14c) { throw (\"32-bit shim is not an I386 PE (machine 0x{0:x})\" -f \$machine) }
'built 32-bit shim'
"

  # Separate ps_exec call, not folded into the one above: PowerShell ships to winvm as
  # a base64 -EncodedCommand string over UTF-16LE, and Windows OpenSSH's cmd.exe
  # wrapper caps that whole line at 8191 chars -- the combined script tripped that
  # limit ("The command line is too long.", no other output at all, since the failure
  # is in launching the process, before a single line of the script runs).
  echo "==> publishing LongwavePCVRHost (AOT) on $HOST"
  ps_exec 'publish host (AOT)' 300 "
\$ErrorActionPreference = 'Stop'
\$msvc = (Get-ChildItem 'C:\\BuildTools\\VC\\Tools\\MSVC' -Directory | Select-Object -First 1).FullName
\$sdk = 'C:\\Program Files (x86)\\Windows Kits\\10'
\$sdkver = (Get-ChildItem \"\$sdk\\Include\" -Directory | Select-Object -Last 1).Name
\$env:PATH = \"\$msvc\\bin\\Hostarm64\\x64;\$sdk\\bin\\\$sdkver\\arm64;C:\\Program Files\\CMake\\bin;\$env:PATH\"
\$env:INCLUDE = \"\$msvc\\include;\$sdk\\Include\\\$sdkver\\ucrt;\$sdk\\Include\\\$sdkver\\shared;\$sdk\\Include\\\$sdkver\\um;\$sdk\\Include\\\$sdkver\\winrt;\$sdk\\Include\\\$sdkver\\cppwinrt\"
\$env:LIB = \"\$msvc\\lib\\x64;\$sdk\\Lib\\\$sdkver\\ucrt\\x64;\$sdk\\Lib\\\$sdkver\\um\\x64\"

# Native AOT publish needs the same VC linker as the CMake builds above (ILCompiler
# invokes link.exe directly), which is why this runs on the VM instead of as a
# cross-publish from the Mac: Native AOT has no cross-OS story, only a cross-*arch*
# one, and that cross-arch case is exactly what this VM's toolchain (Hostarm64\\x64)
# already proves out for the C++ side. Validated on this same toolchain in the
# installer plan's Phase 0 spike 3.
\$hostProj = Join-Path '$BRIDGE_WIN' 'Longwave-PCVR-Host\\Host.csproj'
\$hostPublish = Join-Path '$BRIDGE_WIN' 'Longwave-PCVR-Host\\publish'
if (Test-Path \$hostPublish) { Remove-Item \$hostPublish -Recurse -Force }
dotnet publish \$hostProj -c Release -r win-x64 --nologo -o \$hostPublish
if (\$LASTEXITCODE -ne 0) { throw 'dotnet publish (PCVR host, AOT) failed' }
if (-not (Test-Path (Join-Path \$hostPublish 'LongwavePCVRHost.exe'))) {
  throw 'expected AOT publish output missing: LongwavePCVRHost.exe'
}
'published'
"
else
  echo "==> --no-build-native: reusing whatever is already built on $HOST"
fi

# scp (unlike the PowerShell strings above) will not take a Windows backslash path — same
# gotcha deploy-windows-companion.sh already works around. Forward-slash mirrors of the two
# backslash vars, for scp remote paths only.
BRIDGE_FS="${BRIDGE_WIN//\\//}"
CLOUDXR_SDK_FS="${CLOUDXR_SDK_WIN//\\//}"

# ------------------------------------------------------------------ .NET host (collected)
echo "==> collecting LongwavePCVRHost (AOT) from $HOST"
scp -qr "$HOST:$BRIDGE_FS/Longwave-PCVR-Host/publish/*" "$STAGE/host/"

# Symbols stay at home. Native AOT means the shipped exe is genuine machine code (not
# IL any more — see Host.csproj), but the PDB is still what maps it back to original
# names/line numbers, so the same reasoning applies: not shipping it costs only the
# symbolication, and the build that produced it still has the PDB if one is ever needed.
#
# The native C++ side needs no equivalent: the bridge files are copied by name below,
# and no .pdb is on that list.
find "$STAGE/host" -name '*.pdb' -delete
echo "    stripped $(find "$STAGE/host" -name '*.pdb' | wc -l | tr -d ' ') remaining .pdb (expect 0)"

# ------------------------------------------------------------------ collect artifacts back
# NMake Makefiles is a single-config generator, so build outputs land straight in build/ —
# no Release/ subfolder, unlike the multi-config VS generator this script used before.
echo "==> collecting artifacts from $HOST"
for f in LongwaveSessionBroker.exe LibOVRRT64_1.dll sidecar.dll sidecar_inject.exe; do
  scp -q "$HOST:$BRIDGE_FS/SessionBroker/build/$f" "$STAGE/bridge/$f"
done
# The 32-bit shim comes out of its own configure directory, and is the one file in the bundle
# whose absence is silent until a 32-bit OpenVR title (HL2VR) is launched.
scp -q "$HOST:$BRIDGE_FS/SessionBroker/build32/LibOVRRT32_1.dll" "$STAGE/bridge/LibOVRRT32_1.dll"
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

# ------------------------------------------------------------------ optional Xbox driver
# The client code is linked into the broker, but Windows needs the separately installed
# ViGEmBus driver before an Xbox 360 target can exist. Ship the official EOL release in the
# signed bundle and let the user invoke its UAC-backed installer explicitly from the UI.
echo "==> collecting optional ViGEmBus ${VIGEMBUS_VERSION}"
mkdir -p "$STAGE/drivers" "$STAGE/licenses"
curl -fL --retry 3 --output "$STAGE/drivers/$VIGEMBUS_ASSET" "$VIGEMBUS_URL"
VIGEMBUS_ACTUAL="$(shasum -a 256 "$STAGE/drivers/$VIGEMBUS_ASSET" | awk '{print $1}')"
if [[ "$VIGEMBUS_ACTUAL" != "$VIGEMBUS_SHA256" ]]; then
  echo "error: ViGEmBus checksum mismatch: expected $VIGEMBUS_SHA256, got $VIGEMBUS_ACTUAL" >&2
  exit 1
fi
cp "$REPO_ROOT/CompanionWindows/licenses/ViGEmClient-LICENSE.txt" "$STAGE/licenses/"
cp "$REPO_ROOT/CompanionWindows/licenses/ViGEmBus-LICENSE.txt" "$STAGE/licenses/"

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

# ------------------------------------------------------------------ zip + checksum
ASSET="Longwave-PCVR-Bundle-win-x64.zip"
ZIP="$STAGE/$ASSET"
echo "==> zipping bundle"
(cd "$STAGE" && zip -qr "$ASSET" host bridge drivers licenses)
shasum -a 256 "$ZIP" | awk '{print $1"  '"$ASSET"'"}' > "$ZIP.sha256"
echo "    $(du -h "$ZIP" | cut -f1)  $ASSET"
echo "    $(cat "$ZIP.sha256")"

# No per-bundle signature any more. It used to be detach-signed with the YubiKey's OpenPGP
# key right here; the release-wide signed manifest (scripts/bless-release.sh) now covers this
# asset along with every other one on the release, so signing it twice would mean two signing
# mechanisms, two key formats and two things to remember for one guarantee. The app still
# verifies old bundles' .asc signatures — see release-trust.js's verifyGpgSignature — so
# nothing already published stops working.

if [[ "$STAGE_ONLY" == 1 ]]; then
  FINAL_DIR="$REPO_ROOT/.pcvr-bundle-out"
  mkdir -p "$FINAL_DIR"
  cp "$ZIP" "$ZIP.sha256" "$FINAL_DIR/"
  echo "==> --stage-only: left the bundle in $FINAL_DIR (not uploaded, not signed)"
  exit 0
fi

# ------------------------------------------------------------------ attach to the release
echo "==> uploading to release $TAG"
(cd "$REPO_ROOT" && gh release upload "$TAG" "$ZIP" "$ZIP.sha256" --clobber)

# ------------------------------------------------------------------ (re-)bless the release
# Run here, not left to the operator, because the ordering is a trap: the manifest covers what
# was attached at the moment it was signed, and this script has just added an asset. A release
# blessed before this upload has a perfectly valid signature that simply does not mention the
# bundle — and the app treats an unlisted asset as untrusted, so the download would fail with a
# signature error that looks like tampering rather than like a missed step.
echo "==> blessing $TAG so the manifest covers this bundle (check for a PIN/touch prompt)"
"$REPO_ROOT/scripts/bless-release.sh" --tag "$TAG"

echo
echo "Done. $ASSET (+ .sha256) is attached to release $TAG and covered by its signed manifest."
echo "An app built from that same release will offer it under PCVR -> Download & install."
