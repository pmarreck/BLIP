import Foundation

enum BlarError: Error {
    case createFailed(Int32)
    case extractFailed(String)
    case compressionFailed(Int32)
    case encryptionFailed(Int32)
    case readFailed(String)
    case writeFailed(String)
}

enum CompressionAlgo: UInt8 {
    case none = 0
    case lzma2 = 1
    case bzip2 = 2
    case lz4 = 3
    case zstd = 4
}

enum EncryptionAlgo: UInt8 {
    case none = 0
    case aes = 1
    case chacha = 2
}

/// Progress callback type: (fractionComplete: 0.0-1.0)
typealias ProgressCallback = (Double) -> Void

/// Swift wrapper around libblip C FFI for archive creation and extraction.
class BlarBridge {

    /// Create a blar archive from the given file/directory paths.
    static func createArchive(
        paths: [URL],
        outputPath: URL,
        compression: CompressionAlgo = .none,
        solid: Bool = false,
        encryption: EncryptionAlgo = .none,
        password: String? = nil,
        expandContainers: Bool = true,
        threads: UInt8 = 0,
        progress: @escaping ProgressCallback
    ) throws {
        // Collect all files (recursing directories)
        var allFiles: [(path: String, url: URL)] = []
        let fm = FileManager.default
        for url in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let relPath = fileURL.path.replacingOccurrences(of: url.deletingLastPathComponent().path + "/", with: "")
                        allFiles.append((relPath, fileURL))
                    }
                }
            } else {
                allFiles.append((url.lastPathComponent, url))
            }
        }

        // Build entry array
        var entries: [blip_archive_entry] = []
        var contentBuffers: [Data] = [] // keep data alive

        for (path, url) in allFiles {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)

            var entry = blip_archive_entry()
            // Zero all fields
            memset(&entry, 0, MemoryLayout<blip_archive_entry>.size)
            entry.pdf_stream_offset = UInt64.max
            entry.pdf_stream_length = UInt64.max
            entry.zip_compression_method = 0xFFFF

            if isDir.boolValue {
                let dirPath = path.hasSuffix("/") ? path : path + "/"
                let pathData = dirPath.data(using: .utf8)!
                contentBuffers.append(pathData)
                pathData.withUnsafeBytes { ptr in
                    entry.path = ptr.baseAddress!.assumingMemoryBound(to: CChar.self)
                    entry.path_len = pathData.count
                }
                entry.is_dir = 1

                // Get directory metadata
                if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                    entry.mode = UInt16((attrs[.posixPermissions] as? Int) ?? 0o755)
                    if let mtime = attrs[.modificationDate] as? Date {
                        entry.mtime_ns = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
                    }
                }
                entries.append(entry)
            } else {
                let pathData = path.data(using: .utf8)!
                contentBuffers.append(pathData)
                let fileData = try Data(contentsOf: url)
                contentBuffers.append(fileData)

                pathData.withUnsafeBytes { pathPtr in
                    entry.path = pathPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
                    entry.path_len = pathData.count
                }
                fileData.withUnsafeBytes { contentPtr in
                    entry.content = contentPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    entry.content_len = fileData.count
                }
                entry.is_dir = 0

                if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                    entry.mode = UInt16((attrs[.posixPermissions] as? Int) ?? 0o644)
                    if let mtime = attrs[.modificationDate] as? Date {
                        entry.mtime_ns = Int64(mtime.timeIntervalSince1970 * 1_000_000_000)
                    }
                }
                entries.append(entry)
            }
        }

        // Progress bridge
        let progressBridge = ProgressBridge(callback: progress, totalBytes: UInt64(allFiles.count))
        let bridgePtr = Unmanaged.passRetained(progressBridge).toOpaque()

        let progressFn: @convention(c) (UInt64, UInt64, UnsafeMutableRawPointer?) -> Void = { done, total, ctx in
            guard let ctx = ctx else { return }
            let bridge = Unmanaged<ProgressBridge>.fromOpaque(ctx).takeUnretainedValue()
            let fraction = bridge.totalBytes > 0 ? Double(done) / Double(bridge.totalBytes) : 0
            DispatchQueue.main.async {
                bridge.callback(min(fraction, 1.0))
            }
        }

        // Create archive
        var archiveBuf: UnsafeMutablePointer<UInt8>? = nil
        var archiveLen: Int = 0
        let perFileComp = solid ? UInt8(0) : compression.rawValue

        let flags: UInt32 = expandContainers ? 0 : 0x04 // BLIP_ARCHIVE_NO_EXPAND_CONTAINERS

        let entryCount = entries.count
        let rc = entries.withUnsafeMutableBufferPointer { entriesPtr -> Int32 in
            return blip_archive_create_full(
                entriesPtr.baseAddress,
                entryCount,
                flags,
                perFileComp,
                threads,
                progressFn,
                nil,  // phase callback
                bridgePtr,
                &archiveBuf,
                &archiveLen
            )
        }

        if rc != 0 { // BLIP_OK = 0
            Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()
            throw BlarError.createFailed(rc)
        }

        // Solid compression
        var finalBuf = archiveBuf
        var finalLen = archiveLen
        if solid && compression != .none {
            var compBuf: UnsafeMutablePointer<UInt8>? = nil
            var compLen: Int = 0
            let compRc = blip_compress_container(
                archiveBuf, archiveLen,
                compression.rawValue, threads,
                progressFn, nil, bridgePtr,
                &compBuf, &compLen
            )
            blip_free(archiveBuf, archiveLen)
            if compRc != 0 {
                Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()
                throw BlarError.compressionFailed(compRc)
            }
            finalBuf = compBuf
            finalLen = compLen
        }

        // Encryption
        if encryption != .none, let pw = password {
            var encBuf: UnsafeMutablePointer<UInt8>? = nil
            var encLen: Int = 0
            let encRc = pw.withCString { pwPtr -> Int32 in
                return blip_encrypt_container(
                    finalBuf, finalLen,
                    pwPtr, pw.utf8.count,
                    encryption.rawValue,
                    0, // default KDF (argon2)
                    &encBuf, &encLen
                )
            }
            blip_free(finalBuf, finalLen)
            if encRc != 0 {
                Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()
                throw BlarError.encryptionFailed(encRc)
            }
            finalBuf = encBuf
            finalLen = encLen
        }

        // Write to disk
        guard let data = finalBuf else {
            Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()
            throw BlarError.writeFailed("No archive data")
        }
        let archiveData = Data(bytes: data, count: finalLen)
        blip_free(finalBuf, finalLen)
        Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()

        try archiveData.write(to: outputPath)
        DispatchQueue.main.async { progress(1.0) }
    }

    /// Extract a blar archive to a directory.
    /// For now, shells out to the blar CLI. Will be replaced with direct FFI
    /// once extraction logic is factored into the Zig core.
    static func extractArchive(
        archivePath: URL,
        outputDir: URL,
        password: String? = nil,
        progress: @escaping ProgressCallback
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Use blar CLI for extraction (container reconstruction is complex)
        // TODO: Replace with direct FFI call to blip_extract_archive()
        let args = ["extract", archivePath.path, "-f", "-C", outputDir.path]
        if let pw = password {
            setenv("BLIP_PASSWORD", pw, 1)
        }

        // Look for blar in bundle first, then PATH
        let blarPath: String = Bundle.main.path(forResource: "blar", ofType: nil)
            ?? {
                if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
                    for dir in pathEnv.split(separator: ":") {
                        let p = "\(dir)/blar"
                        if fm.isExecutableFile(atPath: p) { return p }
                    }
                }
                return "/usr/local/bin/blar"
            }()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blarPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        // Poll for completion (simple progress simulation)
        DispatchQueue.global().async {
            var tick = 0.0
            while process.isRunning {
                tick = min(tick + 0.02, 0.95)
                DispatchQueue.main.async { progress(tick) }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async { progress(1.0) }
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw BlarError.extractFailed(errorStr)
        }
    }
}

/// Helper class to bridge C callbacks to Swift closures.
class ProgressBridge {
    let callback: ProgressCallback
    let totalBytes: UInt64

    init(callback: @escaping ProgressCallback, totalBytes: UInt64) {
        self.callback = callback
        self.totalBytes = totalBytes
    }
}
