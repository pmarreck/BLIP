# Opt-in Fast DICT Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `DictReader.findKey` a binary search (free default) and add an opt-in allocating `DictIndex` accelerator (O(1) random access, O(log n) `findKey`), exposed in Zig and the C FFI.

**Architecture:** `DictReader` stays a pure, allocator-free view; `findKey` switches from O(n²) linear scan to O(n log n) binary search using the existing sorted-key invariant. A separate `DictIndex` type parses the offset table once into `[]u64` for O(1) probes. The C FFI gets an opaque-handle API mirroring existing `blip_container_*` semantics.

**Tech Stack:** Zig 0.16, Nix build (`nix develop -c zig build ...`), `jj` for version control (NEVER raw `git`), C FFI in `src/lib.zig` + `src/blip.h`.

**Spec:** `docs/superpowers/specs/2026-06-01-dict-fast-access-design.md`
**Background:** `docs/2026-06-01-index-access-and-boundary-notes.md`

---

## Conventions for every task

- **Build/test command:** `nix develop -c zig build test --summary all 2>&1 | tail -8`
  - PASS looks like: `Build Summary: N/N steps succeeded; M/M tests passed` + `test success`.
  - FAIL looks like: a compile error, or `... K fail (... total)` + `test transitive failure`.
- **Commit command (jj — NOT git):** `jj commit -m "<message>"` finalizes the working copy and starts a fresh one.
- All Zig files use **4-space indentation** (no tabs — Zig forbids them).
- Tests must run clean (no stray stderr). These are pure in-memory tests, so there is no stderr to capture.

---

## File Structure

- **Modify `src/dict.zig`** — add `const builtin` import; rewrite `findKey` as binary search; add `verifyKeysSorted`; call it in `init` under Debug; add the `DictIndex` struct; add tests. (Single responsibility: DICT container read/write — `DictIndex` belongs here next to `DictReader`.)
- **Modify `src/lib.zig`** — add `dict_mod`/`leaf_mod`/`testing` imports; add six `blip_dict_index_*` exports; add FFI Zig tests.
- **Modify `src/blip.h`** — add the six C declarations.
- **Modify `src/benchmark.zig`** — add `benchDictFindKey`; call it from `main`.
- **Modify docs** — `BLIP_CONTAINER_SPEC.md`, `CODE_MINIMAP.md`, `PLAN.md`.

---

## Task 1: `findKey` binary search + sorted-invariant guard

**Files:**
- Modify: `src/dict.zig` (imports at top ~line 1-8; `findKey` ~line 369-388; `init` ~line 248-287)
- Test: `src/dict.zig` (Tests section, after the existing `findKey` tests ~line 540)

- [ ] **Step 1: Add a set-based regression test for `findKey` (guards the refactor)**

Add this test in the Tests section of `src/dict.zig` (after the existing `test "DictReader.findKey returns null for missing key"`):

```zig
test "DictReader.findKey resolves every key and rejects absent ones (set-based)" {
    const allocator = testing.allocator;
    // Zero-padded names sort lexicographically == numeric order, so they are
    // already in canonical order for serializeDict.
    const N = 500;
    var keys: [N][]u8 = undefined;
    var vals: [N][]u8 = undefined;
    var pairs: [N]KeyValue = undefined;
    var made: usize = 0;
    defer for (0..made) |i| {
        allocator.free(keys[i]);
        allocator.free(vals[i]);
    };
    for (0..N) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "k{d:0>6}", .{i});
        keys[i] = try leaf.serializeUtf8(allocator, name);
        vals[i] = try leaf.serializeData(allocator, "v");
        pairs[i] = .{ .key = keys[i], .value = vals[i] };
        made += 1;
    }

    const dict = try serializeDict(allocator, &pairs);
    defer allocator.free(dict);
    const reader = try DictReader.init(dict);

    // Every present key resolves to its own index.
    for (0..N) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "k{d:0>6}", .{i});
        try testing.expectEqual(@as(?u64, @intCast(i)), try reader.findKey(name));
    }
    // Swept absent keys: before-first, between pairs, after-last.
    try testing.expectEqual(@as(?u64, null), try reader.findKey("k!!!!!!")); // sorts before "k000000"
    try testing.expectEqual(@as(?u64, null), try reader.findKey("k0000005zzz")); // between
    try testing.expectEqual(@as(?u64, null), try reader.findKey("zzzzzzz")); // after-last
}
```

- [ ] **Step 2: Run the test against the current linear `findKey` (it should PASS)**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: PASS. (This is a behavior-preserving refactor; the test passes before and after, proving the refactor keeps behavior. Per project rules, refactors under coverage are valid this way.)

- [ ] **Step 3: Add the `builtin` import**

At the top of `src/dict.zig`, after `const std = @import("std");`, add:

```zig
const builtin = @import("builtin");
```

- [ ] **Step 4: Replace `findKey` body with binary search**

Replace the existing `findKey` implementation body (keep its doc comment) so it reads:

```zig
    pub fn findKey(self: DictReader, key_bytes: []const u8) LPContainerError!?u64 {
        var lo: u64 = 0;
        var hi: u64 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const stored = try extractKeyBytes(try self.keyAt(mid));
            switch (compareKeys(stored, key_bytes)) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
```

- [ ] **Step 5: Add `verifyKeysSorted` method (testable in any build mode)**

Add this method to `DictReader`, immediately after `findKey`:

```zig
    /// Verify keys are in canonical non-decreasing order — the invariant that
    /// findKey's binary search relies on. Returns KeysNotSorted on violation.
    /// O(n); used as a Debug-only self-check in init and directly in tests.
    pub fn verifyKeysSorted(self: DictReader) LPContainerError!void {
        if (self.count < 2) return;
        var prev = try extractKeyBytes(try self.keyAt(0));
        var i: u64 = 1;
        while (i < self.count) : (i += 1) {
            const cur = try extractKeyBytes(try self.keyAt(i));
            if (compareKeys(prev, cur) == .gt) return ContainerError.KeysNotSorted;
            prev = cur;
        }
    }
```

- [ ] **Step 6: Call `verifyKeysSorted` from `init` under Debug only**

In `DictReader.init`, replace the final `return DictReader{ ... };` block so the reader is bound first, checked in Debug, then returned:

```zig
        const reader = DictReader{
            .lp_view = lp,
            .index_offset = index_offset,
            .count = n_result.value,
            .header_size = header_size,
            .index_start = idx_start + n_result.bytes_read,
        };
        if (builtin.mode == .Debug) try reader.verifyKeysSorted();
        return reader;
```

- [ ] **Step 7: Add a direct test for `verifyKeysSorted` (new behavior — build-mode independent)**

`serializeDict` rejects unsorted input, so build malformed-but-parseable bytes via the internal `serializeDictLike` (same file, accessible from tests). Add:

```zig
test "DictReader.verifyKeysSorted flags out-of-order keys" {
    const allocator = testing.allocator;
    // "beta" then "alpha" is descending — serializeDictLike does NOT validate.
    const k_beta = try leaf.serializeUtf8(allocator, "beta");
    defer allocator.free(k_beta);
    const k_alpha = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(k_alpha);
    const v = try leaf.serializeData(allocator, "x");
    defer allocator.free(v);
    const pairs = [_]KeyValue{
        .{ .key = k_beta, .value = v },
        .{ .key = k_alpha, .value = v },
    };
    const bytes = try serializeDictLike(allocator, &pairs, .dict, .{});
    defer allocator.free(bytes);

    const reader = try DictReader.init(bytes); // init's Debug check is off in ReleaseFast test build
    try testing.expectError(ContainerError.KeysNotSorted, reader.verifyKeysSorted());

    // A sorted dict passes.
    const sorted = [_]KeyValue{
        .{ .key = k_alpha, .value = v },
        .{ .key = k_beta, .value = v },
    };
    const ok_bytes = try serializeDictLike(allocator, &sorted, .dict, .{});
    defer allocator.free(ok_bytes);
    const ok_reader = try DictReader.init(ok_bytes);
    try ok_reader.verifyKeysSorted();
}
```

- [ ] **Step 8: Run all tests (should PASS)**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: PASS, with the two new tests included.

- [ ] **Step 9: Commit**

```bash
jj commit -m "perf(dict): binary-search findKey (O(n^2) -> O(n log n)) + sorted-invariant guard

findKey now binary-searches over the already-sorted keys using compareKeys.
Adds verifyKeysSorted() (tested directly) and a Debug-only invariant check in
init. Set-based regression test covers 500 keys + swept absent lookups."
```

---

## Task 2: `DictIndex` accelerator

**Files:**
- Modify: `src/dict.zig` (add `DictIndex` struct after the `DictReader` struct's closing `};` ~line 399; add tests in Tests section)

- [ ] **Step 1: Write failing oracle + leak tests for `DictIndex`**

Add to the Tests section of `src/dict.zig`:

```zig
test "DictIndex matches DictReader (oracle) and binary-search findKey" {
    const allocator = testing.allocator;
    const N = 300;
    var keys: [N][]u8 = undefined;
    var vals: [N][]u8 = undefined;
    var pairs: [N]KeyValue = undefined;
    var made: usize = 0;
    defer for (0..made) |i| {
        allocator.free(keys[i]);
        allocator.free(vals[i]);
    };
    for (0..N) |i| {
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "k{d:0>6}", .{i});
        keys[i] = try leaf.serializeUtf8(allocator, name);
        vals[i] = try leaf.serializeData(allocator, "v");
        pairs[i] = .{ .key = keys[i], .value = vals[i] };
        made += 1;
    }
    const dict = try serializeDict(allocator, &pairs);
    defer allocator.free(dict);

    const reader = try DictReader.init(dict);
    var index = try DictIndex.build(allocator, reader);
    defer index.deinit(allocator);

    try testing.expectEqual(reader.pairCount(), index.pairCount());
    for (0..N) |i| {
        try testing.expectEqualSlices(u8, try reader.keyAt(@intCast(i)), try index.keyAt(@intCast(i)));
        try testing.expectEqualSlices(u8, try reader.valueAt(@intCast(i)), try index.valueAt(@intCast(i)));
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "k{d:0>6}", .{i});
        try testing.expectEqual(try reader.findKey(name), try index.findKey(name));
    }
    try testing.expectEqual(@as(?u64, null), try index.findKey("zzzzzzz"));
    try testing.expectError(ContainerError.IndexOutOfBounds, index.keyAt(N));
}
```

- [ ] **Step 2: Run to verify it FAILS**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: FAIL — compile error `error: container 'dict' has no member named 'DictIndex'`.

- [ ] **Step 3: Implement `DictIndex`**

Add this struct in `src/dict.zig` immediately after the `DictReader` struct's closing `};`:

```zig
/// Opt-in accelerator over a DictReader: parses the variable-width BLIP offset
/// table once into a flat []u64 so random access is O(1) and findKey is a true
/// O(log n) binary search with O(1) probes. Borrows the reader's buffer; owns
/// only the decoded offsets. See docs/2026-06-01-index-access-and-boundary-notes.md.
pub const DictIndex = struct {
    buf: []const u8, // borrowed — must outlive the index
    total: usize,
    offsets: []u64, // owned — 2*count entries: [key0, val0, key1, val1, ...]
    count: u64,

    /// Single O(n) pass decoding all 2*count BLIP offsets from the index section.
    pub fn build(allocator: Allocator, reader: DictReader) (Allocator.Error || LPContainerError)!DictIndex {
        const buf = reader.lp_view.buf;
        const total: usize = @intCast(reader.lp_view.total_length);
        const n: usize = @intCast(reader.count);
        const offsets = try allocator.alloc(u64, n * 2);
        errdefer allocator.free(offsets);

        var pos: usize = reader.index_start;
        for (0..n * 2) |i| {
            const r = blip.decode(buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            offsets[i] = r.value;
            pos += r.bytes_read;
        }
        return DictIndex{ .buf = buf, .total = total, .offsets = offsets, .count = reader.count };
    }

    pub fn deinit(self: *DictIndex, allocator: Allocator) void {
        allocator.free(self.offsets);
        self.offsets = &.{};
    }

    pub fn pairCount(self: DictIndex) u64 {
        return self.count;
    }

    fn sliceAt(self: DictIndex, offset: u64) LPContainerError![]const u8 {
        const off: usize = @intCast(offset);
        if (off >= self.total) return ContainerError.IndexOutOfBounds;
        const view = try container.parseLPHeader(self.buf[off..self.total]);
        const t: usize = @intCast(view.total_length);
        return self.buf[off .. off + t];
    }

    pub fn keyAt(self: DictIndex, index: u64) LPContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;
        return self.sliceAt(self.offsets[@intCast(index * 2)]);
    }

    pub fn valueAt(self: DictIndex, index: u64) LPContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;
        return self.sliceAt(self.offsets[@intCast(index * 2 + 1)]);
    }

    pub fn findKey(self: DictIndex, key_bytes: []const u8) LPContainerError!?u64 {
        var lo: u64 = 0;
        var hi: u64 = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const stored = try extractKeyBytes(try self.keyAt(mid));
            switch (compareKeys(stored, key_bytes)) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};
```

- [ ] **Step 4: Run to verify it PASSES**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: PASS (the oracle test now compiles and passes; `testing.allocator` confirms no leak).

- [ ] **Step 5: Commit**

```bash
jj commit -m "feat(dict): add opt-in DictIndex accelerator (O(1) access, O(log n) findKey)

DictIndex.build parses the BLIP offset table once into []u64; keyAt/valueAt are
O(1) and findKey is O(log n). Borrows the buffer, owns offsets, explicit deinit.
Oracle test asserts parity with DictReader across 300 keys; leak-checked."
```

---

## Task 3: C FFI — opaque `DictIndex` handle

**Files:**
- Modify: `src/lib.zig` (imports ~line 5-12; new exports; new tests at end)
- Modify: `src/blip.h` (after the `blip_container_key_at` declaration ~line 89-93)

- [ ] **Step 1: Add imports to `src/lib.zig`**

After `const ct = blip.container_types;` add:

```zig
const dict_mod = blip.dict_mod;
const leaf_mod = blip.leaf_mod;
const testing = std.testing;
```

- [ ] **Step 2: Add the six FFI exports**

Add to `src/lib.zig` (near the other `blip_container_*` exports):

```zig
// ---------------------------------------------------------------------------
// DictIndex — opt-in fast DICT access (opaque handle)
// ---------------------------------------------------------------------------

/// Build a DictIndex over a DICT/MAP/DIR container. Caller MUST keep `buf`
/// alive until blip_dict_index_free. On success *out_handle is an opaque handle.
export fn blip_dict_index_build(buf: [*]const u8, len: usize, out_handle: *?*anyopaque) callconv(.c) i32 {
    const reader = dict_mod.DictReader.init(buf[0..len]) catch |e| return containerErrorCode(e);
    const handle = page_allocator.create(dict_mod.DictIndex) catch return -13;
    handle.* = dict_mod.DictIndex.build(page_allocator, reader) catch |e| {
        page_allocator.destroy(handle);
        return switch (e) {
            error.OutOfMemory => -13,
            else => containerErrorCode(e),
        };
    };
    out_handle.* = @ptrCast(handle);
    return 0;
}

export fn blip_dict_index_count(handle: ?*anyopaque, out_count: *u64) callconv(.c) i32 {
    const idx: *dict_mod.DictIndex = @ptrCast(@alignCast(handle orelse return -2));
    out_count.* = idx.pairCount();
    return 0;
}

/// out_found = 1 if the key exists (and out_index is set), 0 otherwise.
/// Return value: 0 = ok, negative = error. Absence is not an error.
export fn blip_dict_index_find(handle: ?*anyopaque, key: [*]const u8, key_len: usize, out_found: *u8, out_index: *u64) callconv(.c) i32 {
    const idx: *dict_mod.DictIndex = @ptrCast(@alignCast(handle orelse return -2));
    const found = idx.findKey(key[0..key_len]) catch |e| return containerErrorCode(e);
    if (found) |i| {
        out_found.* = 1;
        out_index.* = i;
    } else {
        out_found.* = 0;
        out_index.* = 0;
    }
    return 0;
}

/// Returns a pointer INTO buf (no copy) — valid while handle and buf live.
export fn blip_dict_index_key_at(handle: ?*anyopaque, index: u64, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) i32 {
    const idx: *dict_mod.DictIndex = @ptrCast(@alignCast(handle orelse return -2));
    const s = idx.keyAt(index) catch |e| return containerErrorCode(e);
    out_ptr.* = s.ptr;
    out_len.* = s.len;
    return 0;
}

/// Returns a pointer INTO buf (no copy) — valid while handle and buf live.
export fn blip_dict_index_value_at(handle: ?*anyopaque, index: u64, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) i32 {
    const idx: *dict_mod.DictIndex = @ptrCast(@alignCast(handle orelse return -2));
    const s = idx.valueAt(index) catch |e| return containerErrorCode(e);
    out_ptr.* = s.ptr;
    out_len.* = s.len;
    return 0;
}

export fn blip_dict_index_free(handle: ?*anyopaque) callconv(.c) void {
    const idx: *dict_mod.DictIndex = @ptrCast(@alignCast(handle orelse return));
    idx.deinit(page_allocator);
    page_allocator.destroy(idx);
}
```

- [ ] **Step 3: Add C declarations to `src/blip.h`**

After the `blip_container_key_at(...)` declaration block, add:

```c
/* ---- DictIndex: opt-in fast DICT access (opaque handle) ---- */
/* Build over a DICT/MAP/DIR container. Caller MUST keep `buf` alive until
   blip_dict_index_free. *out_handle receives an opaque handle. */
int32_t blip_dict_index_build(const uint8_t *buf, size_t len, void **out_handle);
int32_t blip_dict_index_count(void *handle, uint64_t *out_count);
/* out_found = 1 if found (out_index set), else 0. Return 0=ok, negative=error. */
int32_t blip_dict_index_find(void *handle, const uint8_t *key, size_t key_len,
                             uint8_t *out_found, uint64_t *out_index);
/* out_ptr aliases the caller's buf (no copy); valid while handle and buf live. */
int32_t blip_dict_index_key_at(void *handle, uint64_t index,
                               const uint8_t **out_ptr, size_t *out_len);
int32_t blip_dict_index_value_at(void *handle, uint64_t index,
                                 const uint8_t **out_ptr, size_t *out_len);
void blip_dict_index_free(void *handle);
```

- [ ] **Step 4: Add FFI tests in `src/lib.zig`**

Add at the end of `src/lib.zig`:

```zig
test "FFI blip_dict_index_* roundtrip" {
    const allocator = testing.allocator;
    const k_alpha = try leaf_mod.serializeUtf8(allocator, "alpha");
    defer allocator.free(k_alpha);
    const k_beta = try leaf_mod.serializeUtf8(allocator, "beta");
    defer allocator.free(k_beta);
    const v1 = try leaf_mod.serializeData(allocator, "one");
    defer allocator.free(v1);
    const v2 = try leaf_mod.serializeData(allocator, "two");
    defer allocator.free(v2);
    const pairs = [_]dict_mod.KeyValue{
        .{ .key = k_alpha, .value = v1 },
        .{ .key = k_beta, .value = v2 },
    };
    const dict = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict);

    var handle: ?*anyopaque = null;
    try testing.expectEqual(@as(i32, 0), blip_dict_index_build(dict.ptr, dict.len, &handle));
    defer blip_dict_index_free(handle);

    var count: u64 = 0;
    try testing.expectEqual(@as(i32, 0), blip_dict_index_count(handle, &count));
    try testing.expectEqual(@as(u64, 2), count);

    var found: u8 = 0;
    var idx: u64 = 99;
    try testing.expectEqual(@as(i32, 0), blip_dict_index_find(handle, "beta", 4, &found, &idx));
    try testing.expectEqual(@as(u8, 1), found);
    try testing.expectEqual(@as(u64, 1), idx);

    try testing.expectEqual(@as(i32, 0), blip_dict_index_find(handle, "zzz", 3, &found, &idx));
    try testing.expectEqual(@as(u8, 0), found);

    var kptr: [*]const u8 = undefined;
    var klen: usize = 0;
    try testing.expectEqual(@as(i32, 0), blip_dict_index_key_at(handle, 0, &kptr, &klen));
    try testing.expectEqualSlices(u8, k_alpha, kptr[0..klen]);

    var vptr: [*]const u8 = undefined;
    var vlen: usize = 0;
    try testing.expectEqual(@as(i32, 0), blip_dict_index_value_at(handle, 1, &vptr, &vlen));
    try testing.expectEqualSlices(u8, v2, vptr[0..vlen]);
}
```

- [ ] **Step 5: Run all tests (should PASS)**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: PASS, including the new FFI test. (The FFI test exercises `_build`/`_free`, so the `page_allocator` allocation is balanced.)

- [ ] **Step 6: Commit**

```bash
jj commit -m "feat(ffi): expose DictIndex via opaque-handle C API

blip_dict_index_build/count/find/key_at/value_at/free, declared in blip.h.
Mirrors blip_container_* semantics: page_allocator-backed handle, slices alias
the caller's buf, errors via containerErrorCode. Zig FFI roundtrip test added."
```

---

## Task 4: Benchmark findKey scaling

**Files:**
- Modify: `src/benchmark.zig` (add `benchDictFindKey`; call it from `main` ~line 523-546)

Note: benchmarks are NOT part of `./test`; they run via `./bm` (ReleaseFast). This task's verification is "builds and runs," not a unit assertion.

- [ ] **Step 1: Add the benchmark function**

Add to `src/benchmark.zig` (before `pub fn main`):

```zig
fn benchDictFindKey(stderr: *WriterType, allocator: std.mem.Allocator) !void {
    try stderr.writeAll("\n--- DICT findKey (ns/lookup) ---\n");
    try stderr.print("{s:>8} | {s:>18} | {s:>18}\n", .{ "keys", "Reader (binary)", "DictIndex (O(1))" });
    try stderr.writeAll("---------+--------------------+--------------------\n");
    try stderr.flush();

    const dict_mod = blip.dict_mod;
    const leaf_mod = blip.leaf_mod;
    const sizes = [_]usize{ 10, 100, 1000, 10000 };
    const LOOKUPS: usize = 100_000;

    inline for (sizes) |N| {
        var keys: [N][]u8 = undefined;
        var vals: [N][]u8 = undefined;
        var pairs: [N]dict_mod.KeyValue = undefined;
        for (0..N) |i| {
            var nb: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&nb, "k{d:0>10}", .{i});
            keys[i] = try leaf_mod.serializeUtf8(allocator, name);
            vals[i] = try leaf_mod.serializeData(allocator, "v");
            pairs[i] = .{ .key = keys[i], .value = vals[i] };
        }
        defer for (0..N) |i| {
            allocator.free(keys[i]);
            allocator.free(vals[i]);
        };

        const dict = try dict_mod.serializeDict(allocator, &pairs);
        defer allocator.free(dict);
        const reader = try dict_mod.DictReader.init(dict);
        var index = try dict_mod.DictIndex.build(allocator, reader);
        defer index.deinit(allocator);

        var prng = std.Random.DefaultPrng.init(SEED +% N);
        const rng = prng.random();

        // Reader (binary search)
        var t1 = try std.time.Timer.start();
        for (0..LOOKUPS) |_| {
            var nb: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&nb, "k{d:0>10}", .{rng.intRangeLessThan(usize, 0, N)});
            const r = try reader.findKey(name);
            doNotOptimizeAway(r);
        }
        const ns_reader = t1.read() / LOOKUPS;

        // DictIndex (O(1) probes)
        var t2 = try std.time.Timer.start();
        for (0..LOOKUPS) |_| {
            var nb: [24]u8 = undefined;
            const name = try std.fmt.bufPrint(&nb, "k{d:0>10}", .{rng.intRangeLessThan(usize, 0, N)});
            const r = try index.findKey(name);
            doNotOptimizeAway(r);
        }
        const ns_index = t2.read() / LOOKUPS;

        try stderr.print("{d:>8} | {d:>18} | {d:>18}\n", .{ N, ns_reader, ns_index });
        try stderr.flush();
    }
}
```

- [ ] **Step 2: Call it from `main`**

In `pub fn main`, after the existing `try benchRandomAccess(io, stderr, allocator);` line, add:

```zig
    try benchDictFindKey(stderr, allocator);
    try stderr.flush();
```

- [ ] **Step 3: Build the benchmark (ReleaseFast) and run it**

Run: `nix develop -c zig build bench -Doptimize=ReleaseFast 2>&1 | tail -20`
Expected: builds cleanly; prints the `DICT findKey` table. The `Reader (binary)` column should grow slowly (log-ish) with N; `DictIndex` should stay roughly flat. **STOP and show Peter the table** — confirm it looks right before encoding any expectations (per the visual-output rule).

- [ ] **Step 4: Commit**

```bash
jj commit -m "bench(dict): findKey scaling at 10/100/1000/10000 keys

Compares DictReader.findKey (binary) vs DictIndex.findKey (O(1) probes).
Verification requested by the 2026-06-01 complexity finding."
```

---

## Task 5: Documentation + final verification

**Files:**
- Modify: `BLIP_CONTAINER_SPEC.md` (Dict section ~line 229)
- Modify: `CODE_MINIMAP.md`
- Modify: `PLAN.md`

- [ ] **Step 1: Update `BLIP_CONTAINER_SPEC.md`**

In the Dict section, near the sorted-keys / binary-search note (~line 229), append a sentence:

```markdown
The reference implementation realizes this: `DictReader.findKey` binary-searches
the sorted keys (O(n log n)), and an opt-in `DictIndex` accelerator parses the
offset table once for O(1) random access and O(log n) lookup (Zig + C FFI
`blip_dict_index_*`). See docs/superpowers/specs/2026-06-01-dict-fast-access-design.md.
```

- [ ] **Step 2: Update `CODE_MINIMAP.md`**

Under the `src/dict.zig` entry, add bullets:

```markdown
- `DictReader.findKey` — binary search over sorted keys (O(n log n)).
- `DictReader.verifyKeysSorted` — invariant check (Debug-only in init; testable).
- `DictIndex` — opt-in accelerator: parse offsets once → O(1) keyAt/valueAt, O(log n) findKey.
```

Under the `src/lib.zig` entry, add:

```markdown
- `blip_dict_index_build/count/find/key_at/value_at/free` — opaque-handle FFI for DictIndex.
```

- [ ] **Step 3: Update `PLAN.md`**

Add a completed section (use the real date when executing):

```markdown
## Opt-in fast DICT access (completed 2026-06-01 EST)
- [x] binary-search findKey + sorted-invariant guard
- [x] DictIndex accelerator (Zig)
- [x] DictIndex C FFI (blip_dict_index_*) + blip.h
- [x] findKey scaling benchmark
- [x] spec + docs updated
```

- [ ] **Step 4: Final full test run**

Run: `nix develop -c zig build test --summary all 2>&1 | tail -8`
Expected: PASS — all tests green.

- [ ] **Step 5: Check the working tree for stray artifacts**

Run: `dirtree` and `jj status`
Expected: only the intended doc edits remain uncommitted; no stray files.

- [ ] **Step 6: Commit**

```bash
jj commit -m "docs(dict): record fast-access API in spec, CODE_MINIMAP, PLAN"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** Component 1 (binary findKey) → Task 1; sorted-invariant guard → Task 1 (steps 5-7); Component 2 (DictIndex) → Task 2; Component 3 (FFI) → Task 3; benchmark → Task 4; docs (`blip.h` in Task 3, spec/minimap/plan in Task 5) → covered.
- **Placeholder scan:** no TBD/TODO; every code step shows complete code; every command shows expected output.
- **Type consistency:** `DictIndex.build(allocator, reader)`, `deinit(allocator)`, `pairCount/keyAt/valueAt/findKey`, and the six `blip_dict_index_*` names are used identically across tasks and the `blip.h` declarations. `out_found` is `*u8` in Zig and `uint8_t*` in C consistently. `compareKeys(stored, query)` ordering is identical in `DictReader.findKey` and `DictIndex.findKey`.
- **Note:** the Debug-only `init` check does not fire in the ReleaseFast test build; that is why `verifyKeysSorted` is tested directly (Task 1, step 7).
