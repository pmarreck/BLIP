# BLIP Implementation Design

**Date:** 2026-02-22
**Status:** Approved

## Goal

Zig 0.15.2 implementation of BLIP encoding with benchmark suite comparing against LEB128, SLEB128, ASN.1 BER length encoding, Protobuf varint (+ZigZag), PrefixVarint, and SQLite varint.

## Architecture

```
src/
  blip.zig             -- BLIP encode/decode (pure, no I/O)
  leb128.zig           -- LEB128 + SLEB128
  asn1_length.zig      -- ASN.1 BER/DER length encoding
  protobuf_varint.zig  -- Protobuf varint + ZigZag
  prefix_varint.zig    -- PrefixVarint
  sqlite_varint.zig    -- SQLite varint
  encoding.zig         -- Common interface (comptime generic)
  bignum.zig           -- Direct-on-encoded LE arithmetic for BLIP
  lib.zig              -- C FFI exports (BLIP only)
  main.zig             -- CLI entry point (calls through C FFI)
tests/
  unit/                -- Per-encoding unit tests
  benchmark/           -- Benchmark harness
  fuzz/                -- Fuzz tests (encode->decode roundtrip)
```

## Common Interface

Each encoding exposes:
- `encode(value: u64, buf: []u8) !usize` — returns bytes written
- `decode(buf: []const u8) !struct { value: u64, bytes_read: usize }`

Bignum variants (arbitrary width):
- `encodeBytes(value_bytes: []const u8, buf: []u8) !usize`
- `decodeBytes(buf: []const u8, out: []u8) !struct { len: usize, bytes_read: usize }`

## Benchmarks

### 1. Throughput

Encode/decode 10M values from four distributions:
- Uniform small (0-127)
- Uniform medium (0-65535)
- Bimodal (90% <128, 10% >16384)
- Large (>2^32)

Metric: ns/op for encode and decode separately.

### 2. Bignum Math

Two sub-benchmarks:

**Roundtrip:** Decode two large encoded values -> `std.math.big.int` add/multiply -> re-encode. Measures full encode-compute-decode cost.

**Direct LE (BLIP only):** Operate directly on raw LE payload bytes with carry-propagating addition. Other encodings must still decode/re-encode. Demonstrates BLIP's structural advantage for arithmetic on encoded data.

### 3. Random-Access Jumping

A deterministic chain of encoded offsets in a sparse file (~1GB in $TMPDIR). Start at byte 0, decode offset, pread to that position, decode next offset, repeat for N jumps. Measures decode-in-context-of-I/O latency. No container format — just raw encoded offset chains.

Separate regions per encoding so the same file serves all benchmarks.

## C FFI

Exports BLIP only (other encodings are internal reference implementations):
- `blip_encode(value_bytes, value_len, out_buf, out_cap) -> encoded_len`
- `blip_decode(encoded_bytes, encoded_len, out_buf, out_cap) -> decoded_len`
- `blip_encoded_size(value_bytes, value_len) -> size`

## Not In Scope

- Container format (unnecessary for benchmarking offset-chain navigation)
- CLI i18n (benchmark demo, not user-facing tool)
- Streaming/async I/O
- Sentinel value assignment (application-defined per spec)
