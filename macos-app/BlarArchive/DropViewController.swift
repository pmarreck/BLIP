import Cocoa

class DropViewController: NSViewController {
    private var dropZone: DropZoneView!
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var optionsPanel: OptionsPanel!
    private var optionsContainer: NSView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

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
            // Options panel: right side, full height
            optionsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            optionsContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            optionsContainer.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -8),
            optionsContainer.widthAnchor.constraint(equalToConstant: 180),

            // Drop zone: fills remaining space
            dropZone.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            dropZone.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            dropZone.trailingAnchor.constraint(equalTo: optionsContainer.leadingAnchor, constant: -8),
            dropZone.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            // Status label: above progress bar
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: progressBar.topAnchor, constant: -4),

            // Progress bar: bottom
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            progressBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            progressBar.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    func handleDroppedURLs(_ urls: [URL]) {
        // Determine mode: if all are .blar files → extract, otherwise → create
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

    private func createArchive(from urls: [URL]) {
        let options = optionsPanel.currentOptions

        // Determine output path
        let firstURL = urls[0]
        let baseName: String
        if urls.count == 1 {
            baseName = firstURL.deletingPathExtension().lastPathComponent
        } else {
            baseName = firstURL.deletingLastPathComponent().lastPathComponent
        }
        let outputDir = firstURL.deletingLastPathComponent()
        let outputPath = outputDir.appendingPathComponent(baseName + ".blar")

        // Check for overwrite
        if FileManager.default.fileExists(atPath: outputPath.path) {
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

        statusLabel.stringValue = "Creating archive..."
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        dropZone.setEnabled(false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try BlarBridge.createArchive(
                    paths: urls,
                    outputPath: outputPath,
                    compression: options.compression,
                    solid: options.solid,
                    encryption: options.encryption,
                    password: options.password,
                    expandContainers: options.expandContainers,
                    threads: 0,
                    progress: { fraction in
                        self?.progressBar.doubleValue = fraction * 100
                    }
                )
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Created \(outputPath.lastPathComponent)"
                    self?.progressBar.doubleValue = 100
                    self?.dropZone.setEnabled(true)

                    // Reset after delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.statusLabel.stringValue = "Drop files to archive, or drop .blar to extract"
                        self?.progressBar.isHidden = true
                        self?.progressBar.doubleValue = 0
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Error: \(error.localizedDescription)"
                    self?.progressBar.isHidden = true
                    self?.dropZone.setEnabled(true)
                }
            }
        }
    }

    private func extractFiles(_ urls: [URL]) {
        statusLabel.stringValue = "Extracting..."
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        dropZone.setEnabled(false)

        let password = optionsPanel.currentOptions.password

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var successCount = 0
            let total = urls.count

            for (i, url) in urls.enumerated() {
                let outputDir = url.deletingPathExtension()
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
                self?.statusLabel.stringValue = "Extracted \(successCount) archive(s)"
                self?.progressBar.doubleValue = 100
                self?.dropZone.setEnabled(true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self?.statusLabel.stringValue = "Drop files to archive, or drop .blar to extract"
                    self?.progressBar.isHidden = true
                    self?.progressBar.doubleValue = 0
                }
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

        // Icon
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop files")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
        iconView.contentTintColor = .tertiaryLabelColor
        addSubview(iconView)

        // Label
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
