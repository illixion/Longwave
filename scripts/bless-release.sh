#!/usr/bin/env bash
#
# Sign a GitHub release with the Ixion YubiKey: hash every asset attached to it into one
# SHA256SUMS file, detach-sign that, and attach both back to the same release.
#
# WHY THIS EXISTS
#
# Nothing this project ships is Authenticode- or notarization-signed: there is no code-signing
# certificate, by decision. That is fine for an artifact a human downloads from a release page
# and checks against the build-provenance attestation. It is not fine for the Companion's
# updater, which fetches an .exe and runs it with nobody looking at the URL — so that path
# needs an authenticity check rooted in something CI cannot hold.
#
# CI builds and publishes; this signs afterwards, by hand, from a machine with the key. One
# signature covers the whole release — both Windows installers, the visionOS IPAs, the macOS
# zips, and the closed-source PCVR bundle — so there is one thing to verify and one thing to
# trust, rather than a different story per artifact. The private half lives on a YubiKey and
# has never been on a disk, let alone in a CI secret: a stolen GitHub token can publish assets
# to a release, but cannot make the app accept them.
#
# SSHSIG (`ssh-keygen -Y sign -n file`), the same scheme, namespace and signer pair as the
# ssh-keys-updater manifests in illixion.github.io — so there is one set of keys to protect and
# one recovery drill to remember. The app verifies against the two pinned signers committed at
# CompanionWindows/app/src/release-signers; anyone can run the same check with
# scripts/verify-release.sh.
#
# LOSING THE KEY
#
# The signer list pins two keys: the everyday YubiKey and an offline backup. If the YubiKey is
# lost or destroyed, releases keep shipping — sign with the backup instead:
#
#   scripts/bless-release.sh --key-file ~/path/to/backup_ed25519
#
# Every copy of the app already out there accepts it, because both keys were pinned before
# either was needed. That is the only reason this works, and it is why the backup must never be
# added "when required" — by then, nothing in the field would trust it.
#
#   scripts/bless-release.sh                            # most recent release, YubiKey
#   scripts/bless-release.sh --tag 0.1.0-abc12345       # a specific release
#   scripts/bless-release.sh --signer ixion@SecureBackup  # a specific pinned signer, via agent
#   scripts/bless-release.sh --key-file ~/backup_ed25519  # the offline key, no agent
#   scripts/bless-release.sh --dry-run                  # hash and sign locally, upload nothing
#
# RUN THIS LAST. It hashes what is attached at the moment it runs, so anything uploaded
# afterwards is not covered and the release has to be blessed again — which is exactly what
# happens with the PCVR bundle, and why package-pcvr-bundle.sh calls this itself once its own
# upload is done. Re-running is safe and idempotent: it reports what changed since last time.
#
# Requires: `gh` authenticated against this repo; and, unless --key-file is given, an agent
# holding the signing key — the YubiKey plugged in, which will ask for its PIN and a physical
# touch. Runs in the foreground for that reason: a backgrounded signer cannot raise the prompt
# at all, and fails as a timeout that looks like anything but a missing fingerprint.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The pinned signer list — the single source of trust, shared with the app. No separate .pub
# file to keep in step with it.
SIGNERS="$REPO_ROOT/CompanionWindows/app/src/release-signers"
MANIFEST='SHA256SUMS'
SIG_EXT='sig'
# The principal every line in release-signers is issued to; ssh-keygen -Y verify matches on it.
IDENTITY='releases@longwave.pro'

TAG=""
DRY_RUN=0
SIGNER=""            # pinned signer to use: comment substring or 1-based index (default: first)
KEY_FILE=""          # sign with this private key file instead of an agent (the offline backup)
USE_GPG_AGENT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)       TAG="${2:?--tag needs a value}"; shift ;;
    --signer)    SIGNER="${2:?--signer needs a value}"; shift ;;
    --key-file)  KEY_FILE="${2:?--key-file needs a value}"; shift ;;
    --gpg-agent) USE_GPG_AGENT=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '3,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$SIGNERS" ]] || { echo "error: signer list not found at $SIGNERS" >&2; exit 1; }

# Pick a pinned signer line by comment substring or 1-based index; default the first.
# Lines are `principal keytype base64 comment`.
pick_signer() {
  local want="$1" n=0
  while read -r _principal algo b64 comment; do
    [[ -z "${algo:-}" || "$_principal" == \#* ]] && continue
    n=$((n + 1))
    if [[ -z "$want" && "$n" == 1 ]] \
       || [[ "$want" == "$n" ]] \
       || { [[ -n "$want" ]] && [[ "$comment" == *"$want"* ]]; }; then
      printf '%s %s %s\n' "$algo" "$b64" "$comment"
      return 0
    fi
  done < "$SIGNERS"
  return 1
}

agent_has_key() { SSH_AUTH_SOCK="$1" ssh-add -L 2>/dev/null | grep -qF "$2"; }

cd "$REPO_ROOT"

if [[ -z "$TAG" ]]; then
  TAG="$(gh release list --limit 1 --json tagName -q '.[0].tagName')"
  [[ -n "$TAG" ]] || { echo "error: no releases found and no --tag given" >&2; exit 1; }
  echo "==> no --tag given, using the most recent release: $TAG"
fi

STAGE="$(mktemp -d -t longwave-bless)"
trap 'rm -rf "$STAGE"' EXIT
ASSETS="$STAGE/assets"
mkdir -p "$ASSETS"

# ------------------------------------------------------------------ what is on the release
echo "==> reading $TAG"
# Read with a while-loop rather than `mapfile`: this script runs outside the Bash-tool
# wrapper, where `bash` can still be macOS's /bin/bash 3.2, and mapfile is a bash 4 builtin.
# The same constraint the CI runners already impose (see CLAUDE.md).
ASSET_NAMES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ASSET_NAMES+=("$line")
done < <(gh release view "$TAG" --json assets -q '.assets[].name' | sort)
[[ ${#ASSET_NAMES[@]} -gt 0 ]] || { echo "error: $TAG has no assets to sign" >&2; exit 1; }

# The manifest and its signature are the output of this script, never its input.
COVERED=()
for name in "${ASSET_NAMES[@]}"; do
  case "$name" in
    "$MANIFEST"|"$MANIFEST.$SIG_EXT") continue ;;
    *) COVERED+=("$name") ;;
  esac
done
[[ ${#COVERED[@]} -gt 0 ]] || { echo "error: $TAG has nothing but a manifest on it" >&2; exit 1; }

# Was it blessed before, and has the asset list moved since? Worth saying out loud: the usual
# reason to re-bless is that the PCVR bundle arrived after the first blessing, and "3 new
# assets" is the difference between that and someone else having uploaded something.
PREVIOUS=""
if printf '%s\n' "${ASSET_NAMES[@]}" | grep -qx "$MANIFEST"; then
  PREVIOUS="$STAGE/previous-manifest"
  gh release download "$TAG" --pattern "$MANIFEST" --dir "$STAGE" --clobber >/dev/null 2>&1 \
    && mv "$STAGE/$MANIFEST" "$PREVIOUS" || PREVIOUS=""
  if [[ -n "$PREVIOUS" ]]; then
    echo "==> $TAG is already blessed; comparing"
    while IFS= read -r added; do echo "    + $added (new since the last blessing)"; done \
      < <(comm -23 <(printf '%s\n' "${COVERED[@]}") <(awk '{ $1=""; sub(/^ +\**/, ""); print }' "$PREVIOUS" | sort))
    while IFS= read -r gone; do echo "    - $gone (no longer on the release)"; done \
      < <(comm -13 <(printf '%s\n' "${COVERED[@]}") <(awk '{ $1=""; sub(/^ +\**/, ""); print }' "$PREVIOUS" | sort))
  fi
fi

# ------------------------------------------------------------------ download + hash
echo "==> downloading ${#COVERED[@]} asset(s)"
for name in "${COVERED[@]}"; do
  gh release download "$TAG" --pattern "$name" --dir "$ASSETS" --clobber
done

# Hashed from inside the directory so the manifest carries bare filenames — the app matches
# GitHub asset names against these exactly, and a "./" prefix or an absolute path would make
# every lookup miss. Sorted for a stable, reviewable diff between blessings.
echo "==> hashing"
( cd "$ASSETS" && shasum -a 256 -- * | sort -k2 ) > "$STAGE/$MANIFEST"
sed 's/^/    /' "$STAGE/$MANIFEST"

# A downloaded asset that is somehow missing from the manifest would silently narrow what the
# signature covers, so check the count rather than assume the glob and the list agreed.
HASHED=$(grep -c '' "$STAGE/$MANIFEST")
if [[ "$HASHED" -ne "${#COVERED[@]}" ]]; then
  echo "error: hashed $HASHED file(s) but the release has ${#COVERED[@]} — refusing to sign a partial manifest" >&2
  exit 1
fi

# ------------------------------------------------------------------ sign
# `ssh-keygen -Y sign` writes <file>.sig, and if that file already exists it leaves it ALONE
# and still exits 0 — no error, no diagnostic, the old signature simply survives. On a fresh
# mktemp directory this cannot bite, but it is one line to make sure, and a silently stale
# signature here would be uploaded as if it covered the new manifest.
SIGFILE="$STAGE/$MANIFEST.$SIG_EXT"
rm -f "$SIGFILE"

if [[ -n "$KEY_FILE" ]]; then
  # The offline-backup path: no agent, no hardware, just the key file. This is the key-loss
  # drill — see LOSING THE KEY above.
  [[ -f "$KEY_FILE" ]] || { echo "error: key file not found: $KEY_FILE" >&2; exit 1; }
  echo "==> signing with the offline key file $KEY_FILE"
  ssh-keygen -Y sign -n file -f "$KEY_FILE" "$STAGE/$MANIFEST"
else
  SIGNER_LINE="$(pick_signer "$SIGNER")" \
    || { echo "error: no pinned signer matches '${SIGNER:-<first>}' in $SIGNERS" >&2; exit 1; }
  SIGNER_ALGO="$(awk '{print $1}' <<<"$SIGNER_LINE")"
  SIGNER_BLOB="$(awk '{print $2}' <<<"$SIGNER_LINE")"
  SIGNER_NAME="$(awk '{print $3}' <<<"$SIGNER_LINE")"
  echo "==> signing as $SIGNER_NAME (check for a PIN/touch prompt)"

  # Find an agent that actually holds this key: an explicit --gpg-agent, else the current
  # SSH_AUTH_SOCK, else gpg-agent's ssh socket — which is where a YubiKey's PGP-applet key
  # appears. Checking rather than assuming, because `ssh-keygen -Y sign` against an agent that
  # does not hold the key fails with a generic error that reads like a bad key file.
  if [[ "$USE_GPG_AGENT" -eq 1 ]]; then
    SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"; export SSH_AUTH_SOCK
    gpgconf --launch gpg-agent || true
  elif ! agent_has_key "${SSH_AUTH_SOCK:-}" "$SIGNER_BLOB"; then
    gpgsock="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)"
    if [[ -n "$gpgsock" ]] && { gpgconf --launch gpg-agent 2>/dev/null; agent_has_key "$gpgsock" "$SIGNER_BLOB"; }; then
      SSH_AUTH_SOCK="$gpgsock"; export SSH_AUTH_SOCK
    fi
  fi
  agent_has_key "${SSH_AUTH_SOCK:-}" "$SIGNER_BLOB" || {
    echo "error: no reachable ssh-agent holds $SIGNER_NAME." >&2
    echo "       Plug in the YubiKey, or use --gpg-agent, or sign the offline key with --key-file." >&2
    exit 1
  }

  # -f takes a PUBLIC key here; ssh-keygen then asks the agent to sign with the matching
  # private key. Written to a temp file because the signer list's own format (a leading
  # principal) is not what -f expects.
  PUBTMP="$STAGE/signer.pub"
  printf '%s %s %s\n' "$SIGNER_ALGO" "$SIGNER_BLOB" "$SIGNER_NAME" > "$PUBTMP"
  ssh-keygen -Y sign -n file -f "$PUBTMP" "$STAGE/$MANIFEST"
fi

[[ -f "$SIGFILE" ]] || { echo "error: ssh-keygen produced no signature" >&2; exit 1; }

# Self-verify before uploading, with ssh-keygen's own verifier against the committed signer
# list. This is what catches signing with a key that is NOT pinned: the signature would be
# perfectly valid and every client would reject it, which is a worse failure than not signing
# at all because it only shows up on someone else's machine.
echo "==> self-verifying against $SIGNERS"
ssh-keygen -Y verify -f "$SIGNERS" -I "$IDENTITY" -n file -s "$SIGFILE" \
  < "$STAGE/$MANIFEST" | sed 's/^/    /'

if [[ "$DRY_RUN" == 1 ]]; then
  OUT="$REPO_ROOT/.release-manifest-out"
  mkdir -p "$OUT"
  cp "$STAGE/$MANIFEST" "$SIGFILE" "$OUT/"
  echo "==> --dry-run: nothing uploaded. Manifest and signature in $OUT/"
  exit 0
fi

echo "==> uploading $MANIFEST + $MANIFEST.$SIG_EXT to $TAG"
gh release upload "$TAG" "$STAGE/$MANIFEST" "$SIGFILE" --clobber

echo
echo "==> $TAG is blessed. ${#COVERED[@]} asset(s) covered by one signature."
echo "    Anyone can check it with:  scripts/verify-release.sh --tag $TAG"
