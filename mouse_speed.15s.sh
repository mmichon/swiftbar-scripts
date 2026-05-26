#!/bin/bash

# <xbar.title>Mouse Speed Switcher</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Switch between Home (1.0) and On-the-Go (3.0/Fastest) mouse tracking speeds.</xbar.desc>

# Configuration
HOME_SPEED="1"
OTG_SPEED="3"

# Read current scaling value
CURRENT_SPEED=$(defaults read -g com.apple.mouse.scaling 2>/dev/null || echo "1")

# Action handler
if [ "$1" = "set" ]; then
    NEW_SPEED="$2"
    
    # Update global domain
    defaults write -g com.apple.mouse.scaling "$NEW_SPEED"
    
    # Update AppleMultitouchMouse if it exists
    if defaults read com.apple.AppleMultitouchMouse MouseScaling >/dev/null 2>&1; then
        defaults write com.apple.AppleMultitouchMouse MouseScaling "$NEW_SPEED"
    fi
    
    # Update driver-specific settings if they exist
    if defaults read com.apple.driver.AppleBluetoothMultitouch.mouse MouseScaling >/dev/null 2>&1; then
        defaults write com.apple.driver.AppleBluetoothMultitouch.mouse MouseScaling "$NEW_SPEED"
    fi

    # Flush preferences cache
    killall -u "$USER" cfprefsd
    
    # FORCE REFRESH via System Settings UI
    # This simulates opening the Mouse pane which triggers the OS to apply the 'defaults' change to the hardware.
    osascript <<'EOF' >/dev/null 2>&1
tell application "System Settings"
    activate
    -- Try to reveal the Mouse pane
    try
        reveal pane id "com.apple.Mouse-Settings.extension"
    on error
        -- Fallback: try to find it in the list if ID fails
        reveal pane id "com.apple.Trackpad-Settings.extension"
        delay 0.5
        tell application "System Events" to tell process "System Settings"
            click menu item "Mouse" of menu 1 of menu bar item "View" of menu bar 1
        end tell
    end try
    delay 1
    quit
end tell
EOF
    exit
fi

# Display current status in menu bar
IS_HOME=$(echo "$CURRENT_SPEED <= $HOME_SPEED" | bc -l)

if [ "$IS_HOME" -eq 1 ]; then
    echo "🖱️"
    echo "---"
    echo "Mode: Home ($CURRENT_SPEED)"
    echo "Switch to On-the-Go (Fastest: $OTG_SPEED) | bash='$0' param1=set param2=$OTG_SPEED terminal=false refresh=true"
else
    echo "🐁"
    echo "---"
    echo "Mode: OTG ($CURRENT_SPEED)"
    echo "Switch to Home (Speed: $HOME_SPEED) | bash='$0' param1=set param2=$HOME_SPEED terminal=false refresh=true"
fi
