#!/bin/bash

# <xbar.title>Display Resolution Switcher</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.desc>Switch between display resolution presets</xbar.desc>
# <xbar.dependencies>displayplacer</xbar.dependencies>

DISPLAYPLACER=/usr/local/bin/displayplacer
BUILTIN_ID="37D8832A-2D66-02CA-B9F7-8F30A301B230"
LOG=/tmp/resolution_plugin.log

# Dynamically find the external display ID (first non-builtin screen)
EXTERNAL_ID=$($DISPLAYPLACER list 2>/dev/null \
  | awk '/^Persistent screen id:/{id=$4} /^Type:/ && !/built in/{print id; exit}')

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

log "EXTERNAL_ID resolved to: ${EXTERNAL_ID:-NONE}"

builtin_active() {
  local result
  result=$($DISPLAYPLACER list 2>/dev/null | awk '/'"${BUILTIN_ID}"'/{found=1} found && /^Enabled:/{print $2; exit}')
  log "builtin_active: Enabled field = '$result'"
  [ "$result" = "true" ]
}

set_resolution() {
  log "set_resolution called with: $1"
  log "displayplacer list output:"
  $DISPLAYPLACER list >> "$LOG" 2>&1

  case "$1" in
    "2560x1440")
      if builtin_active; then
        log "builtin active — using mirror mode (LG source)"
        out=$($DISPLAYPLACER "id:${EXTERNAL_ID}+${BUILTIN_ID} res:2560x1440 hz:60 color_depth:8 scaling:on origin:(0,0)" 2>&1)
      else
        log "clamshell — setting external only"
        out=$($DISPLAYPLACER "id:${EXTERNAL_ID} res:2560x1440 hz:60 color_depth:8 scaling:on origin:(0,0)" 2>&1)
      fi
      log "displayplacer output: $out"
      ;;
    "1470x956")
      if builtin_active; then
        log "builtin active — using mirror mode (built-in source)"
        out=$($DISPLAYPLACER "id:${BUILTIN_ID}+${EXTERNAL_ID} res:1470x956 hz:60 color_depth:8 scaling:on origin:(0,0)" 2>&1)
      else
        log "clamshell — setting external only"
        out=$($DISPLAYPLACER "id:${EXTERNAL_ID} res:1470x956 hz:60 color_depth:8 scaling:on origin:(0,0)" 2>&1)
      fi
      log "displayplacer output: $out"
      ;;
  esac
}

if [ "$1" = "set" ]; then
  set_resolution "$2"
  exit 0
fi

# Get current resolution — prefer external in clamshell, built-in otherwise
CURRENT_RES=$($DISPLAYPLACER list 2>/dev/null \
  | awk '/'"${BUILTIN_ID}"'/{found=1} found && /^Resolution:/{print $2; exit}')
if [ -z "$CURRENT_RES" ]; then
  CURRENT_RES=$($DISPLAYPLACER list 2>/dev/null \
    | awk '/'"${EXTERNAL_ID}"'/{found=1} found && /^Resolution:/{print $2; exit}')
fi

case "$CURRENT_RES" in
  2560x1440) ICON="🖥️" ;;
  1470x956)  ICON="💻" ;;
  *)         ICON="🖥️" ;;
esac

echo "$ICON"
echo "---"
echo "🖥️  2560x1440 | bash='$0' param1=set param2=2560x1440 terminal=false refresh=true"
echo "💻  1470x956  | bash='$0' param1=set param2=1470x956 terminal=false refresh=true"
