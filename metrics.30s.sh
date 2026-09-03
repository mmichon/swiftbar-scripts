#!/bin/bash

# <xbar.title>System Metrics Combined</xbar.title>
# <xbar.version>v1.5</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Combined Metrics with ANSI per-metric coloring, compact format, top processes, and passive sustained-CPU-hog warnings.</xbar.desc>
# <xbar.dependencies>bash, vm_stat, top, ps, ping, bc</xbar.dependencies>

# State for the CPU-hog warning. The plugin is otherwise stateless; these files
# are what let it tell a brief spike apart from a process that has been hot for
# minutes. Per-user dir, same convention as space.1s.sh.
#   streak  - pid \t name \t tier \t first_seen \t peak_cpu   (rebuilt every tick)
#   killed  - epoch \t name                                   (appended on kill)
#   ignored - name \t until_epoch                             (per-process cooldown)
#   host_streak   - pid \t first_seen \t peak_cpu             (SwiftBar spin clock)
#   host_restarts - epoch \t peak_cpu                         (appended on auto-restart)
STATE_DIR="${TMPDIR:-/tmp}/xbar-metrics.$(id -u)"
STREAK_FILE="$STATE_DIR/streak"
KILLED_FILE="$STATE_DIR/killed"
IGNORED_FILE="$STATE_DIR/ignored"
HOST_STREAK_FILE="$STATE_DIR/host_streak"
HOST_RESTART_FILE="$STATE_DIR/host_restarts"
HOST_HELPER="$STATE_DIR/restart-host.sh"
mkdir -p "$STATE_DIR" 2>/dev/null

# Tunables for the hog warning. Two tiers, because "a lot of CPU" means different
# things for different apps: a compiler at 300% for a minute is fine, a menu-bar
# widget holding half a core for five minutes is not. A single tick below the
# threshold resets the streak, which is what keeps spikes from ever warning.
HOG_CPU_HOG=100          # tier 1: CPU% that counts as a hog
HOG_SUSTAIN_HOG=180      # tier 1: how long it must stay that hot to warn
HOG_CPU_BURN=50          # tier 2: CPU% for a background app that should be idle
HOG_SUSTAIN_BURN=300     # tier 2: longer sustain, since the bar is lower
HOG_SUSTAIN_REPEAT=45    # sustain for either tier when recently killed by hand
HOG_REPEAT_WINDOW=3600   # how far back "recently killed" looks
HOG_IGNORE_SEC=3600      # per-process cooldown from "Ignore for 1 hour"
# Never warn about these: killing them is never the answer. SwiftBar/xbar are the
# host app running this plugin -- it shows high CPU partly *because* of these ticks,
# and killing it would take the menu bar (and the warning) with it.
HOG_EXCLUDE="kernel_task WindowServer mds mds_stores mdworker backupd top SwiftBar xbar"

# Tunables for the host (SwiftBar) spin watchdog. The host stays out of the hog
# path above -- click-to-kill must never target the app drawing this menu -- but it
# does get its own clock, because it has a failure mode the generic check can't see:
# menu-bar apps can fall into a self-sustaining `_activeTrackingAreasNeedUpdate ->
# NSCursor set` run-loop cycle and hold a full core indefinitely. It costs that much
# only when the accessibility pointer is customized (no cached cursor, so every set
# regenerates the bitmap and re-registers it with SkyLight), which is why the warning
# links to the Pointer pane. Restarting the host clears it; nothing else does.
# 60, not 80: the spin measures ~82% as a true rate (CPU-time delta over 20s), but
# top's instantaneous sample of the same spin swings between ~67% and ~110%, so a
# bar set near the real value flaps. A healthy SwiftBar idles in low single digits,
# so 60 is still an enormous margin, and HOST_GRACE_TICKS absorbs the odd cool tick.
HOST_CPU_SPIN=60            # %CPU that counts as a runaway host
HOST_GRACE_TICKS=1          # cool ticks tolerated before the clock resets
HOST_SUSTAIN=300            # how long it must stay that hot before acting
HOST_MIN_UPTIME=600         # ignore a host that just launched (anti restart-loop)
HOST_RESTART_COOLDOWN=3600  # at most one auto-restart per hour

# --- Kill action mode ---
# When invoked as `metrics.30s.sh kill <pid> <name>` (from a dropdown click),
# confirm, then SIGKILL the process: the things this menu targets are runaway
# hogs, and some of them trap or ignore SIGTERM, so a graceful signal makes the
# click feel unreliable. -9 always wins, immediately.
# The kill is recorded so a repeat offender gets flagged much faster next time.
if [ "$1" = "kill" ]; then
    pid="$2"; name="$3"
    osascript -e "display dialog \"Kill ${name} (PID ${pid})?\" buttons {\"Cancel\",\"Kill\"} default button \"Cancel\" with icon caution" >/dev/null 2>&1 || exit 0
    printf '%s\t%s\n' "$(date +%s)" "$name" >> "$KILLED_FILE"
    kill -9 "$pid" 2>/dev/null              # SIGKILL -- always, so it dies predictably
    for _ in 1 2 3 4 5; do                  # let it finish dying before we redraw
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    # Redraw now rather than waiting out the tick. refresh=true on the menu item
    # fires too early (this script is still running), so trigger the host directly.
    open -g "swiftbar://refreshplugin?name=$(basename "$0" | cut -d. -f1)" >/dev/null 2>&1
    exit 0
fi

# --- Ignore action mode ---
# `metrics.30s.sh ignore <name>` silences warnings for that process for an hour.
if [ "$1" = "ignore" ]; then
    printf '%s\t%s\n' "$2" "$(( $(date +%s) + HOG_IGNORE_SEC ))" >> "$IGNORED_FILE"
    exit 0
fi

# Stable path to this script, so dropdown items can call back into the kill mode.
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ANSI Color Codes
APPEARANCE=${OS_APPEARANCE:-${SWIFTBAR_OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")}}
if [ "$APPEARANCE" = "Dark" ]; then
    RED="\033[38;5;196m"    # System Red
    YELLOW="\033[38;5;226m" # System Yellow
    P_HEX="#ffffff"
    RED_HEX="#FF0000"
else
    RED="\033[38;5;160m"    # System Red (Darker)
    YELLOW="\033[38;5;172m" # System Orange/Amber (Visible)
    P_HEX="#000000"
    RED_HEX="#D70000"
fi
# Reset to SwiftBar's color=primary (adapts to light/dark) rather than hardcoded RGB
P_ANSI="\033[0m"

# --- Memory ---
# ... (rest of the logic stays same until output)
vm_stat_output=$(vm_stat)
pages_free=$(echo "$vm_stat_output" | awk '/Pages free:/ {print $3}' | sed 's/\.//')
pages_inactive=$(echo "$vm_stat_output" | awk '/Pages inactive:/ {print $3}' | sed 's/\.//')
pages_speculative=$(echo "$vm_stat_output" | awk '/Pages speculative:/ {print $3}' | sed 's/\.//')
page_size=4096
total_free_pages=$(echo "$pages_free + $pages_inactive + $pages_speculative" | bc)
free_mem_gb=$(echo "scale=1; $total_free_pages * $page_size / (1024 * 1024 * 1024)" | bc)
free_mem_gb=$(printf "%.1f" "$free_mem_gb")

pressure_level=$(sysctl -n kern.memorystatus_vm_pressure_level)
mem_ansi=""
if [ "$pressure_level" -eq 4 ]; then 
    mem_ansi=$RED
elif [ "$pressure_level" -eq 2 ]; then 
    mem_ansi=$YELLOW
fi

# Top memory-consuming process. Unlike CPU, RSS is a point-in-time value, so a
# single sample is enough -- no delta needed. Scan 10 deep so there's a real
# candidate left after excluding the ever-present, never-interesting names:
# WindowServer is system chrome (no relation to killing it being useful), and
# Chrome itself is normally the single biggest memory user on this machine but
# never the one worth flagging -- its helpers are supposed to hold a lot of RAM.
MEM_EXCLUDE="kernel_task WindowServer"
top_mem_output=$(top -l 1 -n 10 -o mem -stats pid,command,mem)
top_mem_candidates=$(echo "$top_mem_output" | awk '
    /^PID/ { block=1; next }
    block && count < 10 {
        pid=$1; mem=$NF
        $1=""; $NF=""
        sub(/^[ \t]+/,""); sub(/[ \t]+$/,"")
        print pid "|" $0 "|" mem
        count++
    }
')
top_mem_pid=""; top_mem_name=""; top_mem_val=""
while IFS='|' read -r c_pid c_name c_mem; do
    [ -z "$c_pid" ] && continue
    # top truncates long command names (see the CPU hog section below for the
    # same problem), so resolve the real name for exclusion, display, and kill.
    real_name=$(ps -p "$c_pid" -o comm= 2>/dev/null)
    real_name="${real_name##*/}"
    [ -z "$real_name" ] && real_name="$c_name"

    excluded=0
    for ex in $MEM_EXCLUDE; do
        [ "$real_name" = "$ex" ] && excluded=1 && break
    done
    case "$real_name" in
        "Google Chrome"*|com.google.Chrome*) excluded=1 ;;
    esac
    [ "$excluded" -eq 1 ] && continue

    top_mem_pid=$c_pid; top_mem_name=$real_name; top_mem_val=$c_mem
    break
done <<< "$top_mem_candidates"

# --- CPU & Top Processes ---
# top -l 2 gives two samples. The second one is accurate.
# Scan 12 deep, not 5: the dropdown only shows 5, but a tier-2 offender sitting at
# ~50% is easily ranked below five Chrome helpers and would otherwise be invisible
# to the hog check. Same single top call either way.
top_output=$(top -l 2 -n 12 -F -R -o cpu -stats pid,command,cpu)

# Extract CPU idle from the SECOND sample
cpu_idle=$(echo "$top_output" | awk '/CPU usage/ {idle=$7} END {print idle}' | sed 's/%//')
cpu_usage=$(echo "100 - $cpu_idle" | bc)
cpu_usage=$(printf "%.0f" "$cpu_usage")

# Extract top 5 processes from the SECOND sample
top_processes_full=$(echo "$top_output" | awk '
    /^PID/ { block++; next }
    block == 2 && count < 12 {
        pid = $1
        cpu = $NF
        $1 = ""; $NF = ""
        sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
        print pid "|" $0 "|" cpu
        count++
    }
')

# Get top 5 for dropdown, carrying the PID: "pid|name: cpu%"
top_processes=$(echo "$top_processes_full" | head -5 | awk -F'|' '{print $1 "|" $2 ": " $3 "%"}')

# Get top non-kernel process for menu bar
top_non_kernel_line=$(echo "$top_processes_full" | grep -v "kernel_task" | head -1)
top_non_kernel=$(echo "$top_non_kernel_line" | awk -F'|' '{print $2}')
top_non_kernel_cpu=$(echo "$top_non_kernel_line" | awk -F'|' '{print $3}')
top_non_kernel_cpu_int=$(printf "%.0f" "${top_non_kernel_cpu:-0}")

cpu_display="${cpu_usage}%"
if [ -n "$top_non_kernel" ] && [ "$top_non_kernel_cpu_int" -gt 50 ]; then
    cpu_display="${cpu_usage}%(${top_non_kernel})"
fi

# --- Sustained CPU hog detection ---
# Everything above is instantaneous. This section is the only part of the plugin
# that remembers anything: it tracks how long each hot process has *stayed* hot,
# so a 3-second spike never warns but a stuck app does.
now=$(date +%s)

# Drop expired cooldowns, and trim kill history to a day.
[ -f "$IGNORED_FILE" ] && awk -F'\t' -v now="$now" '$2 > now' "$IGNORED_FILE" > "$IGNORED_FILE.tmp" 2>/dev/null && mv "$IGNORED_FILE.tmp" "$IGNORED_FILE"
[ -f "$KILLED_FILE" ] && awk -F'\t' -v cut=$((now - 86400)) '$1 >= cut' "$KILLED_FILE" > "$KILLED_FILE.tmp" 2>/dev/null && mv "$KILLED_FILE.tmp" "$KILLED_FILE"

# Epoch of the most recent hand-kill of this process within the repeat window.
recent_kill_epoch() {
    [ -f "$KILLED_FILE" ] || return 0
    awk -F'\t' -v n="$1" -v cut=$((now - HOG_REPEAT_WINDOW)) \
        '$1 >= cut && $2 == n {e=$1} END {if (e) print e}' "$KILLED_FILE"
}

fmt_dur() {
    if [ "$1" -ge 3600 ]; then printf '%dh%dm' $(($1 / 3600)) $((($1 % 3600) / 60))
    elif [ "$1" -ge 60 ]; then printf '%dm' $(($1 / 60))
    else printf '%ds' "$1"; fi
}

hog_name=""; hog_pid=""; hog_cpu=0; hog_dur=0; hog_tier=""; hog_killed_ago=""
hog_best=-1
streak_rows=()

while IFS='|' read -r p_pid p_name p_cpu; do
    [ -z "$p_pid" ] && continue
    cpu_int=$(printf "%.0f" "${p_cpu:-0}" 2>/dev/null)
    [[ "$cpu_int" =~ ^[0-9]+$ ]] || continue
    [ "$cpu_int" -lt "$HOG_CPU_BURN" ] && continue

    # top truncates the command column (com.apple.weather.menu renders as
    # com.apple.weathe, which collides with every other long com.apple.*), so get
    # the real name for display, exclusions, and kill-history matching.
    real_name=$(ps -p "$p_pid" -o comm= 2>/dev/null)
    real_name="${real_name##*/}"
    [ -z "$real_name" ] && real_name="$p_name"

    excluded=0
    for ex in $HOG_EXCLUDE; do
        [ "$real_name" = "$ex" ] && excluded=1 && break
    done
    [ "$excluded" -eq 1 ] && continue
    if [ -f "$IGNORED_FILE" ] && awk -F'\t' -v n="$real_name" '$1 == n {f=1} END {exit !f}' "$IGNORED_FILE"; then
        continue
    fi

    # Streaks are keyed by PID, so a restarted process correctly starts over.
    # first_hot = when it crossed the tier-2 bar; first_hog = when it crossed
    # tier 1 (reset to 0 the moment it drops back below, so the hog clock is
    # always a run of consecutive hot ticks).
    prev_first_hot=""; prev_first_hog=0; prev_peak=0
    if [ -f "$STREAK_FILE" ]; then
        prev_row=$(awk -F'\t' -v pid="$p_pid" '$1 == pid {print; exit}' "$STREAK_FILE")
        if [ -n "$prev_row" ]; then
            prev_first_hot=$(printf '%s' "$prev_row" | cut -f3)
            prev_first_hog=$(printf '%s' "$prev_row" | cut -f4)
            prev_peak=$(printf '%s' "$prev_row" | cut -f5)
        fi
    fi
    [[ "$prev_first_hot" =~ ^[0-9]+$ ]] || prev_first_hot=$now
    [[ "$prev_first_hog" =~ ^[0-9]+$ ]] || prev_first_hog=0
    [[ "$prev_peak" =~ ^[0-9]+$ ]] || prev_peak=0

    first_hot=$prev_first_hot
    first_hog=$prev_first_hog
    if [ "$cpu_int" -ge "$HOG_CPU_HOG" ]; then
        tier="hog"
        [ "$first_hog" -eq 0 ] && first_hog=$now
    else
        tier="burn"
        first_hog=0
    fi
    peak=$prev_peak
    [ "$cpu_int" -gt "$peak" ] && peak=$cpu_int
    streak_rows+=("${p_pid}"$'\t'"${real_name}"$'\t'"${first_hot}"$'\t'"${first_hog}"$'\t'"${peak}")

    # A process I killed by hand within the last hour has already proven itself,
    # so it warns on a much shorter fuse if it comes back hot.
    k_epoch=$(recent_kill_epoch "$real_name")
    if [ -n "$k_epoch" ]; then
        need=$HOG_SUSTAIN_REPEAT; elapsed=$((now - first_hot))
    elif [ "$tier" = "hog" ]; then
        need=$HOG_SUSTAIN_HOG;    elapsed=$((now - first_hog))
    else
        need=$HOG_SUSTAIN_BURN;   elapsed=$((now - first_hot))
    fi
    [ "$elapsed" -lt "$need" ] && continue

    # Rank by severity class, then by how long it has been going, and only then by
    # current CPU. Ranking on instantaneous CPU alone makes the named process flap
    # between offenders every tick, which is exactly the kind of twitchy menu bar
    # this is meant to avoid.
    [ "$tier" = "hog" ] && score=$((1000000 + elapsed)) || score=$elapsed
    if [ "$score" -gt "$hog_best" ] || { [ "$score" -eq "$hog_best" ] && [ "$cpu_int" -gt "$hog_cpu" ]; }; then
        hog_best=$score
        hog_name=$real_name; hog_pid=$p_pid; hog_cpu=$cpu_int
        hog_dur=$elapsed; hog_tier=$tier
        hog_killed_ago=""
        [ -n "$k_epoch" ] && hog_killed_ago=$((now - k_epoch))
    fi
done <<< "$top_processes_full"

# Rewrite atomically. Processes absent this tick simply aren't carried over,
# which is exactly how a streak resets.
if [ ${#streak_rows[@]} -gt 0 ]; then
    printf '%s\n' "${streak_rows[@]}" > "$STREAK_FILE.tmp" && mv "$STREAK_FILE.tmp" "$STREAK_FILE"
else
    : > "$STREAK_FILE"
fi

# --- Host (SwiftBar) spin watchdog ---
# Same shape as the hog clock above -- a run of consecutive hot ticks, so a spike
# never acts -- but the remedy is a restart of the host rather than a kill, and it
# fires on its own because a spinning menu bar is exactly the state in which nobody
# is looking at the menu bar.
host_pid=$(pgrep -x SwiftBar 2>/dev/null | head -1)
[ -z "$host_pid" ] && host_pid=$(pgrep -x xbar 2>/dev/null | head -1)
host_cpu_int=0; host_dur=0; host_peak=0; host_restart_ago=""

if [ -n "$host_pid" ]; then
    # Reuse the top sample already taken; fall back to ps for a host that somehow
    # ranked below the 12 rows scanned.
    host_cpu=$(awk -F'|' -v pid="$host_pid" '$1 == pid {print $3; exit}' <<< "$top_processes_full")
    [ -z "$host_cpu" ] && host_cpu=$(ps -o %cpu= -p "$host_pid" 2>/dev/null | tr -d ' ')
    host_cpu_int=$(printf "%.0f" "${host_cpu:-0}" 2>/dev/null)
    [[ "$host_cpu_int" =~ ^[0-9]+$ ]] || host_cpu_int=0

    h_prev_pid=""; h_since=0; h_peak=0; h_cool=0
    if [ -f "$HOST_STREAK_FILE" ]; then
        h_prev_pid=$(cut -f1 "$HOST_STREAK_FILE" 2>/dev/null)
        h_since=$(cut -f2 "$HOST_STREAK_FILE" 2>/dev/null)
        h_peak=$(cut -f3 "$HOST_STREAK_FILE" 2>/dev/null)
        h_cool=$(cut -f4 "$HOST_STREAK_FILE" 2>/dev/null)
    fi
    [[ "$h_since" =~ ^[0-9]+$ ]] || h_since=0
    [[ "$h_peak" =~ ^[0-9]+$ ]] || h_peak=0
    [[ "$h_cool" =~ ^[0-9]+$ ]] || h_cool=0
    # A restarted host is a new PID, which correctly starts the clock over.
    [ "$h_prev_pid" = "$host_pid" ] || { h_since=0; h_peak=0; h_cool=0; }

    if [ "$host_cpu_int" -ge "$HOST_CPU_SPIN" ]; then
        [ "$h_since" -eq 0 ] && h_since=$now
        h_cool=0
        [ "$host_cpu_int" -gt "$h_peak" ] && h_peak=$host_cpu_int
    elif [ "$h_since" -gt 0 ] && [ "$h_cool" -lt "$HOST_GRACE_TICKS" ]; then
        h_cool=$((h_cool + 1))   # one sampling dip does not undo a long streak
    else
        h_since=0; h_peak=0; h_cool=0
    fi

    if [ "$h_since" -gt 0 ]; then
        host_dur=$((now - h_since)); host_peak=$h_peak
        printf '%s\t%s\t%s\t%s\n' "$host_pid" "$h_since" "$h_peak" "$h_cool" > "$HOST_STREAK_FILE.tmp" \
            && mv "$HOST_STREAK_FILE.tmp" "$HOST_STREAK_FILE"
    else
        rm -f "$HOST_STREAK_FILE" 2>/dev/null
    fi
fi

# Most recent auto-restart, for both the rate limit and the dropdown row.
host_last_restart=0
if [ -s "$HOST_RESTART_FILE" ]; then
    host_last_restart=$(awk -F'\t' 'END {print $1}' "$HOST_RESTART_FILE" 2>/dev/null)
    [[ "$host_last_restart" =~ ^[0-9]+$ ]] || host_last_restart=0
    # Keep a week of history; this file is also the "why did my menu bar blink" log.
    awk -F'\t' -v cut=$((now - 604800)) '$1 >= cut' "$HOST_RESTART_FILE" > "$HOST_RESTART_FILE.tmp" 2>/dev/null \
        && mv "$HOST_RESTART_FILE.tmp" "$HOST_RESTART_FILE"
fi
[ "$host_last_restart" -gt 0 ] && [ $((now - host_last_restart)) -lt "$HOST_RESTART_COOLDOWN" ] \
    && host_restart_ago=$((now - host_last_restart))

if [ -n "$host_pid" ] && [ "$host_dur" -ge "$HOST_SUSTAIN" ] && [ -z "$host_restart_ago" ]; then
    # macOS ps has no `etimes`; parse `etime` ([[dd-]hh:]mm:ss) into seconds.
    host_uptime=$(ps -o etime= -p "$host_pid" 2>/dev/null | awk '{
        t = $1; d = 0
        if (split(t, a, "-") == 2) { d = a[1]; t = a[2] }
        n = split(t, b, ":")
        if (n == 3)      s = b[1] * 3600 + b[2] * 60 + b[3]
        else if (n == 2) s = b[1] * 60 + b[2]
        else             s = b[1]
        print d * 86400 + s
    }')
    [[ "$host_uptime" =~ ^[0-9]+$ ]] || host_uptime=0
    if [ "$host_uptime" -ge "$HOST_MIN_UPTIME" ]; then
        # This script is a child of the host, so it cannot outlive the app it is
        # about to quit: hand the job to a detached helper and let this tick end.
        cat > "$HOST_HELPER" <<'HELPER'
#!/bin/bash
# Written by metrics -- restarts the SwiftBar host after a sustained CPU spin.
# Runs detached, because its parent dies partway through by design.
sleep 1
osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1
for _ in $(seq 1 20); do          # up to 10s for a clean quit
    pgrep -x SwiftBar >/dev/null 2>&1 || break
    sleep 0.5
done
pgrep -x SwiftBar >/dev/null 2>&1 && pkill -x SwiftBar 2>/dev/null
sleep 2
open -a SwiftBar
HELPER
        chmod +x "$HOST_HELPER" 2>/dev/null
        # Record before spawning: this tick is about to be killed mid-flight, and a
        # restart that never made it into the log would defeat the rate limit.
        printf '%s\t%s\n' "$now" "$host_peak" >> "$HOST_RESTART_FILE"
        host_restart_ago=0
        nohup /bin/bash "$HOST_HELPER" >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
fi

# --- Thermal / Throttle Detection ---
# Combine multiple signals into throttle_level: 0=none, 1=moderate, 2=serious.
# Each signal can only raise the level, never lower it (logical OR / max).
#   1) thermalpressure notification - OS-level, coarse; often stays 0 on Apple Silicon.
#   2) pmset -g therm CPU_Speed_Limit - no sudo; <100 means the OS is capping CPU speed.
#   3) smctemp CPU temperature - the most direct signal on M-series. powermetrics
#      does NOT expose a numeric die temp on Apple Silicon (only a qualitative
#      pressure level), so we read the SMC sensor via `smctemp` instead (no sudo):
#        brew install narugit/tap/smctemp
#      If smctemp is not installed, this signal is simply skipped.

# Tunables
PMSET_SPEED_SERIOUS=75   # CPU_Speed_Limit at/below this = serious throttle
TEMP_MODERATE_C=90       # CPU die temp >= this = moderate
TEMP_SERIOUS_C=100       # CPU die temp >= this = serious

throttle_level=0
throttle_detail=""

# 1) Thermal pressure notification
thermal_pressure=$(notifyutil -g "com.apple.system.thermalpressure" 2>/dev/null | awk '{print $2}')
if [[ "$thermal_pressure" =~ ^[0-9]+$ && "$thermal_pressure" -gt 0 ]]; then
    if [ "$thermal_pressure" -ge 2 ]; then
        [ "$throttle_level" -lt 2 ] && throttle_level=2
    else
        [ "$throttle_level" -lt 1 ] && throttle_level=1
    fi
    throttle_detail="${throttle_detail}pressure=${thermal_pressure} "
fi

# 2) pmset -g therm (unprivileged); CPU_Speed_Limit < 100 indicates speed capping
speed_limit=$(pmset -g therm 2>/dev/null | awk -F'=' '/CPU_Speed_Limit/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
if [[ "$speed_limit" =~ ^[0-9]+$ && "$speed_limit" -lt 100 ]]; then
    if [ "$speed_limit" -le "$PMSET_SPEED_SERIOUS" ]; then
        [ "$throttle_level" -lt 2 ] && throttle_level=2
    else
        [ "$throttle_level" -lt 1 ] && throttle_level=1
    fi
    throttle_detail="${throttle_detail}speed=${speed_limit}% "
fi

# 3) smctemp CPU temperature (no sudo; skipped if smctemp is not installed)
if command -v smctemp >/dev/null 2>&1; then
    cpu_temp=$(smctemp -c 2>/dev/null | tr -d ' ')
fi
if [[ "$cpu_temp" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    cpu_temp_int=$(printf "%.0f" "$cpu_temp")
    cpu_temp_f=$(printf "%.0f" "$(echo "$cpu_temp_int * 9 / 5 + 32" | bc -l)")
    if [ "$cpu_temp_int" -ge "$TEMP_SERIOUS_C" ]; then
        [ "$throttle_level" -lt 2 ] && throttle_level=2
    elif [ "$cpu_temp_int" -ge "$TEMP_MODERATE_C" ]; then
        [ "$throttle_level" -lt 1 ] && throttle_level=1
    fi
fi

cpu_ansi=""
if [ "$throttle_level" -ge 2 ]; then
    cpu_ansi=$RED
elif [ "$throttle_level" -ge 1 ]; then
    cpu_ansi=$YELLOW
fi

# A sustained hog always wins the CPU field: red, marked, and naming the culprit
# rather than whatever happens to be top of the list. This is the whole warning --
# no banner, no dialog, just a glance-able change in the menu bar.
if [ -n "$hog_name" ]; then
    cpu_ansi=$RED
    cpu_display="⚠${cpu_usage}%(${hog_name})"
fi

# --- Ping ---
SITES=(8.8.8.8 1.1.1.1)
PING_TIMES=()
for site in "${SITES[@]}"; do
    if res=$(ping -c 1 -n -q -t 2 "$site" 2>/dev/null); then
        val=$(echo "$res" | awk -F '/' 'END {printf "%.0f\n", $5}')
        [ -n "$val" ] && PING_TIMES+=("$val")
    fi
done

ping_ansi=""
if [ ${#PING_TIMES[@]} -gt 0 ]; then
    sum=0; for t in "${PING_TIMES[@]}"; do sum=$((sum + t)); done
    mean=$((sum / ${#PING_TIMES[@]}))
    sq_sum_diff=0; for t in "${PING_TIMES[@]}"; do diff=$((t - mean)); sq_sum_diff=$((sq_sum_diff + diff * diff)); done
    sd=$(echo "sqrt($sq_sum_diff / ${#PING_TIMES[@]})" | bc)
    ping_str="${mean}±${sd}ms"
    if [ "$mean" -gt 500 ]; then 
        ping_ansi=$RED
    elif [ "$mean" -gt 150 ]; then 
        ping_ansi=$YELLOW
    fi
else
    ping_str="ERR"
    ping_ansi=$RED
fi

# --- Output ---
# Menu Bar: ANSI colors only when active, otherwise default text
# This ensures non-colored text is system-default black/white
BAR_MEM="${free_mem_gb}GB"
[ -n "$mem_ansi" ] && BAR_MEM="${mem_ansi}${BAR_MEM}${P_ANSI}"

BAR_CPU="${cpu_display}"
[ -n "$cpu_ansi" ] && BAR_CPU="${cpu_ansi}${BAR_CPU}${P_ANSI}"

BAR_PING="${ping_str}"
[ -n "$ping_ansi" ] && BAR_PING="${ping_ansi}${BAR_PING}${P_ANSI}"

echo -e "${BAR_MEM} ${BAR_CPU} ${BAR_PING} | ansi=true font='SF Mono' size=12 color=primary"
echo "---"
# Host watchdog block, above everything: when the menu bar itself is spinning, that
# is the thing worth reading first.
if [ -n "$host_restart_ago" ] || [ "$host_dur" -gt 0 ]; then
    if [ -n "$host_restart_ago" ]; then
        echo -e "${RED}↻ SwiftBar auto-restarted $(fmt_dur "$host_restart_ago") ago (runaway cursor loop)${P_ANSI} | ansi=true font='SF Mono' size=12 color=primary bash=true terminal=false"
    else
        echo -e "${RED}⚠ SwiftBar spinning: ${host_cpu_int}% for $(fmt_dur "$host_dur")${P_ANSI} | ansi=true font='SF Mono' size=12 color=primary bash=true terminal=false"
    fi
    # Root cause, when it is the one we know about: a customized accessibility
    # pointer makes every NSCursor set regenerate the cursor bitmap, which turns a
    # normally-invisible run-loop cycle into a full core -- in every menu-bar app,
    # not just this one. Resetting the pointer colors is the actual fix.
    if [ "$(defaults read com.apple.universalaccess cursorIsCustomized 2>/dev/null)" = "1" ]; then
        echo "Custom pointer causes menu-bar CPU spins — reset it | size=12 color=primary href='x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display'"
    fi
    echo "---"
fi
# Warning block, promoted to the top so the fix is one click from the glance.
if [ -n "$hog_name" ]; then
    hog_when=$(fmt_dur "$hog_dur")
    hog_hdr="⚠ ${hog_name} — ${hog_cpu}% for ${hog_when}"
    [ -n "$hog_killed_ago" ] && hog_hdr="${hog_hdr} (killed $(fmt_dur "$hog_killed_ago") ago)"
    hog_kill_attrs="bash=\"$SCRIPT_PATH\" param1=kill param2=$hog_pid param3=\"$hog_name\" terminal=false refresh=true"
    echo -e "${RED}${hog_hdr}${P_ANSI} | ansi=true font='SF Mono' size=12 color=primary $hog_kill_attrs"
    echo "Kill ${hog_name} (PID ${hog_pid}) | size=12 color=primary $hog_kill_attrs"
    echo "Ignore for 1 hour | size=12 color=primary bash=\"$SCRIPT_PATH\" param1=ignore param2=\"$hog_name\" terminal=false refresh=true"
    echo "---"
fi
# Dropdown summary: Monochrome
echo "${free_mem_gb}GB ${cpu_display} ${ping_str} | font='SF Mono' size=12 color=primary bash=true terminal=false"
echo "---"
echo "Memory Free: ${free_mem_gb}GB | color=primary bash=true terminal=false"
if [ -n "$top_mem_name" ]; then
    top_mem_kill_attrs="bash=\"$SCRIPT_PATH\" param1=kill param2=$top_mem_pid param3=\"$top_mem_name\" terminal=false refresh=true"
    echo "Top Memory: ${top_mem_name} (${top_mem_val}) | font='SF Mono' size=12 color=primary $top_mem_kill_attrs"
fi
if [ -n "$cpu_ansi" ]; then
    echo -e "CPU Usage: ${cpu_ansi}${cpu_usage}%${P_ANSI} | ansi=true color=primary bash=true terminal=false"
else
    echo "CPU Usage: ${cpu_usage}% | color=primary bash=true terminal=false"
fi
thermal_mode="nominal"
[ "$throttle_level" -ge 1 ] && thermal_mode="moderate"
[ "$throttle_level" -ge 2 ] && thermal_mode="serious"
thermal_status="$thermal_mode"
[ -n "$throttle_detail" ] && thermal_status="${thermal_mode} (${throttle_detail% })"
echo "Thermal: ${thermal_status} | color=primary bash=true terminal=false"
if [ -n "$cpu_temp_int" ]; then
    temp_ansi=""
    if [ "$cpu_temp_int" -ge "$TEMP_SERIOUS_C" ]; then
        temp_ansi=$RED
    elif [ "$cpu_temp_int" -ge "$TEMP_MODERATE_C" ]; then
        temp_ansi=$YELLOW
    fi
    if [ -n "$temp_ansi" ]; then
        echo -e "Temperature: ${temp_ansi}${cpu_temp_f}°F${P_ANSI} | ansi=true color=primary bash=true terminal=false"
    else
        echo "Temperature: ${cpu_temp_f}°F | color=primary bash=true terminal=false"
    fi
fi
echo "Ping (Mean±SD): ${ping_str} | color=primary bash=true terminal=false"
echo "---"
echo "Top Processes: | color=primary bash=true terminal=false"
line_num=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    pid="${row%%|*}"
    line="${row#*|}"
    name="${line%%:*}"
    line_num=$((line_num + 1))
    kill_attrs="bash=\"$SCRIPT_PATH\" param1=kill param2=$pid param3=\"$name\" terminal=false refresh=true"
    if [ "$line_num" -eq 1 ] && [ "$throttle_level" -ge 2 ]; then
        proc_name=$(echo "$line" | sed 's/: [0-9.]*%$//')
        cpu_part=$(echo "$line" | grep -o '[0-9.]*%$')
        echo -e "${proc_name}: ${RED}${cpu_part}\033[0m | font='SF Mono' size=11 ansi=true color=primary $kill_attrs"
    else
        echo "$line | font='SF Mono' size=11 color=primary $kill_attrs"
    fi
done <<< "$top_processes"
# Recent hand-kills, for transparency about why the warning fuse is short.
if [ -s "$KILLED_FILE" ]; then
    recent_kills=$(awk -F'\t' -v cut=$((now - HOG_REPEAT_WINDOW)) '$1 >= cut {print}' "$KILLED_FILE" | tail -5)
    if [ -n "$recent_kills" ]; then
        echo "---"
        echo "Recently killed: | color=primary bash=true terminal=false"
        while IFS=$'\t' read -r k_epoch k_name; do
            [ -z "$k_name" ] && continue
            echo "${k_name} — $(fmt_dur $((now - k_epoch))) ago | font='SF Mono' size=11 color=primary bash=true terminal=false"
        done <<< "$recent_kills"
    fi
fi
echo "---"
echo "Refresh | refresh=true color=primary"
echo "Open Activity Monitor | bash='open' param1='-a' param2='Activity Monitor' terminal=false color=primary"
