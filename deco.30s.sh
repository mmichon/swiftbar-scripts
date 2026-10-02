#!/bin/bash

# <xbar.title>Deco Node</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.author>Claude</xbar.author>
# <xbar.desc>Shows which TP-Link Deco mesh node this Mac is on, plus band, signal, and gateway jitter.</xbar.desc>
# <xbar.dependencies>uv,tplinkrouterc6u,pyobjc-framework-CoreWLAN</xbar.dependencies>

# All the work is in .deco.py (dotfile, so SwiftBar does not run it as a
# plugin). uv resolves its inline dependencies into a cached env on first run.
UV=/opt/homebrew/bin/uv
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HELPER="$(dirname "$SELF")/.deco.py"
export DECO_PLUGIN="$SELF"

CACHE_DIR="${TMPDIR:-/tmp}/xbar-deco.$(id -u)"
LOCK="$CACHE_DIR/run.lock"
LAST_FILE="$CACHE_DIR/last_output.txt"
LOCK_STALE=40

mkdir -p "$CACHE_DIR" 2>/dev/null

if [ "$1" = "rejoin" ]; then
    # Dropping and re-raising the radio makes macOS pick the strongest BSS from
    # scratch, which is the only way to shake a client stuck on a far node.
    /usr/sbin/networksetup -setairportpower en0 off
    sleep 2
    /usr/sbin/networksetup -setairportpower en0 on
    sleep 8
    exec "$UV" run --quiet --script "$HELPER" --refresh > /dev/null 2>&1
elif [ "$1" = "refresh" ]; then
    exec "$UV" run --quiet --script "$HELPER" --refresh > /dev/null 2>&1
fi

# --- Single-instance guard ---------------------------------------------------
# Same guard as bgs.5s.sh. A Deco login can stall on a slow node, and SwiftBar
# fires every 30s regardless; a backlog of runs finishing at once is what
# crashed SwiftBar on 2026-09-20.
if ! mkdir "$LOCK" 2>/dev/null; then
    owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$LOCK_STALE" ] && [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        cat "$LAST_FILE" 2>/dev/null
        exit 0
    fi
    if [ -n "$owner" ]; then
        pkill -9 -P "$owner" 2>/dev/null || true
        kill -9 "$owner" 2>/dev/null || true
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || { cat "$LAST_FILE" 2>/dev/null; exit 0; }
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 143' INT TERM

if "$UV" run --quiet --script "$HELPER" > "$LAST_FILE.tmp" 2> "$CACHE_DIR/stderr.log" && [ -s "$LAST_FILE.tmp" ]; then
    mv -f "$LAST_FILE.tmp" "$LAST_FILE"
    cat "$LAST_FILE"
elif [ -s "$LAST_FILE" ]; then
    # Helper died (deadline, uv hiccup): keep the last answer rather than blank.
    cat "$LAST_FILE"
else
    echo "Deco ? | sfimage=wifi.exclamationmark template=true"
    echo "---"
    echo "Helper failed: $(tail -1 "$CACHE_DIR/stderr.log" 2>/dev/null)"
fi
