#!/bin/bash
#
# Copies the agent-sandbox installer (scripts/agent-sandbox/) into Longwave
# Companion's Resources/agent-sandbox, with semd.c prebuilt as
# longwave-sandbox-semd, so the Companion can install the sandbox itself behind
# one administrator prompt — no checkout and no command-line tools needed.
#
# Usage:
#   scripts/bundle-agent-sandbox.sh <output-dir>
#
# Run from an Xcode script phase it picks up MACOSX_DEPLOYMENT_TARGET, ARCHS and
# EXPANDED_CODE_SIGN_IDENTITY, like build-mediaremote-helper.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/agent-sandbox"

if [ $# -ne 1 ]; then
    echo "usage: $(basename "$0") <output-dir>" >&2
    exit 64
fi
OUTPUT="$1"
mkdir -p "$OUTPUT"

for file in install.sh uninstall.sh longwave-sandbox provision-golden.sh pro.longwave.sandbox.plist; do
    cp -f "$SOURCE_DIR/$file" "$OUTPUT/$file"
done
chmod 755 "$OUTPUT/install.sh" "$OUTPUT/uninstall.sh" "$OUTPUT/longwave-sandbox" "$OUTPUT/provision-golden.sh"

SEMD="$OUTPUT/longwave-sandbox-semd"
if [ -f "$SEMD" ] && [ "$SEMD" -nt "$SOURCE_DIR/semd.c" ]; then
    echo "note: longwave-sandbox-semd is up to date"
    exit 0
fi

ARCH_FLAGS=""
for arch in ${ARCHS:-arm64 x86_64}; do
    ARCH_FLAGS="$ARCH_FLAGS -arch $arch"
done

# Staged outside the output, as build-mediaremote-helper.sh explains: codesign
# writes a sibling temp file that script sandboxing would deny.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
# shellcheck disable=SC2086
xcrun clang -Os -Wall $ARCH_FLAGS \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.2}" \
    -o "$SCRATCH/semd" "$SOURCE_DIR/semd.c"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp --options runtime "$SCRATCH/semd"
else
    codesign --force --sign - "$SCRATCH/semd" 2>/dev/null || true
fi
cp -f "$SCRATCH/semd" "$SEMD"
echo "bundled agent sandbox installer"
