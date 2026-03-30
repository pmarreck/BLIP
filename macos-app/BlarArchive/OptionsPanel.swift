import Cocoa

struct ArchiveOptions {
    var compression: CompressionAlgo
    var solid: Bool
    var encryption: EncryptionAlgo
    var password: String?
    var expandContainers: Bool
}

class OptionsPanel: NSViewController {
    private var compressionPopup: NSPopUpButton!
    private var solidCheckbox: NSButton!
    private var encryptionPopup: NSPopUpButton!
    private var passwordField: NSSecureTextField!
    private var expandCheckbox: NSButton!

    var currentOptions: ArchiveOptions {
        return ArchiveOptions(
            compression: CompressionAlgo(rawValue: UInt8(compressionPopup.indexOfSelectedItem)) ?? .none,
            solid: solidCheckbox.state == .on,
            encryption: EncryptionAlgo(rawValue: UInt8(encryptionPopup.indexOfSelectedItem)) ?? .none,
            password: passwordField.stringValue.isEmpty ? nil : passwordField.stringValue,
            expandContainers: expandCheckbox.state == .on
        )
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Section header
        let header = NSTextField(labelWithString: "Options")
        header.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(header)

        // Compression
        let compLabel = NSTextField(labelWithString: "Compression:")
        compLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(compLabel)

        compressionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        compressionPopup.addItems(withTitles: ["None", "LZMA2", "bzip2", "LZ4", "zstd"])
        compressionPopup.selectItem(at: 1) // Default: LZMA2
        compressionPopup.controlSize = .small
        compressionPopup.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(compressionPopup)

        // Solid mode
        solidCheckbox = NSButton(checkboxWithTitle: "Solid mode", target: nil, action: nil)
        solidCheckbox.controlSize = .small
        solidCheckbox.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(solidCheckbox)

        // Separator
        let sep1 = NSBox()
        sep1.boxType = .separator
        stack.addArrangedSubview(sep1)
        sep1.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Encryption
        let encLabel = NSTextField(labelWithString: "Encryption:")
        encLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(encLabel)

        encryptionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        encryptionPopup.addItems(withTitles: ["None", "AES-256", "ChaCha20"])
        encryptionPopup.selectItem(at: 0)
        encryptionPopup.controlSize = .small
        encryptionPopup.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(encryptionPopup)

        let pwLabel = NSTextField(labelWithString: "Password:")
        pwLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(pwLabel)

        passwordField = NSSecureTextField()
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.controlSize = .small
        passwordField.font = .systemFont(ofSize: 11)
        passwordField.placeholderString = "Enter password"
        stack.addArrangedSubview(passwordField)
        passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        stack.addArrangedSubview(sep2)
        sep2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Container expansion
        expandCheckbox = NSButton(checkboxWithTitle: "Expand containers", target: nil, action: nil)
        expandCheckbox.state = .on
        expandCheckbox.controlSize = .small
        expandCheckbox.font = .systemFont(ofSize: 11)
        expandCheckbox.toolTip = "Decompose PDF/PNG/JPEG/ZIP for better compression"
        stack.addArrangedSubview(expandCheckbox)
    }
}
