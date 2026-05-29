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
  - Prevents system sleep via `caffeinate -s` to keep the machine awake during remote use (AC power only).
  - Restores original brightness and re-enables sleep when the session ends.

### 3. Display Resolution Switcher (`resolution.30s.sh`)
- **Description**: Switches between display layout presets from the menu bar.
- **Dependencies**: [displayplacer](https://github.com/jakehilborn/displayplacer)
- **Features**:
  - Preset layouts: External 2560×1440 clamshell, iPad Sidecar extended, Built-in only.
  - Dynamically detects built-in and external display IDs at runtime.
  - Automatically triggers iPad Sidecar connection via a Shortcuts shortcut if the iPad isn't already connected.
  - Menu bar icon reflects the current display mode (🖥️ / 📱 / 💻).

### 4. Mouse Speed Switcher (`mouse_speed.15s.sh`)
- **Description**: Quickly toggle between different mouse tracking speed profiles.
- **Features**:
  - **Profiles**: Supports "Home" (1.0) and "On-the-Go" (3.0/Fastest) speed settings.
  - **Instant Apply**: Uses a combination of `defaults` writes and a System Settings refresh to ensure hardware speed updates immediately.
  - **Minimal UI**: Uses distinct mouse emojis (🖱️ / 🐁) to indicate the active profile in the menu bar.

### 5. Background Sounds (`bgs.5s.sh`)
- **Description**: Toggle macOS Background Sounds from the menu bar.
- **Features**:
  - Detects whether the `heard` daemon is playing by inspecting its open `.m4a` files.
  - Shows the current sound name when active.
  - On/off actions invoke the "Background sounds On" / "Background sounds Off" Shortcuts.

### 6. Desktop Space Indicator (`space.1s.sh`)
- **Description**: Shows the current macOS Desktop Space number in the menu bar.
- **Features**:
  - Uses private CoreGraphics APIs (`CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`) via inline Swift to identify the active space.
  - Refreshes every second for near-live tracking as you switch spaces.

## Installation

1. Install [SwiftBar](https://swiftbar.app/).
2. Point SwiftBar to this directory in its preferences.
3. Ensure the scripts are executable: `chmod +x *.sh`.
4. For the resolution switcher, install `displayplacer`: `brew install displayplacer`.
