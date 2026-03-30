import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var dropViewController: DropViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        dropViewController = DropViewController()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blip Archiver"
        window.contentViewController = dropViewController
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.minSize = NSSize(width: 400, height: 300)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Handle files opened via Finder (double-click .blar, Open With, etc.)
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        dropViewController.handleDroppedURLs(urls)
        sender.reply(toOpenOrPrint: .success)
    }
}
