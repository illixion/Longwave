#!/bin/bash
set -euo pipefail

# Set up the local SPM dependencies in repos/ (gitignored), recreating the
# CI dependency steps so a full Moonlight-enabled build works locally.
# CI itself builds with Moonlight DISABLED (enet doesn't compile on the
# runner image) — this script is the local path to a complete build.
#
# Idempotent: existing checkouts are left untouched. Use --force to wipe
# repos/ and re-clone everything.
#
# Usage:
#   ./scripts/setup-deps.sh            # clone + patch anything missing
#   ./scripts/setup-deps.sh --force    # wipe repos/ and redo from scratch

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pinned dependency versions (keep in sync with the historical CI pins)
ROYALVNC_REF='337197a'
MOONLIGHT_COMMON_C_REF='7b026e77be62175104640e7e722b758df6d3d0d7'
OPUS_REF='788cc89ce4f2c42025d8c70ec1b4457dc89cd50f'

cd "$PROJECT_ROOT"

if [[ "${1:-}" == "--force" ]]; then
    echo "==> Removing repos/ for a clean re-setup"
    rm -rf repos
fi
mkdir -p repos

if [[ -d repos/royalvnc ]]; then
    echo "==> repos/royalvnc exists — skipping (use --force to redo)"
else
    echo "==> Cloning and patching RoyalVNC ($ROYALVNC_REF)"
    git clone https://github.com/royalapplications/royalvnc.git repos/royalvnc
    (
        cd repos/royalvnc
        git checkout "$ROYALVNC_REF"
        # Static linking (dyld embedding fix) + Longwave API additions:
        # per-connection JPEG quality/compression settings and
        # pause/resumeFramebufferUpdates
        git apply ../../ci/patches/royalvnc-longwave.patch
    )
fi

if [[ -d repos/moonlight-common-c ]]; then
    echo "==> repos/moonlight-common-c exists — skipping (use --force to redo)"
else
    echo "==> Cloning and patching moonlight-common-c ($MOONLIGHT_COMMON_C_REF)"
    # Clone WITHOUT --recursive, then check out the pin, then init submodules.
    # Order matters: a recursive clone populates submodules as they stand on the
    # default branch, where `nanors` is a submodule — but at the pinned ref it is
    # a plain tracked directory. The checkout then aborts with "untracked working
    # tree files would be overwritten" on nanors/rs.c and friends. Initializing
    # after the checkout also gets the submodule commits the pin actually
    # records, rather than whatever the default branch points at.
    git clone https://github.com/moonlight-stream/moonlight-common-c.git repos/moonlight-common-c
    (
        cd repos/moonlight-common-c
        git checkout "$MOONLIGHT_COMMON_C_REF"
        git submodule update --init --recursive
        # Add SPM Package.swift wrapper and public headers directory
        cp ../../ci/deps/moonlight-common-c/Package.swift .
        mkdir -p include
        cp src/Limelight.h include/
        # Explicit modulemap for enet: declares enet/time.h as a module header so
        # its ENET_TIME_* macros stay visible under Xcode's explicit-modules C
        # builds (SPM's auto-generated umbrella module loses them otherwise)
        cp ../../ci/deps/moonlight-common-c/enet-module.modulemap enet/include/module.modulemap
        # Apply FEC recovery crash fixes for newer Sunshine versions
        git apply ../../ci/patches/moonlight-common-c-fec-fix.patch
        git apply ../../ci/patches/moonlight-common-c-audio-fec-fix.patch
        # Add CommonCrypto backend for AES-GCM/CBC (replaces OpenSSL on Apple platforms)
        git apply ../../ci/patches/moonlight-common-c-commoncrypto.patch
    )
fi

if [[ -d repos/opus ]]; then
    echo "==> repos/opus exists — skipping (use --force to redo)"
    # Migration: drop the hand-written modulemap from older checkouts. Xcode
    # already generates an umbrella-header modulemap for the Opus target
    # (opus.h matches the module name case-insensitively), and Xcode 26.6's
    # clang dependency scanner errors on the resulting double coverage
    # ("umbrella for module 'Opus' already covers this directory").
    rm -f repos/opus/include/module.modulemap
else
    echo "==> Cloning and patching Opus ($OPUS_REF)"
    git clone https://github.com/xiph/opus.git repos/opus
    (
        cd repos/opus
        git checkout "$OPUS_REF"
        # Add SPM Package.swift wrapper and config files. No custom
        # module.modulemap: Xcode generates an umbrella-header one from
        # opus.h, and shipping our own alongside it breaks Xcode 26.6+
        # dependency scanning (duplicate umbrella coverage of include/).
        cp ../../ci/deps/opus/Package.swift .
        mkdir -p spm-config
        cp ../../ci/deps/opus/spm-config/config.h spm-config/
        # Patch opus.h to include multistream API for SPM umbrella header
        git apply ../../ci/patches/opus-spm-umbrella.patch
        # Guard the ARM NEON intrinsic sources so they no-op when compiled
        # for x86_64 (needed for the universal arm64+x86_64 macOS targets)
        git apply ../../ci/patches/opus-x86_64-universal.patch
    )
fi

echo ""
echo "Done. Build with Moonlight via:"
echo "  ./scripts/build-and-sign.sh   (PRE_BUILD_HOOK runs this script automatically)"
