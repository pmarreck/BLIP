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

    // Maps dropdown index to CompressionAlgo:
    //   0 = None, 1 = LZ4, 2 = zstd, 3 = 7zip (LZMA2)
    private static let compressionMap: [CompressionAlgo] = [.none, .lz4, .zstd, .lzma2]

    var currentOptions: ArchiveOptions {
        return ArchiveOptions(
            compression: Self.compressionMap[compressionPopup.indexOfSelectedItem],
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
        compressionPopup.addItems(withTitles: ["None", "Very Fast (LZ4)", "Fast (zstd)", "Best (7zip)"])
        compressionPopup.selectItem(at: 3) // Default: Best (7zip/LZMA2)
        compressionPopup.controlSize = .small
        compressionPopup.font = .systemFont(ofSize: 11)

        // Tooltips for compression options
        compressionPopup.item(at: 0)?.toolTip = "No compression — fastest, largest files"
        compressionPopup.item(at: 1)?.toolTip = "LZ4 — extremely fast compression and decompression, lower ratio. Good for temporary or local archives."
        compressionPopup.item(at: 2)?.toolTip = "Zstandard — near-best compression ratio at much faster speed than 7zip. Great default for most use cases."
        compressionPopup.item(at: 3)?.toolTip = "LZMA2 (7-Zip algorithm) — best compression ratio, slower to compress. Best for archival or sharing."

        stack.addArrangedSubview(compressionPopup)

        // Solid mode
        solidCheckbox = NSButton(checkboxWithTitle: "Solid mode", target: nil, action: nil)
        solidCheckbox.controlSize = .small
        solidCheckbox.font = .systemFont(ofSize: 11)
        solidCheckbox.toolTip = "Compress the entire archive as one block instead of per-file. Better compression ratio for many similar files, but extracting any single file requires decompressing everything."
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

        // Tooltips for encryption options
        encryptionPopup.item(at: 0)?.toolTip = "No encryption — anyone with the file can read it"
        encryptionPopup.item(at: 1)?.toolTip = "AES-256-GCM — industry standard, hardware-accelerated on most CPUs. Uses Argon2id for key derivation."
        encryptionPopup.item(at: 2)?.toolTip = "ChaCha20-Poly1305 — constant-time on all platforms, no hardware acceleration needed. Uses Argon2id for key derivation."

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
        expandCheckbox.toolTip = "Decompose PDFs, JPEGs, PNGs, and ZIP-based files (Office docs, EPUBs) into their parts for significantly better compression. Files are perfectly reconstructed on extraction."
        stack.addArrangedSubview(expandCheckbox)
    }
}
