#!/bin/bash

# <swiftbar.title>Chrome Remote Desktop Mode</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Dims screen, disables sleep, and prevents lock screen when a CRD session is active</swiftbar.desc>
# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>

SCRIPT="$HOME/Library/Application Support/xbar/plugins/crd.15s.sh"
FLAG_ACTIVE="/tmp/.crd-mode-active"
FLAG_AUTO="/tmp/.crd-auto-managed"
FLAG_MANUAL_OFF="/tmp/.crd-manual-off"
DISPLAYSLEEP_FILE="/tmp/.crd-original-displaysleep"
DEFAULT_DISPLAYSLEEP=5
BRIGHTNESS_FILE="/tmp/.crd-original-brightness"
FLAG_DIMMED="/tmp/.crd-brightness-dimmed"
DEFAULT_BRIGHTNESS=0.8
HOTCORNERS_FILE="/tmp/.crd-original-hotcorners"
FLAG_WAS_LOCKED="/tmp/.crd-was-locked"
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
    crd_log "$1" "crd_assertion=$has_assertion mode_on=$MODE_ON crd_active=$CRD_ACTIVE auto=$AUTO_MANAGED locked=$screen_locked"
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

enable_crd_mode() {
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

disable_crd_mode() {
    # Restore brightness
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
    rm -f "$FLAG_ACTIVE" "$FLAG_AUTO" "$FLAG_WAS_LOCKED"
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
        disable_crd_mode
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

# Clear manual-off override once the session actually ends
if ! $CRD_ACTIVE; then
    rm -f "$FLAG_MANUAL_OFF"
fi

if $CRD_ACTIVE && ! $MODE_ON && ! [[ -f "$FLAG_MANUAL_OFF" ]]; then
    log_detection_state "AUTO-ENABLE"
    touch "$FLAG_AUTO"
    enable_crd_mode
    MODE_ON=true
elif ! $CRD_ACTIVE && $MODE_ON && $AUTO_MANAGED; then
    log_detection_state "AUTO-DISABLE"
    disable_crd_mode
    MODE_ON=false
else
    if $MODE_ON || $CRD_ACTIVE; then
        log_detection_state "TICK"
    fi
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
fi

# --- Menu bar title ---

if $MODE_ON && ! $AUTO_MANAGED; then
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

echo "---"

# Status info
if $CRD_ACTIVE; then
    echo "Session: Active | color=primary bash=true terminal=false"
else
    echo "Session: Idle | color=primary bash=true terminal=false"
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
