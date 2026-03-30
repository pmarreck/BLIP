import Cocoa

class DropViewController: NSViewController {
    private var dropZone: DropZoneView!
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var optionsPanel: OptionsPanel!
    private var optionsContainer: NSView!
    var autoQuit: Bool = false       // quit after processing (CLI mode)
    var forceOverwrite: Bool = false  // skip overwrite prompts (CLI mode)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    // MARK: - Size formatting

    private static func formatSize(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Options panel (right side)
        optionsPanel = OptionsPanel()
        optionsContainer = optionsPanel.view
        optionsContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(optionsContainer)

        // Drop zone (main area)
        dropZone = DropZoneView()
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.onDrop = { [weak self] urls in
            self?.handleDroppedURLs(urls)
        }
        view.addSubview(dropZone)

        // Status label
        statusLabel = NSTextField(labelWithString: "Drop files to archive, or drop .blar to extract")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        view.addSubview(statusLabel)

        // Progress bar
        progressBar = NSProgressIndicator()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        view.addSubview(progressBar)

        NSLayoutConstraint.activate([
            optionsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            optionsContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            optionsContainer.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -8),
            optionsContainer.widthAnchor.constraint(equalToConstant: 180),

            dropZone.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            dropZone.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            dropZone.trailingAnchor.constraint(equalTo: optionsContainer.leadingAnchor, constant: -8),
            dropZone.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -4),

            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            progressBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    // MARK: - Drop handling

    /// Apply CLI options: set the GUI controls and auto-quit flag
    func applyCLIOptions(_ opts: CLIOptions) {
        autoQuit = opts.autoQuit
        forceOverwrite = opts.forceOverwrite
        optionsPanel.applyOptions(opts)
    }

    /// Report stats to stderr (for CLI/scripted usage)
    private func reportStats(_ message: String) {
        if autoQuit {
            fputs("\(message)\n", stderr)
        }
    }

    /// Quit the app if in auto-quit mode
    private func autoQuitIfNeeded() {
        if autoQuit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
    }

    func handleDroppedURLs(_ urls: [URL]) {
        let blarFiles = urls.filter { $0.pathExtension == "blar" }
        let nonBlarFiles = urls.filter { $0.pathExtension != "blar" }

        if !blarFiles.isEmpty && nonBlarFiles.isEmpty {
            extractFiles(blarFiles)
        } else if !nonBlarFiles.isEmpty && blarFiles.isEmpty {
            createArchive(from: nonBlarFiles)
        } else {
            statusLabel.stringValue = "Drop all .blar files to extract, or all other files to archive — don't mix."
        }
    }

    // MARK: - Create archive

    private func totalSize(of urls: [URL]) -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.producesRelativePathURLs]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let fullURL = url.appendingPathComponent(fileURL.relativePath)
                        if let size = try? fullURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            total += UInt64(size)
                        }
                    }
                }
            } else {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }
        return total
    }

    private func createArchive(from urls: [URL]) {
        let options = optionsPanel.currentOptions

        let firstURL = urls[0]
        let baseName: String
        if urls.count == 1 {
            baseName = firstURL.deletingPathExtension().lastPathComponent
        } else {
            baseName = firstURL.deletingLastPathComponent().lastPathComponent
        }
        let outputDir = firstURL.deletingLastPathComponent()
        let outputPath = outputDir.appendingPathComponent(baseName + ".blar")

        if FileManager.default.fileExists(atPath: outputPath.path) && !forceOverwrite {
            let alert = NSAlert()
            alert.messageText = "Overwrite existing archive?"
            alert.informativeText = "\(outputPath.lastPathComponent) already exists."
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        // Validate settings before starting
        do {
            try optionsPanel.validateForCreate()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot create archive"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Resolve password now (before background thread) so env var errors show immediately
        let resolvedPassword: String?
        do {
            resolvedPassword = try optionsPanel.resolvePassword()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Password error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let originalSize = totalSize(of: urls)

        statusLabel.stringValue = "Creating archive..."
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        dropZone.setEnabled(false)

        let startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try BlarBridge.createArchive(
                    paths: urls,
                    outputPath: outputPath,
                    compression: options.compression,
                    solid: options.solid,
                    encryption: options.encryption,
                    password: resolvedPassword,
                    expandContainers: options.expandContainers,
                    threads: 0,
                    progress: { fraction in
                        self?.progressBar.doubleValue = fraction * 100
                    },
                    statusUpdate: { text in
                        self?.statusLabel.stringValue = text
                    }
                )

                // Get output file size
                let archiveSize: UInt64
                if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath.path),
                   let size = attrs[.size] as? UInt64 {
                    archiveSize = size
                } else {
                    archiveSize = 0
                }

                DispatchQueue.main.async {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let origStr = Self.formatSize(originalSize)
                    let archStr = Self.formatSize(archiveSize)
                    let pct = originalSize > 0 ? Double(archiveSize) / Double(originalSize) * 100.0 : 100.0
                    let mbPerSec = elapsed > 0 ? Double(originalSize) / 1024.0 / 1024.0 / elapsed : 0
                    let timeStr = elapsed < 60 ? String(format: "%.1fs", elapsed) : String(format: "%dm%02ds", Int(elapsed) / 60, Int(elapsed) % 60)
                    let statusMsg = "Created \(outputPath.lastPathComponent) (\(origStr) → \(archStr), \(String(format: "%.1f", pct))%) in \(timeStr) (\(String(format: "%.1f", mbPerSec)) MB/s)"
                    self?.statusLabel.stringValue = statusMsg
                    self?.reportStats(statusMsg)
                    self?.progressBar.isHidden = true
                    self?.dropZone.setEnabled(true)
                    self?.autoQuitIfNeeded()
                }
            } catch {
                DispatchQueue.main.async {
                    let errMsg = "Error: \(error.localizedDescription)"
                    self?.statusLabel.stringValue = errMsg
                    self?.reportStats(errMsg)
                    self?.progressBar.isHidden = true
                    self?.dropZone.setEnabled(true)
                    self?.autoQuitIfNeeded()
                }
            }
        }
    }

    // MARK: - Extract archive

    private func extractFiles(_ urls: [URL]) {
        // Resolve password before starting (env var errors show immediately)
        let password: String?
        do {
            password = try optionsPanel.resolvePassword()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Password error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Check if any output directories already exist and are non-empty
        let fm = FileManager.default
        var existingDirs: [String] = []
        for url in urls {
            let outputDir = url.deletingPathExtension()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: outputDir.path, isDirectory: &isDir) && isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(atPath: outputDir.path), !contents.isEmpty {
                    existingDirs.append(outputDir.lastPathComponent)
                }
            }
        }
        if !existingDirs.isEmpty && !forceOverwrite {
            let alert = NSAlert()
            alert.messageText = "Overwrite existing files?"
            if existingDirs.count == 1 {
                alert.informativeText = "'\(existingDirs[0])' already exists and is not empty."
            } else {
                alert.informativeText = "\(existingDirs.count) output directories already exist and are not empty:\n\(existingDirs.prefix(5).joined(separator: ", "))\(existingDirs.count > 5 ? "..." : "")"
            }
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        statusLabel.stringValue = "Extracting..."
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        dropZone.setEnabled(false)

        let startTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var successCount = 0
            var totalArchiveSize: UInt64 = 0
            var totalExtractedSize: UInt64 = 0
            let total = urls.count

            for (i, url) in urls.enumerated() {
                let outputDir = url.deletingPathExtension()

                // Track archive size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? UInt64 {
                    totalArchiveSize += size
                }

                do {
                    try BlarBridge.extractArchive(
                        archivePath: url,
                        outputDir: outputDir,
                        password: password,
                        progress: { fraction in
                            let overall = (Double(i) + fraction) / Double(total)
                            self?.progressBar.doubleValue = overall * 100
                        }
                    )
                    successCount += 1

                    // Calculate extracted size
                    if let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: [.fileSizeKey]) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                totalExtractedSize += UInt64(size)
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Extraction failed"
                        alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
                        alert.alertStyle = .critical
                        alert.runModal()
                    }
                }
            }

            DispatchQueue.main.async {
                if successCount > 0 {
                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                    let archStr = Self.formatSize(totalArchiveSize)
                    let extStr = Self.formatSize(totalExtractedSize)
                    let label = successCount == 1 ? urls[0].deletingPathExtension().lastPathComponent : "\(successCount) archive(s)"
                    let mbPerSec = elapsed > 0 ? Double(totalExtractedSize) / 1024.0 / 1024.0 / elapsed : 0
                    let timeStr = elapsed < 60 ? String(format: "%.1fs", elapsed) : String(format: "%dm%02ds", Int(elapsed) / 60, Int(elapsed) % 60)
                    let statusMsg = "Extracted \(label) (\(archStr) → \(extStr)) in \(timeStr) (\(String(format: "%.1f", mbPerSec)) MB/s)"
                    self?.statusLabel.stringValue = statusMsg
                    self?.reportStats(statusMsg)
                } else {
                    self?.statusLabel.stringValue = "Extraction failed"
                    self?.reportStats("Extraction failed")
                }
                self?.progressBar.isHidden = true
                self?.dropZone.setEnabled(true)
                self?.autoQuitIfNeeded()
            }
        }
    }
}

// MARK: - Drop Zone View

class DropZoneView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var isDragging = false
    private var label: NSTextField!
    private var iconView: NSImageView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.separatorColor.cgColor

        registerForDraggedTypes([.fileURL])

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop files")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.unregisterDraggedTypes()  // let drags pass through to parent
        addSubview(iconView)

        label = NSTextField(labelWithString: "Drop files or folders here")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: 16, weight: .medium)
        addSubview(label)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
        ])
    }

    func setEnabled(_ enabled: Bool) {
        alphaValue = enabled ? 1.0 : 0.5
        if enabled {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    // Ensure the drop zone captures all drag events, even over child views
    override func hitTest(_ point: NSPoint) -> NSView? {
        return self.bounds.contains(point) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragging = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragging = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragging = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = nil

        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        onDrop?(items)
        return true
    }
}
