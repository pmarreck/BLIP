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
- [x] mini_blar.zig — high-level archive API (createArchive, ArchiveReader)
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

## poke Command (Completed 2026-02-24)
- [x] poke.zig — reconstructEntries (inverse of createFullArchive), pokeArchive
- [x] Path target classification: data_content, metadata_leaf, container (error), immutable (error)
- [x] C FFI: blip_poke export in lib.zig + blip.h
- [x] blar/miniblar CLI: poke command + Kf tar-style flag
- [x] Value input: --value, -i (file), stdin
- [x] Output: in-place (atomic write), -o (different file), --backup (.bak)
- [x] Integration tests: 22 poke tests (all passing)
- [x] All existing tests still pass (141 tests across 5 suites)
- [x] README documentation

## JSON Serialization/Deserialization (Completed 2026-02-25)
- [x] json_serde.zig — archiveToJson, jsonToArchive, timestamp/mode formatting
- [x] High-level structured JSON format (entries array with type/path/content/metadata)
- [x] Printable-binary encoding for binary content in JSON strings
- [x] Merkle hash recomputation for DIR entries on from-json
- [x] C FFI: blip_to_json, blip_from_json exports in lib.zig + blip.h
- [x] blar/miniblar CLI: to-json + from-json commands, j/J tar-style flags
- [x] Full jq integration: content/path/mode/timestamp manipulation, add/remove entries
- [x] Integration tests: 34 JSON tests + 12 Zig unit tests (all passing)
- [x] All existing tests still pass (158 tests across 6 suites)
- [x] README documentation with jq pipeline examples

## v2 LP Container Format Migration (Completed 2026-02-27)
- [x] LP (Length-Payload) envelope replaces old TLV structure
- [x] Sorted attribute sigils: TYPE, COMP, DECOMP_LEN, CSUM, ENC, SIG, VAL
- [x] container_types.zig — AttributeSigil, ContainerTypeId, CompressionId, ChecksumId, EncryptionId, KdfId enums
- [x] container.zig — computeLPLength, writeLPHeader, parseLPHeader
- [x] Per-container LZMA2 compression via COMP attribute (blar create -z)
- [x] Per-container checksums via CSUM attribute (CRC32, xxHash64, BLAKE3-128)
- [x] BLAKE3-128 outer archive integrity + xxHash64 inner containers
- [x] Per-file xxHash64 checksums on FILE/DATA/DIR containers
- [x] Merkle hash auto-computation in createFullArchive
- [x] All existing CLI tools updated for v2 LP format
- [x] Integration tests: 25 LZMA2 tests + 21 binary format tests (all passing)

## Encryption (Completed 2026-02-28)
- [x] EncryptionId (AES-256-GCM, ChaCha20-Poly1305) + KdfId (Argon2id, PBKDF2-SHA256) enums
- [x] ENC attribute sigil (0x13) in LP envelope sort order
- [x] encryption.zig — deriveKey, encrypt, decrypt, encryptContainer, decryptContainer, isEncrypted
- [x] AES-256-GCM + ChaCha20-Poly1305 AEAD ciphers via Zig stdlib
- [x] Argon2id (64 MiB, t=3, p=4) + PBKDF2-SHA256 (600k rounds) key derivation
- [x] C FFI: blip_is_encrypted, blip_encrypt_container, blip_decrypt_container
- [x] blar CLI: `blar create -e` (encrypt), `--kdf` (KDF selection), auto-decrypt on read
- [x] Password from BLIP_PASSWORD env var or interactive prompt on stderr
- [x] Layering: compress → encrypt → checksum (write), checksum → decrypt → decompress (read)
- [x] Integration tests: 14 encryption tests (all passing)
- [x] All existing tests still pass (236 shell tests + all Zig unit tests)

## Future
- [ ] Arbitrary-width encode/decode (values > u64)
- [ ] Streaming writes with padded BLIPs for containers
- [ ] Cross-language implementations (C, Rust, etc.)
- [ ] Binary data manipulation DSL — extend peek/poke into a full structural editor (insert/delete array elements, add/remove dict keys, splice content, move entries, etc.). Note: JSON interchange (`to-json | jq | from-json`) already covers most high-level manipulation use cases.
- [ ] Segmentation container type — a new top-level container for splitting large archives into fixed-size segments (e.g. for transport over size-limited channels, span across volumes, or resumable transfers)
- [ ] Per-MIME-type zstd dictionaries — When using zstd with per-file compression: (1) group files by MIME type, (2) train a zstd dictionary per group on the fly, (3) store dictionaries in a MAP container within the archive keyed by MIME type, (4) compress each file with its group's dictionary. Dictionary-level compression gains without solid-archive fragility. If a dictionary is corrupted, only its group's files are lost. Design questions: minimum sample threshold for training (zstd recommends 100+ samples), CLI UX (`-z zstd-dict` vs automatic).
- [ ] Archive metadata inspection (`blar info --depth N`) — Rich metadata reporting at the FFI level, exposed through CLI. Reports: compression algorithm(s), encryption algorithm(s), compressed/expanded sizes and ratio, creation date, format version, master checksum and validation status. `--depth` parameter (default: shallow/1) controls how deep to inspect nested containers for additional compression/encryption layers. Encrypted containers remain opaque (with warning) unless password is supplied. All reporting available via C FFI functions (e.g. `blip_archive_info()`) so any consumer can access it, not just the CLI.
