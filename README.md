# SwiftBar Scripts

A collection of useful SwiftBar/xbar plugins for macOS.

## Active Plugins

### 1. System Metrics (`metrics.30s.sh`)
- **Description**: A combined monitor for Memory, CPU, and Network latency.
- **Features**:
  - **Memory**: Displays free GB with color coding based on system pressure.
  - **CPU**: Shows usage percentage, temperature (°F via `smctemp`), and thermal throttling status (`pmset` + `powermetrics` signals on Apple Silicon); usage is colored when throttling.
  - **Top Processes**: Lists the top CPU consumers; automatically surfaces the top non-kernel process in the menu bar if CPU usage exceeds 50%. Click any process in the dropdown to kill it — a confirmation dialog appears, then SIGTERM is sent, escalating to SIGKILL if the process survives.
  - **Sustained CPU-hog warning**: warns proactively when a process stays hot, with no banner or popup — the CPU field in the menu bar gains a ⚠, turns red, and names the culprit (`⚠41%(WeatherMenu)`), and the dropdown promotes a one-click **Kill** row plus **Ignore for 1 hour** to the top. Two tiers, because "a lot of CPU" means different things for different apps: ≥100% sustained 3 minutes (a runaway pegging a core), or ≥50% sustained 5 minutes (a background/menu-bar app that should be idle). A single tick below the threshold resets the streak, so spikes, compiles, and page loads never warn. If a process was killed by hand within the last hour it is treated as a known repeat offender and warns after just 45s, annotated `(killed 22m ago)`; a **Recently killed** section lists those. `kernel_task`, `WindowServer`, `mds*`, `backupd`, and SwiftBar/xbar itself are never flagged. Thresholds are the `HOG_*` tunables near the top of the script. This is the only stateful part of the plugin — streaks, kill history, and cooldowns live in `$TMPDIR/xbar-metrics.$UID/`. Streaks are keyed by PID and names resolved via `ps`, since `top` truncates the command column (`com.apple.weather.menu` → `com.apple.weathe`).
  - **SwiftBar spin watchdog**: the host app is excluded from the hog check above (click-to-kill must never target the app drawing the menu), so it gets its own clock and its own remedy. Menu-bar apps can fall into a self-sustaining `_activeTrackingAreasNeedUpdate → NSCursor set` run-loop cycle and hold a full core indefinitely — SwiftBar, Apple's own weather extra, and WindowServer all at once. If SwiftBar stays ≥60% CPU for 5 minutes (and has been up 10 minutes, so a restart loop is impossible), the plugin **auto-restarts it**, at most once per hour, via a detached helper that outlives the quit; the dropdown then shows `↻ SwiftBar auto-restarted 12m ago` for the rest of the cooldown, and the restart log lives in `$TMPDIR/xbar-metrics.$UID/host_restarts`. One cool tick of grace absorbs `top`'s sampling swings without losing a long streak. The real cause is a **customized accessibility pointer**: with custom fill/outline colors there is no cached cursor, so every `NSCursor set` regenerates the bitmap through `_AXFMouseCursorGenerator` and re-registers it with SkyLight, turning an invisible cycle into a full core. Whenever `cursorIsCustomized` is set, the warning adds a row linking straight to the Pointer pane — resetting those colors is the actual fix; the restart only buys time. Tunables are the `HOST_*` group near the top of the script.
  - **Ping**: Monitors network latency (mean ± standard deviation) to 8.8.8.8 and 1.1.1.1.
  - **Compact UI**: Uses ANSI colors for per-metric status in a single line.

### 2. Chrome Remote Desktop Mode (`crd.15s.sh`)
- **Description**: Detects active Chrome Remote Desktop sessions and optimizes system state.
- **Dependencies**: Passwordless sudo for `pmset` (see Installation).
- **Features**:
  - Automatically dims the screen to 0 brightness when a remote session is established.
  - Prevents lock screen by simulating mouse movement every 5s via a compiled Swift helper (`.crd-jiggle`), resetting the HID idle timer.
  - Disables hot corners that could trigger display sleep or screen lock; restores them on disable.
  - Prevents system and display sleep via `pmset` as a safety net (AC power only).
  - **Leave On mode**: an optional persistent toggle that keeps the system and display awake even when no session is detected. Survives reboots/sleep-wake (flag stored in the plugin dir, not `/tmp`), keeps the local screen visible when idle (only dims while a session is actually active), and shows a filled-pin menu-bar icon.
  - **Battery/lid safeguards**: never keeps the machine awake on battery — unplugging (AC→battery) or running on battery tears down Leave On and session keep-awake, and a closed lid on battery with no session forces a full teardown so it can sleep in a bag. A closed lid on AC (clamshell with external display) is respected, so a manual "Enable CRD Mode" still sticks.
  - **Foreign sleep-blocker detection**: shows 😴 in the menu bar plus a `Sleep blocked by: <process>` status line when another process holds a `PreventSystemSleep`/`InternalPreventSleep` assertion. Those defeat lid-close (clamshell) sleep regardless of this plugin's `pmset` state, so the machine can stay awake in a bag even with CRD mode fully off — this makes the culprit visible at a glance instead of looking like a plugin bug.
  - Logs lock state (`locked=0/1`) on every tick and alerts on lock-during-active failures.
  - Restores original brightness, sleep settings, and hot corners when the session ends.

### 3. Display Resolution Switcher (`resolution.30s.sh`)
- **Description**: Switches between display layout presets from the menu bar.
- **Dependencies**: [displayplacer](https://github.com/jakehilborn/displayplacer)
- **Features**:
  - Preset layouts: External 2560×1440 clamshell, iPad Sidecar extended, Built-in only.
  - Dynamically detects built-in and external display IDs at runtime.
  - Automatically triggers iPad Sidecar connection via a Shortcuts shortcut if the iPad isn't already connected.
  - Menu bar icon reflects the current display mode (🖥️ / 📱 / 💻).

### 4. Mouse Speed Switcher (`mouse_speed.300s.sh`)
- **Description**: Quickly toggle between different mouse tracking speed profiles.
- **Features**:
  - **Profiles**: Supports "Home" (1.0) and "On-the-Go" (3.0/Fastest) speed settings.
  - **Instant Apply**: Uses a combination of `defaults` writes and a System Settings refresh to ensure hardware speed updates immediately.
  - **Refresh interval**: 5 minutes, not seconds. The speed only ever changes through this plugin's own click action, and that action already carries `refresh=true`, so polling faster just makes SwiftBar rebuild a status item that cannot have changed.
  - **Minimal UI**: Icon-only menu bar title — a `tortoise.fill` SF Symbol for Home, `hare.fill` for On-the-Go, both `template=true` so they invert with the menu bar in light/dark. The full `M:`/`T:` speeds are in the dropdown. If a symbol ever fails to resolve the item renders empty; swap the `sfimage` lines back to plain 🐢/🐇 emoji in that case.

### 5. Background Sounds (`bgs.5s.sh`)
- **Description**: Toggle macOS Background Sounds from the menu bar.
- **Features**:
  - Detects whether the `heard` daemon is playing by inspecting its open `.m4a` files.
  - Shows the current sound name when active.
  - On/off actions invoke the "Background sounds On" / "Background sounds Off" Shortcuts.

### 6. Desktop Space Indicator (`space.1s.sh`)
- **Description**: Shows the current macOS Desktop Space number in the menu bar, with a per-space summary of what's running in the dropdown.
- **Features**:
  - Uses private CoreGraphics APIs (`CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`, `CGSCopySpacesForWindows`) via inline Swift to identify the active space and map each window to its space.
  - Per-space summary: lists the key app(s) on each space, and for Chrome shows the active tab's page title (the "topic") — e.g. `Desktop 4 — Chrome: Travel planning`.
  - Filters out minimized/hidden windows and transient popovers/panels by requiring a real window title, so the summary matches what you actually see on each space.
  - Fully native (one window-list pass plus a per-window space lookup, a few ms) — no AppleScript, polling, or caching.
  - Chrome topics require Screen Recording permission for xbar (to read window titles); without it the summary degrades gracefully to app names only and shows an inline hint.
  - Compiles the inline Swift to a cached binary, recompiling only when the script changes (~20ms/tick vs ~750ms to JIT each tick).
  - **Self-guarding**: a single-instance lock plus a watchdog keep a stalled WindowServer call (during sleep/wake, lock, or fast user switching) from piling 1s ticks into stuck processes — new ticks skip while a run is active, and a wedged run is bounded and killed.
  - Refreshes every second for near-live tracking as you switch spaces.

## Installation

1. Install [SwiftBar](https://swiftbar.app/).
2. Point SwiftBar to this directory in its preferences.
3. Ensure the scripts are executable: `chmod +x *.sh`.
4. For the resolution switcher, install `displayplacer`: `brew install displayplacer`.
5. For the CRD plugin, grant passwordless sudo for `pmset`:
   ```
   echo "$USER ALL = (ALL) NOPASSWD:/usr/bin/pmset" | sudo tee /etc/sudoers.d/pmset
   ```
