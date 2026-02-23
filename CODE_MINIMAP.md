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
- `ContainerType` — enum(u7): array, dict, utf8, raw, file, map
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
DICT and FILE containers with key ordering and interleaved index.
- `KeyValue` — struct { key, value } (pre-serialized container bytes)
- `serializeDict(alloc, pairs) ![]u8` — sorted keys, interleaved index, xxHash64
- `serializeFile(alloc, pairs) ![]u8` — FILE variant, validates required keys
- `DictReader` — zero-copy reader: init, pairCount, keyAt, valueAt, findKey, verifyHash
- `extractKeyBytes(key_container) ![]const u8` — extract key value from TLV

## src/mini_blip.zig
High-level miniBLIP archive API.
- `FileEntry` — struct { path, content, metadata }
- `createArchive(alloc, files) ![]u8` — build complete BLIP archive
- `ArchiveReader` — reader: init, verifyMagic, fileCount, fileAt, findFile, verifyHash

## src/lib.zig
C FFI exports for BLIP encoding and container operations.
- `blip_encode`, `blip_decode`, `blip_is_sentinel`, `blip_encoded_size`
- `blip_archive_create`, `blip_archive_file_count`, `blip_archive_verify`, `blip_free`

## src/blip.h
C header for the BLIP FFI (encoding + containers).

## src/main.zig
CLI entry point calling through C FFI. Supports --about, -h/--help, self-test.

## src/benchmark.zig
Benchmark suite: throughput, bignum math, random-access jumping.

## src/fuzz.zig
Fuzz roundtrip tests for all encodings (100K random values each).
