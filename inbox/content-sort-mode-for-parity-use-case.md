# Request: Content-based sort mode for mini_blar archives

**From**: entropy_shield
**Date**: 2026-02-25

## Problem

mini_blar currently sorts `FileEntry` items by path (lexicographic byte order). For entropy_shield's manifest parity use case, this is problematic: **file renames cause catastrophic blob reordering**, which destroys par2 repair capability.

## Why it matters

entropy_shield computes par2 parity over mini_blar archives. Par2 works on fixed-size blocks. When files reorder in the archive, blocks shift, and par2 sees massive "damage" even though no actual content changed. This eats the redundancy budget needed for real corruption repair.

The scenario: a manifest contains 30 small files. One file is renamed (intentional), another is corrupted (bit rot). With path-sorting, the rename cascades through the blob, consuming the par2 budget. The corruption becomes unrecoverable.

## Requested feature

A sort mode (or option) for `createArchive` / `createFullArchive` that sorts entries by **raw binary content** (lexicographic byte comparison of `FileEntry.content`), with path as a tiebreaker for identical content.

### Why raw content, not content hash?

Sorting by xxHash64 of content would randomize position on any change (hashes are avalanche-designed). Sorting by raw bytes provides **locality**: if the first N bytes are unchanged, the file stays at approximately the same position. This makes:

- Renames: invisible (content unchanged)
- Corruption in middle/end: invisible (first bytes unchanged)
- Appends: invisible (prefix unchanged)
- Middle edits: minimal position shift

### API suggestion

```zig
pub const SortOrder = enum {
    by_path,      // current default, good for archive browsing
    by_content,   // good for parity: minimizes blob churn on file changes
};

pub fn createArchive(allocator: Allocator, files: []const FileEntry,
                      sort: SortOrder) ![]u8;
```

Or keep the current `createArchive` as path-sorted and add `createArchiveContentSorted`.

## Alternative

entropy_shield could pre-sort the files before passing to `createArchive`, but that bypasses mini_blar's internal sort (it re-sorts regardless). We'd need either a no-sort option or to match the internal sort order from outside.
