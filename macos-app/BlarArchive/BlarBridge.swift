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
    /// Uses blar_gui_create which handles file collection, container expansion,
    /// metadata/xattr preservation, and archive serialization via the C layer.
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
        // Convert URLs to C string paths
        let pathStrings = paths.map { $0.path }
        let perFileComp = solid ? UInt8(0) : compression.rawValue

        var archiveBuf: UnsafeMutablePointer<UInt8>? = nil
        var archiveLen: Int = 0

        // Call C layer which does: collect entries → expand containers → create archive
        let rc: Int32 = pathStrings.withCStringArray { cPaths in
            return blar_gui_create(
                cPaths, paths.count,
                perFileComp, threads,
                expandContainers, false, // expand_all_zips = false
                nil, nil, // progress (TODO: wire up)
                &archiveBuf, &archiveLen
            )
        }

        if rc != 0 {
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
                nil, nil, nil,
                &compBuf, &compLen
            )
            blip_free(archiveBuf, archiveLen)
            if compRc != 0 {
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
                throw BlarError.encryptionFailed(encRc)
            }
            finalBuf = encBuf
            finalLen = encLen
        }

        // Write to disk
        guard let data = finalBuf else {
            throw BlarError.writeFailed("No archive data")
        }
        let archiveData = Data(bytes: data, count: finalLen)
        blip_free(finalBuf, finalLen)

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

/// Helper: convert [String] to C string array for FFI calls
extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let cStrings = self.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        return cStrings.withUnsafeBufferPointer { buf in
            // Cast UnsafeMutablePointer<CChar>? array to UnsafePointer<CChar>? array
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: cStrings.count) { ptr in
                body(ptr)
            }
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
