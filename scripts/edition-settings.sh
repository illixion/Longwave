#!/usr/bin/env bash
#
# edition-settings.sh <edition>
#
# Prints the xcodebuild setting assignments that define one edition of the
# visionOS app, one per line. Read them into an array — several values contain
# spaces, so an unquoted $(...) would split them into separate arguments and
# xcodebuild would reject the fragments:
#
#   EDITION=()
#   while IFS= read -r line; do EDITION+=("$line"); done \
#       < <(scripts/edition-settings.sh appstore)
#   xcodebuild archive -scheme Longwave "${EDITION[@]}" ...
#
# The read loop rather than `mapfile` because GitHub's macOS runners still run
# bash 3.2, which predates it.
#
# There are three because two of them are forced by licensing, not by taste:
#
#   oss            The MIT app. Ships as an unsigned IPA on GitHub.
#   oss-moonlight  The same app plus Moonlight game streaming. moonlight-common-c
#                  is GPLv3, so the whole binary becomes GPLv3 — which is also
#                  why this build can never go to the App Store, whose terms are
#                  incompatible with the GPL's. Same identifier as `oss`: it is
#                  the same app, built twice, and nobody installs both.
#   appstore       The App Store build: everything except Moonlight, plus PCVR.
#
# All three are called "Longwave" — the editions are how it is distributed, not
# different products, and the paid part is one in-app purchase inside PCVR.
# `oss` and `appstore` do carry distinct identifiers, so a sideloaded copy and an
# App Store install coexist instead of fighting for the same slot; that is the
# only reason they differ.
#
# PCVR is Pro-only for the mirror-image reason: its Windows host halves are
# closed-source, so it cannot be part of an edition that claims to be MIT.
#
# Command-line settings beat both the target and the xcconfig, so anything
# printed here wins over the project defaults (which are the `oss` values).
#
# Two conditions are deliberately never printed by any edition here:
#
#   PCVR_UNLOCKED      Dev-only: makes PCVRStore report the lifetime unlock so a
#                      receipt-less sideload is not stuck in trial. Set only in the
#                      local, gitignored build-signing.conf.
#   LONGWAVE_INTERNAL  Internal-only features for private test builds.
#
# CI builds the appstore edition from this file and fails if the binary carries
# either (see the string guard in .github/workflows/build.yml), so adding one of
# them to an edition below breaks the build on purpose.

set -euo pipefail

edition="${1:-}"

# Keep $(inherited) — swift-crypto's BoringSSL exclusion is carried in the
# inherited value, and dropping it breaks the build in a way that looks
# unrelated. See KNOWN_CONSTRAINTS.md.
case "$edition" in
    oss)
        echo 'LONGWAVE_BUNDLE_ID=pro.longwave.oss'
        echo 'LONGWAVE_DISPLAY_NAME=Longwave'
        ;;
    oss-moonlight)
        echo 'LONGWAVE_BUNDLE_ID=pro.longwave.oss'
        echo 'LONGWAVE_DISPLAY_NAME=Longwave'
        echo 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MOONLIGHT_ENABLED'
        ;;
    appstore)
        echo 'LONGWAVE_BUNDLE_ID=pro.longwave.app'
        echo 'LONGWAVE_DISPLAY_NAME=Longwave'
        echo 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) FOVEATED_ENABLED'
        # FoveatedStreaming is 26.4+. Raising the floor for every edition would
        # cost the OSS build two OS versions of reach for a feature it lacks.
        echo 'XROS_DEPLOYMENT_TARGET=26.4'
        # The app target alone signs with the foveated-streaming-session
        # capability. A variable rather than CODE_SIGN_ENTITLEMENTS itself: a
        # command-line CODE_SIGN_ENTITLEMENTS would also land on the embedded
        # broadcast extension, whose App ID does not carry the capability.
        echo 'LONGWAVE_APP_ENTITLEMENTS=Longwave/Longwave-Foveated.entitlements'
        ;;
    *)
        echo "usage: $(basename "$0") {oss|oss-moonlight|appstore}" >&2
        exit 2
        ;;
esac
