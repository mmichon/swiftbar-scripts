#!/bin/bash

# <swiftbar.title>Chrome Remote Desktop Mode</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Dims screen, disables sleep, and prevents lock screen when a CRD session is active</swiftbar.desc>
# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>

SCRIPT="$HOME/Library/Application Support/xbar/plugins/crd.15s.sh"
FLAG_ACTIVE="/tmp/.crd-mode-active"
FLAG_AUTO="/tmp/.crd-auto-managed"
FLAG_MANUAL_OFF="/tmp/.crd-manual-off"
# Persistent (survives reboot): keep sleep/display awake even with no CRD session
FLAG_LEAVE_ON="$(dirname "$SCRIPT")/.crd-leave-on"
DISPLAYSLEEP_FILE="/tmp/.crd-original-displaysleep"
DEFAULT_DISPLAYSLEEP=5
BRIGHTNESS_FILE="/tmp/.crd-original-brightness"
FLAG_DIMMED="/tmp/.crd-brightness-dimmed"
DEFAULT_BRIGHTNESS=0.8
HOTCORNERS_FILE="/tmp/.crd-original-hotcorners"
FLAG_WAS_LOCKED="/tmp/.crd-was-locked"
IDLE_SINCE_FILE="/tmp/.crd-idle-since"
LOG_FILE="$HOME/Library/Logs/crd-plugin.log"
LOG_MAX_LINES=2000

# System Appearance
APPEARANCE=${OS_APPEARANCE:-${SWIFTBAR_OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")}}
if [ "$APPEARANCE" = "Dark" ]; then
    P_HEX="#ffffff"
else
    P_HEX="#000000"
fi

# --- Logging ---

crd_log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
    # Trim log if too long
    if (( $(wc -l < "$LOG_FILE") > LOG_MAX_LINES )); then
        tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

log_detection_state() {
    local has_assertion screen_locked
    has_assertion=$(pmset -g assertions 2>/dev/null | grep -c 'Remoting session is active')
    is_screen_locked && screen_locked=1 || screen_locked=0
    crd_log "$1" "crd_assertion=$has_assertion mode_on=$MODE_ON crd_active=$CRD_ACTIVE auto=$AUTO_MANAGED leave_on=${LEAVE_ON:-false} locked=$screen_locked"
}

# --- Helpers ---

brightness_available() {
    python3 -c "
import ctypes
ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices')
" 2>/dev/null
}

get_brightness_value() {
    python3 -c "
import ctypes
lib = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices')
lib.DisplayServicesGetBrightness.restype = ctypes.c_int
lib.DisplayServicesGetBrightness.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_float)]
b = ctypes.c_float(0.0)
lib.DisplayServicesGetBrightness(1, ctypes.byref(b))
print(b.value)
" 2>/dev/null
}

set_brightness_value() {
    python3 -c "
import ctypes
lib = ctypes.cdll.LoadLibrary('/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices')
lib.DisplayServicesSetBrightness.restype = ctypes.c_int
lib.DisplayServicesSetBrightness.argtypes = [ctypes.c_uint32, ctypes.c_float]
lib.DisplayServicesSetBrightness(1, ctypes.c_float($1))
" 2>/dev/null
}

is_crd_session_active() {
    # remoting_me2me_host holds a "Remoting session is active" power assertion
    # while a client is connected. This is the most reliable detection method.
    pmset -g assertions 2>/dev/null | grep -q 'remoting_me2me_host.*Remoting session is active'
}

crd_session_age_secs() {
    # Seconds since the current "Remoting session is active" assertion was
    # created (pmset shows its elapsed HH:MM:SS). A fresh assertion is created
    # on every connect, so this is the live session's start. Empty if no session.
    local elapsed h m s
    elapsed=$(pmset -g assertions 2>/dev/null \
        | grep 'remoting_me2me_host.*Remoting session is active' \
        | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
    [[ -z "$elapsed" ]] && return 1
    IFS=: read -r h m s <<< "$elapsed"
    echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

is_on_ac_power() {
    pmset -g ps 2>/dev/null | head -1 | grep -q "AC Power"
}

disablesleep_active() {
    # Check actual pmset state — survives /tmp being cleared on sleep/wake
    pmset -g 2>/dev/null | grep -q 'SleepDisabled.*1'
}

displaysleep_disabled() {
    local val
    val=$(pmset -g 2>/dev/null | awk '/displaysleep/{print $2; exit}')
    [[ "$val" == "0" ]]
}

JIGGLE_BIN="$(dirname "$SCRIPT")/.crd-jiggle"
JIGGLE_SRC="$(dirname "$SCRIPT")/.crd-jiggle.swift"

ensure_jiggle_binary() {
    [[ -x "$JIGGLE_BIN" ]] && return
    swiftc -O "$JIGGLE_SRC" -o "$JIGGLE_BIN" 2>/dev/null
}

assert_user_active() {
    # Move mouse 1px and back to reset HID idle timer. The lock screen checks
    # actual HID idle time, which caffeinate -u does NOT reset.
    ensure_jiggle_binary
    "$JIGGLE_BIN" &>/dev/null
    # Fire again at +5s and +10s to cover the full 15s tick interval
    ("$JIGGLE_BIN" &>/dev/null; sleep 5; "$JIGGLE_BIN" &>/dev/null; sleep 5; "$JIGGLE_BIN" &>/dev/null) &
}

is_screen_locked() {
    ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'
}

is_lid_closed() {
    ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'
}

# Hot corner values that can trigger lock: 5=Screen Saver, 10=Display Sleep, 13=Lock Screen
DANGEROUS_CORNER_VALUES="5|10|13"

save_and_disable_hot_corners() {
    [[ -f "$HOTCORNERS_FILE" ]] && return
    local corners=""
    for pos in tl tr bl br; do
        local val mod
        val=$(defaults read com.apple.dock "wvous-${pos}-corner" 2>/dev/null || echo "0")
        mod=$(defaults read com.apple.dock "wvous-${pos}-modifier" 2>/dev/null || echo "0")
        corners+="${pos}:${val}:${mod} "
        if [[ "$val" =~ ^($DANGEROUS_CORNER_VALUES)$ ]]; then
            defaults write com.apple.dock "wvous-${pos}-corner" -int 0
            defaults write com.apple.dock "wvous-${pos}-modifier" -int 0
        fi
    done
    echo "$corners" > "$HOTCORNERS_FILE"
    killall Dock 2>/dev/null
}

restore_hot_corners() {
    [[ ! -f "$HOTCORNERS_FILE" ]] && return
    local corners
    corners=$(cat "$HOTCORNERS_FILE")
    for entry in $corners; do
        local pos val mod
        pos=$(echo "$entry" | cut -d: -f1)
        val=$(echo "$entry" | cut -d: -f2)
        mod=$(echo "$entry" | cut -d: -f3)
        defaults write com.apple.dock "wvous-${pos}-corner" -int "$val"
        defaults write com.apple.dock "wvous-${pos}-modifier" -int "$mod"
    done
    rm -f "$HOTCORNERS_FILE"
    killall Dock 2>/dev/null
}

dim_screen() {
    # Save and dim brightness
    if brightness_available; then
        local current
        current=$(get_brightness_value)

        # Don't save a near-zero value — restore would just dim again
        if [[ -n "$current" ]] && python3 -c "import sys; sys.exit(0 if float('$current') >= 0.1 else 1)" 2>/dev/null; then
            echo "$current" > "$BRIGHTNESS_FILE"
        else
            echo "$DEFAULT_BRIGHTNESS" > "$BRIGHTNESS_FILE"
        fi

        set_brightness_value 0
        touch "$FLAG_DIMMED"
    fi
}

enable_crd_mode() {
    # $1: whether to dim the screen (default true). Leave-on mode keeps the
    # screen visible when no session is active, so it passes false.
    local dim=${1:-true}
    $dim && dim_screen

    # Disable system sleep via pmset (only on AC power)
    if ! disablesleep_active && is_on_ac_power; then
        sudo pmset -a disablesleep 1
    elif ! is_on_ac_power; then
        crd_log "WARN" "Skipping disablesleep — not on AC power"
    fi

    # Prevent display sleep
    if ! displaysleep_disabled; then
        local current_ds
        current_ds=$(pmset -g 2>/dev/null | awk '/displaysleep/{print $2; exit}')
        [[ -n "$current_ds" && "$current_ds" != "0" ]] && echo "$current_ds" > "$DISPLAYSLEEP_FILE"
        sudo pmset -a displaysleep 0
    fi

    save_and_disable_hot_corners
    assert_user_active

    touch "$FLAG_ACTIVE"
}

restore_brightness() {
    if brightness_available; then
        local saved
        saved=$(cat "$BRIGHTNESS_FILE" 2>/dev/null)
        if [[ -n "$saved" ]]; then
            set_brightness_value "$saved"
        else
            set_brightness_value "$DEFAULT_BRIGHTNESS"
        fi
    fi
    rm -f "$BRIGHTNESS_FILE" "$FLAG_DIMMED"
}

disable_crd_mode() {
    # Only restore brightness if CRD session is gone — the CRD host holds its
    # own NoDisplaySleepAssertion so pmset can't sleep the display while
    # connected. Keeping brightness at 0 is the only way to "darken" the screen.
    if is_crd_session_active; then
        crd_log "INFO" "CRD session still active — keeping brightness dimmed"
    else
        restore_brightness
    fi

    # Re-enable sleep via pmset
    if disablesleep_active; then
        sudo pmset -a disablesleep 0
    fi

    # Restore display sleep timeout
    if displaysleep_disabled; then
        local saved_ds
        saved_ds=$(cat "$DISPLAYSLEEP_FILE" 2>/dev/null)
        sudo pmset -a displaysleep "${saved_ds:-$DEFAULT_DISPLAYSLEEP}"
    fi
    rm -f "$DISPLAYSLEEP_FILE"

    restore_hot_corners
    rm -f "$FLAG_ACTIVE" "$FLAG_AUTO" "$FLAG_WAS_LOCKED" "$IDLE_SINCE_FILE"
}

# --- Action mode ---

case "$1" in
    enable)
        MODE_ON=false; CRD_ACTIVE=false; AUTO_MANAGED=false
        log_detection_state "MANUAL-ENABLE"
        rm -f "$FLAG_MANUAL_OFF"
        enable_crd_mode
        exit 0
        ;;
    disable)
        MODE_ON=true; CRD_ACTIVE=false; AUTO_MANAGED=false
        log_detection_state "MANUAL-DISABLE"
        touch "$FLAG_MANUAL_OFF"
        rm -f "$FLAG_LEAVE_ON"
        disable_crd_mode
        exit 0
        ;;
    leaveon-on)
        MODE_ON=false; CRD_ACTIVE=false; AUTO_MANAGED=false
        is_crd_session_active && CRD_ACTIVE=true
        log_detection_state "LEAVE-ON"
        touch "$FLAG_LEAVE_ON"
        rm -f "$FLAG_MANUAL_OFF" "$FLAG_AUTO"
        enable_crd_mode "$CRD_ACTIVE"
        exit 0
        ;;
    leaveon-off)
        MODE_ON=true; CRD_ACTIVE=false; AUTO_MANAGED=false
        is_crd_session_active && CRD_ACTIVE=true
        log_detection_state "LEAVE-OFF"
        rm -f "$FLAG_LEAVE_ON"
        if $CRD_ACTIVE; then
            # Session still up — hand back to auto so it disables when it ends
            touch "$FLAG_AUTO"
        else
            disable_crd_mode
        fi
        exit 0
        ;;
esac

# --- Auto-detection (runs every 5s) ---

CRD_ACTIVE=false
is_crd_session_active && CRD_ACTIVE=true

MODE_ON=false
[[ -f "$FLAG_ACTIVE" ]] && MODE_ON=true

AUTO_MANAGED=false
[[ -f "$FLAG_AUTO" ]] && AUTO_MANAGED=true

LEAVE_ON=false
[[ -f "$FLAG_LEAVE_ON" ]] && LEAVE_ON=true

# Clear the manual-off override once it no longer applies to the live session.
# Two timestamp-based triggers, both robust to sleep/wake (when the plugin isn't
# ticking) since /tmp flags and mtimes survive sleep:
#   1. CRD idle for 5+ minutes — the disabled session has ended.
#   2. A *new* CRD session started 5+ minutes after the manual disable. This
#      catches the case where the machine slept overnight and woke straight into
#      a fresh session: the first post-wake tick already sees CRD active, so the
#      idle timer (trigger 1) never ran. Without this, a stale manual-off blocks
#      auto-enable for the entire new session.
MANUAL_OFF_GRACE=300
if [[ -f "$FLAG_MANUAL_OFF" ]]; then
    now=$(date +%s)
    if ! $CRD_ACTIVE; then
        [[ -f "$IDLE_SINCE_FILE" ]] || echo "$now" > "$IDLE_SINCE_FILE"
        idle_since=$(cat "$IDLE_SINCE_FILE")
        if (( now - idle_since >= MANUAL_OFF_GRACE )); then
            rm -f "$FLAG_MANUAL_OFF" "$IDLE_SINCE_FILE"
        fi
    else
        rm -f "$IDLE_SINCE_FILE"
        session_age=$(crd_session_age_secs) || session_age=""
        manual_off_at=$(stat -f %m "$FLAG_MANUAL_OFF" 2>/dev/null)
        if [[ -n "$session_age" && -n "$manual_off_at" ]]; then
            session_start=$(( now - session_age ))
            if (( session_start - manual_off_at >= MANUAL_OFF_GRACE )); then
                crd_log "INFO" "Clearing stale manual-off — new CRD session started $(( session_start - manual_off_at ))s after manual disable"
                rm -f "$FLAG_MANUAL_OFF"
            fi
        fi
    fi
fi

# Restore brightness once CRD session ends (deferred from disable_crd_mode)
if ! $CRD_ACTIVE && ! $MODE_ON && [[ -f "$FLAG_DIMMED" ]]; then
    crd_log "INFO" "CRD session ended — restoring brightness"
    restore_brightness
fi

# Power-transition safeguard: when the laptop is unplugged (AC -> battery), tear
# down Leave On and any active CRD keep-awake so the battery doesn't drain. Even
# though disablesleep is never set on battery, leave-on/session mode still kills
# display sleep, disables hot corners, and jiggles the mouse — all battery drains.
# Tracked via a /tmp flag (survives sleep/wake; a missing flag on first run is
# treated as the current state, so we only act on a real plugged->unplugged edge).
POWER_STATE_FILE="/tmp/.crd-last-power-state"
ON_AC=false
is_on_ac_power && ON_AC=true
PREV_POWER=$(cat "$POWER_STATE_FILE" 2>/dev/null)
$ON_AC && echo "ac" > "$POWER_STATE_FILE" || echo "battery" > "$POWER_STATE_FILE"

if [[ "$PREV_POWER" == "ac" ]] && ! $ON_AC && { $LEAVE_ON || $MODE_ON; }; then
    log_detection_state "POWER-UNPLUGGED"
    crd_log "WARN" "Unplugged (AC -> battery) — disabling Leave On / CRD mode to protect battery"
    rm -f "$FLAG_LEAVE_ON"
    LEAVE_ON=false
    # If a remote session is still live, block auto re-enable while on battery.
    # disable_crd_mode keeps brightness dimmed when a session is active, so the
    # local screen stays dark; we just stop defeating sleep/lock.
    $CRD_ACTIVE && touch "$FLAG_MANUAL_OFF"
    disable_crd_mode
    MODE_ON=false
    AUTO_MANAGED=false
fi

# Battery guard (level-triggered): Leave On must NEVER keep the machine awake on
# battery. The plugged->unplugged edge check above fires only on the single
# transition tick, so it misses two real cases that silently drain the battery:
#   1. Leave On toggled on while already unplugged (no edge to catch).
#   2. A stale/cleared /tmp power-state flag (reboot or sleep/wake) that leaves
#      PREV_POWER != "ac", so the edge condition can never become true again.
# This runs every battery tick, so once unplugged Leave On always tears down.
if ! $ON_AC && $LEAVE_ON; then
    log_detection_state "BATTERY-LEAVEON-GUARD"
    crd_log "WARN" "On battery with Leave On active — disabling to protect battery"
    rm -f "$FLAG_LEAVE_ON"
    LEAVE_ON=false
    # If a remote session is still live, block auto re-enable while on battery
    # (disable_crd_mode keeps brightness dimmed so the remote screen stays dark).
    $CRD_ACTIVE && touch "$FLAG_MANUAL_OFF"
    disable_crd_mode
    MODE_ON=false
    AUTO_MANAGED=false
fi

if $LEAVE_ON && ! $MODE_ON; then
    log_detection_state "LEAVE-ON-ENABLE"
    enable_crd_mode "$CRD_ACTIVE"
    MODE_ON=true
elif $CRD_ACTIVE && ! $MODE_ON && ! [[ -f "$FLAG_MANUAL_OFF" ]]; then
    log_detection_state "AUTO-ENABLE"
    touch "$FLAG_AUTO"
    enable_crd_mode
    MODE_ON=true
elif ! $CRD_ACTIVE && $MODE_ON && $AUTO_MANAGED && ! $LEAVE_ON; then
    log_detection_state "AUTO-DISABLE"
    disable_crd_mode
    MODE_ON=false
else
    if $MODE_ON; then
        assert_user_active
        if is_screen_locked; then
            if [[ ! -f "$FLAG_WAS_LOCKED" ]]; then
                crd_log "ALERT" "Screen locked while CRD mode active — lock prevention failed"
                touch "$FLAG_WAS_LOCKED"
            fi
        else
            if [[ -f "$FLAG_WAS_LOCKED" ]]; then
                crd_log "INFO" "Screen unlocked — lock cleared"
                rm -f "$FLAG_WAS_LOCKED"
            fi
        fi
    fi
fi

# Lid-closed safeguard (battery only): a closed lid on battery with no active
# session and Leave On off means the laptop is in a bag — force a full teardown
# so it can sleep and the battery doesn't drain. This is gated on !ON_AC on
# purpose: a closed lid on AC power is clamshell-on-desk (external display), the
# canonical reason to *manually* force CRD mode on to keep the machine awake and
# reachable. Tearing that down would make the "Enable CRD Mode" pulldown appear
# to do nothing — it would flip back off within one tick. A manual force-on and
# a stale FLAG_ACTIVE (FLAG_AUTO cleared by sleep/wake) both look auto=false, so
# we can't distinguish them; battery state is the reliable "in a bag" signal.
if $MODE_ON && ! $CRD_ACTIVE && ! $LEAVE_ON && ! $ON_AC && is_lid_closed; then
    crd_log "WARN" "Lid closed on battery with no session and Leave On off — disabling CRD mode to allow sleep"
    disable_crd_mode
    MODE_ON=false
fi

# Leave-on: dim only while a session is actually active; otherwise keep the
# local screen visible (the whole point of "leave on" is to not go dark).
if $LEAVE_ON && $MODE_ON; then
    if $CRD_ACTIVE && [[ ! -f "$FLAG_DIMMED" ]]; then
        crd_log "INFO" "Leave-on: session started — dimming"
        dim_screen
    elif ! $CRD_ACTIVE && [[ -f "$FLAG_DIMMED" ]]; then
        crd_log "INFO" "Leave-on: session ended — restoring brightness"
        restore_brightness
    fi
fi

# Refresh state after potential auto-changes
[[ -f "$FLAG_ACTIVE" ]] && MODE_ON=true || MODE_ON=false

# Stale-state cleanup: if mode is off and CRD is idle, but pmset still has
# leftover values (e.g. /tmp flags cleared on sleep/wake), reset them.
if ! $MODE_ON && ! $CRD_ACTIVE; then
    if disablesleep_active; then
        crd_log "WARN" "Stale disablesleep=1 detected while idle — resetting"
        sudo pmset -a disablesleep 0
    fi
    if displaysleep_disabled; then
        crd_log "WARN" "Stale displaysleep=0 detected while idle — restoring default"
        saved_ds=$(cat "$DISPLAYSLEEP_FILE" 2>/dev/null)
        sudo pmset -a displaysleep "${saved_ds:-$DEFAULT_DISPLAYSLEEP}"
        rm -f "$DISPLAYSLEEP_FILE"
    fi
    if [[ -f "$HOTCORNERS_FILE" ]]; then
        crd_log "WARN" "Stale hot corner overrides detected while idle — restoring"
        restore_hot_corners
    fi
    rm -f "$IDLE_SINCE_FILE"
fi

# --- Menu bar title ---

if $LEAVE_ON; then
    # Leave-on (always awake) — pin icon to distinguish from session-driven modes
    echo " | sfimage=pin.fill"
elif $MODE_ON && ! $AUTO_MANAGED; then
    # Manually forced on — click icon to distinguish from auto
    echo " | sfimage=cursorarrow.click"
elif $MODE_ON && $CRD_ACTIVE; then
    echo " | sfimage=cursorarrow.rays"
elif $MODE_ON; then
    echo " | sfimage=cursorarrow"
else
    echo " | sfimage=cursorarrow"
fi

echo "---"

# Toggle action
if $MODE_ON; then
    echo "Disable CRD Mode | bash=\"$SCRIPT\" param1=disable terminal=false refresh=true color=primary"
else
    echo "Enable CRD Mode | bash=\"$SCRIPT\" param1=enable terminal=false refresh=true color=primary"
fi

# Leave-on toggle: keep system/display awake even with no CRD session
if $LEAVE_ON; then
    echo "✓ Leave On (always awake) | bash=\"$SCRIPT\" param1=leaveon-off terminal=false refresh=true color=primary"
else
    echo "Leave On (always awake) | bash=\"$SCRIPT\" param1=leaveon-on terminal=false refresh=true color=primary"
fi

echo "---"

# Status info
if $CRD_ACTIVE; then
    echo "Session: Active | color=primary bash=true terminal=false"
else
    echo "Session: Idle | color=primary bash=true terminal=false"
fi

if $LEAVE_ON; then
    echo "Mode: Leave on (always awake) | color=primary bash=true terminal=false"
fi

if disablesleep_active; then
    echo "System sleep: disabled | color=primary bash=true terminal=false"
else
    echo "System sleep: normal | color=primary bash=true terminal=false"
fi

if displaysleep_disabled; then
    echo "Display sleep: disabled | color=primary bash=true terminal=false"
else
    ds_val=$(pmset -g 2>/dev/null | awk '/displaysleep/{print $2; exit}')
    echo "Display sleep: ${ds_val}min | color=primary bash=true terminal=false"
fi

if $MODE_ON; then
    if is_screen_locked; then
        echo "Screen lock: LOCKED | color=red bash=true terminal=false"
    else
        echo "Screen lock: suppressed | color=primary bash=true terminal=false"
    fi
    if [[ -f "$HOTCORNERS_FILE" ]]; then
        echo "Hot corners: disabled | color=primary bash=true terminal=false"
    fi
fi

if brightness_available; then
    if [[ -f "$FLAG_DIMMED" ]]; then
        echo "Brightness: dimmed | color=primary bash=true terminal=false"
    elif $MODE_ON; then
        echo "Brightness: control unavailable | color=primary bash=true terminal=false"
    fi
else
    echo "---"
    echo "⚠ brightness control unavailable | color=primary bash=true terminal=false"
fi
