# Spec: Opt-in fast DICT access (binary-search `findKey` + `DictIndex`)

**Date:** 2026-06-01
**Status:** approved design — ready for implementation plan
**Scope:** DICT only (ARRAY and the rest of the container layer unchanged)

## Motivation

`DictReader.findKey` is a linear scan, and `keyAt(i)` walks the variable-width
BLIP offset list from the start (O(i) per call), making `findKey` **O(n²)**.
The `BLIP_CONTAINER_SPEC.md` already states keys are stored sorted *precisely*
to enable binary search (Dict section), but the implementation never did it.

Current usage is cold (every caller uses small fixed-schema metadata dicts), so
this is not a hot-path fix — it is about giving library consumers a real
fast-access option, chosen per use case and storage context, without paying for
it when they don't need it. Background and the offset-design rationale:
`docs/2026-06-01-index-access-and-boundary-notes.md`.

## Design overview

Two independent pieces:

1. **`DictReader.findKey` becomes a binary search** — the free, zero-alloc,
   behavior-preserving default. Strictly better than the linear scan (keys are
   already sorted); no format change.
2. **`DictIndex`** — an opt-in, allocating accelerator built from a
   `DictReader`. Parses the offset table once (O(n)) into `[]u64`, then offers
   O(1) random access and O(log n) `findKey`. Exposed in both Zig and the C FFI.

`DictReader` stays a pure, allocator-free view over bytes. The allocation lives
entirely in `DictIndex` (separate-accelerator pattern), keeping the reader's
responsibility singular and testable.

## Component 1 — binary-search `findKey`

Keys are guaranteed canonical byte order by `validateKeyOrder` at serialize
time, using `compareKeys`. `findKey` uses the same ordering:

```
lo = 0; hi = self.count
while (lo < hi):
    mid = lo + (hi - lo) / 2
    k   = extractKeyBytes(keyAt(mid))
    switch compareKeys(k, key_bytes):
        .eq -> return mid
        .lt -> lo = mid + 1
        .gt -> hi = mid
return null
```

- Same results as the current linear scan; **O(n log n)** (each probe's
  `keyAt(mid)` is still O(mid)) instead of O(n²). Zero allocation, no format
  change, no signature change.
- The existing FFI (`blip_container_*`, any path through `findKey`) transparently
  gets the improvement.

### Sorted-invariant safety

Binary search depends on the sorted invariant. Malformed/hand-crafted input that
violates it could make `findKey` miss a key the linear scan would find. Mitigate
with a **Debug-only** assertion in `DictReader.init` that verifies adjacent keys
are non-decreasing (`compareKeys != .gt`). Zero cost in Release
(`if (builtin.mode == .Debug)`).

## Component 2 — `DictIndex` (Zig)

```zig
pub const DictIndex = struct {
    buf: []const u8,   // borrowed — must outlive the index
    offsets: []u64,    // owned — 2*count entries: [key0,val0,key1,val1,...]
    count: u64,

    /// Single O(n) pass: decode all 2*count BLIP offsets from the index section.
    pub fn build(allocator: Allocator, reader: DictReader) (Allocator.Error || LPContainerError)!DictIndex;
    pub fn deinit(self: *DictIndex, allocator: Allocator) void; // frees offsets

    pub fn pairCount(self: DictIndex) u64;                      // O(1)
    pub fn keyAt(self: DictIndex, index: u64) LPContainerError![]const u8;   // O(1)
    pub fn valueAt(self: DictIndex, index: u64) LPContainerError![]const u8; // O(1)
    pub fn findKey(self: DictIndex, key_bytes: []const u8) LPContainerError!?u64; // O(log n)
};
```

- **`build`** walks the index section once, sequentially decoding `2*count`
  offsets into `offsets`. On any decode error it returns the error and frees the
  partial allocation (`errdefer`). O(n) total vs. the reader's per-call O(i).
- **`keyAt(i)`/`valueAt(i)`**: `off = offsets[2*i (+1)]`; parse the LP header at
  `buf[off..]` to get the container extent; return the slice. O(1).
- **`findKey`**: identical binary search to Component 1 but using the O(1)
  `keyAt`, giving O(log n) with O(1) probes.
- **Memory custody:** owns only `offsets`; borrows `buf`. Caller keeps `buf`
  alive and calls `deinit`. Canonical entry is `DictIndex.build(allocator,
  reader)`; no method is added to `DictReader` (keeps the reader allocator-free).

## Component 3 — C FFI (opaque handle)

```c
// Build once; caller MUST keep `buf` alive until _free. *out_handle is opaque.
int32_t blip_dict_index_build(const uint8_t* buf, size_t len, void** out_handle);

int32_t blip_dict_index_count(void* handle, uint64_t* out_count);

// out_found distinguishes found/absent; return value is 0=ok, negative=error.
int32_t blip_dict_index_find(void* handle, const uint8_t* key, size_t key_len,
                             bool* out_found, uint64_t* out_index);

// key/value slices point INTO buf (no copy), like blip_container_key_at.
int32_t blip_dict_index_key_at(void* handle, uint64_t index,
                               const uint8_t** out_ptr, size_t* out_len);
int32_t blip_dict_index_value_at(void* handle, uint64_t index,
                                 const uint8_t** out_ptr, size_t* out_len);

void    blip_dict_index_free(void* handle);
```

- Handle is `page_allocator.create(...)` wrapping the Zig `DictIndex`; `build`
  allocates `offsets` via `page_allocator`; `_free` calls `deinit` then
  `destroy`. (Consistent with all other FFI allocations in `lib.zig`.)
- Errors map through the existing `containerErrorCode`. Return convention:
  `0` = success, negative = error.
- `_find` sets `out_found` (bool) and, when found, `out_index`. Not-found is
  `out_found=false` with return `0` (absence is not an error).
- **Custody:** handle owns `offsets`; borrows `buf`; returned key/value pointers
  alias `buf` — valid while both handle and `buf` live. Same contract as
  `blip_container_key_at`.
- Declarations added to `src/blip.h`.

## Testing (TDD)

### `findKey` binary search (harden an existing-coverage refactor)
- **Set-based correctness:** build dicts of sizes {1, 2, 50, 500}; assert every
  present key resolves to its correct index, and a swept set of absent keys
  (before-first, between each adjacent pair, after-last) all return `null`.
  (Filters tested as classifiers over sets, per project rules.)
- **Debug sortedness assertion:** a hand-crafted unsorted dict trips the
  `init` assertion in a Debug build.

### `DictIndex` (new behavior — write failing tests first)
- **Oracle test:** for a generated dict, assert `DictIndex.keyAt/valueAt/
  findKey/pairCount` equal the corresponding `DictReader` results across all
  indices and a swept key set. Write → fail (type absent) → implement → pass.
- **Error/leak path:** malformed offset makes `build` return an error and leak
  nothing — verified with `std.testing.allocator` (leak-detecting).

### FFI (Zig tests in `lib.zig` calling the `export fn`s)
- build → count → find (found + absent) → key_at → value_at roundtrip against a
  known dict; then `_free`. Correctness asserted at this layer; leak-tracking
  asserts live at the Zig `DictIndex` layer (`page_allocator` is not
  leak-tracking).

### Benchmark (`benchmark.zig`, ReleaseFast)
- `findKey` at **10 / 100 / 1000 / 10000** keys: `DictReader.findKey` (binary)
  vs `DictIndex.findKey`. Logged to `bench/*.jsonl`; confirms logarithmic, not
  linear, growth — the verification the original complexity finding requested.

### Hygiene
- All test stderr captured and asserted (clean runs).
- `./test` stays green at every commit; benchmarks run only via `./bm`.

## Documentation updates
- `src/blip.h` — new FFI declarations.
- `BLIP_CONTAINER_SPEC.md` — note the binary-search guarantee is now realized and
  the optional `DictIndex` accelerator exists.
- `CODE_MINIMAP.md` — `DictIndex` in `dict.zig`; new FFI exports in `lib.zig`.
- `PLAN.md` — track the work items.

## Non-goals (YAGNI)
- No changes to ARRAY or other container types (random access there stays
  O(index); revisit separately if measured hot).
- No format change (offsets stay variable-width BLIP; fixed-width is explicitly
  rejected — see the index-access notes doc).
- No caching/memoization inside `DictReader` (it stays a pure view).

## Open questions
None outstanding — all resolved during brainstorming (scope = findKey + opt-in
index; API = separate `DictIndex`; FFI = exposed now; M-indexing/format
untouched).
