#!/bin/bash

# <xbar.title>Background Sounds</xbar.title>
# <xbar.version>1.6</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Toggle macOS Background Sounds.</xbar.desc>

# Action handler
if [ "$1" = "on" ]; then
    /usr/bin/shortcuts run "Background sounds On" > /dev/null 2>&1
    exit
elif [ "$1" = "off" ]; then
    /usr/bin/shortcuts run "Background sounds Off" > /dev/null 2>&1
    exit
fi

# State detection
IS_ON=0
SOUND_NAME=""
HEARD_PID=$(/usr/bin/pgrep -x heard)

if [ -n "$HEARD_PID" ]; then
    # Optimized check: search only for files ending in .m4a opened by 'heard'
    SOUND_FILE=$(/usr/sbin/lsof -p "$HEARD_PID" -Fn 2>/dev/null | /usr/bin/grep "\.m4a$" | /usr/bin/awk -F/ '{print $NF}' | /usr/bin/sed 's/\.m4a//' | /usr/bin/head -n 1)
    if [ -n "$SOUND_FILE" ]; then
        IS_ON=1
        SOUND_NAME="$SOUND_FILE"
    fi
fi

# Output
# Using 'template=true' ensures the SF Symbol adapts to the menu bar's color/theme.
if [ "$IS_ON" -eq 1 ]; then
    echo " | sfimage=speaker.wave.3.fill template=true"
    echo "---"
    echo "Status: Playing ($SOUND_NAME)"
    echo "Turn Off | bash=\"$0\" param1=off terminal=false refresh=true"
else
    echo " | sfimage=speaker.slash.fill template=true"
    echo "---"
    echo "Status: Off"
    echo "Turn On | bash=\"$0\" param1=on terminal=false refresh=true"
fi

echo "---"
echo "Accessibility Settings | href='x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Audio'"
