import Cocoa

/// Parsed CLI options (when the app is invoked from the command line)
struct CLIOptions {
    var paths: [URL] = []
    var compression: CompressionAlgo = .lzma2
    var solid: Bool = false
    var encryption: EncryptionAlgo = .none
    var password: String? = nil
    var expandContainers: Bool = true
    var autoQuit: Bool = false   // quit after processing
    var hasOptions: Bool = false // true if any CLI flags were given
}

func parseCLIOptions() -> CLIOptions {
    var opts = CLIOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    var i = 0

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-z", "--compress":
            opts.hasOptions = true
            // Check for optional algorithm argument
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                switch args[i].lowercased() {
                case "lz4":    opts.compression = .lz4
                case "zstd":   opts.compression = .zstd
                case "lzma2", "7zip", "7z": opts.compression = .lzma2
                case "none":   opts.compression = .none
                default:       opts.compression = .lzma2
                }
            } else {
                opts.compression = .lzma2
            }
        case "--no-compress":
            opts.hasOptions = true
            opts.compression = .none
        case "--solid":
            opts.hasOptions = true
            opts.solid = true
        case "-e", "--encrypt":
            opts.hasOptions = true
            if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                i += 1
                switch args[i].lowercased() {
                case "aes", "aes-256":    opts.encryption = .aes
                case "chacha", "chacha20": opts.encryption = .chacha
                default:                   opts.encryption = .aes
                }
            } else {
                opts.encryption = .aes
            }
        case "-p", "--password":
            opts.hasOptions = true
            if i + 1 < args.count {
                i += 1
                opts.password = args[i]
            }
        case "--no-expand":
            opts.hasOptions = true
            opts.expandContainers = false
        case "--auto-quit", "-q":
            opts.autoQuit = true
        case "-h", "--help":
            fputs("""
            Usage: BlarArchive [options] [paths...]

            Options:
              -z [algo]        Compression: lzma2 (default), zstd, lz4, none
              --no-compress    No compression
              --solid          Solid mode (better ratio, slower random access)
              -e [cipher]      Encrypt: aes (default), chacha
              -p <password>    Password (or $ENV_VAR)
              --no-expand      Don't expand containers (PDF/PNG/JPEG/ZIP)
              -q, --auto-quit  Quit after processing (for scripting)
              -h, --help       Show this help

            If paths are given, processing starts immediately.
            If -q is given, the app quits after completion and prints
            stats to stderr.

            """, stderr)
            exit(0)
        default:
            if !arg.hasPrefix("-") {
                opts.paths.append(URL(fileURLWithPath: arg))
            } else {
                fputs("Unknown option: \(arg)\n", stderr)
            }
        }
        i += 1
    }

    if !opts.paths.isEmpty {
        opts.hasOptions = true
    }

    return opts
}

let cliOptions = parseCLIOptions()

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.cliOptions = cliOptions

if !cliOptions.paths.isEmpty {
    delegate.pendingURLs = cliOptions.paths
}

app.delegate = delegate
app.run()
