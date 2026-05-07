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
BRIGHTNESS_BIN="/usr/local/bin/brightness"

# --- Helpers ---

brightness_available() {
    [[ -x "$BRIGHTNESS_BIN" ]]
}

is_crd_session_active() {
    # CRD runs as root; pgrep/lsof can't inspect it without hanging.
    # netstat -anv shows process names in its output and is fast (~25ms).
    netstat -anv tcp 2>/dev/null | grep -i "remoting_me2me_h" | grep -q "ESTABLISHED"
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
        current=$("$BRIGHTNESS_BIN" -l 2>/dev/null | grep -oE 'brightness [0-9.]+' | grep -oE '[0-9.]+' | head -1)
        [[ -n "$current" ]] && echo "$current" > "$BRIGHTNESS_FILE"
        # brightness exits 0 even on failure; only mark dimmed if we could read current value
        if [[ -n "$current" ]]; then
            "$BRIGHTNESS_BIN" 0 2>/dev/null
            touch "$FLAG_DIMMED"
        fi
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
            "$BRIGHTNESS_BIN" "$saved" 2>/dev/null
        else
            "$BRIGHTNESS_BIN" 1 2>/dev/null
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
    echo "| sfimage=rectangle.on.rectangle.fill color=#FF6600"
elif $MODE_ON; then
    echo "| sfimage=rectangle.on.rectangle color=#888888"
else
    echo "| sfimage=rectangle.on.rectangle color=#444444"
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
    echo "⚠ brightness not found | color=#FF0000"
    echo "Install: brew install brightness | color=#888888"
fi
