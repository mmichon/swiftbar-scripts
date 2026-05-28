#!/bin/bash

# <xbar.title>Display Resolution Switcher</xbar.title>
# <xbar.version>2.0</xbar.version>
# <xbar.desc>Switch between display layout presets</xbar.desc>
# <xbar.dependencies>displayplacer</xbar.dependencies>

DISPLAYPLACER=/usr/local/bin/displayplacer
IPAD_ID="4756CB7D-982A-4E4D-AE97-3D532E60AABD"
LOG=/tmp/resolution_plugin.log
BUILTIN_CACHE=/tmp/resolution_builtin_id_cache

# System Appearance
APPEARANCE=${OS_APPEARANCE:-${SWIFTBAR_OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")}}
if [ "$APPEARANCE" = "Dark" ]; then
    P_HEX="#ffffff"
else
    P_HEX="#000000"
fi

DISPLAY_LIST=$($DISPLAYPLACER list 2>/dev/null)

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

detect_displays() {
  local list="$1"
  BUILTIN_ID=$(echo "$list" \
    | awk '/^Persistent screen id:/{id=$4} /^Type:/ && /built in/{print id; exit}')
  EXTERNAL_ID=$(echo "$list" \
    | awk '/^Persistent screen id:/{id=$4} /^Type:/ && !/built in/{print id; exit}')
  BUILTIN_LIVE=false
  [ -n "$BUILTIN_ID" ] && BUILTIN_LIVE=true
  if [ -n "$BUILTIN_ID" ]; then
    echo "$BUILTIN_ID" > "$BUILTIN_CACHE"
  elif [ -f "$BUILTIN_CACHE" ]; then
    BUILTIN_ID=$(cat "$BUILTIN_CACHE")
  fi
}

get_display_props() {
  local id="$1" list="$2"
  D_RES=$(echo "$list" | awk '/'"$id"'/{f=1} f && /^Resolution:/{print $2; exit}')
  D_HZ=$(echo "$list" | awk '/'"$id"'/{f=1} f && /^Hertz:/{print $2; exit}')
  D_DEPTH=$(echo "$list" | awk '/'"$id"'/{f=1} f && /^Color Depth:/{print $3; exit}')
  D_SCALING=$(echo "$list" | awk '/'"$id"'/{f=1} f && /^Scaling:/{print $2; exit}')
}

is_crd_mode() { [ -f /tmp/.crd-mode-active ]; }

detect_displays "$DISPLAY_LIST"
log "BUILTIN_ID=${BUILTIN_ID:-NONE} EXTERNAL_ID=${EXTERNAL_ID:-NONE}"

set_layout() {
  log "set_layout called with: $1"
  DISPLAY_LIST=$($DISPLAYPLACER list 2>/dev/null)
  detect_displays "$DISPLAY_LIST"
  log "BUILTIN_ID=${BUILTIN_ID:-NONE} EXTERNAL_ID=${EXTERNAL_ID:-NONE}"

  case "$1" in
    "external")
      if [ -z "$EXTERNAL_ID" ]; then
        log "ERROR: no external display detected"
      else
        log "setting external 2560x1440 clamshell"
        if $BUILTIN_LIVE; then
          out=$($DISPLAYPLACER \
            "id:${EXTERNAL_ID} res:2560x1440 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0" \
            "id:${BUILTIN_ID} enabled:false" 2>&1)
        else
          out=$($DISPLAYPLACER "id:${EXTERNAL_ID} res:2560x1440 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0" 2>&1)
        fi
        log "displayplacer output: $out"
      fi
      ;;
    "ipad")
      LIST=$($DISPLAYPLACER list 2>/dev/null)
      # Check if iPad is already connected as a display
      if echo "$LIST" | grep -q "$IPAD_ID"; then
        IPAD_DISPLAY_ID="$IPAD_ID"
        log "found hardcoded iPad ID: $IPAD_DISPLAY_ID"
      else
        IPAD_DISPLAY_ID=$(echo "$LIST" \
          | awk '/^Persistent screen id:/{id=$4} /^Type:/ && !/built in/{print id; exit}')
        log "hardcoded iPad ID not found; dynamic detection: ${IPAD_DISPLAY_ID:-NONE}"
      fi

      # If iPad not yet connected, trigger Sidecar via Shortcut and wait
      if [ -z "$IPAD_DISPLAY_ID" ]; then
        log "iPad not connected — triggering Sidecar via Shortcut"
        shortcuts run "Connect iPad Sidecar" 2>>"$LOG"
        sleep 3
        LIST=$($DISPLAYPLACER list 2>/dev/null)
        if echo "$LIST" | grep -q "$IPAD_ID"; then
          IPAD_DISPLAY_ID="$IPAD_ID"
        else
          IPAD_DISPLAY_ID=$(echo "$LIST" \
            | awk '/^Persistent screen id:/{id=$4} /^Type:/ && !/built in/{print id; exit}')
        fi
        log "after Sidecar trigger, iPad display ID: ${IPAD_DISPLAY_ID:-NONE}"
      fi

      IPAD_RES=$(echo "$LIST" \
        | awk '/'"${IPAD_DISPLAY_ID}"'/{found=1} found && /^Resolution:/{print $2; exit}')
      IPAD_DEPTH=$(echo "$LIST" \
        | awk '/'"${IPAD_DISPLAY_ID}"'/{found=1} found && /^Color Depth:/{print $3; exit}')
      IPAD_DEPTH="${IPAD_DEPTH:-8}"
      log "iPad display ID: ${IPAD_DISPLAY_ID:-unknown}, resolution: ${IPAD_RES:-unknown}, color_depth: ${IPAD_DEPTH}"

      if [ -n "$IPAD_DISPLAY_ID" ] && [ -n "$IPAD_RES" ]; then
        out=$($DISPLAYPLACER \
          "id:${BUILTIN_ID} res:1470x956 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" \
          "id:${IPAD_DISPLAY_ID} res:${IPAD_RES} hz:60 color_depth:${IPAD_DEPTH} enabled:true scaling:on origin:(1470,0) degree:0" 2>&1)
      else
        log "iPad still not connected after Sidecar trigger — falling back to builtin only"
        out=$($DISPLAYPLACER "id:${BUILTIN_ID} res:1470x956 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" 2>&1)
      fi
      log "displayplacer output: $out"
      ;;
    "builtin")
      log "setting builtin 1470x956 only"
      if ! $BUILTIN_LIVE; then
        log "ERROR: built-in display not in active list — lid must be open to switch to it"
      elif [ -n "$EXTERNAL_ID" ]; then
        out=$($DISPLAYPLACER \
          "id:${BUILTIN_ID} res:1470x956 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" \
          "id:${EXTERNAL_ID} enabled:false" 2>&1)
        log "displayplacer output: $out"
      else
        out=$($DISPLAYPLACER "id:${BUILTIN_ID} res:1470x956 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" 2>&1)
        log "displayplacer output: $out"
      fi
      ;;
  esac
}

if [ "$1" = "set" ]; then
  set_layout "$2"
  exit 0
fi

# Detect current mode for menu bar icon
IPAD_PRESENT=$(echo "$DISPLAY_LIST" | grep -c "$IPAD_ID")

if ! $BUILTIN_LIVE && [ -n "$EXTERNAL_ID" ]; then
  echo " | sfimage=desktopcomputer"
elif [ "$IPAD_PRESENT" -gt 0 ] && $BUILTIN_LIVE; then
  echo " | sfimage=ipad"
elif $BUILTIN_LIVE; then
  echo " | sfimage=laptopcomputer"
else
  echo " | sfimage=desktopcomputer"
fi

echo "---"

echo "🖥️  External 2560×1440 (clamshell) | bash='$0' param1=set param2=external terminal=false refresh=true color=primary"

echo "📱  iPad Extended                   | bash='$0' param1=set param2=ipad terminal=false refresh=true color=primary"

if $BUILTIN_LIVE; then
  echo "💻  Built-in 1470×956              | bash='$0' param1=set param2=builtin terminal=false refresh=true color=primary"
else
  echo "💻  Built-in 1470×956 (lid closed) | bash='$0' param1=set param2=builtin terminal=false refresh=true color=primary"
fi
