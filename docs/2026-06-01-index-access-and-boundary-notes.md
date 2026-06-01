# Design notes: container index access + the blip/blar boundary (2026-06-01)

Captured from a discussion triggered by the fleet code review (2026-06-01).
Two separate threads ended up here:

1. **Container random-access design** — does DICT store offsets like ARRAY,
   and is there a reason random access is O(n) rather than O(1)?
2. **The blip / blar project boundary** — the container layer currently lives
   in BLIP; per the 2026-05-04 split proposal it arguably belongs in blar.
   Decision: **leave as-is for now**, but record the rationale and the cost of
   moving it later.

---

## 1. Container index / random-access design

### What is actually stored (ground truth from `BLIP_CONTAINER_SPEC.md` + code)

Both ARRAY and DICT store a **trailing index section of BLIP-encoded
(variable-width) offsets**. They are structurally the same idea:

| Type  | Index entries                         | Source |
|-------|---------------------------------------|--------|
| ARRAY | `BLIP(off_0) BLIP(off_1) …`           | spec §Array; `array.zig` `elementAt` |
| DICT  | `BLIP(N) BLIP(key0) BLIP(val0) …`     | spec §Dict; `dict.zig` `keyAt`/`valueAt` |

Container layout (DICT), from `serializeDictLike`:

```
[LP header][BLIP(index_offset)][data: key0|val0|key1|val1|…][index: BLIP(N) BLIP(key0_off) BLIP(val0_off) …][optional CSUM]
```

Offsets are **absolute** (from the start of the containing container — spec
§Offset Convention).

### Correcting two errors from the audit note

- The audit note claimed **"ArrayReader is O(1) per index (computed
  offsets)."** This is **false**. `array.zig:elementAt` does `for (0..index)`
  decoding BLIP offsets — it is **O(index)**, exactly like DICT. The spec
  agrees: random access = "skip K offset entries, read offset K" (§Array).
- The note claimed keys are unsorted. **False** — `serializeDict` calls
  `validateKeyOrder`, which errors (`KeysNotSorted`) on any out-of-order pair.
  Keys are guaranteed canonical byte order, and the spec (line ~229) says this
  is *precisely* to enable binary search for many-key dicts.

So: **DICT does store offsets, just like ARRAY. Neither is O(1).** Random
access is O(index); a full key scan (`findKey`) is **O(n²)**.

### Why variable-width offsets (the actual design decision)

The decision was *not* "don't store offsets." It was **store them as
variable-width BLIP varints rather than fixed-width**, plus **index-at-end**.
Rationale:

1. **Space — the dominant case is small containers.** A metadata dict's
   offsets are small integers → ~1 byte each in BLIP vs 4–8 bytes fixed. For a
   12-entry dict that's ~24 bytes vs 96–192. A fixed-width index would often
   dwarf the data it indexes.
2. **Format uniformity.** Everything in BLIP is a BLIP varint — one
   encode/decode primitive, no separate "fixed-width offset table" concept,
   no width-selection metadata.
3. **Unbounded range, no width commitment.** A BLIP offset scales to its
   magnitude; no need to choose u32 (4 GB ceiling) vs always-8-byte u64.
4. **Index-at-end enables single-pass streaming writes.** Offsets are only
   known after layout; emitting the index last lets a writer stream elements,
   record positions, then append the index (with padded-BLIP backfill for the
   `index_offset` field — spec §Streaming Writes).

**The cost:** variable width means you can't compute the position of `offset[K]`
by multiplication — you must decode entries `0..K-1`. Hence O(index) access.

### "Is there an advantage to NOT storing offsets at all?"

Conceptually yes. Every key/value/element is itself **LP-framed**
(self-delimiting via its Length header), so the index is *redundant*: a reader
could walk the chain by hopping each container's `Length`. Dropping the index
would make containers smaller.

But the index earns its keep: walking via LP headers forces you to touch every
(possibly large, possibly deeply nested) payload header to skip it, whereas
walking the compact offset list only decodes small varints. To reach element K
when values are large, walking the offset list is far cheaper than hopping K
payloads. So the current design is a deliberate middle ground: **offsets
present (a compact skip-list) but compact (variable-width).**

### The real tension: "we want fast access in general"

The current design delivers cheap *sequential* iteration and cheap
*space*, but **not** O(1) random access or fast key lookup. Today that is
fine because every real caller uses small fixed-schema records:

- BLIP + blar `findKey` call sites: all small fixed 2-char metadata keys
  (`md mt un ct bt ui gi gn rf xa co zc po pl jx …`).
- blar array access: constant indices (`elementAt(0)`, `elementAt(2)`), never
  a large-N loop.
- blar's large collection (archive entries) is an ARRAY accessed at fixed
  positions, not a filename-keyed DICT.

So the O(n²) `findKey` is real but **cold** — verified across both repos.

**If fast access becomes a real (measured) requirement,** options in
increasing cost:

1. **Binary search over `keyAt(mid)`** — O(n log n), zero new state, no format
   change. Keys are already sorted; the spec already promises this. Each probe
   still walks variable-width offsets, so it's not true O(log n), but it kills
   the quadratic scan. *Lowest friction; this is what the spec intended.*
2. **Parse the offset table once at reader init** into a `[]u64` → O(n)
   one-time, then O(1) probes and true O(log n) binary search. No format
   change; costs one allocation per reader. *Best when a reader does many
   lookups.*
3. **Fixed-width offsets in the index** → O(1) random access, true O(log n)
   cold lookup. *Breaking format change; fatter index for small containers —
   contradicts reason (1) above.*

Recommendation if we act later: **option 1 or 2** (no format change, keeps the
small-container space win). Not pursued now per "solve present requirements,
not hypotheticals" — current usage is cold.

---

## 2. The blip / blar project boundary

### Intended split (2026-05-04 proposal)

| Project    | Scope                                            |
|------------|--------------------------------------------------|
| `blip`     | Length-prefix varint spec + reference codec      |
| `blar`     | The BLIP-framed archiver                          |
| `mini_blar`| Size-constrained subset for embedded/bootstrap   |
| `printable_binary` | the byte↔printable-Unicode visual encoding |

Intent: BLIP = the frozen, RFC-shaped varint primitive; blar = the
actively-developed archiver.

### Current reality

The split partially happened — `../blar` exists with the archiver (tar, zip,
compression, encryption, codec expansion, etc.). **But the container layer
still lives in BLIP**: `dict.zig`, `array.zig`, `container.zig`, `leaf.zig`,
`peek.zig`, `segmentation.zig`, `checksum.zig`, `container_types.zig`.

This middle layer (DICT/MAP/DIR/ARRAY/FILE framing built on BLIP
length-prefixes) sits between "pure varint" and "archiver." Per the proposal's
strict reading it is more archive-structure than varint-spec.

### It is NOT vestigial — blar depends on it both ways

- **Via the C FFI:** `blip_peek`, `blip_container_count`, `blip_container_hash`,
  `blip_container_key_at`, `blip_peek_display`, `blip_segment_*`
  (`src/lib.zig`).
- **Directly in Zig:** `blar/src/lib.zig` imports the `blip` module and calls
  `DictReader.findKey(...)`, `ArrayReader.elementAt(...)` throughout.

`blar/build.zig.zon` declares `blip` as a dependency and consumes its module +
static lib + header.

### Decision (2026-06-01): leave as-is

Peter's call: **do not move the container layer now.** Untangling it is a real
cross-repo refactor, not a quick move:

- blar would absorb `dict/array/container/leaf/peek/segmentation/checksum/
  container_types` (or they'd go to a third shared crate).
- BLIP's public FFI would shrink to the varint surface
  (`blip_encode/decode/is_sentinel/encoded_size`) plus printable-binary
  passthrough.
- Every blar call site would swap its import path; the spec docs
  (`BLIP_CONTAINER_SPEC.md`) would move with the code.

There is no functional problem today — only an organizational/conceptual
mismatch with the original split intent. Revisit if/when BLIP is published as a
standalone frozen spec and the container layer's churn becomes a release-cadence
problem (the original motivation in the split proposal).

---

## Status of the inbox notes that fed this

- **2026-04-22 fix-fsck-duplicateEntries** — already executed 2026-04-24
  (fsck clean, objects GC'd via jj op-trim + gc, no force-push needed).
- **2026-04-24 add-segment-container-type** — accepted & shipped: SEGMENT is
  type 9, SEG sigil 0x14 (`container_types.zig`), `segmentation.zig`,
  `docs/transport_embedding.md`. Open question on M-indexing was resolved
  **1-based** (M=0 illegal in v3), opposite the proposer's suggestion.
- **2026-05-04 project-split** — captured above; boundary left as-is.

All three notes deleted after this capture.
