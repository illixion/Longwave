#!/usr/bin/env bash
#
# check-app-strings.sh <path> [<path> ...]
#
# Fails if a built visionOS app (a .app bundle, an .ipa, or any directory holding
# one) contains strings that only non-release builds may carry:
#
#   VRChat          internal-only PCVR copy (LONGWAVE_INTERNAL)
#   sidecar         likewise
#   PCVR_UNLOCKED   the dev-only lifetime unlock (a marker log line in PCVRStore)
#
# scripts/edition-settings.sh never emits LONGWAVE_INTERNAL or PCVR_UNLOCKED, so
# a hit means one leaked in some other way (a hand-edited build setting, an
# xcconfig, a scheme). Case-insensitive, over every regular file in the bundle,
# at the byte level — Swift string literals are stored as UTF-8, so no Mach-O
# parsing is needed. Portable to BSD grep (macOS runners) on purpose.
#
# Run by .github/workflows/build.yml after the appstore compile-check, and by
# scripts/verify-release.sh over any .ipa on a release.

set -euo pipefail

PATTERN='vrchat|sidecar|pcvr_unlocked'

[[ $# -gt 0 ]] || { echo "usage: $0 <app|ipa|dir> ..." >&2; exit 2; }

scan_dir() {
  local dir="$1" hits
  # -a: treat binaries as text; -o: only the match (a Mach-O "line" can be huge);
  # -r over the bundle; -l would lose which string matched, so list file:match.
  hits="$(LC_ALL=C grep -r -a -o -i -E "$PATTERN" "$dir" 2>/dev/null | sort | uniq -c || true)"
  if [[ -n "$hits" ]]; then
    echo "error: release-forbidden strings found under $dir:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    return 1
  fi
  return 0
}

status=0
for target in "$@"; do
  if [[ -d "$target" ]]; then
    scan_dir "$target" || status=1
  elif [[ -f "$target" && "$target" == *.ipa ]]; then
    tmp="$(mktemp -d -t longwave-strings)"
    unzip -q "$target" -d "$tmp"
    scan_dir "$tmp" || status=1
    rm -rf "$tmp"
  else
    echo "error: $target is neither a directory nor an .ipa" >&2
    status=1
  fi
done
[[ $status == 0 ]] && echo "    clean: no release-forbidden strings in $*"
exit $status
