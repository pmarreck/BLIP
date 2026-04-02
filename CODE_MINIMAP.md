# Code Minimap

## src/blip.zig
Core BLIP encoding implementation.
- `encode(value: u64, buf: []u8) !usize` — BLIP encode, immediate mode (0-127) or length-prefixed
- `decode(buf: []const u8) !DecodeResult` — BLIP decode, returns value + bytes consumed
- `isSentinel(buf: []const u8) bool` — detect overlong (sentinel) encodings
- `encodeSentinel(value: u7, buf: []u8) !usize` — encode a sentinel value
- `minBytes(value: u64) usize` — minimum LE byte width for a value

## src/leb128.zig
LEB128 (unsigned) and SLEB128 (signed) variable-length integer encoding.
- `encode/decode` — unsigned LEB128
- `signedEncode/signedDecode` — signed SLEB128

## src/protobuf_varint.zig
Protobuf varint (LEB128 unsigned + ZigZag for signed).
- `encode/decode` — unsigned (same as LEB128)
- `zigzagEncode/zigzagDecode` — ZigZag mapping (signed <-> unsigned)
- `signedEncode/signedDecode` — ZigZag + LEB128 compose

## src/asn1_length.zig
ASN.1 BER/DER length encoding (big-endian payload, L <= 126).
- `encode/decode` — short form (<128) or long form (0x80|N + N BE bytes)

## src/prefix_varint.zig
PrefixVarint encoding (count leading 1-bits for byte count).
- `encode/decode` — unary prefix in first byte determines total length

## src/sqlite_varint.zig
SQLite varint encoding (Huffman-inspired thresholds).
- `encode/decode` — 0-240 in 1 byte, then threshold-based tiers up to 9 bytes

## src/encoding.zig
Common interface re-exporting all encoding modules.
- `all_encodings` — tuple for comptime iteration over all 6 encodings
- Re-exports: `blip`, `leb128`, `protobuf`, `asn1`, `prefix_varint`, `sqlite`

## src/bignum.zig
Direct arithmetic on raw little-endian byte slices.
- `addLE(a, b, out) !usize` — LE addition with carry propagation
- `mulLE(a, b, out) !usize` — schoolbook LE multiplication
- `compareLE(a, b) Order` — LE comparison ignoring trailing zeros

## src/container_types.zig
Container type tags and sentinel mapping.
- `ContainerType` — enum(u7): array, dict, utf8, raw, file, map, dir
- `typeSentinel(ct) [2]u8` — convert type to 2-byte sentinel
- `parseType(buf) ?ContainerType` — parse sentinel from buffer

## src/container.zig
Core TLV header read/write and self-referential length solver.
- `ContainerError` — error set for all container operations
- `ContainerView` — parsed container header (type, total_length, value_offset, buf)
- `computeTotalLength(v_size) u64` — solve total = 2 + blip_size(total) + v_size
- `writeHeader(type, total, buf) !usize` — write type sentinel + BLIP length
- `parseHeader(buf) !ContainerView` — parse container header from buffer

## src/leaf.zig
UTF8 and RAW leaf container serialization/parsing.
- `serializeUtf8(alloc, text) ![]u8` — serialize UTF-8 string container
- `serializeRaw(alloc, data) ![]u8` — serialize raw binary container
- `readUtf8(buf) ![]const u8` — zero-copy read of UTF8 container
- `readRaw(buf) ![]const u8` — zero-copy read of RAW container

## src/array.zig
ARRAY container with index tables and xxHash64.
- `serializeArray(alloc, elements) ![]u8` — fixpoint iteration, index, xxHash64
- `ArrayReader` — zero-copy reader: init, elementCount, elementAt, verifyHash

## src/dict.zig
DICT, FILE, and DIR containers with key ordering and interleaved index.
- `KeyValue` — struct { key, value } (pre-serialized container bytes)
- `serializeDict(alloc, pairs) ![]u8` — sorted keys, interleaved index, xxHash64
- `serializeFile(alloc, pairs) ![]u8` — FILE variant, validates required keys (path, xh64, bina)
- `serializeDir(alloc, pairs) ![]u8` — DIR variant, validates required keys (path, xh64; no bina)
- `DictReader` — zero-copy reader: init, pairCount, keyAt, valueAt, findKey, verifyHash (supports DICT, FILE, MAP, DIR)
- `extractKeyBytes(key_container) ![]const u8` — extract key value from TLV

## src/mini_blar.zig
High-level BLIP archive API (miniBlar flat archives + full archives with DIR).
- `FileEntry` — struct { path, content, metadata }
- `DirEntry` — struct { path, xh64, metadata }
- `ArchiveEntry` — union(enum) { file: FileEntry, dir: DirEntry }
- `createArchive(alloc, files) ![]u8` — build flat FILE-only BLIP archive
- `createFullArchive(alloc, entries) ![]u8` — build archive with FILE + DIR entries
- `computeMerkleHash(child_hashes) [8]u8` — xxHash64 of concatenated child hashes
- `ArchiveReader` — reader: init, verifyMagic, fileCount, fileAt, findFile, entryCount, entryAt, entryTypeAt, verifyHash

## src/lib.zig
C FFI exports for BLIP encoding and container operations.
- `blip_encode`, `blip_decode`, `blip_is_sentinel`, `blip_encoded_size`
- `blip_archive_create`, `blip_archive_file_count`, `blip_archive_verify`, `blip_free`
- `blip_archive_create_full` — create archive with FILE + DIR entries and metadata
- `blip_archive_entry_type` — return entry type (0x05=FILE, 0x07=DIR)
- `blip_archive_entry_metadata` — extract mode, mtime, owner from entry

## src/blip.h
C header for the BLIP FFI (encoding + containers + full archive API).

## src/main.zig
CLI entry point calling through C FFI. Supports --about, -h/--help, self-test.

## src/benchmark.zig
Benchmark suite: throughput, bignum math, random-access jumping.

## src/fuzz.zig
Fuzz roundtrip tests for all encodings (100K random values each).

## src/blar_common.h
Shared utilities for blar and miniblar CLIs.
- `read_file`, `write_file` — file I/O helpers
- `mkdirp`, `ensure_parent_dir` — recursive directory creation
- `progress_t`, `progress_init/update/finish` — progress bar for interactive terminals
- `parse_tar_flags` — tar-style flag parsing (cf, tf, xf, Vf, If, pf)
- `default_output_name` — generate default output path (<basename>.blar)
- `normalize_path` — strip leading ./ and / from paths

## src/blar.c
Full-featured BLIP archive CLI with directory + metadata support (calls through C FFI).
- `cmd_create` — recurse directories, collect metadata (mode, mtime, owner), call `blip_archive_create_full`
- `cmd_list` — show entries with type prefix (d=dir, -=file)
- `cmd_extract` — two-pass: create dirs first, then extract files; restore mode + mtime
- `cmd_verify` — verify outer hash + per-entry xh64 + Merkle hashes
- `cmd_info` — report file count, directory count, sizes
- `cmd_cat` — print single file content to stdout

## src/miniblar.c
Minimal BLIP archive CLI for flat file-only archives (calls through C FFI).
- Same commands as blar: create, list, extract, verify, info, cat
- Rejects directory arguments (use blar for directory support)
- Uses `blip_archive_create` (not create_full)

## tests/blar_full_test.sh
Integration tests for blar CLI (18 tests: directory trees, DIR/FILE entries, metadata, Merkle hash, corruption detection).

## tests/miniblar_test.sh
Integration tests for miniblar CLI (19 tests: flat archives, binary roundtrip, directory rejection).

## src/expansion.zig
Unified container expansion and collapse — all 15 format handlers.
- `detectCodec(content) ?[]const u8` — format detection by magic bytes
- `expandFile(allocator, content, codec_name) !?ExpandResult` — expand a file into container entries
- `collapseContainer(allocator, codec_name, children) !?[]u8` — reconstruct original file from expanded children
- `expandPdf(allocator, content) !?ExpandResult` — PDF-specific expansion (FlateDecode + JPEG streams)
- `expandZip(allocator, content) !?ExpandResult` — ZIP decomposition
- `expandSlot(allocator, entry, slot, expand, expand_all_zips)` — per-entry expansion (thread-safe)

## src/streaming.zig
Streaming (spill-to-disk) archive creation with O(largest_file) memory.
- `createArchiveStreaming(allocator, entries, comp_id, expand, expand_all_zips) ![]u8` — two-pass streaming archive creation
- `ExpSlot` — per-entry expansion result slot for parallel processing
- `isArchiveExtension(path) bool` — check if file has archive extension (ZIP skip logic)

## src/array.zig (additions)
- `computeArrayLayout(allocator, element_sizes, type_id, options) !ArrayLayout` — dry-run ARRAY layout from sizes alone (enables streaming assembly)
- `ArrayLayout` — struct with header bytes, index section, total size for streaming

## src/bmp.zig
BMP image parser for container expansion (24/32-bit uncompressed).
- `parseBmp(allocator, data) !ParsedBmp` — parse BMP → pixels + header metadata
- `encodeBmp(allocator, pixels, header) ![]u8` — reconstruct BMP from pixels + header

## src/tga.zig
TGA image parser for container expansion (24/32-bit uncompressed true-color).
- `parseTga(allocator, data) !ParsedTga` — parse TGA → pixels + header
- `encodeTga(allocator, pixels, header, footer) ![]u8` — reconstruct TGA

## src/tiff.zig
TIFF image parser for container expansion (uncompressed 8/16-bit).
- `parseTiff(allocator, data) !ParsedTiff` — parse TIFF → pixels + compact metadata (non-pixel bytes)

## src/gif.zig
GIF image parser with LZW decompression (static GIFs only).
- `parseGif(allocator, data) !ParsedGif` — parse GIF → RGBA pixels + original file
- LZW decoder: `LzwDecoder`, `decodeLzw(allocator, compressed, min_code_size, output_size) ![]u8`

## src/tar.zig
tar archive parser for container decomposition.
- `parseTar(allocator, data) !ParsedTar` — parse tar → individual entries with headers
- `encodeTar(allocator, entries, trailer) ![]u8` — reconstruct tar from entries

## src/wav.zig
WAV audio parser for FLAC container expansion.
- `parseWav(allocator, data) !ParsedWav` — parse WAV → PCM samples + compact metadata

## src/aiff.zig
AIFF audio parser for FLAC container expansion (big-endian PCM).
- `parseAiff(allocator, data) !ParsedAiff` — parse AIFF → LE PCM + metadata
- `parseExtended80(buf) u32` — decode 80-bit IEEE 754 sample rate

## src/flac.zig
FLAC encoder/decoder wrapper (uses libFLAC via @cImport).
- `encodePcmToFlac(allocator, samples, channels, rate, bps, frames) ![]u8` — PCM → FLAC
- `decodeFlacToPcm(allocator, flac_data, channels, rate, bps, total) ![]u8` — FLAC → PCM

## src/fits.zig
FITS astronomy image parser (8/16-bit integer pixel arrays).
- `parseFits(allocator, data) !ParsedFits` — parse FITS → pixels + header metadata

## src/dicom.zig
DICOM medical image parser (uncompressed 8/16-bit).
- `parseDicom(allocator, data) !ParsedDicom` — parse DICOM → pixels + tag metadata

## src/nifti.zig
NIfTI neuroimaging parser (3D/4D voxel data).
- `parseNifti(allocator, data) !ParsedNifti` — parse NIfTI → voxels + 348-byte header

## src/compression_stub.zig
Compression stub — same API as compression.zig but returns UnsupportedCompression.
Used when enable_compression=false for downstream consumers.

## src/checksum.zig
Checksum computation (xxHash64, CRC32, BLAKE3-128).
- `compute(id, data) [32]u8` — compute checksum
- `verify(id, data, expected) bool` — verify checksum

## src/encryption.zig
Archive encryption (AES-256-GCM, ChaCha20-Poly1305) with Argon2id/PBKDF2 KDF.

## src/zip.zig
ZIP container reader/writer for container expansion.
- `readEntries(allocator, buf) ![]ZipEntry` — parse ZIP central directory
- `extractEntry(allocator, entry) ![]u8` — decompress a ZIP entry
- `createZip(allocator, entries) ![]u8` — create a ZIP from entries

## src/lzma2.zig
LZMA2 compression integration (via z7z dependency).

## src/blar_common.h
C wiring layer — connects CLI/GUI to Zig core via FFI.
- `entry_list_t` — file/dir collection with metadata_only streaming support
- `expand_via_zig()` — routes all container expansion through blip_expand_file FFI
- `blar_extract_to_dir()` — extraction with Zig collapse bridge for all formats
- `expand_containers_pass()` — parallel expansion with work-stealing queue

## src/blar.c
C CLI — `blar create/extract/list/verify/info` with --streaming flag.

## src/blip.h
C FFI header — declares all Zig-exported functions for C consumers.

## bench/archive_bench.sh
Archive creation benchmarks (small/medium/large, in-memory vs streaming, with/without expansion).
