# BLIP Container Library + miniBLIP Design

**Date:** 2026-02-23
**Status:** Approved

## Goal

Implement the BLIP Container Format (BLIP_CONTAINER_SPEC.md v1.1) as a Zig library with C FFI, plus a "miniBLIP" high-level API for entropy_shield's virtual manifest use case.

## Decisions

- **Architecture:** Layered module stack (one file per container type)
- **miniBLIP scope:** ARRAY + FILE (as sorted DICT) + UTF8 keys + RAW values + xxHash64 on outer ARRAY
- **Repo:** Same repo (pmarreck/BLIP), entropy_shield imports as dependency
- **C FFI:** Both Zig module and C API
- **xxHash64:** Use std.hash.XxHash64
- **Writer API:** Pre-serialized composable KeyValue pairs
- **Reader API:** Zero-copy views with index-based random access

## Module Layout

```
src/
  container.zig         -- ContainerType enum, TLV header read/write,
                           self-referential length solver, type dispatch
  container_types.zig   -- sentinel byte constants, type<->sentinel mapping
  leaf.zig              -- UTF8 + RAW serialize/parse
  array.zig             -- ARRAY serialize/parse, index table, xxHash64
  dict.zig              -- DICT/MAP/FILE serialize/parse, key ordering, index
  mini_blip.zig         -- high-level miniBLIP API (createArchive, readArchive)
  container_lib.zig     -- C FFI exports for container operations
  container.h           -- C header for container FFI
```

## Data Model

```zig
pub const ContainerType = enum(u7) {
    array = 0x01, dict = 0x02, utf8 = 0x03,
    raw = 0x04, file = 0x05, map = 0x06,
};
```

Writer builds containers bottom-up (leaves first), serializes to `[]u8`. Reader parses from `[]const u8` zero-copy via ContainerView, ArrayReader, DictReader structs.

## Writer API

- `leaf.serializeUtf8(allocator, text) -> []u8`
- `leaf.serializeRaw(allocator, data) -> []u8`
- `dict.serializeDict(allocator, pairs) -> []u8` (canonical key order)
- `dict.serializeFile(allocator, pairs) -> []u8` (validates required keys)
- `array.serializeArray(allocator, elements) -> []u8` (index + xxHash64)
- `mini_blip.createArchive(allocator, files) -> []u8`

Self-referential length: iterate to find L where `2 + blip_size(L) + V_size == L`.

## Reader API

- `container.parseHeader(buf) -> ContainerView`
- `array.readArray(buf) -> ArrayReader` (elementAt, elementCount, verifyHash)
- `dict.readDict(buf) -> DictReader` (keyAt, valueAt, findKey, verifyHash)
- `leaf.readUtf8(view) -> []const u8`
- `leaf.readRaw(view) -> []const u8`
- `mini_blip.readArchive(buf) -> ArchiveReader`

## Testing (~100 tests)

1. Leaf round-trips (~15)
2. Self-referential length convergence (~5)
3. Array round-trips + index verification (~20)
4. Dict round-trips + key ordering + binary search (~20)
5. FILE validation (required keys) (~10)
6. miniBLIP archive end-to-end (~15)
7. Spec compliance (hand-crafted byte sequences) (~10)
8. C FFI round-trips (~5)

## Not In Scope (This Phase)

- Streaming writes / padded BLIPs (in-memory only)
- Scratch pool / indirect overflow
- MAP container (can add later, same layout as DICT minus sort)
- Compression wrapper
- Symlinks, empty directories
