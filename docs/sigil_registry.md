# BLIP Sigil Registry

> **Status:** authoritative.  Updates require a BLIP point release and bump
> `BLIP_CONTAINER_SPEC.md` accordingly.  Downstream projects (`blar`, `mini_blar`,
> `blip_mp`, etc.) consume this registry through `src/container_types.zig`.
>
> **Last revised:** 2026-05-04 (v3.0.0 spec freeze).

This document is the single source of truth for every reserved 2-byte sentinel
in BLIP.  Every sentinel begins with `0x81` (length-prefixed varint with `L=1`,
`E=0`, `C=0`) — the second byte determines the meaning.

```
  byte 0     byte 1
  ┌────┐  ┌─────────────────────────┐
  │0x81│  │ sigil / scalar / pad    │
  └────┘  └─────────────────────────┘
```

## Allocation policy

- **`0x00`–`0x7B`** — attribute sigils + future-reserved range.  Allocated by
  this registry; downstream projects must NOT invent new sigils in this range
  without coordinating an upstream PR.
- **`0x7C`–`0x7E`** — scalar sentinels (boolean / nil).  Reserved.
- **`0x7F`** — `VAL` payload sigil (always last attribute in a container).

The end of every attribute is followed by exactly one `VAL` sigil and the
container payload.  Sigils within a container appear **in ascending byte-1
order** (TYPE first, VAL last); decoders MUST reject out-of-order sigil
sequences with `InvalidSigilOrder`.

## Reserved sigils (byte 1)

| Hex   | Symbol         | Kind       | Required? | Notes                                                       |
|-------|----------------|------------|-----------|-------------------------------------------------------------|
| 0x00  | `PAD_END`      | reserved   | n/a       | Reserved pad/end byte; not a valid sigil in spec contexts.  |
| 0x01  | `TYPE`         | attribute  | required  | Container type ID (always first attribute).                 |
| 0x10  | `COMP`         | attribute  | optional  | Compression algorithm ID (see `CompressionId`).             |
| 0x11  | `DECOMP_LEN`   | attribute  | required when COMP present | Decompressed payload length (BLIP varint).      |
| 0x12  | `CSUM`         | attribute  | optional  | Checksum algorithm ID (see `ChecksumId`).                   |
| 0x13  | `ENC`          | attribute  | optional  | Encryption algorithm + KDF + salt + nonce.                  |
| 0x14  | `SEG`          | attribute  | optional  | Segmentation metadata (stream id, segment idx, total / NIL).|
| 0x20  | `SIG`          | attribute  | optional  | Digital signature (future).                                 |
| 0x7C  | `SCALAR_TRUE`  | scalar     | n/a       | Boolean true literal (whole-value sentinel).                |
| 0x7D  | `SCALAR_FALSE` | scalar     | n/a       | Boolean false literal.                                      |
| 0x7E  | `SCALAR_NIL`   | scalar     | n/a       | Nil literal.                                                |
| 0x7F  | `VAL`          | attribute  | required  | Payload follows; always the last attribute.                 |

`PAD_END_VALUE = 0x00` and `SENTINEL_BYTE = 0x81` are exposed in
`src/container_types.zig` for compile-time use.

## Container type IDs (`TYPE` payload)

`TYPE` is followed by a BLIP-encoded varint that is the type ID.  IDs 1–9 are
predefined; user-defined types start at **8** and skip 9 (which is reserved
for `SEGMENT`).

| ID  | Name      | Layout summary                                                            |
|----:|-----------|---------------------------------------------------------------------------|
| 1   | `ARRAY`   | Length-prefixed sequence with optional element-index table + xxHash64.    |
| 2   | `DICT`    | Sorted key→value pairs with interleaved index + xxHash64.                 |
| 3   | `UTF8`    | UTF-8 leaf payload.                                                       |
| 4   | `DATA`    | Raw byte leaf payload.                                                    |
| 5   | `FILE`    | Archive-shaped FILE entry (ARRAY of [meta DICT, DATA, optional forks]).   |
| 6   | `MAP`     | Unsorted key→value pairs (rarely used).                                   |
| 7   | `DIR`     | Archive-shaped directory entry (DICT with `pa`+`xh` keys).                |
| 9   | `SEGMENT` | Layer 5 transport-fragmentation wrapper (stream id, seg index, total).    |

`FILE` and `DIR` *are* BLIP types-by-id, but their archive-shaped key schemas
(`pa`, `xh`, `mt`, `md`, `un`, etc.) are governed by the **blar** spec, not
this registry.

## Compression algorithm IDs (`CompressionId` — payload of `COMP`)

| ID | Name    | Notes                                       |
|---:|---------|---------------------------------------------|
| 1  | `lzma2` | Default, used by 7-Zip-compatible streams.  |
| 2  | `bzip2` | bzip2 block-sort.                           |
| 3  | `lz4`   | Raw LZ4 frame.                              |
| 4  | `zstd`  | Zstandard.                                  |

Codec implementations live in **blar**; BLIP itself only reserves the IDs.

## Checksum algorithm IDs (`ChecksumId` — payload of `CSUM`, also returned by xxHash FFI)

| ID | Name         | Length (bytes) |
|---:|--------------|---------------:|
| 1  | `crc32`      | 4              |
| 2  | `xxhash64`   | 8              |
| 3  | `blake3_128` | 16             |

`checksumLength(id)` returns the byte width.

## Encryption algorithm IDs (`EncryptionId` — payload of `ENC`)

| ID | Name                  | Tag len | Nonce len |
|---:|-----------------------|--------:|----------:|
| 1  | `aes_256_gcm`         | 16      | 12        |
| 2  | `chacha20_poly1305`   | 16      | 12        |

`authTagLength(id)` and `encNonceLength(id)` return the relevant widths.
`ENC_SALT_LEN = 16` for both.  Algorithm impl lives in **blar**.

## Key derivation function IDs (`KdfId` — embedded inside the `ENC` payload)

| ID | Name             |
|---:|------------------|
| 1  | `argon2id`       |
| 2  | `pbkdf2_sha256`  |

## Reserving a new sigil / type / algorithm ID

1. Open a PR against `BLIP_CONTAINER_SPEC.md` and `src/container_types.zig`
   that adds the new ID + the corresponding helper (`checksumLength` etc.) at
   the same time.
2. Update this registry table.
3. Bump the BLIP minor version (e.g. v3.1.0) — sigils are an additive surface.
4. Coordinate with downstream consumers (blar, mini_blar, blip_mp) before
   merging if the new ID changes the wire format for an existing container.

## See also

- `src/container_types.zig` — Zig source-of-truth for every value above.
- `BLIP_CONTAINER_SPEC.md` — full LP envelope grammar + semantics.
- `BLIP_SPEC.md` — varint specification (the encoding under every byte above).
