#!/usr/bin/env bash
#
# archive-appstore.sh — archive and export the App Store edition of the
# visionOS app for TestFlight / App Store Connect.
#
#   scripts/archive-appstore.sh [options]
#
#   --version X.Y[.Z]  CFBundleShortVersionString. Default: the project's
#                      MARKETING_VERSION.
#   --build N          CFBundleVersion. Default: `git rev-list --count HEAD`,
#                      which only grows along main. Must be a plain integer.
#   --team ID          Development team. Default: TEAM_ID from the local,
#                      gitignored scripts/build-signing.conf (only that one
#                      line is read), or $LONGWAVE_TEAM_ID.
#   --out DIR          Where the .xcarchive and export land.
#                      Default: build/appstore/<version>-<build>.
#   --upload           Export with destination=upload, sending the build
#                      straight to App Store Connect. Without it the signed
#                      .ipa is only written to --out.
#   --dry-run          Resolve and check the build settings, print the plan,
#                      and stop before archiving.
#   --unsigned         Archive with code signing disabled and skip the
#                      export. For checking the pipeline on a machine with no
#                      signing identity; the result cannot be uploaded.
#   --allow-dirty      Archive a working tree with uncommitted changes.
#
# Signing is automatic (-allowProvisioningUpdates): Xcode must be signed in to
# an account on the team, with the App ID pro.longwave.app carrying the App
# Group and Foveated Streaming capabilities.
#
# Independent of any dev-deploy configuration on purpose: the edition comes
# from scripts/edition-settings.sh alone, build-signing.conf contributes only
# the team ID, and the script refuses to continue if PCVR_UNLOCKED or
# LONGWAVE_INTERNAL appear anywhere in the resolved build settings, or if the
# archived app contains any string scripts/check-app-strings.sh forbids.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

PROJECT="Longwave.xcodeproj"
SCHEME="Longwave"
CONFIGURATION="Release"
DESTINATION="generic/platform=visionOS"
EXPECTED_BUNDLE_ID="pro.longwave.app"
EXPORT_TEMPLATE="$SCRIPT_DIR/ExportOptions-appstore.plist"

version=""
build=""
team="${LONGWAVE_TEAM_ID:-}"
out=""
upload=0
dry_run=0
unsigned=0
allow_dirty=0

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2:-}"; shift 2 ;;
        --build) build="${2:-}"; shift 2 ;;
        --team) team="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --upload) upload=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --unsigned) unsigned=1; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ $upload == 1 && $unsigned == 1 ]] && die "--upload and --unsigned are mutually exclusive"

# Build settings can arrive from the environment too (xcodebuild exposes
# environment variables as settings, and the project's $(inherited) picks
# them up). Clear the ones that carry compilation conditions.
unset SWIFT_ACTIVE_COMPILATION_CONDITIONS OTHER_SWIFT_FLAGS GCC_PREPROCESSOR_DEFINITIONS \
      OTHER_CFLAGS LONGWAVE_APP_ENTITLEMENTS LONGWAVE_BUNDLE_ID 2>/dev/null || true

# --- Working tree -----------------------------------------------------------
if ! git diff --quiet HEAD --ignore-submodules -- 2>/dev/null; then
    if [[ $allow_dirty == 1 || $dry_run == 1 || $unsigned == 1 ]]; then
        echo "warning: working tree has uncommitted changes" >&2
    else
        die "working tree has uncommitted changes (commit them, or pass --allow-dirty)"
    fi
fi

# --- Build number -------------------------------------------------------------
if [[ -z "$build" ]]; then
    build="$(git rev-list --count HEAD)"
fi
[[ "$build" =~ ^[0-9]+$ ]] || die "--build must be a plain integer, got '$build'"

# --- Team -----------------------------------------------------------------------
if [[ -z "$team" && -f "$SCRIPT_DIR/build-signing.conf" ]]; then
    # Read the one assignment rather than sourcing the file: it also holds
    # certificate passwords and dev-only build settings.
    team="$(sed -n 's/^[[:space:]]*TEAM_ID=["'\'']\{0,1\}\([A-Z0-9]\{10\}\)["'\'']\{0,1\}.*$/\1/p' \
        "$SCRIPT_DIR/build-signing.conf" | head -1)"
fi
if [[ -z "$team" && $unsigned == 0 && $dry_run == 0 ]]; then
    die "no team ID (pass --team, set LONGWAVE_TEAM_ID, or set TEAM_ID in scripts/build-signing.conf)"
fi

# --- Edition --------------------------------------------------------------------
EDITION=()
while IFS= read -r line; do EDITION+=("$line"); done \
    < <("$SCRIPT_DIR/edition-settings.sh" appstore)

SETTINGS=("${EDITION[@]}" "CURRENT_PROJECT_VERSION=$build")
[[ -n "$version" ]] && SETTINGS+=("MARKETING_VERSION=$version")
if [[ $unsigned == 1 ]]; then
    SETTINGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=')
else
    SETTINGS+=(CODE_SIGN_STYLE=Automatic)
fi
[[ -n "$team" ]] && SETTINGS+=("DEVELOPMENT_TEAM=$team")

# --- Resolved settings guard ----------------------------------------------------
step "Resolving build settings ($CONFIGURATION, appstore edition)"
resolved="$(xcodebuild -showBuildSettings \
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" "${SETTINGS[@]}" 2>/dev/null)" \
    || die "xcodebuild -showBuildSettings failed"

forbidden="$(printf '%s\n' "$resolved" | grep -E 'PCVR_UNLOCKED|LONGWAVE_INTERNAL' || true)"
if [[ -n "$forbidden" ]]; then
    echo "error: dev-only or internal-only conditions in the resolved build settings:" >&2
    printf '%s\n' "$forbidden" | sed 's/^/    /' >&2
    exit 1
fi

# The first "Build settings for action ... target Longwave" block is the app.
app_settings="$(printf '%s\n' "$resolved" | awk '
    /^Build settings for action .* target / { inapp = ($NF == "Longwave:") ; next }
    inapp { print }')"
setting() { printf '%s\n' "$app_settings" | sed -n "s/^ *$1 = //p" | head -1; }

conditions="$(setting SWIFT_ACTIVE_COMPILATION_CONDITIONS)"
bundle_id="$(setting PRODUCT_BUNDLE_IDENTIFIER)"
entitlements="$(setting CODE_SIGN_ENTITLEMENTS)"
resolved_version="$(setting MARKETING_VERSION)"
resolved_build="$(setting CURRENT_PROJECT_VERSION)"
deployment="$(setting XROS_DEPLOYMENT_TARGET)"

[[ " $conditions " == *" FOVEATED_ENABLED "* ]] || die "FOVEATED_ENABLED missing from '$conditions'"
[[ " $conditions " != *" MOONLIGHT_ENABLED "* ]] || die "MOONLIGHT_ENABLED must not be in an App Store build"
[[ " $conditions " != *" DEBUG "* ]] || die "DEBUG is set — not a Release configuration"
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] || die "bundle identifier is '$bundle_id', expected $EXPECTED_BUNDLE_ID"
[[ "$entitlements" == "Longwave/Longwave-Foveated.entitlements" ]] \
    || die "app entitlements are '$entitlements', expected Longwave/Longwave-Foveated.entitlements"
[[ "$resolved_build" == "$build" ]] || die "CFBundleVersion resolved to '$resolved_build', expected $build"
[[ -n "$resolved_version" ]] || die "could not resolve MARKETING_VERSION"
version="$resolved_version"

[[ -z "$out" ]] && out="$ROOT/build/appstore/$version-$build"
archive="$out/Longwave.xcarchive"
export_dir="$out/export"

cat <<EOF
    version      $version ($build)
    bundle id    $bundle_id
    conditions   $conditions
    deployment   visionOS $deployment
    entitlements $entitlements
    team         ${team:-(none)}
    signing      $([[ $unsigned == 1 ]] && echo "disabled (--unsigned)" || echo automatic)
    export       $([[ $unsigned == 1 ]] && echo skipped || { [[ $upload == 1 ]] && echo "upload to App Store Connect" || echo "$export_dir"; })
    archive      $archive
EOF

if [[ $dry_run == 1 ]]; then
    step "Dry run: settings check passed, nothing archived"
    exit 0
fi

# --- Prerequisites --------------------------------------------------------------
if [[ ! -f repos/royalvnc/Package.swift ]]; then
    step "Setting up local dependencies"
    "$SCRIPT_DIR/setup-deps.sh"
fi
"$SCRIPT_DIR/set-build-info.sh"

# --- Archive ----------------------------------------------------------------------
mkdir -p "$out"
rm -rf "$archive"
step "Archiving"
ARCHIVE_ARGS=(archive
    -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION"
    -destination "$DESTINATION" -archivePath "$archive")
[[ $unsigned == 0 ]] && ARCHIVE_ARGS+=(-allowProvisioningUpdates)
xcodebuild "${ARCHIVE_ARGS[@]}" "${SETTINGS[@]}"

app="$archive/Products/Applications/Longwave.app"
[[ -d "$app" ]] || die "archived app not found at $app"

# --- Archive checks ---------------------------------------------------------------
step "Checking the archived app"
"$SCRIPT_DIR/check-app-strings.sh" "$app"

plist="$app/Info.plist"
got_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
got_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
got_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
[[ "$got_build" == "$build" ]] || die "archived CFBundleVersion is '$got_build', expected $build"
[[ "$got_version" == "$version" ]] || die "archived version is '$got_version', expected $version"
[[ "$got_id" == "$EXPECTED_BUNDLE_ID" ]] || die "archived bundle id is '$got_id'"
/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$plist" >/dev/null 2>&1 \
    || die "Info.plist lacks ITSAppUsesNonExemptEncryption"
for bundle in "$app" "$app"/PlugIns/*.appex; do
    [[ -d "$bundle" ]] || continue
    [[ -f "$bundle/PrivacyInfo.xcprivacy" ]] || die "PrivacyInfo.xcprivacy missing from ${bundle#"$archive"/}"
    ext_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Info.plist")"
    [[ "$ext_build" == "$build" ]] || die "CFBundleVersion of ${bundle##*/} is '$ext_build', expected $build"
done

if [[ $unsigned == 1 ]]; then
    step "Unsigned archive checked: $archive (not uploadable; export skipped)"
    exit 0
fi

signed_entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
[[ "$signed_entitlements" == *"com.apple.developer.foveated-streaming-session"* ]] \
    || die "signed app lacks the foveated-streaming-session entitlement"

# --- Export -------------------------------------------------------------------------
options_dir="$(mktemp -d -t longwave-export)"
trap 'rm -rf "$options_dir"' EXIT
options="$options_dir/ExportOptions.plist"
cp "$EXPORT_TEMPLATE" "$options"
plutil -replace teamID -string "$team" "$options"
[[ $upload == 1 ]] && plutil -replace destination -string upload "$options"

rm -rf "$export_dir"
step "Exporting ($([[ $upload == 1 ]] && echo "upload" || echo "export"))"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$options" \
    -allowProvisioningUpdates

if [[ $upload == 1 ]]; then
    step "Uploaded $version ($build). It appears in App Store Connect → TestFlight once processed."
else
    ipa="$(ls "$export_dir"/*.ipa 2>/dev/null | head -1 || true)"
    [[ -n "$ipa" ]] && "$SCRIPT_DIR/check-app-strings.sh" "$ipa"
    step "Exported ${ipa:-to $export_dir}. Upload with --upload, Xcode Organizer, or Transporter."
fi
