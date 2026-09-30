#!/bin/bash
# Longwave agent sandbox — removes everything install.sh set up.
#   sudo scripts/agent-sandbox/uninstall.sh [--keep-exchange]
#
# The exchange dir holds bare repos with work the agent produced; by default it
# is deleted along with everything else, --keep-exchange leaves it (and its
# group) in place.
#
# Must stay compatible with macOS /bin/bash 3.2.

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

readonly AGENT_USER=longwave-agent
readonly EXCHANGE_GROUP=longwave-exchange
readonly BASE=/Library/Longwave
readonly LIBEXEC=/usr/local/libexec
readonly DAEMON_PLIST=/Library/LaunchDaemons/pro.longwave.sandbox.plist
readonly SUDOERS=/etc/sudoers.d/longwave-sandbox
readonly KEYCHAIN_SERVICE=pro.longwave.sandbox

say() { printf '==> %s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
keep_exchange=0
case "${1:-}" in
    "") ;;
    --keep-exchange) keep_exchange=1 ;;
    *) die "usage: sudo $0 [--keep-exchange]" ;;
esac
OWNER=${SUDO_USER:-}

# Stop the agent and release the firewall while the helper still exists.
if [ -x "$LIBEXEC/longwave-sandbox" ] && [ -f "$BASE/sandbox.conf" ]; then
    say "stopping the agent and removing the firewall anchor"
    "$LIBEXEC/longwave-sandbox" stop >/dev/null 2>&1 || true
    "$LIBEXEC/longwave-sandbox" firewall off >/dev/null 2>&1 || true
fi

say "removing the LaunchDaemon"
launchctl bootout system/pro.longwave.sandbox >/dev/null 2>&1 || true
rm -f "$DAEMON_PLIST"

say "removing sudoers entry and root helpers"
rm -f "$SUDOERS"
visudo -c >/dev/null || say "WARNING: sudoers does not validate after removal — check /etc/sudoers.d"
rm -f "$LIBEXEC/longwave-sandbox" "$LIBEXEC/longwave-sandbox-semd"

if dscl . -read "/Users/$AGENT_USER" UniqueID >/dev/null 2>&1; then
    AGENT_UID=$(dscl . -read "/Users/$AGENT_USER" UniqueID | awk '{print $2}')
    [ "$AGENT_UID" -ge 550 ] || die "refusing: $AGENT_USER has uid $AGENT_UID"
    say "deleting account $AGENT_USER (uid $AGENT_UID) and its home"
    launchctl bootout "user/$AGENT_UID" >/dev/null 2>&1 || true
    pkill -9 -u "$AGENT_UID" >/dev/null 2>&1 || true
    for g in com.apple.access_ssh com.apple.access_screensharing "$EXCHANGE_GROUP"; do
        dseditgroup -o edit -d "$AGENT_USER" -t user "$g" >/dev/null 2>&1 || true
    done
    find /private/var/folders -mindepth 2 -maxdepth 2 -type d -user "$AGENT_UID" -exec rm -rf {} + 2>/dev/null || true
    find /private/tmp /Users/Shared -xdev -mindepth 1 -user "$AGENT_UID" -prune -exec rm -rf {} + 2>/dev/null || true
    rm -f "/private/var/db/com.apple.xpc.launchd/disabled.$AGENT_UID.plist"
    sysadminctl -deleteUser "$AGENT_USER" >/dev/null 2>&1 || dscl . -delete "/Users/$AGENT_USER"
    rm -rf "/Users/$AGENT_USER"
fi
crontab -r -u "$AGENT_USER" >/dev/null 2>&1 || true
for f in /usr/lib/cron/cron.deny /usr/lib/cron/at.deny; do
    if [ -f "$f" ]; then
        tmp=$(mktemp /tmp/lwdeny.XXXXXX)
        /usr/bin/grep -vx "$AGENT_USER" "$f" > "$tmp" || true
        cat "$tmp" > "$f"; rm -f "$tmp"
    fi
done

if [ "$keep_exchange" -eq 1 ]; then
    say "keeping $BASE/exchange (and group $EXCHANGE_GROUP)"
    find "$BASE" -mindepth 1 -maxdepth 1 ! -name exchange -exec rm -rf {} +
else
    rm -rf "$BASE"
    dscl . -delete "/Groups/$EXCHANGE_GROUP" >/dev/null 2>&1 || true
fi

if [ -n "$OWNER" ] && [ "$OWNER" != root ]; then
    sudo -u "$OWNER" -H security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$AGENT_USER" \
        >/dev/null 2>&1 && say "removed the keychain item" || true
    OWNER_HOME=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory | awk '{print $2}')
    if [ -f "$OWNER_HOME/.ssh/longwave_sandbox_ed25519" ]; then
        rm -f "$OWNER_HOME/.ssh/longwave_sandbox_ed25519" "$OWNER_HOME/.ssh/longwave_sandbox_ed25519.pub"
        say "removed ~/.ssh/longwave_sandbox_ed25519"
    fi
fi

say "done"
