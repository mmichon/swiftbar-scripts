#!/bin/bash

# <xbar.title>Space Indicator</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>Antigravity</xbar.author>
# <xbar.desc>Displays the current macOS Desktop Space number using private APIs.</xbar.desc>

# Compile the embedded Swift source to a cached binary on first run (or when
# this script changes) and exec it. Running the precompiled binary takes ~20ms
# vs ~750ms for `swift -` to JIT the same source every tick.

set -e

CACHE_DIR="${TMPDIR:-/tmp}/xbar-space-indicator.$(id -u)"
BIN="$CACHE_DIR/space-indicator"
STAMP="$CACHE_DIR/source.stamp"
SELF="${BASH_SOURCE[0]}"
LOCK="$CACHE_DIR/run.lock"

# Runtime caps (seconds). BIN_TIMEOUT bounds a single render; LOCK_STALE is the
# backstop for reclaiming a lock whose owner died without cleaning up.
BIN_TIMEOUT=6
LOCK_STALE=12

mkdir -p "$CACHE_DIR"

# --- Single-instance guard ---------------------------------------------------
# SwiftBar fires this plugin every second. The render binary calls into
# WindowServer (CGS*/CGWindowList), which can block indefinitely during
# sleep/wake, lock, or fast user switching. Without a guard, each tick spawns
# another copy that also wedges, piling up until the machine is buried in stuck
# processes and SwiftBar stops refreshing every plugin. An atomic mkdir lock
# keeps at most one run alive: a healthy in-progress run makes new ticks skip,
# and a lock older than LOCK_STALE (owner died uncleanly) is reclaimed with any
# lingering process killed.
if ! mkdir "$LOCK" 2>/dev/null; then
    owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
    age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$LOCK_STALE" ] && [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        # A recent run still owns the lock — let it finish; skip this tick.
        exit 0
    fi
    # Stale or dead owner: kill any leftovers, then take over the lock.
    if [ -n "$owner" ]; then
        pkill -9 -P "$owner" 2>/dev/null || true
        kill -9 "$owner" 2>/dev/null || true
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT
trap 'exit 143' INT TERM

# Recompile if binary is missing or this script is newer than the stamp.
if [ ! -x "$BIN" ] || [ "$SELF" -nt "$STAMP" ]; then
    SRC="$CACHE_DIR/space-indicator.swift"
    sed -n '/^### SWIFT BEGIN$/,/^### SWIFT END$/p' "$SELF" \
        | sed '1d;$d' > "$SRC"
    /usr/bin/swiftc -O -o "$BIN.tmp" "$SRC" 2>"$CACHE_DIR/build.log" && mv "$BIN.tmp" "$BIN"
    touch "$STAMP"
fi

# Run under a watchdog so a wedged WindowServer call can't hang the tick forever.
# Output streams straight to SwiftBar; a killed run just yields one blank tick
# that the next second replaces. We can't exec here (the lock-cleanup trap must
# run), so the binary is a child whose stdout is inherited.
"$BIN" &
bin_pid=$!
( sleep "$BIN_TIMEOUT"; kill -9 "$bin_pid" 2>/dev/null ) &
wd_pid=$!
wait "$bin_pid" 2>/dev/null || true
kill "$wd_pid" 2>/dev/null || true
wait "$wd_pid" 2>/dev/null || true

# Stop before the embedded Swift source below (previously unreachable after the
# exec; now that the binary runs as a child, bash would try to run it as shell).
exit 0

### SWIFT BEGIN
import Foundation
import AppKit

// Declarations of private APIs
typealias CGSConnectionID = Int32

@_silgen_name("_CGSDefaultConnection")
func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> CFArray?

func run() {
    let conn = _CGSDefaultConnection()
    let activeSpaceId = CGSGetActiveSpace(conn)

    guard let displaySpaces = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else {
        print("? | sfimage=exclamationmark.triangle template=true")
        print("---")
        print("Error: Could not retrieve display spaces")
        return
    }

    var activeGlobalIndex: Int?
    var activeLocalIndex: Int?
    var activeDisplayIndex: Int?

    var globalUserSpaceCount = 0

    struct DisplayInfo {
        let index: Int
        let identifier: String
        var spaces: [SpaceInfo]
    }

    struct SpaceInfo {
        let id: UInt64
        let managedId: UInt64
        let uuid: String
        let type: Int
        let isCurrent: Bool
        let localUserIndex: Int?
        let globalUserIndex: Int?
    }

    var displays: [DisplayInfo] = []

    for (dIdx, displayDict) in displaySpaces.enumerated() {
        let displayID = displayDict["Display Identifier"] as? String ?? "Display \(dIdx + 1)"
        var spacesList: [SpaceInfo] = []
        var displayUserSpaceCount = 0

        if let rawSpaces = displayDict["Spaces"] as? [[String: Any]] {
            for spaceDict in rawSpaces {
                let id64 = spaceDict["id64"] as? UInt64 ?? 0
                let managedId = spaceDict["ManagedSpaceID"] as? UInt64 ?? id64
                let uuid = spaceDict["uuid"] as? String ?? ""
                let type = spaceDict["type"] as? Int ?? 0
                let isCurrent = (id64 == activeSpaceId)

                var localUserIdx: Int?
                var globalUserIdx: Int?

                if type == 0 {
                    displayUserSpaceCount += 1
                    globalUserSpaceCount += 1
                    localUserIdx = displayUserSpaceCount
                    globalUserIdx = globalUserSpaceCount

                    if isCurrent {
                        activeGlobalIndex = globalUserSpaceCount
                        activeLocalIndex = displayUserSpaceCount
                        activeDisplayIndex = dIdx
                    }
                } else {
                    if isCurrent {
                        activeDisplayIndex = dIdx
                    }
                }

                spacesList.append(SpaceInfo(
                    id: id64,
                    managedId: managedId,
                    uuid: uuid,
                    type: type,
                    isCurrent: isCurrent,
                    localUserIndex: localUserIdx,
                    globalUserIndex: globalUserIdx
                ))
            }
        }

        displays.append(DisplayInfo(index: dIdx, identifier: displayID, spaces: spacesList))
    }

    // Build a per-space summary of what's running on it by mapping every visible
    // app window to its space via CGSCopySpacesForWindows. App (owner) names are
    // always available; window titles (the Chrome page topic) require Screen
    // Recording permission — when absent, kCGWindowName is empty and we fall back
    // to app names. This is all native (a few ms), no AppleScript/polling.
    let helperOwners: Set<String> = [
        "Window Server", "loginwindow", "LaunchBar", "Spotlight",
        "Dock", "SystemUIServer", "Control Center", "Notification Center"
    ]

    struct SpaceWindows {
        var appCounts: [String: Int] = [:]
        var chromeTitles: [String] = []
        var chromeWindowCount = 0
    }
    struct Candidate {
        let owner: String
        let title: String
        let width: Double
        let height: Double
        let space: UInt64
    }

    // Collect candidate top-level windows. `.optionAll` also returns minimized,
    // hidden, popover, and menubar-extra windows — all of which get attributed to
    // a space and would pollute the summary (e.g. Calendar's tiny event popovers
    // appearing on spaces you never see it on). Real, visible top-level windows
    // are reasonably sized and, with Screen Recording granted, carry a title;
    // transient panels/popovers do not. We use that to filter below.
    var candidates: [Candidate] = []
    var titlesAvailable = false

    if let wl = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for w in wl {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  !owner.isEmpty, !owner.hasSuffix("ViewService"),
                  !helperOwners.contains(owner) else { continue }
            guard let num = w[kCGWindowNumber as String] as? Int else { continue }
            guard let spaces = CGSCopySpacesForWindows(conn, 7, [num] as CFArray) as? [UInt64],
                  let sid = spaces.first else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = b["Width"] as? Double ?? 0
            let height = b["Height"] as? Double ?? 0
            // Drop obvious non-windows (1x1 probes, 0x0 helpers, thin menubar strips).
            guard width > 100, height > 100 else { continue }
            let title = w[kCGWindowName as String] as? String ?? ""
            if !title.isEmpty { titlesAvailable = true }
            candidates.append(Candidate(owner: owner, title: title, width: width, height: height, space: sid))
        }
    }

    // When titles are available (Screen Recording on), count only titled windows —
    // this excludes untitled popovers/panels and is what makes the summary match
    // what you actually see. Without titles, fall back to large windows only, so
    // app names still appear (with some unavoidable noise) and we show the hint.
    var windowsBySpace: [UInt64: SpaceWindows] = [:]
    for c in candidates {
        if titlesAvailable {
            guard !c.title.isEmpty else { continue }
        } else {
            guard c.width >= 400, c.height >= 300 else { continue }
        }
        var entry = windowsBySpace[c.space] ?? SpaceWindows()
        entry.appCounts[c.owner, default: 0] += 1
        if c.owner == "Google Chrome" {
            entry.chromeWindowCount += 1
            if !c.title.isEmpty && !entry.chromeTitles.contains(c.title) {
                entry.chromeTitles.append(c.title)
            }
        }
        windowsBySpace[c.space] = entry
    }

    func truncate(_ s: String, _ n: Int) -> String {
        return s.count > n ? "\(s.prefix(n - 1))…" : s
    }

    // Compose a one-line "Topic + key apps" summary for a space id.
    func summary(for space: SpaceInfo) -> String? {
        guard let entry = windowsBySpace[space.id] ?? windowsBySpace[space.managedId] else { return nil }
        var parts: [String] = []
        if !entry.chromeTitles.isEmpty {
            var chrome = "Chrome: \(truncate(entry.chromeTitles[0], 40))"
            let extra = entry.chromeWindowCount - 1
            if extra > 0 { chrome += " (+\(extra))" }
            parts.append(chrome)
            // up to 2 other top apps besides Chrome
            let others = entry.appCounts.filter { $0.key != "Google Chrome" }
                .sorted { $0.value > $1.value }.prefix(2).map { $0.key }
            parts.append(contentsOf: others)
        } else {
            // No titles (incl. Chrome with no Screen Recording): top apps by count.
            let apps = entry.appCounts.sorted { $0.value > $1.value }.prefix(3).map { $0.key }
            parts.append(contentsOf: apps)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // Determine menu bar representation
    if let globalIdx = activeGlobalIndex {
        let sfImage: String
        if globalIdx >= 1 && globalIdx <= 50 {
            sfImage = "\(globalIdx).circle.fill"
        } else {
            sfImage = "square.stack.3d.up.fill"
        }
        print(" | sfimage=\(sfImage) template=true")
    } else {
        // Active space is fullscreen or special space
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Fullscreen"
        let truncatedAppName = appName.count > 15 ? "\(appName.prefix(12))..." : appName
        print("\(truncatedAppName) | sfimage=arrow.up.left.and.arrow.down.right template=true")
    }

    // SwiftBar renders rows without an action as disabled (grey). Append a no-op
    // action plus the primary (mode-adaptive) color so info rows read clearly,
    // matching the other plugins in this repo.
    let readable = "color=primary bash=true terminal=false"

    print("---")
    print("Desktop Space Info | \(readable)")

    let currentSpace = displays.flatMap { $0.spaces }.first { $0.isCurrent }
    let currentSummary = currentSpace.flatMap { summary(for: $0) }

    if let globalIdx = activeGlobalIndex {
        let suffix = currentSummary.map { " — \($0)" } ?? ""
        print("Current Space: \(globalIdx) (Global)\(suffix) | \(readable)")
    } else {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown App"
        print("Current Space: Fullscreen (\(appName)) | \(readable)")
    }

    if let dIdx = activeDisplayIndex {
        print("Display: \(dIdx + 1) | \(readable)")
        if let localIdx = activeLocalIndex {
            print("Space on Display: \(localIdx) | \(readable)")
        }
    }

    print("---")

    for display in displays {
        let displayName = "Display \(display.index + 1) (\(display.identifier.prefix(8))...)"
        print("\(displayName) | \(readable)")

        for space in display.spaces {
            let prefix = space.isCurrent ? "● " : "  "
            let label: String
            if space.type == 0 {
                if let gIdx = space.globalUserIndex {
                    label = "\(prefix)Desktop \(gIdx)"
                } else {
                    label = "\(prefix)Desktop"
                }
            } else {
                label = "\(prefix)Fullscreen Space (\(space.id))"
            }

            var details: [String] = []
            if space.isCurrent {
                details.append("active")
            }
            if space.type != 0 {
                details.append("fullscreen")
            }

            let detailStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            let summaryStr = summary(for: space).map { " — \($0)" } ?? ""
            print("\(label)\(detailStr)\(summaryStr) | size=12 \(readable)")
        }
    }

    print("---")
    // Only nag about Screen Recording when permission is truly missing: Chrome
    // windows exist but not a single one yielded a title.
    let totalChromeWindows = windowsBySpace.values.reduce(0) { $0 + $1.chromeWindowCount }
    let totalChromeTitles = windowsBySpace.values.reduce(0) { $0 + $1.chromeTitles.count }
    if totalChromeWindows > 0 && totalChromeTitles == 0 {
        print("Enable Screen Recording for Chrome topic names | size=11 href='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'")
    }
    print("Desktop & Dock Settings... | href='x-apple.systempreferences:com.apple.Desktop-Settings.extension'")
    print("Refresh | refresh=true")
}

run()
### SWIFT END
