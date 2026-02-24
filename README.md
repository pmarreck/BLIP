# BLIP: Byte Length Integer Prefix

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

## Container Format

BLIP also defines a recursive binary container format (TLV) for archives, dictionaries, and structured data. See [BLIP_CONTAINER_SPEC.md](BLIP_CONTAINER_SPEC.md) for the full specification.

Container types: ARRAY, DICT, MAP, FILE, UTF8, RAW — each identified by a 2-byte BLIP sentinel. Features include end-of-container index tables for O(1) random access, xxHash64 integrity verification, and canonical key ordering for deterministic output.

### miniBLIP Archive API

The `mini_blip` module provides a high-level API for creating and reading BLIP archives:

```zig
const mini_blip = @import("mini_blip.zig");

// Create an archive
const files = [_]mini_blip.FileEntry{
    .{ .path = "hello.txt", .content = "Hello, world!\n", .metadata = null },
    .{ .path = "src/main.zig", .content = source_bytes, .metadata = null },
};
const archive = try mini_blip.createArchive(allocator, &files);
defer allocator.free(archive);

// Read an archive
const reader = try mini_blip.ArchiveReader.init(archive);
const count = try reader.fileCount();   // 2
const file = try reader.findFile("hello.txt");  // DictReader for the file
```

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

`blar` is a CLI for creating, inspecting, and extracting BLIP archives — similar to `tar`.

### Usage

```bash
# Create an archive
blar create -o archive.blar file1.txt file2.txt dir/file3.txt

# List files
blar list archive.blar

# Extract all files
blar extract archive.blar -C output_dir/

# Verify integrity (outer + per-file xxHash64)
blar verify archive.blar

# Show metadata
blar info archive.blar

# Print single file to stdout
blar cat archive.blar path/to/file.txt
```

### Tar-style shortcuts (hyphen optional)

```bash
blar cf archive.blar file1.txt    # create
blar tf archive.blar              # list
blar xf archive.blar              # extract
blar Vf archive.blar              # verify
blar If archive.blar              # info
blar pf archive.blar file.txt     # cat (print)
```

## License

MIT - see [LICENSE](LICENSE).
