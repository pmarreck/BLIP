# BLIP: Byte Length Integer Prefix

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2FBLIP)](https://garnix.io/repo/pmarreck/BLIP)
[![CI](https://github.com/pmarreck/BLIP/actions/workflows/ci.yml/badge.svg)](https://github.com/pmarreck/BLIP/actions/workflows/ci.yml)

A variable-length integer encoding optimized for CPU-friendly decoding of small values, with a built-in sentinel channel for format extensibility.

See [BLIP_SPEC.md](BLIP_SPEC.md) for the full specification.

## Why BLIP?

Existing variable-length integer encodings (LEB128, VLQ, Protocol Buffers varint) pack 7 data bits per byte and require a **branch on every byte** during decoding. BLIP takes a different approach: the first byte(s) is either an immediate value or the start of a varint that tells you how many raw bytes follow, and those bytes are a plain little-endian integer — decoded with a single load instruction, no per-byte branching, no shift-and-OR reassembly.

The trade-off is 1 extra byte for values in the 256-16383 range, which is acceptable in distributions where values cluster around "small" (<128) or "large" (>16383).

## Benchmark Results

Measured on Apple M4 Max, Zig 0.15.2, ReleaseFast. All timings are best-of-3 runs over 1M values per distribution.

### Encode/Decode Throughput (ns/op)

| Encoding | Small enc | Small dec | Medium enc | Medium dec | Large enc | Large dec |
|----------|-----------|-----------|------------|------------|-----------|-----------|
| **BLIP** | **0.2** | 0.3 | 0.6 | 0.7 | **1.3** | **1.3** |
| LEB128 | 0.5 | 0.3 | 1.9 | 2.1 | 5.1 | 4.2 |
| Protobuf | 0.5 | 0.3 | 2.0 | 2.1 | 5.0 | 4.2 |
| ASN.1 | 0.2 | 0.3 | 0.6 | 0.5 | 1.2 | 2.1 |
| PrefixVarint | 0.6 | 0.3 | 2.7 | 2.7 | 2.1 | 0.4 |
| SQLite | 1.0 | 0.2 | 1.7 | 0.7 | 3.4 | 1.4 |

- **Small**: uniform 0-127
- **Medium**: uniform 0-65535
- **Large**: uniform 2^32 - 2^64

BLIP is **4x faster** than LEB128/Protobuf for large value encoding (1.3 vs 5.1 ns/op) because it writes raw LE bytes with a single memcpy instead of shifting and masking 7 bits at a time.

### Bignum Arithmetic (ns/op)

| Encoding | Roundtrip | Direct LE |
|----------|-----------|-----------|
| **BLIP** | 11.0 | **9.4** |
| LEB128 | 13.0 | N/A |
| Protobuf | 11.9 | N/A |
| ASN.1 | 15.2 | N/A |
| PrefixVarint | 7.3 | N/A |
| SQLite | 17.5 | N/A |

BLIP's raw LE payload enables **direct arithmetic on encoded data** without decoding first — just extract the payload bytes, do carry-propagating addition, and re-encode. Other encodings must fully decode to integers, compute, then re-encode.

### Random-Access File Jumping (jumps/sec)

| Encoding | Jumps/sec |
|----------|-----------|
| BLIP | 3,705,075 |
| LEB128 | 3,700,391 |
| Protobuf | 3,603,062 |
| ASN.1 | 3,377,950 |
| PrefixVarint | 3,683,976 |
| SQLite | 3,585,032 |

Following a chain of 10,000 encoded offsets in a sparse file using `pread()`. All encodings perform similarly because the benchmark is I/O-dominated — the decode cost is dwarfed by the syscall overhead. This confirms that BLIP adds no penalty in real-world offset-chasing scenarios.

## Build

Requires [Nix](https://nixos.org/) with flakes enabled. All dependencies (Zig 0.15.2, hyperfine) are provided hermetically.

```bash
./test           # run tests
./build          # build (ReleaseFast)
./build --debug  # build (Debug)
./bm             # run benchmarks
```

Or directly:

```bash
nix develop -c zig build test
nix develop -c zig build -Doptimize=ReleaseFast
nix develop -c zig build bench -Doptimize=ReleaseFast
```

## Container Format (v2 LP)

BLIP also defines a recursive binary container format for archives, dictionaries, and structured data. See [BLIP_CONTAINER_SPEC.md](BLIP_CONTAINER_SPEC.md) for the full specification.

Container types: ARRAY, DICT, MAP, FILE, DIR, DATA, UTF8. Each container uses the LP (Length-Payload) envelope: `[BLIP(total_length)] [sorted attributes] [VAL payload + checksum]`. Attributes include TYPE (container type ID), COMP (compression algorithm), DECOMP_LEN (decompressed length), CSUM (checksum algorithm), and SIG (digital signature). Features include end-of-container index tables for O(1) random access, BLAKE3-128 integrity at the archive level with xxHash64 for inner containers, Merkle hash trees for directories, built-in LZMA2 compression, and canonical key ordering for deterministic output. FILE containers use ARRAY layout with embedded DATA containers for dual-level checksumming. All metadata uses compact 2-character key names.

## C FFI

BLIP is available as a C library. Link against `libblip.a` and include `src/blip.h`:

```c
#include "blip.h"

// Encoding/decoding
uint8_t buf[16];
int32_t n = blip_encode(42, buf, sizeof(buf));    // n = 1, buf = {0x2A}
uint64_t value;
int32_t consumed = blip_decode(buf, n, &value);   // value = 42, consumed = 1

// Archives
blip_file_entry files[] = {
    { "hello.txt", 9, (uint8_t*)"Hello!\n", 7 },
};
uint8_t *archive;
size_t archive_len;
blip_archive_create(files, 1, &archive, &archive_len);
bool ok = blip_archive_verify(archive, archive_len);
blip_free(archive, archive_len);
```

## blar: BLIP Archive Tool

`blar` is a full-featured CLI for creating, inspecting, and extracting BLIP archives — similar to `tar`. It supports directory recursion, metadata preservation (permissions, mtime, owner), and Merkle hash integrity for directory trees.

### Usage

```bash
# Create an archive from a directory tree (recurses automatically)
blar create -o archive.blar myproject/

# Default output name: blar create mydir -> mydir.blar
blar create myproject

# Create from individual files
blar create -o archive.blar file1.txt file2.txt

# List entries (d=directory, -=file)
blar list archive.blar

# Extract all files, restoring directory structure + permissions
blar extract archive.blar -C output_dir/

# Verify integrity (BLAKE3-128 outer + per-file hashes + Merkle hashes)
blar verify archive.blar

# Show metadata (file count, directory count, sizes)
blar info archive.blar

# Print single file to stdout
blar cat archive.blar path/to/file.txt

# Modify a value in the archive
blar poke archive.blar "[1][0][1]" --value "new content"

# Convert archive to JSON (pipe to jq for manipulation)
blar to-json archive.blar | jq '.entries[].path'

# Modify via jq and create new archive
blar to-json a.blar | jq '(.entries[] | select(.path=="hello.txt")).content = "new"' | blar from-json -o b.blar

# Add a file via jq
blar to-json a.blar | jq '.entries += [{"type":"file","path":"new.txt","content":"added"}]' | blar from-json -o b.blar
```

### Tar-style shortcuts (hyphen optional)

```bash
blar cf archive.blar myproject/   # create
blar tf archive.blar              # list
blar xf archive.blar              # extract
blar Vf archive.blar              # verify
blar If archive.blar              # info
blar pf archive.blar file.txt     # cat (print)
blar kf archive.blar "[1][0]"     # peek
blar Kf archive.blar "[1][0][1]"  # poke
blar jf archive.blar              # to-json
blar Jf input.json -o out.blar    # from-json
```

### Inspecting archives (peek)

Navigate BLIP archive structure with jq-like path expressions:

```bash
# Navigation: [N] for array index, [key] for dict key
blar peek archive.blar "[1][0][0][pa]"      # file path
blar peek archive.blar "[1][0][1]" --raw    # raw file content

# Accessors
blar peek archive.blar "[1][0].type"        # FILE
blar peek archive.blar "[1][0].count"       # 2
blar peek archive.blar "[1][0].hash"        # a1b2c3d4e5f6a7b8
blar peek archive.blar "[1][0][0].keys"     # metadata key list

# Output modes
blar peek archive.blar "[1][0][0][md]"          # 0644 (semantic: mode as octal)
blar peek archive.blar "[1][0][0][mt]"          # 2026-02-24T10:30:00.123456789Z
blar peek archive.blar "[1][0][0].keys" --json  # ["bt","ct","gi","gn","md","mt","pa","ui","un"]
blar peek archive.blar "[1][0][1]" --raw        # raw bytes to stdout
blar peek archive.blar "[1][0][1]" --hex        # 0x68656c6c6f (hex-encoded payload)
blar peek archive.blar "[1][0]" --type          # FILE (shorthand for .type)
```

**Output flags:**

- `--raw` — Output raw payload bytes. When stdout is a terminal, data is automatically piped through printable-binary encoding for safety, with a warning on stderr. When piped to a file or another command, raw bytes are emitted directly.
- `--hex` — Output payload bytes as `0x`-prefixed hex string. For leaf containers (UTF8, DATA), shows the payload hex. For aggregate containers (ARRAY, DICT, FILE, DIR), shows the container's checksum as hex.
- `--json` — JSON output. Strings use printable-binary identity check: if the value contains only printable bytes it appears as-is; if it contains non-printable bytes, it is encoded via printable-binary and a warning is emitted on stderr.
- `--type` — Shorthand for the `.type` accessor.

Archive structure: `ARRAY[DATA(magic), ARRAY[FILE[DICT{metadata}, DATA{content}], ...]]`. So `[0]` is the magic, `[1]` is the body array, `[1][0]` is the first file entry, `[1][0][0]` is its metadata dict, and `[1][0][1]` is its content. Known metadata keys (md, mt, ct, bt, ui, gi, xh) get semantic display (octal, ISO 8601, decimal, hex).

`miniblar peek` works identically.

### Modifying archives (poke)

Modify any leaf value in a BLIP archive with automatic hash recomputation:

```bash
# Replace file content via stdin
echo -n "new content" | blar poke archive.blar "[1][0][1]"

# Replace file content with --value flag
blar poke archive.blar "[1][0][1]" --value "hello world"

# Rename a file
blar poke archive.blar "[1][0][0][pa]" --value "renamed.txt"

# Read new value from a file
blar poke archive.blar "[1][0][1]" -i data.bin

# Write to a different file (original unchanged)
blar poke archive.blar "[1][0][1]" --value "x" -o modified.blar

# Create .bak backup before overwriting
blar poke archive.blar "[1][0][1]" --value "x" --backup
```

`poke` is the write counterpart to `peek` — same path syntax, but *sets* values. The entire archive is re-serialized with all hashes, offsets, and index tables recomputed automatically. `miniblar poke` works identically.

## Killer Feature: `peek` — Structural Introspection

Most archive formats are opaque blobs. You can list files, extract files, maybe verify checksums — but the internal structure is invisible. BLIP archives are different: every container, every metadata key, every hash is addressable.

`peek` lets you navigate the binary structure of a BLIP archive the way `jq` lets you navigate JSON. But unlike JSON, BLIP is a typed binary format with integrity guarantees — and peek understands that:

```bash
# What type is this container?
$ blar peek archive.blar "[1][0]" --type
FILE

# What metadata keys does this file have?
$ blar peek archive.blar "[1][0][0].keys"
bt ct gi gn md mt pa ui un

# What is the stored checksum of the archive?
$ blar peek archive.blar ".hash"
a1b2c3d4e5f6a7b8

# Timestamps are displayed as ISO 8601 with nanosecond precision
$ blar peek archive.blar "[1][0][0][mt]"
2026-02-24T10:30:00.123456789Z

# Permissions as octal
$ blar peek archive.blar "[1][0][0][md]"
0755

# Raw file content (terminal-safe via printable-binary)
$ blar peek archive.blar "[1][0][1]" --raw
hello world

# Hex dump of any payload
$ blar peek archive.blar "[1][0][1]" --hex
0x68656c6c6f20776f726c640a
```

This isn't just a debugging tool — it's a **verification tool**. You can extract the stored checksum of any container and independently verify it. You can inspect metadata without extracting. You can trace the Merkle hash tree of a directory archive from leaf to root. No other archive format gives you this level of structural transparency.

**`poke` — the write counterpart to peek.** Same path syntax, but *sets* values. C64 PEEK/POKE for binary archives — read any value, write any value, with automatic hash recomputation across the entire archive. See [Modifying archives](#modifying-archives-poke) above.

### JSON interchange (to-json / from-json)

JSON is the universal interchange format for BLIP archives. Convert any archive to JSON, manipulate it with `jq` (or any tool that speaks JSON), and convert back:

```bash
# List all file paths
blar to-json archive.blar | jq '.entries[].path'

# Change file content
blar to-json a.blar \
  | jq '(.entries[] | select(.path=="hello.txt")).content = "new"' \
  | blar from-json -o b.blar

# Add a file
blar to-json a.blar \
  | jq '.entries += [{"type":"file","path":"new.txt","content":"hello"}]' \
  | blar from-json -o b.blar

# Remove a file
blar to-json a.blar \
  | jq '.entries = [.entries[] | select(.path != "remove-me.txt")]' \
  | blar from-json -o b.blar

# Rename a file
blar to-json a.blar \
  | jq '(.entries[] | select(.path=="old.txt")).path = "new.txt"' \
  | blar from-json -o b.blar

# Change permissions
blar to-json a.blar \
  | jq '(.entries[] | select(.path=="script.sh")).mode = "0755"' \
  | blar from-json -o b.blar
```

Binary content is encoded using printable-binary encoding in JSON strings, which preserves all 256 byte values safely within JSON. All hashes, offsets, and index tables are recomputed automatically on `from-json`.

`miniblar to-json` and `miniblar from-json` work identically.

## BLIP Archive (blar) vs tar

| | BLIP Archive (`blar`) | `tar` (POSIX/GNU/BSD) |
|---|---|---|
| **Determinism** | Byte-identical output guaranteed by spec (canonical key ordering, canonical BLIP encoding, caller-controlled entry order) | Format-dependent — GNU, BSD, and POSIX tar produce different bytes from the same inputs; header fields vary by implementation |
| **Integrity** | Built-in BLAKE3-128 on the outer archive with xxHash64 on inner containers; Merkle hash trees for directories propagate changes from any leaf to the root | None built-in; users layer external checksums (`sha256sum`) or signatures after the fact |
| **Random access** | O(1) via index tables at the end of each container; jump directly to element K without scanning | Sequential scan only — must read every 512-byte header from the beginning to find a file |
| **Per-file overhead** | ~165 bytes (metadata DICT + DATA container + ARRAY index + dual hashes) | 512-byte header + content padded to 512-byte boundary; minimum 1024 bytes per file regardless of content size |
| **Metadata** | Extensible key-value pairs — any key name, any container type as value; applications define what they need | Fixed set defined by the header format (mtime, uid, gid, mode, size, linkname, uname, gname); pax extended headers add flexibility but are complex |
| **Typed values** | First-class types: UTF8, DATA, ARRAY, DICT, MAP, FILE, DIR | Everything is byte ranges within fixed-width header fields; no type system |
| **Nesting** | Recursive — containers nest arbitrarily (ARRAY of DICTs of ARRAYs...) | Flat — one level of file entries; no structured nesting |
| **Path encoding** | UTF-8 only, normalized (no leading `/`, forward slashes, no `.`/`..`) | ASCII (POSIX) or UTF-8 (pax); leading `/` handling varies by implementation; `..` components are a known security risk |
| **Streaming** | Supported via padded BLIPs with backfill; streaming reads ignore the index and process containers sequentially | Native strength — append headers + data sequentially, finalize with two zero blocks |
| **Ecosystem** | New — requires a BLIP-aware tool | Universal — every Unix system has tar; decades of tooling, documentation, and interoperability |
| **Specification** | Single spec, one canonical encoding | Multiple incompatible specs (v7, ustar, pax, GNU, BSD); real-world archives mix formats |
| **Empty directories** | Explicit DIR container type with its own metadata and Merkle hash | Representable but inconsistently handled across implementations |

**Where tar wins:** Ubiquity. tar is everywhere, understood by every tool, and has decades of battle-tested interoperability. If you need an archive that any system can unpack without installing anything, tar is the right choice.

**Where BLIP Archive wins:** Correctness guarantees. Deterministic output means two archives of the same files are byte-identical — useful for caching, deduplication, and content-addressed storage. Built-in BLAKE3-128 integrity verification catches corruption without external tooling. O(1) random access means you can extract one file from a million-file archive without scanning the rest. Built-in LZMA2 compression via the LP attribute system keeps archives compact. And ~3x lower per-file overhead matters when archiving many small files.

## miniblar: Minimal BLIP Archive Tool

`miniblar` is a flat-file archiver that bundles files with their relative paths, content, and file metadata (permissions, timestamps, ownership). No directory entries — files only. The result is a compact bag of files with full metadata preservation. Entry order is caller-controlled (the CLI sorts by path; the Zig API preserves the order given).

### Use cases

- **Hashing a set of files together.** Deterministic encoding (canonical BLIP encoding, caller-controlled entry order) produces a stable archive hash. Any change to file contents OR metadata (permissions, mtime) changes the archive hash — useful for cache invalidation.
- **Lightweight bundles with metadata.** Ship files as a single blob with permissions and timestamps preserved. Extracted files retain their original mode and mtime.
- **Integrity-verified file sets.** Each file has dual checksums: a DATA hash for content-only integrity and a FILE ARRAY hash covering content + metadata.
- **Embedding in other formats.** Compact overhead (~165 bytes per file with metadata, no 512-byte block padding) keeps the archive small when used as a payload inside another container.

### Usage

```bash
# Create archive from files (directories rejected)
miniblar create -o bundle.mblar file1.txt file2.txt

# Default extension is .mblar
miniblar create file1.txt file2.txt   # -> file1.mblar

# Same subcommands as blar: list, extract, verify, info, cat
miniblar list bundle.mblar
miniblar verify bundle.mblar

# Tar-style shortcuts work too
miniblar cf bundle.mblar file1.txt
miniblar tf bundle.mblar
```

`miniblar` rejects directory arguments — use `blar` for directory trees and Merkle hashing.

### Zig API

The `mini_blar` module provides a high-level API for creating and reading BLIP archives:

```zig
const mini_blar = @import("mini_blar.zig");

// Create an archive
const files = [_]mini_blar.FileEntry{
    .{ .path = "hello.txt", .content = "Hello, world!\n" },
    .{ .path = "src/main.zig", .content = source_bytes, .mode = 0o644, .mtime_ns = 1708787200_000_000_000 },
};
const archive = try mini_blar.createArchive(allocator, &files);
defer allocator.free(archive);

// Read an archive
const reader = try mini_blar.ArchiveReader.init(archive);
const count = try reader.entryCount();    // 2
const path = try reader.entryPathAt(0);   // "hello.txt"
const content = try reader.fileContentAt(0);  // "Hello, world!\n"
```

## License

MIT - see [LICENSE](LICENSE).
