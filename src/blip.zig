const std = @import("std");

// BLIP: Byte Length Integer Prefix encoding
// See BLIP_SPEC.md for the full specification.

pub const name = "BLIP";

pub const Endian = enum(u1) {
    little = 0,
    big = 1,
};

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
    endian: Endian = .little,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Returns the minimum number of bytes needed to represent `value` as an unsigned
/// little-endian integer. Returns 1 for values 1-255, 2 for 256-65535, etc.
/// For value 0, returns 1 (a single zero byte).
fn minBytes(value: u64) usize {
    if (value == 0) return 1;
    // Number of bits needed, divided by 8, rounded up
    const bits = 64 - @clz(value);
    return (bits + 7) / 8;
}

/// Returns the number of bytes that encode(value) would produce,
/// without actually writing to a buffer.
pub fn encodedSize(value: u64) usize {
    if (value < 128) return 1; // immediate mode
    return 1 + minBytes(value); // header byte + L value bytes
}

/// Encode a u64 value in BLIP format (little-endian payload). Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    return encodeEndian(value, buf, .little);
}

/// Encode a u64 value in BLIP format with big-endian payload (lexicographically sortable).
pub fn encodeBE(value: u64, buf: []u8) Error!usize {
    return encodeEndian(value, buf, .big);
}

/// Encode a u64 value in BLIP format with specified endianness. Returns number of bytes written.
/// Header layout for length-prefixed values:
///   Bit 7: 1 (length-prefixed mode)
///   Bit 6: E (0=LE, 1=BE)
///   Bit 5: C (continuation flag for L)
///   Bits 4-0: L (payload length, 0-31)
pub fn encodeEndian(value: u64, buf: []u8, endian: Endian) Error!usize {
    // Immediate mode: values 0-127 fit in a single byte (endianness irrelevant)
    if (value < 128) {
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }

    // Length-prefixed mode
    const L = minBytes(value);
    const e_bit: u8 = @as(u8, @intFromEnum(endian)) << 6;

    // Encode L into header byte(s)
    var pos: usize = 0;
    if (L < 32) {
        // Single header byte: bit 7 = 1, bit 6 = E, bit 5 = 0 (no continuation), bits 4-0 = L
        if (buf.len < 1 + L) return Error.BufferTooSmall;
        buf[0] = 0x80 | e_bit | @as(u8, @intCast(L));
        pos = 1;
    } else {
        // L >= 32: use continuation encoding for L
        // First byte: bit 7 = 1, bit 6 = E, bit 5 = 1 (continuation), bits 4-0 = low 5 bits of L
        const first: u8 = 0x80 | e_bit | 0x20 | @as(u8, @intCast(L & 0x1F));
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = first;
        pos = 1;

        var remaining = L >> 5;
        while (remaining >= 128) {
            if (pos >= buf.len) return Error.BufferTooSmall;
            buf[pos] = 0x80 | @as(u8, @intCast(remaining & 0x7F));
            pos += 1;
            remaining >>= 7;
        }
        if (pos >= buf.len) return Error.BufferTooSmall;
        buf[pos] = @intCast(remaining & 0x7F); // final L byte (bit 7 = 0)
        pos += 1;

        if (buf.len < pos + L) return Error.BufferTooSmall;
    }

    // Write raw value in the specified byte order.
    //
    // Fast path (most callers): if the buffer has at least 8 bytes after the
    // header, do a single u64 store.  Trailing bytes beyond L are overwritten
    // with garbage but we return only `pos + L`, so the caller never sees them
    // (and the next BLIP write will overwrite them anyway).
    //
    // Slow path: fall back to a per-byte loop only when at the end of a small
    // buffer.  Replaces an 8-way unrolled loop with branched per-byte stores
    // (visible in LLVM IR) by a single 64-bit store on the hot path.
    const tail = buf[pos..];
    if (tail.len >= 8) {
        switch (endian) {
            .little => std.mem.writeInt(u64, tail[0..8], value, .little),
            .big => std.mem.writeInt(u64, tail[0..8], value << @intCast((8 - L) * 8), .big),
        }
    } else {
        var val = value;
        switch (endian) {
            .little => {
                for (0..L) |i| {
                    buf[pos + i] = @intCast(val & 0xFF);
                    val >>= 8;
                }
            },
            .big => {
                var i: usize = L;
                while (i > 0) {
                    i -= 1;
                    buf[pos + i] = @intCast(val & 0xFF);
                    val >>= 8;
                }
            },
        }
    }

    return pos + L;
}

/// Encode a value as a sentinel (overlong encoding). Value must be 0-127.
/// This encodes using L=1 length-prefixed mode instead of immediate mode.
/// Sentinels are always LE (E=0): header = 0x81 (bit7=1, E=0, C=0, L=1).
pub fn encodeSentinel(value: u7, buf: []u8) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = 0x81; // bit 7 = 1, E = 0, C = 0, L = 1
    buf[1] = @intCast(value);
    return 2;
}

/// Decode a BLIP-encoded value from a buffer.
/// Automatically detects endianness from the E bit in the header.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;

    const first = buf[0];

    // Immediate mode: bit 7 = 0 (endianness irrelevant for single byte)
    if (first & 0x80 == 0) {
        return DecodeResult{
            .value = first,
            .bytes_read = 1,
        };
    }

    // Length-prefixed mode
    // Bit 6: E (endianness), Bit 5: C (continuation), Bits 4-0: L
    const endian: Endian = @enumFromInt((first >> 6) & 1);
    var L: usize = first & 0x1F; // low 5 bits
    var header_bytes: usize = 1;

    // Check continuation flag (bit 5)
    if (first & 0x20 != 0) {
        // C = 1: more L bytes follow
        var shift: u6 = 5;
        while (true) {
            if (header_bytes >= buf.len) return Error.UnexpectedEndOfInput;
            const next = buf[header_bytes];
            header_bytes += 1;

            L |= @as(usize, next & 0x7F) << shift;
            if (shift > 60) {
                // Overflow protection for shift
                if (next & 0x80 != 0) return Error.Overflow;
            }
            if (next & 0x80 == 0) break; // last L byte
            shift +|= 7; // saturating add to prevent overflow
        }
    }

    // Read L value bytes
    if (buf.len < header_bytes + L) return Error.UnexpectedEndOfInput;

    if (L == 0) {
        return DecodeResult{
            .value = 0,
            .bytes_read = header_bytes,
            .endian = endian,
        };
    }

    if (L > 8) return Error.Overflow; // Can't fit in u64

    // Read value bytes according to endianness.
    //
    // Fast path: if there are 8 bytes available from header_bytes, do a single
    // u64 load and mask off the upper (8 - L) bytes.  Replaces an 8-way
    // unrolled byte loop with two instructions (load + and).
    //
    // Slow path: fall back to per-byte assembly only at end-of-buffer.
    const tail = buf[header_bytes..];
    var value: u64 = 0;
    if (tail.len >= 8) {
        // Branchless mask via shift-shift.  For L in [1, 8], shift_bits in [0, 56].
        // L=8 → shift=0 → no-op; L=1 → shift=56 → keeps low 8 bits.
        const shift_bits: u6 = @intCast((8 - L) * 8);
        switch (endian) {
            .little => {
                const raw = std.mem.readInt(u64, tail[0..8], .little);
                value = (raw << shift_bits) >> shift_bits;
            },
            .big => {
                const raw = std.mem.readInt(u64, tail[0..8], .big);
                value = raw >> shift_bits;
            },
        }
    } else {
        switch (endian) {
            .little => {
                for (0..L) |i| {
                    value |= @as(u64, buf[header_bytes + i]) << @intCast(i * 8);
                }
            },
            .big => {
                for (0..L) |i| {
                    value = (value << 8) | @as(u64, buf[header_bytes + i]);
                }
            },
        }
    }

    return DecodeResult{
        .value = value,
        .bytes_read = header_bytes + L,
        .endian = endian,
    };
}

/// Returns true if the encoded bytes are a sentinel (overlong encoding).
/// A sentinel is a 2-byte sequence where byte 0 = 0x81 (L=1) and byte 1 < 0x80
/// (value that could have been encoded in immediate mode).
pub fn isSentinel(buf: []const u8) bool {
    if (buf.len < 2) return false;
    // Must be length-prefixed with L=1 (0x81) and value byte < 128
    return buf[0] == 0x81 and buf[1] < 0x80;
}

/// Returns the endianness of a BLIP-encoded value by reading bit 6 of the header.
/// Returns null for immediate values (single byte, endianness not applicable).
/// Returns null for empty buffers.
pub fn endianOf(buf: []const u8) ?Endian {
    if (buf.len == 0) return null;
    if (buf[0] & 0x80 == 0) return null; // immediate
    return @enumFromInt((buf[0] >> 6) & 1);
}

// ---------------------------------------------------------------------------
// BLIP Spec v1.2 — Scalar sentinels (NIL / TRUE / FALSE)
//
// Reserved 2-byte BLIP sentinels at the top of the sentinel range, used to
// represent nil / boolean values in attribute positions where the surrounding
// format explicitly permits a scalar sentinel (see SEG attribute in
// BLIP_WIRE_SPEC.md).  Restricted-position rule: callers MUST use
// decodeScalar() only at positions whose spec allows a sentinel; integer-only
// positions continue to use decode().
// ---------------------------------------------------------------------------

/// 2-byte sentinel marking the boolean TRUE value.
pub const SCALAR_TRUE_BYTES: [2]u8 = .{ 0x81, 0x7C };
/// 2-byte sentinel marking the boolean FALSE value.
pub const SCALAR_FALSE_BYTES: [2]u8 = .{ 0x81, 0x7D };
/// 2-byte sentinel marking the NIL value.
pub const SCALAR_NIL_BYTES: [2]u8 = .{ 0x81, 0x7E };

/// A BLIP scalar value. Used by decoders/encoders at positions that explicitly
/// permit nil/bool sentinels (e.g., the N field of the SEG attribute).
pub const Scalar = union(enum) {
    integer: u64,
    nil,
    boolean: bool,
};

pub const ScalarResult = struct {
    scalar: Scalar,
    bytes_read: usize,
};

/// Decode a BLIP value at a position that may be NIL, TRUE, FALSE, or an integer.
/// Other length-prefixed sentinels (0x81 0x00-0x7B and 0x7F) are surfaced as their
/// integer face value here; their interpretation is the caller's responsibility
/// (e.g., LP-envelope parsers treat 0x7F as the VAL sigil contextually, not via
/// this function).
pub fn decodeScalar(buf: []const u8) Error!ScalarResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;
    if (buf.len >= 2 and buf[0] == 0x81) {
        switch (buf[1]) {
            0x7C => return ScalarResult{ .scalar = .{ .boolean = true }, .bytes_read = 2 },
            0x7D => return ScalarResult{ .scalar = .{ .boolean = false }, .bytes_read = 2 },
            0x7E => return ScalarResult{ .scalar = .nil, .bytes_read = 2 },
            else => {},
        }
    }
    const r = try decode(buf);
    return ScalarResult{ .scalar = .{ .integer = r.value }, .bytes_read = r.bytes_read };
}

/// Encode a BLIP scalar value (integer, nil, or boolean) into `buf`.
/// Returns number of bytes written. nil/bool always emit 2-byte canonical form.
pub fn encodeScalar(scalar: Scalar, buf: []u8) Error!usize {
    switch (scalar) {
        .integer => |v| return encode(v, buf),
        .nil => {
            if (buf.len < 2) return Error.BufferTooSmall;
            buf[0] = SCALAR_NIL_BYTES[0];
            buf[1] = SCALAR_NIL_BYTES[1];
            return 2;
        },
        .boolean => |b| {
            if (buf.len < 2) return Error.BufferTooSmall;
            const bytes = if (b) SCALAR_TRUE_BYTES else SCALAR_FALSE_BYTES;
            buf[0] = bytes[0];
            buf[1] = bytes[1];
            return 2;
        },
    }
}

/// Returns the encoded size of a Scalar without writing anything.
pub fn encodedScalarSize(scalar: Scalar) usize {
    return switch (scalar) {
        .integer => |v| encodedSize(v),
        .nil, .boolean => 2,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Helper: encode a value and return the bytes as a slice
fn encodeToSlice(value: u64, buf: []u8) []const u8 {
    const n = encode(value, buf) catch unreachable;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Spec Worked Examples — exact byte sequences
// ---------------------------------------------------------------------------

test "encode value 0 = [0x00] immediate" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "encode value 42 = [0x2A] immediate" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(42, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x2A}, result);
}

test "encode value 127 = [0x7F] immediate" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "encode value 128 = [0x81, 0x80] L=1" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, result);
}

test "encode value 200 = [0x81, 0xC8] L=1" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(200, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xC8 }, result);
}

test "encode value 255 = [0x81, 0xFF] L=1" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(255, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, result);
}

test "encode value 256 = [0x82, 0x00, 0x01] L=2" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(256, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x01 }, result);
}

test "encode value 1000 = [0x82, 0xE8, 0x03] L=2" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xE8, 0x03 }, result);
}

test "encode value 50000 = [0x82, 0x50, 0xC3] L=2" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(50000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x50, 0xC3 }, result);
}

test "encode value 65535 = [0x82, 0xFF, 0xFF] L=2" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65535, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xFF, 0xFF }, result);
}

test "encode value 65536 = [0x83, 0x00, 0x00, 0x01] L=3" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65536, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x00, 0x00, 0x01 }, result);
}

test "encode value 5000000 = [0x83, 0x40, 0x4B, 0x4C] L=3" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(5000000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x40, 0x4B, 0x4C }, result);
}

test "encode value 2^32-1 = [0x84, 0xFF, 0xFF, 0xFF, 0xFF] L=4" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x84, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

test "encode value 2^64-1 = [0x88, 0xFF x8] L=8" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

// ---------------------------------------------------------------------------
// Decode spec worked examples
// ---------------------------------------------------------------------------

test "decode value 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "decode value 42 from [0x2A]" {
    const result = try decode(&[_]u8{0x2A});
    try testing.expectEqual(@as(u64, 42), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "decode value 127 from [0x7F]" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "decode value 128 from [0x81, 0x80]" {
    const result = try decode(&[_]u8{ 0x81, 0x80 });
    try testing.expectEqual(@as(u64, 128), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "decode value 200 from [0x81, 0xC8]" {
    const result = try decode(&[_]u8{ 0x81, 0xC8 });
    try testing.expectEqual(@as(u64, 200), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "decode value 255 from [0x81, 0xFF]" {
    const result = try decode(&[_]u8{ 0x81, 0xFF });
    try testing.expectEqual(@as(u64, 255), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "decode value 256 from [0x82, 0x00, 0x01]" {
    const result = try decode(&[_]u8{ 0x82, 0x00, 0x01 });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "decode value 1000 from [0x82, 0xE8, 0x03]" {
    const result = try decode(&[_]u8{ 0x82, 0xE8, 0x03 });
    try testing.expectEqual(@as(u64, 1000), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "decode value 50000 from [0x82, 0x50, 0xC3]" {
    const result = try decode(&[_]u8{ 0x82, 0x50, 0xC3 });
    try testing.expectEqual(@as(u64, 50000), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "decode value 65535 from [0x82, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0x82, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 65535), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "decode value 65536 from [0x83, 0x00, 0x00, 0x01]" {
    const result = try decode(&[_]u8{ 0x83, 0x00, 0x00, 0x01 });
    try testing.expectEqual(@as(u64, 65536), result.value);
    try testing.expectEqual(@as(usize, 4), result.bytes_read);
}

test "decode value 5000000 from [0x83, 0x40, 0x4B, 0x4C]" {
    const result = try decode(&[_]u8{ 0x83, 0x40, 0x4B, 0x4C });
    try testing.expectEqual(@as(u64, 5000000), result.value);
    try testing.expectEqual(@as(usize, 4), result.bytes_read);
}

test "decode value 2^32-1 from [0x84, 0xFF, 0xFF, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0x84, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "decode value 2^64-1 from [0x88, 0xFF x8]" {
    const result = try decode(&[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 9), result.bytes_read);
}

// ---------------------------------------------------------------------------
// Roundtrip tests: encode then decode, verify value matches
// ---------------------------------------------------------------------------

test "roundtrip all spec values" {
    const values = [_]u64{
        0,
        1,
        42,
        127,
        128,
        200,
        255,
        256,
        1000,
        50000,
        65535,
        65536,
        5000000,
        0xFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
    };
    var buf: [16]u8 = undefined;
    for (values) |value| {
        const n = try encode(value, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

test "roundtrip powers of 2" {
    var buf: [16]u8 = undefined;
    var value: u64 = 1;
    for (0..64) |_| {
        const n = try encode(value, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
        value *|= 2; // saturating multiply
    }
}

test "roundtrip boundary values" {
    const values = [_]u64{
        0,
        1,
        126,
        127,
        128,
        129,
        254,
        255,
        256,
        257,
        0x3FFF, // 16383
        0x4000, // 16384
        0xFFFE,
        0xFFFF,
        0x10000,
        0xFFFFFE,
        0xFFFFFF,
        0x1000000,
        0xFFFFFFFE,
        0xFFFFFFFF,
        0x100000000,
        0xFFFFFFFFFFFFFFFE,
        0xFFFFFFFFFFFFFFFF,
    };
    var buf: [16]u8 = undefined;
    for (values) |value| {
        const n = try encode(value, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

// ---------------------------------------------------------------------------
// Sentinel tests
// ---------------------------------------------------------------------------

test "isSentinel: 0x81 0x00 is sentinel" {
    try testing.expect(isSentinel(&[_]u8{ 0x81, 0x00 }));
}

test "isSentinel: 0x81 0x7F is sentinel" {
    try testing.expect(isSentinel(&[_]u8{ 0x81, 0x7F }));
}

test "isSentinel: 0x81 0x80 is NOT sentinel (valid L=1 encoding of 128)" {
    try testing.expect(!isSentinel(&[_]u8{ 0x81, 0x80 }));
}

test "isSentinel: 0x81 0xFF is NOT sentinel (valid L=1 encoding of 255)" {
    try testing.expect(!isSentinel(&[_]u8{ 0x81, 0xFF }));
}

test "isSentinel: immediate value is NOT sentinel" {
    try testing.expect(!isSentinel(&[_]u8{0x00}));
    try testing.expect(!isSentinel(&[_]u8{0x7F}));
}

test "isSentinel: empty buffer is NOT sentinel" {
    try testing.expect(!isSentinel(&[_]u8{}));
}

test "isSentinel: all 128 sentinel values" {
    for (0..128) |i| {
        const sentinel_buf = [_]u8{ 0x81, @intCast(i) };
        try testing.expect(isSentinel(&sentinel_buf));
    }
}

test "encodeSentinel roundtrip" {
    var buf: [16]u8 = undefined;
    for (0..128) |i| {
        const n = try encodeSentinel(@intCast(i), &buf);
        try testing.expectEqual(@as(usize, 2), n);
        try testing.expect(isSentinel(buf[0..n]));
        // Decoding a sentinel gives the face value
        const result = try decode(buf[0..n]);
        try testing.expectEqual(@as(u64, i), result.value);
        try testing.expectEqual(@as(usize, 2), result.bytes_read);
    }
}

// ---------------------------------------------------------------------------
// Edge case: errors
// ---------------------------------------------------------------------------

test "decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "decode truncated length-prefixed returns UnexpectedEndOfInput" {
    // Header says L=2 but only 1 value byte follows
    const result = decode(&[_]u8{ 0x82, 0x00 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "decode truncated L=8 returns UnexpectedEndOfInput" {
    // Header says L=8 but only 4 value bytes follow
    const result = decode(&[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "encode buffer too small for immediate" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "encode buffer too small for length-prefixed" {
    var buf: [1]u8 = undefined;
    const result = encode(200, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "encode buffer too small for L=2" {
    var buf: [2]u8 = undefined;
    const result = encode(256, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

// ---------------------------------------------------------------------------
// minBytes tests
// ---------------------------------------------------------------------------

test "minBytes" {
    try testing.expectEqual(@as(usize, 1), minBytes(0));
    try testing.expectEqual(@as(usize, 1), minBytes(1));
    try testing.expectEqual(@as(usize, 1), minBytes(127));
    try testing.expectEqual(@as(usize, 1), minBytes(128));
    try testing.expectEqual(@as(usize, 1), minBytes(255));
    try testing.expectEqual(@as(usize, 2), minBytes(256));
    try testing.expectEqual(@as(usize, 2), minBytes(1000));
    try testing.expectEqual(@as(usize, 2), minBytes(50000));
    try testing.expectEqual(@as(usize, 2), minBytes(65535));
    try testing.expectEqual(@as(usize, 3), minBytes(65536));
    try testing.expectEqual(@as(usize, 3), minBytes(5000000));
    try testing.expectEqual(@as(usize, 4), minBytes(0xFFFFFFFF));
    try testing.expectEqual(@as(usize, 5), minBytes(0x100000000));
    try testing.expectEqual(@as(usize, 8), minBytes(0xFFFFFFFFFFFFFFFF));
}

// ---------------------------------------------------------------------------
// L=0 edge case (length-prefixed with zero payload bytes)
// ---------------------------------------------------------------------------

test "decode L=0 length-prefixed gives value 0" {
    // 0x80 = bit 7 set, C=0, L=0 -- zero payload bytes = value 0
    const result = try decode(&[_]u8{0x80});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

// ---------------------------------------------------------------------------
// Decode with trailing data (bytes_read should be correct)
// ---------------------------------------------------------------------------

test "decode ignores trailing bytes" {
    // Value 42 immediate, followed by garbage
    const result = try decode(&[_]u8{ 0x2A, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 42), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "decode length-prefixed ignores trailing bytes" {
    // Value 256 = [0x82, 0x00, 0x01], followed by garbage
    const result = try decode(&[_]u8{ 0x82, 0x00, 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

// ---------------------------------------------------------------------------
// Encoding size tests (verify total byte count)
// ---------------------------------------------------------------------------

test "encoding sizes match spec" {
    var buf: [16]u8 = undefined;

    // Immediate: 1 byte
    try testing.expectEqual(@as(usize, 1), try encode(0, &buf));
    try testing.expectEqual(@as(usize, 1), try encode(42, &buf));
    try testing.expectEqual(@as(usize, 1), try encode(127, &buf));

    // L=1: 2 bytes
    try testing.expectEqual(@as(usize, 2), try encode(128, &buf));
    try testing.expectEqual(@as(usize, 2), try encode(200, &buf));
    try testing.expectEqual(@as(usize, 2), try encode(255, &buf));

    // L=2: 3 bytes
    try testing.expectEqual(@as(usize, 3), try encode(256, &buf));
    try testing.expectEqual(@as(usize, 3), try encode(1000, &buf));
    try testing.expectEqual(@as(usize, 3), try encode(50000, &buf));
    try testing.expectEqual(@as(usize, 3), try encode(65535, &buf));

    // L=3: 4 bytes
    try testing.expectEqual(@as(usize, 4), try encode(65536, &buf));
    try testing.expectEqual(@as(usize, 4), try encode(5000000, &buf));

    // L=4: 5 bytes
    try testing.expectEqual(@as(usize, 5), try encode(0xFFFFFFFF, &buf));

    // L=8: 9 bytes
    try testing.expectEqual(@as(usize, 9), try encode(0xFFFFFFFFFFFFFFFF, &buf));
}

// ---------------------------------------------------------------------------
// Decode overflow for L > 8
// ---------------------------------------------------------------------------

test "decode L=9 returns Overflow" {
    // 0x89 = bit 7 set, C=0, L=9 -- too many bytes for u64
    const result = decode(&[_]u8{ 0x89, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectError(Error.Overflow, result);
}

// ---------------------------------------------------------------------------
// encodedSize tests
// ---------------------------------------------------------------------------

test "encodedSize matches actual encode size" {
    var buf: [16]u8 = undefined;
    const values = [_]u64{
        0, 1, 42, 127, 128, 200, 255, 256, 1000,
        50000, 65535, 65536, 5000000, 0xFFFFFFFF,
        0x100000000, 0xFFFFFFFFFFFFFFFF,
    };
    for (values) |value| {
        const actual = try encode(value, &buf);
        try testing.expectEqual(actual, encodedSize(value));
    }
}

// ---------------------------------------------------------------------------
// Big-endian encoding tests
// ---------------------------------------------------------------------------

fn encodeBEToSlice(value: u64, buf: []u8) []const u8 {
    const n = encodeBE(value, buf) catch unreachable;
    return buf[0..n];
}

test "endianOf: null for immediate values" {
    try testing.expectEqual(@as(?Endian, null), endianOf(&[_]u8{0x00}));
    try testing.expectEqual(@as(?Endian, null), endianOf(&[_]u8{0x7F}));
    try testing.expectEqual(@as(?Endian, null), endianOf(&[_]u8{0x2A}));
}

test "endianOf: null for empty buffer" {
    try testing.expectEqual(@as(?Endian, null), endianOf(&[_]u8{}));
}

test "endianOf: detects LE" {
    var buf: [16]u8 = undefined;
    _ = try encode(256, &buf);
    try testing.expectEqual(@as(?Endian, .little), endianOf(&buf));
}

test "endianOf: detects BE" {
    var buf: [16]u8 = undefined;
    _ = try encodeBE(256, &buf);
    try testing.expectEqual(@as(?Endian, .big), endianOf(&buf));
}

test "encodeBE: immediate values are identical to LE" {
    var buf_le: [16]u8 = undefined;
    var buf_be: [16]u8 = undefined;
    for (0..128) |v| {
        const le = encodeToSlice(@intCast(v), &buf_le);
        const be = encodeBEToSlice(@intCast(v), &buf_be);
        try testing.expectEqualSlices(u8, le, be);
    }
}

test "encodeBE: header byte has E=1 (bit 6 set)" {
    var buf: [16]u8 = undefined;
    _ = try encodeBE(200, &buf); // L=1
    try testing.expectEqual(@as(u8, 0xC1), buf[0]); // 1_1_0_00001 = bit7=1, E=1, C=0, L=1
}

test "encodeBE: value 256 = [0xC2, 0x01, 0x00] L=2 big-endian" {
    var buf: [16]u8 = undefined;
    const result = encodeBEToSlice(256, &buf);
    // 256 = 0x0100 → BE payload: [0x01, 0x00]
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC2, 0x01, 0x00 }, result);
}

test "encodeBE: value 1000 = [0xC2, 0x03, 0xE8] L=2 big-endian" {
    var buf: [16]u8 = undefined;
    const result = encodeBEToSlice(1000, &buf);
    // 1000 = 0x03E8 → BE payload: [0x03, 0xE8]
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC2, 0x03, 0xE8 }, result);
}

test "encodeBE: value 0xDEADBEEF = [0xC4, 0xDE, 0xAD, 0xBE, 0xEF]" {
    var buf: [16]u8 = undefined;
    const result = encodeBEToSlice(0xDEADBEEF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC4, 0xDE, 0xAD, 0xBE, 0xEF }, result);
}

test "encodeBE: decode auto-detects endianness" {
    var buf: [16]u8 = undefined;

    // Encode BE
    const be_n = try encodeBE(1000, &buf);
    const be_result = try decode(buf[0..be_n]);
    try testing.expectEqual(@as(u64, 1000), be_result.value);
    try testing.expectEqual(Endian.big, be_result.endian);

    // Encode LE
    const le_n = try encode(1000, &buf);
    const le_result = try decode(buf[0..le_n]);
    try testing.expectEqual(@as(u64, 1000), le_result.value);
    try testing.expectEqual(Endian.little, le_result.endian);
}

test "encodeBE: round-trip all u64 magnitude classes" {
    var buf: [16]u8 = undefined;
    const values = [_]u64{
        0, 1, 42, 127, 128, 200, 255, 256, 1000,
        50000, 65535, 65536, 5000000, 0xFFFFFFFF,
        0x100000000, 0xFFFFFFFFFFFFFFFF,
    };
    for (values) |value| {
        const n = try encodeBE(value, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        if (value >= 128) {
            try testing.expectEqual(Endian.big, result.endian);
        }
    }
}

test "encodeBE: lexicographic ordering matches numeric ordering" {
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;

    const pairs = [_][2]u64{
        .{ 0, 1 },
        .{ 127, 128 },
        .{ 255, 256 },
        .{ 256, 257 },
        .{ 511, 512 },
        .{ 999, 1000 },
        .{ 65535, 65536 },
        .{ 0xFFFFFFFF, 0x100000000 },
        .{ 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF },
    };

    for (pairs) |pair| {
        const a = pair[0];
        const b = pair[1];
        const slice_a = encodeBEToSlice(a, &buf_a);
        const slice_b = encodeBEToSlice(b, &buf_b);

        // Lexicographic comparison: a < b should mean encode(a) < encode(b)
        const order = std.mem.order(u8, slice_a, slice_b);
        try testing.expect(order == .lt);
    }
}

test "encodeBE: same-L values sort correctly (the LE failure case)" {
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;

    // This is the case that fails with LE: 511 vs 512
    // LE: 511 = [0x82, 0xFF, 0x01], 512 = [0x82, 0x00, 0x02] → 0xFF > 0x00, WRONG
    // BE: 511 = [0xC2, 0x01, 0xFF], 512 = [0xC2, 0x02, 0x00] → 0x01 < 0x02, CORRECT
    const slice_511 = encodeBEToSlice(511, &buf_a);
    const slice_512 = encodeBEToSlice(512, &buf_b);
    try testing.expect(std.mem.order(u8, slice_511, slice_512) == .lt);
}

// ---------------------------------------------------------------------------
// BLIP Spec v1.2 — Scalar sentinels (NIL / TRUE / FALSE)
// ---------------------------------------------------------------------------

test "decodeScalar: NIL sentinel (0x81 0x7E) returns .nil" {
    const result = try decodeScalar(&[_]u8{ 0x81, 0x7E });
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
    try testing.expect(result.scalar == .nil);
}

test "decodeScalar: FALSE sentinel (0x81 0x7D) returns .boolean = false" {
    const result = try decodeScalar(&[_]u8{ 0x81, 0x7D });
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
    try testing.expectEqual(false, result.scalar.boolean);
}

test "decodeScalar: TRUE sentinel (0x81 0x7C) returns .boolean = true" {
    const result = try decodeScalar(&[_]u8{ 0x81, 0x7C });
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
    try testing.expectEqual(true, result.scalar.boolean);
}

test "decodeScalar: immediate integer 42 returns .integer = 42" {
    const result = try decodeScalar(&[_]u8{0x2A});
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
    try testing.expectEqual(@as(u64, 42), result.scalar.integer);
}

test "decodeScalar: length-prefixed integer 1000 returns .integer = 1000" {
    const result = try decodeScalar(&[_]u8{ 0x82, 0xE8, 0x03 });
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
    try testing.expectEqual(@as(u64, 1000), result.scalar.integer);
}

test "encodeScalar: NIL produces [0x81, 0x7E]" {
    var buf: [4]u8 = undefined;
    const n = try encodeScalar(.nil, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x7E }, buf[0..n]);
}

test "encodeScalar: FALSE produces [0x81, 0x7D]" {
    var buf: [4]u8 = undefined;
    const n = try encodeScalar(.{ .boolean = false }, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x7D }, buf[0..n]);
}

test "encodeScalar: TRUE produces [0x81, 0x7C]" {
    var buf: [4]u8 = undefined;
    const n = try encodeScalar(.{ .boolean = true }, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x7C }, buf[0..n]);
}

test "encodeScalar: integer 42 produces [0x2A] (immediate)" {
    var buf: [16]u8 = undefined;
    const n = try encodeScalar(.{ .integer = 42 }, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x2A}, buf[0..n]);
}

test "encodeScalar: integer 1000 produces [0x82, 0xE8, 0x03]" {
    var buf: [16]u8 = undefined;
    const n = try encodeScalar(.{ .integer = 1000 }, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xE8, 0x03 }, buf[0..n]);
}

test "encodeScalar/decodeScalar roundtrip: nil, true, false, integers" {
    var buf: [16]u8 = undefined;
    const cases = [_]Scalar{
        .nil,
        .{ .boolean = true },
        .{ .boolean = false },
        .{ .integer = 0 },
        .{ .integer = 127 },
        .{ .integer = 128 },
        .{ .integer = 1000 },
        .{ .integer = std.math.maxInt(u32) },
        .{ .integer = std.math.maxInt(u64) },
    };
    for (cases) |s| {
        const n = try encodeScalar(s, &buf);
        const r = try decodeScalar(buf[0..n]);
        try testing.expectEqual(@as(usize, n), r.bytes_read);
        try testing.expect(std.meta.eql(s, r.scalar));
    }
}

test "decodeScalar: integer at scalar-sentinel-adjacent values still decodes as integer" {
    // 0x81 0x7B is a non-reserved sentinel slot. decodeScalar treats it as an integer
    // (overlong encoding of 123) only because the spec defers application-level
    // sentinel handling to higher layers; new SCALAR sentinels are exactly 0x7C/0x7D/0x7E.
    const r1 = try decodeScalar(&[_]u8{ 0x81, 0x7B });
    try testing.expectEqual(@as(u64, 123), r1.scalar.integer);
    const r2 = try decodeScalar(&[_]u8{ 0x81, 0x7F });
    // 0x7F is the VAL sigil byte; decodeScalar still surfaces it as integer 127 here
    // because attribute-sigil interpretation is contextual to LP envelope parsing.
    try testing.expectEqual(@as(u64, 127), r2.scalar.integer);
}

test "decodeScalar: empty buffer returns UnexpectedEndOfInput" {
    try testing.expectError(Error.UnexpectedEndOfInput, decodeScalar(&[_]u8{}));
}

test "encodeScalar: integer encoding matches plain encode" {
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 1000, 65535, 1_000_000 }) |v| {
        const n_scalar = try encodeScalar(.{ .integer = v }, &buf_a);
        const n_plain = try encode(v, &buf_b);
        try testing.expectEqualSlices(u8, buf_b[0..n_plain], buf_a[0..n_scalar]);
    }
}

// ---------------------------------------------------------------------------
// Re-export modules for benchmark access (avoids multi-module file conflicts)
// ---------------------------------------------------------------------------
pub const encoding = @import("encoding.zig");
pub const bignum_mod = @import("bignum.zig");
pub const array_mod = @import("array.zig");
pub const dict_mod = @import("dict.zig");
pub const leaf_mod = @import("leaf.zig");
pub const checksum_mod = @import("checksum.zig");
pub const container_mod = @import("container.zig");
pub const container_types = @import("container_types.zig");
pub const peek_mod = @import("peek.zig");
pub const segmentation_mod = @import("segmentation.zig");
pub const build_options = @import("build_options");

// ---------------------------------------------------------------------------
// Pull in tests from BLIP-side modules
// ---------------------------------------------------------------------------
test {
    _ = @import("leb128.zig");
    _ = @import("protobuf_varint.zig");
    _ = @import("asn1_length.zig");
    _ = @import("prefix_varint.zig");
    _ = @import("sqlite_varint.zig");
    _ = @import("encoding.zig");
    _ = @import("bignum.zig");
    _ = @import("fuzz.zig");
    _ = @import("container_types.zig");
    _ = @import("container.zig");
    _ = @import("leaf.zig");
    _ = @import("array.zig");
    _ = @import("dict.zig");
    _ = @import("peek.zig");
    _ = @import("checksum.zig");
    _ = @import("segmentation.zig");
}
