import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Pass command-line arguments (paths) to the delegate for processing after launch
let args = CommandLine.arguments.dropFirst() // skip argv[0] (executable path)
if !args.isEmpty {
    delegate.pendingURLs = args.map { URL(fileURLWithPath: $0) }
}

app.run()
