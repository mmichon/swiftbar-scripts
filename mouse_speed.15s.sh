#!/bin/bash

# <xbar.title>Mouse Speed Switcher</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Switch between Home (1.0) and On-the-Go (3.0/Fastest) mouse tracking speeds.</xbar.desc>

# Configuration
HOME_SPEED="1.0"
OTG_SPEED="3"

# System Appearance
APPEARANCE=${OS_APPEARANCE:-${SWIFTBAR_OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")}}
if [ "$APPEARANCE" = "Dark" ]; then
    P_HEX="#ffffff"
else
    P_HEX="#000000"
fi

# Read current scaling value
MOUSE_SPEED=$(defaults read -g com.apple.mouse.scaling 2>/dev/null || echo "1.0")
TRACKPAD_SPEED=$(defaults read -g com.apple.trackpad.scaling 2>/dev/null || echo "1.0")

# Action handler
if [ "$1" = "set" ]; then
    NEW_SPEED="$2"

    # Update global domain (both mouse and trackpad for consistency)
    defaults write -g com.apple.mouse.scaling -float "$NEW_SPEED"
    defaults write -g com.apple.trackpad.scaling -float "$NEW_SPEED"

    # Update AppleMultitouchMouse if it exists
    if defaults read com.apple.AppleMultitouchMouse MouseScaling >/dev/null 2>&1; then
        defaults write com.apple.AppleMultitouchMouse MouseScaling -float "$NEW_SPEED"
    fi

    # Update driver-specific settings if they exist
    if defaults read com.apple.driver.AppleBluetoothMultitouch.mouse MouseScaling >/dev/null 2>&1; then
        defaults write com.apple.driver.AppleBluetoothMultitouch.mouse MouseScaling -float "$NEW_SPEED"
    fi

    # Flush preferences cache
    killall -u "$USER" cfprefsd

    # Trigger system to reload settings
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

    # FORCE REFRESH via System Settings UI as a fallback
    # This is backgrounded to avoid blocking the script
    (
        osascript <<EOF >/dev/null 2>&1
tell application "System Settings"
    -- Reveal the pane to trigger the OS to apply the change
    try
        reveal pane id "com.apple.Mouse-Settings.extension"
    on error
        try
            reveal pane id "com.apple.Trackpad-Settings.extension"
        end try
    end try
    delay 1
    quit
end tell
EOF
    ) &

    exit
fi

# Display current status in menu bar
# We use MOUSE_SPEED for the primary indicator
IS_HOME=$(echo "$MOUSE_SPEED <= $HOME_SPEED" | bc -l)

if [ "$IS_HOME" -eq 1 ]; then
    echo " | sfimage=computermouse"
    echo "---"
    echo "Mode: Home (M:$MOUSE_SPEED / T:$TRACKPAD_SPEED) | color=primary bash=true terminal=false"
    echo "Switch to On-the-Go (Fast: $OTG_SPEED) | bash='$0' param1=set param2=$OTG_SPEED terminal=false refresh=true color=primary"
else
    echo " | sfimage=computermouse.fill"
    echo "---"
    echo "Mode: OTG (M:$MOUSE_SPEED / T:$TRACKPAD_SPEED) | color=primary bash=true terminal=false"
    echo "Switch to Home (Speed: $HOME_SPEED) | bash='$0' param1=set param2=$HOME_SPEED terminal=false refresh=true color=primary"
fi

