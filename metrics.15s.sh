#!/bin/bash

# <xbar.title>System Metrics Combined</xbar.title>
# <xbar.version>v1.3</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.desc>Combined Metrics with ANSI per-metric coloring, compact format, and fixed top processes.</xbar.desc>
# <xbar.dependencies>bash, vm_stat, top, ping, bc</xbar.dependencies>

# ANSI Color Codes
APPEARANCE=${OS_APPEARANCE:-${SWIFTBAR_OS_APPEARANCE:-$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo "Light")}}
if [ "$APPEARANCE" = "Dark" ]; then
    RED="\033[38;5;196m"    # System Red
    YELLOW="\033[38;5;226m" # System Yellow
    P_HEX="#ffffff"
    RED_HEX="#FF0000"
else
    RED="\033[38;5;160m"    # System Red (Darker)
    YELLOW="\033[38;5;172m" # System Orange/Amber (Visible)
    P_HEX="#000000"
    RED_HEX="#D70000"
fi
# Reset to SwiftBar's color=primary (adapts to light/dark) rather than hardcoded RGB
P_ANSI="\033[0m"

# --- Memory ---
# ... (rest of the logic stays same until output)
vm_stat_output=$(vm_stat)
pages_free=$(echo "$vm_stat_output" | awk '/Pages free:/ {print $3}' | sed 's/\.//')
pages_inactive=$(echo "$vm_stat_output" | awk '/Pages inactive:/ {print $3}' | sed 's/\.//')
pages_speculative=$(echo "$vm_stat_output" | awk '/Pages speculative:/ {print $3}' | sed 's/\.//')
page_size=4096
total_free_pages=$(echo "$pages_free + $pages_inactive + $pages_speculative" | bc)
free_mem_gb=$(echo "scale=1; $total_free_pages * $page_size / (1024 * 1024 * 1024)" | bc)
free_mem_gb=$(printf "%.1f" "$free_mem_gb")

pressure_level=$(sysctl -n kern.memorystatus_vm_pressure_level)
mem_ansi=""
if [ "$pressure_level" -eq 4 ]; then 
    mem_ansi=$RED
elif [ "$pressure_level" -eq 2 ]; then 
    mem_ansi=$YELLOW
fi

# --- CPU & Top Processes ---
# top -l 2 gives two samples. The second one is accurate.
top_output=$(top -l 2 -n 5 -F -R -o cpu -stats command,cpu)

# Extract CPU idle from the SECOND sample
cpu_idle=$(echo "$top_output" | awk '/CPU usage/ {idle=$7} END {print idle}' | sed 's/%//')
cpu_usage=$(echo "100 - $cpu_idle" | bc)
cpu_usage=$(printf "%.0f" "$cpu_usage")

# Extract top 5 processes from the SECOND sample
top_processes_full=$(echo "$top_output" | awk '
    /^COMMAND/ { block++; next }
    block == 2 && count < 10 {
        cpu = $NF
        $NF = ""
        sub(/[ \t]+$/, "")
        print $0 "|" cpu
        count++
    }
')

# Get top 5 for dropdown
top_processes=$(echo "$top_processes_full" | head -5 | awk -F'|' '{print $1 ": " $2 "%"}')

# Get top non-kernel process for menu bar
top_non_kernel_line=$(echo "$top_processes_full" | grep -v "kernel_task" | head -1)
top_non_kernel=$(echo "$top_non_kernel_line" | awk -F'|' '{print $1}')
top_non_kernel_cpu=$(echo "$top_non_kernel_line" | awk -F'|' '{print $2}')
top_non_kernel_cpu_int=$(printf "%.0f" "${top_non_kernel_cpu:-0}")

cpu_display="${cpu_usage}%"
if [ -n "$top_non_kernel" ] && [ "$top_non_kernel_cpu_int" -gt 50 ]; then
    cpu_display="${cpu_usage}%(${top_non_kernel})"
fi

thermal_pressure=$(notifyutil -g "com.apple.system.thermalpressure" 2>/dev/null | awk '{print $2}')
cpu_ansi=""
if [[ -n "$thermal_pressure" && "$thermal_pressure" -gt 0 ]]; then
    if [ "$thermal_pressure" -ge 2 ]; then 
        cpu_ansi=$RED
    else 
        cpu_ansi=$YELLOW
    fi
fi

# --- Ping ---
SITES=(8.8.8.8 1.1.1.1)
PING_TIMES=()
for site in "${SITES[@]}"; do
    if res=$(ping -c 1 -n -q -t 2 "$site" 2>/dev/null); then
        val=$(echo "$res" | awk -F '/' 'END {printf "%.0f\n", $5}')
        [ -n "$val" ] && PING_TIMES+=("$val")
    fi
done

ping_ansi=""
if [ ${#PING_TIMES[@]} -gt 0 ]; then
    sum=0; for t in "${PING_TIMES[@]}"; do sum=$((sum + t)); done
    mean=$((sum / ${#PING_TIMES[@]}))
    sq_sum_diff=0; for t in "${PING_TIMES[@]}"; do diff=$((t - mean)); sq_sum_diff=$((sq_sum_diff + diff * diff)); done
    sd=$(echo "sqrt($sq_sum_diff / ${#PING_TIMES[@]})" | bc)
    ping_str="${mean}±${sd}ms"
    if [ "$mean" -gt 500 ]; then 
        ping_ansi=$RED
    elif [ "$mean" -gt 150 ]; then 
        ping_ansi=$YELLOW
    fi
else
    ping_str="ERR"
    ping_ansi=$RED
fi

# --- Output ---
# Menu Bar: ANSI colors only when active, otherwise default text
# This ensures non-colored text is system-default black/white
BAR_MEM="${free_mem_gb}GB"
[ -n "$mem_ansi" ] && BAR_MEM="${mem_ansi}${BAR_MEM}${P_ANSI}"

BAR_CPU="${cpu_display}"
[ -n "$cpu_ansi" ] && BAR_CPU="${cpu_ansi}${BAR_CPU}${P_ANSI}"

BAR_PING="${ping_str}"
[ -n "$ping_ansi" ] && BAR_PING="${ping_ansi}${BAR_PING}${P_ANSI}"

echo -e "${BAR_MEM} ${BAR_CPU} ${BAR_PING} | ansi=true font='SF Mono' size=12 color=primary"
echo "---"
# Dropdown summary: Monochrome
echo "${free_mem_gb}GB ${cpu_display} ${ping_str} | font='SF Mono' size=12 color=primary bash=true terminal=false"
echo "---"
echo "Memory Free: ${free_mem_gb}GB | color=primary bash=true terminal=false"
echo "CPU Usage: ${cpu_usage}% | color=primary bash=true terminal=false"
echo "Ping (Mean±SD): ${ping_str} | color=primary bash=true terminal=false"
echo "---"
echo "Top Processes: | color=primary bash=true terminal=false"
line_num=0
while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [ "$line_num" -eq 1 ] && [[ -n "$thermal_pressure" && "$thermal_pressure" -ge 2 ]]; then
        proc_name=$(echo "$line" | sed 's/: [0-9.]*%$//')
        cpu_part=$(echo "$line" | grep -o '[0-9.]*%$')
        echo -e "${proc_name}: ${RED}${cpu_part}\033[0m | font='SF Mono' size=11 ansi=true color=primary bash=true terminal=false"
    else
        echo "$line | font='SF Mono' size=11 color=primary bash=true terminal=false"
    fi
done <<< "$top_processes"
echo "---"
echo "Refresh | refresh=true color=primary"
echo "Open Activity Monitor | bash='open' param1='-a' param2='Activity Monitor' terminal=false color=primary"
