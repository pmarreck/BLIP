# BLIP Wire Format

A recursive, typed, self-describing binary **wire format** built on [BLIP encoding](BLIP_SPEC.md). This is the generic *expression vocabulary* — containers, attributes, and transport segmentation — for compact messages that remain visible via [printable-binary](https://github.com/pmarreck/printable_binary).

**Author:** Peter Marreck
**Version:** 3.1 (2026-07-02)
**Depends on:** BLIP Spec v1.2

> **Scope.** This document defines only the *generic* wire vocabulary. The **archive application** built on top of it (the tar-replacement: FILE/DIR containers, the archive envelope, metadata key registries, Merkle directory hashing) lives in **[blar's `BLAR_ARCHIVE_SPEC.md`](https://github.com/pmarreck/blar/blob/yolo/BLAR_ARCHIVE_SPEC.md)**. This split (v3.1) replaces the former `BLIP_CONTAINER_SPEC.md`, which welded the two layers together.
>
> **North star.** The wire format is heading toward a compact RPC-like expression layer — function calls with arguments in various formats and their return values — carried over a unix socket by default and optionally over TCP/IP or UDP. The primitives here (the container types, SEGMENT, and the *optional* COMP/CSUM/ENC attributes) are the building blocks for that layer.

## Overview

Every element in the format is a **container**: a Length-Payload (LP) envelope whose payload carries a sorted set of attributes (including a type tag) and a value. Containers nest recursively.

The format provides:
- **Typed values** — UTF8 strings, raw/checksummed binary, ordered arrays, sorted/unsorted key-value maps.
- **Random access** via end-of-container index tables (ARRAY/DICT).
- **Optional integrity** via the CSUM attribute (xxHash64/CRC32/BLAKE3-128) — off by default; used on lossy/untrusted transports.
- **Optional compression / encryption** via the COMP / ENC attributes — off by default.
- **Transport fragmentation** via the SEGMENT container (datagram/record-size limits, e.g. UDP).
- **Streaming writes** via padded BLIPs for index offsets that are backfilled after layout.
- **Determinism** via sorted keys and canonical BLIP encoding.
- **Text transport** — the entire binary stream round-trips through printable-binary, so any container is copy-pasteable through a text channel.

## TLV Structure

Conceptually every container is a Type-Length-Value triplet. In the v2+ LP envelope (below) the type is expressed as an attribute rather than an inline sentinel, but the length/skip mechanics are universal:

```
┌────────────────────────────────────────────────────────────┐
│ Length: BLIP integer (total container size in bytes,       │
│         INCLUDING every byte of the container)             │
│ Payload: attributes (sorted) + value                       │
└────────────────────────────────────────────────────────────┘
```

**Total container size** = offset from container start to the first byte past it. To skip a container during sequential parsing: `next = container_start + Length`.

**Self-referential length**: Because Length includes its own encoded size, the encoder must solve `L = header + blip_size(L) + payload_size`. This converges in 1-2 iterations:

```
fn compute_total(V_size: u64) -> u64:
    base = 2 + V_size           // T + V
    for L_bytes in 1..9:        // try each BLIP encoding width
        total = base + L_bytes
        if blip_encoded_size(total) == L_bytes:
            return total        // converged
```

## LP Envelope (v2)

All containers use the LP (Length-Payload) envelope. The type sentinel is not inline — container type and other properties are expressed as **sorted attributes** within the payload.

```
┌─────────────────────────────────────────────────────────────┐
│ Length:  BLIP(total_length)                                  │
│ Attributes (sorted by sigil value):                          │
│   0x81 0x01 BLIP(type_id)            -- TYPE (required)     │
│   0x81 0x10 BLIP(comp_id)            -- COMP (optional)     │
│   0x81 0x11 BLIP(decomp_len)         -- DECOMP_LEN (opt)   │
│   0x81 0x12 BLIP(csum_id)            -- CSUM (optional)     │
│   0x81 0x13 ...                      -- ENC (optional)      │
│   0x81 0x14 ...                      -- SEG (optional)      │
│   0x81 0x20 ...                      -- SIG (future)        │
│   0x81 0x7F                          -- VAL (required)      │
│ Payload:  type-specific data + [checksum]                    │
└─────────────────────────────────────────────────────────────┘
```

Each attribute is a 2-byte sentinel (`0x81` + sigil byte) followed by attribute-specific data. Attributes MUST be sorted by sigil value within a container. TYPE is always first; VAL is always last.

### Attribute Sigils

| Sigil | Hex | Name | Description |
|-------|-----|------|-------------|
| `0x01` | `0x81 0x01` | TYPE | Container type ID (required) |
| `0x10` | `0x81 0x10` | COMP | Compression algorithm ID (optional) |
| `0x11` | `0x81 0x11` | DECOMP_LEN | Decompressed payload length (required when COMP present) |
| `0x12` | `0x81 0x12` | CSUM | Checksum algorithm ID (optional) |
| `0x13` | `0x81 0x13` | ENC | Encryption algorithm, KDF, salt, nonce (optional) |
| `0x14` | `0x81 0x14` | SEG | Segmentation metadata: stream ID, segment index, total (see §Segmentation) |
| `0x20` | `0x81 0x20` | SIG | Digital signature (reserved, future) |
| `0x7F` | `0x81 0x7F` | VAL | Value/payload marker (required) |

### Container Type IDs

| ID | Name | Layer | Description |
|----|------|-------|-------------|
| 1 | ARRAY | wire | Ordered sequence of containers |
| 2 | DICT | wire | Sorted key-value pairs |
| 3 | UTF8 | wire | UTF-8 string |
| 4 | DATA | wire | Checksummed binary data |
| 5 | FILE | **archive** | File container — defined in blar's archive spec |
| 6 | MAP | wire | Unsorted key-value pairs (insertion order) |
| 7 | DIR | **archive** | Directory container — defined in blar's archive spec |
| 9 | SEGMENT | wire | Transport wrapper around a slice of a larger BLIP byte stream (see §Segmentation) |

FILE (5) and DIR (7) are reserved here for interoperability but their structure is specified by the **archive layer** in blar. Everything else is generic wire vocabulary defined below.

### Optional attributes: COMP, CSUM, ENC

COMP (compression), CSUM (checksum), and ENC (encryption) are **optional** and **off by default**. A reliable, trusted, local transport (e.g. an RPC over a unix-domain socket) omits all three. They exist for transports that need them:

- **CSUM** — integrity over a lossy channel (UDP's 16-bit checksum is weak; corruption slips through).
- **COMP** — bandwidth reduction over a network link.
- **ENC** — confidentiality + authenticity over an untrusted network.

The registries below define the *mechanism*. Application-specific *defaults and tuning* (e.g. an archive's LZMA2 level or Argon2 parameters) are the concern of the layer that uses them.

#### Compression (COMP Attribute)

When COMP is present, the VAL payload is compressed and DECOMP_LEN MUST also be present (decompressed size).

| ID | Algorithm |
|----|-----------|
| 1 | LZMA2 |
| 2 | bzip2 |
| 3 | LZ4 |
| 4 | zstd |

Because COMP is an LP attribute on any container, implementations choose where to apply it (per-container for random access, or on a parent ARRAY for a solid stream). Grouping conventions are application-defined; the wire format provides only the mechanism.

#### Checksum (CSUM Attribute)

When CSUM is present, a checksum is appended to the end of the VAL payload.

| ID | Algorithm | Length |
|----|-----------|--------|
| 1 | CRC-32 | 4 bytes |
| 2 | xxHash64 | 8 bytes |
| 3 | BLAKE3-128 | 16 bytes |

> Note: ARRAY, DICT, and DATA containers carry a *structural* trailing xxHash64 as part of their layout (see below), independent of the CSUM attribute. The CSUM attribute is for adding integrity to other containers or choosing a stronger algorithm over a whole payload.

#### Encryption (ENC Attribute)

The ENC attribute provides per-container AEAD encryption with password-based key derivation.

**ENC attribute layout:**

```
0x81 0x13  BLIP(enc_id)  BLIP(kdf_id)  <16-byte salt>  <12-byte nonce>
```

| Field | Size | Description |
|-------|------|-------------|
| Sentinel | 2 bytes | `0x81 0x13` |
| enc_id | 1+ bytes | BLIP-encoded encryption algorithm ID |
| kdf_id | 1+ bytes | BLIP-encoded key derivation function ID |
| Salt | 16 bytes | Random salt for KDF (CSPRNG) |
| Nonce | 12 bytes | Random nonce for AEAD cipher (CSPRNG) |

**Encryption algorithm IDs:**

| ID | Algorithm | Key size | Nonce | Auth tag |
|----|-----------|----------|-------|----------|
| 1 | AES-256-GCM | 256 bits | 12 bytes | 16 bytes |
| 2 | ChaCha20-Poly1305 | 256 bits | 12 bytes | 16 bytes |

**Key derivation function IDs:**

| ID | Algorithm | Parameters |
|----|-----------|------------|
| 1 | Argon2id | m=65536 (64 MiB), t=3, p=4, output=32 bytes |
| 2 | PBKDF2-SHA256 | 600,000 iterations, output=32 bytes |

KDF parameters are fixed per ID. New parameter sets require new KDF IDs.

**Encrypted payload layout** — the AEAD ciphertext replaces the plaintext in VAL, with the 16-byte auth tag appended:

```
0x81 0x7F  <ciphertext>  <16-byte auth tag>  [checksum]
```

**Attribute interaction order:**
- **Serialization (write):** compress → encrypt → checksum.
- **Deserialization (read):** verify checksum → decrypt → decompress. The checksum covers the ciphertext, providing tamper detection before decryption.

**Error cases:**
- Wrong password → AEAD tag verification fails → `AuthenticationFailed`
- Truncated ciphertext → length check fails → `BufferTooSmall`
- Missing password when ENC detected → `PasswordRequired`

## Type Assignments (Legacy)

> **Note:** The type sentinel assignments below are from the v1 TLV format. In v2+ LP format, container types are expressed via the TYPE attribute (see §LP Envelope). Semantics are unchanged — only the envelope encoding changed.

BLIP sentinels (`0x81 0x00` – `0x81 0x7F`) served as type tags in v1. `0x81 0x00` is reserved at the BLIP level as PAD_END and is not a container type.

```
Sentinel        Type            Layer     Description
──────────────────────────────────────────────────────────────
0x81 0x00       (PAD_END)       —         Reserved by BLIP spec
0x81 0x01       ARRAY           wire      Ordered sequence, indexed + hashed
0x81 0x02       DICT            wire      Sorted key-value pairs, indexed + hashed
0x81 0x03       UTF8            wire      UTF-8 string
0x81 0x04       RAW             wire      Raw binary data (untyped)
0x81 0x05       FILE            archive   File container (blar)
0x81 0x06       MAP             wire      Unsorted key-value pairs
0x81 0x07       DIR             archive   Directory container (blar)
0x81 0x08       DATA            wire      Checksummed binary data
0x81 0x09       SEGMENT         wire      Transport segmentation wrapper (v3; LP-only)
0x81 0x0A - 0x0F               —          Reserved (future container types)
0x81 0x10 - 0x7F               —          Application-defined types (v1 only)
```

## Offset Convention

All offsets within a container are measured **from the start of the containing container**. This is universal — it does not vary by container type. See [BLIP Spec §Offset and Length Convention](BLIP_SPEC.md) for the full specification. Offsets MAY be negative (signed two's complement) when pointing into a preceding scratch pool (see §Scratch Pool).

## Key Ordering

DICT containers store key-value pairs in canonical sort order; MAP containers preserve insertion order. Keys MUST be sorted in **lexicographic byte order** — the same ordering as `memcmp`:

1. Compare keys byte-by-byte using unsigned byte values (`0x00 < 0x01 < … < 0xFF`).
2. If one key is a prefix of another, the shorter key sorts first.
3. Applies uniformly to all keys regardless of container type (UTF8 or RAW).
4. UTF8 keys are compared by raw bytes, not Unicode codepoint or collation order.

**Rationale:** Byte ordering is unambiguous, locale-independent, trivial to implement, identical for UTF8 and RAW keys, and keeps index-section keys in a known order — enabling binary search for key lookup.

Encoders MUST emit key-value pairs in canonical key order for DICT containers. Decoders SHOULD reject DICT containers with out-of-order keys as malformed. MAP containers are exempt.

> The archive layer defines a compact 2-character key registry (`pa`, `md`, `mt`, `xh`, …) for FILE/DIR metadata; see the blar archive spec. Those keys obey this same ordering.

## Container Types

### UTF8 String (type 3)

A UTF-8 encoded string. Value is the raw string bytes (no null terminator).

```
┌─────────────────────────────────────┐
│ Type:   UTF8 (3)                    │
│ Length: BLIP(total)                 │
│ Value:  raw UTF-8 bytes             │
└─────────────────────────────────────┘
```

Example — the string `"hello"` (v1 inline-sentinel form shown for illustration):
```
0x81 0x03                 ← type: UTF8
0x08                      ← length: 8 (2 type + 1 length + 5 value)
0x68 0x65 0x6C 0x6C 0x6F  ← "hello"
```

### Raw Binary (type 4)

Untyped binary data. Value is raw bytes, no checksum.

```
┌─────────────────────────────────────┐
│ Type:   RAW (4)                     │
│ Length: BLIP(total)                 │
│ Value:  raw bytes                   │
└─────────────────────────────────────┘
```

### Data (type 8)

Checksummed binary data: raw bytes with an embedded xxHash64 suffix for content integrity.

```
┌─────────────────────────────────────────────────────┐
│ Type:   DATA (8)                                     │
│ Length: BLIP(total)                                  │
│ Value:  [data_bytes][xxHash64(data_bytes) 8B LE]     │
└─────────────────────────────────────────────────────┘
```

- `data_len = value_len - 8`
- The trailing 8 bytes are `xxHash64(data_bytes)` with seed 0, little-endian.
- Hash covers only the data bytes, NOT the type/length prefix.
- Empty content is valid: value = 8-byte hash of the empty input.

### Array (type 1)

An ordered sequence of containers with a trailing index for random access and a trailing xxHash64 for integrity.

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    ARRAY (1)                                              │
│ Length:  BLIP(total)                                            │
│ Value:                                                          │
│   Index offset: BLIP (padded for streaming writers)             │
│     Byte offset from array container start to the INDEX section │
│   DATA SECTION: Element 0 TLV, Element 1 TLV, … Element N-1 TLV  │
│   INDEX SECTION (at index_offset from container start):          │
│     Element count: BLIP(N)                                       │
│     Offset 0..N-1: BLIP(off_k)   ← each from array start         │
│   HASH: xxHash64 (8 bytes) over everything except these 8 bytes  │
└──────────────────────────────────────────────────────────────────┘
```

**Random access to element K:** jump to `container_start + index_offset` → read `N` → read offset `K` → jump to `container_start + off_K`.

**Integrity check:** compute xxHash64 of bytes `[container_start .. container_start + Length - 8]`; compare with the stored 8-byte hash.

**Index-at-the-end rationale:** offsets can only be computed after all elements are laid out, so the encoder writes elements sequentially, records positions, then emits the index; the hash covers everything including the index. A streaming writer that doesn't yet know the index position emits `index_offset` as a **padded BLIP** (see §Streaming Writes). For in-memory construction the index offset is a normal BLIP.

### Dictionary (type 2)

A sorted collection of key-value pairs with a trailing index and hash. Keys must be unique and stored in canonical key order (see §Key Ordering).

```
┌──────────────────────────────────────────────────────────────────┐
│ Type:    DICT (2)                                               │
│ Length:  BLIP(total)                                            │
│ Value:                                                          │
│   Index offset: BLIP (padded for streaming writers)             │
│   DATA SECTION: Key0, Val0, Key1, Val1, …  (interleaved,         │
│                 canonical key order)                            │
│   INDEX SECTION:                                                │
│     Pair count: BLIP(N)                                          │
│     Pair k: BLIP(key_off_k) BLIP(val_off_k)  ← from dict start   │
│   HASH: xxHash64 (8 bytes) — same semantics as array            │
└──────────────────────────────────────────────────────────────────┘
```

**Key lookup:** jump to index, read N, **binary search** the sorted pairs (each is a `(key_offset, value_offset)` tuple); dereference `key_offset`, compare; on match the adjacent `value_offset` gives the value. O(log N).

Keys are UTF8 (3) or RAW (4) containers and MUST be unique. Keys and values are interleaved in canonical key order for determinism; parsers MUST use the index for access.

The reference implementation realizes fast lookup: `DictReader.findKey` binary-searches the sorted keys, and an opt-in `DictIndex` accelerator parses the offset table once for O(1) random access and O(log n) lookup (Zig + C FFI `blip_dict_index_*`).

### Map (type 6)

An unsorted collection of key-value pairs. Identical layout to DICT, but keys are stored in **insertion order** rather than canonical order.

**Differences from DICT:**
- Keys are NOT required to be sorted — they appear in the writer's chosen order.
- Key lookup is O(N) sequential scan (no binary search).
- Output is NOT deterministic (different insertion orders produce different bytes).
- Decoders MUST NOT reject a MAP for out-of-order keys.

**When to use MAP vs DICT:** use **DICT** when determinism matters (anything hashed or compared byte-for-byte); use **MAP** when insertion order matters or sorting is undesirable. Keys in a MAP MUST still be unique.

## Segmentation (v3)

A SEGMENT container wraps a contiguous slice of a larger BLIP byte stream that has been split across N transport units. Multiple SEGMENT containers, reassembled in order, reproduce the original inner container's wire encoding.

### Motivation

Some host environments cap individual record sizes — JPEG APP markers cap at 64 KiB, **UDP datagrams at 64 KiB**, multipart uploads at chunk-defined limits. Without a BLIP-level segmentation primitive, every host adapter has to invent its own reassembly protocol. SEGMENT provides one canonical mechanism every host adapter can reuse — and it is the datagram-fragmentation primitive the RPC layer uses over UDP.

### Wire format

A SEGMENT container uses the standard v2 LP envelope:

```
┌──────────────────────────────────────────────────────────────────┐
│ Length:    BLIP(total)                                           │
│ Attributes (sorted by sigil):                                    │
│   TYPE:    0x81 0x01 BLIP(9)               SEGMENT type          │
│   COMP:    0x81 0x10 BLIP(comp_id)         optional, per-segment │
│   CSUM:    0x81 0x12 BLIP(csum_id)         optional, per-segment │
│   ENC:     0x81 0x13 ...                   optional, per-segment │
│   SEG:     0x81 0x14 BLIP(I) BLIP(M) BLIP(N | NIL)               │
│   VAL:     0x81 0x7F <payload slice>                             │
└──────────────────────────────────────────────────────────────────┘
```

### SEG attribute payload

The SEG attribute payload is exactly **three** BLIP scalar values, in order:

| Field | Type | Semantics |
|-------|------|-----------|
| `I` | BLIP integer (u64) | Stream ID. `0` = "default / unnamed stream" (single logical payload). `I > 0` caller-chosen. Uniqueness scope: one host container. |
| `M` | BLIP integer (u64) | **1-based** index of this segment within stream `I`. First segment is `M = 1`; `M = 0` is illegal. |
| `N` | BLIP integer **or** NIL (`0x81 0x7E`) | Total segment count in stream `I`, or **NIL** for streaming / unknown-total. |

`M` is 1-based (counts the way humans do, matches the disk-files transport convention). `N = NIL` (the BLIP scalar sentinel) signals incremental emission with unknown total; `N = 0` is not valid — if a SEGMENT exists then `N >= 1` or `N = NIL`. `N = 1` (single-segment stream) is legal, useful for hosts that wrap every payload for pipeline uniformity. The SEG payload is fixed arity — always three values; the N slot uses NIL to express "unknown" without changing field count.

### Reassembly algorithm

```
function reassemble(segments: list[SEGMENT], expected_I: int) -> bytes:
    mine = [s for s in segments if s.I == expected_I]          # 1. filter by stream
    mine = [s for s in mine if not s.has_csum or verify_csum(s)]  # 2. drop failing CSUM copies
    N = mine[0].N                                              # 3. N consistent across members
    if any(s.N != N for s in mine): error InconsistentTotal(I)
    # 4. coalesce duplicate M: identical VAL → accept one; conflicting → error
    by_M = group_by(mine, key=s.M)
    deduped = []
    for M, cands in by_M.items():
        if len({c.VAL for c in cands}) == 1: deduped.append(cands[0])
        else: error DuplicateSegmentValueMismatch(I, M)
    mine = deduped
    if N is not NIL:                                           # 5. numeric N: verify density [1..N]
        if len(mine) != N: error MissingSegments(I, set(range(1, N+1)) - {s.M for s in mine})
        mine.sort(key=s.M)
        for i, s in enumerate(mine):
            if s.M != i + 1: error SequenceGap(I, expected=i+1, got=s.M)
    else:
        mine.sort(key=s.M)                                     # streaming: missing detection N/A
    return b"".join(s.VAL for s in mine)                       # 6. concatenate
```

**Duplicate-M rule.** If two segments share `(I, M)`: each must verify against its own CSUM (failing copies silently dropped); among survivors, VAL payloads MUST agree byte-for-byte; if they agree, accept one copy; if they disagree, error `DuplicateSegmentValueMismatch`. This makes duplicate-M safe under retransmit — the only error case is genuinely conflicting good data.

### Streaming mode (N = NIL)

The producer MAY emit segments incrementally without knowing the total; the consumer accepts them until the host signals end-of-stream. **Missing-segment detection is impossible in streaming mode** — applications that need loss detection MUST use a numeric `N`. All other rules (sort-by-M, dedup-by-checksum) still apply.

### Nested segmentation

If the reassembled VAL is itself a SEGMENT (TYPE=9), the consumer parses it again recursively — useful for multi-hop transport where each hop adds framing.

### Attribute interaction

| Attribute | Meaning on SEGMENT | Notes |
|-----------|--------------------|-------|
| COMP | Compresses this segment's VAL independently | Rarely useful — usually compress the inner container instead. |
| CSUM | Integrity over this segment's VAL | RECOMMENDED — enables precise corruption reporting and the duplicate-M dedup rule. |
| ENC | AEAD over this segment's VAL | Transport-layer auth; each segment its own nonce/tag. |
| SIG | Per-segment signature | Reserved. |

Attributes on the inner reassembled container are independent of per-segment attributes; the two layers do not interfere. If the inner container carries its own CSUM (e.g. BLAKE3-128 over its full payload), that whole-stream checksum is the canonical authenticator; per-segment CSUMs are a transport concern.

### Forward compatibility

A pure v2 parser encountering a SEGMENT (TYPE=9) reads its Length correctly and can SKIP it cleanly — it cannot reassemble but will not crash, misparse, or follow a pointer into the segment. Applications emitting SEGMENTs SHOULD include a v3 marker in surrounding metadata so v2 readers can produce a "segmented data, requires v3 parser" diagnostic.

## Streaming Writes

The format supports streaming writes via **padded BLIPs** — a BLIP integer emitted into a fixed pre-allocated byte budget, backfilled after the real value is known.

1. The writer emits a container's index-offset field as a padded BLIP with a budget (e.g. 12 bytes): initially L=0, followed by padding (`0x00`), terminated by PAD_END (`0x81 0x00`).
2. The writer emits elements sequentially, recording positions.
3. The writer emits the index and hash.
4. The writer seeks back and backfills the actual offset; the padding absorbs the size difference.

**Budget sizing:** a 12-byte budget accommodates offsets up to 2^64 (`1 header + 8 value + 1 padding + 2 PAD_END`). Smaller containers (a few keys) can use a 6–8 byte budget.

**Overflow:** if the real value exceeds the budget, the writer sets the indirect flag (I=1); the value bytes then hold a signed offset to a scratch-pool entry storing the actual value as a normal BLIP (see §Scratch Pool). Generous pre-allocation makes overflow astronomically unlikely; the mechanism exists for formal completeness.

Streaming reads are straightforward: to process elements sequentially, ignore the index and read containers one after another. The index is only needed for random access.

## Scratch Pool

Containers using padded BLIPs MAY reserve a **scratch pool** — a pre-allocated block of `0x00` bytes immediately after the index-offset field:

```
Type + Length
Index offset: padded BLIP
Scratch pool: [0x00 × S bytes]   ← optional
DATA SECTION: elements…
INDEX SECTION + HASH
```

If a padded BLIP overflows, the writer sets I=1 and writes a signed offset into the scratch pool, where a normal BLIP holds the actual value. When a padded BLIP uses indirection, the value is a **signed offset from the container's start byte** (consistent with the universal offset convention).

The scratch pool is a concern **only** for enormous containers where re-emission would be prohibitively expensive. In-memory construction needs none (all values known); streaming writes of typical containers (up to multi-GB) need none (a 12-byte budget covers 2^64). Implementations targeting reasonable sizes MAY omit scratch-pool support and re-emit on the rare overflow. It exists so the format is **formally complete** — any valid container can be produced without re-emission, regardless of size.

## Determinism

A container is deterministic (byte-identical given the same inputs) if:

1. All DICT keys are sorted in canonical key order (MUST per §Key Ordering).
2. All BLIP integers use canonical (shortest) encoding.
3. xxHash64 is computed consistently (same algorithm, same byte range).
4. Padded BLIP budgets use a fixed, predetermined size (not content-dependent).

For deterministic output, use in-memory construction with normal (non-padded) BLIPs. Padded BLIPs are a streaming-write optimization; their variable padding prevents byte-identical output unless the budget is fixed by convention. MAP containers are non-deterministic by design (insertion order).

## Text Transport (printable-binary)

The entire wire stream is opaque bytes, but any BLIP container round-trips losslessly through [printable-binary](https://github.com/pmarreck/printable_binary): a UTF-8 encoding that maps every byte to a stable, monospaced, copy-pasteable glyph while preserving embedded ASCII legibly. This makes a container **copy-pasteable through any text channel** (chat, email, a code comment, JSON) without base64 — and human-inspectable in a terminal. The BLIP C FFI exposes `blip_encode_printable_binary` / `blip_decode_printable_binary` for this. It is the wire format's answer to "binary is hostile to text pipes."

## Human-Readable Representation (JSON)

When BLIP is the transport between a frontend and a backend, two things are needed beyond the raw bytes: a way to **inspect** a message, and a way to **author** a message in a readable form and convert it back to the wire (so human-written JSON can serve as test-data input). The wire format therefore defines a canonical, **bidirectional** correspondence with JSON.

**Type mapping (structural):**

| BLIP container | JSON |
|----------------|------|
| ARRAY | array `[…]` |
| DICT / MAP | object `{…}` (DICT canonical-ordered; MAP insertion-ordered) |
| UTF8 | string |
| BLIP integer | number (or a string when it exceeds JSON's safe-integer range) |
| TRUE / FALSE / NIL scalar sentinels | `true` / `false` / `null` |
| DATA / RAW (binary leaf) | printable-binary string (consistent with §Text Transport) — never base64 |

**Fidelity note.** A naive mapping is lossy in the JSON→BLIP direction: a JSON string could mean UTF8 *or* a binary leaf; a number hides its BLIP width; `{…}` could be DICT *or* MAP; and JSON's f64 number type cannot hold a `u64 > 2^53`. Faithful round-tripping therefore uses a lightweight **typed form** where ambiguity matters (e.g. `{"$data":"<printable-binary>"}`, `{"$u64":"…"}`, `{"$map":{…}}`), falling back to the natural mapping otherwise.

**Universal lossless guarantee.** Because printable-binary can represent *any* byte sequence as valid UTF-8, it is the universal escape hatch: any value — a subtree, or the entire frame — that lacks a clean or agreed structural mapping degrades to a printable-binary string of its **raw BLIP bytes**, tagged (e.g. `{"$blip":"<printable-binary>"}`). The decoder printable-binary-decodes it straight back to the container bytes and splices them in. So **lossless projection is total by construction** — there is always a faithful representation for any binary content, and no format can defeat it. The structural mapping above is the *readable* path; the escape hatch is the *guarantee*.

The exact typed-JSON tag vocabulary is finalized alongside the RPC expression layer (a call's arguments are exactly this authoring problem) and is intentionally left open here.

**Reference implementation.** blar ships an *archive-specialized* codec — `archiveToJson` / `jsonToArchive` in [`src/json_serde.zig`](https://github.com/pmarreck/blar/blob/yolo/src/json_serde.zig) — which renders paths, ISO-8601 timestamps, and octal modes for the archive use case. A **generic** container↔JSON codec (any message, no archive semantics) is planned as BLIP-side wire tooling, mirroring how the generic container code lives in BLIP while blar consumes it.

## Security Considerations

1. **Recursive depth.** Containers nest arbitrarily. Parsers SHOULD enforce a maximum nesting depth (e.g. 64) to prevent stack overflow from malicious inputs.
2. **Length validation.** A container's Length must not exceed the remaining bytes in the enclosing container. Parsers MUST validate before reading the value.
3. **Index offset validation.** The index offset must point within the container's value section. Parsers MUST validate before jumping.
4. **Duplicate keys.** DICT and MAP containers MUST NOT have duplicate keys. Parsers SHOULD reject duplicates.
5. **Hash verification.** The structural xxHash64 provides integrity, not cryptographic authentication — it detects accidental corruption, not adversarial tampering. For authentication use the ENC attribute (AEAD).
6. **Padded BLIP overflow.** A parser encountering a padded BLIP with I=1 MUST validate that the target offset falls within the container bounds before following it.
7. **Encryption.** ENC provides confidentiality + authenticity via AEAD; the auth tag guarantees ciphertext integrity. The LP envelope attributes (TYPE, COMP, CSUM, ENC metadata) are cleartext — an observer sees that a container is encrypted and which algorithms are used, but cannot read the payload. Implementations MUST use a CSPRNG for salt/nonce. Nonce reuse with the same key is catastrophic for AES-GCM; random 96-bit nonces provide adequate collision resistance for typical volumes.

## License

MIT — see [LICENSE](LICENSE).
