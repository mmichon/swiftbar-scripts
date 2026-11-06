import CoreGraphics
import Foundation

// Puts the built-in display back in its factory-default mode (the one macOS flags
// as "Default for display" in System Settings). A CRD session resizes the desktop
// to fit the client and leaves it that way after disconnecting.
//
// The mode is looked up by flag rather than hardcoded, so this keeps working on a
// different MacBook. kDisplayModeDefaultFlag lives in IOKit's IOGraphicsTypes.h,
// which isn't importable from Swift.
//
// Exit codes: 0 = display is in the default mode (or would be set, with --dry-run)
//             1 = could not set it
//             2 = built-in display not online (lid closed); try again later
let kDisplayModeDefaultFlag: UInt32 = 0x4
let dryRun = CommandLine.arguments.contains("--dry-run")

var count: UInt32 = 0
var displays = [CGDirectDisplayID](repeating: 0, count: 16)
CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)

guard let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
    print("built-in display not online")
    exit(2)
}

// Without this option the HiDPI modes are hidden, and the default mode is one.
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []

guard let target = modes.first(where: { $0.ioFlags & kDisplayModeDefaultFlag != 0 }) else {
    print("no default mode reported for built-in display")
    exit(1)
}
let targetDesc = "\(target.width)x\(target.height)"

guard let current = CGDisplayCopyDisplayMode(display) else {
    print("could not read current mode")
    exit(1)
}
let currentDesc = "\(current.width)x\(current.height)"

// Already there: skip it, since a mode change blanks the screen for a moment.
if current.ioDisplayModeID == target.ioDisplayModeID {
    print("already at default \(targetDesc)")
    exit(0)
}

if dryRun {
    print("would change \(currentDesc) -> \(targetDesc)")
    exit(0)
}

var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else {
    print("could not begin display configuration")
    exit(1)
}
guard CGConfigureDisplayWithDisplayMode(config, display, target, nil) == .success else {
    CGCancelDisplayConfiguration(config)
    print("could not configure \(targetDesc)")
    exit(1)
}
guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
    print("could not apply \(targetDesc)")
    exit(1)
}
print("changed \(currentDesc) -> \(targetDesc)")
