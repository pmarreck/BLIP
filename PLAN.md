# BLIP Implementation Plan

## Completed
- [x] Project scaffolding (flake.nix, build.zig) ~2026-02-22 23:40 EST
- [x] GitHub repo creation (pmarreck/BLIP) ~2026-02-22 23:42 EST
- [x] BLIP core encode/decode with 51 spec-verified tests ~2026-02-22 23:47 EST
- [x] LEB128 + SLEB128 implementation ~2026-02-22 23:55 EST
- [x] Protobuf varint + ZigZag ~2026-02-22 23:58 EST
- [x] ASN.1 BER length encoding ~2026-02-23 00:03 EST
- [x] PrefixVarint encoding ~2026-02-23 00:07 EST
- [x] SQLite varint encoding ~2026-02-23 00:10 EST
- [x] Common encoding interface ~2026-02-23 00:12 EST
- [x] C FFI for BLIP ~2026-02-23 00:20 EST
- [x] CLI entry point through C FFI ~2026-02-23 00:25 EST
- [x] Bignum direct LE arithmetic ~2026-02-23 00:30 EST
- [x] Benchmark suite (throughput, bignum, random-access) ~2026-02-23 00:45 EST
- [x] Fuzz tests ~2026-02-23 01:00 EST
- [x] Project documentation ~2026-02-23 01:05 EST

## Container Library (Completed 2026-02-23)
- [x] `encodedSize` public API on blip.zig
- [x] container_types.zig — ContainerType enum, sentinel mapping
- [x] container.zig — TLV header, self-referential length solver
- [x] leaf.zig — UTF8 + RAW container serialize/parse
- [x] array.zig — ARRAY with fixpoint iteration, index tables, xxHash64
- [x] dict.zig — DICT/FILE with key ordering, interleaved index
- [x] mini_blip.zig — high-level archive API (createArchive, ArchiveReader)
- [x] Container C FFI exports (blip_archive_create, verify, file_count, free)
- [x] 447 tests total (all passing)

## blar CLI (Completed 2026-02-23)
- [x] Typed FFI error codes and blip_error_string
- [x] FFI archive access: file_path, file_content, file_content_by_path, file_verify
- [x] blar C CLI (create/list/extract/verify/info/cat) with progress bar
- [x] Bash integration tests

## blar/miniblar Split + DIR Container (Completed 2026-02-24)
- [x] DIR container type (0x81 0x07) in ContainerType enum
- [x] serializeDir() with path+xh64 required key validation
- [x] DictReader updated to accept .dir type
- [x] DirEntry, ArchiveEntry union, computeMerkleHash
- [x] createFullArchive() with FILE+DIR+metadata support
- [x] ArchiveReader: entryCount, entryAt, entryTypeAt
- [x] C FFI: blip_archive_create_full, entry_type, entry_metadata
- [x] blar_common.h — shared utilities
- [x] miniblar.c — flat file-only CLI (rejects directories)
- [x] blar.c — rewritten for full spec (directory recursion, metadata, Merkle hash)
- [x] build.zig — miniblar target added
- [x] Integration tests: 18 blar tests + 19 miniblar tests (all passing)
- [x] Documentation updates (spec, README, CODE_MINIMAP)

## Future
- [ ] Arbitrary-width encode/decode (values > u64)
- [ ] Streaming writes with padded BLIPs for containers
- [ ] Cross-language implementations (C, Rust, etc.)
- [ ] Compression wrapper container type
