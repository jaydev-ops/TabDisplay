import Foundation
import CoreGraphics

class EventInjector {
    private var isMouseDown = false
    
    init() {
        print("EventInjector initialized")
    }
    
    func injectInput(_ event: TDInputEvent, displayID: CGDirectDisplayID?) {
        // Default coordinates to the primary display if no virtual display ID is active.
        let targetDisplayID = displayID ?? CGMainDisplayID()
        let bounds = CGDisplayBounds(targetDisplayID)
        
        // Compute target global position
        let xGlobal = bounds.origin.x + CGFloat(event.xPercent) * bounds.size.width
        let yGlobal = bounds.origin.y + CGFloat(event.yPercent) * bounds.size.height
        let cursorPosition = CGPoint(x: xGlobal, y: yGlobal)
        
        switch event.action {
        case .actionDown:
            isMouseDown = true
            // Move cursor to the target position first (mouseMoved)
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cursorPosition, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            // Trigger down event
            if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cursorPosition, mouseButton: .left) {
                downEvent.post(tap: .cghidEventTap)
            }
            
        case .actionUp:
            isMouseDown = false
            if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cursorPosition, mouseButton: .left) {
                upEvent.post(tap: .cghidEventTap)
            }
            
        case .actionMove:
            let type: CGEventType = isMouseDown ? .leftMouseDragged : .mouseMoved
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursorPosition, mouseButton: .left) {
                moveEvent.post(tap: .cghidEventTap)
            }
            
        case .actionScroll:
            // scrollWheelEvent2Source expects vertical scroll in wheel1 and horizontal scroll in wheel2
            // wheelCount is 2 for 2D scrolling. wheel1 is vertical, wheel2 is horizontal.
            if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: event.scrollDeltaY, wheel2: event.scrollDeltaX, wheel3: 0) {
                scrollEvent.post(tap: .cghidEventTap)
            }
            
        case .UNRECOGNIZED:
            break
        }
    }
}
