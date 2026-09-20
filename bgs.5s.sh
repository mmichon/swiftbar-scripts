#!/bin/bash

# <xbar.title>Background Sounds</xbar.title>
# <xbar.version>1.7</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Toggle macOS Background Sounds.</xbar.desc>

CACHE_DIR="${TMPDIR:-/tmp}/xbar-bgs.$(id -u)"
LOCK="$CACHE_DIR/run.lock"
LAST_FILE="$CACHE_DIR/last_output.txt"
OUT_FILE="$CACHE_DIR/lsof_output.txt"

# Runtime caps (seconds). LSOF_TIMEOUT bounds the one call here that can block
# indefinitely; LOCK_STALE is the backstop for reclaiming a lock whose owner
# died without cleaning up. Both sit under the 5s refresh so a wedged tick
# clears before many more arrive.
LSOF_TIMEOUT=3
LOCK_STALE=15

mkdir -p "$CACHE_DIR" 2>/dev/null

# Action handlers run before the guard: a click is the user waiting on us, and
# `shortcuts run` has nothing to do with the state probe below.
if [ "$1" = "on" ]; then
    /usr/bin/shortcuts run "Background sounds On" > /dev/null 2>&1
    exit
elif [ "$1" = "off" ]; then
    /usr/bin/shortcuts run "Background sounds Off" > /dev/null 2>&1
    exit
fi

# --- Single-instance guard ---------------------------------------------------
# The same guard space.1s.sh uses, and for a sharper reason. The lsof call below
# walks the whole open-file table, which stalls for as long as an unreachable
# SMB server takes to time out -- and this Mac keeps four SMB mounts. SwiftBar
# fires this plugin every 5s regardless of whether the last run finished, so a
# 55s stall queues a dozen invocations that then all complete in the same
# millisecond. That burst is what killed the host on 2026-09-20: a dozen plugin
# operations finishing at once on one NSOperationQueue raced SwiftBar's own
# (not thread-safe) output teardown into heap corruption and a SIGSEGV. An
# atomic mkdir lock keeps at most one run alive, so no backlog can form.
if ! mkdir "$LOCK" 2>/dev/null; then
    owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$LOCK_STALE" ] && [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        # A recent run still owns the lock -- let it finish; skip this tick.
        # Replay the last known output so the menu bar item does not blank out.
        cat "$LAST_FILE" 2>/dev/null
        exit 0
    fi
    # Stale or dead owner: kill any leftovers (a wedged lsof is the likely
    # occupant), then take over the lock.
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

# State detection
IS_ON=0
SOUND_NAME=""
HEARD_PID=$(/usr/bin/pgrep -x heard)

if [ -n "$HEARD_PID" ]; then
    # Search only for files ending in .m4a opened by 'heard'. Run it under a
    # watchdog rather than trusting it to return: a blocked lsof is not
    # interruptible by the lock alone, and holding the lock for a full SMB
    # timeout would blank this item for a minute at a time.
    /usr/sbin/lsof -p "$HEARD_PID" -Fn > "$OUT_FILE" 2>/dev/null &
    lsof_pid=$!
    ( sleep "$LSOF_TIMEOUT"; kill -9 "$lsof_pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd_pid=$!

    status=0
    wait "$lsof_pid" 2>/dev/null || status=$?
    kill "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true

    if [ "$status" -ne 0 ] && [ ! -s "$OUT_FILE" ]; then
        # lsof was killed mid-walk and told us nothing. Reporting "Off" here
        # would flip the icon on a filesystem hiccup, so keep the last answer.
        cat "$LAST_FILE" 2>/dev/null
        exit 0
    fi

    SOUND_FILE=$(/usr/bin/grep "\.m4a$" "$OUT_FILE" | /usr/bin/awk -F/ '{print $NF}' | /usr/bin/sed 's/\.m4a//' | /usr/bin/head -n 1)
    if [ -n "$SOUND_FILE" ]; then
        IS_ON=1
        SOUND_NAME="$SOUND_FILE"
    fi
fi

# Output
# Buffered so the successful result can be cached verbatim for the replay paths
# above. Using 'template=true' ensures the SF Symbol adapts to the menu bar's
# color/theme.
{
if [ "$IS_ON" -eq 1 ]; then
    echo " | sfimage=waveform template=true"
    echo "---"
    echo "Status: Playing ($SOUND_NAME)"
    echo "Turn Off | bash=\"$0\" param1=off terminal=false refresh=true"
else
    echo " | sfimage=waveform.slash template=true"
    echo "---"
    echo "Status: Off"
    echo "Turn On | bash=\"$0\" param1=on terminal=false refresh=true"
fi

echo "---"
echo "Accessibility Settings | href='x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Audio'"
} > "$LAST_FILE.tmp"

mv -f "$LAST_FILE.tmp" "$LAST_FILE" 2>/dev/null
cat "$LAST_FILE"
