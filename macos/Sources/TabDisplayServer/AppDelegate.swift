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

    // ── STEP 2: compositor probe window ──────────────────────────────────────
    // A fullscreen borderless NSWindow placed on the virtual display.
    // Purpose: give WindowServer composited content so SCStream receives
    // continuous damage events instead of going idle immediately.
    // Background is a distinctive dark-gray so first_frame.png confirms
    // we are capturing the virtual display, not the primary display.
    private var displayProbeWindow: NSWindow?
    private var permissionTimer: Timer?
    // ── END STEP 2 ───────────────────────────────────────────────────────────

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
        // Auto-start USB Bridge polling on launch for seamless plug-and-play detection
        usbBridge.start()
        
        print("TabDisplay macOS Server initialized and status menu ready.")
        
        // Priority 1 & 2: Check screen capture permissions on launch
        let hasAccess = CGPreflightScreenCaptureAccess()
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        print("[\(t0) ms] [Permission] Status on Launch: \(hasAccess ? "GRANTED" : "NOT GRANTED")")
        
        if hasAccess {
            // Start TCP control listener immediately if permission is already granted
            controlServer.startListener(port: 5001)
            updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
        } else {
            let t1 = Int64(Date().timeIntervalSince1970 * 1000)
            print("[\(t1) ms] [Permission] Requesting screen recording permission from user...")
            // Trigger system prompt (non-blocking)
            let reqResult = CGRequestScreenCaptureAccess()
            let t2 = Int64(Date().timeIntervalSince1970 * 1000)
            print("[\(t2) ms] [Permission] CGRequestScreenCaptureAccess returned \(reqResult)")
            updateMenuStatus(active: false, statusText: "Status: Permission Required")
            
            // Start polling timer to detect when permission is granted
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self = self else { return }
                let tp = Int64(Date().timeIntervalSince1970 * 1000)
                let pollAccess = CGPreflightScreenCaptureAccess()
                print("[\(tp) ms] [Permission] Polling check: \(pollAccess ? "GRANTED" : "NOT GRANTED")")
                if pollAccess {
                    print("[\(Int64(Date().timeIntervalSince1970 * 1000)) ms] [Permission] Access granted! Initializing control listener.")
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.controlServer.startListener(port: 5001)
                    self.updateMenuStatus(active: true, statusText: "Status: Waiting for client...")
                }
            }
        }
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

        // [5] USB Mode toggle (default to enabled/scanning)
        let usbItem = NSMenuItem(title: "USB Mode: Scanning…", action: #selector(toggleUsbMode), keyEquivalent: "u")
        usbItem.target = self
        usbItem.state = .on
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
        controlServer.onHandshakeRequest = { [weak self] request, completion in
            guard let self = self else {
                completion(TDHandshakeResponse())
                return
            }
            print("Received handshake request from client device: '\(request.clientDeviceName)' (\(request.preferredWidth)x\(request.preferredHeight))")

            // Handle the handshake asynchronously on the main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    completion(TDHandshakeResponse())
                    return
                }

                // Clean up any active session before initiating a new one
                if self.virtualDisplay.displayID != nil {
                    print("Handshake: Cleaning up active previous session before starting new one.")
                    self.stopDisplayAndStreaming()
                }

                let rawWidth = request.preferredWidth > 0 ? Int(request.preferredWidth) : 1920
                let rawHeight = request.preferredHeight > 0 ? Int(request.preferredHeight) : 1080
                let width = rawWidth & ~1
                let height = rawHeight & ~1

                var response = TDHandshakeResponse()
                response.accepted = true
                response.serverName = Host.current().localizedName ?? "macOS Host Server"
                response.allocatedWidth = UInt32(width)
                response.allocatedHeight = UInt32(height)
                response.negotiatedFps = 60
                response.videoStreamPort = 6002

                // Negotiate transport: TCP when a USB device is connected, UDP otherwise
                if self.usbBridge.isRunning && self.usbBridge.isDeviceConnected && request.clientDeviceName != "Local Loopback Mock Tablet" {
                    response.videoTransport = .tcp
                    print("Handshake: Negotiated TCP video transport (USB mode).")
                } else {
                    response.videoTransport = .udp
                    print("Handshake: Negotiated UDP video transport (Wi-Fi mode).")
                }

                self.startDisplayAndStreamingAsync(
                    width: width, height: height, fps: 60,
                    usbMode: response.videoTransport == .tcp
                ) { success in
                    if success {
                        completion(response)
                    } else {
                        var failResponse = response
                        failResponse.accepted = false
                        completion(failResponse)
                    }
                }
            }
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
                    let targetWidth = Int(Double(self.allocatedWidth) * scaleFactor) & ~1
                    let targetHeight = Int(Double(self.allocatedHeight) * scaleFactor) & ~1
                    
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

    private func startDisplayAndStreamingAsync(
        width: Int, height: Int, fps: Int, usbMode: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        print("Activating Virtual Display and capture streams asynchronously (usbMode=\(usbMode))...")

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
            completion(false)
            return
        }

        guard let displayID = virtualDisplay.displayID else {
            print("Error: Display created but ID is missing.")
            virtualDisplay.destroy()
            completion(false)
            return
        }

        print("[P1] CGVirtualDisplay created | ID: \(displayID)")
        print("[P1] CGDisplayIsActive:       \(CGDisplayIsActive(displayID))")
        print("[P1] CGDisplayIsAsleep:       \(CGDisplayIsAsleep(displayID))")
        print("[P1] CGDisplayIsInMirrorSet:  \(CGDisplayIsInMirrorSet(displayID))")
        print("[P1] CGDisplayPixelsWide:     \(CGDisplayPixelsWide(displayID))")
        print("[P1] CGDisplayPixelsHigh:     \(CGDisplayPixelsHigh(displayID))")
        var cgCount: UInt32 = 0
        var cgIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &cgIDs, &cgCount)
        print("[P1] CGGetActiveDisplayList count: \(cgCount)")
        for i in 0..<Int(cgCount) {
            let b = CGDisplayBounds(cgIDs[i])
            print("[P1]   Display[\(i)] ID=\(cgIDs[i]) bounds={x:\(b.origin.x), y:\(b.origin.y), w:\(b.size.width), h:\(b.size.height)}")
        }
        for screen in NSScreen.screens {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            print("[P1] NSScreen: '\(screen.localizedName)' id=\(screenID) frame=\(screen.frame)")
        }

        if let recordPath = recordFilePath {
            print("Configuring local H.264 recording stream to: \(recordPath)")
            fileWriter = FileStreamWriter(path: recordPath)
            if fileWriter == nil {
                print("Error: Failed to open record file at: \(recordPath)")
            }
        }

        // Wait dynamically for NSScreen to appear
        waitForVirtualDisplayScreen(displayID: displayID) { [weak self] virtualScreen in
            guard let self = self, self.virtualDisplay.displayID == displayID else {
                completion(false)
                return
            }

            guard let screen = virtualScreen else {
                print("[Step2] ERROR: NSScreen for virtual display \(displayID) not found after timeout.")
                self.stopDisplayAndStreaming()
                completion(false)
                return
            }

            print("[Step2] NSScreen found for virtual display: \(screen.localizedName) frame=\(screen.frame)")

            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            win.level = .statusBar
            win.isOpaque = true
            win.hasShadow = false
            win.collectionBehavior = [.canJoinAllSpaces, .stationary]
            win.setFrame(screen.frame, display: true)

            let tickView = DisplayTickView(frame: screen.frame)
            win.contentView = tickView
            tickView.startTicking()

            win.orderFrontRegardless()
            self.displayProbeWindow = win
            print("[Step2] Probe window + DisplayTickView created at \(win.frame) on virtual display \(displayID)")

            // Wait 200ms for first display-link repaint cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.virtualDisplay.displayID == displayID else {
                    completion(false)
                    return
                }

                print("[Step2] Starting capture 200ms after probe window creation.")

                var firstFrameHandled = false
                let timeoutTask = DispatchWorkItem { [weak self] in
                    guard let self = self, !firstFrameHandled else { return }
                    firstFrameHandled = true
                    print("[P3] WATCHDOG: First frame timeout after 5.0 seconds.")
                    self.stopDisplayAndStreaming()
                    completion(false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutTask)

                self.screenCapture.onFirstFrameReceived = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, !firstFrameHandled else { return }
                        firstFrameHandled = true
                        timeoutTask.cancel()

                        print("[P3] WATCHDOG: First frame confirmed received. Completing handshake and starting video stream.")

                        self.videoEncoder.startSession(width: width, height: height, fps: fps)

                        self.videoEncoder.onEncodedFrame = { [weak self] data, isKeyframe in
                            self?.fileWriter?.write(data: data)
                            self?.serverNetwork.sendFrame(data: data, isKeyframe: isKeyframe)
                        }

                        self.screenCapture.onPixelBufferCaptured = { [weak self] pixelBuffer, pts in
                            self?.videoEncoder.encode(pixelBuffer: pixelBuffer, pts: pts)
                        }

                        if usbMode {
                            self.serverNetwork.startTCPStreaming(port: 6002)
                        } else {
                            self.serverNetwork.startStreaming(port: 6002)
                        }

                        self.updateMenuStatus(active: true, statusText: "Status: Connected & Streaming")
                        completion(true)
                    }
                }

                self.screenCapture.startCapture(displayID: displayID, width: width, height: height)
            }
        }
    }

    private func waitForVirtualDisplayScreen(displayID: CGDirectDisplayID, retries: Int = 30, completion: @escaping (NSScreen?) -> Void) {
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID }) {
            completion(screen)
            return
        }
        guard retries > 0 else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForVirtualDisplayScreen(displayID: displayID, retries: retries - 1, completion: completion)
        }
    }


    private func stopDisplayAndStreaming() {
        print("Deactivating Virtual Display and streaming pipelines...")

        // ── STEP 2 teardown: close probe window before display is destroyed ──
        if let win = displayProbeWindow {
            (win.contentView as? DisplayTickView)?.stopTicking()
            win.close()
            displayProbeWindow = nil
            print("[Step2] Probe window + DisplayTickView closed.")
        }
        // ── END STEP 2 teardown ──────────────────────────────────────────────

        screenCapture.onPixelBufferCaptured = nil
        screenCapture.stopCapture { [weak self] in
            DispatchQueue.main.async {
                self?.virtualDisplay.destroy()
            }
        }

        videoEncoder.onEncodedFrame = nil
        videoEncoder.stopSession()

        serverNetwork.stopStreaming()

        if let writer = fileWriter {
            print("Closing local recording file stream...")
            writer.close()
            fileWriter = nil
            print("Local recording file closed.")
        }
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

// MARK: - DisplayTickView (Step 2: CVDisplayLink-driven compositor damage source)
// ─────────────────────────────────────────────────────────────────────────────
// A borderless fullscreen NSView that drives a CVDisplayLink at 60 Hz.
// Every 30 display-link ticks (~0.5s) it toggles between two near-identical
// dark shades. The pixel change is imperceptible but forces WindowServer to
// emit a damage rectangle, which SCStream picks up as SCFrameStatus.complete.
//
// This is an explicit diagnostic instrument. In production it should be
// replaced with the actual tablet UI renderer (e.g., a Metal layer showing
// the extended desktop content). It is kept minimal and reversible.
// ─────────────────────────────────────────────────────────────────────────────

fileprivate class DisplayTickView: NSView {
    private var displayLink: CVDisplayLink?
    private var tickCount: Int = 0
    private var phase: Bool = false

    // Two near-identical dark shades — difference is intentional for damage.
    private let colorA = NSColor(calibratedWhite: 0.08, alpha: 1.0)
    private let colorB = NSColor(calibratedWhite: 0.09, alpha: 1.0)

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (phase ? colorB : colorA).setFill()
        dirtyRect.fill()
    }

    func startTicking() {
        guard displayLink == nil else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let view = Unmanaged<DisplayTickView>.fromOpaque(userInfo!).takeUnretainedValue()
            view.tick()
            return kCVReturnSuccess
        }

        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, callback, selfPtr)
        CVDisplayLinkStart(link)
        print("[Step2] DisplayTickView CVDisplayLink started.")
    }

    func stopTicking() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
        print("[Step2] DisplayTickView CVDisplayLink stopped.")
    }

    private func tick() {
        tickCount += 1
        // Toggle phase every 30 ticks (~0.5s at 60Hz) to produce damage.
        if tickCount % 30 == 0 {
            phase.toggle()
            DispatchQueue.main.async { [weak self] in
                self?.setNeedsDisplay(NSRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    deinit { stopTicking() }
}
