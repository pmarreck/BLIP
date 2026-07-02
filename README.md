# BLIP: Byte Length Integer Prefix

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2FBLIP)](https://garnix.io/repo/pmarreck/BLIP)
[![CI](https://github.com/pmarreck/BLIP/actions/workflows/ci.yml/badge.svg)](https://github.com/pmarreck/BLIP/actions/workflows/ci.yml)

A variable-length integer encoding optimized for CPU-friendly decoding of small values, with a built-in sentinel channel for format extensibility.

See [BLIP_SPEC.md](BLIP_SPEC.md) for the full specification.

## Why BLIP?

Existing variable-length integer encodings (LEB128, VLQ, Protocol Buffers varint) pack 7 data bits per byte and require a **branch on every byte** during decoding. BLIP takes a different approach: the first byte(s) is either an immediate value or the start of a varint that tells you how many raw bytes follow, and those bytes are a plain little-endian integer — decoded with a single load instruction, no per-byte branching, no shift-and-OR reassembly.

The trade-off is 1 extra byte for values in the 256-16383 range, which is acceptable in distributions where values cluster around "small" (<128) or "large" (>16383).

## Self-Describing Endianness

Every BLIP-encoded value declares its own byte order via a single bit in the header:

```
Immediate:       0xxxxxxx         (single byte, endianness irrelevant)
Length-prefixed:  1ECxxxxx [payload...]
                  bit 7 = mode (length-prefixed)
                  bit 6 = E (0 = little-endian, 1 = big-endian)
                  bit 5 = C (continuation flag for L)
                  bits 4-0 = L (payload length)
```

This means:

- **LE payloads** (`E=0`) are optimal for arithmetic — carry-propagating addition works directly on the encoded bytes without decoding.
- **BE payloads** (`E=1`) are optimal for comparison — `memcmp()` gives correct numeric ordering, enabling naive lexicographic sorting for database indexes, B-tree keys, and sorted collections with zero custom comparator code.
- **Any consumer can read any value** — the endianness is right there in byte 0, not in a separate header, not in documentation, not in a convention that someone might forget.

### Why this matters

Endianness bugs are one of the most persistent defect classes in systems programming. They're insidious because they often pass tests — values 0-255 are identical in both byte orders, so the bug only manifests when a value exceeds 255, which may be rare in development but common in production.

A 2008 Linux kernel audit using the `sparse` static analysis tool found **over 600 endianness bugs in drivers alone**. The `__le16`/`__be16`/`__bitwise` type annotation system was invented specifically to combat this problem. Academic studies of data format parser bugs (Lu et al., 2019) found endianness bugs account for **4-7% of all parsing defects**, making them a top-5 category. Debian big-endian ports report that **2-3% of all architecture-specific build failures** per release cycle are attributable to byte-order assumptions.

Notable examples:

- **CVE-2006-1242** (Linux kernel): The `ip_id` field was set in host byte order instead of network byte order, enabling system fingerprinting and NAT host counting. Affected all Linux kernels for years.
- **CVE-2020-25705** (Linux kernel, "SAD DNS"): Byte-order handling inconsistencies in the ICMP rate limiter enabled DNS cache poisoning.
- **CVE-2018-16301** (libpcap/tcpdump): Endianness-related parsing bugs allowed crafted pcap files to trigger buffer overflows.
- **OpenSSL**: Multiple byte-order bugs in ASN.1 parsing and the BN (bignum) library's serialization boundary between host-endian word arrays and big-endian wire format.
- **SQLite**: The entire `sqlite3Get4byte()`/`sqlite3Put4byte()` macro layer exists solely because the file format is big-endian but most CPUs are little-endian — every access site is a potential byte-order bug. A 2006 bug in `btreeInitPage()` caused silent data corruption on big-endian machines.
- **PostgreSQL**: The on-disk format is endian-dependent — copying a data directory from an LE to BE machine corrupts data silently. This is by design, but has caused real data loss.

These bugs persist because the endianness is always *implicit* — specified in documentation, assumed by convention, or baked into code that someone copies to a context where the assumption doesn't hold. As Rob Pike argued in "The Byte Order Fallacy" (2012), code should not depend on host byte order at all. BLIP takes this further: every encoded value *declares* its own byte order. There is no possibility of misinterpretation because the data describes itself.

### Signedness

BLIP's payload bytes are raw and type-agnostic — they support signed two's complement integers natively. To encode -1 as an i8, use L=1 with payload `0xFF`. To encode -129 (which doesn't fit in i8), use L=2 with payload `0x7F 0xFF` (LE) or `0xFF 0x7F` (BE). The decoder reads L bytes; the application interprets them as signed or unsigned. No zigzag encoding is needed (unlike Protocol Buffers), and no separate signed variant is needed (unlike SLEB128 for DWARF). This works because BLIP's payload has no continuation bits interleaved with data bits — the bytes are completely raw, so sign extension is trivial. Note: immediate mode (values 0-127 in a single byte) is always unsigned. Negative values require length-prefixed mode (minimum 2 bytes).

### Lexicographic sortability (BE mode)

BLIP-BE encoded values sort correctly via raw byte comparison (`memcmp`), without any knowledge of the BLIP format:

```
  42 = [0x2A]                       (immediate)
 127 = [0x7F]                       (immediate)
 128 = [0xC1, 0x80]                 (L=1, BE)
 255 = [0xC1, 0xFF]                 (L=1, BE)
 256 = [0xC2, 0x01, 0x00]           (L=2, BE)
 511 = [0xC2, 0x01, 0xFF]           (L=2, BE)
 512 = [0xC2, 0x02, 0x00]           (L=2, BE)
```

Comparison proceeds left to right: shorter encodings (smaller values) sort before longer ones because the header byte encodes the magnitude class. Within the same magnitude class, the big-endian payload bytes sort in numeric order. A system that stores BLIP-BE values as BLOBs in SQLite, keys in a B-tree, or entries in a sorted file gets correct numeric ordering with zero custom code.

### Eliminating GMP's limb abstraction

Traditional arbitrary-precision libraries like GMP use "limbs" (machine-word-sized chunks) as an intermediate representation between serialized bytes and arithmetic operations. This adds allocation overhead, import/export conversion costs, and yet another endianness boundary (limb order vs byte order within limbs).

BLIP-encoded integers need no intermediate representation. The payload bytes *are* the integer in a known byte order. For LE: arithmetic operates directly on the bytes. For BE: comparison operates directly on the bytes. The length prefix eliminates the need for a separate size field. The E bit eliminates the need for out-of-band byte-order metadata. One format serves as both the storage representation and the working representation.

## Benchmark Results

Measured on Apple M4 Max, Zig 0.15.2, ReleaseFast. All timings are best-of-3 runs over 1M values per distribution.

### Arbitrary-Precision Encodings

These encodings support values of unlimited size — no fixed upper bound on the integer being encoded.

#### Encode/Decode Throughput (ns/op)

| Encoding | Small enc | Small dec | Medium enc | Medium dec | Large enc | Large dec |
|----------|-----------|-----------|------------|------------|-----------|-----------|
| **BLIP** | **0.2** | 0.3 | **0.6** | 0.7 | **1.3** | **1.3** |
| LEB128 | 0.5 | 0.3 | 1.9 | 2.1 | 5.1 | 4.2 |
| Protobuf | 0.5 | 0.3 | 2.0 | 2.1 | 5.0 | 4.2 |
| ASN.1 | 0.2 | 0.3 | 0.6 | 0.5 | 1.2 | 2.1 |

- **Small**: uniform 0-127
- **Medium**: uniform 0-65535
- **Large**: uniform 2^32 - 2^64

BLIP is **4x faster** than LEB128/Protobuf for large value encoding (1.3 vs 5.1 ns/op) because it writes raw LE bytes with a single memcpy instead of shifting and masking 7 bits at a time.

#### Bignum Arithmetic (ns/op)

| Encoding | Roundtrip | Direct LE |
|----------|-----------|-----------|
| **BLIP** | 11.0 | **9.4** |
| LEB128 | 13.0 | N/A |
| Protobuf | 11.9 | N/A |
| ASN.1 | 15.2 | N/A |

BLIP's raw LE payload enables **direct arithmetic on encoded data** without decoding first — just extract the payload bytes, do carry-propagating addition, and re-encode. Other encodings must fully decode to integers, compute, then re-encode.

#### Random-Access File Jumping (jumps/sec)

| Encoding | Jumps/sec |
|----------|-----------|
| BLIP | 3,705,075 |
| LEB128 | 3,700,391 |
| Protobuf | 3,603,062 |
| ASN.1 | 3,377,950 |

Following a chain of 10,000 encoded offsets in a sparse file using `pread()`. All encodings perform similarly because the benchmark is I/O-dominated — the decode cost is dwarfed by the syscall overhead. This confirms that BLIP adds no penalty in real-world offset-chasing scenarios.

### Fixed-Width Encodings (max 64-bit)

These encodings are limited to values that fit in a u64 (max 9 bytes encoded). They cannot represent arbitrary-precision integers, so bignum arithmetic and direct LE operations are not applicable.

#### Encode/Decode Throughput (ns/op)

| Encoding | Small enc | Small dec | Medium enc | Medium dec | Large enc | Large dec |
|----------|-----------|-----------|------------|------------|-----------|-----------|
| PrefixVarint | 0.6 | 0.3 | 2.7 | 2.7 | 2.1 | 0.4 |
| SQLite | 1.0 | 0.2 | 1.7 | 0.7 | 3.4 | 1.4 |

#### Random-Access File Jumping (jumps/sec)

| Encoding | Jumps/sec |
|----------|-----------|
| PrefixVarint | 3,683,976 |
| SQLite | 3,585,032 |

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

## Command-line tool: `blip`

[`bin/blip`](bin/blip) is a small LuaJIT filter that frames arbitrary binary data on stdin as a single BLIP value — and, because the endianness lives *in the frame*, doubles as a self-describing byte-order transcoder. Put `bin/` on your `PATH` (no build step; needs `luajit`).

```
blip encode [-b|-l] [-f] < raw   > frame
blip decode [-b|-l] [-f] < frame > raw
```

- **`encode`** frames stdin as one BLIP value. `-b`/`--big` (default) or `-l`/`--little` **declare** the input's byte order; the payload is stored **verbatim** and the E bit is stamped. Encode never reverses bytes.
- **`decode`** unframes stdin. `-b`/`--big` (default) or `-l`/`--little` **require** the *output's* byte order; decode reads the frame's stored order from the E bit and converts (same order ⇒ verbatim, cross order ⇒ reversed).

`encode` is the default verb, so `… | blip` (or `blip -l < raw`) filters straight through it; use `blip decode` for the reverse. Run `blip` interactively with no input for help.

The default output order is **big-endian == stream/network order** (the order bytes are written and transmitted — first byte most significant, à la `htonl`/network byte order). So a bare `decode` **normalizes** any frame to a stable big-endian fixpoint, while `decode -l` hands back genuine little-endian bytes:

```bash
# a little-endian u32 0xDEADBEEF sits in memory as the bytes ef be ad de
printf '\xef\xbe\xad\xde' | blip encode -l | xxd -p   # 84efbeadde  (LE stored verbatim + E=LE)
printf '\xef\xbe\xad\xde' | blip encode -l | blip decode | xxd -p      # deadbeef  (normalized big-endian)
printf '\xef\xbe\xad\xde' | blip encode -l | blip decode -l | xxd -p   # efbeadde  (round-trips to your LE bytes)
```

`-l` is for genuine little-endian *numbers*; opaque/non-numeric data should use the default `-b`, which passes through `decode` unchanged. Both commands emit raw binary and **refuse an interactive terminal** (pipe to a file or a tool like `xxd` / `printable-binary`, or pass `-f`/`--force`).

## Container Format (v2 LP)

BLIP also defines a recursive binary container format for archives, dictionaries, and structured data. See [BLIP_CONTAINER_SPEC.md](BLIP_CONTAINER_SPEC.md) for the full specification.

Container types: ARRAY, DICT, MAP, FILE, DIR, DATA, UTF8. Each container uses the LP (Length-Payload) envelope: `[BLIP(total_length)] [sorted attributes] [VAL payload + checksum]`. Attributes include TYPE (container type ID), COMP (compression algorithm), DECOMP_LEN (decompressed length), CSUM (checksum algorithm), ENC (encryption algorithm + KDF + salt + nonce), and SIG (digital signature). Features include end-of-container index tables for O(1) random access, BLAKE3-128 integrity at the archive level with xxHash64 for inner containers, Merkle hash trees for directories, built-in LZMA2 compression, per-container AEAD encryption (AES-256-GCM or ChaCha20-Poly1305 with Argon2id or PBKDF2-SHA256 key derivation), and canonical key ordering for deterministic output. FILE containers use ARRAY layout with embedded DATA containers for dual-level checksumming. All metadata uses compact 2-character key names.

## C FFI

BLIP is available as a C library. Link against `libblip.a` and include `src/blip.h`:

```c
#include "blip.h"

// Varint encoding/decoding
uint8_t buf[16];
int32_t n = blip_encode(42, buf, sizeof(buf));    // n = 1, buf = {0x2A}
uint64_t value;
int32_t consumed = blip_decode(buf, n, &value);   // value = 42, consumed = 1

// Generic LP-envelope navigation (peek)
const uint8_t *data;
size_t data_len;
uint8_t type_id;
int32_t rc = blip_peek(envelope, envelope_len,
                       "[0][meta]", strlen("[0][meta]"),
                       &type_id, &data, &data_len);

// SEGMENT (Layer 5 transport-fragmentation)
blip_segment_t *segments;
size_t segment_count;
blip_segment_chunk(payload, payload_len,
                   /*max_payload=*/65536, /*stream_id=*/1, /*csum_id=*/0,
                   &segments, &segment_count);
// ... transmit each segments[i].data, segments[i].len ...
blip_segment_array_free(segments, segment_count);
```

The full FFI surface is declared in [src/blip.h](src/blip.h): varint, generic LP-envelope navigation, printable-binary encode/decode, SEGMENT chunk/reassemble, xxHash64.

## Repository layout

A per-file index is maintained as inline **`dirtree` notes** rather than a separate document — run `dirtree` at the repo root for the annotated tree (one line describing every source file). The high-level module groupings:

- **Varint core** — `src/blip.zig` (the spec: encode/decode, sentinels, `encodedSize`). Comparison encodings used only by the benchmarks live alongside (`leb128`, `protobuf_varint`, `asn1_length`, `prefix_varint`, `sqlite_varint`, unified by `encoding.zig`; `bignum.zig` for direct-LE arithmetic).
- **LP envelope + generic containers** — `container_types.zig`, `container.zig`, `checksum.zig`, `leaf.zig`, `array.zig`, `dict.zig`.
- **Navigation & transport** — `peek.zig` (path traversal), `segmentation.zig` (Layer 5 SEGMENT).
- **C FFI surface** — `src/lib.zig` (`export fn`s) + `src/blip.h` (matching C declarations); the real public API.
- **Binaries & fuzzing** — `main.zig` (FFI smoke-test), `benchmark.zig`, `fuzz.zig`.
- **CLI** — [`bin/blip`](bin/blip) (LuaJIT encode/decode filter), tested by `tests/cli/blip_cli_test.sh`.
- **Vendored** — `vendor/printable_binary/` (UTF-8 printable encoding, backing the `blip_*_printable_binary` FFI helpers).

All other BLIP coverage lives in Zig unit tests embedded inside the modules above. Entry-point scripts: `./build`, `./test`, `./bm`.

## Sister projects

This repo contains the **BLIP spec + library**.  Tooling that builds *on top of* BLIP lives in sibling repos:

- **[blar](https://github.com/pmarreck/blar)** — full-featured archive CLI (FILE/DIR containers, metadata preservation, codecs, compression, encryption, archive↔JSON, GUI).  Depends on BLIP.
- **[mini_blar](https://github.com/pmarreck/mini_blar)** — minimal embedded-friendly archive subset (FILE/DIR only, xxHash64, no codecs/compression/encryption).  Depends on BLIP.
- **[printable_binary](https://github.com/pmarreck/printable_binary)** — UTF-8 printable encoding for arbitrary bytes; a build-time dep of BLIP for the `blip_*_printable_binary` FFI helpers.

## License

MIT - see [LICENSE](LICENSE).
