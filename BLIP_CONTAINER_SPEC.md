# BLIP Container Format

A recursive, typed, self-indexed binary container format built on [BLIP encoding](BLIP_SPEC.md). Designed as a compact, deterministic, integrity-verified alternative to tar and similar archive formats.

**Author:** Peter Marreck
**Version:** 1.2 (2026-02-24)
**Depends on:** BLIP Spec v1.1

## Overview

Every element in the format is a **container**: a Type-Length-Value (TLV) triplet where the type is a BLIP sentinel, the length is a BLIP integer describing the total container size, and the value is the payload. Containers can nest recursively.

The format provides:
- **Random access** via end-of-container index tables
- **Integrity verification** via xxHash64 checksums on array and dictionary containers
- **Streaming writes** via padded BLIPs for index offsets that are backfilled after layout
- **Extensibility** via arbitrary metadata keys in file containers
- **Determinism** via sorted keys and canonical BLIP encoding

## TLV Structure

Every container follows this layout:

```
┌────────────────────────────────────────────────────────────┐
│ Type:   BLIP sentinel (2 bytes: 0x81 + type byte)          │
│ Length: BLIP integer (total container size in bytes,       │
│         INCLUDING Type bytes + Length bytes + Value bytes) │
│ Value:  payload (type-specific)                            │
└────────────────────────────────────────────────────────────┘
```

**Total container size** = offset from container start to first byte past it. To skip a container during sequential parsing: `next = container_start + Length`.

**Self-referential length**: Because Length includes its own encoded size, the encoder must solve `L = 2 + blip_size(L) + V_size`. This converges in 1-2 iterations:

```
fn compute_total(V_size: u64) -> u64:
    base = 2 + V_size           // T + V
    for L_bytes in 1..9:        // try each BLIP encoding width
        total = base + L_bytes
        if blip_encoded_size(total) == L_bytes:
            return total        // converged
```

## Type Assignments

BLIP sentinels (0x81 0x00 through 0x81 0x7F) serve as type tags. The sentinel 0x81 0x00 is reserved at the BLIP level as PAD_END (see BLIP Spec §Sentinel Values) and is NOT available as a container type.

```
Sentinel        Type            Description
─────────────────────────────────────────────────────────
0x81 0x00       (PAD_END)       Reserved by BLIP spec — terminates padded BLIP padding
0x81 0x01       ARRAY           Ordered sequence of containers, indexed + hashed
0x81 0x02       DICT            Sorted key-value pairs, indexed + hashed (deterministic)
0x81 0x03       UTF8            UTF-8 string
0x81 0x04       RAW             Raw binary data (untyped)
0x81 0x05       FILE            ARRAY-layout container (metadata DICT + DATA content + optional forks DICT)
0x81 0x06       MAP             Unsorted key-value pairs, indexed + hashed (insertion order)
0x81 0x07       DIR             Specialized sorted dictionary (2-char keys: pa, xh, md, mt, etc.)
0x81 0x08       DATA            Checksummed binary data (raw bytes + embedded xxHash64)
0x81 0x09 - 0x81 0x0F          Reserved (future container types)
0x81 0x10 - 0x81 0x7F          Application-defined types
```

## Offset Convention

All offsets within a container are measured **from the start of the containing container** (the first byte of the container's Type sentinel). This convention is universal — it does not vary by container type. See BLIP Spec §Offset and Length Convention for the full specification.

Offsets MAY be negative (signed two's complement) when pointing into a scratch pool that precedes the target data. This is relevant only for the indirect overflow mechanism in padded BLIPs (see §Scratch Pool below).

## Key Ordering

Dictionary (DICT) and Directory (DIR) containers store key-value pairs in a canonical sort order. Map (MAP) containers are exempt — they preserve insertion order. File (FILE) containers use ARRAY layout internally and contain a metadata DICT whose keys follow this same ordering. For DICT and DIR, keys MUST be sorted in **lexicographic byte order** — the same ordering as `memcmp`.

**Rules:**
1. Compare keys byte-by-byte using unsigned byte values (0x00 < 0x01 < ... < 0xFF)
2. If one key is a prefix of another, the shorter key sorts first
3. This applies uniformly to all keys regardless of container type (UTF8 or RAW)
4. UTF8 keys are compared by their raw byte representation, not by Unicode codepoint or collation order

**Examples (sorted):**
```
"bt"      (0x62 0x74)   birthtime
"ct"      (0x63 0x74)   ctime
"gi"      (0x67 0x69)   group ID
"gn"      (0x67 0x6E)   group name
"md"      (0x6D 0x64)   mode (permissions)
"mt"      (0x6D 0x74)   mtime
"pa"      (0x70 0x61)   path
"ui"      (0x75 0x69)   user ID
"un"      (0x75 0x6E)   username
"xa"      (0x78 0x61)   xattrs (DIR only)
"xh"      (0x78 0x68)   Merkle hash (DIR only)
```

**Rationale:** Byte ordering is unambiguous, locale-independent, trivial to implement, and works identically for UTF8 and RAW keys. It also means that keys in the index section are in a known order, enabling binary search for key lookup in dictionaries with many keys.

Encoders MUST emit key-value pairs in canonical key order for DICT and DIR containers, and for the metadata DICT within FILE containers. Decoders SHOULD reject DICT/DIR containers with out-of-order keys as malformed. MAP containers are exempt from ordering requirements.

## Container Types

### UTF8 String (0x81 0x03)

A UTF-8 encoded string. Value is the raw string bytes (no null terminator).

```
┌─────────────────────────────────────┐
│ Type:   0x81 0x03                   │
│ Length: BLIP(total)                 │
│ Value:  raw UTF-8 bytes             │
└─────────────────────────────────────┘
```

Example: the string `"hello"` (5 bytes):
```
0x81 0x03       ← type: UTF8
0x08            ← length: 8 (2 type + 1 length + 5 value), immediate BLIP
0x68 0x65 0x6C 0x6C 0x6F  ← "hello"
```

### Raw Binary (0x81 0x04)

Untyped binary data. Value is raw bytes.

```
┌─────────────────────────────────────┐
│ Type:   0x81 0x04                   │
│ Length: BLIP(total)                 │
│ Value:  raw bytes                   │
└─────────────────────────────────────┘
```

### Array (0x81 0x01)

An ordered sequence of containers with a trailing index for random access and a trailing xxHash64 for integrity verification.

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x01                                               │
│ Length:  BLIP(total)                                             │
│ Value:                                                           │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │ Index offset: BLIP (padded for streaming writers)        │   │
│   │   Byte offset from array container start to the INDEX    │   │
│   │   section. For streaming writes, this is a padded BLIP   │   │
│   │   with a pre-allocated budget (see §Streaming Writes).   │   │
│   │   For in-memory construction, a normal BLIP suffices.    │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ DATA SECTION                                             │   │
│   │   Element 0: container TLV                               │   │
│   │   Element 1: container TLV                               │   │
│   │   ...                                                    │   │
│   │   Element N-1: container TLV                             │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ INDEX SECTION (at index_offset from container start)     │   │
│   │   Element count: BLIP(N)                                 │   │
│   │   Offset 0: BLIP(off_0)  ← from array container start    │   │
│   │   Offset 1: BLIP(off_1)                                  │   │
│   │   ...                                                    │   │
│   │   Offset N-1: BLIP(off_N-1)                              │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ HASH: xxHash64 (8 bytes, fixed)                          │   │
│   │   Hash of all bytes from array container start           │   │
│   │   through end of INDEX SECTION (everything except        │   │
│   │   these 8 hash bytes). These 8 bytes DO count            │   │
│   │   towards the container's total Length.                  │   │
│   └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

**Random access to element K:**
1. Jump to `container_start + index_offset` → INDEX SECTION
2. Read `N` (element count)
3. Skip K offset entries, read offset K → `off_K`
4. Jump to `container_start + off_K` → Element K's TLV

**Integrity check:**
1. Compute xxHash64 of bytes `container_start` through `container_start + Length - 9` (everything except the trailing 8-byte hash)
2. Compare with the stored 8-byte hash at `container_start + Length - 8`

**Index at the end rationale:** The index contains offsets that can only be computed after all elements are laid out. Placing it after the data section means the encoder can write elements sequentially, record their positions, then emit the index. Same rationale for the hash — it covers everything including the index.

**Padded index offset for streaming writers:** A streaming writer that doesn't know the final index position can emit the `index_offset` field as a **padded BLIP** with a pre-allocated budget:

```
Initial (value unknown, 12-byte budget):
  [0xA0] [0x00×9] [0x81, 0x00]
   ^P=1, I=0, L=0  ^padding   ^PAD_END

Backfilled (index_offset = 500000):
  [0xA3] [0x20, 0xA1, 0x07] [0x00×6] [0x81, 0x00]
   ^L=3   ^^^ value LE        ^padding  ^PAD_END
```

A 12-byte budget accommodates offsets up to 2^64 (L=8: 1 header + 8 value + 1 padding + 2 PAD_END). After all elements and the index are laid out, the writer seeks back to the padded field and backfills the actual offset. The PAD_END sentinel (0x81 0x00) terminates the field, making the boundary unambiguous regardless of how much padding remains.

For in-memory construction (where the full structure is built in RAM and serialized once), the index offset is a normal (non-padded) BLIP — the writer knows all values before emitting any bytes.

### Dictionary (0x81 0x02)

A sorted collection of key-value pairs with a trailing index and hash. Keys must be unique within a dictionary and MUST be stored in **canonical key order** (see §Key Ordering).

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x02                                               │
│ Length:  BLIP(total)                                             │
│ Value:                                                           │
│   ┌──────────────────────────────────────────────────────────┐   │
│   │ Index offset: BLIP (padded for streaming writers)        │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ DATA SECTION                                             │   │
│   │   Key 0: UTF8 or RAW container                           │   │
│   │   Value 0: any container                                 │   │
│   │   Key 1: UTF8 or RAW container                           │   │
│   │   Value 1: any container                                 │   │
│   │   ...                                                    │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ INDEX SECTION                                            │   │
│   │   Pair count: BLIP(N)                                    │   │
│   │   Pair 0: BLIP(key_0) BLIP(val_0)                        │   │
│   │   Pair 1: BLIP(key_1) BLIP(val_1)                        │   │
│   │   ...                                                    │   │
│   │   Pair N-1: BLIP(key_N-1) BLIP(val_N-1)                  │   │
│   │   All offsets from dictionary container start.           │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ HASH: xxHash64 (8 bytes)                                 │   │
│   │   Same semantics as array hash.                          │   │
│   └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

**Key lookup:** To find value for a given key:
1. Jump to index, read N
2. Binary search pairs (keys are sorted) — each pair is a (key_offset, value_offset) tuple
3. For each candidate pair: dereference key_offset, read the key container, compare
4. When key matches, the value_offset is immediately adjacent — read the value

Keys are either UTF8 (0x81 0x03) or RAW (0x81 0x04) containers. Keys MUST be unique — duplicate keys are a format error.

**Data layout:** Keys and values are interleaved in the data section in canonical key order (key₀, val₀, key₁, val₁, ...). Parsers MUST use the index for access — the interleaving is required for determinism but parsers should not rely on sequential layout for correctness.

**Key ordering enables binary search:** Because keys are sorted, lookup is O(log N) via binary search on the key offsets in the index section, rather than O(N) sequential scan. This is significant for dictionaries with many keys (e.g., extended attributes, large metadata sets).

### Directory (0x81 0x07)

A specialized dictionary representing a directory in an archive. Uses 2-character lowercase key names for compactness.

```
┌──────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x07                                            │
│ Length:  BLIP(total)                                         │
│ Value:   (dictionary structure — index, data, hash)           │
│                                                              │
│ Required keys: pa, xh                                        │
│ Optional keys: bt, ct, gi, gn, md, mt, ui, un, xa           │
│                                                              │
│ DIR containers follow dictionary layout (index + hash).      │
└──────────────────────────────────────────────────────────────┘
```

**DIR key table:**

| Key | Type | Description | Required? |
|-----|------|-------------|-----------|
| `bt` | RAW 8B i64 LE | birthtime / creation time (ns since epoch) | When available |
| `ct` | RAW 8B i64 LE | ctime / inode change time (ns since epoch) | When available |
| `gi` | RAW 4B u32 LE | Numeric group ID | When available |
| `gn` | UTF8 | Group name string | When available |
| `md` | RAW 2B u16 LE | POSIX permission bits | When available |
| `mt` | RAW 8B i64 LE | mtime (ns since epoch) | When available |
| `pa` | UTF8 | Relative path (normalized) | Required |
| `ui` | RAW 4B u32 LE | Numeric user ID | When available |
| `un` | UTF8 | Username string | When available |
| `xa` | DICT | Extended attributes (xattr name → RAW value) | Optional |
| `xh` | RAW 8B | Merkle hash | Required |

**Merkle hash algorithm:** The `xh` value for a DIR entry is a Merkle hash computed from its direct children:

1. Collect the trailing 8-byte xxHash64 from each direct child's container:
   - For FILE children: the ARRAY hash (last 8 bytes of the FILE container)
   - For DIR children: the DICT hash (last 8 bytes of the DIR container)
2. Sort children by path
3. Concatenate these 8-byte hashes in sorted-path order
4. Compute `xxHash64(child_0_hash || child_1_hash || ... || child_N_hash)` with seed 0

This produces a bottom-up hash tree where any change to a file's content OR metadata propagates up through all ancestor directory hashes to the root.

**Merkle hash properties:**
- Changing any file's content changes its DATA hash, which changes its FILE ARRAY hash, which propagates up through all ancestor directory Merkle hashes
- Changing any file's metadata (permissions, mtime, etc.) also changes the FILE ARRAY hash and propagates up
- Verifying the root directory's Merkle hash transitively verifies every file and subdirectory in the tree
- Individual subtrees can be verified independently

### Map (0x81 0x06)

An unsorted collection of key-value pairs with a trailing index and hash. Identical layout to Dictionary (0x81 0x02), but keys are stored in **insertion order** rather than canonical key order.

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x06                                               │
│ Length:  BLIP(total)                                             │
│ Value:   (same layout as Dictionary — index offset, data,        │
│           index section, xxHash64)                               │
└──────────────────────────────────────────────────────────────────┘
```

**Differences from DICT:**
- Keys are NOT required to be sorted — they appear in whatever order the writer chose
- Key lookup is O(N) sequential scan (no binary search)
- Output is NOT deterministic (different insertion orders produce different bytes)
- Decoders MUST NOT reject a MAP for out-of-order keys

**When to use MAP vs DICT:**
- Use **DICT** (0x81 0x02) when determinism matters (archives, manifests, content-addressed storage, anything that will be hashed or compared byte-for-byte)
- Use **MAP** (0x81 0x06) when insertion order matters or sorting is undesirable (e.g., preserving original key order from a configuration file, or when the overhead of sorting is not justified)

Keys in a MAP MUST still be unique — duplicate keys are a format error regardless of container type.

### Data (0x81 0x08)

Checksummed binary data: raw bytes with an embedded xxHash64 suffix for content integrity verification.

```
┌─────────────────────────────────────────────────────┐
│ Type:   0x81 0x08                                    │
│ Length: BLIP(total)                                  │
│ Value:  [data_bytes][xxHash64(data_bytes) 8B LE]     │
└─────────────────────────────────────────────────────┘
```

- `data_len = value_len - 8`
- The trailing 8 bytes are `xxHash64(data_bytes)` with seed 0, little-endian
- Hash covers only the data bytes, NOT the type/length prefix
- Empty content is valid: value = 8-byte hash of empty (hash of zero-length input)

DATA containers provide content-only integrity checking. When used inside a FILE container, this gives two levels of checksumming for free: the DATA hash verifies content-only integrity, while the FILE's ARRAY hash verifies everything (metadata + content + forks).

### File (0x81 0x05)

A container representing a file in an archive. Uses ARRAY layout (like ARRAY 0x81 0x01) but with the FILE sentinel (0x81 0x05). Always contains 2 or 3 elements.

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x05                                               │
│ Length:  BLIP(total)                                             │
│ Value:   (ARRAY structure — index offset, data, index, hash)     │
│                                                                  │
│ Elements (ARRAY layout):                                         │
│   [0]: DICT (0x81 0x02) — metadata                               │
│        Required keys: pa, md, mt                                 │
│        Optional keys: ct, bt, ui, gi, un, gn                    │
│   [1]: DATA (0x81 0x08) — file content with embedded xxHash64    │
│   [2]: DICT (0x81 0x02) — extended forks (optional)              │
│        Keys: "rf" → RAW (resource fork), xattr names → RAW      │
│                                                                  │
│ Trailing INDEX + xxHash64 (covers everything including metadata) │
└──────────────────────────────────────────────────────────────────┘
```

**Two checksums for free:**
- DATA hash (element 1) = content-only integrity
- FILE ARRAY hash = everything (metadata + content + forks)

No explicit content hash key needed — hashes are structural.

**Metadata keys (element 0 DICT):**

| Key | Type | Description | Required? |
|-----|------|-------------|-----------|
| `bt` | RAW 8B i64 LE | birthtime / creation time (ns since epoch) | When available |
| `ct` | RAW 8B i64 LE | ctime / inode change time (ns since epoch) | When available (Unix) |
| `gi` | RAW 4B u32 LE | Numeric group ID | When available |
| `gn` | UTF8 | Group name string | When available |
| `md` | RAW 2B u16 LE | POSIX permission bits | Required |
| `mt` | RAW 8B i64 LE | mtime (ns since epoch) | Required |
| `pa` | UTF8 | Relative path (normalized) | Required |
| `ui` | RAW 4B u32 LE | Numeric user ID | When available |
| `un` | UTF8 | Username string | When available |

Keys are in canonical byte sort order: bt < ct < gi < gn < md < mt < pa < ui < un

**Path normalization:**
- Forward slashes only (`/`), never backslashes
- No leading slash (relative to archive root)
- No `.` or `..` components
- UTF-8 encoded, NFC normalized
- Example: `src/core/main.zig`

**Extended forks (element 2, optional):**
- Present only when the file has a resource fork or extended attributes
- `"rf"` key → RAW resource fork data (macOS)
- xattr names as-is → RAW xattr values
- On extraction to non-macOS: resource fork written as AppleDouble file (`._originalname`)

## Archive Format

A complete archive (the "tar replacement") is a top-level **Array** container:

```
Archive (ARRAY):
  Element 0: RAW containing magic bytes: "BLIP" + version byte (0x01)
  Element 1: ARRAY (body) containing:
    Element 0: DIR  { pa: "src", xh: [Merkle hash], md: 0o755, mt: ... }
    Element 1: FILE [metadata DICT {pa: "src/main.zig", md: 0o644, mt: ...},
                      DATA [content + xxHash64]]
    Element 2: FILE [metadata DICT {pa: "src/lib.zig", md: 0o644, mt: ...},
                      DATA [content + xxHash64]]
    ...
    Element N-1: FILE or DIR { ... }
```

The body array may contain both FILE (0x81 0x05) and DIR (0x81 0x07) entries. FILE entries use ARRAY layout containing a metadata DICT and a DATA container. DIR entries use DICT layout with 2-char keys. Archives without DIR entries are valid — directories are then implicit from file paths.

**Magic identification:** The first bytes of any archive are:
```
0x81 0x01       ← ARRAY type sentinel
BLIP(length)    ← total archive size
BLIP(idx_off)   ← index offset (padded BLIP for streaming, normal otherwise)
0x81 0x04       ← RAW type sentinel (element 0)
0x08            ← RAW length: 8 (2+1+5)
0x42 0x4C 0x49 0x50 0x01  ← "BLIP" + version 1
```

A parser can identify a BLIP archive by checking for the ARRAY sentinel at byte 0, then verifying the first element is a RAW container starting with `"BLIP"`.

**Body element ordering:** Entries (FILE and DIR) in the body array SHOULD be sorted lexicographically by path for deterministic archives. Parsers MUST NOT assume sorted order — use the index for random access.

**Integrity verification of entire archive:** The outer ARRAY's trailing xxHash64 covers the entire archive contents (all files, all metadata, the index). A single 8-byte comparison verifies the whole thing.

## Nesting Examples

### Minimal archive with one file

```
ARRAY                                           ← top-level archive
├── RAW "BLIP\x01"                              ← magic + version
└── ARRAY                                       ← body
    └── FILE (ARRAY layout, 0x81 0x05)          ← single file
        ├── [0] DICT (metadata)                 ← keys in canonical byte order
        │   ├── "md" → RAW [2 bytes, 0o644]
        │   ├── "mt" → RAW [8 bytes, ns since epoch]
        │   └── "pa" → UTF8 "hello.txt"
        └── [1] DATA                            ← content + embedded xxHash64
            └── "Hello, world!\n" + [8B hash]
```

### Archive with directories

```
ARRAY                                           ← top-level archive
├── RAW "BLIP\x01"
└── ARRAY                                       ← body
    ├── DIR (DICT layout, 0x81 0x07)            ← directory entry
    │   ├── "md" → RAW [2 bytes, 0o755]
    │   ├── "mt" → RAW [8 bytes, nanoseconds]
    │   ├── "pa" → UTF8 "src"
    │   └── "xh" → RAW [8 bytes, Merkle hash]
    ├── FILE (ARRAY layout, 0x81 0x05)
    │   ├── [0] DICT { md: 0o644, mt: ..., pa: "src/lib.zig" }
    │   └── [1] DATA [file contents + hash]
    └── FILE (ARRAY layout, 0x81 0x05)
        ├── [0] DICT { md: 0o644, mt: ..., pa: "src/main.zig" }
        └── [1] DATA [file contents + hash]
```

The DIR entry's `xh` is `xxHash64(file_hash_lib || file_hash_main)` — a Merkle hash of children's ARRAY hashes, concatenated in path-sorted order.

### Archive with extended metadata and forks

```
ARRAY                                           ← top-level archive
├── RAW "BLIP\x01"
└── ARRAY                                       ← body
    ├── FILE (ARRAY layout, 0x81 0x05)
    │   ├── [0] DICT (metadata)
    │   │   ├── "gi" → RAW [4 bytes, gid]
    │   │   ├── "gn" → UTF8 "staff"
    │   │   ├── "md" → RAW [2 bytes, 0o644]
    │   │   ├── "mt" → RAW [8 bytes, ns since epoch]
    │   │   ├── "pa" → UTF8 "README.md"
    │   │   ├── "ui" → RAW [4 bytes, uid]
    │   │   └── "un" → UTF8 "peter"
    │   └── [1] DATA [content + hash]
    └── FILE (ARRAY layout, 0x81 0x05)
        ├── [0] DICT { md: 0o755, mt: ..., pa: "icon.icns", un: "peter" }
        ├── [1] DATA [content + hash]
        └── [2] DICT (forks)                    ← extended forks
            ├── "rf" → RAW [resource fork data]
            └── "user.comment" → RAW [xattr value]
```

## Encoding Process

### Writing an archive (in-memory)

When the full archive is constructed in memory and serialized once, all values are known before any bytes are emitted. No padded BLIPs are needed.

```
1. Sort files by path (for deterministic output)
2. Serialize magic element: RAW("BLIP\x01")
3. For each file:
   a. Build metadata DICT (element 0): 2-char keys in canonical order
   b. Build DATA container (element 1): content bytes + xxHash64 suffix
   c. Optionally build forks DICT (element 2): resource fork, xattrs
   d. Serialize FILE as ARRAY-layout with FILE sentinel (0x81 0x05)
   e. Record FILE's position for body array index
4. For each directory:
   a. Compute Merkle hash from children's ARRAY/DICT hashes
   b. Build DIR DICT with 2-char keys (pa, xh, md, mt, etc.)
5. Build body ARRAY: emit index offset (normal BLIP), data section (FILEs/DIRs),
   index (N, element offsets), xxHash64
6. Build outer ARRAY: emit index offset (normal BLIP), magic + body elements,
   index (2, element offsets), xxHash64
```

### Writing an archive (streaming)

When writing to a stream or file where seeking back is possible but re-emission of the entire container is prohibitively expensive, use padded BLIPs for index offset fields.

```
1. Sort files by path (for deterministic output)
2. Emit outer ARRAY type sentinel + padded Length BLIP (budget for total size)
3. Emit outer ARRAY index offset as padded BLIP (e.g., 12-byte budget)
4. Emit magic element: RAW("BLIP\x01"), record its position
5. Emit body ARRAY type sentinel + padded Length BLIP
6. Emit body ARRAY index offset as padded BLIP
7. For each file:
   a-f. Same as in-memory (FILE containers are small enough to build in memory)
   g. Record FILE's position for body array index
8. Emit body ARRAY index (N, element offsets) + xxHash64
9. Seek back, backfill body ARRAY index offset and Length
10. Emit outer ARRAY index (2, element offsets) + xxHash64
11. Seek back, backfill outer ARRAY index offset and Length
```

If a padded BLIP's budget is exceeded (value doesn't fit), the writer uses the indirect overflow mechanism: set I=1, write a signed offset to a scratch pool entry, and place the actual value there. See §Scratch Pool. In practice, a 12-byte budget covers offsets up to 2^64, making overflow astronomically unlikely.

### Reading an archive

```
1. Verify outer ARRAY sentinel (0x81 0x01)
2. Read Length → know total archive size
3. Optionally verify xxHash64: hash bytes [0..Length-8], compare with [Length-8..Length]
4. Read index offset (consuming padding + PAD_END if padded) → jump to outer index
5. Read element 0 offset → verify magic ("BLIP\x01")
6. Read element 1 offset → jump to body ARRAY
7. Read body ARRAY index offset → jump to body index
8. Read body element count N and offsets
9. For element K: jump to offset K → check container type:
   - FILE (0x81 0x05): parse as ARRAY; element 0 = metadata DICT (read "pa"),
     element 1 = DATA (content + hash)
   - DIR (0x81 0x07): parse as DICT; read "pa" key for path
```

Note: When reading a padded BLIP index offset, the parser reads the BLIP header, extracts the value, then skips any trailing 0x00 padding bytes and the PAD_END sentinel (0x81 0x00). This is handled transparently by the BLIP decoder — no special container-level logic is needed.

### Extracting a single file by path

```
1. Parse outer ARRAY → find body ARRAY (element 1)
2. Parse body ARRAY index → get all N element offsets
3. For each element offset:
   a. Check container type (FILE or DIR)
   b. If FILE: parse as ARRAY → element 0 is metadata DICT → read "pa" key
   c. If DIR: parse as DICT → read "pa" key
   d. Compare path with target
   e. If match (FILE): element 1 is DATA → read content (data_len = value_len - 8)
   f. Done (or continue scanning if not found)
```

For frequent lookups, cache the path→element mapping after first scan.

## Streaming Writes

The format supports streaming writes via **padded BLIPs** (see BLIP Spec §Padded BLIPs). This mechanism replaces ad-hoc padding schemes with a first-class BLIP feature.

### How It Works

1. **Writer** emits the container's index offset field as a padded BLIP with a pre-allocated budget (e.g., 12 bytes). The padded BLIP initially has L=0 (no value yet), followed by padding bytes (0x00), terminated by PAD_END (0x81 0x00).

2. **Writer** emits elements sequentially, recording their positions.

3. **Writer** emits the index and hash.

4. **Writer** seeks back to the padded BLIP field and backfills the actual offset value. The padding bytes absorb the size difference between the initial placeholder and the final value.

### Budget Sizing

A 12-byte padded BLIP budget accommodates offsets up to 2^64:

```
12 bytes = 1 (header) + 8 (u64 value) + 1 (min padding) + 2 (PAD_END)
```

For containers known to be smaller (e.g., FILE dictionaries with a few keys), a smaller budget (6-8 bytes) reduces overhead.

### Overflow

If the actual value exceeds the pre-allocated budget (e.g., the container grew larger than expected), the writer sets the indirect flag (I=1) on the padded BLIP. The value bytes then contain a signed offset to a scratch pool entry where the actual value is stored as a normal BLIP. See §Scratch Pool.

In practice, generous pre-allocation makes overflow astronomically unlikely. The mechanism exists for formal completeness — so that no container, regardless of size, can be in a state where it cannot express a required offset.

Streaming reads are straightforward: to process elements sequentially, ignore the index and read containers one after another. The index is only needed for random access.

## Scratch Pool

Containers that use padded BLIPs for streaming writes MAY reserve a **scratch pool** — a pre-allocated block of 0x00 bytes near the beginning of the container's value area, immediately after the index offset field.

```
┌──────────────────────────────────────────────────┐
│ Type + Length                                    │
│ Index offset: padded BLIP                        │
│ Scratch pool: [0x00 × S bytes]                   │  ← optional
│ DATA SECTION: elements...                        │
│ INDEX SECTION + HASH                             │
└──────────────────────────────────────────────────┘
```

If a padded BLIP overflows (its actual value doesn't fit in the pre-allocated budget), the writer sets I=1 (indirect) on the padded BLIP and writes the signed offset to a position in the scratch pool. At that position, a normal (non-padded) BLIP contains the actual value.

### When to Use a Scratch Pool

The scratch pool is a concern **only** for use cases that expect to emit **very large** containers where re-emission would be prohibitively expensive (multi-terabyte archives, for example). In practice:

- For in-memory construction: **no scratch pool needed**. All values are known before serialization.
- For streaming writes of typical containers (up to multi-GB): **no scratch pool needed**. A 12-byte padded BLIP budget covers offsets up to 2^64.
- For streaming writes of enormous containers where even the Length field might overflow its padding budget: **allocate a small scratch pool** (e.g., 64 bytes) for the rare overflow case.

The scratch pool exists so that the format is **formally complete** — any valid container can be produced without re-emitting, regardless of size. But implementations that target reasonable container sizes (< 2^64 bytes) MAY omit scratch pool support entirely and instead re-emit the container if any padded BLIP overflows.

### Scratch Pool Offsets

When a padded BLIP uses indirection (I=1), the value is a **signed offset from the containing container's start byte** (the first byte of the Type sentinel). This is consistent with the universal offset convention — all offsets in the format are from the container start, including indirect overflow targets.

Because the scratch pool is located between the index offset field and the data section, all offsets pointing into it are positive (the scratch pool comes after the container start). Negative offsets are theoretically possible but reserved for future extensions.

## Determinism

An archive is deterministic (byte-identical given the same inputs) if:

1. Files are sorted lexicographically by path (byte order — see §Key Ordering)
2. All dictionary/file keys are sorted in canonical key order (MUST per §Key Ordering)
3. All BLIP integers use canonical (shortest) encoding
4. xxHash64 is computed consistently (same algorithm, same byte range)
5. Padded BLIP budgets use a fixed, predetermined size (not dependent on content)

For deterministic archives, padded BLIPs are unnecessary — use in-memory construction with normal BLIPs. Padded BLIPs are a streaming write optimization; their variable padding prevents byte-identical output unless the budget is fixed by convention.

## Size Budget

For a typical use case (200 files averaging 50KB each, ~10MB total content):

```
Per-file overhead (FILE as ARRAY with metadata DICT + DATA):
  FILE ARRAY shell:   2 (type) + 3 (length) = 5 bytes
  FILE index offset:  ~3 bytes (BLIP)
  Metadata DICT:      ~5 (shell) + ~3 (idx offset) + ~80 (pa+md+mt keys/values)
                      + ~30 (index) + 8 (hash) ≈ 126 bytes
  DATA container:     2 (type) + 3 (length) + content + 8 (xxHash64) = 13 + content
  FILE index:         ~10 bytes (count + 2 element offsets)
  FILE hash:          8 bytes
  Total per file:     ~165 bytes overhead (+ content)

Body array:
  200 element offsets: ~600 bytes
  Body hash:          8 bytes

Outer array:
  2 element offsets:  ~8 bytes
  Outer hash:         8 bytes

Total overhead:       ~165 × 200 + 600 + 16 ≈ 33.6 KB
Content:              10 MB
Overhead ratio:       0.33%

Compare to tar:       200 × 1024 = 200 KB (2%)
```

## Comparison with tar

| Aspect | tar | BLIP Container |
|--------|-----|----------------|
| Determinism | Format-dependent (GNU/BSD/POSIX differ) | Guaranteed by spec |
| Random access | Sequential scan only | O(1) via index tables |
| Per-file overhead | 512B header + padding to 512B | ~165 bytes (with metadata) |
| Integrity | None built-in | xxHash64 per array/dict |
| Metadata | Fixed set (mtime, uid, gid, mode, etc.) | Extensible key-value pairs |
| Nesting | Flat (no nested containers) | Recursive |
| Streaming write | Yes (append elements, finalize) | Yes (padded BLIP backfill) |
| Streaming read | Yes (sequential headers) | Yes (ignore index, read TLVs) |
| Platform encoding | ASCII (POSIX) or UTF-8 (pax) | UTF-8 only |
| Typed values | No (everything is byte ranges) | Yes (UTF8, RAW, ARRAY, DICT, MAP, FILE, DIR, DATA) |
| Ecosystem | Universal | New (requires BLIP decoder) |
| Compression | External (tar.gz, tar.zst) | External (same — wrap in compression) |

## Security Considerations

1. **Recursive depth:** Containers can nest arbitrarily. Parsers SHOULD enforce a maximum nesting depth (e.g., 64) to prevent stack overflow from malicious inputs.

2. **Length validation:** A container's Length must not exceed the remaining bytes in the enclosing container. Parsers MUST validate this before reading the value.

3. **Index offset validation:** The index offset must point within the container's value section. Parsers MUST validate before jumping.

4. **Duplicate keys:** Dictionary, Map, and Directory containers MUST NOT have duplicate keys. Parsers SHOULD reject duplicates. File containers' metadata DICT must also not have duplicate keys.

5. **Hash verification:** The xxHash64 at the end of arrays and dictionaries provides integrity checking, not cryptographic authentication. It detects accidental corruption but not adversarial tampering. For cryptographic integrity, layer a signature over the archive.

6. **Padded BLIP overflow:** If a parser encounters a padded BLIP with I=1 (indirect), it MUST validate that the target offset falls within the container bounds before following it. Malicious inputs could set indirect offsets pointing outside the container.

## Open Questions

1. **Compression:** Should the format define a standard compression wrapper (e.g., a COMPRESSED container type that wraps another container with zstd/deflate)? Or is external compression (like `archive.blip.zst`) sufficient?

## License

MIT — see [LICENSE](LICENSE).
