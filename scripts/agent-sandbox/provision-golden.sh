#!/bin/bash
# Longwave agent sandbox — provisions the agent account's home. Run AS the agent:
#   sudo -u longwave-agent -H /bin/bash /Library/Longwave/provision-golden.sh
# install.sh does this once; re-running is safe (every step checks first).
#
# The result becomes the golden home only after the owner finishes macOS
# first-run setup in the Sandbox desktop window and the app runs
# `longwave-sandbox snapshot-golden`. No credentials are ever written here:
# every agent session gets short-lived tokens from the app at launch.
#
# Must stay compatible with macOS /bin/bash 3.2.

set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$HOME"

[ "$(id -un)" = "longwave-agent" ] || { echo "run as longwave-agent" >&2; exit 1; }

say() { printf -- '--> %s\n' "$*"; }
failures=0
fail() { printf -- '--> FAILED: %s\n' "$*" >&2; failures=$((failures + 1)); }

# --- Shell environment ----------------------------------------------------------
# Homebrew lives in the owner's /opt/homebrew: readable and executable for the
# agent (tmux, node, git…), not writable, which is what we want.
MARK="# longwave-sandbox PATH"
touch "$HOME/.zprofile"
if ! /usr/bin/grep -qF "$MARK" "$HOME/.zprofile"; then
    # shellcheck disable=SC2016  # $HOME/$PATH expand at login, not now
    printf '%s\nexport PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"\n' "$MARK" >> "$HOME/.zprofile"
    say "PATH added to ~/.zprofile"
fi
mkdir -p "$HOME/.local/bin"

# --- Agent CLIs (official installers, all into the agent's own home) -------------
if [ ! -x "$HOME/.local/bin/claude" ]; then
    say "installing Claude Code"
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null || fail "Claude Code install"
fi
if [ ! -x "$HOME/.local/bin/codex" ]; then
    say "installing Codex"
    curl -fsSL https://chatgpt.com/codex/install.sh | sh >/dev/null || fail "Codex install"
fi
if [ ! -x "$HOME/.local/bin/copilot" ]; then
    say "installing GitHub Copilot CLI"
    # Non-root installs go to $HOME/.local by default; PREFIX makes it explicit.
    curl -fsSL https://gh.io/copilot-install | PREFIX="$HOME/.local" bash >/dev/null || fail "Copilot CLI install"
fi

# --- Git identity -----------------------------------------------------------------
git config --global user.name >/dev/null 2>&1 || git config --global user.name "Longwave Agent"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "agent@longwave.invalid"
git config --global init.defaultBranch main

# --- Agent settings ---------------------------------------------------------------
# Claude: the app is the only scheduler. Deny the tools an agent could use to
# wake itself up later or trigger remote runs.
mkdir -p "$HOME/.claude"
/usr/bin/python3 - "$HOME/.claude/settings.json" <<'PY' || fail "Claude settings"
import json, os, sys
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
perms = data.setdefault("permissions", {})
deny = perms.setdefault("deny", [])
for tool in ("CronCreate", "CronDelete", "ScheduleWakeup", "RemoteTrigger"):
    if tool not in deny:
        deny.append(tool)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

# Codex: its built-in Seatbelt sandbox breaks xcodebuild and the simulator (they
# talk to per-user XPC services outside it); the whole account is the sandbox
# here, so Codex runs unsandboxed inside it. Codex has no self-scheduling tool
# to deny as of 0.159.
mkdir -p "$HOME/.codex"
if [ ! -f "$HOME/.codex/config.toml" ] || ! /usr/bin/grep -q '^sandbox_mode' "$HOME/.codex/config.toml"; then
    printf '# The macOS account is the sandbox (see Longwave scripts/agent-sandbox/README.md).\nsandbox_mode = "danger-full-access"\n' >> "$HOME/.codex/config.toml"
fi

# --- Simulator devices ------------------------------------------------------------
# One iPhone and one Apple Vision Pro on the newest installed runtimes. The
# device type is taken from the runtime's own supported list — a device type
# the runtime doesn't support fails with "Incompatible device".
make_device() {
    local name=$1 platform=$2 hint=$3
    if xcrun simctl list devices 2>/dev/null | /usr/bin/grep -qF "$name ("; then return 0; fi
    local pair
    pair=$(xcrun simctl list runtimes -j 2>/dev/null | /usr/bin/python3 -c '
import json, sys
platform, hint = sys.argv[1], sys.argv[2]
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and platform in r["identifier"]]
if not rts: sys.exit(1)
rt = rts[-1]
types = [t["identifier"] for t in rt.get("supportedDeviceTypes", []) if hint in t["name"]]
if not types: sys.exit(1)
print(rt["identifier"], types[-1])
' "$platform" "$hint") || { fail "no $platform runtime/device type for $name"; return 0; }
    # shellcheck disable=SC2086
    set -- $pair
    if xcrun simctl create "$name" "$2" "$1" >/dev/null; then say "created simulator $name"; else fail "simctl create $name"; fi
}
make_device "Sandbox iPhone" iOS "iPhone"
make_device "Sandbox Vision Pro" xrOS "Vision"

if [ "$failures" -gt 0 ]; then
    say "$failures step(s) failed"
    exit 1
fi
say "done"
