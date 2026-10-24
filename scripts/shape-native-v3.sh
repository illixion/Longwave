#!/bin/bash
# Throttles the Native v3 video (UDP from the Companion's stream port) through
# a dummynet pipe, stepping through a schedule of link conditions, then
# removes the shaping. Only v3 is touched: v2 is TCP on the same port, and
# nothing else on this Mac goes through the pipe. The same mechanism Network
# Link Conditioner uses, without installing it.
#
#   sudo scripts/shape-native-v3.sh            # the default step test, ~4.5 min
#   sudo scripts/shape-native-v3.sh 8 0.02 10  # hold 8 Mbit/s, 2% loss, 10 ms, until Ctrl-C
#
# Each step prints its wall-clock start so it lines up with the Companion's
# "v3 link:" lines and the headset's "Frame latency v3 desktop" lines.
# Runs under /bin/bash 3.2 (sudo's default), so no bash 4 features.

set -u

PORT="${PORT:-4857}"
PIPE=4857
ANCHOR="com.apple/longwave.shape-v3"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: dnctl and pfctl need root." >&2
    exit 1
fi

TOKEN=""
cleanup() {
    pfctl -q -a "$ANCHOR" -F all 2>/dev/null
    dnctl pipe delete "$PIPE" 2>/dev/null
    [ -n "$TOKEN" ] && pfctl -q -X "$TOKEN" 2>/dev/null
    echo "$(date +%H:%M:%S)  shaping removed"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# pf stays enabled only while our reference is held; other users (NLC, VPNs)
# keep theirs.
TOKEN=$(pfctl -E 2>&1 | sed -n 's/^Token : //p')
dnctl pipe "$PIPE" config bw 0 >/dev/null
echo "dummynet out quick proto udp from any port $PORT to any pipe $PIPE" \
    | pfctl -q -a "$ANCHOR" -f - || { echo "pfctl refused the rule" >&2; exit 1; }

# set <Mbit/s or 0 for unlimited> <loss 0..1> <one-way delay ms>
set_link() {
    local bw="$1" loss="$2" delay="$3"
    local bwarg="bw 0"
    [ "$bw" != "0" ] && bwarg="bw ${bw}Mbit/s"
    # 100 slots: ~140 KB, roughly a Wi-Fi AP's per-station queue.
    dnctl pipe "$PIPE" config $bwarg plr "$loss" delay "$delay" queue 100 >/dev/null
}

stats() {
    dnctl pipe show "$PIPE" 2>/dev/null | awk 'NR>1 && /[0-9]/ { print "           pipe: " $0 }' | tail -n 1
}

step() {
    local seconds="$1" bw="$2" loss="$3" delay="$4" label="$5"
    set_link "$bw" "$loss" "$delay"
    echo "$(date +%H:%M:%S)  ${label} for ${seconds}s"
    sleep "$seconds"
    stats
}

if [ $# -ge 1 ]; then
    set_link "$1" "${2:-0}" "${3:-0}"
    echo "$(date +%H:%M:%S)  holding ${1} Mbit/s, loss ${2:-0}, delay ${3:-0} ms (Ctrl-C to stop)"
    while :; do sleep 10; stats; done
fi

step 30 0  0    0  "baseline, unshaped"
step 45 20 0    0  "20 Mbit/s"
step 45 8  0    0  "8 Mbit/s"
step 30 8  0.02 0  "8 Mbit/s, 2% loss"
step 30 3  0    20 "3 Mbit/s, +20 ms"
step 90 0  0    0  "recovery, unshaped"
