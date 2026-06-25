import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    private let virtualDisplay = VirtualDisplay()
    private let screenCapture = ScreenCapture()
    private let videoEncoder = VideoEncoder()
    private var fileWriter: FileStreamWriter?
    
    var autoStart = false
    var recordFilePath: String?
    
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
        
        // Setup local H.264 file recording if requested
        if let recordPath = recordFilePath {
            print("Configuring local H.264 recording stream to: \(recordPath)")
            fileWriter = FileStreamWriter(path: recordPath)
            if fileWriter == nil {
                print("Error: Failed to open record file at path: \(recordPath)")
            }
        }
        
        // Configure and start video compression session
        videoEncoder.startSession(width: width, height: height, fps: fps)
        
        var encodedFrameCount: UInt64 = 0
        videoEncoder.onEncodedFrame = { [weak self] data, isKeyframe in
            encodedFrameCount += 1
            if encodedFrameCount % 60 == 0 {
                print("Encoded Frame: #\(encodedFrameCount) | Bytes: \(data.count) | Keyframe: \(isKeyframe)")
            }
            self?.fileWriter?.write(data: data)
        }
        
        // Wire screen capture frames directly into the video encoder input
        screenCapture.onPixelBufferCaptured = { [weak self] pixelBuffer, pts in
            self?.videoEncoder.encode(pixelBuffer: pixelBuffer, pts: pts)
        }
        
        // Start capture loop on newly created display ID
        screenCapture.startCapture(displayID: displayID, width: width, height: height)
        
        updateMenuStatus(active: true)
    }
    
    @objc private func stopDisplay() {
        print("Stopping display mirroring...")
        
        screenCapture.onPixelBufferCaptured = nil
        screenCapture.stopCapture()
        videoEncoder.onEncodedFrame = nil
        videoEncoder.stopSession()
        
        if let writer = fileWriter {
            print("Closing local recording file stream...")
            writer.close()
            fileWriter = nil
            print("Local recording file closed.")
        }
        
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
        screenCapture.onPixelBufferCaptured = nil
        screenCapture.stopCapture()
        videoEncoder.onEncodedFrame = nil
        videoEncoder.stopSession()
        fileWriter?.close()
        fileWriter = nil
        
        virtualDisplay.destroy()
        NSApp.terminate(nil)
    }
}

fileprivate class FileStreamWriter {
    private var fileHandle: FileHandle?
    private let writeQueue = DispatchQueue(label: "com.tabdisplay.filewriter")
    
    init?(path: String) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(atPath: path)
        }
        if !fileManager.createFile(atPath: path, contents: nil, attributes: nil) {
            return nil
        }
        self.fileHandle = FileHandle(forWritingAtPath: path)
    }
    
    func write(data: Data) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            if #available(macOS 10.15.4, *) {
                try? self.fileHandle?.write(contentsOf: data)
            } else {
                self.fileHandle?.write(data)
            }
        }
    }
    
    func close() {
        writeQueue.sync { [weak self] in
            guard let self = self else { return }
            if #available(macOS 10.15, *) {
                try? self.fileHandle?.close()
            } else {
                self.fileHandle?.closeFile()
            }
            self.fileHandle = nil
        }
    }
}
