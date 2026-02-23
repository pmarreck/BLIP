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

## src/lib.zig
C FFI exports for BLIP encoding.
- `blip_encode`, `blip_decode`, `blip_is_sentinel`, `blip_encoded_size`

## src/blip.h
C header for the BLIP FFI.

## src/main.zig
CLI entry point calling through C FFI. Supports --about, -h/--help, self-test.

## src/benchmark.zig
Benchmark suite: throughput, bignum math, random-access jumping.

## src/fuzz.zig
Fuzz roundtrip tests for all encodings (100K random values each).
