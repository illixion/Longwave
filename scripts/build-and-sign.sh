#!/bin/bash
set -euo pipefail

# Build and sign an app for device deployment.
#
# All signing material (certs, profiles, passwords) is read from
# build-signing.conf — nothing needs to be in the login keychain, so this
# works over SSH.
#
# Usage:
#   ./scripts/build-and-sign.sh                  # Release build + deploy (dev-signed)
#   ./scripts/build-and-sign.sh --debug          # Debug build + deploy
#   ./scripts/build-and-sign.sh --distribution   # Sign with the distribution cert/profile
#   ./scripts/build-and-sign.sh --no-deploy      # Sign but don't install to device
#   ./scripts/build-and-sign.sh --sign-only      # Skip build, sign existing IPA
#   ./scripts/build-and-sign.sh --ipa path.ipa   # Sign a specific IPA (implies --sign-only)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Load configuration ---
CONF_FILE="$SCRIPT_DIR/build-signing.conf"
if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONF_FILE" >&2
    echo "Copy scripts/build-signing.conf.example to scripts/build-signing.conf and edit it." >&2
    exit 1
fi
# shellcheck source=build-signing.conf
source "$CONF_FILE"

# Defaults for optional config values
PLATFORM="${PLATFORM:-visionOS}"
TARGET_NAME="${TARGET_NAME:-$SCHEME_NAME}"
P12_PASSWORD="${P12_PASSWORD:-}"
DEV_P12_PASSWORD="${DEV_P12_PASSWORD:-$P12_PASSWORD}"
DIST_P12_PASSWORD="${DIST_P12_PASSWORD:-$P12_PASSWORD}"
PRE_BUILD_HOOK="${PRE_BUILD_HOOK:-}"
# Extra xcodebuild settings (bash array), e.g. the Moonlight flag:
#   EXTRA_BUILD_SETTINGS=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MOONLIGHT_ENABLED')
if [[ -z "${EXTRA_BUILD_SETTINGS+x}" ]]; then EXTRA_BUILD_SETTINGS=(); fi

required_vars=(
    PROJECT_PATH SCHEME_NAME TARGET_NAME PLATFORM
    TEAM_ID BUILD_BUNDLE_ID DEVICE_NAME
    DEV_P12_PATH DEV_PROFILE_PATH
)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: Required variable $var is not set in $CONF_FILE" >&2
        exit 1
    fi
done

# --- Parse arguments ---
CONFIG="Release"
SIGN_ONLY=false
NO_DEPLOY=false
USE_DIST=false
INPUT_IPA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)         CONFIG="Debug"; shift ;;
        --distribution)  USE_DIST=true; shift ;;
        --sign-only)     SIGN_ONLY=true; shift ;;
        --no-deploy)     NO_DEPLOY=true; shift ;;
        --ipa)           INPUT_IPA="$2"; SIGN_ONLY=true; shift 2 ;;
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$USE_DIST" == true ]]; then
    P12_PATH="$DIST_P12_PATH"
    P12_PW="$DIST_P12_PASSWORD"
    PROFILE_PATH="$DIST_PROFILE_PATH"
    [[ -n "$P12_PATH" && -n "$PROFILE_PATH" ]] || {
        echo "ERROR: --distribution requires DIST_P12_PATH and DIST_PROFILE_PATH in $CONF_FILE" >&2
        exit 1
    }
else
    P12_PATH="$DEV_P12_PATH"
    P12_PW="$DEV_P12_PASSWORD"
    PROFILE_PATH="$DEV_PROFILE_PATH"
fi

for f in "$P12_PATH" "$PROFILE_PATH"; do
    [[ -f "$f" ]] || { echo "ERROR: File not found: $f" >&2; exit 1; }
done

# --- Work dir + cleanup ---
WORK_DIR=$(mktemp -d)
KEYCHAIN_PATH=""
ORIGINAL_KEYCHAINS=""

cleanup() {
    if [[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]]; then
        if [[ -n "$ORIGINAL_KEYCHAINS" ]]; then
            # shellcheck disable=SC2086
            security list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
        fi
        security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    [[ -n "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# --- Helpers ---

# Create a temporary keychain and import the given .p12 into it.
# Sets SIGN_IDENTITY to the SHA1 of the imported signing identity.
# Must be called directly, NOT via $(...): it sets KEYCHAIN_PATH and
# ORIGINAL_KEYCHAINS for the EXIT trap, and a command-substitution
# subshell would discard them — leaking the temp keychain into the
# user search list on every build.
setup_signing_keychain() {
    local p12="$1"
    local p12_password="$2"

    KEYCHAIN_PATH="$WORK_DIR/signing.keychain-db"
    local keychain_pass
    keychain_pass="$(openssl rand -hex 16)"

    security create-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null
    security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH" >/dev/null
    security unlock-keychain -p "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null

    # Prepend our keychain to the user search list so codesign can find it.
    ORIGINAL_KEYCHAINS=$(security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' | tr '\n' ' ')
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_KEYCHAINS >/dev/null

    security import "$p12" -k "$KEYCHAIN_PATH" -P "$p12_password" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_pass" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

    local sha1
    sha1=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
        | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')
    if [[ -z "$sha1" ]]; then
        echo "ERROR: No code-signing identity found in $p12" >&2
        echo "       (is the password correct?)" >&2
        exit 1
    fi
    SIGN_IDENTITY="$sha1"
}

extract_entitlements() {
    local profile_path="$1"
    local entitlements_plist="$2"
    security cms -D -i "$profile_path" 2>/dev/null \
        | plutil -extract Entitlements xml1 -o "$entitlements_plist" -- -
}

sign_app() {
    local app_path="$1"
    local identity="$2"
    local entitlements="$3"
    local keychain="$4"

    echo "Signing with identity: $identity"

    # Sign all embedded dylibs and frameworks first (deepest items first)
    find "$app_path" \( -name "*.dylib" -o -name "*.framework" \) | while read -r item; do
        echo "  Signing: $(basename "$item")"
        codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$item"
    done

    # Sign nested app extensions before the outer bundle (inside-out rule).
    # Same profile entitlements as the app — sideload profiles carry one
    # application-identifier for everything.
    find "$app_path/PlugIns" -maxdepth 1 -name '*.appex' -type d 2>/dev/null | while read -r appex; do
        echo "  Signing: $(basename "$appex") (with entitlements)"
        codesign --force --sign "$identity" --keychain "$keychain" \
            --entitlements "$entitlements" --timestamp=none "$appex"
    done

    # Sign the main app bundle with entitlements
    echo "  Signing: $(basename "$app_path") (with entitlements)"
    codesign --force --sign "$identity" --keychain "$keychain" \
        --entitlements "$entitlements" --timestamp=none "$app_path"
}

# --- Main ---

cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build"
IPA_PATH="$BUILD_DIR/${TARGET_NAME}.ipa"

# Figure out whether PROJECT_PATH is a project or a workspace
case "$PROJECT_PATH" in
    *.xcworkspace) PROJECT_FLAG="-workspace" ;;
    *.xcodeproj)   PROJECT_FLAG="-project" ;;
    *) echo "ERROR: PROJECT_PATH must end in .xcodeproj or .xcworkspace" >&2; exit 1 ;;
esac

# Step 1: Build (unless --sign-only)
if [[ "$SIGN_ONLY" == false ]]; then
    if [[ -n "$PRE_BUILD_HOOK" ]]; then
        echo "==> Running pre-build hook: $PRE_BUILD_HOOK"
        # shellcheck disable=SC2086
        ( cd "$PROJECT_ROOT" && eval $PRE_BUILD_HOOK )
    fi

    echo "==> Building for $PLATFORM ($CONFIG)..."
    xcodebuild -quiet \
        "$PROJECT_FLAG" "$PROJECT_PATH" \
        -scheme "$SCHEME_NAME" \
        -configuration "$CONFIG" \
        -destination "generic/platform=$PLATFORM" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        ${EXTRA_BUILD_SETTINGS[@]+"${EXTRA_BUILD_SETTINGS[@]}"} \
        build

    echo "==> Packaging IPA..."
    APP_PATH=$(find "$BUILD_DIR/DerivedData" -name '*.app' -type d | head -1)
    if [[ -z "$APP_PATH" ]]; then
        echo "ERROR: No .app bundle found in DerivedData" >&2
        exit 1
    fi
    rm -rf "$BUILD_DIR/Payload"
    mkdir -p "$BUILD_DIR/Payload"
    cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
    ( cd "$BUILD_DIR" && rm -f "${TARGET_NAME}.ipa" && zip -qr "${TARGET_NAME}.ipa" Payload )
    echo "  Built: $IPA_PATH"
fi

# Use custom IPA path if specified
if [[ -n "$INPUT_IPA" ]]; then
    IPA_PATH="$INPUT_IPA"
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "ERROR: IPA not found at $IPA_PATH" >&2
    exit 1
fi

# Step 2: Import signing cert into a temporary keychain
echo "==> Importing signing certificate from $(basename "$P12_PATH")..."
setup_signing_keychain "$P12_PATH" "$P12_PW"
echo "  Identity: $SIGN_IDENTITY"

# Step 3: Extract entitlements from the provisioning profile
ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"
extract_entitlements "$PROFILE_PATH" "$ENTITLEMENTS_PLIST"
echo "==> Using profile: $PROFILE_PATH"

# Step 4: Unpack IPA
echo "==> Unpacking IPA..."
UNPACK_DIR="$WORK_DIR/unpack"
mkdir -p "$UNPACK_DIR"
unzip -qo "$IPA_PATH" -d "$UNPACK_DIR"

APP_BUNDLE=$(find "$UNPACK_DIR/Payload" -name '*.app' -type d -maxdepth 1 | head -1)
if [[ -z "$APP_BUNDLE" ]]; then
    echo "ERROR: No .app found in IPA" >&2
    exit 1
fi

# Step 4.5: Enforce bundle identities. A command-line
# PRODUCT_BUNDLE_IDENTIFIER override would hit EVERY target (the broadcast
# extension would clone the app's ID → installd DuplicateIdentifier), so the
# IDs are patched per-bundle here instead.
echo "==> Setting bundle identifiers..."
plutil -replace CFBundleIdentifier -string "$BUILD_BUNDLE_ID" "$APP_BUNDLE/Info.plist"
APPEX_BUNDLE=$(find "$APP_BUNDLE/PlugIns" -maxdepth 1 -name '*.appex' -type d 2>/dev/null | head -1)
if [[ -n "$APPEX_BUNDLE" ]]; then
    plutil -replace CFBundleIdentifier -string "${BUILD_BUNDLE_ID}.broadcast" "$APPEX_BUNDLE/Info.plist"
    echo "  App:       $BUILD_BUNDLE_ID"
    echo "  Extension: ${BUILD_BUNDLE_ID}.broadcast"
fi

# Step 5: Embed provisioning profile (app + extension; both bundles resolve
# their shared App Group from it at runtime)
echo "==> Embedding provisioning profile..."
cp "$PROFILE_PATH" "$APP_BUNDLE/embedded.mobileprovision"
if [[ -n "$APPEX_BUNDLE" ]]; then
    cp "$PROFILE_PATH" "$APPEX_BUNDLE/embedded.mobileprovision"
fi

# Step 6: Sign
echo "==> Signing app bundle..."
sign_app "$APP_BUNDLE" "$SIGN_IDENTITY" "$ENTITLEMENTS_PLIST" "$KEYCHAIN_PATH"

# Step 7: Repack as signed IPA
SIGNED_IPA="${IPA_PATH%.ipa}-signed.ipa"
echo "==> Repacking signed IPA..."
( cd "$UNPACK_DIR" && rm -f "$SIGNED_IPA" && zip -qr "$SIGNED_IPA" Payload )
echo ""
echo "Done! Signed IPA: $SIGNED_IPA"

# Step 8: Verify
echo ""
echo "==> Verification:"
codesign -dvvv "$APP_BUNDLE" 2>&1 | grep -E "^(Authority|TeamIdentifier|Identifier|Signature)"

# Step 9: Deploy to device
if [[ "$NO_DEPLOY" == false ]]; then
    echo ""
    echo "==> Deploying to $DEVICE_NAME..."
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_NAME" | awk '{print $3}')
    if [[ -z "$DEVICE_ID" ]]; then
        echo "ERROR: Device '$DEVICE_NAME' not found. Is it connected and paired?" >&2
        echo "Available devices:"
        xcrun devicectl list devices 2>/dev/null | grep -E "available|connected"
        exit 1
    fi
    xcrun devicectl device install app --device "$DEVICE_ID" "$SIGNED_IPA"
    echo ""
    echo "Installed on $DEVICE_NAME!"
else
    echo ""
    echo "To install: xcrun devicectl device install app --device <UDID> '$SIGNED_IPA'"
fi
