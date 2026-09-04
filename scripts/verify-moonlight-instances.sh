#!/bin/bash
set -euo pipefail

# Checks that the extra, symbol-prefixed copies of moonlight-common-c really
# are fully prefixed, and that the rename list still covers every symbol the
# unprefixed original defines.
#
# Why this exists: a symbol missing from ml_redefine_symbols.h does NOT fail
# the link. Static archives resolve a name to whichever member defines it
# first, so copy 1 would quietly call into copy 0's function or write copy 0's
# global — a corrupted session rather than a build error. The only reliable
# check is to look at the objects that were actually built.
#
# Usage:
#   scripts/verify-moonlight-instances.sh [DerivedData or OBJROOT dir…]
#       Verifies every MoonlightCommonC*.build / enet.build object tree found
#       under the given directories (default: ~/Library/Developer/Xcode/DerivedData).
#   scripts/verify-moonlight-instances.sh --regenerate [dirs…]
#       Rewrites the GENERATED block of ci/deps/moonlight-common-c/ml_redefine_symbols.h
#       from the unprefixed objects found (union across every arch present),
#       then re-runs make-instances.sh so the checkout picks the new list up.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEADER="$PROJECT_ROOT/ci/deps/moonlight-common-c/ml_redefine_symbols.h"

regenerate=0
if [[ "${1:-}" == "--regenerate" ]]; then
    regenerate=1
    shift
fi
roots=("$@")
[[ ${#roots[@]} -gt 0 ]] || roots=("$HOME/Library/Developer/Xcode/DerivedData")

# Defined external symbols (no leading underscore), one per line, sorted.
defined_symbols() { # <object files…>
    nm -gjU "$@" 2>/dev/null | grep -v -E ':$|^$' | sed 's/^_//' | sort -u
}

find_objects() { # <build dir name>
    for root in "${roots[@]}"; do
        find "$root" -type f -path "*/$1/Objects-normal/*/*.o" 2>/dev/null
    done
}

# Objects of the unprefixed original: the MoonlightCommonC target plus enet.
original_objs=()
while IFS= read -r f; do original_objs+=("$f"); done < <(
    { find_objects "MoonlightCommonC.build"; find_objects "enet.build"; } | sort -u
)
if [[ ${#original_objs[@]} -eq 0 ]]; then
    echo "verify-moonlight-instances: no MoonlightCommonC/enet objects under: ${roots[*]}" >&2
    echo "Build a Moonlight-enabled target first (any platform)." >&2
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
defined_symbols "${original_objs[@]}" > "$tmp/actual.txt"

if [[ $regenerate == 1 ]]; then
    {
        sed -n '1,/^\/\/ BEGIN GENERATED SYMBOLS$/p' "$HEADER"
        sed 's/^\(.*\)$/ML_RENAME(\1)/' "$tmp/actual.txt"
        sed -n '/^\/\/ END GENERATED SYMBOLS$/,$p' "$HEADER"
    } > "$tmp/header.h"
    mv "$tmp/header.h" "$HEADER"
    echo "Regenerated $HEADER with $(wc -l < "$tmp/actual.txt" | tr -d ' ') symbols."
    if [[ -d "$PROJECT_ROOT/repos/moonlight-common-c/src" ]]; then
        "$PROJECT_ROOT/ci/deps/moonlight-common-c/make-instances.sh" "$PROJECT_ROOT/repos/moonlight-common-c"
    fi
    exit 0
fi

status=0

# 1. Every symbol the original defines must be in the rename list.
sed -n 's/^ML_RENAME(\(.*\))$/\1/p' "$HEADER" | sort -u > "$tmp/listed.txt"
if missing="$(comm -23 "$tmp/actual.txt" "$tmp/listed.txt")" && [[ -n "$missing" ]]; then
    echo "ERROR: symbols defined by moonlight-common-c but missing from ml_redefine_symbols.h:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    echo "Run: scripts/verify-moonlight-instances.sh --regenerate" >&2
    status=1
fi

# 2. Every symbol an instance defines must carry that instance's prefix.
checked=0
for n in 1 2 3 4 5 6 7 8; do
    objs=()
    while IFS= read -r f; do objs+=("$f"); done < <(find_objects "MoonlightCommonC$n.build" | sort -u)
    [[ ${#objs[@]} -gt 0 ]] || continue
    checked=$((checked + 1))
    if leaked="$(defined_symbols "${objs[@]}" | grep -v "^ml${n}_")" && [[ -n "$leaked" ]]; then
        echo "ERROR: MoonlightCommonC$n defines symbols without the ml${n}_ prefix (they would collide with the original):" >&2
        echo "$leaked" | sed 's/^/  /' >&2
        status=1
    fi
done
if [[ $checked -eq 0 ]]; then
    echo "verify-moonlight-instances: no MoonlightCommonC<n> instance objects found — did the build include them?" >&2
    status=1
fi

if [[ $status -eq 0 ]]; then
    echo "OK: $(wc -l < "$tmp/actual.txt" | tr -d ' ') symbols listed, $checked prefixed instance(s) clean."
fi
exit $status
