import CoreGraphics
let pos = CGEvent(source: nil)?.location ?? CGPoint.zero
let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                 mouseCursorPosition: CGPoint(x: pos.x + 1, y: pos.y),
                 mouseButton: .left)
ev?.post(tap: .cghidEventTap)
let ev2 = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                  mouseCursorPosition: pos, mouseButton: .left)
ev2?.post(tap: .cghidEventTap)
