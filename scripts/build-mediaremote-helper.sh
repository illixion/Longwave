#!/bin/bash
#
# Compiles the MediaRemote now-playing helper (MediaRemoteHelper/) into a
# universal dylib.
#
# The helper is loaded by /usr/bin/perl, never by Longwave itself, so it is
# bundled as a plain resource rather than linked or embedded as a framework.
# See MediaRemoteHelper/README.md for why the perl host is necessary.
#
# Usage:
#   scripts/build-mediaremote-helper.sh <output-dylib-path> [arch ...]
#
# Run from an Xcode script phase it picks up MACOSX_DEPLOYMENT_TARGET, ARCHS and
# EXPANDED_CODE_SIGN_IDENTITY automatically. Standalone it builds arm64+x86_64
# and leaves the result unsigned.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/MediaRemoteHelper/longwave-mediaremote.m"

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <output-dylib-path> [arch ...]" >&2
    exit 64
fi

OUTPUT="$1"
shift

# Architectures: explicit arguments, else Xcode's ARCHS, else universal.
if [ $# -gt 0 ]; then
    ARCH_LIST="$*"
elif [ -n "${ARCHS:-}" ]; then
    ARCH_LIST="$ARCHS"
else
    ARCH_LIST="arm64 x86_64"
fi

ARCH_FLAGS=""
for arch in $ARCH_LIST; do
    ARCH_FLAGS="$ARCH_FLAGS -arch $arch"
done

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

if [ ! -f "$SOURCE" ]; then
    echo "error: helper source not found at $SOURCE" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

# Skip the rebuild when the output is already newer than the source — Xcode runs
# script phases on every incremental build.
if [ -f "$OUTPUT" ] && [ "$OUTPUT" -nt "$SOURCE" ]; then
    echo "note: $(basename "$OUTPUT") is up to date"
    exit 0
fi

# Compile and sign in a temporary directory rather than in place. Under Xcode's
# user script sandboxing the only writable path is the declared output itself —
# not even DERIVED_FILE_DIR is writable — and codesign writes a sibling
# "<name>.cstemp" before renaming it, which would be denied. Staging in a temp
# directory and copying the finished dylib over keeps sandboxing enabled.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
STAGED="$SCRATCH/$(basename "$OUTPUT")"

# No -framework MediaRemote: the private framework is resolved with dlopen at
# runtime, inside the perl host. Linking it here would both fail to help and
# put a private-framework load command in a shipped binary.
# shellcheck disable=SC2086
xcrun clang \
    -dynamiclib \
    -fobjc-arc \
    -fvisibility=hidden \
    -O2 \
    -Wall \
    $ARCH_FLAGS \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -framework Foundation \
    -o "$STAGED" \
    "$SOURCE"

# Sign when Xcode gave us an identity, so the dylib satisfies the notarization
# requirement that every nested Mach-O carry a Developer ID signature and a
# secure timestamp. Ad-hoc otherwise, which is all an unsigned local build or
# the unsigned GitHub artifact needs — and what the `codesign --deep --sign -`
# step in the release instructions re-applies anyway.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$STAGED"
else
    codesign --force --sign - "$STAGED" 2>/dev/null || true
fi

if [ "$STAGED" != "$OUTPUT" ]; then
    cp -f "$STAGED" "$OUTPUT"
fi

echo "built $(basename "$OUTPUT") [$ARCH_LIST]"
