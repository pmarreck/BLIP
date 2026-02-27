# BLIP Container Format v2: LP (Length-Payload) Redesign

**Date:** 2026-02-27
**Status:** Approved
**Breaks backwards compatibility:** Yes (downstream consumers will be notified)

## Motivation

1. Add 3 more compression types (bzip2, LZ4, zstd) alongside existing LZMA2
2. Checksum coverage was incomplete in v1: the type sentinel and length were outside the hash
3. Container types were limited to 127 values (one per sentinel byte)
4. No extensibility mechanism for new per-container attributes (compression, signatures, etc.)

## Overview

Replace the v1 TLV (Type-Length-Value) container envelope with LP (Length-Payload). The length comes first, enabling the checksum to cover everything. The payload consists of sorted attribute-value pairs identified by BLIP sentinels.

## Wire Format

Every container:

```
┌─────────────────────────────────────────────────────────────────────┐
│ BLIP(total_length)              ← self-referential (includes self) │
│ ┌─ Attributes (sorted by sigil value) ──────────────────────────┐  │
│ │ [0x81 0x01]  BLIP(type_id)       ← TYPE (required, first)    │  │
│ │ [0x81 0x10]  BLIP(comp_id)       ← COMP (optional)           │  │
│ │ [0x81 0x11]  BLIP(decomp_size)   ← DECOMP_LEN (if COMP)     │  │
│ │ [0x81 0x12]  BLIP(csum_id)       ← CSUM (optional)           │  │
│ │ [0x81 0x20]  <sig_bytes>         ← SIG (future)              │  │
│ │ [0x81 0x7F]  <payload><checksum> ← VAL (required, last)      │  │
│ └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

**Rules:**
- `total_length` is self-referential: counts from its own first byte to the container's last byte
- Attributes are sorted by sigil byte value (0x01 < 0x10 < 0x11 < 0x12 < 0x20 < 0x7F)
- TYPE (0x01) is always first; VAL (0x7F) is always last
- VAL has no explicit length; its payload extends to end of container
- If a checksum is present, its bytes are the last N bytes of the VAL payload
- Checksum covers all bytes from start of total_length through end of payload (excluding the checksum bytes themselves)
- If COMP is present, DECOMP_LEN is required
- Compression applies to the VAL payload only (not attributes); checksum covers the compressed form

## Attribute Sigil Assignments

```
Sentinel     Name         Value Type      Description
─────────────────────────────────────────────────────────────
0x81 0x00    PAD_END      (n/a)           Reserved (BLIP padded integer terminator)
0x81 0x01    TYPE         BLIP integer    Container type ID (required, always first)
0x81 0x10    COMP         BLIP integer    Compression algorithm ID
0x81 0x11    DECOMP_LEN   BLIP integer    Decompressed size (required when COMP present)
0x81 0x12    CSUM         BLIP integer    Checksum algorithm ID
0x81 0x20    SIG          raw bytes       Digital signature (future)
0x81 0x7F    VAL          raw bytes       Payload data + trailing checksum (required, always last)

Ranges:
  0x00       Reserved (PAD_END)
  0x01-0x0F  Structural (required/fundamental)
  0x10-0x1F  Data-processing (compression, checksums)
  0x20-0x2F  Security
  0x30-0x7E  Reserved for future use
  0x7F       VAL (terminal, always last)
```

## Container Type IDs

The TYPE attribute's value is a BLIP integer. Predefined types:

```
ID    Name     Description
────────────────────────────────────────────────
1     ARRAY    Ordered sequence with index
2     DICT     Sorted key-value pairs (deterministic)
3     UTF8     UTF-8 string
4     DATA     Binary data (replaces v1 RAW + v1 DATA)
5     FILE     Metadata + content (ARRAY layout)
6     MAP      Insertion-order key-value pairs
7     DIR      Directory entry (2-char keys)
8+    (user)   Application-defined types
```

Applications may define their own type IDs >= 8. Since type IDs are BLIP integers, the namespace is effectively infinite.

## Compression Algorithm IDs

```
ID    Name     Implementation
─────────────────────────────────────────────
1     LZMA2    z7z (pmarreck/z7z) encoder, Zig stdlib decoder
2     bzip2    bzip2z (pmarreck/bzip2z) pure Zig
3     LZ4      TBD (pure Zig or C binding)
4     zstd     TBD (Zig stdlib decoder, need encoder)
```

## Checksum Algorithm IDs

```
ID    Name        Length     Notes
───────────────────────────────────────────────
1     CRC32       4 bytes    Fast, weak integrity
2     xxHash64    8 bytes    Fast, good integrity
3     BLAKE3-128  16 bytes   Cryptographic, default for top-level
```

**Default behavior:**
- Top-level container: checksum is required. If CSUM attribute is absent, BLAKE3-128 is assumed.
- Inner/nested containers: checksum is optional. If CSUM is absent, no checksum bytes in VAL.

BLAKE3-128 uses BLAKE3's native XOF (extendable output function) to produce exactly 16 bytes.

## Checksum Coverage

The checksum hash input covers:

```
hash_input = bytes[0 .. total_length - checksum_length]
```

This includes:
- The BLIP-encoded total_length itself
- All attribute sentinels and values (TYPE, COMP, DECOMP_LEN, CSUM, etc.)
- The VAL sentinel
- The payload data (compressed if COMP present)

This explicitly excludes:
- The checksum bytes themselves (last N bytes of VAL)

This is a key improvement over v1: in v1, the type sentinel and length were outside the hash.

## VAL Payload Size Derivation

Since VAL is always last and has no explicit length, its size is computed:

```
val_start = offset after VAL sentinel (0x81 0x7F)
val_end = total_length (from start of container)
val_payload_size = val_end - val_start

If checksum present:
  data_size = val_payload_size - checksum_length
  checksum_bytes = val[data_size .. val_payload_size]
```

## Container Internal Structures

The LP format changes the outer envelope. Internal structures of complex containers remain the same:

- **ARRAY VAL**: `[BLIP(index_offset)] [elements...] [INDEX_SECTION] [checksum?]`
- **DICT VAL**: `[BLIP(index_offset)] [key0 val0 key1 val1...] [INDEX_SECTION] [checksum?]`
- **UTF8 VAL**: raw UTF-8 bytes `[checksum?]`
- **DATA VAL**: raw binary bytes `[checksum?]`
- **FILE VAL**: same as ARRAY internally `[checksum?]`
- **DIR VAL**: same as DICT internally `[checksum?]`
- **MAP VAL**: same as DICT internally but insertion-ordered `[checksum?]`

Inner checksums are optional — containers opt-in via their own CSUM attribute for independent subtree verification (useful for Merkle trees, partial verification).

## Archive Format

Same magic bytes, version bumped:

```
BLAR v2:  "BLAR\x02"  (full archives with directory support)
MBAR v2:  "MBAR\x02"  (flat file-only archives)
```

Archive structure is conceptually unchanged:
```
ARRAY (outer)
├── DATA "BLAR\x02" or "MBAR\x02" (magic + version)
└── ARRAY (body)
    ├── DIR entries (optional, BLAR only)
    └── FILE entries
```

All containers within the archive use the new LP format.

## Worked Examples

### Simple UTF8 container (top-level, default BLAKE3-128)

Content: "hello" (5 bytes)

```
[BLIP(28)]                    ← total: 1 + 2 + 1 + 2 + 5 + 16 + 1(len) = 28
[0x81 0x01] [0x03]            ← TYPE = UTF8 (3)
[0x81 0x7F]                   ← VAL sentinel
"hello"                       ← 5 bytes payload
[BLAKE3-128 16B]              ← checksum of bytes[0..12]
```

### LZMA2-compressed DATA container (top-level)

Original: 10000 bytes, compressed to 2000 bytes

```
[BLIP(2029)]                  ← total length
[0x81 0x01] [0x04]            ← TYPE = DATA (4)
[0x81 0x10] [0x01]            ← COMP = LZMA2 (1)
[0x81 0x11] [BLIP(10000)]    ← DECOMP_LEN = 10000
[0x81 0x7F]                   ← VAL sentinel
[2000 bytes compressed data]  ← LZMA2-compressed payload
[BLAKE3-128 16B]              ← checksum covers all preceding bytes
```

### Inner container (no checksum)

A UTF8 string nested inside an ARRAY — no CSUM attribute:

```
[BLIP(10)]                    ← total
[0x81 0x01] [0x03]            ← TYPE = UTF8
[0x81 0x7F]                   ← VAL
"hello"                       ← payload, no trailing checksum
```

## Migration

- Clean break: v2 reader does not support v1 format. v1 code preserved in git.
- Downstream consumers (entropy_shield, zdiff) notified of format change.
- LZ4 and zstd compression can be stubbed initially (enum defined, implementation returns error) and filled in incrementally.
- bzip2z dependency: upstream GitHub URL in build.zig.zon (same pattern as z7z).
