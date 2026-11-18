#!/bin/bash
set -euo pipefail

# Commit the Longwave patches inside the git checkouts under repos/, so that
# build-and-sign and Apparition do not report the app as built with
# uncommitted changes just because its dependencies are patched.
#
# The commit is local to repos/ (gitignored, never pushed), sits on top of the
# pinned ref, and `git diff <pin>` still yields the whole patch, so exporting
# ci/patches/*.patch works exactly as before. What changes is the meaning of a
# dirty dep: it now means an edit that is NOT yet in a patch file.
#
# setup-deps.sh calls this for checkouts it has just patched. Run it by hand
# after you have edited a dep AND re-exported its patch:
#
#   scripts/seal-dep-patches.sh                  # the four patched checkouts
#   scripts/seal-dep-patches.sh royalvnc opus    # just these
#
# Files the setup creates (Package.swift, include/, instance1/, ...) are
# untracked by design; they go in each checkout's .git/info/exclude, which is
# local too, so no dep's own .gitignore is touched.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

exclude() { # <git dir> <pattern>...
    local dir=$1 file
    shift
    file="$(git -C "$dir" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    local pattern
    for pattern in "$@"; do
        grep -qxF -- "$pattern" "$file" || echo "$pattern" >> "$file"
    done
}

commit_tracked() { # <dir> <message>
    local dir=$1
    if [[ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]]; then
        git -C "$dir" add -u
        git -C "$dir" -c user.name=Ixion -c user.email=illixion@illixion.com \
            -c commit.gpgsign=false commit -q -m "$2"
        echo "==> sealed $dir"
    fi
}

seal() { # <name>
    local name=$1 dir="repos/$1"
    [[ -e "$dir/.git" ]] || return 0
    case "$name" in
        moonlight-common-c)
            # enet's modulemap is copied in from ci/deps; keep it out of enet's status.
            [[ -e "$dir/enet/.git" ]] && exclude "$dir/enet" 'include/module.modulemap'
            exclude "$dir" '.build/' 'Package.swift' '/include/' '/instance1/' '/instance2/'
            ;;
        opus)
            exclude "$dir" '.build/' 'Package.swift' '/spm-config/' '/include/module.modulemap'
            ;;
        *)
            exclude "$dir" '.build/' '.swiftpm/'
            ;;
    esac
    commit_tracked "$dir" "Apply Longwave patches (ci/patches)"
}

if [[ $# -gt 0 ]]; then
    for name in "$@"; do seal "$name"; done
else
    for name in swift-nio-ssh royalvnc moonlight-common-c opus; do seal "$name"; done
fi
