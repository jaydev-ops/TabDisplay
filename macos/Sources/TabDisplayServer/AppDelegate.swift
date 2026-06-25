import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    
    private let virtualDisplay = VirtualDisplay()
    private let screenCapture = ScreenCapture()
    private let videoEncoder = VideoEncoder()
    private let controlServer = ControlServer()
    private let serverNetwork = ServerNetwork()
    private let eventInjector = EventInjector()
    private var fileWriter: FileStreamWriter?
    
    var autoStart = false
    var recordFilePath: String?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory (menu bar app only, no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        setupMenu()
        print("TabDisplay macOS Server initialized and status menu ready.")
        
        setupControlServerCallbacks()
        
        // Start TCP listener immediately on default port 5001 to listen for incoming client handshakes
        controlServer.startListener(port: 5001)
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
        
        let startItem = NSMenuItem(title: "Start Listener", action: #selector(startDisplay), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Stop Listener", action: #selector(stopDisplay), keyEquivalent: "t")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        
        updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
    }
    
    private func setupControlServerCallbacks() {
        controlServer.onHandshakeRequest = { [weak self] request in
            guard let self = self else { return TDHandshakeResponse() }
            print("Received handshake request from client device: '\(request.clientDeviceName)'")
            
            // Accept the request and allocate streaming parameters
            var response = TDHandshakeResponse()
            response.accepted = true
            response.serverName = Host.current().localizedName ?? "macOS Host Server"
            response.allocatedWidth = 1920
            response.allocatedHeight = 1080
            response.negotiatedFps = 60
            response.videoStreamPort = 6002 // Default UDP video port
            
            // Activate the virtual display & capture pipeline on the Main thread
            DispatchQueue.main.async {
                self.startDisplayAndStreaming(width: 1920, height: 1080, fps: 60)
            }
            
            return response
        }
        
        controlServer.onClientDisconnected = { [weak self] in
            guard let self = self else { return }
            print("Client TCP connection closed. Shutting down streaming pipeline.")
            
            DispatchQueue.main.async {
                self.stopDisplayAndStreaming()
            }
        }
        
        controlServer.onInputEvent = { [weak self] inputEvent in
            guard let self = self else { return }
            self.eventInjector.injectInput(inputEvent, displayID: self.virtualDisplay.displayID)
        }
        
        controlServer.onTelemetryFeedback = { [weak self] telemetry in
            let loss = telemetry.packetLossRate
            print("Client Network Telemetry -> Drop Rate: \(String(format: "%.2f", loss))%, Jitter: \(String(format: "%.2f", telemetry.averageJitterMs))ms, Latency: \(String(format: "%.2f", telemetry.endToEndLatencyMs))ms")
            
            // Adjust bitrate dynamically (Adaptive Bitrate Control)
            if loss > 5.0 {
                // Network congestion detected, throttle bitrate down
                self?.videoEncoder.setBitrate(2_500_000)
            } else if loss < 1.0 {
                // Clear network link, ramp bitrate back up to standard 5 Mbps
                self?.videoEncoder.setBitrate(5_000_000)
            }
        }
    }
    
    @objc private func startDisplay() {
        print("Starting TCP listener manually...")
        controlServer.startListener(port: 5001)
        updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
    }
    
    @objc private func stopDisplay() {
        print("Stopping network listeners manually...")
        stopDisplayAndStreaming()
        controlServer.stopListener()
        updateMenuStatus(active: false, statusText: "Status: Idle")
    }
    
    private func startDisplayAndStreaming(width: Int, height: Int, fps: Int) {
        print("Activating Virtual Display and capture streams...")
        
        guard virtualDisplay.create(width: width, height: height, fps: fps) else {
            print("Error: Could not allocate virtual secondary display.")
            return
        }
        
        guard let displayID = virtualDisplay.displayID else {
            print("Error: Display created but ID is missing.")
            virtualDisplay.destroy()
            return
        }
        
        // Open local H.264 file recorder if path requested
        if let recordPath = recordFilePath {
            print("Configuring local H.264 recording stream to: \(recordPath)")
            fileWriter = FileStreamWriter(path: recordPath)
            if fileWriter == nil {
                print("Error: Failed to open record file at: \(recordPath)")
            }
        }
        
        // Start UDP video network streamer
        serverNetwork.startStreaming(port: 6002)
        
        // Configure and start video compression session
        videoEncoder.startSession(width: width, height: height, fps: fps)
        
        videoEncoder.onEncodedFrame = { [weak self] data, isKeyframe in
            // 1. Write to local file if active
            self?.fileWriter?.write(data: data)
            
            // 2. Stream to UDP pipeline
            self?.serverNetwork.sendFrame(data: data, isKeyframe: isKeyframe)
        }
        
        // Link screen capture frame emitter directly into the video encoder input
        screenCapture.onPixelBufferCaptured = { [weak self] pixelBuffer, pts in
            self?.videoEncoder.encode(pixelBuffer: pixelBuffer, pts: pts)
        }
        
        // Activate screen capture stream targeting virtual monitor
        screenCapture.startCapture(displayID: displayID, width: width, height: height)
        
        updateMenuStatus(active: true, statusText: "Status: Connected & Streaming")
    }
    
    private func stopDisplayAndStreaming() {
        print("Deactivating Virtual Display and streaming pipelines...")
        
        screenCapture.onPixelBufferCaptured = nil
        screenCapture.stopCapture()
        
        videoEncoder.onEncodedFrame = nil
        videoEncoder.stopSession()
        
        serverNetwork.stopStreaming()
        
        if let writer = fileWriter {
            print("Closing local recording file stream...")
            writer.close()
            fileWriter = nil
            print("Local recording file closed.")
        }
        
        virtualDisplay.destroy()
        
        updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
    }
    
    private func updateMenuStatus(active: Bool, statusText: String) {
        guard let menu = statusItem?.menu else { return }
        menu.items[0].title = statusText
        
        let isIdle = statusText.contains("Idle")
        
        menu.items[2].isEnabled = isIdle // Start button is enabled only when completely idle
        menu.items[3].isEnabled = !isIdle // Stop button is enabled when waiting or active
    }
    
    @objc private func quitApp() {
        print("Terminating TabDisplay Server app...")
        stopDisplayAndStreaming()
        controlServer.stopListener()
        NSApp.terminate(nil)
    }
}

// MARK: - Thread-safe Local File Stream Writer

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
