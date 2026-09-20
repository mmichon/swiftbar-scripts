#!/bin/bash
#
# Relaunch SwiftBar if it has died. Run from launchd every 60s; see
# ~/Library/LaunchAgents/com.mmichon.swiftbar-watchdog.plist.
#
# Why this exists: SwiftBar is a login item, not a launchd job, so nothing
# brings it back when it dies. metrics.30s.sh already restarts a host that is
# *spinning*, but it cannot notice one that is *gone* -- it runs inside SwiftBar,
# so its ticks stop the instant the host does. The death ledger shows what that
# costs: the 2026-09-20 SIGSEGV left the menu bar empty for 3h47m, and a
# 2026-09-09 death went 116h before the next tick. This closes that hole from
# outside the process, where the observation actually works.
#
# Deliberately not `KeepAlive` on SwiftBar itself: launchd would then own the
# process and race the login item into two instances. Polling for absence and
# using `open -a` keeps LaunchServices the single launcher.
#
# Dot-prefixed so SwiftBar does not try to load it as a plugin (same convention
# as .crd-jiggle).

PAUSE_FILE="$HOME/Library/Application Support/xbar-metrics/watchdog_paused"
LOG_FILE="$HOME/Library/Application Support/xbar-metrics/watchdog_log"

# An intentional quit should stay quit. `touch` the pause file to stop the
# watchdog without unloading it; `rm` it to resume.
[ -f "$PAUSE_FILE" ] && exit 0

# `pgrep -x SwiftBar` is correct here -- the blind spot documented in
# metrics.30s.sh only applies to callers that are themselves SwiftBar children.
# This runs under launchd, so the process is visible.
pgrep -x SwiftBar >/dev/null 2>&1 && exit 0

# Confirm rather than trust a single sample: a host mid-relaunch (the metrics
# spin watchdog quits and reopens it) is briefly absent and must not be raced
# into a second instance.
sleep 5
pgrep -x SwiftBar >/dev/null 2>&1 && exit 0

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
printf '%s\trelaunch\tSwiftBar not running\n' "$(date +%s)" >> "$LOG_FILE"

open -a SwiftBar 2>/dev/null

# Keep the log bounded; this file is a breadcrumb, not a dataset.
if [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
