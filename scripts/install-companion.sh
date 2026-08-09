#!/bin/bash
set -euo pipefail

# Build a macOS Longwave app, install it to /Applications, and restart it —
# quitting the running copy first and relaunching the freshly installed one. For
# a fast local rebuild-test loop: TCC permissions (Accessibility, Screen/Audio
# Recording, Automation) and the stored token live with the app in
# /Applications, not with Xcode's DerivedData build, so running the installed
# copy is what you actually test.
#
# Builds the small menu-bar **companion** by default, or the **full** macOS app
# (LongwaveMac — full client + companion host features) when passed "full".
#
# Usage:   scripts/install-companion.sh [companion|full]   (default: companion)
#   companion  the lightweight menu-bar host app (MIT)
#   full       the full LongwaveMac client+host app (links Moonlight → GPLv3;
#              runs scripts/setup-deps.sh first to fetch the real dependencies)
#
# Why signing matters here: macOS ties TCC privacy grants (Accessibility,
# Screen/Audio Recording, Automation) to the app's code-signing identity. An
# ad-hoc signature ("-") gets a fresh, unstable cdhash on every build, so each
# rebuild looks like a brand-new app and macOS silently drops every grant — you
# re-approve all the prompts after every install. Signing with your stable Apple
# Development identity (the one Xcode already provisions for this Mac) keeps the
# signing identity constant across rebuilds, so the grants stick.
#
# By default this script auto-detects your "Apple Development" identity from the
# login keychain and signs with it. If none is found it falls back to ad-hoc and
# warns. Override detection with SIGN_IDENTITY (e.g. SIGN_IDENTITY="-" to force
# ad-hoc, or a specific identity name / 40-char SHA-1 hash).
#
# Options (env):
#   CONFIG=Debug          build configuration (default: Release)
#   SIGN_IDENTITY="…"     codesign identity. Default: auto-detected Apple
#                         Development identity (falls back to "-", ad-hoc).
#                         Pass "-" to force ad-hoc, or a name/hash to pin one.
#
# Note: the companion's bundle id is pro.longwave.companion. After the
# rename from "Audio Sender" (a different bundle id), macOS treats this as a new
# app — re-grant permissions on first launch and re-pair the token.

# Which app to build/install: the small menu-bar "companion" (default), or the
# "full" macOS app (LongwaveMac — the VNC/Moonlight/Audio/SSH client *plus* the
# companion host features in one app). The full app links Moonlight (GPLv3), so
# it needs the real dependencies cloned/patched into repos/ first (setup-deps.sh).
KIND="${1:-companion}"
case "$KIND" in
  companion)
    SCHEME="LongwaveCompanion"; APP_NAME="LongwaveCompanion.app"
    EXEC_NAME="LongwaveCompanion"; BUNDLE_ID="pro.longwave.companion"
    NEEDS_DEPS=0 ;;
  full|mac|LongwaveMac)
    SCHEME="LongwaveMac"; APP_NAME="LongwaveMac.app"
    EXEC_NAME="LongwaveMac"; BUNDLE_ID="pro.longwave.mac"
    NEEDS_DEPS=1 ;;
  -h|--help|help)
    echo "usage: $0 [companion|full]   (default: companion)"; exit 0 ;;
  *)
    echo "✗ unknown app kind: '$KIND' (expected 'companion' or 'full')" >&2; exit 2 ;;
esac
CONFIG="${CONFIG:-Release}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$PROJECT_DIR/build/${SCHEME}-dd"   # build/ is gitignored
DEST="/Applications/$APP_NAME"

cd "$PROJECT_DIR"

# Resolve the signing identity. If the caller didn't pin one, find the first
# valid "Apple Development" codesigning identity in the keychain — this is the
# per-Mac identity Xcode provisions, and signing with it keeps TCC grants stable
# across rebuilds. Fall back to ad-hoc with a warning if there isn't one.
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "▶ Auto-detected signing identity: $SIGN_IDENTITY"
  else
    SIGN_IDENTITY="-"
    echo "⚠ No 'Apple Development' identity found — falling back to ad-hoc (\"-\")." >&2
    echo "  TCC privacy grants will NOT persist across rebuilds. Open Xcode once" >&2
    echo "  to provision a signing identity, or pass SIGN_IDENTITY explicitly." >&2
  fi
fi

# The full app links Moonlight, so make sure the real (patched) dependencies are
# present in repos/ before building (idempotent; no-op once cloned). MOONLIGHT_ENABLED
# is baked into the LongwaveMac target, so no extra build flag is needed.
if [ "$NEEDS_DEPS" -eq 1 ]; then
  echo "▶ Ensuring Moonlight dependencies (setup-deps.sh)…"
  ./scripts/setup-deps.sh

  # The Opus package used to ship a hand-written modulemap. Xcode persists its
  # absolute path in DerivedData, so an incremental build created before that
  # file was removed fails instead of regenerating the package module. Clean
  # only when this specific stale reference is present.
  REMOVED_OPUS_MODULEMAP="$PROJECT_DIR/repos/opus/include/module.modulemap"
  if [ ! -e "$REMOVED_OPUS_MODULEMAP" ] \
      && [ -d "$DERIVED/Build" ] \
      && grep -RqsF "$REMOVED_OPUS_MODULEMAP" "$DERIVED/Build"; then
    echo "▶ Cleaning stale Opus package build plan…"
    xcodebuild \
      -project Longwave.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIG" \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$DERIVED" \
      clean
  fi
fi

# Manual signing with a real identity; automatic (Xcode-managed) only matters
# for provisioning profiles, which a local app doesn't need. Ad-hoc
# still requires CODE_SIGN_STYLE=Manual + a literal "-" identity.
echo "▶ Building $SCHEME ($CONFIG, signing: $SIGN_IDENTITY)…"
xcodebuild \
  -project Longwave.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
if [ ! -d "$BUILT" ]; then
  echo "✗ Built app not found at: $BUILT" >&2
  exit 1
fi

echo "▶ Quitting the running app (if any)…"
# Graceful quit of the current build by bundle id; only if it's actually
# running (so AppleScript doesn't launch it just to quit it).
if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
fi
# Also clear the pre-rename "Audio Sender" so you don't end up with two
# menu-bar items the first time you run this after the rebrand.
pkill -x "LongwaveAudioSender" 2>/dev/null || true
# Wait for the menu-bar item / file handles to release, then force-stop if it
# ignored the quit.
for _ in $(seq 1 10); do
  pgrep -x "$EXEC_NAME" >/dev/null 2>&1 || break
  sleep 0.3
done
pkill -x "$EXEC_NAME" 2>/dev/null || true

echo "▶ Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

echo "▶ Launching…"
open "$DEST"

echo "✓ $SCHEME ($CONFIG) installed to /Applications and relaunched."
