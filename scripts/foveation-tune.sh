#!/usr/bin/env bash
# foveation-tune.sh — flip CloudXR foveation settings on the PCVR host and restart the
# streaming service so the next headset connection picks them up.
#
# The knobs live in the Stream Manager's cloudxr-runtime.yaml, which is part of the
# NVIDIA download rather than this repo (see CompanionWindows/README.md), so they cannot
# be version-controlled — this script is the reproducible record of what we set and why.
#
# Usage:
#   scripts/foveation-tune.sh show
#   scripts/foveation-tune.sh set runtimeFoveationUnwarpedWidth=4096 \
#                                 runtimeFoveationWarpedWidth=2400
#   scripts/foveation-tune.sh preset baseline|unwarped4096|pinwarped|max
#   scripts/foveation-tune.sh measure          # foveation dims from the last session
#
# After `set`, the CloudXR service is killed; the backend re-spawns it (and re-reads the
# yaml) on the next connect, so just reconnect the headset. Every edit keeps a .bak.
#
# Why this matters (measured 2026-07-26): the runtime starts at 2400x1920 warped per eye
# and then HALVES it to 1200x960 the moment the visionOS client's SystemInfo arrives
# ("Ignoring streaming dimensions 4096x4096, expected 2400x1920"). That is a 4x pixel
# loss before the encoder — far more of the on-device softness than the unwarped render
# width, which was the original suspect. `runtimeFoveationWarpedWidth` pins the warped
# size so the halving cannot apply.
#
# Do NOT set maxFps (measured 2026-07-27). It does not merely cap the rate — it switches
# CloudXR to a fixed-timestep scheduler that slips any frame overrunning its slot by a
# whole period ("predictBlocking: Frame took longer than the configured fixed time step",
# thousands per session) and it is felt as relentless microstutter. Leaving it at 0 gives
# adaptive pacing, which logged zero such warnings and zero dropped frames on the same
# workload. Panel-rate mismatch is real but is not fixable from this end.

set -euo pipefail

HOST=pc
SSH_EXEC="$HOME/.claude/bin/ssh-exec"
YAML='C:\dev\VisionVNC-companion\backend\bin\Release\net8.0-windows10.0.22621.0\publish\Server\cloudxr-runtime.yaml'

ps() { "$SSH_EXEC" exec --host "$HOST" -P --timeout "${2:-180}" --desc "$3" --command "$1"; }

cmd=${1:-show}
shift || true

case "$cmd" in
show)
    ps "Get-Content '$YAML'" 120 "Show foveation config"
    ;;

measure)
    # The service logs the negotiated foveation geometry once per connect; that is the
    # ground truth for whether a setting was accepted or silently overridden.
    ps '$log = Get-ChildItem "$env:LOCALAPPDATA\Temp\com.nvidia.CloudXR_*\cxr_server.*.log" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-Output "LOG: $($log.FullName)"
        Select-String -Path $log.FullName -Pattern "foveationUnwarpedWidth|foveationWarpedWidth|foveationInset|dynamicFoveation|updateFoveationParams|warped:|Pixel totals|streaming resolution|render resolution|Ignoring streaming" |
            ForEach-Object { $_.Line } | Select-Object -Last 30' 200 "Measure negotiated foveation"
    ;;

set)
    [ "$#" -gt 0 ] || { echo "usage: $0 set key=value [key=value...]" >&2; exit 2; }
    # Build a PowerShell hashtable of the requested keys.
    pairs=""
    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        pairs="$pairs '$key' = '$value';"
    done
    ps "\$wanted = @{ $pairs }
        Copy-Item '$YAML' '$YAML.bak' -Force
        \$lines = Get-Content '$YAML'
        foreach (\$key in \$wanted.Keys) {
            \$value = \$wanted[\$key]
            \$hit = \$false
            \$lines = \$lines | ForEach-Object {
                if (\$_ -match \"^(\\s*)\$key\\s*:\") {
                    \$hit = \$true
                    \"\$(\$matches[1])\$key\`: \$value\"
                } else { \$_ }
            }
            if (-not \$hit) {
                # featureFlags is the only mapping in the file; append into it.
                \$lines += \"  \$key\`: \$value\"
                Write-Output \"added \$key = \$value\"
            } else {
                Write-Output \"set \$key = \$value\"
            }
        }
        Set-Content '$YAML' \$lines
        Get-Content '$YAML' | Select-String 'foveation|deviceProfile' | ForEach-Object { \$_.Line }
        Stop-Process -Name CloudXrService -Force -ErrorAction SilentlyContinue
        Write-Output 'CloudXR service stopped — reconnect the headset to apply.'" 200 \
        "Set foveation config"
    ;;

preset)
    case "${1:-}" in
    baseline)   set -- runtimeFoveationUnwarpedWidth=3800 runtimeFoveationWarpedWidth=0 ;;
    unwarped4096) set -- runtimeFoveationUnwarpedWidth=4096 runtimeFoveationWarpedWidth=0 ;;
    # Pin the warped size so the client-negotiation halving cannot apply: 4x the encoded
    # pixels of baseline. Costs encoder headroom — check fps and encode time after.
    pinwarped)  set -- runtimeFoveationUnwarpedWidth=3800 runtimeFoveationWarpedWidth=2400 ;;
    # The live-game sweet spot (measured 2026-07-26 in HL2VR): 2400 warped is 4x the
    # halved baseline's pixels, which pushed encode to 17 ms (>1 frame) and exceeded the
    # AVP's decode budget — CloudXR's flow control collapsed to ~8 fps with bitrate sag.
    # 1600x1280 is 1.78x the halved baseline (visibly sharper), ~7.5 ms encode, and
    # ~490 MPix/s client decode at 120 Hz — sustainable on both ends.
    pin1600)    set -- runtimeFoveationUnwarpedWidth=4096 runtimeFoveationWarpedWidth=1600 ;;
    max)        set -- runtimeFoveationUnwarpedWidth=4096 runtimeFoveationWarpedWidth=2400 ;;
    *) echo "presets: baseline | unwarped4096 | pinwarped | pin1600 | max" >&2; exit 2 ;;
    esac
    exec "$0" set "$@"
    ;;

*)
    sed -n '2,30p' "$0"
    exit 2
    ;;
esac
