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

## Container Format (v2 LP)

BLIP also defines a recursive binary container format for archives, dictionaries, and structured data. See [BLIP_CONTAINER_SPEC.md](BLIP_CONTAINER_SPEC.md) for the full specification.

Container types: ARRAY, DICT, MAP, FILE, DIR, DATA, UTF8. Each container uses the LP (Length-Payload) envelope: `[BLIP(total_length)] [sorted attributes] [VAL payload + checksum]`. Attributes include TYPE (container type ID), COMP (compression algorithm), DECOMP_LEN (decompressed length), CSUM (checksum algorithm), ENC (encryption algorithm + KDF + salt + nonce), and SIG (digital signature). Features include end-of-container index tables for O(1) random access, BLAKE3-128 integrity at the archive level with xxHash64 for inner containers, Merkle hash trees for directories, built-in LZMA2 compression, per-container AEAD encryption (AES-256-GCM or ChaCha20-Poly1305 with Argon2id or PBKDF2-SHA256 key derivation), and canonical key ordering for deterministic output. FILE containers use ARRAY layout with embedded DATA containers for dual-level checksumming. All metadata uses compact 2-character key names.

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

`blar` is a full-featured CLI for creating, inspecting, and extracting BLIP archives — similar to `tar`. It supports directory recursion, metadata preservation (permissions, timestamps, uid/gid, owner/group names), extended attributes (xattrs), macOS resource forks, and Merkle hash integrity for directory trees. Extended attributes and resource forks are stored in the FILE container's optional forks DICT and restored on extraction where the target filesystem supports them.

### Usage

```bash
# Smart defaults — no subcommand needed:
blar myproject/              # create archive (detects directory)
blar archive.blar            # extract (detects .blar extension)
blar -z myproject/           # create with compression (infers from -z)

# Explicit commands:

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

# Re-apply compression and/or encryption when creating archive from JSON
blar to-json a.blar | blar from-json -z -o compressed.blar
BLIP_PASSWORD=secret blar to-json a.blar | BLIP_PASSWORD=secret blar from-json -z -e -o b.blar

# Create an encrypted archive (AES-256-GCM + Argon2id by default)
blar create -e -o secret.blar myproject/

# Encrypt with ChaCha20-Poly1305
blar create -e chacha -o secret.blar myproject/

# Encrypt with PBKDF2-SHA256 instead of Argon2id
blar create -e --kdf pbkdf2 -o secret.blar myproject/

# Compress + encrypt (compression applied first, then encryption)
blar create -z -e -o secret.blar myproject/

# Decrypt automatically on read (prompts for password if BLIP_PASSWORD not set)
BLIP_PASSWORD=mysecret blar list secret.blar
BLIP_PASSWORD=mysecret blar extract secret.blar -C output_dir/
BLIP_PASSWORD=mysecret blar verify secret.blar
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

# Re-apply compression and/or encryption
BLIP_PASSWORD=secret blar to-json encrypted.blar \
  | BLIP_PASSWORD=secret blar from-json -z -e -o b.blar
```

Binary content is encoded using printable-binary encoding in JSON strings, which preserves all 256 byte values safely within JSON. All hashes, offsets, and index tables are recomputed automatically on `from-json`.

**Byte-identical round-tripping:** Because BLIP uses deterministic encoding (canonical BLIP integers, sorted keys, sorted paths), converting an archive to JSON and back produces the *exact same bytes* — not just equivalent content, but identical at the binary level. This means you can convert an archive containing executables, images, or any binary data to JSON text, transmit it through any text channel (email, chat, clipboard, LLM prompt, HTTP API, git commit), convert it back, and get a byte-for-byte identical archive. This property is tested at both the Zig unit level (`expectEqualSlices` on raw buffers) and the shell integration level (`cmp -s` on archive files) across multi-file, single-file, binary, directory, and empty-file archives.

**Caveat for compressed/encrypted archives:** The JSON representation captures logical content, not LP envelope configuration. `to-json` decompresses and decrypts transparently, so plain `from-json` produces an uncompressed, unencrypted archive. Use `from-json -z` to re-apply LZMA2 compression and `from-json -e` to re-apply encryption (password via `BLIP_PASSWORD` env var). The semantic content is always losslessly preserved; byte-identity holds for uncompressed/unencrypted archives. (Encryption byte-identity is impossible by design — fresh salt and nonce are required for security.)

`miniblar to-json` and `miniblar from-json` work identically.

### Encryption

BLIP archives support per-container AEAD encryption as an LP attribute. Encryption is applied after compression and before checksumming, so the on-disk layering is: compressed plaintext → encrypted ciphertext → checksum.

**Ciphers:**
- **AES-256-GCM** (default) — NIST standard, hardware-accelerated on most CPUs
- **ChaCha20-Poly1305** — Software-friendly, constant-time on all platforms

**Key derivation:**
- **Argon2id** (default) — Memory-hard KDF (64 MiB, 3 iterations, parallelism 4), resistant to GPU/ASIC attacks
- **PBKDF2-SHA256** — Portable fallback (600,000 iterations), widely supported

**Usage:**

```bash
# Encrypt with defaults (AES-256-GCM + Argon2id)
blar create -e -o secret.blar myproject/

# Specify cipher
blar create -e chacha -o secret.blar myproject/

# Specify KDF
blar create -e --kdf pbkdf2 -o secret.blar myproject/

# Compress + encrypt
blar create -z -e -o secret.blar myproject/

# Decrypt on read (password from env var)
BLIP_PASSWORD=mysecret blar list secret.blar

# Decrypt on read (interactive prompt on stderr)
blar list secret.blar
# Enter password: ********
```

**On-disk layout (ENC attribute in LP envelope):**

```
BLIP(total_length)
0x81 0x01 BLIP(type_id)                              -- TYPE
0x81 0x10 BLIP(comp_id)                              -- COMP (if compressed)
0x81 0x11 BLIP(decomp_len)                           -- DECOMP_LEN (if compressed)
0x81 0x12 BLIP(csum_id)                              -- CSUM (if checksummed)
0x81 0x13 BLIP(enc_id) BLIP(kdf_id) <16 salt> <12 nonce>  -- ENC
0x81 0x7F                                            -- VAL
<encrypted_payload> <16 auth_tag> [checksum]
```

The 16-byte AEAD authentication tag is appended to the ciphertext within the VAL payload. Total encryption overhead: ~32 bytes in attributes + 16 bytes auth tag. A wrong password produces an `AuthenticationFailed` error via the AEAD tag check — there is no ambiguity about whether decryption succeeded.

**Attribute interaction order:**
- Write: compress → encrypt → checksum
- Read: verify checksum → decrypt → decompress

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
| **Encryption** | Built-in AEAD encryption (AES-256-GCM / ChaCha20-Poly1305) with password-based key derivation (Argon2id / PBKDF2); ~48 bytes overhead | None built-in; users layer external encryption (`gpg`, `age`) after the fact |
| **Compression** | Built-in LZMA2 via LP attribute; per-container granularity; transparent container expansion decomposes PDFs, PNGs, ZIPs for dramatically better compression with byte-identical reconstruction | External only (`tar.gz`, `tar.zst`); whole-archive granularity; no format-aware optimization |
| **Introspection** | `peek` navigates internal structure with path expressions; every container, metadata key, and hash is addressable | `tar tf` lists files; no structural inspection of headers or checksums |
| **JSON interop** | `to-json` / `from-json` round-trip with full `jq` manipulation; binary content encoded via printable-binary | No equivalent; external tools (`tar2json`) exist but don't round-trip |
| **Text-safe representation** | Entire archives representable as printable text via printable-binary encoding — copy-pasteable through any text channel | Binary-only; requires base64 or similar encoding for text transport |

**Where tar wins:** Ubiquity. tar is everywhere, understood by every tool, and has decades of battle-tested interoperability. If you need an archive that any system can unpack without installing anything, tar is the right choice.

**Where BLIP Archive wins:** Correctness guarantees. Deterministic output means two archives of the same files are byte-identical — useful for caching, deduplication, and content-addressed storage. Built-in BLAKE3-128 integrity verification catches corruption without external tooling. O(1) random access means you can extract one file from a million-file archive without scanning the rest. Built-in LZMA2 compression and AEAD encryption via the LP attribute system keep archives compact and secure without external tooling. Structural introspection via `peek` lets you navigate and verify every container, metadata key, and hash in an archive — no other format offers this. JSON round-tripping via `to-json`/`from-json` with `jq` makes archives manipulable with any tool that speaks JSON. And printable-binary encoding means entire archives can be represented as copy-pasteable text — transmittable through email, chat, or any text channel without base64 overhead. ~3x lower per-file overhead matters when archiving many small files.

### Compression granularity

Because LP attributes (including COMP) apply to any container, BLIP supports a full spectrum of compression strategies — from per-file to solid — without any special mechanism:

- **Per-file:** COMP on each FILE or DATA container. Preserves O(1) random access to every file. Worst compression ratio.
- **Solid (whole-archive):** COMP on the body ARRAY. Best ratio for similar files, but requires decompressing everything to access any single file.
- **Grouped:** Organize files into sub-arrays by content type, compress each group independently. O(1) access to the right group via a DICT index, solid compression within each group, and different algorithms or no compression per group (e.g., skip compression for video files that are already compressed).

A grouped layout might look like:

```
ARRAY (archive)
├── DATA (magic)
└── DICT (body, keyed by content type)
    ├── "image/png"  → ARRAY [FILE, FILE, ...]   ← COMP=lzma2
    ├── "text/plain"  → ARRAY [FILE, FILE, ...]   ← COMP=lzma2
    └── "video/mp4"  → ARRAY [FILE, FILE, ...]   ← no COMP
```

This falls out naturally from recursive typed containers with per-container attributes — no special "solid block" feature is needed. The specific grouping semantics (key naming, content-type detection, etc.) are application-defined; interoperating tools would need to agree on a convention.

### Transparent container expansion

`blar` automatically detects and decomposes known file formats during archiving, storing their components in a way that LZMA2 can compress far more effectively. Extraction reconstructs the original file byte-identically. This is transparent — you archive a PDF, you extract a PDF. The internal representation is an implementation detail.

**PDF container expansion:**

PDFs are internally a mix of JPEG images, zlib-compressed content streams, and structural metadata. Without expansion, LZMA2 treats the whole PDF as an opaque blob and can't improve on the already-compressed regions.

With expansion, `blar` decomposes a PDF into:
- **JPEG images → JPEG XL** (lossless transcoding, ~20-40% smaller, bit-exact reconstruction)
- **FlateDecode images → JPEG XL** (PNG-style pixel data transcoded to lossless JXL)
- **Content streams → decompressed** (zlib-compressed page operators stored as raw text, which LZMA2 compresses dramatically better)
- **PDF shell** (the structural skeleton with image regions zeroed out)

Real-world results:

| PDF | Original | blar (no expansion) | blar (expansion) | Savings |
|-----|----------|-------------------|-----------------|---------|
| Far Side Vol I (673 JPEGs) | 158 MB | ~155 MB | 121 MB | 23% smaller |
| Slaughterhouse-Five (text-only) | 876 KB | ~840 KB | 780 KB | 16% smaller |
| Beginning Lua Programming | 8.6 MB | ~8.2 MB | 2.5 MB | 70% smaller |

All extracted PDFs are byte-identical to the originals.

**PNG container expansion:**

PNGs use zlib compression internally, which LZMA2 can't improve on. `blar` decomposes PNGs into raw pixel data encoded as lossless JPEG XL (~50% smaller than PNG) plus preserved metadata chunks (tEXt, iCCP, pHYs, etc.). Extracted PNGs are pixel-identical with all metadata preserved.

**ZIP container expansion:**

ZIP files contain individually deflate-compressed entries that LZMA2 can't shrink further. `blar` decompresses ZIP entries and stores them as a directory tree, letting LZMA2 compress the raw content. The ZIP structure is preserved for byte-identical reconstruction.

**Gzip container expansion:**

Gzip (.gz) files contain a single deflate-compressed stream. `blar` decompresses the content so LZMA2 can compress the raw data far more effectively. On extraction, the content is recompressed to gzip. Note: extracted gzip files are content-identical (same decompressed output) but not byte-identical (the gzip compression level/strategy is not preserved in the format).


**Image container expansion (BMP, TGA, TIFF):**

Uncompressed raster images are parsed into raw pixels, losslessly encoded to JPEG XL, and stored with compact header metadata. On extraction, the original file is reconstructed byte-identically. BMP and TGA achieve ~90% savings; uncompressed TIFF achieves ~97%.

**GIF container expansion:**

Static GIFs are parsed (pure Zig LZW decoder), pixels encoded to JXL. The original GIF is stored as metadata for byte-identical reconstruction. Since GIF is already LZW-compressed, expansion is only applied when the JXL representation saves space.

**Audio container expansion (WAV, AIFF → FLAC):**

Uncompressed PCM audio in WAV and AIFF formats is losslessly encoded to FLAC via libFLAC. Non-PCM metadata (headers, extra chunks) is stored compactly for byte-identical reconstruction. AIFF's big-endian samples are automatically converted. Typical savings: 50-60% on real audio.

**tar container expansion:**

tar archives are decomposed into their constituent files with original tar headers preserved as metadata. This lets LZMA2 group similar file types together across the tar boundary for significantly better compression. The tar is reconstructed byte-identically on extraction.

**Scientific/medical container expansion (FITS, DICOM):**

FITS astronomy images and NIfTI neuroimaging files (8/16-bit) have their pixel/voxel data extracted and JXL-encoded, with the text header blocks stored as compact metadata. DICOM medical images have their uncompressed pixel data (8/16-bit grayscale/RGB) JXL-encoded with DICOM tags preserved. Both achieve byte-identical reconstruction. Compressed/encapsulated DICOM is left as-is.

**Controlling expansion:**

```bash
# Default: expand all recognized containers
blar create -z -o archive.blar documents/

# Disable expansion (store files as opaque blobs)
blar create -z --no-expand-containers -o archive.blar documents/

# List shows container types:
# p=PDF, n=PNG, j=JPEG, b=BMP, a=TGA, i=TIFF, f=GIF
# w=WAV/AIFF, s=FITS, m=DICOM, g=gzip, t=tar, z=ZIP
# d=dir, -=file
blar list archive.blar
```

## miniblar: Minimal BLIP Archive Tool

`miniblar` is a flat-file archiver that bundles files with their relative paths, content, and file metadata (permissions, timestamps, uid/gid, owner/group names, extended attributes, macOS resource forks). No directory entries, no compression, no encryption — files only. The result is a compact bag of files with full metadata preservation. Entry order is caller-controlled (the CLI sorts by path; the Zig API preserves the order given).

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
