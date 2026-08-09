#!/bin/bash
set -euo pipefail

# Build Longwave with Moonlight and attach the unsigned IPA to the GitHub
# release CI created for the current commit (tag 0.1.0-<sha8>), or create
# that release if CI hasn't.
#
# Prerequisites:
#   - gh CLI authenticated
#   - Xcode with visionOS SDK
# Local deps in repos/ are set up automatically via scripts/setup-deps.sh.
#
# Usage:
#   ./scripts/release.sh              # Build and release
#   ./scripts/release.sh --dry-run    # Build only, skip GitHub release

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo "  --dry-run  Build IPA but skip GitHub release"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$PROJECT_ROOT"

# Version from git — must match the CI workflow's tag scheme
# (0.1.0-<8-char sha>) so the Moonlight IPA attaches to the release CI
# created for this commit.
SHORT_SHA=$(git rev-parse --short=8 HEAD)
VERSION="0.1.0-${SHORT_SHA}"
IPA_NAME="Longwave-${VERSION}-moonlight-unsigned.ipa"

BUILD_DIR="$PROJECT_ROOT/build"

# --- Dependencies ---
"$SCRIPT_DIR/setup-deps.sh"
"$SCRIPT_DIR/set-build-info.sh"

# --- Build ---
echo "==> Building (Release + Moonlight)..."
xcodebuild build \
    -project Longwave.xcodeproj \
    -scheme Longwave \
    -configuration Release \
    -destination 'generic/platform=visionOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MOONLIGHT_ENABLED'

# --- Package IPA ---
echo "==> Packaging unsigned IPA..."
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name 'Longwave.app' -type d | head -1)
if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: No .app found in DerivedData" >&2
    exit 1
fi

rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
IPA_PATH="$BUILD_DIR/$IPA_NAME"
(cd "$BUILD_DIR" && rm -f "$IPA_NAME" && zip -qr "$IPA_NAME" Payload)
echo "  Built: $IPA_PATH"

if [[ "$DRY_RUN" == true ]]; then
    echo "==> Dry run — skipping GitHub release"
    exit 0
fi

# --- GitHub Release ---
# CI (on push to main) creates release $VERSION with the VNC-only IPA and
# the macOS Companion. If it exists, attach the Moonlight IPA to it;
# otherwise (CI hasn't run / commit not pushed) create the release here.
if gh release view "$VERSION" &>/dev/null; then
    echo "==> Attaching Moonlight IPA to existing release $VERSION..."
    gh release upload "$VERSION" --clobber "$IPA_PATH#$IPA_NAME"
else
    echo "==> No CI release for $VERSION — creating it..."
    gh release create "$VERSION" \
        --title "$VERSION" \
        --notes "Built from \`${SHORT_SHA}\` on $(date +%Y-%m-%d).

Includes an unsigned IPA built with Moonlight support (GPLv3). See [LICENSE](LICENSE.txt) for details." \
        --latest \
        "$IPA_PATH#$IPA_NAME"
fi

echo ""
echo "Done! Release: $(gh release view "$VERSION" --json url -q .url)"
