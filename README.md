# SwiftBar Scripts

A collection of useful SwiftBar/xbar plugins for macOS.

## Active Plugins

### 1. Free Memory (`memory.15s.sh`)
- **Description**: Displays the amount of free physical memory in your menu bar.
- **Features**:
  - Automatically switches between GB and MB units.
  - Color-coded text based on memory pressure (White = Normal, Yellow = Warning, Red = High Pressure).
  - Quick link to open Activity Monitor from the dropdown.

### 2. ping (`ping.10s.sh`)
- **Description**: Monitors network latency by pinging reliable DNS servers (Google 8.8.8.8 and Cloudflare 1.1.1.1).
- **Features**:
  - Displays average latency and standard deviation (±) in the menu bar.
  - Color-coded based on speed (Green = Fast, Yellow = Moderate, Red = Slow).
  - Detailed breakdown for each site in the dropdown.

### 3. Chrome Remote Desktop Mode (`crd.5s.sh`)
- **Description**: An automation script that detects active Chrome Remote Desktop sessions.
- **Features**:
  - Automatically dims the screen to 0 brightness when a remote session is established.
  - Enables `caffeinate` to prevent the machine from sleeping during remote use.
  - Restores original brightness and disables caffeinate when the session ends.
  - Manual toggle available via the menu bar.

### 4. CPU Usage Graph (`mtop.10s.sh`)
- **Description**: A visual CPU monitor inspired by the `top` command.
- **Features**:
  - Renders a real-time 25x16 mini bar graph of CPU utilization.
  - Shows current top CPU-consuming process and its percentage in the menu bar.
  - Dropdown displays load averages and the top 5 CPU hogs.

## Installation

1. Install [SwiftBar](https://swiftbar.app/).
2. Point SwiftBar to this directory in its preferences.
3. Ensure the scripts are executable: `chmod +x *.sh`.
