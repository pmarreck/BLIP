# BLIP — Concise Spec

A self-describing variable-length integer encoding. Per-value endianness; signedness is a payload-level concern.

## Encoding

```
First byte:

  Bit 7 = 0  IMMEDIATE
    0_xxxxxxx                       value = byte (0-127)

  Bit 7 = 1  LENGTH-PREFIXED
    1_E_C_LLLLL                     L_low5 = bits 4-0
    bit 6 = E (0=LE, 1=BE)          endianness of the payload
    bit 5 = C                        0 = L is complete (0-31)
                                     1 = continuation bytes follow

  Continuation (when C=1):
    Standard varint, LE order, 7 bits per byte:
      bit 7 = 1   more bytes follow
      bit 7 = 0   final byte
      bits 6-0    next 7 bits of L
    L = L_low5 | (cont_byte_0 & 0x7F) << 5
              | (cont_byte_1 & 0x7F) << 12 | ...

After the header, read exactly L payload bytes in the specified
endianness.  No type tag, no signedness flag — payload is raw bytes.
```

## Sentinels

A length-prefixed encoding with `L=1, E=0` whose payload byte is `< 0x80` is **overlong** (the value would have fit in immediate mode). Such encodings are reserved as **sentinels**:

```
0x81 0x00 .. 0x81 0x7B    application-defined sentinels
0x81 0x7C                 TRUE    (scalar, restricted positions)
0x81 0x7D                 FALSE   (scalar, restricted positions)
0x81 0x7E                 NIL     (scalar, restricted positions)
0x81 0x7F                 reserved (BLIP Container Format VAL sigil)
```

Encoders MUST emit canonical (shortest) form for real values. Decoders MUST treat overlong L=1 as a sentinel, not its face-value integer. TRUE/FALSE/NIL are accepted only at positions where the surrounding format explicitly permits a scalar in lieu of an integer.

## Decode

```
fn decode(buf) -> {value, endian}:
    b = buf[0]
    if b < 0x80:
        return {value: b, endian: LE}            # immediate
    endian = (b >> 6) & 1                        # 0=LE, 1=BE
    L = b & 0x1F
    pos = 1
    if b & 0x20:                                  # continuation
        shift = 5
        while True:
            n = buf[pos]; pos += 1
            L |= (n & 0x7F) << shift
            shift += 7
            if not (n & 0x80): break
    raw = buf[pos : pos+L]
    value = bytes_to_int(raw, endian)
    if L == 1 and value < 128 and endian == LE:
        return {sentinel: value}
    return {value, endian}
```

## Encode (LE; pass `endian=BE` to flip bit 6)

```
fn encode(value, endian=LE) -> bytes:
    if 0 <= value < 128:
        return [value]                           # immediate
    L = byte_width(value)                        # min bytes to hold value
    e = (endian == BE) ? 0x40 : 0x00
    if L < 32:
        head = [0x80 | e | L]
    else:
        head = [0x80 | e | 0x20 | (L & 0x1F)]
        L_rem = L >> 5
        while L_rem >= 128:
            head.append(0x80 | (L_rem & 0x7F))
            L_rem >>= 7
        head.append(L_rem & 0x7F)
    return head + int_to_bytes(value, L, endian)
```

## Signedness

The L payload bytes are raw two's complement. Signedness is the application's interpretation of the same bytes. The minimum L for a signed value is the smallest byte width whose two's complement range contains it (`-128` → L=1, `-129` → L=2). No SLEB128/ZigZag distinction; signed and unsigned share an encoding.

## Worked examples

```
Immediate
  0          [0x00]
  127        [0x7F]

Length-prefixed, LE (E=0)
  128        [0x81, 0x80]
  256        [0x82, 0x00, 0x01]
  65535      [0x82, 0xFF, 0xFF]
  65536      [0x83, 0x00, 0x00, 0x01]
  2^64-1     [0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

Length-prefixed, BE (E=1)
  256        [0xC2, 0x01, 0x00]
  65535      [0xC2, 0xFF, 0xFF]
  65536      [0xC3, 0x01, 0x00, 0x00]

Signed (application-interpreted)
  -1   (i8)  [0x81, 0xFF]
  -128 (i8)  [0x81, 0x80]
  -129 (i16) [0x82, 0x7F, 0xFF]

Sentinels (overlong L=1, E=0)
  TRUE       [0x81, 0x7C]
  FALSE      [0x81, 0x7D]
  NIL        [0x81, 0x7E]
```

## Invariants

1. Encoders MUST emit shortest form for real values; only sentinels are overlong.
2. Sentinels (`0x81 NN`, `NN < 0x80`) are always emitted with E=0.
3. The E bit is set per-value; a single stream may freely mix LE and BE BLIPs.
4. There is no maximum L — continuation supports arbitrary precision.
5. There is no defined behavior for malformed input; decoders MAY reject or recover at their discretion, but MUST NOT silently produce a value that doesn't match the encoded bytes.
