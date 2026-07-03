---
purpose: Parking lot for future BLIP-adjacent directions — captured so they don't nag or derail the current productive goal
audience: both
maintained_by: human
---

# BLIP — Ideas / Future Directions

> Not commitments. Parked here deliberately so a good idea is *written down* (and can be let go) without pulling focus off whatever ships next. Promote to `PLAN.md` only when an idea earns a productive goal.

## Shared-memory offset store (SWMR KV over BLIP) — parked 2026-07-03

**One-liner:** a fast in-memory dict/array store (GET/PUT/DEL) in an mmap'd region, imported by 2+ processes, single-writer / multi-reader — where *references into it can cross the process boundary because they're offsets, not pointers*.

**Why it fits BLIP:** BLIP is already offset-addressed, self-describing, and pointer-free, so the container tree *is* the shared-memory layout (no separate serialization; "one format for storage, wire, and now shared memory"). Prior art: Boost.Interprocess `offset_ptr` / relative pointers; LMDB (mmap + MVCC + single writer).

**Core design:** copy-on-write with an **atomic root-offset swap** (MVCC) → lock-free, consistent-snapshot reads that never block; single writer serializes mutations.

**References across the boundary — the real design axis:**
- **Physical `(epoch, offset)`** — O(1) deref, but holding one *pins its version* (GC can't reclaim it) → reader-liveness problem; a crashed holder stalls reclamation.
- **Logical path** (e.g. `"tasks/42/progress"`) — always valid, re-resolved against the live root (O(log n)), but the target can change under you.
- Likely want **both**, bridged by a snapshot/txn handle (à la LMDB read txn: pin a version, then chase physical offsets cheaply within it).

**Hard parts (the honest ones):** (1) reclaiming old MVCC versions when a slow/crashed reader still holds a snapshot; (2) BLIP's sorted-array dict makes a PUT O(n) *per node* (COW rebuild) — a HAMT/B+tree gives O(log n) structural sharing, so the mutable internal node may differ from BLIP-as-snapshot; (3) growth (fixed arena vs remap-invalidates-readers); (4) writer/reader crash semantics + robust cross-process mutex (Windows diverges); (5) durability: ephemeral vs file-backed.

**Where it could earn a goal:** a hybrid IPC for validate-serve — server = single writer, GUI clients mmap the store and read results/progress with zero round-trip; socket keeps command ordering. Only worth building if read-throughput of shared state becomes a real bottleneck the socket can't meet.
