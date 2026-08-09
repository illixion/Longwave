#!/usr/bin/env bash
#
# Deploy the Longwave Windows Companion to the RTX/PCVR host and provision it.
#
# Sync source -> publish backend -> stage the CloudXR SDK -> write launch helpers ->
# register the interactive-session scheduled tasks -> npm install the Electron UI.
# Everything is idempotent, so this is the iterate-on-a-change command.
#
#   scripts/deploy-windows-companion.sh                 # full deploy
#   scripts/deploy-windows-companion.sh --no-ui         # backend only (skip npm install)
#   scripts/deploy-windows-companion.sh --status        # what is the host doing right now
#   scripts/deploy-windows-companion.sh --session start # flip the host into PCVR mode
#   scripts/deploy-windows-companion.sh --session stop   # restore SteamVR + Sunshine
#
# Why a tarball over scp instead of rsync: the host is Windows OpenSSH with a
# PowerShell default shell — no rsync, and `tar.exe` ships in system32.
#
# Why scheduled tasks rather than launching over SSH: NvStreamManager's RPC TLS key
# pair is DPAPI-protected and a pubkey-auth SSH session has no unlocked DPAPI master
# key, so it crash-loops with "Failed to load key pair". The tasks run in the
# logged-on interactive session, which works.

set -euo pipefail

HOST="${LONGWAVE_PC_HOST:-pc}"
ROOT_WIN='C:\dev\Longwave-companion'
# Sibling of ROOT_WIN, exactly as main.js's resolvePcvrHostExe() expects to find it relative to
# app/src (../../../Longwave-PCVR-Host). Not part of CompanionWindows/: it's a separate project
# in this repo today, and will be a separate repo entirely once the split lands.
PCVR_HOST_WIN='C:\dev\Longwave-PCVR-Host'
# Forward slashes: scp will not take a Windows backslash path, and both tar.exe and
# PowerShell accept them fine.
REMOTE_TMP='C:/Windows/Temp/longwave-companion.tar'
PCVR_HOST_REMOTE_TMP='C:/Windows/Temp/longwave-pcvr-host.tar'
REMOTE_MANIFEST='C:/Windows/Temp/longwave-companion.manifest'
PCVR_HOST_REMOTE_MANIFEST='C:/Windows/Temp/longwave-pcvr-host.manifest'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/CompanionWindows"
PCVR_HOST_SRC="$REPO_ROOT/Longwave-PCVR-Host"

NO_UI=0
NO_BUILD=0
DO_DEPLOY=1
SESSION=""
STATUS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-ui)    NO_UI=1 ;;
    --no-build) NO_BUILD=1 ;;
    --status)   STATUS=1; DO_DEPLOY=0 ;;
    --session)  SESSION="${2:?--session needs start|stop}"; DO_DEPLOY=0; shift ;;
    --host)     HOST="${2:?--host needs a value}"; shift ;;
    -h|--help)  sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

SSH_EXEC="$HOME/.claude/bin/ssh-exec"

# Run a PowerShell script on the host. ssh-exec base64s it as -EncodedCommand, so no
# quoting hell — $vars, quotes and backslash paths survive verbatim. Windows OpenSSH
# does not propagate remote exit codes faithfully, so callers judge by output.
ps_exec() {
  local desc="$1" timeout="$2" script="$3"
  "$SSH_EXEC" exec --host "$HOST" --powershell --desc "$desc" --timeout "$timeout" --command "$script"
}

if [[ -n "$SESSION" ]]; then
  ps_exec "pcvr-session $SESSION" 180 "& '$ROOT_WIN\\scripts\\pcvr-session.ps1' -Mode $SESSION"
  exit 0
fi

if [[ "$STATUS" == 1 ]]; then
  ps_exec 'pcvr host status' 120 "& '$ROOT_WIN\\scripts\\pcvr-session.ps1' -Mode status"
  exit 0
fi

[[ "$DO_DEPLOY" == 1 ]] || exit 0

# ------------------------------------------------------------------ pack + ship
STAGE="$(mktemp -d -t longwave-companion)"
TAR="$STAGE/companion.tar"
trap 'rm -rf "$STAGE"' EXIT

echo "==> packing $SRC"
# COPYFILE_DISABLE stops macOS bsdtar from emitting AppleDouble "._foo.cs" sidecars for
# extended attributes — the C# compiler picks those up as source and fails CS2015.
# The --exclude is belt-and-braces for any that already exist on disk.
COPYFILE_DISABLE=1 tar -cf "$TAR" -C "$SRC" \
  --exclude='._*' \
  --exclude='node_modules' \
  --exclude='bin' \
  --exclude='obj' \
  --exclude='dist' \
  --exclude='.vs' \
  --exclude='spike' \
  .
echo "    $(du -h "$TAR" | cut -f1)"

PCVR_HOST_TAR="$STAGE/pcvr-host.tar"
if [[ -d "$PCVR_HOST_SRC" ]]; then
  echo "==> packing $PCVR_HOST_SRC"
  COPYFILE_DISABLE=1 tar -cf "$PCVR_HOST_TAR" -C "$PCVR_HOST_SRC" \
    --exclude='._*' \
    --exclude='bin' \
    --exclude='obj' \
    .
  echo "    $(du -h "$PCVR_HOST_TAR" | cut -f1)"
else
  echo "==> $PCVR_HOST_SRC not present locally - skipping (public-only checkout)"
fi

# Manifests, so the extract can delete as well as add. An unpack-over-the-top can only
# ever notice files that still exist: when the PCVR split MOVED backend/Foveated/*.cs into
# the private submodule, every one of them stayed behind on the host, and an SDK-style
# csproj globs **/*.cs — so the build kept compiling the moved files against a csproj that
# no longer carried their PackageReferences and failed with twenty CS0246s that named our
# own types. Nothing in the deploy could have caught that, because the deletion is exactly
# what an additive sync cannot see.
MANIFEST="$STAGE/companion.manifest"
tar -tf "$TAR" | sed 's|^\./||' | grep -v '/$' > "$MANIFEST"
PCVR_HOST_MANIFEST="$STAGE/pcvr-host.manifest"
[[ -f "$PCVR_HOST_TAR" ]] && tar -tf "$PCVR_HOST_TAR" | sed 's|^\./||' | grep -v '/$' \
  > "$PCVR_HOST_MANIFEST"

echo "==> shipping to $HOST"
scp -q "$TAR" "$HOST:$REMOTE_TMP"
scp -q "$MANIFEST" "$HOST:$REMOTE_MANIFEST"
if [[ -f "$PCVR_HOST_TAR" ]]; then
  scp -q "$PCVR_HOST_TAR" "$HOST:$PCVR_HOST_REMOTE_TMP"
  scp -q "$PCVR_HOST_MANIFEST" "$HOST:$PCVR_HOST_REMOTE_MANIFEST"
fi

# Unpack over the existing tree. Source files are replaced; bin/obj/node_modules and
# the staged CloudXR Server/ live under paths the tarball does not contain, so an
# in-place extract preserves them (and keeps npm install incremental).
echo "==> unpacking + provisioning"
ps_exec 'unpack companion source' 180 "
\$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path '$ROOT_WIN' | Out-Null
Push-Location '$ROOT_WIN'
tar.exe -xf '$REMOTE_TMP'
if (\$LASTEXITCODE -ne 0) { throw 'tar extract failed' }
Pop-Location
Remove-Item '$REMOTE_TMP' -Force
if (Test-Path '$PCVR_HOST_REMOTE_TMP') {
  New-Item -ItemType Directory -Force -Path '$PCVR_HOST_WIN' | Out-Null
  Push-Location '$PCVR_HOST_WIN'
  tar.exe -xf '$PCVR_HOST_REMOTE_TMP'
  if (\$LASTEXITCODE -ne 0) { throw 'pcvr-host tar extract failed' }
  Pop-Location
  Remove-Item '$PCVR_HOST_REMOTE_TMP' -Force
}
# Sweep any AppleDouble sidecars left by an earlier deploy — the C# compiler treats
# them as source files and fails with CS2015. Match on the name rather than -Filter
# '._*': the filesystem wildcard does not match the bare '._.' the tar root produces.
foreach (\$root in @('$ROOT_WIN', '$PCVR_HOST_WIN')) {
  if (-not (Test-Path \$root)) { continue }
  Get-ChildItem \$root -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { \$_.Name.StartsWith('._') } |
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

# Prune source files the tarball no longer carries. Scoped to source EXTENSIONS on
# purpose rather than 'delete anything not in the manifest': the host legitimately holds
# files this sync knows nothing about — provision-pc.ps1's generated tools\\*.bat, logs\\,
# the staged CloudXR Server\\ — and deleting those would trade one bug for a worse one.
# What has to go is a moved-away .cs or .js the compiler or the bundler would otherwise
# still pick up, which is precisely what an add-only sync cannot see.
function Prune-Removed([string] \$root, [string] \$manifestPath) {
  if (-not (Test-Path \$root) -or -not (Test-Path \$manifestPath)) { return }
  \$keep = [System.Collections.Generic.HashSet[string]]::new(
      [string[]](Get-Content \$manifestPath), [StringComparer]::OrdinalIgnoreCase)
  \$prefix = (Resolve-Path \$root).Path.TrimEnd('\\') + '\\'
  # Only extensions a build actually GLOBS, which is the entire failure class: an
  # SDK-style csproj compiles **/*.cs, so a moved-away .cs is still built. A stale .html,
  # .css or .json is inert — every one of those is referenced by an explicit path — and
  # .json in particular is where the host keeps its own state. Pruning by 'not in the
  # manifest' took game-library.json with it on the first run, which is the user's Steam
  # library and per-title profiles, not something this sync has any business deleting.
  \$sourceExt = @('.cs', '.js', '.mjs', '.cjs')
  \$skipDir = @('\\node_modules\\', '\\bin\\', '\\obj\\', '\\dist\\', '\\.vs\\', '\\logs\\', '\\Server\\')
  \$removed = 0
  foreach (\$file in Get-ChildItem \$root -Recurse -File -Force -ErrorAction SilentlyContinue) {
    if (\$sourceExt -notcontains \$file.Extension.ToLower()) { continue }
    \$full = \$file.FullName
    \$skip = \$false
    foreach (\$d in \$skipDir) { if (\$full.IndexOf(\$d, [StringComparison]::OrdinalIgnoreCase) -ge 0) { \$skip = \$true; break } }
    if (\$skip) { continue }
    \$relative = \$full.Substring(\$prefix.Length).Replace('\\', '/')
    if (-not \$keep.Contains(\$relative)) {
      Remove-Item \$full -Force -ErrorAction SilentlyContinue
      \"  pruned \$relative\"
      \$removed++
    }
  }
  if (\$removed -gt 0) { \"  (\$removed stale source file(s) removed from \$root)\" }
}
Prune-Removed '$ROOT_WIN' '$REMOTE_MANIFEST'
Prune-Removed '$PCVR_HOST_WIN' '$PCVR_HOST_REMOTE_MANIFEST'
Remove-Item '$REMOTE_MANIFEST', '$PCVR_HOST_REMOTE_MANIFEST' -Force -ErrorAction SilentlyContinue

# A directory the prune emptied is noise at best; at worst it reads as a source tree
# mysteriously missing its files.
foreach (\$root in @('$ROOT_WIN', '$PCVR_HOST_WIN')) {
  if (-not (Test-Path \$root)) { continue }
  Get-ChildItem \$root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
    Sort-Object { \$_.FullName.Length } -Descending |
    Where-Object { -not (Get-ChildItem \$_.FullName -Force -ErrorAction SilentlyContinue) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
'unpacked -> $ROOT_WIN'
"

PROVISION_ARGS="-Root '$ROOT_WIN' -PcvrHostRoot '$PCVR_HOST_WIN'"
[[ "$NO_UI" == 1 ]] && PROVISION_ARGS="$PROVISION_ARGS -NoUi"
[[ "$NO_BUILD" == 1 ]] && PROVISION_ARGS="$PROVISION_ARGS -NoBuild"

# Generous timeout: a cold self-contained publish plus npm install is minutes.
ps_exec 'provision companion' 900 "& '$ROOT_WIN\\scripts\\provision-pc.ps1' $PROVISION_ARGS"

cat <<EOF

Deployed to $ROOT_WIN on $HOST.

Next:
  scripts/deploy-windows-companion.sh --session start     # CloudXR runtime + OpenComposite, Sunshine off
  ssh $HOST "schtasks /run /tn Longwave-CompanionUI"     # Electron UI (spawns the backend) in session 1
  # press Start host in the Foveated panel, launch the content app, connect the AVP
  scripts/deploy-windows-companion.sh --session stop      # restore SteamVR + Sunshine
EOF
