import CoreGraphics
let pos = CGEvent(source: nil)?.location ?? CGPoint.zero

func post(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// Hot corners fire when the cursor enters a screen corner. If it is parked in
// one, moving out and back would re-trigger it, so step inward and stay there.
let margin: CGFloat = 8
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &count)
for id in ids.prefix(Int(count)) {
    let b = CGDisplayBounds(id)
    guard b.contains(pos) else { continue }
    let nearL = pos.x - b.minX < margin, nearR = b.maxX - pos.x <= margin
    let nearT = pos.y - b.minY < margin, nearB = b.maxY - pos.y <= margin
    if (nearL || nearR) && (nearT || nearB) {
        post(CGPoint(x: nearL ? b.minX + margin * 2 : b.maxX - margin * 2,
                     y: nearT ? b.minY + margin * 2 : b.maxY - margin * 2))
        exit(0)
    }
}

post(CGPoint(x: pos.x + 1, y: pos.y))
post(pos)
