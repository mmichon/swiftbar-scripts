#!/bin/bash

# <xbar.title>Free Memory</xbar.title>
# <xbar.version>1.4</xbar.version>
# <xbar.author>Gemini</xbar.author>
# <xbar.author.github>gemini</xbar.author.github>
# <xbar.desc>Shows the amount of free physical memory with conditional formatting and coloring using vm_stat.</xbar.desc>
# <xbar.image>https://i.imgur.com/example.png</xbar.image>
# <xbar.dependencies>bash, vm_stat, awk, sed, bc</xbar.dependencies>
# <xbar.abouturl>https://github.com/matryer/xbar</xbar.abouturl>

# Get memory statistics from vm_stat
vm_stat_output=$(vm_stat)

# Extract relevant page counts
pages_free=$(echo "$vm_stat_output" | awk '/Pages free:/ {print $3}' | sed 's/\.//')
pages_inactive=$(echo "$vm_stat_output" | awk '/Pages inactive:/ {print $3}' | sed 's/\.//')
pages_speculative=$(echo "$vm_stat_output" | awk '/Pages speculative:/ {print $3}' | sed 's/\.//')

# Page size on macOS is 4096 bytes (4KB)
page_size=4096

# Calculate total free memory in bytes
# Using bc for arithmetic as shell arithmetic doesn't handle large numbers well
total_free_pages=$(echo "$pages_free + $pages_inactive + $pages_speculative" | bc)
free_mem_bytes=$(echo "$total_free_pages * $page_size" | bc)

# Convert to MB and GB for comparison and display
free_mem_mb=$(echo "scale=0; $free_mem_bytes / (1024 * 1024)" | bc)
free_mem_gb=$(echo "scale=2; $free_mem_bytes / (1024 * 1024 * 1024)" | bc)

output_text=""
output_color=""

# Conditional formatting for memory units
if (( $(echo "$free_mem_gb >= .5" | bc -l) )); then
    # If >= 1GB, show as X.YGB (e.g., 1.5GB)
    output_text=$(printf "%.1fGB" "$free_mem_gb")
else
    # If < 1GB, show as XMB (e.g., 500MB)
    output_text="${free_mem_mb}MB"
fi

# Conditional coloring based on free memory amount
if (( $(echo "$free_mem_mb < 500" | bc -l) )); then
    output_color="#FF0000" # Red
elif (( $(echo "$free_mem_mb < 1024" | bc -l) )); then # 1GB = 1024MB
    output_color="#FFA500" # Orange
else
    output_color="#FFFFFF" # White
fi

# Construct the final output string for BitBar
if [ -n "$output_color" ]; then
    echo "$output_text | font=Monaco size=12 color=$output_color"
else
    echo "$output_text | font=Monaco size=12"
fi