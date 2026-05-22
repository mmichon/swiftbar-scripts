# SwiftBar Scripts

A collection of useful SwiftBar/xbar plugins for macOS.

## Active Plugins

### 1. System Metrics (`metrics.15s.sh`)
- **Description**: A combined monitor for Memory, CPU, and Network latency.
- **Features**:
  - **Memory**: Displays free GB with color coding based on system pressure.
  - **CPU**: Shows usage percentage and thermal throttling status.
  - **Top Processes**: Automatically identifies the top non-kernel process if CPU usage exceeds 50%.
  - **Ping**: Monitors network latency (mean ± standard deviation) to 8.8.8.8 and 1.1.1.1.
  - **Compact UI**: Uses ANSI colors for per-metric status in a single line.

### 2. Chrome Remote Desktop Mode (`crd.15s.sh`)
- **Description**: Detects active Chrome Remote Desktop sessions and optimizes system state.
- **Features**:
  - Automatically dims the screen to 0 brightness when a remote session is established.
  - Enables `caffeinate` to prevent the machine from sleeping during remote use.
  - Restores original brightness and disables caffeinate when the session ends.

### 3. Display Resolution (`resolution.30s.sh`)
- **Description**: Displays the current screen resolution in the menu bar.

## Installation

1. Install [SwiftBar](https://swiftbar.app/).
2. Point SwiftBar to this directory in its preferences.
3. Ensure the scripts are executable: `chmod +x *.sh`.
