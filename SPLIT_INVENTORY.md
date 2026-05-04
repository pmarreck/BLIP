# BLIP Split Inventory (temporary, delete after Phase 1)

> Snapshot of the carve-out classification for every file under `src/` and `tests/` plus top-level build/spec/meta files. Used during Phase 1 only; deleted in Task 1.11.

## STAYS in BLIP

### Source (src/)
- blip.zig                  # varint encode/decode (the BLIP spec implementation)
- container_types.zig       # sigils, type IDs, checksum IDs, encryption IDs
- container.zig             # LP envelope mechanic
- checksum.zig              # CRC32, xxHash64, BLAKE3-128
- leaf.zig                  # UTF8 + DATA leaf containers
- array.zig                 # ARRAY container
- dict.zig                  # DICT only — split out FILE/DIR (Task 1.5)
- peek.zig                  # BLIP navigation API
- poke.zig                  # BLIP mutation API
- segmentation.zig          # SEGMENT transport-fragmentation primitive
- json_serde.zig            # generic LP-envelope <-> JSON (part of BLIP library API)
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

### Tests (tests/)
- peek_test.sh              # tests BLIP peek navigation
- poke_test.sh              # tests BLIP poke mutation
- segmentation_test.sh      # KEEP only the segment-arbitrary-bytes tests; split in Task 1.6
- text_roundtrip_test.sh    # tests BLIP text format roundtrip
- binary_format_test.sh     # tests BLIP binary roundtrip

### Build
- flake.nix                 # trim to BLIP-only inputs/outputs (Task 1.8)
- build.zig                 # trim to BLIP-only artifacts (Task 1.7)
- build.zig.zon             # trim deps
- ./build, ./test, ./bm     # entry-point scripts

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
- jxl.zig, flac.zig, pdf.zig, png.zig, bmp.zig, tar.zig, tiff.zig, gif.zig, tga.zig, wav.zig, aiff.zig, fits.zig, dicom.zig, nifti.zig, zip.zig
                            # codec expansion adapters

### Source (src/) — to mini_blar
- mini_blar.zig             # high-level archive API
- miniblar.c                # mini_blar CLI

### Other
- macos-app/                # blar GUI

### Tests (tests/) — to blar
- blar_test.sh, blar_full_test.sh
- compression_test.sh, encryption_test.sh
- container_expansion_test.sh, container_expansion_dual_test.sh
- pdf_container_test.sh, png_container_test.sh
- streaming_test.sh
- explode_implode_test.sh
- json_test.sh              # invokes blar/miniblar binaries — moves with blar
- tri_representation_test.sh # invokes blar binary — moves with blar

### Tests (tests/) — to mini_blar
- miniblar_test.sh

## Notes

- `json_serde.zig` stays as a generic LP-envelope <-> JSON utility (part of BLIP's library surface). The integration tests that exercise it through `blar`/`miniblar` CLIs (`json_test.sh`, `tri_representation_test.sh`) move with the blar agent, where those binaries continue to exist. If/when BLIP grows its own JSON CLI surface, those tests can be re-added in a smaller form.
- `printable_binary` is already a separate repo and is not present under `src/` or `tests/` — see Task 1.4a.
- `LICENSE`, `inbox/` and the spec markdowns are project-wide and trivially stay.
- `dict.zig` STAYS but is split (FILE/DIR archive types extracted in Task 1.5).
- `segmentation_test.sh` STAYS but is split (archive-level segment/join tests extracted in Task 1.6).
