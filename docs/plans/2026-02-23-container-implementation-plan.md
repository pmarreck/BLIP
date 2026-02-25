# BLIP Container Library Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the BLIP Container Format (v1.1) as a Zig library with C FFI, plus a miniBlar high-level API for entropy_shield.

**Architecture:** Layered module stack — one file per container type (leaf, array, dict), a core TLV module, a high-level miniBlar composition layer, and C FFI exports. Writer API uses pre-serialized composable byte slices. Reader API is zero-copy with lazy index access.

**Tech Stack:** Zig 0.15.2, std.hash.XxHash64, Nix flake for hermetic build

**Reference:** `BLIP_CONTAINER_SPEC.md` v1.1, `BLIP_SPEC.md` v1.1

---

### Task 1: Add `encodedSize` to blip.zig

All container modules need to compute BLIP encoding sizes without actually encoding. Add a public function.

**Files:**
- Modify: `src/blip.zig`

**Step 1: Write failing test**

Add to blip.zig test section (before the re-export section):

```zig
test "encodedSize matches actual encode size" {
    var buf: [16]u8 = undefined;
    const values = [_]u64{
        0, 1, 42, 127, 128, 200, 255, 256, 1000,
        50000, 65535, 65536, 5000000, 0xFFFFFFFF,
        0x100000000, 0xFFFFFFFFFFFFFFFF,
    };
    for (values) |value| {
        const actual = try encode(value, &buf);
        try testing.expectEqual(actual, encodedSize(value));
    }
}
```

**Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test 2>&1 | head -30`
Expected: compile error — `encodedSize` not defined

**Step 3: Write implementation**

Add to blip.zig after `minBytes`:

```zig
/// Returns the number of bytes that encode(value) would produce,
/// without actually writing to a buffer.
pub fn encodedSize(value: u64) usize {
    if (value < 128) return 1; // immediate mode
    return 1 + minBytes(value); // header byte + L value bytes
}
```

**Step 4: Run test to verify it passes**

Run: `nix develop -c zig build test 2>&1 | tail -5`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/blip.zig
git commit -m "feat: add encodedSize to BLIP public API"
```

---

### Task 2: container_types.zig — Type constants and sentinel mapping

**Files:**
- Create: `src/container_types.zig`

**Step 1: Write failing tests**

```zig
const std = @import("std");
const testing = std.testing;
const blip = @import("blip.zig");

/// Container type tags — BLIP sentinel values used as type identifiers.
/// Each type is the second byte of a 2-byte sentinel (0x81 0xNN).
pub const ContainerType = enum(u7) {
    array = 0x01,
    dict = 0x02,
    utf8 = 0x03,
    raw = 0x04,
    file = 0x05,
    map = 0x06,
};

/// Sentinel byte constants for each container type.
pub const SENTINEL_BYTE: u8 = 0x81;
pub const PAD_END_VALUE: u7 = 0x00;

/// Convert a ContainerType to its 2-byte sentinel.
pub fn typeSentinel(ct: ContainerType) [2]u8 {
    return .{ SENTINEL_BYTE, @intFromEnum(ct) };
}

/// Try to parse a ContainerType from the first 2 bytes of a buffer.
/// Returns null if not a valid container sentinel.
pub fn parseType(buf: []const u8) ?ContainerType {
    if (buf.len < 2) return null;
    if (buf[0] != SENTINEL_BYTE) return null;
    return std.meta.intToEnum(ContainerType, @as(u7, @truncate(buf[1]))) catch null;
}

// =============================================================================
// Tests
// =============================================================================

test "typeSentinel produces correct bytes" {
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, &typeSentinel(.array));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, &typeSentinel(.dict));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03 }, &typeSentinel(.utf8));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04 }, &typeSentinel(.raw));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, &typeSentinel(.file));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x06 }, &typeSentinel(.map));
}

test "parseType round-trips all container types" {
    inline for (std.meta.fields(ContainerType)) |field| {
        const ct: ContainerType = @enumFromInt(field.value);
        const sentinel = typeSentinel(ct);
        try testing.expectEqual(ct, parseType(&sentinel).?);
    }
}

test "parseType rejects invalid sentinels" {
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x81, 0x00 })); // PAD_END
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x81, 0x7F })); // undefined
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x82, 0x01 })); // wrong first byte
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{0x81})); // too short
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{})); // empty
}

test "all type sentinels are valid BLIP sentinels" {
    inline for (std.meta.fields(ContainerType)) |field| {
        const ct: ContainerType = @enumFromInt(field.value);
        const sentinel = typeSentinel(ct);
        try testing.expect(blip.isSentinel(&sentinel));
    }
}
```

**Step 2-4:** The file above includes both implementation and tests in one file. Write it, then run tests.

Run: `nix develop -c zig build test 2>&1 | tail -5`

**Step 5: Commit**

```bash
git add src/container_types.zig
git commit -m "feat: add container_types.zig with type enum and sentinel mapping"
```

---

### Task 3: container.zig — TLV header read/write and self-referential length

**Files:**
- Create: `src/container.zig`

**Key algorithm — self-referential length convergence:**

```zig
/// Compute total container size given value payload size.
/// Solves: total = 2 (type) + blip_size(total) + v_size
pub fn computeTotalLength(v_size: u64) u64 {
    const base = 2 + v_size; // type sentinel + value payload
    for (1..10) |l_bytes| {
        const total = base + l_bytes;
        if (blip.encodedSize(total) == l_bytes) return total;
    }
    unreachable; // always converges for valid inputs
}
```

**Full file content:**

```zig
const std = @import("std");
const blip = @import("blip.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

pub const ContainerType = ct.ContainerType;
pub const typeSentinel = ct.typeSentinel;
pub const parseType = ct.parseType;

pub const ContainerError = error{
    InvalidContainerType,
    InvalidLength,
    LengthExceedsBounds,
    MissingRequiredKey,
    DuplicateKey,
    KeysNotSorted,
    HashMismatch,
    IndexOutOfBounds,
    InvalidMagic,
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Result of parsing a container header.
pub const ContainerView = struct {
    container_type: ContainerType,
    total_length: u64,
    /// Byte offset where the value payload starts (after type + length)
    value_offset: usize,
    /// The full container buffer (from container start through total_length)
    buf: []const u8,

    /// Returns the value payload slice.
    pub fn valueSlice(self: ContainerView) []const u8 {
        return self.buf[self.value_offset..@intCast(self.total_length)];
    }
};

/// Compute total container size given value payload size.
/// Solves: total = 2 (type sentinel) + blip_encoded_size(total) + v_size
pub fn computeTotalLength(v_size: u64) u64 {
    const base: u64 = 2 + v_size;
    for (1..10) |l_bytes| {
        const total = base + l_bytes;
        if (blip.encodedSize(total) == l_bytes) return total;
    }
    unreachable;
}

/// Write a container header (type sentinel + BLIP total length).
/// Returns number of bytes written (2 + BLIP encoding of total).
pub fn writeHeader(container_type: ContainerType, total_length: u64, buf: []u8) ContainerError!usize {
    if (buf.len < 2) return ContainerError.BufferTooSmall;
    const sentinel = ct.typeSentinel(container_type);
    buf[0] = sentinel[0];
    buf[1] = sentinel[1];
    const len_bytes = blip.encode(total_length, buf[2..]) catch return ContainerError.BufferTooSmall;
    return 2 + len_bytes;
}

/// Parse a container header from a buffer.
/// buf must start at the container's first byte (type sentinel).
pub fn parseHeader(buf: []const u8) ContainerError!ContainerView {
    if (buf.len < 3) return ContainerError.UnexpectedEndOfInput;
    const container_type = ct.parseType(buf) orelse return ContainerError.InvalidContainerType;
    const len_result = blip.decode(buf[2..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    const total_length = len_result.value;
    const value_offset: usize = 2 + len_result.bytes_read;
    if (total_length > buf.len) return ContainerError.LengthExceedsBounds;
    if (total_length < value_offset) return ContainerError.InvalidLength;
    return ContainerView{
        .container_type = container_type,
        .total_length = total_length,
        .value_offset = value_offset,
        .buf = buf,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "computeTotalLength for empty value" {
    // total = 2 (type) + 1 (BLIP(3)) + 0 (value) = 3
    try testing.expectEqual(@as(u64, 3), computeTotalLength(0));
}

test "computeTotalLength for 5-byte value (hello)" {
    // total = 2 + 1 (BLIP(8)) + 5 = 8
    try testing.expectEqual(@as(u64, 8), computeTotalLength(5));
}

test "computeTotalLength at BLIP boundary" {
    // v_size = 125: base = 127, try l=1: total=128, encodedSize(128)=2, no.
    //                            try l=2: total=129, encodedSize(129)=2, yes!
    try testing.expectEqual(@as(u64, 129), computeTotalLength(125));
}

test "computeTotalLength for large value" {
    // v_size = 65535
    const total = computeTotalLength(65535);
    try testing.expectEqual(total, 2 + blip.encodedSize(total) + 65535);
}

test "writeHeader + parseHeader roundtrip" {
    var buf: [32]u8 = undefined;
    const total: u64 = 42;
    const written = try writeHeader(.utf8, total, &buf);
    const view = try parseHeader(&buf);
    try testing.expectEqual(ContainerType.utf8, view.container_type);
    try testing.expectEqual(total, view.total_length);
    try testing.expectEqual(written, view.value_offset);
}

test "parseHeader rejects invalid type" {
    const result = parseHeader(&[_]u8{ 0x81, 0x00, 0x05 }); // PAD_END, not a container
    try testing.expectError(ContainerError.InvalidContainerType, result);
}

test "parseHeader rejects truncated buffer" {
    const result = parseHeader(&[_]u8{ 0x81, 0x03 }); // no length
    try testing.expectError(ContainerError.UnexpectedEndOfInput, result);
}

test "parseHeader rejects length exceeding buffer" {
    // Claims total=100 but buffer is only 5 bytes
    const result = parseHeader(&[_]u8{ 0x81, 0x03, 0x64, 0x00, 0x00 });
    try testing.expectError(ContainerError.LengthExceedsBounds, result);
}

test {
    _ = @import("container_types.zig");
}
```

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/container.zig
git commit -m "feat: add container.zig with TLV header and self-referential length solver"
```

---

### Task 4: leaf.zig — UTF8 and RAW serialization/parsing

**Files:**
- Create: `src/leaf.zig`

**Implementation notes:**
- UTF8: Type = 0x81 0x03, value = raw string bytes
- RAW: Type = 0x81 0x04, value = raw bytes
- Both use `computeTotalLength(data.len)` for self-referential length
- Reader returns zero-copy slices into the original buffer

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;

/// Serialize a UTF-8 string as a UTF8 container (0x81 0x03).
/// Caller owns returned memory.
pub fn serializeUtf8(allocator: Allocator, text: []const u8) (Allocator.Error || ContainerError)![]u8 {
    return serializeLeaf(allocator, .utf8, text);
}

/// Serialize raw bytes as a RAW container (0x81 0x04).
/// Caller owns returned memory.
pub fn serializeRaw(allocator: Allocator, data: []const u8) (Allocator.Error || ContainerError)![]u8 {
    return serializeLeaf(allocator, .raw, data);
}

fn serializeLeaf(allocator: Allocator, leaf_type: ContainerType, data: []const u8) (Allocator.Error || ContainerError)![]u8 {
    const total = container.computeTotalLength(data.len);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);
    const header_len = try container.writeHeader(leaf_type, total, buf);
    @memcpy(buf[header_len..], data);
    return buf;
}

/// Read a UTF8 container. Returns the string bytes (zero-copy).
/// Validates that the container type is UTF8.
pub fn readUtf8(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .utf8) return ContainerError.InvalidContainerType;
    return view.valueSlice();
}

/// Read a RAW container. Returns the raw bytes (zero-copy).
/// Validates that the container type is RAW.
pub fn readRaw(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .raw) return ContainerError.InvalidContainerType;
    return view.valueSlice();
}

/// Read the value bytes from a leaf container (UTF8 or RAW).
/// Does not validate container type.
pub fn readLeafValue(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    return view.valueSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "serializeUtf8 'hello' produces correct bytes" {
    const allocator = testing.allocator;
    const result = try serializeUtf8(allocator, "hello");
    defer allocator.free(result);
    // 0x81 0x03 = UTF8 type, 0x08 = total length 8 (2+1+5)
    // 0x68 0x65 0x6C 0x6C 0x6F = "hello"
    try testing.expectEqualSlices(u8, &[_]u8{
        0x81, 0x03, 0x08, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
    }, result);
}

test "serializeUtf8 empty string" {
    const allocator = testing.allocator;
    const result = try serializeUtf8(allocator, "");
    defer allocator.free(result);
    // total = 2 + 1 + 0 = 3
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03, 0x03 }, result);
}

test "serializeRaw 3 bytes" {
    const allocator = testing.allocator;
    const result = try serializeRaw(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE });
    defer allocator.free(result);
    // total = 2 + 1 + 3 = 6
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04, 0x06, 0xDE, 0xAD, 0xBE }, result);
}

test "readUtf8 round-trip" {
    const allocator = testing.allocator;
    const serialized = try serializeUtf8(allocator, "hello world");
    defer allocator.free(serialized);
    const text = try readUtf8(serialized);
    try testing.expectEqualSlices(u8, "hello world", text);
}

test "readRaw round-trip" {
    const allocator = testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const serialized = try serializeRaw(allocator, &data);
    defer allocator.free(serialized);
    const read_data = try readRaw(serialized);
    try testing.expectEqualSlices(u8, &data, read_data);
}

test "readUtf8 rejects RAW container" {
    const allocator = testing.allocator;
    const raw = try serializeRaw(allocator, "test");
    defer allocator.free(raw);
    try testing.expectError(ContainerError.InvalidContainerType, readUtf8(raw));
}

test "readRaw rejects UTF8 container" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "test");
    defer allocator.free(utf8);
    try testing.expectError(ContainerError.InvalidContainerType, readRaw(utf8));
}

test "serializeUtf8 large string crosses BLIP boundary" {
    const allocator = testing.allocator;
    // 125 bytes of data → total = 2 + 2 + 125 = 129 (needs 2-byte BLIP)
    const data = [_]u8{0x41} ** 125;
    const result = try serializeUtf8(allocator, &data);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 129), result.len);
    // Verify round-trip
    const text = try readUtf8(result);
    try testing.expectEqual(@as(usize, 125), text.len);
}

test "readLeafValue works for both types" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "abc");
    defer allocator.free(utf8);
    const raw = try serializeRaw(allocator, "xyz");
    defer allocator.free(raw);
    try testing.expectEqualSlices(u8, "abc", try readLeafValue(utf8));
    try testing.expectEqualSlices(u8, "xyz", try readLeafValue(raw));
}

test "spec example: UTF8 'hello' = 0x81 0x03 0x08 + payload" {
    // From BLIP_CONTAINER_SPEC.md §UTF8 String
    const expected = [_]u8{ 0x81, 0x03, 0x08, 0x68, 0x65, 0x6C, 0x6C, 0x6F };
    const text = try readUtf8(&expected);
    try testing.expectEqualSlices(u8, "hello", text);
}
```

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/leaf.zig
git commit -m "feat: add leaf.zig with UTF8 and RAW container serialization"
```

---

### Task 5: array.zig — ARRAY container with index and xxHash64

**Files:**
- Create: `src/array.zig`

**Implementation notes:**
- Layout: Type (2) + BLIP(total) + BLIP(index_offset) + elements + index(N, offsets) + xxHash64(8)
- Self-referential length requires fixpoint iteration over S (total length encoding) and I (index_offset encoding)
- xxHash64 covers bytes 0..total-8, stored as 8-byte LE at end
- Reader: lazy offset access (walks index from start for each elementAt call)

**Key algorithm — fixpoint iteration for array serialization:**

```
loop:
    header_size = 2 + S + I
    compute element offsets (each = header_size + cumulative element sizes before it)
    index_offset = header_size + data_size
    index_size = encodedSize(N) + sum(encodedSize(off_k))
    total = header_size + data_size + index_size + 8
    S_new = encodedSize(total)
    I_new = encodedSize(index_offset)
    if converged: break
    S = S_new; I = I_new
```

**Full file:** Implementation should follow this structure. The subagent must implement:

1. `pub fn serializeArray(allocator, elements: []const []const u8) ![]u8`
   - Fixpoint iteration to compute S, I, offsets, total
   - Single allocation of exact total size
   - Write header, index_offset, elements, index section, xxHash64

2. `pub const ArrayReader` struct with:
   - `pub fn init(buf: []const u8) ContainerError!ArrayReader`
   - `pub fn elementCount(self) u64`
   - `pub fn elementAt(self, index: u64) ContainerError!ContainerView`
   - `pub fn verifyHash(self) ContainerError!bool`

3. xxHash64: use `std.hash.XxHash64` (or `std.hash.xxhash.XxHash64` if the short path doesn't work). Seed = 0. Hash bytes 0..total-8, store as `std.mem.writeInt(u64, ..., .little)`.

**Required tests (~20):**

- Empty array (0 elements) serialize + parse
- Single element array
- Multiple element array (3-5 elements)
- Nested array (array containing arrays)
- elementAt for each index in a multi-element array
- elementAt out of bounds → error
- verifyHash returns true for valid array
- verifyHash returns false for corrupted array (flip a byte)
- Self-referential length correctness at BLIP boundaries (v_size = 125, causing length to cross from 1-byte to 2-byte BLIP)
- Round-trip: serialize → parse → extract each element → compare

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/array.zig
git commit -m "feat: add array.zig with ARRAY container, index tables, and xxHash64"
```

---

### Task 6: dict.zig — DICT and FILE containers with key ordering

**Files:**
- Create: `src/dict.zig`

**Implementation notes:**
- Layout: Type (2) + BLIP(total) + BLIP(index_offset) + interleaved key-value TLVs + index(N, key_offsets, val_offsets) + xxHash64(8)
- Keys and values in KeyValue pairs are pre-serialized container bytes
- DICT/FILE: keys sorted in canonical byte order (memcmp). Encoder validates sort order.
- FILE: validates required keys "bina", "path", "xh64" exist (in byte order: bina < path < xh64)
- Key comparison: compare the VALUE bytes of key containers (strip TLV header), use `std.mem.order`

**Key types:**

```zig
pub const KeyValue = struct {
    key: []const u8,   // pre-serialized UTF8 or RAW container
    value: []const u8, // pre-serialized container of any type
};
```

**Serialization functions:**

1. `pub fn serializeDict(allocator, pairs: []const KeyValue) ![]u8`
   - Verify keys are in canonical byte order (compare key values via extractKeyBytes)
   - Same fixpoint iteration as array but with key+value offsets in index
   - Index layout: BLIP(N), then N interleaved (key_offset, val_offset) pairs

2. `pub fn serializeFile(allocator, pairs: []const KeyValue) ![]u8`
   - Same as serializeDict but with type = .file
   - Validates required keys "bina", "path", "xh64" are present

3. `pub fn extractKeyBytes(key_container: []const u8) ![]const u8`
   - Parse the key container header, return the value payload (the actual key text)
   - Used for key comparison during sort validation and lookup

**Reader:**

```zig
pub const DictReader = struct {
    buf: []const u8,
    count: u64,
    index_offset: u64,
    header_size: usize,  // bytes before data section (type + total + index_offset)
    total_length: u64,

    pub fn init(buf: []const u8) ContainerError!DictReader
    pub fn pairCount(self) u64
    pub fn keyAt(self, index: u64) ContainerError![]const u8  // returns key container bytes
    pub fn valueAt(self, index: u64) ContainerError![]const u8  // returns value container bytes
    pub fn findKey(self, key_bytes: []const u8) ContainerError!?u64  // linear scan, returns pair index
    pub fn verifyHash(self) ContainerError!bool
};
```

**Required tests (~25):**

- Empty dict
- Single key-value pair
- Multiple pairs (verify sort order enforcement)
- serializeDict rejects out-of-order keys
- serializeDict rejects duplicate keys
- DictReader.findKey finds existing key
- DictReader.findKey returns null for missing key
- DictReader.keyAt and valueAt for each pair
- FILE with all 3 required keys (bina, path, xh64)
- FILE missing "path" → error
- FILE missing "bina" → error
- FILE missing "xh64" → error
- verifyHash valid and corrupted
- Round-trip: serialize dict → read → extract all pairs → compare
- Key ordering: verify "a" < "aa" < "ab" < "b" (from spec examples)
- extractKeyBytes for UTF8 and RAW keys

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/dict.zig
git commit -m "feat: add dict.zig with DICT/FILE containers, key ordering, and index"
```

---

### Task 7: mini_blar.zig — High-level archive API

**Files:**
- Create: `src/mini_blar.zig`

**Implementation notes:**
- `createArchive` builds a complete BLIP archive from file entries
- Archive structure: outer ARRAY [ RAW("BLIP\x01"), body ARRAY [ FILE, FILE, ... ] ]
- Files sorted by path for determinism
- Each FILE is a sorted dict with keys "bina", "path", "xh64" (in byte order)
- xxHash64 for file content stored as "xh64" key's RAW value
- Outer ARRAY's xxHash64 covers the entire archive

**Public API:**

```zig
pub const FileEntry = struct {
    path: []const u8,      // file path (UTF-8, forward slashes, no leading slash)
    content: []const u8,   // file content bytes
    metadata: ?[]const dict.KeyValue,  // optional extra key-value pairs (pre-serialized)
};

/// Create a complete BLIP archive from file entries.
/// Files are sorted by path for determinism.
pub fn createArchive(allocator: Allocator, files: []const FileEntry) ![]u8

/// Reader for a BLIP archive.
pub const ArchiveReader = struct {
    buf: []const u8,
    outer: array_mod.ArrayReader,

    pub fn init(buf: []const u8) !ArchiveReader
    pub fn verifyMagic(self: ArchiveReader) !bool
    pub fn fileCount(self: ArchiveReader) !u64
    pub fn fileAt(self: ArchiveReader, index: u64) !dict.DictReader
    pub fn verifyHash(self: ArchiveReader) !bool
    /// Find a file by path. Returns the dict reader for the FILE container.
    pub fn findFile(self: ArchiveReader, path: []const u8) !?dict.DictReader
};
```

**Implementation of createArchive:**

```
1. Sort files by path (byte order)
2. For each file:
   a. Serialize "bina" key (UTF8) + RAW(content) value
   b. Serialize "path" key (UTF8) + UTF8(path) value
   c. Serialize "xh64" key (UTF8) + RAW(xxHash64(content)) value
   d. Merge with any metadata pairs
   e. serializeFile(allocator, sorted_pairs) → FILE bytes
3. Collect all FILE bytes as array elements
4. Serialize magic: serializeRaw(allocator, "BLIP\x01") → magic bytes
5. serializeArray(allocator, [FILE bytes...]) → body ARRAY
6. serializeArray(allocator, [magic, body]) → outer ARRAY
7. Return outer ARRAY bytes
```

**Required tests (~15):**

- Empty archive (0 files)
- Single file archive
- Multi-file archive (3 files, verify path sorting)
- Round-trip: createArchive → ArchiveReader → extract each file path and content
- verifyMagic on valid archive
- verifyMagic rejects wrong magic
- verifyHash on valid archive
- findFile by path
- findFile returns null for nonexistent path
- Archive with metadata (mtime as RAW)
- File content xxHash64 matches stored xh64 value

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/mini_blar.zig
git commit -m "feat: add mini_blar.zig with high-level archive creation and reading"
```

---

### Task 8: build.zig + blip.zig integration

**Files:**
- Modify: `src/blip.zig` — add test imports for new modules
- Modify: `build.zig` — no changes needed (blip.zig is already the test root, and new files are imported via `@import`)

**Step 1: Add test imports to blip.zig**

Add to the `test { }` block at the bottom of `src/blip.zig`:

```zig
    _ = @import("container_types.zig");
    _ = @import("container.zig");
    _ = @import("leaf.zig");
    _ = @import("array.zig");
    _ = @import("dict.zig");
    _ = @import("mini_blar.zig");
```

**Step 2: Run full test suite**

Run: `nix develop -c zig build test 2>&1 | tail -10`
Expected: All tests pass (existing + new container tests)

**Step 3: Commit**

```bash
git add src/blip.zig
git commit -m "feat: integrate container modules into test suite"
```

---

### Task 9: C FFI — container_lib.zig + container.h

**Files:**
- Modify: `src/lib.zig` — add container FFI exports
- Modify: `src/blip.h` — add container function declarations

**C FFI functions to expose:**

```zig
// In lib.zig, add:
const mini_blar = @import("blip").mini_blar_mod;

/// Create a BLIP archive from file entries.
/// files: array of {path, path_len, content, content_len} structs
/// Returns allocated buffer (caller must free with blip_free).
export fn blip_archive_create(
    files: [*]const CFileEntry,
    file_count: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32

/// Read archive file count.
export fn blip_archive_file_count(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
) callconv(.c) i32

/// Verify archive xxHash64 integrity.
export fn blip_archive_verify(
    buf: [*]const u8,
    buf_len: usize,
) callconv(.c) bool

/// Free a buffer allocated by blip_archive_create.
export fn blip_free(ptr: [*]u8, len: usize) callconv(.c) void
```

**Note:** The C FFI needs an allocator strategy. Use a global `std.heap.page_allocator` for C-facing allocations, with `blip_free` to release. The `CFileEntry` struct mirrors `FileEntry` but with C-compatible pointers.

**Add to blip.h:**

```c
/* Container/archive operations */
typedef struct {
    const char *path;
    size_t path_len;
    const uint8_t *content;
    size_t content_len;
} blip_file_entry;

int32_t blip_archive_create(const blip_file_entry *files, size_t file_count,
                            uint8_t **out_buf, size_t *out_len);
int32_t blip_archive_file_count(const uint8_t *buf, size_t buf_len, uint64_t *out_count);
bool blip_archive_verify(const uint8_t *buf, size_t buf_len);
void blip_free(uint8_t *ptr, size_t len);
```

**Required tests (~5):**

- Create archive through C FFI, verify file count
- Verify archive integrity through C FFI
- Free allocated buffer
- Round-trip: create → file_count → verify → free

**Run:** `nix develop -c zig build test 2>&1 | tail -5`

**Commit:**
```bash
git add src/lib.zig src/blip.h
git commit -m "feat: add container C FFI exports"
```

---

### Task 10: Final integration, docs, push

**Files:**
- Modify: `PLAN.md` — update with container implementation status
- Modify: `CODE_MINIMAP.md` — add container module descriptions
- Modify: `README.md` — add container format section

**Step 1: Run full test suite**

```bash
nix develop -c zig build test 2>&1
```

Expected: All tests pass (original ~300 + new ~100)

**Step 2: Build library**

```bash
nix develop -c zig build -Doptimize=ReleaseFast 2>&1
```

**Step 3: Update docs**

Add container module entries to CODE_MINIMAP.md. Add "Container Format" section to README.md linking to BLIP_CONTAINER_SPEC.md and describing the miniBlar API.

**Step 4: Commit and push**

```bash
git add -A
git commit -m "docs: update README and CODE_MINIMAP with container library"
jj git push -b yolo
```

---

## Execution Notes

- **TDD is mandatory:** Write failing test → verify it fails → implement → verify it passes → commit
- **Test command:** `nix develop -c zig build test`
- **Build command:** `nix develop -c zig build -Doptimize=ReleaseFast`
- **XxHash64 import:** Try `std.hash.XxHash64` first. If it doesn't exist, use `std.hash.xxhash.XxHash64`. The exact path may vary by Zig version.
- **Allocator pattern:** All writer functions take `std.mem.Allocator`. Use `testing.allocator` in tests (detects leaks).
- **Error union:** Container functions return `(Allocator.Error || ContainerError)!T` for writer, `ContainerError!T` for reader.
- **Self-referential length:** The convergence loop is the trickiest part. Test it at BLIP encoding boundaries (values 125-130, 16380-16390).
- **blip.zig imports:** New modules use `@import("blip.zig")` for encode/decode/encodedSize. The build system resolves these as same-module imports since blip.zig is the module root.
- **IMPORTANT:** Do NOT overwrite or truncate existing files. When modifying blip.zig or lib.zig, append/insert — do not replace existing content.
