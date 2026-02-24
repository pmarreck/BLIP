# BLIP Container Format

A recursive, typed, self-indexed binary container format built on [BLIP encoding](BLIP_SPEC.md). Designed as a compact, deterministic, integrity-verified alternative to tar and similar archive formats.

**Author:** Peter Marreck
**Version:** 1.1 (2026-02-23)
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
┌──────────────────────────────────────────────────────────┐
│ Type:   BLIP sentinel (2 bytes: 0x81 + type byte)        │
│ Length: BLIP integer (total container size in bytes,      │
│         INCLUDING Type bytes + Length bytes + Value bytes) │
│ Value:  payload (type-specific)                           │
└──────────────────────────────────────────────────────────┘
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
0x81 0x05       FILE            Specialized sorted dictionary (required keys: path, xh64, bina)
0x81 0x06       MAP             Unsorted key-value pairs, indexed + hashed (insertion order)
0x81 0x07       DIR             Specialized sorted dictionary (required keys: path, xh64; no bina)
0x81 0x08 - 0x81 0x0F          Reserved (future container types)
0x81 0x10 - 0x81 0x7F          Application-defined types
```

## Offset Convention

All offsets within a container are measured **from the start of the containing container** (the first byte of the container's Type sentinel). This convention is universal — it does not vary by container type. See BLIP Spec §Offset and Length Convention for the full specification.

Offsets MAY be negative (signed two's complement) when pointing into a scratch pool that precedes the target data. This is relevant only for the indirect overflow mechanism in padded BLIPs (see §Scratch Pool below).

## Key Ordering

Dictionary (DICT), File (FILE), and Directory (DIR) containers store key-value pairs in a canonical sort order. Map (MAP) containers are exempt — they preserve insertion order. For DICT, FILE, and DIR, keys MUST be sorted in **lexicographic byte order** — the same ordering as `memcmp`.

**Rules:**
1. Compare keys byte-by-byte using unsigned byte values (0x00 < 0x01 < ... < 0xFF)
2. If one key is a prefix of another, the shorter key sorts first
3. This applies uniformly to all keys regardless of container type (UTF8 or RAW)
4. UTF8 keys are compared by their raw byte representation, not by Unicode codepoint or collation order

**Examples (sorted):**
```
"a"       (0x61)
"aa"      (0x61 0x61)
"ab"      (0x61 0x62)
"b"       (0x62)
"bina"    (0x62 0x69 0x6E 0x61)
"mode"    (0x6D 0x6F 0x64 0x65)
"mtime"   (0x6D 0x74 0x69 0x6D 0x65)
"path"    (0x70 0x61 0x74 0x68)
"xattr"   (0x78 0x61 0x74 0x74 0x72)
"xh64"    (0x78 0x68 0x36 0x34)
```

**Rationale:** Byte ordering is unambiguous, locale-independent, trivial to implement, and works identically for UTF8 and RAW keys. It also means that keys in the index section are in a known order, enabling binary search for key lookup in dictionaries with many keys.

Encoders MUST emit key-value pairs in canonical key order for DICT, FILE, and DIR containers. Decoders SHOULD reject DICT/FILE/DIR containers with out-of-order keys as malformed. MAP containers are exempt from ordering requirements.

## Container Types

### UTF8 String (0x81 0x03)

A UTF-8 encoded string. Value is the raw string bytes (no null terminator).

```
┌─────────────────────────────────────┐
│ Type:   0x81 0x03                   │
│ Length: BLIP(total)                 │
│ Value:  raw UTF-8 bytes            │
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
│ Value:  raw bytes                  │
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
│   │   Offset 0: BLIP(off_0)  ← from array container start   │   │
│   │   Offset 1: BLIP(off_1)                                 │   │
│   │   ...                                                    │   │
│   │   Offset N-1: BLIP(off_N-1)                             │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ HASH: xxHash64 (8 bytes, fixed)                          │   │
│   │   Hash of all bytes from array container start            │   │
│   │   through end of INDEX SECTION (everything except         │   │
│   │   these 8 hash bytes). These 8 bytes DO count             │   │
│   │   towards the container's total Length.                    │   │
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
│   │   Pair 0: BLIP(key_0) BLIP(val_0)                       │   │
│   │   Pair 1: BLIP(key_1) BLIP(val_1)                       │   │
│   │   ...                                                    │   │
│   │   Pair N-1: BLIP(key_N-1) BLIP(val_N-1)                 │   │
│   │   All offsets from dictionary container start.            │   │
│   ├──────────────────────────────────────────────────────────┤   │
│   │ HASH: xxHash64 (8 bytes)                                 │   │
│   │   Same semantics as array hash.                           │   │
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

A specialized dictionary representing a directory in an archive. Like FILE, has required keys but does NOT contain file content (`bina`).

```
┌────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x07                                         │
│ Length:  BLIP(total)                                       │
│ Value:   (dictionary structure — index, data, hash)        │
│                                                            │
│ Required keys:                                             │
│   "path"  → UTF8: relative path, forward-slash separated,  │
│              normalized, no leading slash, UTF-8            │
│   "xh64"  → RAW: 8-byte Merkle hash (see below)           │
│                                                            │
│ Optional keys (examples):                                  │
│   "mtime" → RAW: modification time (8-byte LE int64 ns)   │
│   "mode"  → RAW: POSIX permissions (2-byte LE uint16)     │
│   "owner" → UTF8: owner name                               │
│                                                            │
│ DIR containers follow dictionary layout (index + hash).    │
│ DIR containers do NOT have a "bina" key.                   │
└────────────────────────────────────────────────────────────┘
```

**Merkle hash algorithm:** The `xh64` value for a DIR entry is a Merkle hash computed from its direct children:

1. Collect the `xh64` values of all direct children (files and subdirectories) sorted by path
2. Concatenate these 8-byte hashes in sorted-path order
3. Compute `xxHash64(child_0_xh64 || child_1_xh64 || ... || child_N_xh64)` with seed 0

This produces a bottom-up hash tree: leaf files have `xh64 = xxHash64(file_content)`, leaf directories (empty or containing only files) hash their children's xh64 values, and parent directories hash their children's (already-computed) xh64 values.

**Merkle hash properties:**
- Changing any file's content changes its xh64, which propagates up through all ancestor directory hashes to the root
- Verifying the root directory's Merkle hash transitively verifies every file and subdirectory in the tree
- Individual subtrees can be verified independently

### Map (0x81 0x06)

An unsorted collection of key-value pairs with a trailing index and hash. Identical layout to Dictionary (0x81 0x02), but keys are stored in **insertion order** rather than canonical key order.

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x06                                               │
│ Length:  BLIP(total)                                             │
│ Value:   (same layout as Dictionary — index offset, data,        │
│           index section, xxHash64)                                │
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

### File (0x81 0x05)

A specialized dictionary representing a file in an archive. Has required keys and allows arbitrary additional keys for metadata.

```
┌────────────────────────────────────────────────────────────┐
│ Type:    0x81 0x05                                         │
│ Length:  BLIP(total)                                       │
│ Value:   (dictionary structure — index, data, hash)        │
│                                                            │
│ Required keys:                                             │
│   "path"  → UTF8: relative path, forward-slash separated,  │
│              normalized, no leading slash, UTF-8            │
│   "xh64"  → RAW: 8-byte xxHash64 of the file content      │
│   "bina"  → RAW: the file content bytes                    │
│                                                            │
│ Optional keys (examples):                                  │
│   "mtime" → RAW: modification time (platform encoding)     │
│   "mode"  → RAW: POSIX permissions                         │
│   "owner" → UTF8: owner name                               │
│   "xattr" → DICT: extended attributes                      │
│   ...any UTF8 or RAW key with any container value...       │
│                                                            │
│ File containers follow dictionary layout (index + hash).   │
└────────────────────────────────────────────────────────────┘
```

**Path normalization:**
- Forward slashes only (`/`), never backslashes
- No leading slash (relative to archive root)
- No `.` or `..` components
- UTF-8 encoded, NFC normalized
- Example: `src/core/main.zig`

**Metadata keys:** Applications can store any additional key-value pairs. Use platform-applicable keys as appropriate (POSIX, Windows, macOS). Clients SHOULD parse best-effort — ignore keys they don't understand. Key names SHOULD be short (4-8 chars) to minimize overhead.

## Archive Format

A complete archive (the "tar replacement") is a top-level **Array** container:

```
Archive (ARRAY):
  Element 0: RAW containing magic bytes: "BLIP" + version byte (0x01)
  Element 1: ARRAY (body) containing:
    Element 0: DIR  { path: "src",          xh64: [Merkle hash] }
    Element 1: FILE { path: "src/main.zig", xh64: ..., bina: ... }
    Element 2: FILE { path: "src/lib.zig",  xh64: ..., bina: ... }
    ...
    Element N-1: FILE or DIR { ... }
```

The body array may contain both FILE (0x81 0x05) and DIR (0x81 0x07) entries. DIR entries represent directories explicitly, enabling storage of directory metadata (permissions, mtime, owner). Archives without DIR entries are valid — directories are then implicit from file paths.

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
    └── FILE                                    ← single file
        ├── "bina" → RAW "Hello, world!\n"      ← keys in byte order
        ├── "path" → UTF8 "hello.txt"
        └── "xh64" → RAW [8 bytes xxHash64]
```

### Archive with directories

```
ARRAY                                           ← top-level archive
├── RAW "BLIP\x01"
└── ARRAY                                       ← body
    ├── DIR                                     ← directory entry
    │   ├── "mode"  → RAW [2 bytes, 0o755]
    │   ├── "mtime" → RAW [8 bytes, nanoseconds]
    │   ├── "path"  → UTF8 "src"
    │   └── "xh64"  → RAW [8 bytes, Merkle hash of children]
    ├── FILE
    │   ├── "bina"  → RAW [file contents]
    │   ├── "path"  → UTF8 "src/lib.zig"
    │   └── "xh64"  → RAW [8 bytes]
    └── FILE
        ├── "bina"  → RAW [file contents]
        ├── "path"  → UTF8 "src/main.zig"
        └── "xh64"  → RAW [8 bytes]
```

The DIR entry's `xh64` is `xxHash64(xh64_of_lib.zig || xh64_of_main.zig)` — a Merkle hash of its children's hashes, concatenated in path-sorted order.

### Archive with metadata

```
ARRAY                                           ← top-level archive
├── RAW "BLIP\x01"
└── ARRAY                                       ← body
    ├── FILE                                    ← keys in canonical byte order
    │   ├── "bina"  → RAW [file contents]
    │   ├── "mode"  → RAW [2 bytes, 0o644]
    │   ├── "mtime" → RAW [8 bytes, unix epoch nanoseconds]
    │   ├── "path"  → UTF8 "README.md"
    │   └── "xh64"  → RAW [8 bytes]
    └── FILE
        ├── "bina"  → RAW [file contents]
        ├── "path"  → UTF8 "src/main.zig"
        ├── "xattr" → DICT                     ← nested sorted dictionary
        │   ├── "security.selinux" → RAW [...]
        │   └── "user.comment" → UTF8 "entry point"
        └── "xh64"  → RAW [8 bytes]
```

## Encoding Process

### Writing an archive (in-memory)

When the full archive is constructed in memory and serialized once, all values are known before any bytes are emitted. No padded BLIPs are needed.

```
1. Sort files by path (for deterministic output)
2. Serialize magic element: RAW("BLIP\x01")
3. For each file:
   a. Serialize key-value pairs as containers
   b. Compute file content xxHash64 → "xh64" value
   c. Build FILE dictionary: emit data section, record key/value offsets
   d. Emit FILE index (N, key offsets, value offsets)
   e. Compute and emit FILE xxHash64
   f. Record FILE's position for body array index
4. Build body ARRAY: emit index offset (normal BLIP), data section (FILEs),
   index (N, element offsets), xxHash64
5. Build outer ARRAY: emit index offset (normal BLIP), magic + body elements,
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
9. For element K: jump to offset K → read FILE container
10. Read FILE index → find "path", "xh64", "bina" keys by scanning key offsets
```

Note: When reading a padded BLIP index offset, the parser reads the BLIP header, extracts the value, then skips any trailing 0x00 padding bytes and the PAD_END sentinel (0x81 0x00). This is handled transparently by the BLIP decoder — no special container-level logic is needed.

### Extracting a single file by path

```
1. Parse outer ARRAY → find body ARRAY (element 1)
2. Parse body ARRAY index → get all N element offsets
3. For each element offset:
   a. Jump to FILE container
   b. Parse FILE index → find "path" key offset
   c. Read path value → compare with target path
   d. If match: find "bina" key offset → read file content
   e. Done (or continue scanning if not found)
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
│ Type + Length                                      │
│ Index offset: padded BLIP                          │
│ Scratch pool: [0x00 × S bytes]                     │  ← optional
│ DATA SECTION: elements...                          │
│ INDEX SECTION + HASH                               │
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
Per-file overhead:
  FILE TLV shell:     2 (type) + 3 (length) = 5 bytes
  path key+value:     8 ("path" TLV) + ~20 (path string TLV) = ~28 bytes
  xh64 key+value:     8 ("xh64" TLV) + 12 (8-byte hash TLV) = 20 bytes
  bina key+value:     8 ("bina" TLV) + 5 (RAW TLV shell) + content = ~13 + content
  FILE index:         ~40 bytes (count + 3 key offsets + 3 value offsets)
  FILE hash:          8 bytes
  Total per file:     ~114 bytes overhead (+ content)

Body array:
  200 element offsets: ~600 bytes
  Body hash:          8 bytes

Outer array:
  2 element offsets:  ~8 bytes
  Outer hash:         8 bytes

Total overhead:       ~114 × 200 + 600 + 16 ≈ 23.4 KB
Content:              10 MB
Overhead ratio:       0.23%

Compare to tar:       200 × 1024 = 200 KB (2%)
```

## Comparison with tar

| Aspect | tar | BLIP Container |
|--------|-----|----------------|
| Determinism | Format-dependent (GNU/BSD/POSIX differ) | Guaranteed by spec |
| Random access | Sequential scan only | O(1) via index tables |
| Per-file overhead | 512B header + padding to 512B | ~114 bytes |
| Integrity | None built-in | xxHash64 per array/dict |
| Metadata | Fixed set (mtime, uid, gid, mode, etc.) | Extensible key-value pairs |
| Nesting | Flat (no nested containers) | Recursive |
| Streaming write | Yes (append elements, finalize) | Yes (padded BLIP backfill) |
| Streaming read | Yes (sequential headers) | Yes (ignore index, read TLVs) |
| Platform encoding | ASCII (POSIX) or UTF-8 (pax) | UTF-8 only |
| Typed values | No (everything is byte ranges) | Yes (UTF8, RAW, ARRAY, DICT, MAP, FILE, DIR) |
| Ecosystem | Universal | New (requires BLIP decoder) |
| Compression | External (tar.gz, tar.zst) | External (same — wrap in compression) |

## Security Considerations

1. **Recursive depth:** Containers can nest arbitrarily. Parsers SHOULD enforce a maximum nesting depth (e.g., 64) to prevent stack overflow from malicious inputs.

2. **Length validation:** A container's Length must not exceed the remaining bytes in the enclosing container. Parsers MUST validate this before reading the value.

3. **Index offset validation:** The index offset must point within the container's value section. Parsers MUST validate before jumping.

4. **Duplicate keys:** Dictionary, Map, and File containers MUST NOT have duplicate keys. Parsers SHOULD reject duplicates.

5. **Hash verification:** The xxHash64 at the end of arrays and dictionaries provides integrity checking, not cryptographic authentication. It detects accidental corruption but not adversarial tampering. For cryptographic integrity, layer a signature over the archive.

6. **Padded BLIP overflow:** If a parser encounters a padded BLIP with I=1 (indirect), it MUST validate that the target offset falls within the container bounds before following it. Malicious inputs could set indirect offsets pointing outside the container.

## Open Questions

1. **Compression:** Should the format define a standard compression wrapper (e.g., a COMPRESSED container type that wraps another container with zstd/deflate)? Or is external compression (like `archive.blip.zst`) sufficient?

2. **Symbolic links:** Should FILE containers support a "link" key (target path as UTF8) as an alternative to "bina"? Or are symlinks out of scope?

3. ~~**Empty directories:** Should the format represent empty directories?~~ **Resolved:** The DIR container type (0x81 0x07) explicitly represents directories, including empty ones. Directories can also be implicit from file paths in archives that omit DIR entries.

4. **Maximum container size:** The format is theoretically unlimited (BLIP integers are unbounded). Should we define a practical maximum (e.g., 2^63 bytes) for interoperability?

## License

MIT — see [LICENSE](LICENSE).
