import Foundation

/// Manages ADB USB device detection and automatic port forwarding
/// for the TabDisplay USB mode pipeline.
class UsbBridge {

    // Callbacks
    var onDeviceConnected: (() -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    private(set) var isDeviceConnected = false
    private(set) var isRunning = false

    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.tabdisplay.usbbridge", qos: .utility)
    private let pollIntervalSeconds: Double = 2.0

    // Ports to forward (must match server listen ports)
    private let controlPort = 5001
    private let videoPort   = 6002

    init() {
        print("UsbBridge initialized")
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        guard let _ = adbPath() else {
            print("UsbBridge: ⚠️  'adb' not found. Install Android Platform Tools:")
            print("          brew install android-platform-tools")
            return
        }
        isRunning = true
        print("UsbBridge: Starting USB device polling (every \(Int(pollIntervalSeconds))s)...")
        schedulePoll()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollTimer?.cancel()
        pollTimer = nil

        if isDeviceConnected {
            removeForwards()
            isDeviceConnected = false
        }
        print("UsbBridge: Stopped.")
    }

    // MARK: - Polling

    private func schedulePoll() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: pollIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        guard isRunning else { return }
        let devicePresent = hasConnectedDevice()

        if devicePresent && !isDeviceConnected {
            print("UsbBridge: Android device detected via USB. Setting up port forwards...")
            if setupForwards() {
                isDeviceConnected = true
                DispatchQueue.main.async { [weak self] in
                    self?.onDeviceConnected?()
                }
            }
        } else if !devicePresent && isDeviceConnected {
            print("UsbBridge: Android device disconnected. Removing port forwards.")
            removeForwards()
            isDeviceConnected = false
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceDisconnected?()
            }
        }
    }

    // MARK: - ADB Helpers

    /// Returns the path to the `adb` binary if available.
    private func adbPath() -> String? {
        let candidates = [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: check $PATH
        if let path = runAdb(["which", "adb"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return nil
    }

    /// Checks if at least one ADB device is connected (not `unauthorized`).
    private func hasConnectedDevice() -> Bool {
        guard let adb = adbPath() else { return false }
        let output = shell(adb, args: ["devices"]) ?? ""
        // A connected device line ends with "device" (not "offline" / "unauthorized")
        let lines = output.components(separatedBy: "\n")
        return lines.dropFirst().contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.hasSuffix("device")
        }
    }

    /// Sets up `adb reverse` for both control and video ports.
    @discardableResult
    private func setupForwards() -> Bool {
        guard let adb = adbPath() else { return false }
        let controlOk = shell(adb, args: ["reverse", "tcp:\(controlPort)", "tcp:\(controlPort)"]) != nil
        let videoOk   = shell(adb, args: ["reverse", "tcp:\(videoPort)",   "tcp:\(videoPort)"])   != nil

        if controlOk && videoOk {
            print("UsbBridge: ✓ Reversed tcp:\(controlPort) and tcp:\(videoPort) over USB")
            // Log active reverses
            if let list = shell(adb, args: ["reverse", "--list"]) {
                print("UsbBridge: Active reverses:\n\(list)")
            }
            return true
        } else {
            print("UsbBridge: ✗ Failed to set up port reverses.")
            return false
        }
    }

    /// Removes all ADB port reverses.
    private func removeForwards() {
        guard let adb = adbPath() else { return }
        shell(adb, args: ["reverse", "--remove-all"])
        print("UsbBridge: All ADB port reverses removed.")
    }


    // MARK: - Process Helpers

    @discardableResult
    private func shell(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // `which` fallback via /usr/bin/which
    private func runAdb(_ args: [String]) -> String? {
        return shell("/usr/bin/which", args: args)
    }
}
