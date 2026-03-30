import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var dropViewController: DropViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the main menu
        setupMainMenu()

        // Create the main window
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
        window.minSize = NSSize(width: 400, height: 300)

        // Activate the app and show the window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // Handle files opened via Finder (double-click .blar, Open With, etc.)
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        dropViewController.handleDroppedURLs(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        let appName = "Blip Archiver"
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Blip Archiver"
        alert.informativeText = "A drag-and-drop archive tool for BLAR archives.\n\nDrop files to create an archive.\nDrop .blar files to extract.\n\nhttps://github.com/pmarreck/BLIP"
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }
}
