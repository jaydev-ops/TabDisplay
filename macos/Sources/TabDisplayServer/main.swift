import AppKit

// Disable stdout buffering to allow real-time console logs in remote background processes
setbuf(stdout, nil)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

if CommandLine.arguments.contains("--auto-start") {
    delegate.autoStart = true
}

app.run()
