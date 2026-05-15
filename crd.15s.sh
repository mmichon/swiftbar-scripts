#!/bin/bash

# <swiftbar.title>Chrome Remote Desktop Mode</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Dims screen and enables caffeinate when a CRD session is active</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

SCRIPT="$HOME/Library/Application Support/xbar/plugins/crd.15s.sh"
FLAG_ACTIVE="/tmp/.crd-mode-active"
FLAG_AUTO="/tmp/.crd-auto-managed"
PID_FILE="/tmp/.crd-caffeinate-pid"
BRIGHTNESS_FILE="/tmp/.crd-original-brightness"
FLAG_DIMMED="/tmp/.crd-brightness-dimmed"
DEFAULT_BRIGHTNESS=0.8
LOG_FILE="$HOME/Library/Logs/crd-plugin.log"
LOG_MAX_LINES=2000

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
    local udp_count stun_established last_wake
    local crd_pid
    crd_pid=$(pgrep -x remoting_me2me_host 2>/dev/null | head -1)
    udp_count=$(lsof -a -p "$crd_pid" -i UDP 2>/dev/null | grep -c "UDP" 2>/dev/null || echo 0)
    stun_established=$(lsof -a -p "$crd_pid" -i TCP 2>/dev/null | grep -c "nat-stun-port.*ESTABLISHED" 2>/dev/null || echo 0)
    last_wake=$(pmset -g log 2>/dev/null | grep -E "^[0-9]{4}.*Wake " | tail -1 | awk '{print $1, $2}')
    if [[ -n "$last_wake" ]]; then
        wake_epoch=$(date -jf "%Y-%m-%d %H:%M:%S" "$last_wake" +%s 2>/dev/null || echo 0)
        seconds_since_wake=$(( $(date +%s) - wake_epoch ))
    else
        seconds_since_wake="?"
    fi
    crd_log "$1" "udp_count=$udp_count stun_established=$stun_established wake_ago=${seconds_since_wake}s mode_on=$MODE_ON crd_active=$CRD_ACTIVE auto=$AUTO_MANAGED"
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
    # Primary signal: an ESTABLISHED TCP connection to nat-stun-port (3478) is
    # the WebRTC STUN/TURN relay and only exists during an active session.
    # Fallback: 4+ UDP sockets (WebRTC ICE candidates) bound to the CRD process.
    # We do NOT look for wildcard (*:) UDP sockets — during a live session the
    # sockets are bound to the local LAN IP, not to *.
    local crd_pid
    crd_pid=$(pgrep -x remoting_me2me_host 2>/dev/null | head -1)
    [[ -z "$crd_pid" ]] && return 1

    # Primary: STUN/TURN relay TCP connection (only present during active WebRTC)
    lsof -a -p "$crd_pid" -i TCP 2>/dev/null | grep -q "nat-stun-port.*ESTABLISHED" && return 0

    # Fallback: 4+ UDP sockets (ICE candidates + QUIC relay)
    local udp_count
    udp_count=$(lsof -a -p "$crd_pid" -i UDP 2>/dev/null | grep -c "UDP")
    [[ "$udp_count" -ge 4 ]]
}

caffeinate_running() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

enable_crd_mode() {
    # Save and dim brightness
    if brightness_available; then
        local current
        current=$(get_brightness_value)

        if [[ -n "$current" ]]; then
            echo "$current" > "$BRIGHTNESS_FILE"
        else
            echo "$DEFAULT_BRIGHTNESS" > "$BRIGHTNESS_FILE"
        fi

        set_brightness_value 0
        touch "$FLAG_DIMMED"
    fi

    # Start caffeinate -d if not already running
    if ! caffeinate_running; then
        caffeinate -d &
        echo $! > "$PID_FILE"
    fi

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

    # Kill caffeinate
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    rm -f "$PID_FILE"

    rm -f "$FLAG_ACTIVE" "$FLAG_AUTO"
}

# --- Action mode ---

case "$1" in
    enable)
        MODE_ON=false; CRD_ACTIVE=false; AUTO_MANAGED=false
        log_detection_state "MANUAL-ENABLE"
        enable_crd_mode
        exit 0
        ;;
    disable)
        MODE_ON=true; CRD_ACTIVE=false; AUTO_MANAGED=false
        log_detection_state "MANUAL-DISABLE"
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

if $CRD_ACTIVE && ! $MODE_ON; then
    log_detection_state "AUTO-ENABLE"
    touch "$FLAG_AUTO"
    enable_crd_mode
    MODE_ON=true
elif ! $CRD_ACTIVE && $MODE_ON && $AUTO_MANAGED; then
    log_detection_state "AUTO-DISABLE"
    disable_crd_mode
    MODE_ON=false
else
    # Log every tick while mode is on, or whenever CRD_ACTIVE fires, to capture
    # the full socket picture around false positives.
    if $MODE_ON || $CRD_ACTIVE; then
        log_detection_state "TICK"
    fi
fi

# Refresh state after potential auto-changes
[[ -f "$FLAG_ACTIVE" ]] && MODE_ON=true || MODE_ON=false

# --- Menu bar title ---

if $MODE_ON && $CRD_ACTIVE; then
    echo "| sfimage=cursorarrow.rays color=#FF6600"
elif $MODE_ON; then
    echo "| sfimage=cursorarrow color=#888888"
else
    echo "| sfimage=cursorarrow color=#444444"
fi

echo "---"

# Toggle action
if $MODE_ON; then
    echo "Disable CRD Mode | bash=\"$SCRIPT\" param1=disable terminal=false refresh=true"
else
    echo "Enable CRD Mode | bash=\"$SCRIPT\" param1=enable terminal=false refresh=true"
fi

echo "---"

# Status info
if $CRD_ACTIVE; then
    echo "Session: Active | color=#FF6600"
else
    echo "Session: Idle | color=#888888"
fi

if caffeinate_running; then
    caff_pid=$(cat "$PID_FILE" 2>/dev/null)
    echo "Caffeinate: running (PID $caff_pid) | color=#00CC00"
else
    echo "Caffeinate: off | color=#888888"
fi

if brightness_available; then
    if [[ -f "$FLAG_DIMMED" ]]; then
        echo "Brightness: dimmed | color=#00CC00"
    elif $MODE_ON; then
        echo "Brightness: control unavailable | color=#888888"
    fi
else
    echo "---"
    echo "⚠ brightness control unavailable | color=#FF0000"
fi
