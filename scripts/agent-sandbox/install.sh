#!/bin/bash
# Longwave agent sandbox — one-time installer. Run from a Terminal as the Mac's
# owner:   sudo scripts/agent-sandbox/install.sh
#
# Creates the hidden, non-admin `longwave-agent` account that Longwave's
# Projects tab runs Claude / Codex / Copilot in, plus the small root-side
# surface the app drives it through. Idempotent: re-running upgrades the
# installed helper/daemon and repairs anything missing, and never rotates the
# agent's password or recreates an existing account.
#
# What it touches (uninstall.sh reverses all of it):
#   user longwave-agent (+ home), group longwave-exchange
#   /Library/Longwave/{sandbox.conf,state,exchange,agent-golden,authorized_keys}
#   /usr/local/libexec/longwave-sandbox, /usr/local/libexec/longwave-sandbox-semd
#   /Library/LaunchDaemons/pro.longwave.sandbox.plist
#   /etc/sudoers.d/longwave-sandbox, /usr/lib/cron/{cron,at}.deny
#   the owner's login keychain (item pro.longwave.sandbox / longwave-agent)
#   the owner's ~/.ssh/longwave_sandbox_ed25519{,.pub}
#
# Must stay compatible with macOS /bin/bash 3.2.

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

readonly AGENT_USER=longwave-agent
readonly AGENT_REALNAME="Longwave Agent"
readonly EXCHANGE_GROUP=longwave-exchange
readonly AGENT_PORTS=40000:40999
readonly BASE=/Library/Longwave
readonly LIBEXEC=/usr/local/libexec
readonly DAEMON_PLIST=/Library/LaunchDaemons/pro.longwave.sandbox.plist
readonly SUDOERS=/etc/sudoers.d/longwave-sandbox
readonly KEYCHAIN_SERVICE=pro.longwave.sandbox
HERE="$(cd "$(dirname "$0")" && pwd)"
readonly HERE

say() { printf '==> %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
OWNER=${SUDO_USER:-}
[ -n "$OWNER" ] && [ "$OWNER" != root ] || die "run via sudo from the owner's account (SUDO_USER unset)"
OWNER_HOME=$(dscl . -read "/Users/$OWNER" NFSHomeDirectory | awk '{print $2}')
[ -d "$OWNER_HOME" ] || die "can't find $OWNER's home"
dsmemberutil checkmembership -U "$OWNER" -G admin 2>/dev/null | /usr/bin/grep -q 'is a member' \
    || die "$OWNER must be an admin"

# Screen Sharing is how the app gives the agent a GUI session (a loopback ARD
# login creates a virtual session); visionOS simulators need one.
if ! launchctl print system/com.apple.screensharing >/dev/null 2>&1; then
    say "WARNING: Screen Sharing looks off. Turn it on in System Settings > General > Sharing,"
    say "         or the agent can't get a desktop session (visionOS simulators need one)."
fi

# --- 1. The account -------------------------------------------------------------

free_id() {
    # First id >= 552 unused as both a user and a group id (551 is taken by the
    # spike account on the dev Mac; any free id works).
    local id=552
    while dscl . -search /Users UniqueID "$id" 2>/dev/null | /usr/bin/grep -q . \
       || dscl . -search /Groups PrimaryGroupID "$id" 2>/dev/null | /usr/bin/grep -q .; do
        id=$((id + 1))
    done
    echo "$id"
}

created_user=0
if dscl . -read "/Users/$AGENT_USER" UniqueID >/dev/null 2>&1; then
    AGENT_UID=$(dscl . -read "/Users/$AGENT_USER" UniqueID | awk '{print $2}')
    say "account $AGENT_USER exists (uid $AGENT_UID)"
else
    AGENT_UID=$(free_id)
    say "creating hidden account $AGENT_USER (uid $AGENT_UID)"
    dscl . -create "/Users/$AGENT_USER"
    dscl . -create "/Users/$AGENT_USER" UniqueID "$AGENT_UID"
    dscl . -create "/Users/$AGENT_USER" PrimaryGroupID 20
    dscl . -create "/Users/$AGENT_USER" RealName "$AGENT_REALNAME"
    dscl . -create "/Users/$AGENT_USER" UserShell /bin/zsh
    dscl . -create "/Users/$AGENT_USER" NFSHomeDirectory "/Users/$AGENT_USER"
    created_user=1
fi
[ "$AGENT_UID" -ge 550 ] || die "unexpected uid $AGENT_UID for $AGENT_USER"
# Hidden from the login window and Fast User Switching; it is still a normal
# local account that can log in over SSH and Screen Sharing.
dscl . -create "/Users/$AGENT_USER" IsHidden 1

# The password only exists so the app can log the agent into a Screen Sharing
# virtual session. It is generated here, set without touching argv (dscl reads
# its command from stdin), stored in the owner's login keychain, and never
# printed. It is not rotated on re-runs — the keychain copy must stay in step.
if [ "$created_user" -eq 1 ] || ! sudo -u "$OWNER" -H security find-generic-password \
        -s "$KEYCHAIN_SERVICE" -a "$AGENT_USER" >/dev/null 2>&1; then
    say "setting the agent password and saving it to $OWNER's login keychain"
    AGENT_PW=$(openssl rand -hex 24)
    if ! printf 'passwd /Users/%s %s\n' "$AGENT_USER" "$AGENT_PW" | dscl . >/dev/null 2>&1; then
        unset AGENT_PW; die "setting the agent password failed"
    fi
    # security -i also takes commands on stdin, so the value never shows in ps.
    # -U updates an existing item; the hex password needs no quoting.
    # -T pre-authorizes LongwaveMac (its session keeper reads this for the
    # loopback VNC login) so the first desktop login doesn't raise a keychain
    # prompt; the ACL follows the app's code signature, not the path.
    trusted=""
    [ -d /Applications/LongwaveMac.app ] && trusted='-T /Applications/LongwaveMac.app'
    printf 'add-generic-password -U -s %s -a %s -l "Longwave agent sandbox" -D "application password" %s -w %s\n' \
        "$KEYCHAIN_SERVICE" "$AGENT_USER" "$trusted" "$AGENT_PW" \
        | sudo -u "$OWNER" -H security -i >/dev/null 2>&1 || true
    unset AGENT_PW
    sudo -u "$OWNER" -H security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$AGENT_USER" \
        >/dev/null 2>&1 || die "saving the password to the keychain failed (is $OWNER's login keychain unlocked?)"
    say "keychain item OK"
fi

if [ ! -d "/Users/$AGENT_USER" ]; then
    createhomedir -c -u "$AGENT_USER" >/dev/null 2>&1 || true
    [ -d "/Users/$AGENT_USER" ] || die "createhomedir failed"
fi
chmod 750 "/Users/$AGENT_USER"

# SSH (the agent sessions) and Screen Sharing (its desktop) are both limited
# to admins by default on this Mac; the agent needs each explicitly.
for g in com.apple.access_ssh com.apple.access_screensharing; do
    if dscl . -read "/Groups/$g" >/dev/null 2>&1; then
        dseditgroup -o edit -a "$AGENT_USER" -t user "$g"
    fi
done
# New local users are also members of every com.apple.sharepoint.group.* (the
# SMB share ACLs) — but only through the nested "everyone" group, so there is
# nothing per-user to remove; the firewall below keeps the agent off SMB.

# No cron or at jobs: the agent must not be able to schedule itself. Scheduling
# is the app's job.
for f in /usr/lib/cron/cron.deny /usr/lib/cron/at.deny; do
    touch "$f"
    /usr/bin/grep -qx "$AGENT_USER" "$f" || printf '%s\n' "$AGENT_USER" >> "$f"
done

# --- 2. Shared layout -----------------------------------------------------------

install -d -o root -g wheel -m 755 "$BASE"
install -d -o root -g wheel -m 700 "$BASE/state"
install -d -o root -g wheel -m 700 "$BASE/agent-golden"

if ! dscl . -read "/Groups/$EXCHANGE_GROUP" >/dev/null 2>&1; then
    gid=$(free_id)
    say "creating group $EXCHANGE_GROUP (gid $gid)"
    dscl . -create "/Groups/$EXCHANGE_GROUP"
    dscl . -create "/Groups/$EXCHANGE_GROUP" PrimaryGroupID "$gid"
    dscl . -create "/Groups/$EXCHANGE_GROUP" RealName "Longwave agent exchange"
fi
dseditgroup -o edit -a "$OWNER" -t user "$EXCHANGE_GROUP"
dseditgroup -o edit -a "$AGENT_USER" -t user "$EXCHANGE_GROUP"
# Bare repos the owner pushes work into and fetches results back from. setgid
# keeps new objects in the group; git's core.sharedRepository does the modes.
install -d -o root -g "$EXCHANGE_GROUP" -m 2770 "$BASE/exchange"

cat > "$BASE/sandbox.conf" <<EOF
# Written by scripts/agent-sandbox/install.sh — parsed (not sourced) by longwave-sandbox.
AGENT_USER=$AGENT_USER
AGENT_UID=$AGENT_UID
OWNER_USER=$OWNER
AGENT_PORTS=$AGENT_PORTS
EOF
chown root:wheel "$BASE/sandbox.conf"; chmod 644 "$BASE/sandbox.conf"

# --- 3. Root helper, semaphore daemon, sudoers ----------------------------------

say "installing $LIBEXEC/longwave-sandbox and longwave-sandbox-semd"
install -d -o root -g wheel -m 755 "$LIBEXEC"
install -o root -g wheel -m 755 "$HERE/longwave-sandbox" "$LIBEXEC/longwave-sandbox"
tmpbin=$(mktemp -d /tmp/lwsemd.XXXXXX)
if ! xcrun clang -Os -Wall -o "$tmpbin/semd" "$HERE/semd.c"; then
    rm -rf "$tmpbin"; die "compiling semd.c failed (Xcode command-line tools needed)"
fi
install -o root -g wheel -m 755 "$tmpbin/semd" "$LIBEXEC/longwave-sandbox-semd"
rm -rf "$tmpbin"

say "installing $SUDOERS (only $OWNER, only longwave-sandbox)"
tmpsudo=$(mktemp /tmp/lwsudoers.XXXXXX)
cat > "$tmpsudo" <<EOF
# Longwave agent sandbox: lets $OWNER (and nobody else) run the fixed-verb root
# helper without a password. The helper validates every argument itself.
$OWNER ALL=(root) NOPASSWD: $LIBEXEC/longwave-sandbox, $LIBEXEC/longwave-sandbox *
EOF
if ! visudo -cf "$tmpsudo" >/dev/null; then rm -f "$tmpsudo"; die "generated sudoers failed visudo -c"; fi
install -o root -g wheel -m 440 "$tmpsudo" "$SUDOERS"
rm -f "$tmpsudo"
# Check our file alone: a whole-tree `visudo -c` also fails on other packages'
# sudoers.d files that are 0644 instead of 0440 (colima, lima, … ship that way),
# which sudo itself still reads and which aren't ours to change.
visudo -cf "$SUDOERS" >/dev/null || die "installed sudoers file does not validate — inspect $SUDOERS"


# --- 4. SSH key for the owner ---------------------------------------------------

KEY="$OWNER_HOME/.ssh/longwave_sandbox_ed25519"
if [ ! -f "$KEY" ]; then
    say "generating $KEY"
    sudo -u "$OWNER" install -d -m 700 "$OWNER_HOME/.ssh"
    sudo -u "$OWNER" ssh-keygen -q -t ed25519 -N '' -C "longwave-sandbox@$(scutil --get LocalHostName 2>/dev/null || hostname -s)" -f "$KEY"
fi
chmod 600 "$KEY"
"$LIBEXEC/longwave-sandbox" authorize-key "$(cat "$KEY.pub")" >/dev/null
say "SSH key authorized"

# --- 5. Firewall (opt-in) ------------------------------------------------------

# Not enabled by default: loading any custom pf rule makes iCloud Private Relay
# switch itself off ("System Incompatible"). The sandbox holds no credentials,
# so the default is no network filtering; `longwave-sandbox firewall on` opts in.
if [ "${1:-}" = "--firewall" ]; then
    if /usr/bin/grep -q '^anchor "com.apple/\*"' /etc/pf.conf; then
        "$LIBEXEC/longwave-sandbox" firewall on
    else
        say "WARNING: /etc/pf.conf has no 'anchor \"com.apple/*\"' line; firewall NOT enabled."
    fi
else
    say "network firewall left off (Private Relay-safe); opt in with: sudo $LIBEXEC/longwave-sandbox firewall on"
fi

# The daemon's RunAtLoad restores the firewall too, so it is started only after
# the step above: bootstrapping it earlier raced `firewall on` (both rendered and
# reloaded the anchor at once, and the loser's check saw an empty anchor).
say "installing and (re)starting $DAEMON_PLIST"
install -o root -g wheel -m 644 "$HERE/pro.longwave.sandbox.plist" "$DAEMON_PLIST"
plutil -lint "$DAEMON_PLIST" >/dev/null || die "bad plist"
launchctl bootout system/pro.longwave.sandbox >/dev/null 2>&1 || true
launchctl bootstrap system "$DAEMON_PLIST"

# --- 6. Golden home -------------------------------------------------------------

say "provisioning the agent's home (CLIs, git identity, simulator devices)"
install -o root -g wheel -m 755 "$HERE/provision-golden.sh" "$BASE/provision-golden.sh"
# cd / first: the invoking cwd is usually inside the owner's 700 home, which
# the agent cannot stat (bash then warns "getcwd: cannot access parent directories").
if (cd / && sudo -u "$AGENT_USER" -H /bin/bash "$BASE/provision-golden.sh"); then
    say "provisioning OK"
    # A first golden copy right away, so a reset before first-run setup restores
    # the provisioned home instead of an empty one. "Setup complete" in the app
    # replaces it with a post-setup snapshot.
    if ! [ -d "$BASE/agent-golden/Library" ]; then
        "$LIBEXEC/longwave-sandbox" snapshot-golden >/dev/null && say "initial golden snapshot taken"
    fi
else
    say "WARNING: provisioning reported errors (see above); re-run: sudo -u $AGENT_USER -H /bin/bash $BASE/provision-golden.sh"
fi

cat <<EOF

Installed. Next steps:
  1. In LongwaveMac, open Projects > Sandbox desktop and complete macOS first-run
     setup for "$AGENT_REALNAME" yourself, then press "Setup complete" (this runs
     'longwave-sandbox configure-desktop' — no screen lock, no screen saver, black
     wallpaper — then 'snapshot-golden', so every reset restores a set-up home).
  2. Check status any time:  sudo -n $LIBEXEC/longwave-sandbox status
EOF
