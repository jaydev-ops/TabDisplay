import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    private let virtualDisplay = VirtualDisplay()
    private let screenCapture = ScreenCapture()
    
    var autoStart = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory (menu bar app only, no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        setupMenu()
        print("TabDisplay macOS Server initialized and status menu ready.")
        
        if autoStart {
            startDisplay()
        }
    }
    
    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.title = "🖥️"
        
        let menu = NSMenu()
        
        let statusItemMenu = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)
        
        menu.addItem(NSMenuItem.separator())
        
        let startItem = NSMenuItem(title: "Start Virtual Display", action: #selector(startDisplay), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Stop Virtual Display", action: #selector(stopDisplay), keyEquivalent: "t")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func startDisplay() {
        print("Starting Virtual Display setup...")
        
        // Target standard HD resolution for tablet sizing matching
        let width = 1920
        let height = 1080
        let fps = 60
        
        guard virtualDisplay.create(width: width, height: height, fps: fps) else {
            print("Error: Could not allocate virtual secondary display.")
            return
        }
        
        guard let displayID = virtualDisplay.displayID else {
            print("Error: Virtual display allocation succeeded but display ID is missing.")
            virtualDisplay.destroy()
            return
        }
        
        // Start capture loop on newly created display ID
        screenCapture.startCapture(displayID: displayID, width: width, height: height)
        
        updateMenuStatus(active: true)
    }
    
    @objc private func stopDisplay() {
        print("Stopping display mirroring...")
        
        screenCapture.stopCapture()
        virtualDisplay.destroy()
        
        updateMenuStatus(active: false)
    }
    
    private func updateMenuStatus(active: Bool) {
        guard let menu = statusItem?.menu else { return }
        menu.items[0].title = active ? "Status: Capturing..." : "Status: Idle"
        menu.items[2].isEnabled = !active // Start button
        menu.items[3].isEnabled = active  // Stop button
    }
    
    @objc private func quitApp() {
        // Ensure cleanup is executed on abrupt quit
        screenCapture.stopCapture()
        virtualDisplay.destroy()
        NSApp.terminate(nil)
    }
}
