# Code Minimap

A 1-3 line per-file index of the BLIP repository.  Updated 2026-05-04 after the
project split (BLIP / blar / mini_blar).

## Specs (root)

- **BLIP_SPEC.md** — full varint specification (length-prefix mode, sentinels, endianness bit, signed handling).
- **BLIP_SPEC_CONCISE.md** — terse hand-off variant of the spec for LLMs.
- **BLIP_CONTAINER_SPEC.md** — v2 LP envelope, container types, attribute sigils, scalar sentinels, SEGMENT.
- **docs/transport_embedding.md** — disk-files convention for SEGMENT-based archive splitting.

## Build / scripts (root)

- **build.zig** — produces libblip.a, blip-bench, blip-benchmark, printable-binary, runs unit + FFI tests.
- **build.zig.zon** — Zig package manifest (no external deps after the v3 split).
- **flake.nix** — Nix dev shell + `packages.default` + `checks.default` (Garnix-evaluated).
- **./build / ./test / ./bm** — entry-point scripts (Bash) that delegate to nix build / zig build.

## src/ — BLIP-side core

### Varint (the spec implementation)

- **blip.zig** — varint encode/decode, sentinel handling, scalar sentinels (TRUE/FALSE/NIL), `encodedSize`.
- **leb128.zig**, **protobuf_varint.zig**, **asn1_length.zig**, **prefix_varint.zig**, **sqlite_varint.zig** — comparison varints used by benchmarks (`encoding.zig` is the common interface).
- **bignum.zig** — direct LE-byte arithmetic (add/mul/compare) used by benchmarks for arbitrary-precision tests.
- **encoding.zig** — `all_encodings` tuple for comptime iteration across the 6 varints.

### LP envelope + generic containers

- **container_types.zig** — type IDs (ARRAY, DICT, MAP, FILE, DIR, DATA, UTF8), checksum IDs (xxHash64, CRC32, BLAKE3-128), encryption IDs, attribute sigils, scalar sentinels.
- **container.zig** — Length-Payload envelope mechanics: `parseLPHeader`, `computeLPLength`, attribute parsing/serialization.
- **checksum.zig** — `compute(id, data)` / `verify(id, data, expected)` (xxHash64, CRC32, BLAKE3-128).
- **leaf.zig** — UTF8 + DATA leaf containers (serialize/parse).
- **array.zig** — ARRAY container (fixpoint iteration, index tables, xxHash64).
- **dict.zig** — DICT/MAP/DIR containers (sorted keys, interleaved index, xxHash64).

### Navigation & transport

- **peek.zig** — generic LP-envelope path traversal: `parsePath("[0][meta]")`, `navigate`, `containerCount`, `containerHash`, `containerKeyAt`, `peekDisplay`.
- **segmentation.zig** — Layer 5 SEGMENT primitive: `chunkBytes`, `reassemble`, `parseSegment`.

### C FFI surface

- **lib.zig** — `export fn` declarations for every BLIP C-callable function (varint, peek, segment, printable-binary, xxhash, free, error_string).
- **blip.h** — matching C declarations consumed by downstream projects.

### Other

- **main.zig** — `blip-bench` binary, smoke-tests the C FFI from a Zig main().
- **benchmark.zig** — `blip-benchmark` binary, throughput + bignum + random-access benchmarks across all 6 varints.
- **fuzz.zig** — fuzz roundtrip tests (100K random values per encoding).

## vendor/

- **vendor/printable_binary/printable_binary.zig** + **main.zig** — UTF-8 printable encoding (vendored).  Used by the `blip_*_printable_binary` FFI helpers and the `printable-binary` CLI binary.

## Notes

- **No tests/ directory.**  After the v3 split, every shell test moved with the blar/mini_blar archive CLIs (which those tests actually drive).  All BLIP coverage now lives in Zig unit tests embedded inside the modules above (593 tests as of 2026-05-04).
- **Sister projects**: archive functionality (FILE/DIR helpers, codec expansion, archive↔JSON, compression, encryption, archive CLI/GUI) lives in [pmarreck/blar](https://github.com/pmarreck/blar) and [pmarreck/mini_blar](https://github.com/pmarreck/mini_blar).
