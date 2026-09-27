#!/usr/bin/env bash
#
# capture-screenshots.sh — App Store and in-app-purchase review screenshots of
# the App Store edition, taken in the visionOS simulator by
# LongwaveUITests/ScreenshotTests.
#
#   scripts/capture-screenshots.sh [--out DIR] [--device NAME]
#
#   --out DIR      Where the PNGs land. Default: build/screenshots.
#   --device NAME  Simulator to run on. Default: Apple Vision Pro.
#   --watch        Only answer capture requests (for a run started in Xcode),
#                  for up to 15 minutes; don't build or test.
#
# Each PNG is the full simulated room at 3840x2160, the size App Store Connect
# takes for Apple Vision Pro. The run seeds demo connections
# (-LongwaveScreenshotDemo, DEBUG-only).
#
# The paywall shot needs Xcode itself. The LongwaveUITests scheme points
# StoreKit at Configuration/Longwave.storekit, but only the Xcode app applies
# that; under xcodebuild the paywall has no products and the test fails there,
# after capturing the two screens before it. For a full set, build the App
# Store edition in Xcode (e.g. temporarily add
# `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) FOVEATED_ENABLED` and
# `XROS_DEPLOYMENT_TARGET = 26.4` to the gitignored Configuration/BuildInfo.xcconfig),
# run ScreenshotTests from the LongwaveUITests scheme, and run this script with
# --watch meanwhile to answer the test's capture requests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

out="$ROOT/build/screenshots"
device="Apple Vision Pro"
watch_only=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out="${2:-}"; shift 2 ;;
        --device) device="${2:-}"; shift 2 ;;
        --watch) watch_only=1; shift ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

EDITION=()
while IFS= read -r line; do EDITION+=("$line"); done \
    < <("$SCRIPT_DIR/edition-settings.sh" appstore)

[[ -f repos/royalvnc/Package.swift ]] || "$SCRIPT_DIR/setup-deps.sh"

udid="$(xcrun simctl list devices available \
    | sed -n "s/^ *$device (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)"
[[ -n "$udid" ]] || { echo "error: no available simulator named '$device'" >&2; exit 1; }

mkdir -p "$out"
rm -f "$out"/*.png "$out/.request"

# The test asks for each shot by writing its name to .request (XCUIScreen
# cannot capture on visionOS). Write to a temporary name and rename, so the
# test never sees a half-written PNG.
answer_requests() {
    if [[ -f "$out/.request" ]]; then
        local name
        name="$(cat "$out/.request")"
        rm -f "$out/.request"
        xcrun simctl io "$udid" screenshot "$out/.$name.png" >/dev/null 2>&1
        mv "$out/.$name.png" "$out/$name.png"
        echo "==> captured $name"
    fi
}

if [[ $watch_only == 1 ]]; then
    echo "==> Answering capture requests in $out (Ctrl-C to stop)"
    end=$((SECONDS + 900))
    while (( SECONDS < end )); do answer_requests; sleep 0.2; done
    exit 0
fi

# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process with the
# prefix stripped. -collect-test-diagnostics never: see ~/Projects/CLAUDE.md —
# a passing visionOS run otherwise hangs for 600 s collecting diagnostics.
TEST_RUNNER_LONGWAVE_SCREENSHOT_DIR="$out" xcodebuild test \
    -project Longwave.xcodeproj -scheme LongwaveUITests \
    -destination "platform=visionOS Simulator,id=$udid" \
    -collect-test-diagnostics never \
    "${EDITION[@]}" &
xcodebuild_pid=$!
trap 'kill "$xcodebuild_pid" 2>/dev/null || true' INT TERM

while kill -0 "$xcodebuild_pid" 2>/dev/null; do answer_requests; sleep 0.2; done
status=0
wait "$xcodebuild_pid" || status=$?

echo "==> Screenshots in $out:"
ls -1 "$out"
exit "$status"
