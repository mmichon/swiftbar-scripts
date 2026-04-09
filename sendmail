#!/bin/bash

# <swiftbar.title>Sidecar Toggle</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Toggle iPad Sidecar display connection</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

LAUNCHER="$HOME/bin/SidecarLauncher"
IPAD_NAME="iPad"

# Detect if Sidecar display is currently active (connected = more than 1 display)
DISPLAY_COUNT=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:")
if [ "$DISPLAY_COUNT" -gt 1 ]; then
    CONNECTED=true
else
    CONNECTED=false
fi

# Menu bar title
if $CONNECTED; then
    echo "| sfimage=ipad color=#00CC00"
else
    echo "| sfimage=circle.slash color=#888888"
fi

echo "---"

if $CONNECTED; then
    echo "Disconnect | bash=$LAUNCHER param1=disconnect param2=\"$IPAD_NAME\" terminal=false refresh=true"
else
    echo "Connect | bash=$LAUNCHER param1=connect param2=\"$IPAD_NAME\" terminal=false refresh=true"
fi
