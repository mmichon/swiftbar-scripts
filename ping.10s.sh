#!/bin/bash

# <bitbar.title>ping</bitbar.title>
# <bitbar.version>v1.1</bitbar.version>
# <bitbar.author>Trung Đinh Quang, Grant Sherrick and Kent Karlsson</bitbar.author>
# <bitbar.author.github>thealmightygrant</bitbar.author.github>
# <bitbar.desc>Sends pings to a range of sites to determine network latency</bitbar.desc>
# <bitbar.image>http://i.imgur.com/lk3iGat.png?1</bitbar.image>
# <bitbar.dependencies>ping</bitbar.dependencies>

# This is a plugin of Bitbar
# https://github.com/matryer/bitbar
# It shows current ping to some servers at the top Menubar
# This helps me to know my current connection speed
#
# Authors: (Trung Đinh Quang) trungdq88@gmail.com and (Grant Sherrick) https://github.com/thealmightygrant

# Themes copied from here: http://colorbrewer2.org/
# https://cssgradient.io/
# shellcheck disable=SC2034
# shellcheck disable=SC2034
RED_BLACK_THEME=("#7d00ff" "#ff0000" "#d10000" "#940000" "#5a0000" "#000000")
MIKE_THEME=("#ff0000" "#ca3b00" "#a56400" "#777800" "#49b601" "#13bf00")
# shellcheck disable=SC2034
ORIGINAL_THEME=("#acacac" "#ff0101" "#cc673b" "#ce8458" "#6bbb15" "#0ed812")

# Configuration
COLORS=(${RED_BLACK_THEME[@]})
MENUFONT="font='SF Mono'"
#size=10 font=UbuntuMono-Bold"
FONT="SF Mono"
MAX_PING=1000
SITES=(8.8.8.8 1.1.1.1 10.0.0.80) 
# space separated

#grab ping times for all sites
SITE_INDEX=0
PING_TIMES=

while [ $SITE_INDEX -lt ${#SITES[@]} ]; do
    NEXT_SITE="${SITES[$SITE_INDEX]}"
    if RES=$(ping -c 2 -n -q "$NEXT_SITE" 2>/dev/null); then
        NEXT_PING_TIME=$(echo "$RES" | awk -F '/' 'END {printf "%.0f\n", $5}')
    else
        NEXT_PING_TIME=$MAX_PING
    fi

    if [ -z "$PING_TIMES" ]; then
        PING_TIMES=($NEXT_PING_TIME)
    else
        PING_TIMES=(${PING_TIMES[@]} $NEXT_PING_TIME)
    fi
    SITE_INDEX=$(( SITE_INDEX + 1 ))
done

# Calculate the average ping
SITE_INDEX=0
AVG=0
while [ $SITE_INDEX -lt ${#SITES[@]} ]; do
    AVG=$(( (AVG + ${PING_TIMES[$SITE_INDEX]}) ))
    SITE_INDEX=$(( SITE_INDEX + 1 ))
done
AVG=$(( AVG / ${#SITES[@]} ))

# Calculate STD dev
SITE_INDEX=0
AVG_DEVS=0
while [ $SITE_INDEX -lt ${#SITES[@]} ]; do
    AVG_DEVS=$(( AVG_DEVS + (${PING_TIMES[$SITE_INDEX]} - AVG)**2 ))
    SITE_INDEX=$(( SITE_INDEX + 1 ))
done
AVG_DEVS=$(( AVG_DEVS / ${#SITES[@]} ))
SD=$(echo "sqrt ( $AVG_DEVS )" | bc -l | awk '{printf "%d\n", $1}')

if [ $AVG -ge $MAX_PING ]; then
  MSG=" ❌ "
else
  MSG="$AVG"'±'"${SD}ms"
fi

function colorize {
  latency=$1
  if [ "$latency" -le 15 ]; then
    echo "#FFFFFF"
  elif [ "$latency" -gt 500 ]; then
    echo "#FF0000"
  else
    if [ "$latency" -le 150 ]; then
      # 15ms to 150ms: Green to Yellow gradient
      percentage=$(awk -v lat="$latency" 'BEGIN { print (lat - 15) / 135 }')
      red=$(awk -v p="$percentage" 'BEGIN { printf "%d", p * 255 }')
      printf "#%02x%02x%02x\n" "$red" 255 0
    else
      # 150ms to 500ms: Yellow to Red gradient
      percentage=$(awk -v lat="$latency" 'BEGIN { print (lat - 150) / 350 }')
      green=$(awk -v p="$percentage" 'BEGIN { printf "%d", 255 - (p * 255) }')
      printf "#%02x%02x%02x\n" 255 "$green" 0
    fi
  fi
}

echo "$MSG | color=$(colorize $AVG) $MENUFONT"
# | color=$(colorize $AVG) $MENUFONT"
echo "---"
SITE_INDEX=0
while [ $SITE_INDEX -lt ${#SITES[@]} ]; do
    PING_TIME=${PING_TIMES[$SITE_INDEX]}
    if [ $PING_TIME -eq $MAX_PING ]; then
        PING_TIME="❌"
    else
        PING_TIME="$PING_TIME ms | color=$(colorize $PING_TIME) font='$FONT' size='12'"
# color=$(colorize $PING_TIME) $FONT size=15"
    fi

    echo "${SITES[$SITE_INDEX]}: $PING_TIME"
    SITE_INDEX=$(( SITE_INDEX + 1 ))
done

echo "---"
echo "Refresh... | refresh='true'"
