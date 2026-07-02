# BLIP Implementation Plan

## In progress: Spec reorg → wire-format identity (2026-07-02)

Resolving "spec bleed" so BLIP owns the **generic wire vocabulary** and blar owns the **archive application**. North star: a compact wire format with a wide gamut of expression types (function calls + args + return values), visible via printable-binary.

- [x] Merge the two varint specs into one — fold `BLIP_SPEC_CONCISE.md`'s Invariants list into `BLIP_SPEC.md`, delete the concise file. (2026-07-02)
- [ ] Curate `BLIP_CONTAINER_SPEC.md` → `BLIP_WIRE_SPEC.md`: keep LP envelope + attribute framework, scalar sentinels, ARRAY/DICT/MAP/DATA/UTF8, SEGMENT, and **COMP/CSUM/ENC as documented *optional* attributes** (off by default; on for TCP/UDP transports — cf. validate_gui). Update code-comment + doc refs.
- [ ] Move archive-specific sections to a new `../blar` spec: FILE, DIR, Archive Format, streaming writes, scratch pool, Merkle directory hashing, tar comparison, archive algorithm defaults (LZMA2/Argon2/codec registry). Cross-repo (reach across).
- [ ] Trim redundant spec prose from README; link to `BLIP_SPEC.md` / `BLIP_WIRE_SPEC.md` instead.
- [ ] THEN: draft the RPC-like expression layer (call = ARRAY[UTF8 name, args…], return = tagged value/sentinel) on top of the wire vocabulary. Unix-socket default (no COMP/CSUM); optional CSUM/COMP/ENC + SEGMENT for TCP/UDP.

## Completed
- [x] `bin/blip` CLI: self-describing byte-order transcoder (LuaJIT, in `bin/` for PATH pickup) — `encode`/`decode` BLIP frames over stdin/stdout; `-b`/`-l` *declare* input order on encode / *require* output order on decode (default big-endian == stream/network order, the normalizing fixpoint); encoder stores payload verbatim + stamps E bit, decoder converts from the frame's stored order; immediate mode for lone bytes <0x80 (avoids sentinel collision); `encode` is the default verb (`… | blip` filters through it; bare interactive `blip` shows help); refuses raw binary to a TTY (suggests xxd/printable-binary); 40 bash CLI tests wired into `./test` + Garnix `checks.default`; luajit added to flake. ~2026-07-02 15:31 EST
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

## Transparent Zip Container Expansion (Completed 2026-03-05)
- [x] src/zip.zig — Pure in-memory zip reader/writer (store + deflate)
- [x] "co"/"zc" metadata keys in mini_blar.zig (container_type, zip_compression_method)
- [x] C FFI: blip_is_zip, blip_zip_entry_count/info/extract, blip_zip_create, blip_archive_entry_container_type/zip_comp
- [x] blar create: PK magic detection, container expansion into DIR+FILE entries
- [x] blar extract: 3-pass container re-assembly (skip container dirs, skip children, re-zip)
- [x] CLI flags: --no-expand-containers, --expand-all-zips
- [x] blar list: 'z' prefix for container dirs; info --json: container_type, zip_compression_method
- [x] poke.zig + json_serde.zig: "co"/"zc" roundtrip support
- [x] Fix: flate decompressor panic (direct mode avoids fixed-capacity window overflow)
- [x] Fix: heap corruption in extraction (child_bufs 2x growth rate vs zip_entries)
- [x] 19 container expansion integration tests (all passing)
- [x] All existing tests still pass (27 blar + 144 compression + Zig unit tests)

## Opt-in fast DICT access (completed 2026-06-01 EST)
- [x] binary-search findKey + sorted-invariant guard (verifyKeysSorted)
- [x] DictIndex accelerator (Zig)
- [x] DictIndex C FFI (blip_dict_index_*) + blip.h
- [x] findKey scaling benchmark (benchDictFindKey)
- [x] spec + docs updated

## Future
- [ ] Arbitrary-width encode/decode (values > u64)
- [ ] Streaming writes with padded BLIPs for containers
- [ ] Cross-language implementations (C, Rust, etc.)
- [ ] Binary data manipulation DSL — extend peek/poke into a full structural editor (insert/delete array elements, add/remove dict keys, splice content, move entries, etc.). Note: JSON interchange (`to-json | jq | from-json`) already covers most high-level manipulation use cases.
- [~] Segmentation container type (SEGMENT, type id 9) — Spec drafted 2026-04-26: BLIP_SPEC.md v1.2 (NIL/TRUE/FALSE scalar sentinels at 0x81 0x7C-0x7E) + BLIP_CONTAINER_SPEC.md v3.0 (SEGMENT type, SEG sigil 0x14, reassembly algorithm with checksum-aware duplicate-M dedup) + docs/transport_embedding.md v1.0 (file naming, optional manifest, header-scan fallback, desktop integration). Implementation: pending, in main blar only (miniblar skips SEGMENT).
- [ ] Per-MIME-type zstd dictionaries — When using zstd with per-file compression: (1) group files by MIME type, (2) train a zstd dictionary per group on the fly, (3) store dictionaries in a MAP container within the archive keyed by MIME type, (4) compress each file with its group's dictionary. Dictionary-level compression gains without solid-archive fragility. If a dictionary is corrupted, only its group's files are lost. Design questions: minimum sample threshold for training (zstd recommends 100+ samples), CLI UX (`-z zstd-dict` vs automatic).
- [ ] Archive metadata inspection (`blar info --depth N`) — Rich metadata reporting at the FFI level, exposed through CLI. Reports: compression algorithm(s), encryption algorithm(s), compressed/expanded sizes and ratio, creation date, format version, master checksum and validation status. `--depth` parameter (default: shallow/1) controls how deep to inspect nested containers for additional compression/encryption layers. Encrypted containers remain opaque (with warning) unless password is supplied. All reporting available via C FFI functions (e.g. `blip_archive_info()`) so any consumer can access it, not just the CLI.
- [x] PDF container expansion — PDFs expanded into shell + JPEG/FlateDecode image streams transcoded to JXL. Content streams decompressed for better LZMA2 compression. Byte-identical reconstruction on extraction.
- [x] JPEG XL lossless image recompression — JPEG (~20% smaller) and PNG (~50% smaller) losslessly transcoded to JXL inside expanded containers. Bit-exact roundtrip via libjxl.
- [ ] Per-file compression progress callback — Currently `serializeFileEntry` passes null for the compression progress callback, so large single-file archives show no progress during the compression phase. Thread the progress function through to `compressContainer` for per-file mode.
- [ ] ISO 9660 container expansion — Decompose ISO images into their constituent filesystem (squashfs, UDF, El Torito boot images). For ISOs with uncompressed or weakly-compressed content, this could improve compression. For already-squashfs ISOs (NixOS, Ubuntu), the gain would be minimal.
- [ ] Cross-platform xattr key mapping — On extraction, translate xattr names to the target OS convention (e.g. macOS `com.apple.quarantine` → Linux `user.com.apple.quarantine`, and reverse on re-archiving). Archive stores original names; mapping is extraction-time only. Handle `system.*` xattrs (may require root on Linux), `security.selinux` (skip with warning on macOS).
- [ ] AppleDouble resource fork fallback — When extracting on non-HFS+/APFS filesystems (Linux, Windows, FAT/exFAT), write macOS resource forks as AppleDouble `._filename` sidecar files. On archiving, detect `._filename` sidecars and slurp them back as resource forks. Default behavior on Windows; optional on Linux (`--apple-double` flag). macOS already creates these on non-native filesystems.
## Container Expansion Roadmap

### Audio lossless transcoding
- [x] WAV → FLAC container expansion — Uncompressed PCM → FLAC lossless via libFLAC (zig-pkgs/flac, lazy dep). Compact WAV metadata stores only non-PCM bytes. Byte-identical WAV reconstruction on extraction. 50-60% savings on realistic audio.
- [x] AIFF → FLAC container expansion — Parse AIFF chunks (big-endian PCM), encode to FLAC via libFLAC. BE/LE conversion for FLAC encoding. Byte-identical roundtrip.

### Image lossless transcoding
- [x] BMP → JXL container expansion — Uncompressed raster → JXL lossless (90%+ savings). Parse BMP header (24/32-bit uncompressed), extract pixels to RGB(A), JXL lossless encode. Store original BMP header as metadata for byte-identical reconstruction.
- [x] TIFF → JXL container expansion — Uncompressed raster → JXL lossless (97%+ savings). Parse TIFF IFDs, extract pixel strips, JXL encode. Compact metadata stores only non-pixel bytes. Byte-identical reconstruction.
- [x] GIF → JXL container expansion — Pure Zig GIF parser (LZW decompression), static GIF → RGBA pixels → JXL lossless. Original GIF stored as metadata for byte-identical reconstruction. Expansion typically skipped by size check since GIF is already compressed; value comes from LZMA2 compression of the JXL+palette. Animated GIF deferred (returns error, treated as opaque file).
- [ ] DNG (Digital Negative) container expansion — Extract embedded JPEG preview (→ JXL transcode), decompress deflate-compressed raw sensor data for better LZMA2 compression, preserve TIFF structure for reconstruction. DNG files are large and common in photography workflows.

### Uncompressed raster formats
- [x] TGA → JXL container expansion — Raw pixels + 18-byte header → JXL lossless. Same pattern as BMP. 24/32-bit uncompressed true-color. Byte-identical roundtrip, ~90% savings.

### Professional/scientific imaging
- [x] DICOM → JXL container expansion — Medical imaging (.dcm). Parse DICOM tags (explicit VR), extract uncompressed pixel data (8/16-bit), JXL lossless encode. Compact metadata stores non-pixel DICOM tags. Byte-identical roundtrip. Encapsulated (JPEG/J2K) DICOM rejected as opaque.
- [x] FITS → JXL container expansion — Astronomy imaging (.fits). 8/16-bit integer pixel arrays + text headers. BE→LE conversion for JXL encoding. Compact metadata stores only header blocks. Byte-identical roundtrip.
- [ ] ICO/CUR → JXL container expansion — Deferred: icon files are typically very small, expansion overhead not justified.
### Archive decomposition
- [x] tar → expand — Decompose tar archives into individual files. Parse 512-byte headers, extract entries as a directory tree. With MIME sorting in solid mode, this lets LZMA2 group similar file types together. Byte-identical reconstruction on extraction.

### Additional ZIP-based formats to detect
- [x] Add all ZIP-based format extensions to codec detection: `.cbz` (comics), `.jar`/`.war`/`.ear` (Java), `.apk`/`.aab` (Android), `.ipa` (iOS), `.xpi` (Firefox), `.crx` (Chrome), `.3mf`/`.amf` (3D printing), `.sketch`, `.ott`/`.ots`/`.otp` (LibreOffice templates)


### Formats using zlib/gzip/deflate internally
- [ ] SWF (Flash) container expansion — Dead format but heavily archived. Contains zlib-compressed streams (shapes, bitmaps, ActionScript bytecode). Decompress streams for better LZMA2 compression. Byte-identical reconstruction.
- [ ] WOFF → decompressed font expansion — Web Open Font Format uses zlib internally. Decompress tables, store glyph outlines for JXL (bitmap fonts) or better LZMA2 (outline fonts). Reconstruct WOFF with original zlib levels.
- [ ] HDF5 container expansion — Hierarchical Data Format (.h5, .hdf5). Ubiquitous in science/ML. Datasets compressed with gzip, szip, or uncompressed. Decompose into individual datasets, re-compress each optimally. Image datasets → JXL.
- [ ] NetCDF container expansion — Climate/weather data (.nc). Internally uses zlib on variables. Decompose variables, JXL for gridded image data, LZMA2 for numeric arrays.
- [ ] MAT container expansion — MATLAB data files (.mat). v5+ uses zlib internally. Decompose variables, JXL for image arrays, LZMA2 for numeric data.
- [ ] ROOT container expansion — CERN particle physics (.root). Uses zlib or LZ4 internally. Decompress TTree branches for better LZMA2 grouping.

### Data engineering formats (Snappy/zlib internally)
- [ ] Parquet container expansion — Columnar data format (.parquet). Uses Snappy, gzip, or LZO per column chunk. Decompress and re-group columns for LZMA2. High value for data archival.
- [ ] Avro container expansion — Row-oriented data (.avro). Uses Snappy or deflate per block. Decompress blocks for LZMA2.
- [ ] ORC container expansion — Columnar format (.orc). Uses zlib or Snappy per stripe. Same approach as Parquet.

### Medical/financial imaging (high-security archival candidates)
- [x] NIfTI container expansion — Neuroimaging (.nii). 8/16-bit 3D voxel arrays + 348-byte header. Voxels flattened to 2D for JXL encoding. Compact metadata stores header only. Byte-identical roundtrip.
- [ ] DNG container expansion — Digital Negative (.dng). TIFF-based with embedded JPEG preview + raw sensor data. Extract JPEG preview → JXL transcode, decompress deflate-compressed raw data for better LZMA2. Photography studios archive large DNG collections.
- [ ] PSD container expansion — Photoshop (.psd). Layer-based format with raw pixel data per layer. Extract layers, JXL-encode each. Professional photography/design archives.
- [ ] MINC container expansion — HDF5-based neuroimaging (.mnc). Decomposes to HDF5 datasets. Medical data subject to privacy regulations.

### Database archival
- [ ] SQLite container expansion — Uncompressed B-tree pages (.sqlite, .db). Decompose into page-level entries for better LZMA2 grouping. Database backups are common archival targets, especially when encrypted for compliance.

## GUI Application Roadmap

### File hierarchy view
- [ ] Navigable file hierarchy — Tree view with expandable/collapsible directories showing archive contents. Right-click "Extract to..." on any directory or file. Hold Command to multi-select items. Drag items out to extract/reconstitute them. Drag items in to add to archive (highlight directories on rollover). Show file sizes, types, container status (expanded/opaque).

### Internationalization
- [ ] Translate GUI to 22 languages (same as ../validate): English, Spanish, French, German, Italian, Portuguese, Dutch, Russian, Chinese (Simplified), Chinese (Traditional), Japanese, Korean, Arabic, Hindi, Turkish, Polish, Czech, Swedish, Norwegian, Danish, Finnish, Thai

## Future
- [ ] macOS bundle container types — Recognize `.app`, `.framework`, `.bundle`, `.plugin`, `.kext` directories as containers with appropriate tags (`"co" -> "app"`, `"co" -> "framework"`, etc.). Preserves bundle structure awareness (code signing, `Info.plist` placement, `_CodeSignature/`) and enables bundle-aware deduplication (shared frameworks across apps).

## Code Review Findings (2026-04-02)

### CRITICAL — Fix Immediately
- [x] C1: `./test` script doesn't run any of the 17 CLI test suites — violates "one command runs everything" rule
- [x] C2: `detectCodec` unit test covers only 5 of 13 formats — missing pdf, tga, tiff, gif, tar, dicom, fits, nifti, wav, aiff
- [x] C3: GIF container expansion test depends on `/tmp/make_test_gif.py` (not in repo) — inline the GIF generation

### HIGH — Fix Soon
- [x] H1: FlateDecode PDF image collapse is a no-op in Zig path (`expansion.zig:796`) — images silently zeroed
- [x] H2: Gzip collapse hardcodes level 6, ignores stored gz_level (`expansion.zig:932`)
- [x] H3: ZIP collapse zeroes all modification timestamps and external_attributes (`expansion.zig:748`)
- [x] H4: O(D×N) Merkle hash computation — nested loop scans all entries per DIR (`mini_blar.zig:789`)
- [x] H5: Same O(D×N) Merkle pattern in streaming path (`streaming.zig:317`)
- [x] H6: O(C×N) child collection in extract Pass 3 (`blar_common.h:1762`)
- [x] H7: Missing `errdefer` on allocations throughout expansion.zig — memory leaks on error paths
- [x] H8: `expandSlot` silently drops entries on OOM — no error reporting (`streaming.zig:64,109,113`)
- [x] H9: 8+ test assertions that always pass (both branches call `pass`) in container_expansion_test.sh
- [x] H10: `set -euo pipefail` in 3 test scripts violates CLAUDE.md rule (compression, encryption, explode)
- [x] H11: ~3,500 lines of dead C code in blar_common.h (old expand_*_container + reconstruction blocks)
- [x] H12: No DICOM container expansion CLI roundtrip test
- [x] H13: No symlink tests anywhere in the test suite

### MEDIUM — Address When Touching Nearby Code
- [x] M1: NIfTI `.expand = NULL` in builtin_codecs (inconsistent, Zig handles it)
- [x] M2: Expanded child entries lose ctime/birthtime/uid/gid/username in streaming (`streaming.zig:92`)
- [x] M3: `--about` flag missing from `blar.c` CLI (required by CLAUDE.md)
- [x] M4: Hardcoded `/tmp/blar_streaming_spill.tmp` — not unique, ignores TMPDIR (`streaming.zig:157`)
- [x] M5 (deferred): 6 format parsers hand-roll readU16LE/readU32LE — replace with `std.mem.readInt` (~60 lines)
- [x] M6: 44 runtime `std.mem.eql` string comparisons — introduce `CodecId` enum with switch dispatch
- [x] M7 (acceptable duplication): Duplicated C→Zig metadata conversion in lib.zig (create_full vs streaming, ~80 lines)
- [x] M8: O(B×E) content ownership transfer after expansion (`blar_common.h:6734`) — use hashset
- [x] M9: CODE_MINIMAP.md missing 23 source files — resolved 2026-07-02 by retiring CODE_MINIMAP.md; per-file index migrated to `dirtree` notes (covers every file, `dirtree orphaned-notes` clean) + a high-level "Repository layout" section in README (fleet standard).
- [x] M10: `bench_helpers.zig` is orphaned (never imported)
- [x] M11: Copy-paste "PDF size" comments in non-PDF functions (`expansion.zig:281,610,684`)
- [x] M12: Flate metadata (predictor/columns/colors/bpc) not propagated from Zig expansion path

### LOW — Nice to Have
- [x] L1: Interlaced GIF unhandled (returns UnsupportedGif error)
- [x] L2: `createArchiveStreamingToFile` mentioned as "(future)" but unimplemented
- [x] L3: No Unicode filename tests
- [x] L4: No streaming + encryption combo test
- [x] L5: `CURRENT_GOALS.md` is stale — consolidate into PLAN.md or remove
- [x] L6: Inconsistent `ArrayList` vs `ArrayListUnmanaged` naming (same type in 0.15)

---

# Project Split: BLIP / blar / mini_blar (2026-05-04)

> **You are the BLIP agent.** Your working directory is `/Users/pmarreck/Documents-CloudManaged/BLIP/` and your remote is `pmarreck/BLIP`. **Execute Phase 1 only.** Phases 2 and 3 are for sibling agents in `/Users/pmarreck/Documents-CloudManaged/blar/` and `/Users/pmarreck/Documents-CloudManaged/mini_blar/` respectively — they're already running independently and will pick up Phase 2/3 once Phase 1 is done and BLIP `v3.0.0` is published.
>
> **For agentic workers:** Use **superpowers:subagent-driven-development** (recommended) or **superpowers:executing-plans** to execute this plan. Steps use checkbox (`- [ ]`) syntax.
>
> **Skip everything above this line.** The historical log is reference only — start reading at this section.
>
> **Phase 1 ends at Task 1.12 (BLIP v3.0.0 tagged and pushed).** Once that's done, your job is finished — Phases 2 and 3 belong to the sibling agents and they're documented here only as context for the overall split.

**Goal:** Split the BLIP umbrella into three independent Zig/C projects: `BLIP` (pure spec + length-prefix encoding + LP envelope + generic containers + SEGMENT + sigil registry), `blar` (the archiver), `mini_blar` (constrained subset of blar). Each becomes a separately-versioned, separately-CI'd, separately-published project with a clean dependency graph.

**Architecture:**

```
   ┌──────────────────┐
   │       BLIP       │  ← spec + libblip.a (+ blip-bench, blip-benchmark)
   │ (pmarreck/BLIP)  │     varint, LP envelope, generic containers,
   └──────────────────┘     SEGMENT, sigil registry, scalar sentinels
            ▲
       depends on
            │
   ┌────────┴────────────────────┐
   │                             │
   ▼                             ▼
┌──────────────────┐    ┌──────────────────────┐
│       blar       │    │      mini_blar       │
│ (pmarreck/blar)  │    │ (pmarreck/mini_blar) │
│  archive format, │    │  constrained subset  │
│  CLI, GUI, codec │    │  for embedded use    │
│  expansion       │    │                      │
└──────────────────┘    └──────────────────────┘

         (sister projects — no impl-level dependency between them)
```

`printable_binary` (already separate) stays a dep of `blar` only — it's used by `blar text`/`from-text` for human-readable archive dumps.

**Tech stack:** Zig 0.15.2, C (CLI), Nix flakes, Garnix CI, build.zig.zon for Zig-package fetching.

---

## Pre-flight context (for fresh-Claude)

**Project conventions (from CLAUDE.md):**
- Main branch is **`yolo`** across all repos. Never assume `main`/`master`.
- TDD-strict: failing test first, run it, confirm it fails, then minimal impl, rerun, confirm pass.
- `./test` runs the full suite (Zig unit + CLI integration). `./build` builds via `nix build`. `./bm` runs benchmarks.
- Use `codescan` MCP tools (`mcp__codescan__read_file`, `mcp__codescan__search`, `mcp__codescan__replace_lines`) for code work; fall back to `Read`/`Bash`/`grep` only for non-indexed operations.
- Tabs over spaces. `#!/usr/bin/env <interp>` for scripts.
- **Never** use `set -euo pipefail` in test scripts (only `set -u`).
- Commit messages: no "Generated with Claude Code" / "Co-Authored-By" attribution.
- Garnix CI is org-wide. Just having `flake.nix` with `packages` and `checks` defined enables it. No per-repo config.
- Use `nix develop -c zig build test` for tests (not bare `zig build test` — the bundled libSystem stubs break on macOS 26.x).

**Today's BLIP layout (the `BLIP/` repo before this split):**
```
BLIP/
├── flake.nix            # Nix dev shell + packages + checks
├── build.zig            # Zig build entry point
├── build.zig.zon        # Zig package manifest
├── BLIP_SPEC.md         # Varint spec
├── BLIP_SPEC_CONCISE.md # Hand-off-to-an-LLM concise variant
├── BLIP_CONTAINER_SPEC.md  # LP envelope + container types + sigils
├── docs/
│   └── transport_embedding.md  # SEGMENT disk-files convention
├── src/
│   ├── blip.zig                # ← BLIP-side: varint encode/decode
│   ├── blip.h                  # ← BLIP-side: C FFI header
│   ├── lib.zig                 # ← MIXED: BLIP + archive FFI exports
│   ├── container_types.zig     # ← BLIP-side: sigils, types, checksum IDs
│   ├── container.zig           # ← BLIP-side: LP envelope mechanic
│   ├── checksum.zig            # ← BLIP-side
│   ├── leaf.zig                # ← BLIP-side: UTF8/DATA containers
│   ├── array.zig               # ← BLIP-side
│   ├── dict.zig                # ← MIXED: DICT generic + FILE/DIR archive
│   ├── peek.zig                # ← BLIP-side: navigation
│   ├── poke.zig                # ← BLIP-side: mutation
│   ├── segmentation.zig        # ← BLIP-side: SEGMENT transport
│   ├── benchmark.zig           # ← BLIP-side: blip-benchmark binary
│   ├── main.zig                # ← BLIP-side: blip-bench binary
│   ├── encoding.zig            # ← BLIP-side: comparison varint interface
│   ├── leb128.zig              # ← BLIP-side
│   ├── protobuf_varint.zig     # ← BLIP-side
│   ├── asn1_length.zig         # ← BLIP-side
│   ├── prefix_varint.zig       # ← BLIP-side
│   ├── sqlite_varint.zig       # ← BLIP-side
│   ├── bignum.zig              # ← BLIP-side
│   ├── fuzz.zig                # ← BLIP-side
│   ├── mini_blar.zig           # ← MOVES TO mini_blar
│   ├── streaming.zig           # ← MOVES TO blar
│   ├── expansion.zig           # ← MOVES TO blar
│   ├── blar.c                  # ← MOVES TO blar
│   ├── blar_common.h           # ← MOVES TO blar (mini_blar gets a copy)
│   ├── miniblar.c              # ← MOVES TO mini_blar
│   ├── jxl.zig, flac.zig, pdf.zig, png.zig, bmp.zig, tar.zig, tiff.zig, gif.zig, tga.zig, wav.zig, aiff.zig, fits.zig, dicom.zig, nifti.zig, zip.zig
│   │                             ← ALL MOVE TO blar (codec expansion)
│   └── ...
├── tests/
│   ├── blip CLI tests          # ← BLIP-side
│   ├── blar_test.sh            # ← MOVES TO blar
│   ├── blar_full_test.sh       # ← MOVES TO blar
│   ├── miniblar_test.sh        # ← MOVES TO mini_blar
│   ├── segmentation_test.sh    # ← STAYS WITH BLIP (tests SEGMENT)
│   │                             AND MOVES TO blar (tests blar segment/join)
│   ├── compression_test.sh     # ← MOVES TO blar
│   ├── encryption_test.sh      # ← MOVES TO blar
│   ├── container_expansion_test.sh, pdf_container_test.sh, png_container_test.sh
│   │                             ← ALL MOVE TO blar
│   ├── streaming_test.sh       # ← MOVES TO blar
│   ├── peek_test.sh, poke_test.sh, json_test.sh, text_roundtrip_test.sh
│   │                             ← STAY WITH BLIP (test BLIP-side primitives)
│   └── ...
├── macos-app/                  # ← MOVES TO blar
└── inbox/                      # ← STAYS WITH BLIP (project meta-comms)
```

**The Layer 5 segmentation work (recently shipped):**

- BLIP-side: `src/segmentation.zig` (parser/serializer/reassembler), FFI exports `blip_segment_chunk`/`reassemble`/`is_segment`/`header`/`array_free` in `src/lib.zig`, declarations in `src/blip.h`, error codes -50..-54.
- blar-side: `cmd_segment`/`cmd_join`/`cmd_create --segment-size` in `src/blar.c`, `tests/segmentation_test.sh`, `--manifest` flag emitting `archive.blar.SUMS`.
- Spec: `BLIP_CONTAINER_SPEC.md §Segmentation`, `docs/transport_embedding.md` — both stay with BLIP since SEGMENT is a BLIP-level container type.

**The recent BLIP perf work:**
- Commit `156cbf2` on yolo: replaced byte-by-byte loops in `encodeEndian` and `decode` with single u64 store/load + branchless shift-shift mask. 42-47% speedup on L=8 paths. Stays with BLIP.

**Completed inbox notes that drove this split:**
- `inbox/2026-04-22-fix-fsck-duplicateEntries.md` — git fsck cleanup (done)
- `inbox/2026-04-24-add-segment-container-type.md` — SEGMENT proposal (implemented as Layer 5)
- `inbox/2026-05-04-project-split-blip-blar-mini-blar.md` — **this split, validate's request**

---

## Phase 0: Plan exists

- [x] **Step 0.1: PLAN.md committed**

This document. No further action needed for Phase 0.

---

## Phase 1: BLIP carve-out (sequential — must finish before Phases 2 and 3)

**Goal:** the existing `pmarreck/BLIP` repo (this repo, on yolo branch) gets trimmed down to only the BLIP-the-spec content. Tag `v3.0.0` when green.

### Task 1.1: Copy the entire repo to sibling locations as starting points for the new repos

**Why:** preserves full history in all three repos. Validates the "we were once unified" provenance.

**Files:**
- Create: `/Users/pmarreck/Documents-CloudManaged/blar/` (full copy of BLIP/)
- Create: `/Users/pmarreck/Documents-CloudManaged/mini_blar/` (full copy of BLIP/)

- [ ] **Step 1: Copy the BLIP tree to blar and mini_blar siblings**

```bash
cd /Users/pmarreck/Documents-CloudManaged
cp -a BLIP blar
cp -a BLIP mini_blar
ls -d BLIP blar mini_blar
```

Expected: three directories listed, each containing the full tree including `.git`.

- [ ] **Step 2: Verify the copies have the same git HEAD**

```bash
for d in BLIP blar mini_blar; do
  echo "=== $d ==="
  (cd /Users/pmarreck/Documents-CloudManaged/$d && git log -1 --oneline)
done
```

Expected: all three on commit `156cbf2 perf(blip): replace byte-by-byte loops...` (or whatever the latest yolo commit is at split-time).

- [ ] **Step 3: No commit — these are working copies**

Do NOT commit anything yet. Phase 1 keeps editing the BLIP repo only; blar and mini_blar are dormant copies until Phases 2 and 3.

### Task 1.2: Identify exactly what stays in BLIP

**Files (no moves yet — just classification):**

- [ ] **Step 1: Write the inventory file**

Create `/Users/pmarreck/Documents-CloudManaged/BLIP/SPLIT_INVENTORY.md` (temporary, deleted at end of Phase 1):

```markdown
# BLIP Split Inventory (temporary, delete after Phase 1)

## STAYS in BLIP

### Source (src/)
- blip.zig                  # varint encode/decode
- container_types.zig       # sigils, type IDs, checksum IDs, encryption IDs
- container.zig             # LP envelope mechanic
- checksum.zig              # CRC32, xxHash64, BLAKE3-128
- leaf.zig                  # UTF8 + DATA containers
- array.zig                 # ARRAY container
- dict.zig                  # DICT only (split out FILE/DIR — see Task 1.5)
- peek.zig                  # navigation
- poke.zig                  # mutation
- segmentation.zig          # SEGMENT
- encoding.zig              # comparison-varint interface (benchmarks only)
- leb128.zig                # comparison
- protobuf_varint.zig       # comparison
- asn1_length.zig           # comparison
- prefix_varint.zig         # comparison
- sqlite_varint.zig         # comparison
- bignum.zig                # comparison
- fuzz.zig                  # fuzz tests
- benchmark.zig             # blip-benchmark binary
- main.zig                  # blip-bench binary (FFI smoke test)
- lib.zig                   # KEEP only the BLIP-side FFI exports (see Task 1.4)
- blip.h                    # KEEP only the BLIP-side declarations

### Specs
- BLIP_SPEC.md              # varint
- BLIP_SPEC_CONCISE.md      # varint, hand-off
- BLIP_CONTAINER_SPEC.md    # LP envelope + container types + sigils + scalar sentinels
- docs/transport_embedding.md  # SEGMENT disk-files convention

### Tests (tests/)
- peek_test.sh              # tests BLIP peek navigation
- poke_test.sh              # tests BLIP poke mutation
- segmentation_test.sh      # KEEP only the segment-arbitrary-bytes tests (drop the create/list/extract-on-segment tests — those move to blar)
  ↳ Will need a Phase 1 split: see Task 1.6
- text_roundtrip_test.sh    # tests BLIP text format
- json_test.sh              # tests BLIP JSON conversion
- binary_format_test.sh     # tests BLIP binary roundtrip
- tri_representation_test.sh # tests BLIP <-> JSON <-> text triangle

### Build
- flake.nix                 # trim to BLIP-only inputs/outputs
- build.zig                 # trim to BLIP-only artifacts
- build.zig.zon             # trim deps
- ./build, ./test, ./bm     # entry-point scripts (trim)

### Meta
- README.md, CLAUDE.md, AGENTS.md, RULES.md, PROJECT_OVERVIEW.md, CODE_MINIMAP.md
- LICENSE
- inbox/                    # project comms

## MOVES OUT of BLIP

(See Task 1.3 for the move list.)
```

- [ ] **Step 2: Verify the inventory is complete**

```bash
cd /Users/pmarreck/Documents-CloudManaged/BLIP
ls src/ tests/ | sort > /tmp/all_files.txt
grep -E "^- (src/|tests/)" SPLIT_INVENTORY.md | sed 's/^- //' | sort > /tmp/classified.txt
diff /tmp/all_files.txt /tmp/classified.txt
```

Expected: any unclassified file should appear in the diff. Add it to either STAYS or MOVES OUT before proceeding.

- [ ] **Step 3: Commit the inventory (will be deleted at end of Phase 1)**

```bash
git add SPLIT_INVENTORY.md
git commit -m "chore: add temporary split inventory for project carve-out"
```

### Task 1.3: Move out the archive-and-codec source files

**Files:**
- Delete (from `pmarreck/BLIP` only — the files persist in the blar/ and mini_blar/ working copies):
  - `src/mini_blar.zig`, `src/streaming.zig`, `src/expansion.zig`
  - `src/blar.c`, `src/blar_common.h`, `src/miniblar.c`
  - `src/jxl.zig`, `src/flac.zig`, `src/pdf.zig`, `src/png.zig`, `src/bmp.zig`, `src/tar.zig`, `src/tiff.zig`, `src/gif.zig`, `src/tga.zig`, `src/wav.zig`, `src/aiff.zig`, `src/fits.zig`, `src/dicom.zig`, `src/nifti.zig`, `src/zip.zig`
  - `macos-app/`
  - `tests/blar_test.sh`, `tests/blar_full_test.sh`, `tests/miniblar_test.sh`
  - `tests/compression_test.sh`, `tests/encryption_test.sh`
  - `tests/container_expansion_test.sh`, `tests/container_expansion_dual_test.sh`
  - `tests/pdf_container_test.sh`, `tests/png_container_test.sh`
  - `tests/streaming_test.sh`, `tests/explode_implode_test.sh`

- [ ] **Step 1: Verify the deletion list against the inventory**

```bash
cd /Users/pmarreck/Documents-CloudManaged/BLIP
cat SPLIT_INVENTORY.md | grep -A 100 "MOVES OUT"
```

Cross-check the lines above match what's in the inventory. If anything is missing, update the inventory first.

- [ ] **Step 2: Delete the files (atomically, in one commit)**

```bash
cd /Users/pmarreck/Documents-CloudManaged/BLIP
git rm -r src/mini_blar.zig src/streaming.zig src/expansion.zig \
         src/blar.c src/blar_common.h src/miniblar.c \
         src/jxl.zig src/flac.zig src/pdf.zig src/png.zig src/bmp.zig \
         src/tar.zig src/tiff.zig src/gif.zig src/tga.zig src/wav.zig \
         src/aiff.zig src/fits.zig src/dicom.zig src/nifti.zig src/zip.zig \
         macos-app \
         tests/blar_test.sh tests/blar_full_test.sh tests/miniblar_test.sh \
         tests/compression_test.sh tests/encryption_test.sh \
         tests/container_expansion_test.sh tests/container_expansion_dual_test.sh \
         tests/pdf_container_test.sh tests/png_container_test.sh \
         tests/streaming_test.sh tests/explode_implode_test.sh
```

- [ ] **Step 3: Verify the BLIP-side files still exist**

```bash
ls src/blip.zig src/container_types.zig src/container.zig src/segmentation.zig \
   src/peek.zig src/poke.zig src/leaf.zig src/array.zig src/dict.zig src/checksum.zig \
   src/lib.zig src/blip.h
```

Expected: all listed files still present.

- [ ] **Step 4: Commit the bulk deletion**

```bash
git commit -m "chore(split): remove blar/mini_blar/codec sources from BLIP

Phase 1 of the BLIP/blar/mini_blar split.  These files persist in the
sibling working copies at ../blar/ and ../mini_blar/ which become their
own repos in Phases 2 and 3."
```

### Task 1.4: Trim `src/lib.zig` to BLIP-only FFI exports

**Files:**
- Modify: `src/lib.zig` (remove archive-side exports, keep BLIP-side only)
- Modify: `src/blip.h` (matching declaration removal)

**Exports to KEEP (BLIP-side):**
```
blip_encode, blip_decode, blip_is_sentinel, blip_encoded_size
blip_error_string
blip_normalize_path
blip_peek, blip_container_count, blip_container_hash, blip_container_key_at
blip_peek_display, blip_poke
blip_decode_printable_binary, blip_encode_printable_binary  ← STAYS in BLIP if printable_binary is a BLIP dep; otherwise MOVES
                                                              See Task 1.4a below.
blip_to_json, blip_from_json
blip_is_compressed, blip_is_encrypted               ← KEEP (these check the LP envelope COMP/ENC attrs)
blip_compress_container, blip_decompress_container  ← KEEP (LP envelope-level COMP)
blip_encrypt_container, blip_decrypt_container      ← KEEP (LP envelope-level ENC)
blip_segment_chunk, blip_segment_array_free, blip_segment_reassemble
blip_segment_is_segment, blip_segment_header
blip_xxhash64
blip_free, blip_free_content, blip_free_xattrs
```

**Exports to REMOVE (archive-side, moves to blar):**
```
blip_archive_create, blip_archive_create_full, blip_archive_create_streaming
blip_archive_file_count, blip_archive_verify, blip_archive_file_path
blip_archive_file_content, blip_archive_file_content_by_path
blip_archive_file_verify, blip_archive_verify_merkle
blip_archive_entry_type, blip_archive_entry_metadata, blip_archive_entry_metadata_full
blip_archive_entry_xattrs, blip_archive_entry_container_type
blip_archive_entry_zip_comp
blip_archive_entry_pdf_offset, blip_archive_entry_pdf_length, blip_archive_entry_jxl_source
blip_zip_*                # all ZIP exports
blip_pdf_*                # all PDF exports
blip_is_pdf, blip_is_zip
blip_expand_file, blip_collapse_container
blip_is_wav, blip_wav_to_flac, blip_flac_to_wav
blip_is_aiff, blip_aiff_to_flac, blip_flac_to_aiff
blip_is_fits, blip_fits_parse
blip_is_nifti
blip_is_dicom, blip_dicom_parse
blip_detect_codec
blip_zlib_decompress, blip_zlib_compress
blip_gz_decompress, blip_gz_compress, blip_gz_compress_level, blip_gz_guess_level, blip_is_gz
```

- [ ] **Step 1: Audit `lib.zig` for KEEP/REMOVE classification**

```bash
cd /Users/pmarreck/Documents-CloudManaged/BLIP
grep -n "^export fn" src/lib.zig | wc -l
grep -n "^export fn" src/lib.zig
```

Compare each export against the KEEP/REMOVE lists above. If any export isn't in either list, classify it before continuing.

- [ ] **Step 2: Remove the archive-side exports from `src/lib.zig`**

For each function in the REMOVE list above:
1. Find its definition (`grep -n "^export fn <name>"`)
2. Find the closing `}` (next un-indented `}` after the open brace).
3. Delete the function body and any preceding doc comment block.

Use `mcp__codescan__replace_lines` for each. Verify each deletion compiles before the next:
```bash
nix develop -c zig build 2>&1 | grep -E "error:" | grep -v "Unrecognized C flag" | head
```

If errors mention undefined symbols (e.g., `mini_blar`, `expansion_mod`), those imports also need removal. The transitive dep set to remove: `mini_blar_mod`, `expansion_mod`, `streaming_mod`, `zip_mod`, `pdf_mod`, all codec-specific mods (`png_mod`, `flac_mod`, etc.).

- [ ] **Step 3: Remove matching declarations from `src/blip.h`**

For each removed FFI export, also remove its declaration from `src/blip.h`. Use `grep -n "<name>" src/blip.h` to find each.

- [ ] **Step 4: Verify the build still passes**

```bash
nix develop -c zig build -Doptimize=ReleaseFast 2>&1 | tail -3
nix develop -c zig build test --summary all 2>&1 | grep -E "Build Summary|tests passed"
```

Expected: build success; only the BLIP-side tests should remain (estimate ~500-700 of the original 841 tests).

- [ ] **Step 5: Commit**

```bash
git add src/lib.zig src/blip.h
git commit -m "chore(split): remove archive-side FFI exports from BLIP lib

Keeps only varint, LP envelope, generic container, peek/poke,
SEGMENT, and BLIP-level COMP/ENC operations.  The archive-side
FFI moves to the new blar repo in Phase 2."
```

### Task 1.4a: Resolve `printable_binary` placement

**Decision needed:** does BLIP's `blip_encode_printable_binary` / `blip_decode_printable_binary` stay in BLIP, or move to blar?

**Options:**
- (a) Keep in BLIP — printable_binary becomes a BLIP build dep. BLIP's `to-json` and `from-json` already use printable_binary for binary-byte escaping in JSON output.
- (b) Move to blar — BLIP loses the printable-binary FFI; blar gains it for `blar text`/`from-text`.

**Recommendation:** (a). BLIP's JSON conversion already depends on printable_binary, and the dep is tiny. Keeping it makes BLIP's JSON facility self-contained.

- [ ] **Step 1: Confirm printable_binary stays as a BLIP dep**

Inspect `build.zig` and `flake.nix` for the `printable_binary` import. It should remain. No code change needed if (a).

- [ ] **Step 2: If decision was (b)**, remove the printable_binary FFI exports from `lib.zig` and `blip.h`, and remove printable_binary from BLIP's `build.zig`/`flake.nix`. (Skip this step if (a).)

### Task 1.5: Split FILE/DIR out of `src/dict.zig`

**Why:** `dict.zig` currently hosts both the generic DICT container and the FILE/DIR archive-specific types. The generic DICT belongs in BLIP; FILE/DIR are blar concerns.

**Files:**
- Modify: `src/dict.zig` — remove FILE/DIR-specific code, keep generic DICT
- (FILE/DIR code stays in the `blar` working copy at `../blar/src/dict.zig` for now; it'll be reorganized in Phase 2.)

- [ ] **Step 1: Identify FILE/DIR-specific code in dict.zig**

```bash
grep -n "FILE\|DIR\|file_entry\|dir_entry\|merkleHash\|computeMerkle" src/dict.zig | head -40
```

- [ ] **Step 2: Read the file and tag each function as DICT-generic or FILE/DIR-specific**

Use `mcp__codescan__symbols` and `mcp__codescan__read_file` to inspect. Classify each function. Generic (stays): `serializeDict`, `parseDict`, `DictReader`, `DictBuilder`. Archive-specific (moves): anything taking a `FileEntry` or `DirEntry`, `serializeFileEntry`, `serializeDirEntry`, `computeMerkleHash`.

- [ ] **Step 3: Remove archive-specific code from BLIP's dict.zig**

For each archive-specific symbol, delete it. Verify the file still compiles.

- [ ] **Step 4: Verify tests still pass**

```bash
nix develop -c zig build test --summary all 2>&1 | grep -E "Build Summary|tests passed"
```

If any test fails, it was archive-specific and should be removed too.

- [ ] **Step 5: Commit**

```bash
git add src/dict.zig
git commit -m "chore(split): remove FILE/DIR-specific code from BLIP dict.zig

DICT generic container stays in BLIP.  FILE/DIR (with Merkle hash
and archive metadata) move to blar in Phase 2."
```

### Task 1.6: Split `tests/segmentation_test.sh`

**Why:** the existing 36-test suite mixes BLIP-level segment primitive tests with blar-level CLI tests (create+segment, list/extract on segment files).

**Files:**
- Modify: `tests/segmentation_test.sh` (BLIP version: keep only `blar segment`/`join` on arbitrary files… **wait** — those use `blar` CLI which is moving out)

**Resolution:** the entire `segmentation_test.sh` tests the **CLI**, which moves to blar. BLIP keeps the **Zig unit tests** in `src/segmentation.zig` (already present) which cover the same logic at the FFI/library level.

- [ ] **Step 1: Delete `tests/segmentation_test.sh` from BLIP**

```bash
git rm tests/segmentation_test.sh
```

- [ ] **Step 2: Confirm BLIP's `segmentation.zig` unit tests cover the segment primitive**

```bash
grep -c "^test " src/segmentation.zig
```

Expected: ~21 tests. These are the BLIP-side coverage and stay.

- [ ] **Step 3: Update the master `./test` script**

```bash
cat /Users/pmarreck/Documents-CloudManaged/BLIP/test
```

Remove the line `run_suite "Segmentation Tests" "bash tests/segmentation_test.sh"` if present.

- [ ] **Step 4: Commit**

```bash
git add test tests/
git commit -m "chore(split): remove segmentation_test.sh from BLIP

These tests exercise blar CLI commands (segment/join/create
--segment-size) which move to blar in Phase 2.  BLIP retains
21 Zig unit tests in src/segmentation.zig covering the
SEGMENT primitive at the FFI level."
```

### Task 1.7: Trim `build.zig` to BLIP-only artifacts

**Files:**
- Modify: `build.zig` — remove the `blar`, `miniblar`, `printable-binary` (if (b)) executable targets

**Targets to KEEP:**
- `blip` static library (libblip.a)
- `blip-benchmark` (Zig-direct benchmark binary)
- `blip-bench` (FFI smoke-test binary, optional — could drop)
- Tests (zig build test)

**Targets to REMOVE:**
- `blar` (the C CLI)
- `miniblar`
- macos-app integration steps
- libmagic dependency (used by blar's solid-mode MIME sort)
- libjxl, jxl_threads, libz, flac C library deps (used by codec expansion in blar)

- [ ] **Step 1: Inspect current build.zig**

```bash
grep -n "addExecutable\|addLibrary\|linkSystemLibrary\|addStaticLibrary" build.zig | head -30
```

- [ ] **Step 2: Remove archive-side targets**

Use `mcp__codescan__replace_lines` to remove the `blar = b.addExecutable(.{...})` block, `miniblar = ...` block, macOS GUI integration steps, and the `libmagic_dep` / `progrez_dep` blocks if they're only used by blar.

- [ ] **Step 3: Remove archive-side system library links from `static_lib`**

Remove `static_lib.root_module.linkSystemLibrary("jxl", .{})`, `linkSystemLibrary("jxl_threads", .{})`, `linkSystemLibrary("z", .{})`, the FLAC support call, etc. These are codec deps, not BLIP deps.

- [ ] **Step 4: Verify the build**

```bash
nix develop -c zig build -Doptimize=ReleaseFast 2>&1 | tail -3
ls zig-out/bin/
```

Expected: `zig-out/bin/blip-bench` and `zig-out/bin/blip-benchmark` only. No `blar`, no `miniblar`.

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "chore(split): trim build.zig to BLIP-only artifacts"
```

### Task 1.8: Trim `flake.nix` to BLIP-only outputs

**Files:**
- Modify: `flake.nix` — remove archive-side packages, codec deps

- [ ] **Step 1: Inspect**

```bash
grep -n "package\|jxl\|flac\|libmagic\|libjpeg" flake.nix | head -20
```

- [ ] **Step 2: Remove archive-side package outputs and dep inputs**

The BLIP flake should expose:
- `packages.<system>.default` = libblip + blip-benchmark + blip-bench
- `checks.<system>.test` = the Zig unit test suite + any BLIP-side CLI tests
- Inputs: just nixpkgs + zig package

Remove inputs/outputs related to: libjxl (and the override for libjpeg-turbo), libflac, libmagic.

- [ ] **Step 3: Verify the flake builds**

```bash
nix build .#default 2>&1 | tail -3
nix flake check 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add flake.nix flake.lock
git commit -m "chore(split): trim flake.nix to BLIP-only outputs"
```

### Task 1.9: Update README.md, CLAUDE.md, PROJECT_OVERVIEW.md, CODE_MINIMAP.md

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `PROJECT_OVERVIEW.md`, `CODE_MINIMAP.md`

- [ ] **Step 1: README.md**

Rewrite the project description as "BLIP: a self-describing variable-length integer encoding + LP envelope + generic container format" — drop archive references. Add "see [blar](https://github.com/pmarreck/blar) for the archive format and [mini_blar](https://github.com/pmarreck/mini_blar) for the constrained subset" cross-references.

- [ ] **Step 2: CLAUDE.md**

Trim the "Project-specific" sections to BLIP-only context. Drop archive/codec references.

- [ ] **Step 3: PROJECT_OVERVIEW.md**

Rewrite as "BLIP project overview." Define BLIP as: varint + LP envelope + generic containers + SEGMENT + sigil registry. Cross-ref blar and mini_blar as sister projects.

- [ ] **Step 4: CODE_MINIMAP.md**

Regenerate from the trimmed `src/` tree:
```bash
ls src/*.zig src/*.h | sort
```
Document each file's purpose. Drop entries for moved files.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md PROJECT_OVERVIEW.md CODE_MINIMAP.md
git commit -m "docs(split): update top-level docs for BLIP-only scope"
```

### Task 1.10: Add a sigil registry document

**Why:** Per the user's spec, BLIP should have "a specification of proposed semantic assignments for the token space (sigils)" that points to sister projects for the actual semantics.

**Files:**
- Create: `BLIP_SIGIL_REGISTRY.md`

- [ ] **Step 1: Write the registry**

```markdown
# BLIP Sigil Registry

This document lists the currently-allocated BLIP sigils (overlong L=1
encodings) and BLIP Container type IDs, with cross-references to the
sister project that owns each one's semantics.  An implementation that
only understands the BLIP varint MAY ignore any sigil it doesn't
recognize.

## Attribute sigils (0x81 0xNN)

| Sigil | Name | Owner | Purpose |
|-------|------|-------|---------|
| 0x01  | TYPE | BLIP (this spec) | Container type discriminator |
| 0x10  | COMP | BLIP (this spec) | Compression algorithm ID |
| 0x11  | DECOMP_LEN | BLIP (this spec) | Decompressed length hint |
| 0x12  | CSUM | BLIP (this spec) | Per-container checksum |
| 0x13  | ENC | BLIP (this spec) | Encryption parameters |
| 0x14  | SEG | BLIP (this spec) | Segmentation metadata (I, M, N) |
| 0x20  | SIG | reserved | Future signature attribute |
| 0x7C  | TRUE | BLIP (this spec) | Scalar boolean true |
| 0x7D  | FALSE | BLIP (this spec) | Scalar boolean false |
| 0x7E  | NIL | BLIP (this spec) | Scalar null/absent |
| 0x7F  | VAL | BLIP (this spec) | Container value attribute |

## Container type IDs (in TYPE attribute)

| ID | Name | Owner | Purpose |
|----|------|-------|---------|
| 1  | ARRAY | BLIP (this spec) | Ordered sequence with index table |
| 2  | DICT | BLIP (this spec) | Sorted key→value map |
| 3  | UTF8 | BLIP (this spec) | UTF-8 string |
| 4  | DATA | BLIP (this spec) | Raw bytes |
| 5  | FILE | [blar](https://github.com/pmarreck/blar) | File entry (path + content + metadata) |
| 6  | MAP | BLIP (this spec) | Generic map (subtype of DICT, no key sort requirement) |
| 7  | DIR | [blar](https://github.com/pmarreck/blar) | Directory entry with Merkle hash |
| 9  | SEGMENT | BLIP (this spec) | Transport segment for cross-frame reassembly |

IDs 8, 10-127 are reserved for future allocation.

## Allocation policy

New container types or attribute sigils require:
1. A spec document (in the owning project) defining wire format and semantics.
2. An entry in this registry referencing that spec.
3. A reference implementation (test coverage in the owning project).

Sister projects (`blar`, `mini_blar`) MAY define new container types
and request allocations; the BLIP project maintains this registry as
the central source of truth.
```

- [ ] **Step 2: Commit**

```bash
git add BLIP_SIGIL_REGISTRY.md
git commit -m "docs(split): add BLIP sigil registry pointing to sister projects"
```

### Task 1.11: Delete `SPLIT_INVENTORY.md` (cleanup)

- [ ] **Step 1: Remove**

```bash
git rm SPLIT_INVENTORY.md
git commit -m "chore: remove temporary split inventory; Phase 1 complete"
```

### Task 1.12: Final BLIP green-CI check + tag

- [ ] **Step 1: Run all tests**

```bash
nix develop -c zig build test --summary all 2>&1 | grep -E "Build Summary|tests passed"
./test 2>&1 | tail -10
```

Both must show all tests passing.

- [ ] **Step 2: Run benchmarks (sanity check)**

```bash
./bm 2>&1 | tail -20
```

Expected: BLIP throughput numbers in line with the historical baseline (sub-ns for small values, ~0.7-1.0 ns for large with the post-156cbf2 optimization).

- [ ] **Step 3: Push and verify Garnix CI**

```bash
git push origin yolo
sleep 5
curl -s "https://garnix.io/api/badges/pmarreck/BLIP?branch=yolo" | head -1
```

Expected: green build status.

- [ ] **Step 4: Tag**

```bash
git tag v3.0.0
git push origin v3.0.0
```

**Phase 1 complete.** BLIP is now scoped to spec + LP envelope + generic containers + SEGMENT + sigil registry.

---

## Phase 2: blar carve-out (parallelizable with Phase 3 via subagents)

**Goal:** the `/Users/pmarreck/Documents-CloudManaged/blar/` working copy becomes its own repo at `pmarreck/blar`, depending on BLIP via `build.zig.zon` + flake input.

### Task 2.1: Set up blar repo

**Files:**
- Modify: `/Users/pmarreck/Documents-CloudManaged/blar/.git/config` (remote URL)
- Create: `pmarreck/blar` on GitHub

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create pmarreck/blar --public --description "BLAR archive format — built on BLIP" --no-readme
```

- [ ] **Step 2: Set the new remote**

```bash
cd /Users/pmarreck/Documents-CloudManaged/blar
git remote set-url origin git@github.com:pmarreck/blar.git
git branch -M yolo
git push -u origin yolo
```

- [ ] **Step 3: Verify**

```bash
git remote -v
git log -1 --oneline
```

Expected: remote = `pmarreck/blar`, HEAD = the same commit BLIP was on at copy time.

### Task 2.2: Add BLIP as a dep via build.zig.zon

**Files:**
- Modify: `build.zig.zon` (add BLIP dep)
- Modify: `flake.nix` (add BLIP as a flake input)

- [ ] **Step 1: Add BLIP to build.zig.zon**

Inspect the BLIP repo's published tag for its tarball URL:
```bash
gh release view v3.0.0 --repo pmarreck/BLIP --json tarballUrl --jq .tarballUrl
```

Add to `/Users/pmarreck/Documents-CloudManaged/blar/build.zig.zon`:
```zig
.dependencies = .{
    .blip = .{
        .url = "https://github.com/pmarreck/BLIP/archive/refs/tags/v3.0.0.tar.gz",
        .hash = "...",  // see fix-zig-deps-hash skill or set to "" and let Nix tell you
    },
    // ... existing deps
},
```

- [ ] **Step 2: Add BLIP as a Nix flake input**

In `flake.nix` add:
```nix
inputs.blip.url = "github:pmarreck/BLIP/v3.0.0";
inputs.blip.inputs.nixpkgs.follows = "nixpkgs";
```

And expose `blip.packages.${system}.default` as a build input where needed.

- [ ] **Step 3: Update build.zig to consume the BLIP dep**

In `/Users/pmarreck/Documents-CloudManaged/blar/build.zig`, replace the local `blip_module` definition with:
```zig
const blip_dep = b.dependency("blip", .{
    .target = target,
    .optimize = optimize,
});
const blip_module = blip_dep.module("blip");
```

- [ ] **Step 4: Hash the dep**

```bash
cd /Users/pmarreck/Documents-CloudManaged/blar
nix build 2>&1 | tail -10
```

If it complains about hash mismatch, copy the `got: sha256-...` value into `build.zig.zon` and `flake.nix`. (See `fix-zig-deps-hash` skill if it gets fiddly.)

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon build.zig flake.nix flake.lock
git commit -m "chore(split): add BLIP v3.0.0 as external dep"
```

### Task 2.3: Remove the local BLIP source from blar's tree

**Files:**
- Delete from blar repo (these files now come from the BLIP dep):
  - `src/blip.zig`, `src/blip.h`, `src/container_types.zig`, `src/container.zig`
  - `src/checksum.zig`, `src/leaf.zig`, `src/array.zig`, `src/peek.zig`, `src/poke.zig`
  - `src/segmentation.zig`
  - `src/encoding.zig`, `src/leb128.zig`, `src/protobuf_varint.zig`, `src/asn1_length.zig`
  - `src/prefix_varint.zig`, `src/sqlite_varint.zig`, `src/bignum.zig`, `src/fuzz.zig`
  - `src/benchmark.zig`, `src/main.zig` (the blip-* binaries belong with BLIP)
  - `BLIP_SPEC.md`, `BLIP_SPEC_CONCISE.md`, `BLIP_CONTAINER_SPEC.md`, `BLIP_SIGIL_REGISTRY.md`
  - `docs/transport_embedding.md` (BLIP-side; blar references it)
  - `tests/peek_test.sh`, `tests/poke_test.sh`, `tests/json_test.sh`
  - `tests/binary_format_test.sh`, `tests/text_roundtrip_test.sh`, `tests/tri_representation_test.sh`

**Files to KEEP:**
- `src/blar.c`, `src/blar_common.h`
- `src/dict.zig` (the FILE/DIR portion that was split out in Task 1.5; blar keeps this side)
- `src/mini_blar.zig` — wait, this is going to mini_blar repo. blar should re-export from mini_blar OR have its own.

  **Decision needed (or pick recommended):** In the original codebase, mini_blar.zig holds the lightweight archive primitives that BOTH blar and mini_blar use. After the split, three options:
  - (i) blar imports mini_blar as a dep too (so the layering is BLIP → mini_blar → blar). Cleanest if the impl really is shared.
  - (ii) blar keeps its own copy, completely independent of mini_blar's code.
  - (iii) Move the shared lightweight archive primitives back to BLIP's `dict.zig` or a new `archive_primitives.zig`.

  **Recommendation:** (ii). The user's framing was that mini_blar is a *spec* subset, not an *impl* subset. blar gets its own self-contained archive impl. mini_blar gets a smaller self-contained one. They're independent at the code level. This avoids spec/impl coupling between sister projects.

- [ ] **Step 1: Delete the BLIP-side files**

```bash
cd /Users/pmarreck/Documents-CloudManaged/blar
git rm src/blip.zig src/blip.h src/container_types.zig src/container.zig \
       src/checksum.zig src/leaf.zig src/array.zig src/peek.zig src/poke.zig \
       src/segmentation.zig \
       src/encoding.zig src/leb128.zig src/protobuf_varint.zig src/asn1_length.zig \
       src/prefix_varint.zig src/sqlite_varint.zig src/bignum.zig src/fuzz.zig \
       src/benchmark.zig src/main.zig \
       BLIP_SPEC.md BLIP_SPEC_CONCISE.md BLIP_CONTAINER_SPEC.md BLIP_SIGIL_REGISTRY.md \
       docs/transport_embedding.md \
       tests/peek_test.sh tests/poke_test.sh tests/json_test.sh \
       tests/binary_format_test.sh tests/text_roundtrip_test.sh tests/tri_representation_test.sh
```

- [ ] **Step 2: Delete miniblar from blar repo (it's its own project now)**

```bash
git rm src/miniblar.c
# mini_blar.zig stays only if Decision (i) was chosen above; with (ii) recommended:
git rm src/mini_blar.zig
git rm tests/miniblar_test.sh
```

- [ ] **Step 3: Inspect what's left**

```bash
ls src/
ls tests/
```

Expected `src/`: `blar.c`, `blar_common.h`, `dict.zig` (FILE/DIR portion), `streaming.zig`, `expansion.zig`, all the codec-specific `.zig` files (jxl, flac, pdf, png, etc.), `lib.zig` (with archive-side FFI exports only).

Expected `tests/`: `blar_test.sh`, `blar_full_test.sh`, `compression_test.sh`, `encryption_test.sh`, `container_expansion_test.sh`, `pdf_container_test.sh`, `png_container_test.sh`, `streaming_test.sh`, `explode_implode_test.sh`, `segmentation_test.sh`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(split): remove BLIP-side files; blar consumes BLIP via dep"
```

### Task 2.4: Trim blar's `lib.zig` to archive-side FFI only

**Files:**
- Modify: `/Users/pmarreck/Documents-CloudManaged/blar/src/lib.zig`
- Modify: `/Users/pmarreck/Documents-CloudManaged/blar/src/blip.h` (rename → `blar.h`?)

- [ ] **Step 1: Decision: keep `blip.h` filename or rename to `blar.h`?**

The current `blip.h` mixes BLIP-side and blar-side declarations. After the split, blar has its own header. Choices:
- (a) Keep filename `blip.h` (consumers `#include "blip.h"`) — confusing post-split.
- (b) Rename to `blar.h` — cleaner. Consumers `#include "blar.h"`.

**Recommendation:** (b). Rename.

- [ ] **Step 2: Rename**

```bash
cd /Users/pmarreck/Documents-CloudManaged/blar
git mv src/blip.h src/blar.h
sed -i '' 's|"blip\.h"|"blar.h"|g' src/blar.c src/blar_common.h
```

(macOS `sed -i ''`. On Linux use `sed -i`.)

- [ ] **Step 3: Trim `lib.zig` to archive-side exports**

The exports to KEEP (now blar-side):
```
blip_archive_create*, blip_archive_file_*, blip_archive_verify*
blip_archive_entry_*, blip_zip_*, blip_pdf_*
blip_is_pdf, blip_is_zip, blip_is_wav, blip_is_aiff, blip_is_fits
blip_is_dicom, blip_is_nifti, blip_is_gz
blip_expand_file, blip_collapse_container
blip_wav_to_flac, blip_flac_to_wav, blip_aiff_to_flac, blip_flac_to_aiff
blip_fits_parse, blip_dicom_parse
blip_detect_codec
blip_zlib_*, blip_gz_*
```

**Symbol-rename rule (locked in):** every FFI symbol that moves to blar gets its `blip_` prefix replaced with `blar_`.  Symbols that **stay in BLIP** keep their `blip_` prefix.  This makes the prefix tell you which library a function comes from, with no ambiguity.

| Original (BLIP umbrella) | Renamed (blar) |
|---|---|
| `blip_archive_create` | `blar_create` |
| `blip_archive_create_full` | `blar_create_full` |
| `blip_archive_create_streaming` | `blar_create_streaming` |
| `blip_archive_file_count` | `blar_file_count` |
| `blip_archive_file_path` | `blar_file_path` |
| `blip_archive_file_content` | `blar_file_content` |
| `blip_archive_file_content_by_path` | `blar_file_content_by_path` |
| `blip_archive_file_verify` | `blar_file_verify` |
| `blip_archive_verify` | `blar_verify` |
| `blip_archive_verify_merkle` | `blar_verify_merkle` |
| `blip_archive_entry_type` | `blar_entry_type` |
| `blip_archive_entry_metadata` | `blar_entry_metadata` |
| `blip_archive_entry_metadata_full` | `blar_entry_metadata_full` |
| `blip_archive_entry_xattrs` | `blar_entry_xattrs` |
| `blip_archive_entry_container_type` | `blar_entry_container_type` |
| `blip_archive_entry_zip_comp` | `blar_entry_zip_comp` |
| `blip_archive_entry_pdf_offset` | `blar_entry_pdf_offset` |
| `blip_archive_entry_pdf_length` | `blar_entry_pdf_length` |
| `blip_archive_entry_jxl_source` | `blar_entry_jxl_source` |
| `blip_zip_*` (all) | `blar_zip_*` |
| `blip_pdf_*` (all) | `blar_pdf_*` |
| `blip_is_pdf` / `blip_is_zip` | `blar_is_pdf` / `blar_is_zip` |
| `blip_is_wav` / `blip_is_aiff` / `blip_is_fits` / `blip_is_dicom` / `blip_is_nifti` / `blip_is_gz` | `blar_is_*` (each) |
| `blip_expand_file` / `blip_collapse_container` | `blar_expand_file` / `blar_collapse_container` |
| `blip_wav_to_flac` / `blip_flac_to_wav` / `blip_aiff_to_flac` / `blip_flac_to_aiff` | `blar_*` (each) |
| `blip_fits_parse` / `blip_dicom_parse` | `blar_fits_parse` / `blar_dicom_parse` |
| `blip_detect_codec` | `blar_detect_codec` |
| `blip_zlib_decompress` / `blip_zlib_compress` | `blar_zlib_decompress` / `blar_zlib_compress` |
| `blip_gz_decompress` / `blip_gz_compress` / `blip_gz_compress_level` / `blip_gz_guess_level` | `blar_gz_*` (each) |
| `blip_free_xattrs` | `blar_free_xattrs` (xattrs are archive metadata) |
| `blip_archive_*` error string entries in `blip_error_string` | move to a new `blar_error_string` |

**Stays `blip_*`** (now lives in BLIP via the dep, not in blar's lib.zig):
- `blip_encode`, `blip_decode`, `blip_is_sentinel`, `blip_encoded_size`
- `blip_peek`, `blip_poke`, `blip_container_*`, `blip_peek_display`
- `blip_to_json`, `blip_from_json`, `blip_decode_printable_binary`, `blip_encode_printable_binary`
- `blip_is_compressed`, `blip_is_encrypted` (LP envelope-level)
- `blip_compress_container`, `blip_decompress_container` (LP envelope-level COMP)
- `blip_encrypt_container`, `blip_decrypt_container` (LP envelope-level ENC)
- `blip_segment_*` (segmentation primitive)
- `blip_xxhash64`, `blip_normalize_path`
- `blip_free`, `blip_free_content`
- `blip_error_string` (BLIP-only error codes)

- [ ] **Step 3a: Apply the rename across blar's source tree**

```bash
cd /Users/pmarreck/Documents-CloudManaged/blar

# Source files: rename in lib.zig, blar.h (already renamed), blar.c, blar_common.h, every codec .zig
# Use a single sed pass with all the substitutions.
SED_SCRIPT='
s/\bblip_archive_create_full\b/blar_create_full/g
s/\bblip_archive_create_streaming\b/blar_create_streaming/g
s/\bblip_archive_create\b/blar_create/g
s/\bblip_archive_file_count\b/blar_file_count/g
s/\bblip_archive_file_path\b/blar_file_path/g
s/\bblip_archive_file_content_by_path\b/blar_file_content_by_path/g
s/\bblip_archive_file_content\b/blar_file_content/g
s/\bblip_archive_file_verify\b/blar_file_verify/g
s/\bblip_archive_verify_merkle\b/blar_verify_merkle/g
s/\bblip_archive_verify\b/blar_verify/g
s/\bblip_archive_entry_type\b/blar_entry_type/g
s/\bblip_archive_entry_metadata_full\b/blar_entry_metadata_full/g
s/\bblip_archive_entry_metadata\b/blar_entry_metadata/g
s/\bblip_archive_entry_xattrs\b/blar_entry_xattrs/g
s/\bblip_archive_entry_container_type\b/blar_entry_container_type/g
s/\bblip_archive_entry_zip_comp\b/blar_entry_zip_comp/g
s/\bblip_archive_entry_pdf_offset\b/blar_entry_pdf_offset/g
s/\bblip_archive_entry_pdf_length\b/blar_entry_pdf_length/g
s/\bblip_archive_entry_jxl_source\b/blar_entry_jxl_source/g
s/\bblip_zip_/blar_zip_/g
s/\bblip_pdf_/blar_pdf_/g
s/\bblip_is_pdf\b/blar_is_pdf/g
s/\bblip_is_zip\b/blar_is_zip/g
s/\bblip_is_wav\b/blar_is_wav/g
s/\bblip_is_aiff\b/blar_is_aiff/g
s/\bblip_is_fits\b/blar_is_fits/g
s/\bblip_is_dicom\b/blar_is_dicom/g
s/\bblip_is_nifti\b/blar_is_nifti/g
s/\bblip_is_gz\b/blar_is_gz/g
s/\bblip_expand_file\b/blar_expand_file/g
s/\bblip_collapse_container\b/blar_collapse_container/g
s/\bblip_wav_to_flac\b/blar_wav_to_flac/g
s/\bblip_flac_to_wav\b/blar_flac_to_wav/g
s/\bblip_aiff_to_flac\b/blar_aiff_to_flac/g
s/\bblip_flac_to_aiff\b/blar_flac_to_aiff/g
s/\bblip_fits_parse\b/blar_fits_parse/g
s/\bblip_dicom_parse\b/blar_dicom_parse/g
s/\bblip_detect_codec\b/blar_detect_codec/g
s/\bblip_zlib_/blar_zlib_/g
s/\bblip_gz_/blar_gz_/g
s/\bblip_free_xattrs\b/blar_free_xattrs/g
'

# Apply to all relevant source files
find src tests -type f \( -name "*.zig" -o -name "*.c" -o -name "*.h" -o -name "*.sh" \) \
  -exec sed -i '' "$SED_SCRIPT" {} \;

# Verify no stray blip_archive_/blip_zip_/etc. left
grep -rn "blip_archive_\|blip_zip_\|blip_pdf_\|blip_expand_file\|blip_collapse_container" src tests || echo "rename clean"
```

Expected: "rename clean" message.  If any stragglers, add to the sed script and re-run.

- [ ] **Step 3b: Add a `blar_error_string` and remove blar-specific error codes from BLIP**

In `src/lib.zig` (now blar-only), add:
```zig
export fn blar_error_string(error_code: i32) callconv(.c) [*:0]const u8 {
    return switch (error_code) {
        // ZIP, PDF, JXL, encryption, etc. error codes
        ...
    };
}
```

Move all blar-specific cases out of the (now BLIP-resident) `blip_error_string`.  In `src/blar.h`, declare:
```c
const char *blar_error_string(int32_t error_code);
```

Update C callers in `blar.c` to call `blar_error_string` for blar-side error codes and `blip_error_string` for BLIP-side codes.  Or, simpler: have `blar_error_string` fall through to `blip_error_string` for unknown codes.


- [ ] **Step 4: Verify the build**

```bash
nix develop -c zig build -Doptimize=ReleaseFast 2>&1 | tail -5
```

If the build complains about undefined `blip_encode` (etc.) when building `blar.c`, that's because `blar.c` needs to link against libblip. Update `build.zig` to:
```zig
const blip_dep = b.dependency("blip", .{ .target = target, .optimize = optimize });
blar.linkLibrary(blip_dep.artifact("blip"));
blar.addIncludePath(blip_dep.path("src"));  // for blip.h
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(split): rename blip.h to blar.h; trim lib.zig to archive-side"
```

### Task 2.5: Run the test suite, fix any failures, push to CI

- [ ] **Step 1: Run tests**

```bash
nix develop -c zig build test --summary all 2>&1 | grep -E "Build Summary|tests passed|test failed"
./test 2>&1 | tail -10
```

- [ ] **Step 2: Fix any failures**

Likely failures and fixes:
- Missing imports of `blip` module → add `@import("blip")` and ensure `build.zig` adds the import.
- Missing C headers → add `addIncludePath` for the BLIP dep.
- Missing test fixtures (e.g., a sample BLIP-encoded file used by a tests) → copy from BLIP repo or regenerate.

- [ ] **Step 3: Push and verify Garnix**

```bash
git push origin yolo
curl -s "https://garnix.io/api/badges/pmarreck/blar?branch=yolo" | head -1
```

- [ ] **Step 4: Tag**

```bash
git tag v3.0.0
git push origin v3.0.0
```

**Phase 2 complete.**

---

## Phase 3: mini_blar carve-out (parallelizable with Phase 2)

**Goal:** the `/Users/pmarreck/Documents-CloudManaged/mini_blar/` working copy becomes its own repo at `pmarreck/mini_blar`, depending on BLIP via `build.zig.zon` + flake input.

### Task 3.1: Set up mini_blar repo

- [ ] **Step 1: Create GitHub repo**

```bash
gh repo create pmarreck/mini_blar --public --description "Constrained subset of the BLAR archive format — for embedded/bootstrap use" --no-readme
```

- [ ] **Step 2: Set remote**

```bash
cd /Users/pmarreck/Documents-CloudManaged/mini_blar
git remote set-url origin git@github.com:pmarreck/mini_blar.git
git branch -M yolo
git push -u origin yolo
```

### Task 3.2: Add BLIP dep (same shape as Task 2.2)

- [ ] Repeat Task 2.2 steps in `mini_blar/`. Skip the lengthy comments — same mechanic.

### Task 3.3: Remove BLIP-side and blar-side files; keep mini_blar essentials

**Files to KEEP in mini_blar:**
- `src/mini_blar.zig` (the lightweight archive impl)
- `src/miniblar.c` (the C CLI)
- `src/blar_common.h` — copy is fine; the shared utilities (read_file, mkdirp, etc.)
- `tests/miniblar_test.sh`
- `flake.nix`, `build.zig`, `build.zig.zon`, `./build`, `./test`
- `LICENSE`

**Files to DELETE:**
- All BLIP-side files (same list as Task 2.3 Step 1)
- All blar-side files: `src/blar.c`, `src/streaming.zig`, `src/expansion.zig`, all codec `.zig` files, `macos-app/`, all blar-only test scripts (`blar_test.sh`, `blar_full_test.sh`, `segmentation_test.sh`, `compression_test.sh`, `encryption_test.sh`, container_expansion + pdf + png + streaming test scripts).

- [ ] **Step 1: Delete BLIP-side and blar-side files**

```bash
cd /Users/pmarreck/Documents-CloudManaged/mini_blar
git rm src/blip.zig src/blip.h src/container_types.zig src/container.zig \
       src/checksum.zig src/leaf.zig src/array.zig src/dict.zig src/peek.zig src/poke.zig \
       src/segmentation.zig \
       src/encoding.zig src/leb128.zig src/protobuf_varint.zig src/asn1_length.zig \
       src/prefix_varint.zig src/sqlite_varint.zig src/bignum.zig src/fuzz.zig \
       src/benchmark.zig src/main.zig \
       BLIP_SPEC.md BLIP_SPEC_CONCISE.md BLIP_CONTAINER_SPEC.md BLIP_SIGIL_REGISTRY.md \
       docs/transport_embedding.md \
       tests/peek_test.sh tests/poke_test.sh tests/json_test.sh \
       tests/binary_format_test.sh tests/text_roundtrip_test.sh tests/tri_representation_test.sh \
       src/blar.c src/streaming.zig src/expansion.zig src/lib.zig \
       src/jxl.zig src/flac.zig src/pdf.zig src/png.zig src/bmp.zig \
       src/tar.zig src/tiff.zig src/gif.zig src/tga.zig src/wav.zig \
       src/aiff.zig src/fits.zig src/dicom.zig src/nifti.zig src/zip.zig \
       macos-app \
       tests/blar_test.sh tests/blar_full_test.sh tests/segmentation_test.sh \
       tests/compression_test.sh tests/encryption_test.sh \
       tests/container_expansion_test.sh tests/container_expansion_dual_test.sh \
       tests/pdf_container_test.sh tests/png_container_test.sh \
       tests/streaming_test.sh tests/explode_implode_test.sh
```

- [ ] **Step 2: Verify mini_blar's tree is minimal**

```bash
ls src/ tests/
```

Expected:
- `src/`: `mini_blar.zig`, `miniblar.c`, `blar_common.h`
- `tests/`: `miniblar_test.sh`

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore(split): mini_blar gets only the constrained-subset impl"
```

### Task 3.4: Trim mini_blar's `build.zig` to a single binary target

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Reduce to one executable**

```zig
// build.zig (sketch)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    const blip_dep = b.dependency("blip", .{
        .target = target,
        .optimize = optimize,
    });

    const mini_blar = b.addExecutable(.{
        .name = "miniblar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mini_blar.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_dep.module("blip") },
            },
        }),
    });
    mini_blar.linkLibrary(blip_dep.artifact("blip"));
    mini_blar.addIncludePath(blip_dep.path("src"));
    mini_blar.addCSourceFile(.{ .file = b.path("src/miniblar.c") });
    b.installArtifact(mini_blar);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mini_blar.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "blip", .module = blip_dep.module("blip") },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

- [ ] **Step 2: Verify the build**

```bash
nix develop -c zig build -Doptimize=ReleaseFast 2>&1 | tail -3
ls zig-out/bin/
```

Expected: `zig-out/bin/miniblar` only.

- [ ] **Step 3: Run tests**

```bash
nix develop -c zig build test 2>&1 | grep -E "tests passed|failed"
bash tests/miniblar_test.sh 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(split): trim mini_blar build.zig to single binary"
```

### Task 3.5: Update mini_blar docs

- [ ] **Step 1: README.md**

```markdown
# mini_blar

A constrained subset of the [blar](https://github.com/pmarreck/blar) archive format,
suitable for embedded systems, bootstrap environments, and any context where
the full blar feature set (compression, encryption, codec expansion, etc.)
is overkill.

mini_blar archives are valid blar archives — any blar implementation can read
them.  But mini_blar's writer only emits a profile of the format, and its
reader only handles that profile.

Built on [BLIP](https://github.com/pmarreck/BLIP).

## Profile

mini_blar archives:
- May contain FILE and DIR entries
- Use only TYPE, CSUM, VAL attributes (no COMP, ENC, SEG, SIG)
- Use only xxhash64 for content checksums
- Have no compression, no encryption, no container expansion

If you need any of those, use blar.
```

- [ ] **Step 2: PROJECT_OVERVIEW.md (new file)**

Brief description of mini_blar's design and constraints. Cross-ref blar and BLIP.

- [ ] **Step 3: CLAUDE.md**

Update for mini_blar-only context.

- [ ] **Step 4: Commit**

```bash
git add README.md PROJECT_OVERVIEW.md CLAUDE.md
git commit -m "docs(split): mini_blar top-level docs"
```

### Task 3.6: Push and tag

- [ ] **Step 1: Push**

```bash
git push origin yolo
curl -s "https://garnix.io/api/badges/pmarreck/mini_blar?branch=yolo" | head -1
```

- [ ] **Step 2: Tag**

```bash
git tag v3.0.0
git push origin v3.0.0
```

**Phase 3 complete.**

---

## Phase 4: Post-split cleanup (sequential, after Phases 2 and 3)

### Task 4.1: Update consumer-project inbox notes

**Files:**
- Modify: `/Users/pmarreck/Documents-CloudManaged/validate_gui/inbox/...` (any BLIP-referencing notes)
- Modify: `/Users/pmarreck/Documents-CloudManaged/entropy_shield/inbox/...` (the recently-sent SEGMENT v3 reply)

- [ ] **Step 1: Identify which notes reference BLIP umbrella**

```bash
grep -l "BLIP" /Users/pmarreck/Documents-CloudManaged/{validate_gui,entropy_shield}/inbox/*.md 2>/dev/null
```

- [ ] **Step 2: For each one, add a brief disambiguation note**

For example, append to each:
```markdown
> **Note (post-2026-05-04 split):** "BLIP" in this document refers to the
> length-prefix encoding only — see https://github.com/pmarreck/BLIP. The
> archiver is now https://github.com/pmarreck/blar; the constrained subset is
> https://github.com/pmarreck/mini_blar.
```

- [ ] **Step 3: Commit each project separately**

In each consumer project's repo:
```bash
git add inbox/
git commit -m "docs: disambiguate BLIP references after the project split"
git push origin yolo
```

### Task 4.2: Update the blip_mp/ research project to consume BLIP-the-spec

**Files:**
- Modify: `/Users/pmarreck/Documents-CloudManaged/blip_mp/SPEC.md`

- [ ] **Step 1: Update references**

Update SPEC.md's "References" section to point at:
- BLIP varint: `https://github.com/pmarreck/BLIP/blob/yolo/BLIP_SPEC_CONCISE.md`
- BLIP C FFI: `https://github.com/pmarreck/BLIP/blob/yolo/src/blip.h`

(blip_mp doesn't need blar or mini_blar — only the BLIP varint primitives.)

### Task 4.3: Final state verification

- [ ] **Step 1: All three CIs green**

```bash
for repo in BLIP blar mini_blar; do
  echo "=== $repo ==="
  curl -s "https://garnix.io/api/badges/pmarreck/$repo?branch=yolo" | jq -r .message
done
```

Expected: all three report "X builds succeeded."

- [ ] **Step 2: All three tagged at v3.0.0**

```bash
for repo in BLIP blar mini_blar; do
  echo "=== $repo ==="
  gh release view v3.0.0 --repo pmarreck/$repo --json tagName --jq .tagName
done
```

- [ ] **Step 3: Cross-references resolve**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://github.com/pmarreck/BLIP
curl -s -o /dev/null -w "%{http_code}\n" https://github.com/pmarreck/blar
curl -s -o /dev/null -w "%{http_code}\n" https://github.com/pmarreck/mini_blar
```

Expected: all 200.

**Phase 4 complete. Project split done.**

---

## Acceptance criteria (overall)

A successful completion of this plan means:
1. ✅ Three repos exist on GitHub: `pmarreck/BLIP`, `pmarreck/blar`, `pmarreck/mini_blar`
2. ✅ Each repo has its own `flake.nix`, `build.zig`, `./test`, `./build` — fully self-contained build entry points
3. ✅ `blar` and `mini_blar` consume `BLIP` via `build.zig.zon` + flake input (NOT via vendored copies)
4. ✅ Each repo has Garnix CI green on yolo
5. ✅ Each repo tagged `v3.0.0`
6. ✅ All three repos retain shared git history up to the split point
7. ✅ `BLIP/BLIP_SIGIL_REGISTRY.md` cross-references blar/mini_blar for sigil semantics
8. ✅ Consumer-project inbox notes (validate_gui, entropy_shield) updated to disambiguate
9. ✅ blip_mp/SPEC.md references the new BLIP repo
10. ✅ blar's FFI symbols use `blar_*` prefix (not `blip_archive_*`); BLIP's symbols still use `blip_*`. Renaming applied per the table in Task 2.4 Step 3.
11. ✅ blar's C header is `src/blar.h` (renamed from `src/blip.h`); consumers `#include "blar.h"`.

---

## Open questions for the implementing session

- (none currently — every question above has a recommendation. If a recommendation is wrong, push back via Peter.)

---

## Glossary (for fresh-context Claude)

- **BLIP** (post-split): the varint encoding spec + reference implementation + LP envelope + generic containers + SEGMENT + sigil registry. Frozen-ish.
- **blar**: the BLAR archive format, CLI, GUI, and codec expansion. Active development.
- **mini_blar**: a constrained profile of blar's format, plus a separate impl. Embedded use.
- **Sigil**: an "overlong" BLIP encoding with L=1 and value < 128. Reserved bytes 0x81 0xNN.
- **LP envelope**: a BLIP container's wire format — Length + sorted Attributes + payload.
- **Container types**: enum of 0-127 values stored in the TYPE attribute. ARRAY=1, DICT=2, UTF8=3, DATA=4, FILE=5, MAP=6, DIR=7, SEGMENT=9.
- **yolo**: the main branch on every Peter-owned repo. Never call it `main` or `master`.
