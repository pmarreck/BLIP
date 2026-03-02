# LP Container Format v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the v1 TLV container envelope with v2 LP (Length-Payload) format, adding BLAKE3-128 checksums, 4 compression algorithms, and extensible attribute system.

**Architecture:** Bottom-up rewrite: new attribute sigil definitions → LP envelope parser/writer → leaf containers → complex containers (array, dict) → archive layer → compression → FFI → CLI. Each layer builds on the previous. Old v1 code is replaced in-place (no parallel codepath).

**Tech Stack:** Zig 0.15, BLAKE3 (std.crypto.hash.Blake3), z7z (LZMA2), bzip2z (bzip2), xxHash64 (std.hash.XxHash64)

**Design doc:** `docs/plans/2026-02-27-lp-container-format-v2-design.md`

---

## Phase 1: Foundation — Attribute Sigils and LP Envelope

### Task 1: Replace container_types.zig with attribute sigil definitions

**Files:**
- Modify: `src/container_types.zig`

The old ContainerType enum (array=0x01, dict=0x02, ...) becomes attribute sigil definitions. Container types are now BLIP integer IDs, not sentinel bytes.

**Step 1: Write failing tests for new attribute sigils**

Add tests at the bottom of container_types.zig that expect the new types:
- `AttributeSigil` enum: `type_attr = 0x01, comp = 0x10, decomp_len = 0x11, csum = 0x12, sig = 0x20, val = 0x7F`
- `ContainerTypeId` enum: `array = 1, dict = 2, utf8 = 3, data = 4, file = 5, map = 6, dir = 7`
- `CompressionId` enum: `lzma2 = 1, bzip2 = 2, lz4 = 3, zstd = 4`
- `ChecksumId` enum: `crc32 = 1, xxhash64 = 2, blake3_128 = 3`
- `checksumLength(id: ChecksumId) u8` returning 4, 8, or 16
- `attrSentinel(attr: AttributeSigil) [2]u8` returning `{0x81, @intFromEnum(attr)}`
- `parseAttrSigil(buf: []const u8) ?AttributeSigil`

Test that:
- All attribute sentinels are valid BLIP sentinels (via `blip.isSentinel`)
- `attrSentinel` round-trips through `parseAttrSigil`
- `checksumLength` returns correct values for each ID
- PAD_END (0x00) does not parse as an attribute sigil
- Old container type sentinel bytes (0x01-0x09) are NOT valid attribute sigils (since we redefine 0x01 as TYPE attr)

**Step 2: Run tests, verify they fail**

Run: `zig build test 2>&1 | head -30`

**Step 3: Implement the new types**

Replace the old `ContainerType` enum and helpers with the new enums and functions. Keep `SENTINEL_BYTE = 0x81` and `PAD_END_VALUE = 0x00`. Remove old `ContainerType`, `typeSentinel`, `parseType`.

**Step 4: Run tests, verify they pass**

Run: `zig build test`

**Step 5: Fix all compilation errors in dependent files**

Every file that imports `container_types` will break. For now, add `// TODO: v2 migration` comments and stub out broken code to make it compile. The goal is to make `zig build test` pass (existing tests that test v1 behavior will be removed/rewritten in later tasks).

Files that import container_types: `container.zig`, `leaf.zig`, `data.zig`, `array.zig`, `dict.zig`, `mini_blar.zig`, `lib.zig`, `peek.zig`, `poke.zig`, `json_serde.zig`, `lzma2.zig`

**Step 6: Commit**

```
git add src/container_types.zig
git commit -m "refactor: replace ContainerType enum with v2 attribute sigils and type IDs"
```

---

### Task 2: Rewrite container.zig for LP envelope

**Files:**
- Modify: `src/container.zig`

Replace TLV header parsing/writing with LP envelope parsing/writing.

**Step 1: Write failing tests for LP envelope**

Test the new LP functions:

- `computeLPLength(type_id, val_size, options)` where options includes optional comp_id, decomp_len, csum_id
  - Test: simple container (TYPE + VAL only) → `blip_size(total) + 2 + blip_size(type_id) + 2 + val_size = total`
  - Test: with CSUM → adds `2 + blip_size(csum_id) + checksum_length`
  - Test: with COMP + DECOMP_LEN → adds `2 + blip_size(comp_id) + 2 + blip_size(decomp_len)`

- `writeLPHeader(buf, type_id, options)` → writes `[BLIP(total)] [TYPE sentinel] [BLIP(type_id)] [optional attrs] [VAL sentinel]`, returns bytes written (header size)

- `parseLPHeader(buf)` → returns `LPContainerView { total_length, type_id, comp_id, decomp_len, csum_id, val_offset, val_size, checksum_offset }`

- Test round-trip: write LP header, parse it back, verify all fields match

**Step 2: Run tests, verify they fail**

**Step 3: Implement LP envelope**

Key implementation details:
- Self-referential length: fixpoint iteration (same technique as v1 `computeTotalLength`, but equation is `total = blip_size(total) + attr_overhead + val_size`)
- Attribute overhead: sum of `2 + blip_size(value)` for each present attribute, except VAL which is just `2` (sentinel only, no explicit length)
- `val_size` for the caller includes the checksum bytes if a checksum is present
- Parse must handle: scan attributes in order by sigil, stop at VAL sentinel, compute val_size from remaining bytes

New structs:
```zig
pub const LPOptions = struct {
    comp_id: ?u8 = null,
    decomp_len: ?u64 = null,
    csum_id: ?u8 = null,
    // csum_len is derived from csum_id via checksumLength()
};

pub const LPContainerView = struct {
    total_length: u64,
    type_id: u64,
    comp_id: ?u8,
    decomp_len: ?u64,
    csum_id: ?u8,
    val_offset: usize,  // offset from container start to first byte after VAL sentinel
    val_size: usize,     // total bytes in VAL (payload + checksum)
    buf: []const u8,
};
```

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "feat: implement LP envelope parser and writer for v2 container format"
```

---

### Task 3: Add BLAKE3-128 checksum support

**Files:**
- Create: `src/checksum.zig`

Unified checksum module that handles all 3 algorithms.

**Step 1: Write failing tests**

- `computeChecksum(csum_id, data) → [16]u8` (returns fixed-size buffer, actual length depends on algorithm)
- `checksumSlice(csum_id, result) → []const u8` (returns the meaningful bytes: 4 for CRC32, 8 for xxHash64, 16 for BLAKE3-128)
- `verifyChecksum(csum_id, data, expected_bytes) → bool`

Test each algorithm:
- CRC32: known test vector
- xxHash64: known test vector (seed 0)
- BLAKE3-128: known test vector (first 16 bytes of BLAKE3 output)

**Step 2: Run tests, verify they fail**

**Step 3: Implement**

```zig
const std = @import("std");
const Blake3 = std.crypto.hash.Blake3;
const XxHash64 = std.hash.XxHash64;
const Crc32 = std.hash.crc.Crc32IsoHdlc;
const ct = @import("container_types.zig");

pub fn compute(csum_id: ct.ChecksumId, data: []const u8) [16]u8 {
    var result: [16]u8 = .{0} ** 16;
    switch (csum_id) {
        .crc32 => {
            const hash = Crc32.hash(data);
            std.mem.writeInt(u32, result[0..4], hash, .little);
        },
        .xxhash64 => {
            const hash = XxHash64.hash(0, data);
            std.mem.writeInt(u64, result[0..8], hash, .little);
        },
        .blake3_128 => {
            Blake3.hash(data, result[0..16], .{});
        },
    }
    return result;
}

pub fn length(csum_id: ct.ChecksumId) u8 {
    return ct.checksumLength(csum_id);
}

pub fn verify(csum_id: ct.ChecksumId, data: []const u8, expected: []const u8) bool {
    const computed = compute(csum_id, data);
    const len = length(csum_id);
    return std.mem.eql(u8, computed[0..len], expected[0..len]);
}
```

**Step 4: Run tests, verify they pass**

**Step 5: Add to blip.zig imports and test block**

**Step 6: Commit**

```
git commit -m "feat: add unified checksum module with CRC32, xxHash64, BLAKE3-128"
```

---

## Phase 2: Leaf and Data Containers

### Task 4: Rewrite leaf.zig for LP format

**Files:**
- Modify: `src/leaf.zig`

**Step 1: Write failing tests**

- `serializeUtf8(allocator, "hello")` produces LP-format bytes: `[BLIP(total)] [0x81 0x01] [0x03] [0x81 0x7F] "hello"`
- `serializeData(allocator, bytes)` produces: `[BLIP(total)] [0x81 0x01] [0x04] [0x81 0x7F] <bytes>`
- `readLeafValue(buf)` extracts the payload from VAL section
- Round-trip: serialize then read back, content matches

Note: inner containers (nested inside arrays/dicts) have NO checksum by default. Top-level containers get BLAKE3-128.

**Step 2: Run tests, verify they fail**

**Step 3: Implement using new container.zig LP functions**

The old `serializeLeaf` becomes:
```zig
fn serializeLeaf(allocator: Allocator, type_id: ct.ContainerTypeId, payload: []const u8, options: LPOptions) Error![]u8 {
    // Use container.writeLPHeader + payload
}
```

The old `readLeafValue` becomes:
```zig
pub fn readLeafValue(buf: []const u8) Error![]const u8 {
    const view = try container.parseLPHeader(buf);
    return buf[view.val_offset..][0..view.val_size];
}
```

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "refactor: rewrite leaf.zig for v2 LP container format"
```

---

### Task 5: Remove old data.zig, merge into leaf.zig

**Files:**
- Modify: `src/leaf.zig` (add serializeData with optional CSUM)
- Remove: `src/data.zig` (functionality absorbed into leaf.zig)
- Modify: `src/blip.zig` (update imports)

**Step 1: Write failing tests**

- `serializeData(allocator, bytes, .{ .csum_id = .xxhash64 })` → LP container with DATA type, CSUM attribute, and trailing xxHash64
- `serializeData(allocator, bytes, .{ .csum_id = .blake3_128 })` → LP with BLAKE3-128 checksum
- `serializeData(allocator, bytes, .{})` → LP with no checksum (inner container default)
- `verifyChecksum(buf)` → validate checksum if present
- `readDataContent(buf)` → extract data bytes (excluding checksum if present)

**Step 2: Run tests, verify they fail**

**Step 3: Implement**

`serializeData` now uses `writeLPHeader` with the CSUM option, appends payload + checksum. The checksum is computed over everything from byte 0 to end of payload.

**Step 4: Run tests, verify they pass**

**Step 5: Remove old data.zig, update all imports**

**Step 6: Commit**

```
git commit -m "refactor: merge data.zig into leaf.zig, add configurable checksums"
```

---

## Phase 3: Complex Containers (Array, Dict)

### Task 6: Rewrite array.zig for LP format

**Files:**
- Modify: `src/array.zig`

**Step 1: Write failing tests**

- Serialize an ARRAY with 2 UTF8 elements → LP format with TYPE=1, VAL contains index_offset + elements + index + optional checksum
- `ArrayReader.init(buf)` parses LP header, finds VAL section, reads index_offset
- `ArrayReader.elementAt(0)` returns first element
- `ArrayReader.verifyHash()` checks checksum if CSUM attribute present
- Round-trip: serialize 3 elements, read each back

**Step 2: Run tests, verify they fail**

**Step 3: Implement**

Key change: the fixpoint iteration now solves:
```
total = blip_size(total) + type_attr_size + [csum_attr_size] + val_sentinel_size + val_payload_size
val_payload_size = blip_size(index_offset) + data_size + index_size + checksum_bytes
```

`serializeArrayLike` takes `type_id: ContainerTypeId` instead of `ContainerType`, plus `LPOptions`.

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "refactor: rewrite array.zig for v2 LP container format"
```

---

### Task 7: Rewrite dict.zig for LP format

**Files:**
- Modify: `src/dict.zig`

Same pattern as Task 6 but for DICT/MAP/DIR containers.

**Step 1: Write failing tests for dict serialization and reading in LP format**

**Step 2: Run tests, verify they fail**

**Step 3: Implement — same LP wrapping strategy as array.zig**

Key: `serializeDictLike` takes `type_id` + `LPOptions`. Internal structure (interleaved keys/values, index section) unchanged.

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "refactor: rewrite dict.zig for v2 LP container format"
```

---

## Phase 4: Archive Layer

### Task 8: Update mini_blar.zig for v2 format

**Files:**
- Modify: `src/mini_blar.zig`

**Step 1: Write failing tests**

- `createArchive` produces MBAR v2 archive (magic "MBAR\x02")
- `createFullArchive` produces BLAR v2 archive (magic "BLAR\x02")
- `ArchiveReader.init` accepts v2 archives
- Round-trip: create archive with 2 files, read back paths and content

**Step 2: Run tests, verify they fail**

**Step 3: Implement**

- Update MAGIC_BLAR to `"BLAR\x02"` and MAGIC_MBAR to `"MBAR\x02"`
- Update `serializeFileEntry` to use LP-based leaf/array/dict functions
- Update `serializeDirEntry` to use LP-based dict functions
- Update `ArchiveReader` to parse LP containers
- Top-level archive ARRAY gets BLAKE3-128 checksum (default, no explicit CSUM attr needed)

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "feat: update archive format to v2 with LP containers and BLAKE3-128"
```

---

## Phase 5: Compression

### Task 9: Update LZMA2 for LP attribute-based compression

**Files:**
- Modify: `src/lzma2.zig`

**Step 1: Write failing tests**

- `compressContainer` wraps a container with COMP=1 (LZMA2), DECOMP_LEN, and BLAKE3-128 checksum
- `decompressContainer` reads COMP attribute, decompresses VAL payload, returns original bytes
- Round-trip: compress then decompress, bytes match

**Step 2: Run tests, verify they fail**

**Step 3: Implement**

The old LZMA2 container (type 0x09) becomes a regular container with COMP attribute:
```
[BLIP(total)] [TYPE=<original_type>] [COMP=1] [DECOMP_LEN=N] [CSUM=3] [VAL] [compressed_data] [BLAKE3-128]
```

Note: compressed containers preserve the original TYPE. The COMP attribute signals that VAL is compressed.

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "refactor: LZMA2 compression uses LP COMP attribute instead of dedicated container type"
```

---

### Task 10: Add bzip2 compression via bzip2z dependency

**Files:**
- Modify: `build.zig.zon` (add bzip2z dependency)
- Modify: `build.zig` (wire up bzip2z module)
- Create: `src/compression.zig` (unified compression interface)

**Step 1: Add bzip2z dependency to build.zig.zon**

Same pattern as z7z: GitHub URL + hash.

**Step 2: Write failing tests**

- `compress(allocator, .bzip2, data)` → compressed bytes
- `decompress(allocator, .bzip2, compressed, decomp_len)` → original bytes
- Round-trip test

**Step 3: Implement unified compression module**

```zig
pub fn compress(allocator: Allocator, algo: ct.CompressionId, data: []const u8) Error![]u8
pub fn decompress(allocator: Allocator, algo: ct.CompressionId, data: []const u8, decomp_len: u64) Error![]u8
```

For LZMA2: delegates to z7z encoder / std.compress.lzma2.
For bzip2: delegates to bzip2z.
For LZ4/zstd: returns error.UnsupportedCompression (stub).

**Step 4: Run tests, verify they pass**

**Step 5: Commit**

```
git commit -m "feat: add bzip2 compression via bzip2z, unified compression module"
```

---

### Task 11: Stub LZ4 and zstd compression

**Files:**
- Modify: `src/compression.zig`

Add LZ4 and zstd entries that return `error.UnsupportedCompression` for now. These can be filled in when pure Zig implementations become available.

**Step 1: Write tests that LZ4/zstd compress returns UnsupportedCompression error**

**Step 2: Implement the stubs**

**Step 3: Commit**

```
git commit -m "feat: stub LZ4 and zstd compression (returns UnsupportedCompression)"
```

---

## Phase 6: FFI, Peek, Poke, JSON

### Task 12: Update lib.zig (C FFI) for v2

**Files:**
- Modify: `src/lib.zig`
- Modify: `src/blip.h`

C API signatures stay the same. Internal implementation calls v2 functions. Add new compression-related FFI functions.

**Step 1: Write FFI tests that create archives, verify, extract with v2 format**

**Step 2: Update implementation to call v2 functions**

**Step 3: Add new error codes for unsupported compression**

**Step 4: Update blip.h with any new function declarations**

**Step 5: Commit**

```
git commit -m "refactor: update C FFI to use v2 LP container format"
```

---

### Task 13: Update peek.zig for LP format

**Files:**
- Modify: `src/peek.zig`

The peek module navigates container trees. It needs to understand LP attribute layout to find the VAL section and navigate into nested containers.

**Step 1: Write tests for peek navigating v2 containers**

**Step 2: Update container type detection to use LP parsing (parseLPHeader)**

**Step 3: Update path resolution to account for LP attribute offsets**

**Step 4: Update display formatting for new attributes (show COMP, CSUM info)**

**Step 5: Commit**

```
git commit -m "refactor: update peek.zig for v2 LP container navigation"
```

---

### Task 14: Update poke.zig for LP format

**Files:**
- Modify: `src/poke.zig`

Same approach as peek — update container navigation for LP layout.

**Step 1-4: Tests, implement, verify, commit**

```
git commit -m "refactor: update poke.zig for v2 LP container modification"
```

---

### Task 15: Update json_serde.zig for LP format

**Files:**
- Modify: `src/json_serde.zig`

JSON serialization/deserialization must understand LP attributes.

**Step 1-4: Tests, implement, verify, commit**

```
git commit -m "refactor: update JSON serde for v2 LP container format"
```

---

## Phase 7: CLI and Shell Tests

### Task 16: Update C CLI for v2

**Files:**
- Modify: `src/blar.c`
- Modify: `src/miniblar.c`
- Modify: `src/blar_common.h`

The CLI calls through the C FFI, so most changes are minimal. Key updates:
- Remove v1 LZMA2 sentinel detection in `read_archive()` — now uses LP COMP attribute
- Add compression algorithm flag (`-z lzma2`, `-z bzip2`) instead of just `-z`
- Update help text

**Step 1: Update read_archive() to detect v2 COMP attribute instead of hardcoded 0x81 0x09**

**Step 2: Update -z flag to accept algorithm name**

**Step 3: Commit**

```
git commit -m "refactor: update CLI tools for v2 LP container format"
```

---

### Task 17: Update all shell tests for v2

**Files:**
- Modify: `tests/binary_format_test.sh`
- Modify: `tests/blar_test.sh`
- Modify: `tests/miniblar_test.sh`
- Modify: `tests/blar_full_test.sh`
- Modify: `tests/peek_test.sh`
- Modify: `tests/poke_test.sh`
- Modify: `tests/json_test.sh`
- Modify: `tests/lzma2_test.sh`

Key changes:
- Magic byte checks: `MBAR\x02` and `BLAR\x02` instead of `\x01`
- Sentinel checks: look for TYPE attribute sentinel (0x81 0x01) instead of container type sentinels
- Compression tests: test bzip2 alongside LZMA2
- Checksum tests: verify BLAKE3-128 is used at top level

**Step 1: Update each test file, run, verify all pass**

**Step 2: Commit**

```
git commit -m "test: update all shell tests for v2 LP container format"
```

---

### Task 18: Final integration test and cleanup

**Step 1: Run full test suite**

```bash
zig build test
for t in tests/*.sh; do bash "$t"; done
```

**Step 2: Remove any remaining v1 dead code, TODO comments**

**Step 3: Update README.md with v2 format description**

**Step 4: Final commit and push**

```
git commit -m "feat: complete v2 LP container format migration"
git push
```

---

## Dependency Graph

```
Task 1 (attribute sigils) ──┐
                             ├── Task 2 (LP envelope) ──┐
Task 3 (checksums) ─────────┘                           │
                                                        ├── Task 4 (leaf.zig)
                                                        │
                                                        ├── Task 5 (data → leaf merge)
                                                        │
                                                        ├── Task 6 (array.zig) ──┐
                                                        │                        │
                                                        ├── Task 7 (dict.zig) ───┤
                                                        │                        │
                                                        └────────────────────────┼── Task 8 (mini_blar.zig) ──┐
                                                                                 │                            │
                                                        Task 9 (LZMA2 update) ──┤                            │
                                                                                 │                            │
                                                        Task 10 (bzip2) ────────┤                            │
                                                                                 │                            │
                                                        Task 11 (LZ4/zstd stub) ┘                            │
                                                                                                              │
                                                        Task 12 (FFI) ───────────────────────────────────────┤
                                                        Task 13 (peek) ──────────────────────────────────────┤
                                                        Task 14 (poke) ──────────────────────────────────────┤
                                                        Task 15 (json_serde) ────────────────────────────────┤
                                                                                                              │
                                                        Task 16 (C CLI) ─────────────────────────────────────┤
                                                        Task 17 (shell tests) ───────────────────────────────┤
                                                        Task 18 (integration + cleanup) ─────────────────────┘
```

## Notes

- **TDD discipline:** Every task starts with a failing test. No exceptions.
- **Commit frequently:** Each task gets its own commit.
- **Parallelizable tasks:** Tasks 6+7 (array+dict) can run in parallel. Tasks 9+10+11 (compression) can run in parallel. Tasks 12-15 (FFI+peek+poke+json) can run in parallel.
- **Build must pass between tasks:** `zig build test` must succeed after each task. Stubs are acceptable for not-yet-migrated code.
- **No v1 backwards compat:** Old format code is deleted, not maintained alongside new code.
