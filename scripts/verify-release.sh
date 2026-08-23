#!/usr/bin/env bash
#
# Verify a Longwave release against the signature made by scripts/bless-release.sh: check the
# SHA256SUMS signature with the committed public key, then check every downloaded asset against
# it. This is the same check the Companion's updater performs internally
# (CompanionWindows/app/src/release-trust.js) — written out as a script so that anyone can run
# it, and so the app's claim about its own downloads is independently testable rather than
# something you have to take on trust from the app doing the downloading.
#
#   scripts/verify-release.sh                       # the most recent release
#   scripts/verify-release.sh --tag 0.1.0-abc12345
#   scripts/verify-release.sh --tag <tag> --keep    # leave the downloads behind for inspection
#
# Needs only `gh` and `ssh-keygen`. The trusted keys come from this checkout
# (CompanionWindows/app/src/release-signers) and nowhere else — not from your agent, not from
# your known_hosts, not from anything ambient — so this cannot accidentally pass because some
# other key you happen to trust signed the manifest.
#
# Two keys are pinned there: the everyday YubiKey and an offline backup. A release signed by
# EITHER verifies here, which is the point of the backup — if the first key is ever lost, this
# script and the app both keep working without an update.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNERS="$REPO_ROOT/CompanionWindows/app/src/release-signers"
MANIFEST='SHA256SUMS'
SIG_EXT='sig'
IDENTITY='releases@longwave.pro'

TAG=""
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     TAG="${2:?--tag needs a value}"; shift ;;
    --keep)    KEEP=1 ;;
    -h|--help) sed -n '3,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$REPO_ROOT"
[[ -f "$SIGNERS" ]] || { echo "error: signer list not found at $SIGNERS" >&2; exit 1; }

if [[ -z "$TAG" ]]; then
  TAG="$(gh release list --limit 1 --json tagName -q '.[0].tagName')"
  [[ -n "$TAG" ]] || { echo "error: no releases found and no --tag given" >&2; exit 1; }
fi
echo "==> verifying release $TAG"

if [[ "$KEEP" == 1 ]]; then
  STAGE="$REPO_ROOT/.release-verify-$TAG"
  mkdir -p "$STAGE"
else
  STAGE="$(mktemp -d -t longwave-verify)"
  trap 'rm -rf "$STAGE"' EXIT
fi

echo "==> downloading assets"
gh release download "$TAG" --dir "$STAGE" --clobber

[[ -f "$STAGE/$MANIFEST" && -f "$STAGE/$MANIFEST.$SIG_EXT" ]] || {
  echo "error: $TAG has no $MANIFEST + $MANIFEST.$SIG_EXT — it has not been blessed with a release key." >&2
  echo "       (Releases published before that mechanism existed will not have one.)" >&2
  exit 1
}

echo "==> checking the manifest signature"
# -f names the ONLY keys accepted; -I the principal they are issued to; -n the namespace, which
# must match what bless-release.sh signed with, so a signature made for anything else is not
# replayable here. Output says which of the pinned keys it was, which is how you can tell at a
# glance whether a release was signed by the everyday key or the offline backup.
if ! ssh-keygen -Y verify -f "$SIGNERS" -I "$IDENTITY" -n file \
       -s "$STAGE/$MANIFEST.$SIG_EXT" < "$STAGE/$MANIFEST"; then
  echo "FAIL: the $MANIFEST signature does not check out against $SIGNERS." >&2
  echo "      Do not trust any asset on this release." >&2
  exit 1
fi

echo "==> checking asset hashes"
# The manifest names bare filenames, so shasum -c has to run from the directory holding them.
# `shasum -c` fails on a listed-but-absent file, which is the behaviour we want: an asset the
# signature covers and the release no longer has is a discrepancy, not a pass.
( cd "$STAGE" && shasum -a 256 -c "$MANIFEST" ) | sed 's/^/    /'

echo
echo "==> $TAG verifies: every asset matches a manifest signed by a pinned release key."
[[ "$KEEP" == 1 ]] && echo "    downloads kept in $STAGE"
exit 0
