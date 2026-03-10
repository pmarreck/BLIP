# BLIP/blar Current Goals

## Recently Completed (this session)

1. **Fixed progrez ETA for expansion phase** — was passing `bytes_total=0` to `progrez_set_determinate()`, causing fallback to inaccurate file-count-based ETA. Now passes `total_expandable_bytes`. (committed `18d1346`)

2. **Fixed PDF container expansion for xref-stream PDFs** — nested dicts like `/DecodeParms<<...>>` caused the xref stream parser to break out of the outer dict prematurely, missing `/Length`. The xref path silently returned 0 entries instead of erroring to fall through to linear scan. Fixed by properly skipping nested dict values. (committed `aee806e`)

3. **Fixed segfault in container expansion with many images** — `expand_pdf_container()` calls `entry_list_add()` which may `realloc` the entries array, invalidating the `&el->entries[i]` pointer passed as `file_entry`. Fixed by copying the entry by value before calling expand functions. Tested with Far Side Vol I (673 JPEGs, 158MB → 122MB, byte-identical extraction). (committed `dacb98d`)

## Active / Next Up

### High Priority

4. **Parallelize container expansion** — The expansion pass is single-threaded. Each JPEG→JXL transcode is independent and could run in parallel. Currently a 590MB PDF with 30K JPEGs takes hours on one core. This is the biggest performance bottleneck for image-heavy archives.
   - Approach: Thread pool for JPEG→JXL transcodes within `expand_pdf_container()`
   - The entry list mutations (adding DIR/children) must remain single-threaded, but the actual JXL encoding can be parallelized
   - Could also parallelize across files (multiple PDFs/PNGs expanding concurrently)

5. **FlateDecode image expansion in PDFs (Phases 4-7)** — PNG-style images inside PDFs are not yet transcoded to JXL. This would give MORE significant savings than JPEG→JXL (~50% for lossless pixel data vs ~20% for JPEG recompression). Requires:
   - Phase 4: `findFlateImageStreams()` in pdf.zig
   - Phase 5: FlateDecode metadata fields + ingestion in blar.c
   - Phase 6: PDF rewrite for extraction (hardest — recompressed FlateDecode data may differ in size, requiring `/Length` update + xref rebuild)
   - Phase 7: poke.zig + json_serde.zig support for new fields
   - Plan details in `/Users/pmarreck/.claude/plans/async-drifting-blum.md`

### Lower Priority / Future

6. **Re-create books.blar** — The old books.blar was created with the corrupt z7z encoder (before the sliding window fix). Needs to be re-created with the fixed encoder. With expansion enabled, this will also benefit from JPEG→JXL savings across all PDFs.

7. **PDF text extraction / markdown conversion** — Discussed as a potential separate project for lawyers searching through PDF/Word evidence. Would leverage existing PDF parsing in pdf.zig. Key steps: content stream decompression, text operator parsing, ToUnicode CMap handling, font-size-based heading detection.

## Key Bugs Fixed Earlier (for context)

- z7z LZMA2 MatchFinder sliding window fix (O(data.len) → O(dict_size) memory, prevented 204GB allocation on 128GB machine) — committed to z7z repo, BLIP dependency updated
- Two-pass container expansion refactor (separate progress phase with filename display)
- Debug output cleanup from compression.zig and blar_common.h
