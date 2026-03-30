import Cocoa
import Security

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
    private var passwordPlainField: NSTextField!  // visible twin for peek
    private var peekButton: NSButton!
    private var expandCheckbox: NSButton!
    private var isPasswordVisible = false

    // Maps dropdown index to CompressionAlgo:
    //   0 = None, 1 = LZ4, 2 = zstd, 3 = 7zip (LZMA2)
    private static let compressionMap: [CompressionAlgo] = [.none, .lz4, .zstd, .lzma2]

    // UserDefaults keys
    private static let kCompression = "compressionIndex"
    private static let kSolid = "solidMode"
    private static let kEncryption = "encryptionIndex"
    private static let kExpand = "expandContainers"

    // Keychain service name
    private static let keychainService = "com.mecha.BlarArchive"
    private static let keychainAccount = "archivePassword"

    var currentOptions: ArchiveOptions {
        return ArchiveOptions(
            compression: Self.compressionMap[compressionPopup.indexOfSelectedItem],
            solid: solidCheckbox.state == .on,
            encryption: EncryptionAlgo(rawValue: UInt8(encryptionPopup.indexOfSelectedItem)) ?? .none,
            password: resolvedPassword,
            expandContainers: expandCheckbox.state == .on
        )
    }

    /// Resolve password: if it looks like $ENV_VAR_NAME, read from environment
    private var resolvedPassword: String? {
        let raw = isPasswordVisible ? passwordPlainField.stringValue : passwordField.stringValue
        if raw.isEmpty { return nil }
        // Check for environment variable reference: $CAPS_AND_UNDERSCORES
        if raw.hasPrefix("$") {
            let varName = String(raw.dropFirst())
            if !varName.isEmpty && varName.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) {
                if let envVal = ProcessInfo.processInfo.environment[varName] {
                    return envVal
                }
                // Env var not set — return nil rather than using the literal "$VAR" as password
                return nil
            }
        }
        return raw
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        restoreSettings()
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
        compressionPopup.selectItem(at: 3)
        compressionPopup.controlSize = .small
        compressionPopup.font = .systemFont(ofSize: 11)
        compressionPopup.target = self
        compressionPopup.action = #selector(settingsChanged)

        compressionPopup.item(at: 0)?.toolTip = "No compression — fastest, largest files"
        compressionPopup.item(at: 1)?.toolTip = "LZ4 — extremely fast compression and decompression, lower ratio. Good for temporary or local archives."
        compressionPopup.item(at: 2)?.toolTip = "Zstandard — near-best compression ratio at much faster speed than 7zip. Great default for most use cases."
        compressionPopup.item(at: 3)?.toolTip = "LZMA2 (7-Zip algorithm) — best compression ratio, slower to compress. Best for archival or sharing."

        stack.addArrangedSubview(compressionPopup)

        // Solid mode
        solidCheckbox = NSButton(checkboxWithTitle: "Solid mode", target: self, action: #selector(settingsChanged))
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
        encryptionPopup.target = self
        encryptionPopup.action = #selector(settingsChanged)

        encryptionPopup.item(at: 0)?.toolTip = "No encryption — anyone with the file can read it"
        encryptionPopup.item(at: 1)?.toolTip = "AES-256-GCM — industry standard, hardware-accelerated on most CPUs. Uses Argon2id for key derivation."
        encryptionPopup.item(at: 2)?.toolTip = "ChaCha20-Poly1305 — constant-time on all platforms, no hardware acceleration needed. Uses Argon2id for key derivation."

        stack.addArrangedSubview(encryptionPopup)

        let pwLabel = NSTextField(labelWithString: "Password:")
        pwLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(pwLabel)

        // Password field container (field + peek button)
        let pwContainer = NSView()
        pwContainer.translatesAutoresizingMaskIntoConstraints = false

        // Secure field (default)
        passwordField = NSSecureTextField()
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.controlSize = .small
        passwordField.font = .systemFont(ofSize: 11)
        passwordField.placeholderString = "password or $ENV_VAR"
        passwordField.target = self
        passwordField.action = #selector(passwordChanged)
        pwContainer.addSubview(passwordField)

        // Plain text field (for peek)
        passwordPlainField = NSTextField()
        passwordPlainField.translatesAutoresizingMaskIntoConstraints = false
        passwordPlainField.controlSize = .small
        passwordPlainField.font = .systemFont(ofSize: 11)
        passwordPlainField.placeholderString = "password or $ENV_VAR"
        passwordPlainField.isHidden = true
        passwordPlainField.target = self
        passwordPlainField.action = #selector(passwordChanged)
        pwContainer.addSubview(passwordPlainField)

        // Peek button
        peekButton = NSButton()
        peekButton.translatesAutoresizingMaskIntoConstraints = false
        peekButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
        peekButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        peekButton.isBordered = false
        peekButton.target = self
        peekButton.action = #selector(togglePasswordVisibility)
        peekButton.toolTip = "Show/hide password"
        pwContainer.addSubview(peekButton)

        NSLayoutConstraint.activate([
            passwordField.leadingAnchor.constraint(equalTo: pwContainer.leadingAnchor),
            passwordField.topAnchor.constraint(equalTo: pwContainer.topAnchor),
            passwordField.bottomAnchor.constraint(equalTo: pwContainer.bottomAnchor),
            passwordField.trailingAnchor.constraint(equalTo: peekButton.leadingAnchor, constant: -2),

            passwordPlainField.leadingAnchor.constraint(equalTo: pwContainer.leadingAnchor),
            passwordPlainField.topAnchor.constraint(equalTo: pwContainer.topAnchor),
            passwordPlainField.bottomAnchor.constraint(equalTo: pwContainer.bottomAnchor),
            passwordPlainField.trailingAnchor.constraint(equalTo: peekButton.leadingAnchor, constant: -2),

            peekButton.trailingAnchor.constraint(equalTo: pwContainer.trailingAnchor),
            peekButton.centerYAnchor.constraint(equalTo: pwContainer.centerYAnchor),
            peekButton.widthAnchor.constraint(equalToConstant: 20),

            pwContainer.heightAnchor.constraint(equalToConstant: 22),
        ])

        stack.addArrangedSubview(pwContainer)
        pwContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        stack.addArrangedSubview(sep2)
        sep2.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Container expansion
        expandCheckbox = NSButton(checkboxWithTitle: "Expand containers", target: self, action: #selector(settingsChanged))
        expandCheckbox.state = .on
        expandCheckbox.controlSize = .small
        expandCheckbox.font = .systemFont(ofSize: 11)
        expandCheckbox.toolTip = "Decompose PDFs, JPEGs, PNGs, and ZIP-based files (Office docs, EPUBs) into their parts for significantly better compression. Files are perfectly reconstructed on extraction."
        stack.addArrangedSubview(expandCheckbox)
    }

    // MARK: - Password visibility toggle

    @objc private func togglePasswordVisibility() {
        isPasswordVisible.toggle()
        if isPasswordVisible {
            passwordPlainField.stringValue = passwordField.stringValue
            passwordField.isHidden = true
            passwordPlainField.isHidden = false
            peekButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Hide password")
            passwordPlainField.becomeFirstResponder()
        } else {
            passwordField.stringValue = passwordPlainField.stringValue
            passwordPlainField.isHidden = true
            passwordField.isHidden = false
            peekButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Show password")
            passwordField.becomeFirstResponder()
        }
    }

    // MARK: - Settings persistence

    @objc private func settingsChanged() {
        saveSettings()
    }

    @objc private func passwordChanged() {
        // Sync between secure and plain fields
        if isPasswordVisible {
            passwordField.stringValue = passwordPlainField.stringValue
        } else {
            passwordPlainField.stringValue = passwordField.stringValue
        }
        savePassword()
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(compressionPopup.indexOfSelectedItem, forKey: Self.kCompression)
        defaults.set(solidCheckbox.state == .on, forKey: Self.kSolid)
        defaults.set(encryptionPopup.indexOfSelectedItem, forKey: Self.kEncryption)
        defaults.set(expandCheckbox.state == .on, forKey: Self.kExpand)
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard

        if let comp = defaults.object(forKey: Self.kCompression) as? Int {
            compressionPopup.selectItem(at: min(comp, compressionPopup.numberOfItems - 1))
        }
        solidCheckbox.state = defaults.bool(forKey: Self.kSolid) ? .on : .off
        if let enc = defaults.object(forKey: Self.kEncryption) as? Int {
            encryptionPopup.selectItem(at: min(enc, encryptionPopup.numberOfItems - 1))
        }
        // expandContainers defaults to true if not set
        if defaults.object(forKey: Self.kExpand) != nil {
            expandCheckbox.state = defaults.bool(forKey: Self.kExpand) ? .on : .off
        }

        // Restore password from Keychain
        if let pw = loadPassword() {
            passwordField.stringValue = pw
            passwordPlainField.stringValue = pw
        }
    }

    // MARK: - Keychain password storage

    private func savePassword() {
        let pw = isPasswordVisible ? passwordPlainField.stringValue : passwordField.stringValue

        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Save new password (if non-empty)
        guard !pw.isEmpty, let data = pw.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
