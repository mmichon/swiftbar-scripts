#!/usr/bin/env bash

# <bitbar.title>CPU Usage Graph</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>Ganesh V</bitbar.author>
# <bitbar.author.github>ganeshv</bitbar.author.github>
# <bitbar.desc>CPU usage bar graph</bitbar.desc>
# <bitbar.image>https://raw.github.com/ganeshv/mtop/master/screenshots/mtop2.png</bitbar.image>
# <bitbar.about>https://github.com/ganeshv/mtop</bitbar.about>

# CPU utilization bar graph is rendered onto a 25x16 BMP file created from
# scratch with no external dependencies. The dropdown contains current usage,
# load average and the top 5 CPU-hogs as reported by `top`.
#
# Tested on Mountain Lion through El Capitan. Works with Dark Mode (though
# you have to restart Bitbar if you change mode).
#
# Mountain Lion does not interpret the BITMAPV5HEADER variant of the BMP
# format, which has alpha channel support. We fall back to a basic version
# (BITMAPINFOHEADER).
#
# Bash builtins are used as much as possible to reduce performance impact.

# Converts #RRGGBBAA to BB GG RR AA
hex_to_bgra() {
    local hex_color=$1
    local r=${hex_color:1:2}
    local g=${hex_color:3:2}
    local b=${hex_color:5:2}
    local a=${hex_color:7:2}
    if [ -z "$a" ]; then
        a="ff" # Default to full opacity if alpha is not provided
    fi
    echo "$b $g $r $a"
}



if [ "$1" = 'activity_monitor' ]; then
    osascript << END
    tell application "Activity Monitor"
        reopen
        activate
    end tell
END
    exit 0
fi

HISTORY_FILE=$HOME/.bitbar.mtop
[ ! -r "$HISTORY_FILE" ] && touch "$HISTORY_FILE"
[ X"$(find "$HISTORY_FILE" -mtime -2m)" != X"$HISTORY_FILE" ] && echo -n >"$HISTORY_FILE" # Discard history if older than 2 minutes

OLDIFS=$IFS
width=25
height=16

osver=$(sw_vers -productVersion)

# Colors in BGRA format
FG_HEX_COLOR="#000000FF" # Black with full opacity
BG_HEX_COLOR="#00000000" # Transparent black

fgcol=$(hex_to_bgra "$FG_HEX_COLOR")
bgcol=$(hex_to_bgra "$BG_HEX_COLOR")
bmp_ver=5
icontype=templateImage

if [[ $osver == 10.8.* ]]; then
    bmp_ver=1
    BG_HEX_COLOR_OS8="#d0d0d07f" # Light gray with partial opacity for OS 10.8
    bgcol=$(hex_to_bgra "$BG_HEX_COLOR_OS8")
    icontype=image
fi

border=$fgcol
foreground=$fgcol
background=$bgcol
border_height=3

RED_BLACK_THEME=("#7d00ff" "#ff0000" "#d10000" "#940000" "#5a0000" "#000000")
MIKE_THEME=("#ff0000" "#ca3b00" "#a56400" "#777800" "#49b601" "#13bf00")
ORIGINAL_THEME=("#acacac" "#ff0101" "#cc673b" "#ce8458" "#6bbb15" "#0ed812")
COLORS=(${RED_BLACK_THEME[@]})

function colorize {
  if [ "$1" -ge 90 ]; then
    echo "${COLORS[0]}"
  elif [ "$1" -ge 80 ]; then
    echo "${COLORS[1]}"
  elif [ "$1" -ge 60 ]; then
    echo "${COLORS[2]}"
  elif [ "$1" -ge 40 ]; then
    echo "${COLORS[3]}"
  elif [ "$1" -ge 20 ]; then
    echo "${COLORS[4]}"
  else
    echo "${COLORS[5]}"
  fi
}

# Takes number, prints hex bytes in little endian
# e.g. hexle32 3142 will output 46 0c 00 00
hexle32() {
    printf -v _num "%08x" "$1"
    echo "${_num:6:2}" "${_num:4:2}" "${_num:2:2}" "${_num:0:2}"
}

# make_bmp_header version
# version can be 1 or 5
# v1 is the most compatible, but the graph will be opaque - no alpha support.
# v5 supports alpha channel.
make_bmp_header() {
    headertype=$1
    headerbytes=40
    comp="00"
    if [ "$headertype" -eq 5 ]; then
        headerbytes=124
        comp="03"
    fi
    pixoffset=$((headerbytes + 14))
    pixbytes=$((width * height * 4))
    filebytes=$((pixbytes + pixoffset))
        
    # Common bits for version 1 and 5
    bmp+=(
        42 4d                   # "BM" magic
        $(hexle32 $filebytes)   # size of file
        00 00                   # reserved
        00 00                   # reserved
        $(hexle32 $pixoffset)   # offset of pixel data
        $(hexle32 $headerbytes) # remaining bytes in header
        $(hexle32 $width)       # width
        $(hexle32 $height)      # height
        01 00                   # 1 color plane
        20 00                   # 32 bits per pixel
        $comp 00 00 00          # Compression
        $(hexle32 $pixbytes)    # size of pixel data
        13 0b 00 00             # ~72 dpi horizontal
        13 0b 00 00             # ~72 dpi vertical
        00 00 00 00             # colors in palette
        00 00 00 00             # all colors are important
    )
    if [ "$headertype" -eq 5 ]; then
        bmp+=(
            00 00 ff 00             # red channel mask (BGRA)
            00 ff 00 00             # green channel mask
            ff 00 00 00             # blue channel mask
            00 00 00 ff             # alpha channel mask
            42 47 52 73             # sRGB
            00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
            00 00 00 00             # red gamma
            00 00 00 00             # green gamma
            00 00 00 00             # blue gamma
            00 00 00 00             # intent
            00 00 00 00             # profile data
            00 00 00 00             # profile size
            00 00 00 00             # reserved
        )
    fi
}


# add_row thickness "b g r a"
add_row() {
    thickness=$1
    for ((i = 0; i < thickness; i++)); do
        for ((j = 0; j < width; j++)); do
            bmp+=($2)
        done
    done
}

# add_pixel "b g r a"
add_pixel() {
    bmp+=($1)
}

output_bmp() {
    bmp=(${bmp[@]/#/
})
    local IFS=''
    #echo -ne "${bmp[*]}" >/tmp/mtop.bmp
    echo -ne "${bmp[*]}"
}

get_cpu_stats() {
    local IFS=$'\n'
    topdata=($(top -F -R -l2 -o cpu -n 5 -s 2 -stats pid,command,cpu))
    
    nlines=${#topdata[@]}
    histdata=($(tail -$((width - 1)) "$HISTORY_FILE"))

    IFS=$OLDIFS
    for ((i = nlines / 2; i < nlines; i++)); do
        line=(${topdata[$i]})
        word=${line[0]}
        if [ "$word" = Load ]; then
            loadstr=${topdata[$i]}
        elif [ "$word" = CPU ]; then
            cpustr=${line[*]}
            histdata+=("${line[2]/'%'} ${line[4]/'%'} ${line[6]/'%'}")
            idle_cpu=$(printf "%.0f" ${line[6]/\%*})

        elif [ "$word" = PID ]; then
            top5=("${topdata[@]:$i}")
            top_proc_line=${top5[1]}
            top_proc_cpu=$(echo "$top_proc_line" | awk '{print $NF}')
            top_proc=$(echo "$top_proc_line" | awk '{$1=""; $NF=""; print $0}' | xargs)
        fi
    done

    IFS=$'\n'
    echo "${histdata[*]}" >"$HISTORY_FILE"
}

render_graph() {
    start=$((width - ${#histdata[@]}))

    heights=()
    for ((i = 0; i < ${#histdata[@]}; i++)); do
        comps=(${histdata[$i]})
        heights[$i]=$(((100 - $(printf "%.0f" "${comps[2]}")) * (height - border_height) / 100))
    done 

    for ((i = 0; i < $((height - border_height)); i++)); do
        h=0
        for ((j = 0; j < width; j++)); do
            if [ $j -lt $start ]; then
                add_pixel "$background"
            elif [ ${heights[$h]} -gt $i ]; then
                add_pixel "$foreground"
                h=$((h + 1))
            else
                add_pixel "$background"
                h=$((h + 1))
            fi
        done
    done
}

get_cpu_stats

if [[ "$top_proc" == *kernel_task* ]]; then
    second_proc_line=${top5[2]}
    second_proc_cpu=$(echo "$second_proc_line" | awk '{print $NF}')
    second_proc=$(echo "$second_proc_line" | awk '{$1=""; $NF=""; print $0}' | xargs)
    echo -n " $second_proc_cpu% ${second_proc:0:6} | font='SF Mono' size='12' color='#FF0000'"
else
    echo -n " $top_proc_cpu% ${top_proc:0:6} | font='SF Mono' size='12'"
fi

make_bmp_header $bmp_ver
add_row 2 "$border"
render_graph
add_row 1 "$border"
echo -n "| $icontype="
output_bmp | base64

echo "---"
echo "$cpstr | refresh=true"
echo "$loadstr | refresh=true"
echo "---"
IFS=''
echo "---"
echo "Open Activity Monitor | bash='$0' param1=activity_monitor terminal=false"

for line in "${top5[@]}"; do
    echo "$line | font=Menlo"
done
IFS=$OLDIFS
echo "---"
echo "Refresh... | refresh='true'"
