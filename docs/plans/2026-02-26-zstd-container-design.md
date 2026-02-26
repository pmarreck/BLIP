# ZSTD Container Type Design

**Date:** 2026-02-26

## Overview

Add a ZSTD container type to the BLIP container spec that wraps any other container with zstd compression. Uses Zig stdlib `std.compress.zstd` — zero external dependencies. Available in both BLAR and MBAR archives.

## Wire Format

```
┌─────────────────────────────────────────────────┐
│ Type:              0x81 0x09  (BLIP sentinel)    │
│ Length:            BLIP(total)                    │
│ Uncompressed size: BLIP(original_size)           │
│ Compressed data:   zstd frame bytes              │
│ Hash:              xxHash64 (8 bytes, LE)        │
└─────────────────────────────────────────────────┘
```

- Sentinel 0x09 (next available after DATA 0x08)
- Hash covers compressed data: everything from container start to total - 8
- Uncompressed size stored for single-allocation decompression
- Decompressed bytes are a complete, valid BLIP container (any type)
- Compression level is serialization-time only — not stored in wire format

## Archive Integration

Current: `ARRAY [magic_RAW, body_ARRAY[entries...]]`
Compressed: `ARRAY [magic_RAW, ZSTD(body_ARRAY[entries...])]`

Magic stays uncompressed for format identification without decompression.

ArchiveReader transparently detects ZSTD at element [1] and decompresses before proceeding. All existing operations (list, extract, verify, peek, poke, to-json) work unchanged.

Poke on compressed archives: decompress → modify → recompress (full rewrite, not surgical).

## Zig API

```zig
// src/zstd.zig
pub fn compressContainer(allocator, container_bytes, level) ![]u8
pub fn decompressContainer(allocator, zstd_container) ![]u8
pub const ZstdReader = struct { ... };
```

## C FFI

```c
int32_t blip_zstd_compress(const uint8_t *in, size_t in_len,
                           int32_t level, uint8_t **out, size_t *out_len);
int32_t blip_zstd_decompress(const uint8_t *in, size_t in_len,
                              uint8_t **out, size_t *out_len);
```

Error codes: -23 (decompression), -24 (compression), -25 (invalid level).

## CLI

```
blar create -z archive.blar files...      # default level (3)
blar create -z9 archive.blar files...     # level 9
blar extract archive.blar                 # auto-detects ZSTD
```

`-z` flag for both `blar` and `miniblar`. Level suffix optional (1-22).
