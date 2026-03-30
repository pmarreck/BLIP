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
                // Don't resolve aliases/symlinks — treat them as regular files
                if let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey],
                    options: [.producesRelativePathURLs]
                ) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let fullURL = url.appendingPathComponent(fileURL.relativePath)
                        let relPath = url.lastPathComponent + "/" + fileURL.relativePath
                        allFiles.append((relPath, fullURL))
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
                // Read raw file data (don't resolve aliases — read the alias file itself)
                let fileData: Data
                do {
                    // Use POSIX open to avoid alias resolution
                    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                    if fd >= 0 {
                        defer { close(fd) }
                        var st = stat()
                        fstat(fd, &st)
                        let size = Int(st.st_size)
                        if size > 0 {
                            var buf = Data(count: size)
                            let bytesRead = buf.withUnsafeMutableBytes { ptr in
                                read(fd, ptr.baseAddress!, size)
                            }
                            fileData = bytesRead > 0 ? Data(buf.prefix(bytesRead)) : Data()
                        } else {
                            fileData = Data()
                        }
                    } else {
                        // Fallback for files that can't be opened with O_NOFOLLOW
                        fileData = try Data(contentsOf: url, options: .mappedIfSafe)
                    }
                } catch {
                    NSLog("Warning: skipping unreadable file '%@': %@", url.path, error.localizedDescription)
                    continue
                }
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

                // Read xattrs and resource fork
                var xattrs: UnsafeMutablePointer<blip_xattr_entry>? = nil
                var xattrCount: Int = 0
                var rfork: UnsafeMutablePointer<UInt8>? = nil
                var rforkLen: Int = 0
                blar_gui_read_xattrs(url.path, &xattrs, &xattrCount, &rfork, &rforkLen)
                if xattrCount > 0 {
                    entry.xattrs = UnsafePointer(xattrs)
                    entry.xattr_count = xattrCount
                }
                if rforkLen > 0 {
                    entry.resource_fork = UnsafePointer(rfork)
                    entry.resource_fork_len = rforkLen
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

        // Free xattr/resource fork data now that entries are serialized
        for entry in entries {
            if entry.xattr_count > 0 || entry.resource_fork_len > 0 {
                blar_gui_free_xattrs(
                    UnsafeMutablePointer(mutating: entry.xattrs),
                    entry.xattr_count,
                    UnsafeMutablePointer(mutating: entry.resource_fork)
                )
            }
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

    /// Build a codec registry with just names (for extraction dispatch).
    /// The extraction code only uses codec->name for strcmp dispatch,
    /// not the expand/collapse function pointers.
    private static var extractionCodecs: [blar_codec_t] = {
        var codecs: [blar_codec_t] = []
        // Static strings that live for the process lifetime
        for name in ["jpeg", "pdf", "png", "zip"] {
            var codec = blar_codec_t()
            memset(&codec, 0, MemoryLayout<blar_codec_t>.size)
            // name must be a C string pointer that outlives the codec
            name.withCString { ptr in
                codec.name = UnsafePointer(strdup(ptr))
            }
            codecs.append(codec)
        }
        return codecs
    }()

    /// Extract a blar archive to a directory via direct C FFI.
    static func extractArchive(
        archivePath: URL,
        outputDir: URL,
        password: String? = nil,
        progress: @escaping ProgressCallback
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Read archive file
        let archiveData = try Data(contentsOf: archivePath)

        // Handle decryption if needed
        var buf: UnsafeMutablePointer<UInt8>? = nil
        var bufLen: Int = 0

        let needsDecrypt = archiveData.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return blip_is_encrypted(base, archiveData.count)
        }

        let needsDecompress: Bool
        var workingData = archiveData

        if needsDecrypt {
            guard let pw = password else {
                throw BlarError.extractFailed("Archive is encrypted — password required")
            }
            var decBuf: UnsafeMutablePointer<UInt8>? = nil
            var decLen: Int = 0
            let rc = workingData.withUnsafeBytes { ptr -> Int32 in
                let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return pw.withCString { pwPtr in
                    blip_decrypt_container(base, workingData.count, pwPtr, pw.utf8.count, &decBuf, &decLen)
                }
            }
            if rc != 0 {
                throw BlarError.extractFailed("Decryption failed: \(String(cString: blip_error_string(rc)))")
            }
            workingData = Data(bytes: decBuf!, count: decLen)
            blip_free(decBuf, decLen)
        }

        needsDecompress = workingData.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            return blip_is_compressed(base, workingData.count)
        }

        if needsDecompress {
            var decBuf: UnsafeMutablePointer<UInt8>? = nil
            var decLen: Int = 0
            let rc = workingData.withUnsafeBytes { ptr -> Int32 in
                let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return blip_decompress_container(base, workingData.count, &decBuf, &decLen)
            }
            if rc != 0 {
                throw BlarError.extractFailed("Decompression failed: \(String(cString: blip_error_string(rc)))")
            }
            workingData = Data(bytes: decBuf!, count: decLen)
            blip_free(decBuf, decLen)
        }

        // Progress bridge
        let progressBridge = ProgressBridge(callback: progress, totalBytes: UInt64(workingData.count))
        let bridgePtr = Unmanaged.passRetained(progressBridge).toOpaque()

        let extractProgressFn: @convention(c) (UInt64, UInt64, UInt64, UInt64, UnsafeMutableRawPointer?) -> Void = {
            filesDone, _, totalFiles, _, ctx in
            guard let ctx = ctx else { return }
            let bridge = Unmanaged<ProgressBridge>.fromOpaque(ctx).takeUnretainedValue()
            let fraction = totalFiles > 0 ? Double(filesDone) / Double(totalFiles) : 0
            DispatchQueue.main.async {
                bridge.callback(min(fraction, 1.0))
            }
        }

        let extractLogFn: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = {
            msg, _ in
            if let msg = msg {
                NSLog("BLAR Extract: %@", String(cString: msg))
            }
        }

        // Call the C FFI extraction function with codec registry
        let result = extractionCodecs.withUnsafeMutableBufferPointer { codecsBuf -> Int32 in
            workingData.withUnsafeBytes { dataBuf -> Int32 in
                let base = dataBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return blar_gui_extract(
                    base, workingData.count,
                    outputDir.path,
                    codecsBuf.baseAddress!, codecsBuf.count,
                    extractProgressFn,
                    extractLogFn,
                    bridgePtr
                )
            }
        }

        Unmanaged<ProgressBridge>.fromOpaque(bridgePtr).release()

        if result != 0 {
            throw BlarError.extractFailed("Extraction failed with code \(result)")
        }

        DispatchQueue.main.async { progress(1.0) }
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
