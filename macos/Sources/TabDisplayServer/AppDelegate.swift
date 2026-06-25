import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    private let virtualDisplay = VirtualDisplay()
    private let screenCapture  = ScreenCapture()
    private let videoEncoder   = VideoEncoder()
    private let controlServer  = ControlServer()
    private let serverNetwork  = ServerNetwork()
    private let eventInjector  = EventInjector()
    private let usbBridge      = UsbBridge()
    private var fileWriter: FileStreamWriter?

    var autoStart = false
    var recordFilePath: String?

    // Track which menu item index is the USB toggle (set during setupMenu)
    private var usbMenuItemIndex = 0

    // ABR state tracking variables
    private var currentBitrate: Int = 5_000_000
    private var isScaledDown: Bool = false
    private var lastAdjustmentTime = Date()
    private var allocatedWidth: Int = 1920
    private var allocatedHeight: Int = 1080
    private var negotiatedFps: Int = 60
    private var isUsbModeActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupControlServerCallbacks()
        setupUsbBridgeCallbacks()
        print("TabDisplay macOS Server initialized and status menu ready.")
        // Start TCP control listener immediately
        controlServer.startListener(port: 5001)
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.title = "🖥️"

        let menu = NSMenu()

        // [0] Status label
        let statusItemMenu = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)

        menu.addItem(NSMenuItem.separator()) // [1]

        // [2] Start Listener
        let startItem = NSMenuItem(title: "Start Listener", action: #selector(startDisplay), keyEquivalent: "s")
        startItem.target = self
        menu.addItem(startItem)

        // [3] Stop Listener
        let stopItem = NSMenuItem(title: "Stop Listener", action: #selector(stopDisplay), keyEquivalent: "t")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator()) // [4]

        // [5] USB Mode toggle
        let usbItem = NSMenuItem(title: "USB Mode: Off", action: #selector(toggleUsbMode), keyEquivalent: "u")
        usbItem.target = self
        menu.addItem(usbItem)
        usbMenuItemIndex = 5

        menu.addItem(NSMenuItem.separator()) // [6]

        // [7] Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
    }

    // MARK: - USB Mode

    @objc private func toggleUsbMode() {
        if usbBridge.isRunning {
            usbBridge.stop()
            updateUsbMenuItem(on: false, status: nil)
            print("USB Mode disabled.")
        } else {
            usbBridge.start()
            updateUsbMenuItem(on: true, status: "Scanning…")
            print("USB Mode enabled — polling for device.")
        }
    }

    private func updateUsbMenuItem(on: Bool, status: String?) {
        guard let menu = statusItem?.menu else { return }
        let item = menu.items[usbMenuItemIndex]
        if on, let status = status {
            item.title = "USB Mode: \(status)"
            item.state = .on
        } else {
            item.title = "USB Mode: Off"
            item.state = .off
        }
    }

    private func setupUsbBridgeCallbacks() {
        usbBridge.onDeviceConnected = { [weak self] in
            guard let self = self else { return }
            print("UsbBridge → Device connected! Switching to TCP video transport.")
            self.updateUsbMenuItem(on: true, status: "Device Connected ✓")
        }
        usbBridge.onDeviceDisconnected = { [weak self] in
            guard let self = self else { return }
            print("UsbBridge → Device disconnected.")
            self.updateUsbMenuItem(on: true, status: "Scanning…")
        }
    }

    // MARK: - Control Server Callbacks

    private func setupControlServerCallbacks() {
        controlServer.onHandshakeRequest = { [weak self] request in
            guard let self = self else { return TDHandshakeResponse() }
            print("Received handshake request from client device: '\(request.clientDeviceName)'")

            var response = TDHandshakeResponse()
            response.accepted = true
            response.serverName = Host.current().localizedName ?? "macOS Host Server"
            response.allocatedWidth = 1920
            response.allocatedHeight = 1080
            response.negotiatedFps = 60
            response.videoStreamPort = 6002

            // Negotiate transport: TCP when a USB device is connected, UDP otherwise
            if self.usbBridge.isRunning && self.usbBridge.isDeviceConnected {
                response.videoTransport = .tcp
                print("Handshake: Negotiated TCP video transport (USB mode).")
            } else {
                response.videoTransport = .udp
                print("Handshake: Negotiated UDP video transport (Wi-Fi mode).")
            }

            DispatchQueue.main.async {
                self.startDisplayAndStreaming(
                    width: 1920, height: 1080, fps: 60,
                    usbMode: response.videoTransport == .tcp
                )
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
            guard let self = self else { return }
            let loss = telemetry.packetLossRate
            let jitter = telemetry.averageJitterMs
            let latency = telemetry.endToEndLatencyMs
            print("Client Telemetry → Drop: \(String(format: "%.2f", loss))%, Jitter: \(String(format: "%.2f", jitter))ms, Latency: \(String(format: "%.2f", latency))ms")

            let now = Date()
            guard now.timeIntervalSince(self.lastAdjustmentTime) >= 2.0 else { return }

            var changed = false
            var newBitrate = self.currentBitrate
            let wasScaledDown = self.isScaledDown
            var shouldUpdateResolution = false

            if loss > 2.0 {
                // Network congestion detected, reduce bitrate by 20%
                newBitrate = max(1_500_000, Int(Double(newBitrate) * 0.8))
                changed = true
                
                // If we're already at minimum bitrate and loss is still high, or latency is very high, drop resolution
                if newBitrate == 1_500_000 && (loss > 5.0 || latency > 100.0) && !wasScaledDown {
                    self.isScaledDown = true
                    shouldUpdateResolution = true
                    print("ABR: Network severely congested. Scaling capture resolution down to 0.75x.")
                }
            } else if loss < 0.5 && latency < 50.0 {
                // Clean network, increase bitrate incrementally
                if newBitrate < 5_000_000 {
                    newBitrate = min(5_000_000, newBitrate + 500_000)
                    changed = true
                }
                
                // If bitrate has recovered to >= 4 Mbps, scale resolution back up
                if newBitrate >= 4_000_000 && wasScaledDown {
                    self.isScaledDown = false
                    shouldUpdateResolution = true
                    print("ABR: Network recovered. Restoring native capture resolution.")
                }
            }

            if changed || shouldUpdateResolution {
                self.lastAdjustmentTime = now
                
                if newBitrate != self.currentBitrate {
                    self.currentBitrate = newBitrate
                    self.videoEncoder.setBitrate(newBitrate)
                }

                if shouldUpdateResolution {
                    let scaleFactor: Double = self.isScaledDown ? 0.75 : 1.0
                    let targetWidth = Int(Double(self.allocatedWidth) * scaleFactor)
                    let targetHeight = Int(Double(self.allocatedHeight) * scaleFactor)
                    
                    print("ABR: Applying resolution update: \(targetWidth)x\(targetHeight) (scale=\(scaleFactor))")
                    DispatchQueue.main.async {
                        self.screenCapture.updateResolution(width: targetWidth, height: targetHeight)
                        self.videoEncoder.startSession(width: targetWidth, height: targetHeight, fps: self.negotiatedFps)
                    }
                }
            }
        }
    }

    // MARK: - Start / Stop Menu Actions

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

    // MARK: - Pipeline Lifecycle

    private func startDisplayAndStreaming(width: Int, height: Int, fps: Int, usbMode: Bool) {
        print("Activating Virtual Display and capture streams (usbMode=\(usbMode))...")

        // Initialize display dimensions and ABR parameters
        self.allocatedWidth = width
        self.allocatedHeight = height
        self.negotiatedFps = fps
        self.isUsbModeActive = usbMode
        self.currentBitrate = 5_000_000
        self.isScaledDown = false
        self.lastAdjustmentTime = Date()

        guard virtualDisplay.create(width: width, height: height, fps: fps) else {
            print("Error: Could not allocate virtual secondary display.")
            return
        }

        guard let displayID = virtualDisplay.displayID else {
            print("Error: Display created but ID is missing.")
            virtualDisplay.destroy()
            return
        }

        if let recordPath = recordFilePath {
            print("Configuring local H.264 recording stream to: \(recordPath)")
            fileWriter = FileStreamWriter(path: recordPath)
            if fileWriter == nil {
                print("Error: Failed to open record file at: \(recordPath)")
            }
        }

        // Start video streaming — TCP or UDP based on negotiated transport
        if usbMode {
            serverNetwork.startTCPStreaming(port: 6002)
        } else {
            serverNetwork.startStreaming(port: 6002)
        }

        videoEncoder.startSession(width: width, height: height, fps: fps)

        videoEncoder.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.fileWriter?.write(data: data)
            self?.serverNetwork.sendFrame(data: data, isKeyframe: isKeyframe)
        }

        screenCapture.onPixelBufferCaptured = { [weak self] pixelBuffer, pts in
            self?.videoEncoder.encode(pixelBuffer: pixelBuffer, pts: pts)
        }

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

    // MARK: - Menu Helpers

    private func updateMenuStatus(active: Bool, statusText: String) {
        guard let menu = statusItem?.menu else { return }
        menu.items[0].title = statusText

        let isIdle = statusText.contains("Idle")
        // [2] = Start, [3] = Stop
        menu.items[2].isEnabled = isIdle
        menu.items[3].isEnabled = !isIdle
    }

    @objc private func quitApp() {
        print("Terminating TabDisplay Server app...")
        usbBridge.stop()
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
