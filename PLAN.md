# BLIP Implementation Plan

## Completed
- [x] Project scaffolding (flake.nix, build.zig) ~2026-02-22 23:40 EST
- [x] GitHub repo creation (pmarreck/BLIP) ~2026-02-22 23:42 EST
- [x] BLIP core encode/decode with 51 spec-verified tests ~2026-02-22 23:47 EST
- [x] LEB128 + SLEB128 implementation ~2026-02-22 23:55 EST
- [x] Protobuf varint + ZigZag ~2026-02-22 23:58 EST
- [x] ASN.1 BER length encoding ~2026-02-23 00:03 EST
- [x] PrefixVarint encoding ~2026-02-23 00:07 EST
- [x] SQLite varint encoding ~2026-02-23 00:10 EST
- [x] Common encoding interface ~2026-02-23 00:12 EST
- [x] C FFI for BLIP ~2026-02-23 00:20 EST
- [x] CLI entry point through C FFI ~2026-02-23 00:25 EST
- [x] Bignum direct LE arithmetic ~2026-02-23 00:30 EST
- [x] Benchmark suite (throughput, bignum, random-access) ~2026-02-23 00:45 EST
- [x] Fuzz tests ~2026-02-23 01:00 EST
- [x] Project documentation ~2026-02-23 01:05 EST

## Container Library (Completed 2026-02-23)
- [x] `encodedSize` public API on blip.zig
- [x] container_types.zig — ContainerType enum, sentinel mapping
- [x] container.zig — TLV header, self-referential length solver
- [x] leaf.zig — UTF8 + RAW container serialize/parse
- [x] array.zig — ARRAY with fixpoint iteration, index tables, xxHash64
- [x] dict.zig — DICT/FILE with key ordering, interleaved index
- [x] mini_blar.zig — high-level archive API (createArchive, ArchiveReader)
- [x] Container C FFI exports (blip_archive_create, verify, file_count, free)
- [x] 447 tests total (all passing)

## blar CLI (Completed 2026-02-23)
- [x] Typed FFI error codes and blip_error_string
- [x] FFI archive access: file_path, file_content, file_content_by_path, file_verify
- [x] blar C CLI (create/list/extract/verify/info/cat) with progress bar
- [x] Bash integration tests

## blar/miniblar Split + DIR Container (Completed 2026-02-24)
- [x] DIR container type (0x81 0x07) in ContainerType enum
- [x] serializeDir() with path+xh64 required key validation
- [x] DictReader updated to accept .dir type
- [x] DirEntry, ArchiveEntry union, computeMerkleHash
- [x] createFullArchive() with FILE+DIR+metadata support
- [x] ArchiveReader: entryCount, entryAt, entryTypeAt
- [x] C FFI: blip_archive_create_full, entry_type, entry_metadata
- [x] blar_common.h — shared utilities
- [x] miniblar.c — flat file-only CLI (rejects directories)
- [x] blar.c — rewritten for full spec (directory recursion, metadata, Merkle hash)
- [x] build.zig — miniblar target added
- [x] Integration tests: 18 blar tests + 19 miniblar tests (all passing)
- [x] Documentation updates (spec, README, CODE_MINIMAP)

## poke Command (Completed 2026-02-24)
- [x] poke.zig — reconstructEntries (inverse of createFullArchive), pokeArchive
- [x] Path target classification: data_content, metadata_leaf, container (error), immutable (error)
- [x] C FFI: blip_poke export in lib.zig + blip.h
- [x] blar/miniblar CLI: poke command + Kf tar-style flag
- [x] Value input: --value, -i (file), stdin
- [x] Output: in-place (atomic write), -o (different file), --backup (.bak)
- [x] Integration tests: 22 poke tests (all passing)
- [x] All existing tests still pass (141 tests across 5 suites)
- [x] README documentation

## JSON Serialization/Deserialization (Completed 2026-02-25)
- [x] json_serde.zig — archiveToJson, jsonToArchive, timestamp/mode formatting
- [x] High-level structured JSON format (entries array with type/path/content/metadata)
- [x] Printable-binary encoding for binary content in JSON strings
- [x] Merkle hash recomputation for DIR entries on from-json
- [x] C FFI: blip_to_json, blip_from_json exports in lib.zig + blip.h
- [x] blar/miniblar CLI: to-json + from-json commands, j/J tar-style flags
- [x] Full jq integration: content/path/mode/timestamp manipulation, add/remove entries
- [x] Integration tests: 34 JSON tests + 12 Zig unit tests (all passing)
- [x] All existing tests still pass (158 tests across 6 suites)
- [x] README documentation with jq pipeline examples

## v2 LP Container Format Migration (Completed 2026-02-27)
- [x] LP (Length-Payload) envelope replaces old TLV structure
- [x] Sorted attribute sigils: TYPE, COMP, DECOMP_LEN, CSUM, ENC, SIG, VAL
- [x] container_types.zig — AttributeSigil, ContainerTypeId, CompressionId, ChecksumId, EncryptionId, KdfId enums
- [x] container.zig — computeLPLength, writeLPHeader, parseLPHeader
- [x] Per-container LZMA2 compression via COMP attribute (blar create -z)
- [x] Per-container checksums via CSUM attribute (CRC32, xxHash64, BLAKE3-128)
- [x] BLAKE3-128 outer archive integrity + xxHash64 inner containers
- [x] Per-file xxHash64 checksums on FILE/DATA/DIR containers
- [x] Merkle hash auto-computation in createFullArchive
- [x] All existing CLI tools updated for v2 LP format
- [x] Integration tests: 25 LZMA2 tests + 21 binary format tests (all passing)

## Encryption (Completed 2026-02-28)
- [x] EncryptionId (AES-256-GCM, ChaCha20-Poly1305) + KdfId (Argon2id, PBKDF2-SHA256) enums
- [x] ENC attribute sigil (0x13) in LP envelope sort order
- [x] encryption.zig — deriveKey, encrypt, decrypt, encryptContainer, decryptContainer, isEncrypted
- [x] AES-256-GCM + ChaCha20-Poly1305 AEAD ciphers via Zig stdlib
- [x] Argon2id (64 MiB, t=3, p=4) + PBKDF2-SHA256 (600k rounds) key derivation
- [x] C FFI: blip_is_encrypted, blip_encrypt_container, blip_decrypt_container
- [x] blar CLI: `blar create -e` (encrypt), `--kdf` (KDF selection), auto-decrypt on read
- [x] Password from BLIP_PASSWORD env var or interactive prompt on stderr
- [x] Layering: compress → encrypt → checksum (write), checksum → decrypt → decompress (read)
- [x] Integration tests: 14 encryption tests (all passing)
- [x] All existing tests still pass (236 shell tests + all Zig unit tests)

## Transparent Zip Container Expansion (Completed 2026-03-05)
- [x] src/zip.zig — Pure in-memory zip reader/writer (store + deflate)
- [x] "co"/"zc" metadata keys in mini_blar.zig (container_type, zip_compression_method)
- [x] C FFI: blip_is_zip, blip_zip_entry_count/info/extract, blip_zip_create, blip_archive_entry_container_type/zip_comp
- [x] blar create: PK magic detection, container expansion into DIR+FILE entries
- [x] blar extract: 3-pass container re-assembly (skip container dirs, skip children, re-zip)
- [x] CLI flags: --no-expand-containers, --expand-all-zips
- [x] blar list: 'z' prefix for container dirs; info --json: container_type, zip_compression_method
- [x] poke.zig + json_serde.zig: "co"/"zc" roundtrip support
- [x] Fix: flate decompressor panic (direct mode avoids fixed-capacity window overflow)
- [x] Fix: heap corruption in extraction (child_bufs 2x growth rate vs zip_entries)
- [x] 19 container expansion integration tests (all passing)
- [x] All existing tests still pass (27 blar + 144 compression + Zig unit tests)

## Future
- [ ] Arbitrary-width encode/decode (values > u64)
- [ ] Streaming writes with padded BLIPs for containers
- [ ] Cross-language implementations (C, Rust, etc.)
- [ ] Binary data manipulation DSL — extend peek/poke into a full structural editor (insert/delete array elements, add/remove dict keys, splice content, move entries, etc.). Note: JSON interchange (`to-json | jq | from-json`) already covers most high-level manipulation use cases.
- [ ] Segmentation container type — a new top-level container for splitting large archives into fixed-size segments (e.g. for transport over size-limited channels, span across volumes, or resumable transfers)
- [ ] Per-MIME-type zstd dictionaries — When using zstd with per-file compression: (1) group files by MIME type, (2) train a zstd dictionary per group on the fly, (3) store dictionaries in a MAP container within the archive keyed by MIME type, (4) compress each file with its group's dictionary. Dictionary-level compression gains without solid-archive fragility. If a dictionary is corrupted, only its group's files are lost. Design questions: minimum sample threshold for training (zstd recommends 100+ samples), CLI UX (`-z zstd-dict` vs automatic).
- [ ] Archive metadata inspection (`blar info --depth N`) — Rich metadata reporting at the FFI level, exposed through CLI. Reports: compression algorithm(s), encryption algorithm(s), compressed/expanded sizes and ratio, creation date, format version, master checksum and validation status. `--depth` parameter (default: shallow/1) controls how deep to inspect nested containers for additional compression/encryption layers. Encrypted containers remain opaque (with warning) unless password is supplied. All reporting available via C FFI functions (e.g. `blip_archive_info()`) so any consumer can access it, not just the CLI.
- [x] PDF container expansion — PDFs expanded into shell + JPEG/FlateDecode image streams transcoded to JXL. Content streams decompressed for better LZMA2 compression. Byte-identical reconstruction on extraction.
- [x] JPEG XL lossless image recompression — JPEG (~20% smaller) and PNG (~50% smaller) losslessly transcoded to JXL inside expanded containers. Bit-exact roundtrip via libjxl.
- [ ] Per-file compression progress callback — Currently `serializeFileEntry` passes null for the compression progress callback, so large single-file archives show no progress during the compression phase. Thread the progress function through to `compressContainer` for per-file mode.
- [ ] ISO 9660 container expansion — Decompose ISO images into their constituent filesystem (squashfs, UDF, El Torito boot images). For ISOs with uncompressed or weakly-compressed content, this could improve compression. For already-squashfs ISOs (NixOS, Ubuntu), the gain would be minimal.
- [ ] Cross-platform xattr key mapping — On extraction, translate xattr names to the target OS convention (e.g. macOS `com.apple.quarantine` → Linux `user.com.apple.quarantine`, and reverse on re-archiving). Archive stores original names; mapping is extraction-time only. Handle `system.*` xattrs (may require root on Linux), `security.selinux` (skip with warning on macOS).
- [ ] AppleDouble resource fork fallback — When extracting on non-HFS+/APFS filesystems (Linux, Windows, FAT/exFAT), write macOS resource forks as AppleDouble `._filename` sidecar files. On archiving, detect `._filename` sidecars and slurp them back as resource forks. Default behavior on Windows; optional on Linux (`--apple-double` flag). macOS already creates these on non-native filesystems.
## Container Expansion Roadmap

### Audio lossless transcoding
- [x] WAV → FLAC container expansion — Uncompressed PCM → FLAC lossless via libFLAC (zig-pkgs/flac, lazy dep). Compact WAV metadata stores only non-PCM bytes. Byte-identical WAV reconstruction on extraction. 50-60% savings on realistic audio.
- [x] AIFF → FLAC container expansion — Parse AIFF chunks (big-endian PCM), encode to FLAC via libFLAC. BE/LE conversion for FLAC encoding. Byte-identical roundtrip.

### Image lossless transcoding
- [x] BMP → JXL container expansion — Uncompressed raster → JXL lossless (90%+ savings). Parse BMP header (24/32-bit uncompressed), extract pixels to RGB(A), JXL lossless encode. Store original BMP header as metadata for byte-identical reconstruction.
- [x] TIFF → JXL container expansion — Uncompressed raster → JXL lossless (97%+ savings). Parse TIFF IFDs, extract pixel strips, JXL encode. Compact metadata stores only non-pixel bytes. Byte-identical reconstruction.
- [x] GIF → JXL container expansion — Pure Zig GIF parser (LZW decompression), static GIF → RGBA pixels → JXL lossless. Original GIF stored as metadata for byte-identical reconstruction. Expansion typically skipped by size check since GIF is already compressed; value comes from LZMA2 compression of the JXL+palette. Animated GIF deferred (returns error, treated as opaque file).
- [ ] DNG (Digital Negative) container expansion — Extract embedded JPEG preview (→ JXL transcode), decompress deflate-compressed raw sensor data for better LZMA2 compression, preserve TIFF structure for reconstruction. DNG files are large and common in photography workflows.

### Uncompressed raster formats
- [x] TGA → JXL container expansion — Raw pixels + 18-byte header → JXL lossless. Same pattern as BMP. 24/32-bit uncompressed true-color. Byte-identical roundtrip, ~90% savings.

### Professional/scientific imaging
- [x] DICOM → JXL container expansion — Medical imaging (.dcm). Parse DICOM tags (explicit VR), extract uncompressed pixel data (8/16-bit), JXL lossless encode. Compact metadata stores non-pixel DICOM tags. Byte-identical roundtrip. Encapsulated (JPEG/J2K) DICOM rejected as opaque.
- [x] FITS → JXL container expansion — Astronomy imaging (.fits). 8/16-bit integer pixel arrays + text headers. BE→LE conversion for JXL encoding. Compact metadata stores only header blocks. Byte-identical roundtrip.
- [ ] ICO/CUR → JXL container expansion — Deferred: icon files are typically very small, expansion overhead not justified.
### Archive decomposition
- [x] tar → expand — Decompose tar archives into individual files. Parse 512-byte headers, extract entries as a directory tree. With MIME sorting in solid mode, this lets LZMA2 group similar file types together. Byte-identical reconstruction on extraction.

### Additional ZIP-based formats to detect
- [x] Add all ZIP-based format extensions to codec detection: `.cbz` (comics), `.jar`/`.war`/`.ear` (Java), `.apk`/`.aab` (Android), `.ipa` (iOS), `.xpi` (Firefox), `.crx` (Chrome), `.3mf`/`.amf` (3D printing), `.sketch`, `.ott`/`.ots`/`.otp` (LibreOffice templates)


### Formats using zlib/gzip/deflate internally
- [ ] SWF (Flash) container expansion — Dead format but heavily archived. Contains zlib-compressed streams (shapes, bitmaps, ActionScript bytecode). Decompress streams for better LZMA2 compression. Byte-identical reconstruction.
- [ ] WOFF → decompressed font expansion — Web Open Font Format uses zlib internally. Decompress tables, store glyph outlines for JXL (bitmap fonts) or better LZMA2 (outline fonts). Reconstruct WOFF with original zlib levels.
- [ ] HDF5 container expansion — Hierarchical Data Format (.h5, .hdf5). Ubiquitous in science/ML. Datasets compressed with gzip, szip, or uncompressed. Decompose into individual datasets, re-compress each optimally. Image datasets → JXL.
- [ ] NetCDF container expansion — Climate/weather data (.nc). Internally uses zlib on variables. Decompose variables, JXL for gridded image data, LZMA2 for numeric arrays.
- [ ] MAT container expansion — MATLAB data files (.mat). v5+ uses zlib internally. Decompose variables, JXL for image arrays, LZMA2 for numeric data.
- [ ] ROOT container expansion — CERN particle physics (.root). Uses zlib or LZ4 internally. Decompress TTree branches for better LZMA2 grouping.

### Data engineering formats (Snappy/zlib internally)
- [ ] Parquet container expansion — Columnar data format (.parquet). Uses Snappy, gzip, or LZO per column chunk. Decompress and re-group columns for LZMA2. High value for data archival.
- [ ] Avro container expansion — Row-oriented data (.avro). Uses Snappy or deflate per block. Decompress blocks for LZMA2.
- [ ] ORC container expansion — Columnar format (.orc). Uses zlib or Snappy per stripe. Same approach as Parquet.

### Medical/financial imaging (high-security archival candidates)
- [ ] NIfTI container expansion — Neuroimaging (.nii). Uncompressed 3D/4D voxel arrays + 348-byte header. Same approach as FITS but with 3D slicing. Hospitals and research institutions archive these long-term, often with encryption requirements (HIPAA).
- [ ] DNG container expansion — Digital Negative (.dng). TIFF-based with embedded JPEG preview + raw sensor data. Extract JPEG preview → JXL transcode, decompress deflate-compressed raw data for better LZMA2. Photography studios archive large DNG collections.
- [ ] PSD container expansion — Photoshop (.psd). Layer-based format with raw pixel data per layer. Extract layers, JXL-encode each. Professional photography/design archives.
- [ ] MINC container expansion — HDF5-based neuroimaging (.mnc). Decomposes to HDF5 datasets. Medical data subject to privacy regulations.

### Database archival
- [ ] SQLite container expansion — Uncompressed B-tree pages (.sqlite, .db). Decompose into page-level entries for better LZMA2 grouping. Database backups are common archival targets, especially when encrypted for compliance.

## GUI Application Roadmap

### File hierarchy view
- [ ] Navigable file hierarchy — Tree view with expandable/collapsible directories showing archive contents. Right-click "Extract to..." on any directory or file. Hold Command to multi-select items. Drag items out to extract/reconstitute them. Drag items in to add to archive (highlight directories on rollover). Show file sizes, types, container status (expanded/opaque).

### Internationalization
- [ ] Translate GUI to 22 languages (same as ../validate): English, Spanish, French, German, Italian, Portuguese, Dutch, Russian, Chinese (Simplified), Chinese (Traditional), Japanese, Korean, Arabic, Hindi, Turkish, Polish, Czech, Swedish, Norwegian, Danish, Finnish, Thai

## Future
- [ ] macOS bundle container types — Recognize `.app`, `.framework`, `.bundle`, `.plugin`, `.kext` directories as containers with appropriate tags (`"co" -> "app"`, `"co" -> "framework"`, etc.). Preserves bundle structure awareness (code signing, `Info.plist` placement, `_CodeSignature/`) and enables bundle-aware deduplication (shared frameworks across apps).
