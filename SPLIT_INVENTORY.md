# BLIP Split Inventory (temporary, delete after Phase 1)

> Snapshot of the carve-out classification for every file under `src/` and `tests/` plus top-level build/spec/meta files. Used during Phase 1 only; deleted in Task 1.11.
>
> **Revision note (2026-05-04):** the original PLAN classification under-estimated how deeply archive types are woven into `poke.zig` and `json_serde.zig`. Both turn out to be archive-coupled (every function takes `mini_blar.FileEntry` / `ArchiveEntry` / `ArchiveReader`). Likewise, every shell test in `tests/` invokes `blar` / `miniblar` binaries — there is no BLIP-only CLI test surface. Reclassified accordingly.

## STAYS in BLIP

### Source (src/)
- blip.zig                  # varint encode/decode (the BLIP spec implementation)
- container_types.zig       # sigils, type IDs, checksum IDs, encryption IDs
- container.zig             # LP envelope mechanic
- checksum.zig              # CRC32, xxHash64, BLAKE3-128
- leaf.zig                  # UTF8 + DATA leaf containers
- array.zig                 # ARRAY container
- dict.zig                  # DICT only — split out FILE/DIR (Task 1.5)
- peek.zig                  # generic LP envelope path traversal (no archive coupling)
- segmentation.zig          # SEGMENT transport-fragmentation primitive
- encoding.zig              # comparison varint interface (used by benchmarks)
- leb128.zig                # comparison varint
- protobuf_varint.zig       # comparison varint
- asn1_length.zig           # comparison length
- prefix_varint.zig         # comparison varint
- sqlite_varint.zig         # comparison varint
- bignum.zig                # comparison bignum encoding
- fuzz.zig                  # fuzz harness
- benchmark.zig             # blip-benchmark binary entry
- main.zig                  # blip-bench binary entry (FFI smoke test)
- lib.zig                   # KEEP only the BLIP-side FFI exports (Task 1.4)
- blip.h                    # KEEP only BLIP-side C declarations (Task 1.4)

### Specs / docs
- BLIP_SPEC.md
- BLIP_SPEC_CONCISE.md
- BLIP_CONTAINER_SPEC.md
- docs/transport_embedding.md

### Build
- flake.nix                 # trim to BLIP-only inputs/outputs (Task 1.8)
- build.zig                 # trim to BLIP-only artifacts (Task 1.7)
- build.zig.zon             # trim deps
- ./build, ./test, ./bm     # entry-point scripts (drop shell test loop in `./test`)

### Meta
- README.md, CLAUDE.md, AGENTS.md, RULES.md, PROJECT_OVERVIEW.md, CODE_MINIMAP.md, PLAN.md
- LICENSE
- inbox/                    # project comms

## MOVES OUT of BLIP

(Files persist in `../blar/` and `../mini_blar/` working copies; they are deleted from `pmarreck/BLIP` only.)

### Source (src/) — to blar
- streaming.zig             # archive-side streaming
- expansion.zig             # codec expansion engine
- blar.c                    # archive CLI
- blar_common.h             # archive C declarations
- compression.zig           # archive compression
- compression_stub.zig      # archive compression stub
- lzma2.zig                 # LZMA2 codec
- encryption.zig            # archive encryption
- json_serde.zig            # archive↔JSON (depends on `mini_blar.ArchiveEntry`)
- poke.zig                  # archive-entry mutation (every fn takes `FileEntry`/`DirEntry`)
- jxl.zig, flac.zig, pdf.zig, png.zig, bmp.zig, tar.zig, tiff.zig, gif.zig, tga.zig, wav.zig, aiff.zig, fits.zig, dicom.zig, nifti.zig, zip.zig
                            # codec expansion adapters

### Source (src/) — to mini_blar
- mini_blar.zig             # high-level archive API (FileEntry, ArchiveReader, etc.)
- miniblar.c                # mini_blar CLI

### Other
- macos-app/                # blar GUI

### Tests (tests/) — to blar
All shell tests reference the `blar`/`miniblar` binaries; none drive BLIP directly.
- peek_test.sh, poke_test.sh
- binary_format_test.sh, text_roundtrip_test.sh
- segmentation_test.sh, json_test.sh, tri_representation_test.sh
- blar_test.sh, blar_full_test.sh
- compression_test.sh, encryption_test.sh
- container_expansion_test.sh, container_expansion_dual_test.sh
- pdf_container_test.sh, png_container_test.sh
- streaming_test.sh, explode_implode_test.sh

### Tests (tests/) — to mini_blar
- miniblar_test.sh

## Notes

- BLIP retains no shell tests. Coverage is via `nix develop -c zig build test` (the Zig unit tests in each module — currently ~841 tests, of which the codec/archive subset is going away with the deleted modules; expect ~500-600 tests post-trim).
- `printable_binary` remains an external dep of BLIP (decision (a) in Task 1.4a) so the FFI exports `blip_decode_printable_binary`/`blip_encode_printable_binary` survive.
- `dict.zig` STAYS but is split (FILE/DIR archive types extracted in Task 1.5).
- `LICENSE`, `inbox/` and the spec markdowns are project-wide and trivially stay.
