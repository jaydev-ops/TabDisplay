import Foundation
import CoreGraphics
import CoreGraphicsPrivate

class VirtualDisplay {
    private var displayInstance: AnyObject?
    private(set) var displayID: CGDirectDisplayID?
    
    init() {
        print("VirtualDisplay wrapper initialized (using CoreGraphicsPrivate helper)")
    }
    
    func create(width: Int, height: Int, fps: Int) -> Bool {
        var displayObj: AnyObject?
        let newDisplayID = PrivateDisplayHelper.createVirtualDisplay(
            withWidth: Int32(width),
            height: Int32(height),
            fps: Int32(fps),
            outDisplay: &displayObj
        )
        
        guard newDisplayID != 0, let activeDisplay = displayObj else {
            print("Error: PrivateDisplayHelper failed to allocate virtual display.")
            return false
        }
        
        self.displayInstance = activeDisplay
        self.displayID = newDisplayID
        print("CGVirtualDisplay created with Display ID: \(newDisplayID)")
        return true
    }
    
    func destroy() {
        if let id = displayID {
            print("Destroying virtual display ID: \(id)")
        }
        if let activeDisplay = displayInstance {
            PrivateDisplayHelper.destroyVirtualDisplay(activeDisplay)
        }
        displayInstance = nil
        displayID = nil
    }
}
