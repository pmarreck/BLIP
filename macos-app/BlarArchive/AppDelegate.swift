import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var dropViewController: DropViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

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
        alert.informativeText = """
        A next-generation archive tool built on the BLAR format.

        Why BLAR?

        \u{2022} Transparent container expansion — PDFs, JPEGs, PNGs, \
        ZIPs (including Office docs and EPUBs) are automatically \
        decomposed for dramatically better compression, then \
        perfectly reconstructed on extraction.

        \u{2022} Integrated BLAKE3 checksumming with Merkle hash trees \
        for per-file and per-directory integrity verification.

        \u{2022} Built-in encryption (AES-256-GCM or ChaCha20-Poly1305) \
        with Argon2id key derivation — no external tools needed.

        \u{2022} Full metadata preservation — permissions, timestamps, \
        extended attributes, and macOS resource forks.

        \u{2022} Multiple compression algorithms (LZMA2/7zip, zstd, LZ4) \
        with per-file or solid-archive granularity.

        \u{2022} Deterministic output — same inputs always produce \
        byte-identical archives.

        https://github.com/pmarreck/BLIP
        """
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.runModal()
    }
}

