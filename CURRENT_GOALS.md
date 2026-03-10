# BLIP/blar Current Goals

## Recently Completed (this session)

1. **Fixed progrez ETA for expansion phase** — was passing `bytes_total=0` to `progrez_set_determinate()`, causing fallback to inaccurate file-count-based ETA. Now passes `total_expandable_bytes`. (committed `18d1346`)

2. **Fixed PDF container expansion for xref-stream PDFs** — nested dicts like `/DecodeParms<<...>>` caused the xref stream parser to break out of the outer dict prematurely, missing `/Length`. The xref path silently returned 0 entries instead of erroring to fall through to linear scan. Fixed by properly skipping nested dict values. (committed `aee806e`)

3. **Fixed segfault in container expansion with many images** — `expand_pdf_container()` calls `entry_list_add()` which may `realloc` the entries array, invalidating the `&el->entries[i]` pointer passed as `file_entry`. Fixed by copying the entry by value before calling expand functions. Tested with Far Side Vol I (673 JPEGs, 158MB → 122MB, byte-identical extraction). (committed `dacb98d`)

4. **Parallel JPEG→JXL transcode + batch PDF stream API** — Implemented batch FFI (`blip_pdf_jpeg_streams`) returning parallel arrays of all JPEG stream offsets/lengths/obj/gen in one call, enabling parallel transcode. (committed `52f2ef0`)

5. **FlateDecode image expansion in PDFs (Phases 4-7)** — PNG-style images inside PDFs transcoded to lossless JXL. Detection, defiltering, zlib decompress/compress, metadata fields, FFI exports, ingestion in blar.c all complete. Extraction works when recompressed size matches; PDF rewrite for size-changing streams deferred to Phase 6. (committed `682b202`)

6. **Phase 6: PDF rewrite for FlateDecode extraction** — Implemented `rewritePdfWithStreams()` in pdf.zig: updates `/Length` values, rebuilds xref table with delta-point offset tracking, handles same-size fast path. FFI export `blip_pdf_rewrite_streams` in lib.zig/blip.h. blar.c extraction does two-phase: JPEG splice then FlateDecode recompress+splice/rewrite. Falls back gracefully for xref-stream PDFs.

7. **Phase 7: poke.zig + json_serde.zig flate fields** — All four FlateDecode metadata fields (fb/fc/fl/fp) implemented in: FileEntry struct (mini_blar.zig), archive reading (poke.zig), archive modification (poke.zig), JSON serialization/deserialization (json_serde.zig).

8. **Replaced stored-blocks zlibCompress with C zlib** — The Zig 0.15 flate compressor has `@panic("TODO")`, so replaced the workaround (stored deflate blocks, always larger than input) with real C zlib `compress2()`. This means FlateDecode extraction no longer always triggers the PDF rewrite path.

## Active / Next Up

### Lower Priority / Future

7. **Re-create books.blar** — The old books.blar was created with the corrupt z7z encoder (before the sliding window fix). Needs to be re-created with the fixed encoder. With expansion enabled, this will also benefit from JPEG→JXL savings across all PDFs.

8. **PDF text extraction / markdown conversion** — Discussed as a potential separate project for lawyers searching through PDF/Word evidence. Would leverage existing PDF parsing in pdf.zig. Key steps: content stream decompression, text operator parsing, ToUnicode CMap handling, font-size-based heading detection.

## Key Bugs Fixed Earlier (for context)

- z7z LZMA2 MatchFinder sliding window fix (O(data.len) → O(dict_size) memory, prevented 204GB allocation on 128GB machine) — committed to z7z repo, BLIP dependency updated
- Two-pass container expansion refactor (separate progress phase with filename display)
- Debug output cleanup from compression.zig and blar_common.h
