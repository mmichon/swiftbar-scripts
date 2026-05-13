#!/bin/bash

# <swiftbar.title>Chrome Remote Desktop Mode</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Dims screen and enables caffeinate when a CRD session is active</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

SCRIPT="$HOME/bitbar/crd.5s.sh"
FLAG_ACTIVE="/tmp/.crd-mode-active"
FLAG_AUTO="/tmp/.crd-auto-managed"
PID_FILE="/tmp/.crd-caffeinate-pid"
BRIGHTNESS_FILE="/tmp/.crd-original-brightness"
FLAG_DIMMED="/tmp/.crd-brightness-dimmed"
DEFAULT_BRIGHTNESS=0.8

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
    # An active CRD session opens WebRTC data channels over UDP to Google relay
    # servers. lsof shows these as connected UDP sockets with a "->remote" addr.
    # The idle daemon uses only TCP keep-alives — it has no connected UDP sockets.
    # TCP sockets linger in CLOSE_WAIT/TIME_WAIT after wake (causing false
    # positives with netstat counting), but connected UDP state clears immediately.
    timeout 2 lsof -i UDP -P -n 2>/dev/null \
        | grep -qi "remoting_.*->"
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
        enable_crd_mode
        exit 0
        ;;
    disable)
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
    touch "$FLAG_AUTO"
    enable_crd_mode
    MODE_ON=true
elif ! $CRD_ACTIVE && $MODE_ON && $AUTO_MANAGED; then
    disable_crd_mode
    MODE_ON=false
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
    echo "Disable CRD Mode | bash=$SCRIPT param1=disable terminal=false refresh=true"
else
    echo "Enable CRD Mode | bash=$SCRIPT param1=enable terminal=false refresh=true"
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
