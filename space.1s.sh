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

mkdir -p "$CACHE_DIR"

# Recompile if binary is missing or this script is newer than the stamp.
if [ ! -x "$BIN" ] || [ "$SELF" -nt "$STAMP" ]; then
    SRC="$CACHE_DIR/space-indicator.swift"
    sed -n '/^### SWIFT BEGIN$/,/^### SWIFT END$/p' "$SELF" \
        | sed '1d;$d' > "$SRC"
    /usr/bin/swiftc -O -o "$BIN.tmp" "$SRC" 2>"$CACHE_DIR/build.log" && mv "$BIN.tmp" "$BIN"
    touch "$STAMP"
fi

exec "$BIN"

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

    print("---")
    print("Desktop Space Info | header=true")

    if let globalIdx = activeGlobalIndex {
        print("Current Space: \(globalIdx) (Global)")
    } else {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown App"
        print("Current Space: Fullscreen (\(appName))")
    }

    if let dIdx = activeDisplayIndex {
        print("Display: \(dIdx + 1)")
        if let localIdx = activeLocalIndex {
            print("Space on Display: \(localIdx)")
        }
    }

    print("---")

    for display in displays {
        let displayName = "Display \(display.index + 1) (\(display.identifier.prefix(8))...)"
        print("\(displayName) | header=true")

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
            print("\(label)\(detailStr) | size=12")
        }
    }

    print("---")
    print("Desktop & Dock Settings... | href='x-apple.systempreferences:com.apple.Desktop-Settings.extension'")
    print("Refresh | refresh=true")
}

run()
### SWIFT END
