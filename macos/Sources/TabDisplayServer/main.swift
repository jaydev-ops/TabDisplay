import AppKit

// Disable stdout buffering to allow real-time console logs in remote background processes
setbuf(stdout, nil)

if CommandLine.arguments.contains("--test-client") {
    runTestClient()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    if CommandLine.arguments.contains("--auto-start") {
        delegate.autoStart = true
    }

    if let recordIndex = CommandLine.arguments.firstIndex(of: "--record-to-file"),
       recordIndex + 1 < CommandLine.arguments.count {
        delegate.recordFilePath = CommandLine.arguments[recordIndex + 1]
    }

    app.run()
}
