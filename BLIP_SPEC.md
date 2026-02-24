# BLIP: Byte Length Integer Prefix

A variable-length integer encoding optimized for CPU-friendly decoding of small values, with a built-in sentinel channel for format extensibility and optional padding support for streaming writers.

**Author:** Peter Marreck
**Version:** 1.1 (2026-02-23)

## Motivation

Binary formats frequently need to encode integers of widely varying magnitude: a file count might be 12, a path length 47, a byte offset 5,242,880. Existing variable-length integer encodings (LEB128, VLQ, Protocol Buffers varint) handle this by using a per-byte continuation bit and packing 7 data bits per byte. This is compact but requires a **branch on every byte** during decoding — a significant cost on modern CPUs where branch misprediction penalties run 10-20 cycles.

BLIP takes a different approach: the first byte tells you **how many raw bytes follow**, and those bytes are a plain little-endian integer — decoded with a single load instruction, no per-byte branching, no shift-and-OR reassembly. For values 0-127, the first byte *is* the value (one branch, one mask, done). The trade-off is 1 extra byte for values in the 256-16383 range, which is acceptable in most real-world distributions where values cluster around either "small" (<128) or "large" (>16383).

Because the payload bytes are completely raw and untouched by the encoding (no continuation bits interleaved, no bit-scattering), they can represent **any interpretation**: unsigned integers, signed two's complement integers, IEEE floats, or even small fixed-size structures. The encoding is type-agnostic — the application decides how to interpret the L payload bytes.

As a bonus, the encoding has a natural **sentinel space** — values that *could* be encoded in 1 byte but are encoded in 2 are redundant, and those 128 overlong patterns can be reserved for type tags, version markers, or control codes without adding a separate type-tag field.

## Encoding

```
First byte:

  Bit 7 = 0: IMMEDIATE MODE
    ┌─┬─────────────────┐
    │0│     value       │  Bits 6-0 = value directly
    └─┴─────────────────┘  Range: 0-127. Total size: 1 byte.

  Bit 7 = 1: LENGTH-PREFIXED MODE
    ┌─┬─┬─┬─────────────┐
    │1│C│P│   L bits    │
    └─┴─┴─┴─────────────┘
    Bit 6 = C (continuation flag for L)
    Bit 5 = P (padded flag)

    ── When P = 0 (NORMAL): ──────────────────────────────
      Bits 4-0 = low 5 bits of L (range 0-31 inline)
      If C = 0: L is complete.
      If C = 1: following bytes extend L using standard
                varint continuation (bit 7 = continue,
                bits 6-0 = next 7 bits of L, LE order).
      Read L bytes as raw little-endian value. Done.

    ── When P = 1 (PADDED): ──────────────────────────────
      ┌─┬─┬─┬─┬─────────┐
      │1│C│1│I│  L bits  │
      └─┴─┴─┴─┴─────────┘
      Bit 4 = I (indirect/overflow flag)
      Bits 3-0 = low 4 bits of L (range 0-15 inline)
      If C = 0: L is complete.
      If C = 1: following bytes extend L (same continuation).
      Read L bytes as raw little-endian value.

      Then: skip 0 or more 0x00 bytes (padding).
      Then: read 2-byte PAD_END sentinel (0x81 0x00).

      If I = 0: value is the actual value (direct).
      If I = 1: value is a signed offset to another BLIP
                that holds the actual value (overflow).
                See "Padded BLIPs" section below.
```

### Bit budget summary

| Mode | Bits 7-0 | Inline L range | Notes |
|------|----------|----------------|-------|
| Immediate | `0_xxxxxxx` | N/A | Value IS the byte (0-127) |
| Normal | `1_C_0_LLLLL` | 0-31 (5 bits) | Common path, no padding overhead |
| Padded direct | `1_C_1_0_LLLL` | 0-15 (4 bits) | Followed by padding + PAD_END |
| Padded indirect | `1_C_1_1_LLLL` | 0-15 (4 bits) | Value = offset to real BLIP |

All inline L ranges are more than sufficient: L=8 covers u64/i64, L=15 covers u120, L=31 covers u248.

### Decoding pseudocode

```
fn decode_blip(stream) -> BlipResult:
    byte = stream.read_byte()

    // Immediate mode
    if byte & 0x80 == 0:
        return .{ .value = byte }

    // Length-prefixed mode
    padded   = (byte & 0x20) != 0
    indirect = padded and (byte & 0x10) != 0

    if padded:
        L = byte & 0x0F                     // 4 bits
        cont_shift = 4
    else:
        L = byte & 0x1F                     // 5 bits
        cont_shift = 5

    if byte & 0x40 != 0:                    // C = 1: more L bytes
        shift = cont_shift
        loop:
            next = stream.read_byte()
            L |= (next & 0x7F) << shift
            shift += 7
            if next & 0x80 == 0: break

    raw = stream.read_bytes(L)
    value = little_endian_to_int(raw, L)

    // Sentinel check (non-padded, L=1, value 0-127 = overlong)
    if not padded and L == 1 and 0 <= value and value < 128:
        return .{ .sentinel = value }

    // Padding consumption
    if padded:
        while stream.peek() == 0x00:
            stream.advance(1)
        assert stream.read_bytes(2) == [0x81, 0x00]   // PAD_END

    if indirect:
        return .{ .indirect_offset = value }   // signed offset to real BLIP
    else:
        return .{ .value = value }
```

### Encoding pseudocode

```
fn encode_blip(value, stream):
    if 0 <= value and value < 128:
        stream.write_byte(value)                       // immediate
        return

    L = byte_width(value)                              // minimum bytes for value

    if L < 32:
        stream.write_byte(0x80 | L)                    // C=0, P=0
    else:
        first = 0x80 | 0x40 | (L & 0x1F)              // C=1, P=0
        stream.write_byte(first)
        emit_varint_continuation(stream, L >> 5)

    stream.write_bytes(value_to_le_bytes(value, L))

fn encode_blip_padded(value, stream, budget):
    // budget = total pre-allocated bytes including header, value, padding, PAD_END
    L = byte_width(value)
    header_size = 1                                    // may grow with L continuation
    pad_end_size = 2
    padding = budget - header_size - L - pad_end_size

    if padding < 0:
        error("value exceeds padding budget")          // must re-emit container

    if L < 16:
        stream.write_byte(0x80 | 0x20 | L)            // C=0, P=1, I=0
    else:
        first = 0x80 | 0x40 | 0x20 | (L & 0x0F)      // C=1, P=1, I=0
        stream.write_byte(first)
        emit_varint_continuation(stream, L >> 4)
        // recalculate padding with actual header size

    stream.write_bytes(value_to_le_bytes(value, L))
    stream.write_bytes([0x00] * padding)               // padding
    stream.write_bytes([0x81, 0x00])                   // PAD_END
```

## Worked Examples

```
── Immediate ──
Value 0:       [0x00]                              1 byte
Value 42:      [0x2A]                              1 byte
Value 127:     [0x7F]                              1 byte

── Normal (P=0) ──
Value 128:     [0x81, 0x80]                        2 bytes  L=1
Value 200:     [0x81, 0xC8]                        2 bytes  L=1
Value 255:     [0x81, 0xFF]                        2 bytes  L=1
Value 256:     [0x82, 0x00, 0x01]                  3 bytes  L=2
Value 1000:    [0x82, 0xE8, 0x03]                  3 bytes  L=2
Value 50000:   [0x82, 0x50, 0xC3]                  3 bytes  L=2
Value 65535:   [0x82, 0xFF, 0xFF]                  3 bytes  L=2
Value 65536:   [0x83, 0x00, 0x00, 0x01]            4 bytes  L=3
Value 5000000: [0x83, 0x40, 0x4B, 0x4C]            4 bytes  L=3
Value 2^32-1:  [0x84, 0xFF, 0xFF, 0xFF, 0xFF]      5 bytes  L=4
Value 2^64-1:  [0x88, 0xFF×8]                      9 bytes  L=8

── Signed (two's complement, application-interpreted) ──
Value -1 (i8):   [0x81, 0xFF]                      2 bytes  L=1
Value -1 (i32):  [0x84, 0xFF, 0xFF, 0xFF, 0xFF]    5 bytes  L=4
Value -128 (i8): [0x81, 0x80]                       2 bytes  L=1
Value -129 (i16):[0x82, 0x7F, 0xFF]                 3 bytes  L=2

── Padded (P=1, I=0) with 4 bytes of padding ──
Value 500000:  [0xA3, 0x20, 0xA1, 0x07, 0x00, 0x00, 0x00, 0x00, 0x81, 0x00]
                ^P=1   ^^^ 3 bytes LE       ^^^^ 4× padding     ^^^ PAD_END
                I=0, L=3

── Padded indirect (P=1, I=1) ──
Offset -24:    [0xB1, 0xE8, 0x00, 0x81, 0x00]
                ^P=1   ^-24 as i8  ^pad  ^PAD_END
                I=1, L=1
               (signed offset from container start to real BLIP)
```

Note: Immediate mode (bit 7 = 0) can only represent unsigned 0-127. Negative values always use length-prefixed mode. The minimum L for a signed value is the smallest byte width whose two's complement range includes the value (e.g., -128 fits in i8 so L=1, -129 requires i16 so L=2).

## Sentinel Values

When a **non-padded** value in the range 0-127 is encoded in length-prefixed mode rather than immediate mode, the encoding is **overlong** — it uses more bytes than necessary. BLIP reserves these overlong encodings as **sentinels**: special markers that are syntactically distinct from any valid integer.

```
Sentinel byte pattern: 0x81 followed by 0x00-0x7F
  → 128 sentinel values, each exactly 2 bytes

These are distinguishable from valid length-prefixed integers because:
  - A valid L=1 encoding of value ≥ 128 has byte 2 in range 0x80-0xFF
  - A sentinel has byte 2 in range 0x00-0x7F (could have been immediate)
```

Encoders MUST use the shortest possible encoding for real values (canonical form). Decoders that encounter a non-padded overlong encoding MUST treat it as a sentinel, not as the integer value it would otherwise represent.

Padded BLIPs (P=1) with small values are NOT sentinels — they are legitimate padded values (the value really is small; it's just padded for streaming write purposes).

### Reserved sentinel assignments

```
0x81 0x00 = PAD_END    End of a padded BLIP's trailing padding.
                        Only appears after 0+ padding bytes (0x00)
                        following a padded BLIP's value.
0x81 0x01 - 0x81 0x7F  Available for application-defined types,
                        version markers, section delimiters, etc.
```

## Padded BLIPs

Padded BLIPs solve the **streaming write problem**: when emitting a binary structure sequentially, some values (offsets, lengths) cannot be known until the entire structure is laid out. A padded BLIP pre-allocates space that is later backfilled with the actual value.

### Structure

```
┌──────────────────────────────────────────────────────────────┐
│ BLIP header (P=1, I=0 or I=1)                                │
│ L value bytes (the actual or indirect value)                  │
│ 0x00 × N (padding, N ≥ 0)                                    │
│ 0x81 0x00 (PAD_END sentinel)                                  │
└──────────────────────────────────────────────────────────────┘
Total field size = header + L + N + 2
```

### Pre-allocation

The writer pre-allocates a fixed budget for the padded field. For example, with a 12-byte budget:

```
Initial (value unknown):
  [0xA0] [0x00×9] [0x81, 0x00]
   ^P=1, I=0, L=0  ^padding   ^PAD_END
   (L=0 means "no value yet")

Backfilled (value = 500000, needs L=3):
  [0xA3] [0x20, 0xA1, 0x07] [0x00×6] [0x81, 0x00]
   ^L=3   ^^^ value LE        ^pad     ^PAD_END
```

A 12-byte budget accommodates values up to 2^64 (L=8: 1 header + 8 value + 1 padding + 2 PAD_END).

### Overflow via Indirection

If the actual value exceeds what fits in the pre-allocated padding budget, the writer sets the **indirect flag** (I=1). The value bytes then contain a **signed offset** (from the containing container's start byte) to another BLIP that holds the actual value.

```
Padded field (I=1, value = offset 40 to scratch pool):
  [0xB1] [0x28] [0x00×7] [0x81, 0x00]
   ^P=1,  ^40    ^padding  ^PAD_END
    I=1,
    L=1

At container_start + 40:
  [0x84] [0xF0, 0x49, 0x02, 0x00]    ← normal BLIP, value = 150000
```

The indirect BLIP at the target location can itself be padded (and potentially indirect), forming an overflow chain. In practice, one hop suffices — the chain exists for formal completeness.

### When to Use Padded BLIPs

Padded BLIPs exist specifically for values that are written to a stream or file **before their final value is known**, in contexts where rewriting the container would be prohibitively expensive (e.g., multi-terabyte archives). They are a streaming-writer optimization, not a general encoding feature.

For in-memory construction (where the full structure is built in RAM and serialized once), padded BLIPs are unnecessary — the writer knows all values before emitting any bytes.

**The indirect overflow mechanism** is a theoretical correctness guarantee. In practice, generous pre-allocation (12 bytes covers offsets up to 2^64) makes overflow astronomically unlikely. The mechanism exists so that the spec is formally complete — no container of any size can be in a state where it cannot express a required offset. But implementations that never produce multi-hundred-terabyte containers MAY omit indirect overflow support and instead re-emit the container if padding is exceeded.

### Scratch Pool Convention

Containers that use padded BLIPs MAY reserve a **scratch pool** — a pre-allocated block of 0x00 bytes near the beginning of the container's value area. If a padded BLIP overflows, the indirect offset points into the scratch pool, where the actual value is written as a normal (non-padded) BLIP.

The scratch pool is a container-format convention, not a BLIP-level feature. See the BLIP Container Format spec for details.

## Offset and Length Convention

When BLIP integers represent offsets or lengths within a container format:

- **All offsets are measured from the start of the containing container** (the first byte of the container's Type sentinel). This is universal — it does not vary by container type.
- **Offsets MAY be negative** (signed two's complement) when pointing into a scratch pool or other pre-container data. The BLIP payload is type-agnostic, so signed offsets work natively.
- **Lengths are always non-negative** but use the same signed-capable encoding for consistency.
- **If containers shift** (e.g., during compaction or re-emission), all offsets within them must be recomputed.

This convention is defined here for consistency across all formats that use BLIP. Individual container format specs may add additional constraints.

## Comparison with Other Encodings

### LEB128 (Little-Endian Base 128)

Used by DWARF, WebAssembly, Android DEX, and many binary formats.

**Encoding:** Each byte carries 7 data bits (bits 6-0) and 1 continuation bit (bit 7). Bit 7 = 1 means more bytes follow; bit 7 = 0 means this is the last byte. Value is reconstructed by concatenating 7-bit groups in LE order.

```
LEB128 value 300:  [0xAC, 0x02]   →  0101100 ++ 0000010  →  0b100101100 = 300
BLIP value 300:    [0x82, 0x2C, 0x01]
```

**Pros of LEB128 over BLIP:**
- **1 byte smaller for values 128-16383** — the key advantage. LEB128 packs 14 data bits into 2 bytes; BLIP needs 3 bytes (1 header + 2 payload) for the same range.
- **Massive ecosystem adoption** — every DWARF parser, every Wasm runtime, every protobuf library already speaks LEB128.
- **Simpler spec** — one rule ("7 bits per byte, MSB = continue") vs BLIP's multiple modes.

**Pros of BLIP over LEB128:**
- **Faster decode for small values (0-127)** — both are 1 byte and 1 branch, but BLIP's decode is `return byte` while LEB128's is `return byte & 0x7F` (a mask that's optimized away on most CPUs, so effectively equivalent).
- **Faster decode for large values (128+)** — BLIP does 2 branches then a single native LE memory load. LEB128 does N branches (one per byte) plus N shift-and-OR operations. On modern CPUs where branch misprediction costs 10-20 cycles, this matters when decoding many integers.
- **Multi-byte values are raw LE** — no bit reassembly. On LE hardware (x86, ARM), `std.mem.readInt(u64, bytes, .little)` compiles to a single load instruction.
- **Signed integers for free** — payload bytes are raw, so two's complement just works (`readInt(i64, ...)` instead of `readInt(u64, ...)`). LEB128 requires a separate SLEB128 variant (DWARF) or ZigZag encoding (protobuf) because continuation bits are interleaved with data bits, making sign-extension complex.
- **Sentinel space** — 128 reserved overlong patterns for free. LEB128 also has overlong encodings but no standard defines what to do with them (most specs say "reject").
- **Bounded branch count** — BLIP decode has a maximum of 2 branches for any value (for the common case of L < 32). LEB128 branches once per byte, so a 64-bit value requires up to 10 branches.
- **Padding support** — built into the encoding for streaming writers. LEB128 has no equivalent.

**Cons of BLIP vs LEB128:**
- **1 byte larger for values 256-16383** — BLIP's main space penalty. In distributions where these mid-range values are common (e.g., Unicode codepoints, small packet lengths), this adds up.
- **Not yet battle-tested** — LEB128 has decades of implementations, fuzzing, edge-case discovery. BLIP is new.
- **More complex first-byte parsing** — multiple modes vs LEB128's uniform byte-at-a-time loop.

**When to prefer LEB128:** If your value distribution has many values in the 256-16383 range and you don't need sentinels or padding, LEB128 is more compact. Also if ecosystem compatibility matters (DWARF, Wasm, protobuf interop).

**When to prefer BLIP:** If your value distribution is bimodal (many small values <128 and some large values >16383, with few in between), BLIP is both more compact and faster to decode. Also if you want built-in sentinel/type-tag support or streaming write padding.

### VLQ (Variable-Length Quantity)

Used by MIDI file format and Git packfiles.

**Encoding:** Identical to LEB128 but **big-endian** — the most significant 7-bit group comes first. Continuation bit (bit 7) has the same meaning.

**Pros over BLIP:**
- Big-endian ordering allows lexicographic comparison of encoded values without decoding — encoded bytes sort in the same order as the values they represent.
- Same compactness as LEB128 (1 byte better for 256-16383 range).

**Cons vs BLIP:**
- Same branch-per-byte decode cost as LEB128.
- Big-endian payload requires byte-swapping on LE architectures (x86, ARM) even after reassembly from 7-bit groups.
- No sentinel space. No padding support.

**When to prefer VLQ:** When you need encoded values to sort lexicographically (e.g., B-tree keys, sorted file formats).

### Protocol Buffers Varint

Used by Google Protocol Buffers, gRPC, and many derived formats.

**Encoding:** Essentially LEB128 with one addition: signed integers use ZigZag encoding (`(n << 1) ^ (n >> 63)`) so that small negative values are also compact.

**Pros over BLIP:**
- Same compactness as LEB128.
- Enormous ecosystem: protobuf, gRPC, FlatBuffers, Cap'n Proto all use variants.

Note: Protobuf uses ZigZag encoding for signed integers because LEB128's continuation bits make sign-extension complex. BLIP doesn't need ZigZag — the raw LE payload supports two's complement natively.

**Cons vs BLIP:**
- Same decode performance characteristics as LEB128 (branch-per-byte, shift-and-OR reassembly).
- No sentinel space. No padding support.

**When to prefer Protobuf varint:** When interoperating with protobuf-based systems.

### ASN.1 BER/DER Length Encoding

Used by X.509 certificates, TLS, LDAP, SNMP, and most of the PKI/telecom world.

**Encoding:**
- Short form: byte < 0x80 → length = byte (range 0-127, 1 byte). Same as BLIP immediate mode.
- Long form: byte = 0x80 | N, where N = number of following length bytes (1-126). Then N bytes of length in **big-endian**.
- Indefinite form: byte = 0x80, length determined by end-of-contents marker.

BLIP is structurally similar to ASN.1 length encoding. Key differences:

| Aspect | ASN.1 BER/DER | BLIP |
|--------|---------------|------|
| Byte order of payload | Big-endian | Little-endian |
| Max L value | 126 (7 bits minus reserved 0x7F) | Unlimited (varint continuation) |
| Overlong encodings | DER forbids them; BER allows but discourages | Explicitly reserved as sentinels |
| Indefinite length | 0x80 = start, 0x00 0x00 = end | Not supported (use padded BLIP instead) |
| Standalone use | Always part of TLV (Type-Length-Value) | Self-contained integer encoding |
| Padding/streaming | Not supported | Built-in padded mode |

**Pros of ASN.1 over BLIP:**
- Decades of implementation experience, extensive test vectors, well-understood security properties.
- Part of a complete TLV system (Type + Length + Value) — BLIP is just the "L" part.
- Indefinite-length form allows streaming without knowing total size upfront.

**Cons of ASN.1 vs BLIP:**
- Big-endian payload — extra byte-swap on LE hardware.
- L limited to 126 (sufficient for most uses but not truly unlimited).
- DER's prohibition of overlong encodings means no sentinel space.
- The full ASN.1 TLV system is notoriously complex; BLIP is just an integer encoding.

**When to prefer ASN.1:** When interoperating with X.509, TLS, or other ASN.1-based protocols. When you need a full TLV framework, not just integer encoding.

**When to prefer BLIP:** When you want a standalone integer encoding with native LE decode performance, unlimited integer size, built-in sentinels, and streaming write padding. BLIP can be thought of as "ASN.1 length encoding, but LE, with unlimited L, overlong encodings repurposed as sentinels, and padding for streaming."

### SQLite Varint

Used internally by SQLite for record headers and page pointers.

**Encoding:** A Huffman-inspired scheme with multiple thresholds:
- Byte 1 in 0-240: value = byte (1 byte)
- Byte 1 = 241-248: value = 240 + 256 × (byte1 - 241) + byte2 (2 bytes)
- Byte 1 = 249: value = 2288 + 256 × byte2 + byte3 (3 bytes)
- Byte 1 = 250-255: value encoded in 3-8 following bytes as big-endian

**Pros over BLIP:**
- **Extremely compact** — immediate mode covers 0-240 (vs BLIP's 0-127), squeezing an extra 113 values into 1 byte.
- **No wasted bits** — thresholds are tuned to minimize average encoding size for SQLite's value distribution.
- More compact than both BLIP and LEB128 for values 128-240.

**Cons vs BLIP:**
- **Complex decode** — multiple threshold checks (`if < 241`, `if < 249`, `if == 249`, etc.) with different formulas per range. Hard to get right, hard to audit.
- **Big-endian payload** for larger values — byte-swap needed on LE hardware.
- **Fixed maximum** — 9 bytes encodes up to 2^64. Not unlimited (though 2^64 suffices for all practical uses).
- **No sentinel space** — all byte patterns are valid values.
- **No padding support** — no streaming write mechanism.
- **Asymmetric ranges** make mental arithmetic difficult when debugging hex dumps.

**When to prefer SQLite varint:** When you're implementing a database engine and every byte matters at scale, and you can tolerate the decode complexity. When your value distribution peaks below 240.

**When to prefer BLIP:** When decode speed matters more than squeezing out 113 extra values in the immediate range. When you need sentinels, padding, or unlimited integer width. When implementation simplicity and auditability are priorities.

### UTF-8 Prefix Coding

Not a general integer encoding, but worth mentioning because BLIP shares the "first byte tells you the length" philosophy.

**Encoding:** Leading bits of byte 1 determine total byte count: `0xxxxxxx` = 1 byte, `110xxxxx` = 2, `1110xxxx` = 3, `11110xxx` = 4. Continuation bytes always start with `10xxxxxx`.

**Pros over BLIP:**
- **Self-synchronizing** — you can detect your position within a multi-byte sequence from any byte. If you land on a continuation byte (`10xxxxxx`), scan forward to find the next start byte. BLIP (and LEB128) cannot do this.
- **Battle-tested** — billions of devices decode UTF-8 daily.

**Cons vs BLIP:**
- **Limited to 21 bits** (Unicode range) — not a general-purpose integer encoding.
- **Continuation bytes waste 2 bits each** (the `10` prefix) — less dense than BLIP's raw LE payload.
- **Not little-endian** — data bits are big-endian across bytes.
- **No sentinel space** — overlong encodings are explicitly invalid per the Unicode standard.
- **No padding support.**

**When to prefer UTF-8:** When you need self-synchronizing properties (e.g., text streams where you might seek to arbitrary byte positions). When encoding Unicode codepoints.

**When to prefer BLIP:** For everything else.

### Prefix Varint (PrefixVarint)

Used by some Google internal systems and proposed as a successor to LEB128.

**Encoding:** Count leading 1-bits in the first byte to determine how many additional bytes follow. Remaining bits of the first byte plus all bits of the following bytes form the value.

```
0xxxxxxx                          → 1 byte,  7 bits (0-127)
10xxxxxx xxxxxxxx                 → 2 bytes, 14 bits (0-16383)
110xxxxx xxxxxxxx xxxxxxxx        → 3 bytes, 21 bits
...
11111111 xxxxxxxx × 8             → 9 bytes, 64 bits
```

**Pros over BLIP:**
- **Single branch to determine length** — count leading ones (some CPUs have `clz`/`ctz` instructions for this).
- **Same compactness as LEB128** for all value ranges — doesn't lose the byte at 256-16383.
- **No shift-and-OR per byte** — payload bits span the boundary between first byte and continuation, but can be extracted with a shift and a wide load.

**Cons vs BLIP:**
- **Payload straddles byte boundary** — bits 6-0 of byte 1 are the high bits, remaining bytes are the low bits. This requires a shift and OR to combine (vs BLIP's clean "first byte is header, remaining bytes are raw LE").
- **No sentinel space** — all bit patterns encode valid values.
- **No padding support.**
- **Not widely adopted** — proposed but not standardized or broadly deployed.
- **Hardware `clz` dependency** — the "single branch" advantage depends on CPU instructions that aren't universally fast.

**When to prefer PrefixVarint:** When you need LEB128's compactness without its per-byte branching, and don't need sentinels or padding.

**When to prefer BLIP:** When your multi-byte values benefit from being raw LE (single load instruction), and when sentinels or padding matter for format extensibility and streaming writes.

## Summary Comparison Table

| Encoding | 0-127 | 128-255 | 256-16383 | 16384-65535 | Branches | Raw LE | Sentinels | Unlimited | Signed | Padding |
|----------|-------|---------|-----------|-------------|----------|--------|-----------|-----------|--------|---------|
| **BLIP** | 1B | 2B | 3B | 3B | 1-2 | Yes | 128 free | Yes | Yes | Yes |
| LEB128 | 1B | 2B | **2B** | 3B | N/byte | No | No* | Yes | SLEB128 | No |
| VLQ | 1B | 2B | **2B** | 3B | N/byte | No | No | Yes | No | No |
| Protobuf | 1B | 2B | **2B** | 3B | N/byte | No | No | Yes† | ZigZag | No |
| ASN.1 | 1B | 2B | 3B | 3B | 2 | No (BE) | No‡ | No (L≤126) | Yes | No |
| SQLite | **1B (0-240)** | **1B** | **2B** | 3B | 3-5 | No (BE) | No | No (≤64b) | No | No |
| PrefixVarint | 1B | 2B | **2B** | 3B | 1 (clz) | Partial | No | No (≤64b) | No | No |
| UTF-8 | 1B | 2B | 3B | 3B | 1 | No (BE) | No | No (≤21b) | N/A | No |

\* LEB128 has overlong encodings but no standard assigns them meaning; most specs say "reject."
† Protobuf limits to 10 bytes (64-bit signed via ZigZag).
‡ DER explicitly forbids overlong; BER allows but discourages.

## Properties

| Property | BLIP |
|----------|------|
| Byte order of payload | Little-endian |
| Maximum value | Unlimited (L is varint-encoded) |
| Self-synchronizing | No (same as LEB128) |
| Canonical form | Shortest encoding required; non-padded overlong = sentinel |
| Signed integers | Yes — payload bytes are raw two's complement (no ZigZag needed) |
| Streamable | Yes (decode without knowing total message length) |
| Padding support | Yes — padded mode with optional indirect overflow |
| Random-access friendly | No (must parse sequentially within a BLIP stream) |

## Implementation Notes

### Decode fast path (most common)

On LE hardware, the entire decode for values 0-127 is:
```
if (byte & 0x80 == 0) return byte;
```

For normal (non-padded) values 128+ with L < 32:
```
L = byte & 0x1F;
return std.mem.readInt(u64, buffer[1..][0..L], .little);
```

Two branches, one memory load. The L continuation path (L ≥ 32) and the padded path exist for completeness but are rarely exercised — L=8 already covers 2^64.

### Sentinel detection

After decoding a 2-byte non-padded sequence with L=1:
```
if (value < 128) → this is a sentinel, not a regular value
```

This check is only needed when the application uses sentinels. Formats that don't use sentinels can skip it and treat overlong encodings as their face value (though this is discouraged for forward compatibility).

### Padded BLIP detection

Check bit 5 of the first byte:
```
if (byte & 0x20 != 0) → this is a padded BLIP; consume padding + PAD_END after value
```

Only relevant in contexts where padded BLIPs are expected (offset/length fields in container formats with streaming write support).

## License

MIT — see [LICENSE](LICENSE).
