const std = @import("std");

// PrefixVarint: Variable-length integer encoding using a unary prefix.
//
// The number of leading 1-bits in the first byte determines how many additional
// bytes follow. The remaining bits of the first byte (after the prefix 1s and
// the separator 0) are the most significant data bits; the following bytes are
// stored in little-endian order and form the less significant data bits.
//
// Format:
//   0xxxxxxx                          -> 1 byte,  7 data bits (0-127)
//   10xxxxxx xxxxxxxx                 -> 2 bytes, 14 data bits (0-16383)
//   110xxxxx xxxxxxxx xxxxxxxx        -> 3 bytes, 21 data bits (0-2097151)
//   1110xxxx + 3 bytes                -> 4 bytes, 28 data bits
//   11110xxx + 4 bytes                -> 5 bytes, 35 data bits
//   111110xx + 5 bytes                -> 6 bytes, 42 data bits
//   1111110x + 6 bytes                -> 7 bytes, 49 data bits
//   11111110 + 7 bytes                -> 8 bytes, 56 data bits
//   11111111 + 8 bytes                -> 9 bytes, 64 data bits
//
// Encode:
//   N = number of additional bytes (0 for values 0-127)
//   If N < 8:
//     prefix_mask = (0xFF << (8 - N)) & 0xFF
//     data_bits_in_first_byte = 7 - N
//     first_byte = prefix_mask | ((value >> (N * 8)) & ((1 << data_bits_in_first_byte) - 1))
//     remaining N bytes written in little-endian order
//   If N == 8:
//     first_byte = 0xFF
//     followed by 8 bytes of value in little-endian order
//
// Decode:
//   N = count leading 1-bits of first byte (0 to 8)
//   If N == 0: return first byte directly (7-bit value)
//   If N == 8: read next 8 bytes as little-endian u64
//   Otherwise:
//     data_bits = 7 - N
//     value = (first_byte & ((1 << data_bits) - 1)) << (N * 8)
//     value |= next N bytes read as little-endian

pub const name = "PrefixVarint";

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Determine the number of extra bytes needed to encode a value.
/// Returns N where total encoded size = N + 1.
fn extraBytesNeeded(value: u64) u4 {
    // N=0: 7 data bits -> max 127
    if (value < (1 << 7)) return 0;
    // N=1: 14 data bits -> max 16383
    if (value < (1 << 14)) return 1;
    // N=2: 21 data bits -> max 2097151
    if (value < (1 << 21)) return 2;
    // N=3: 28 data bits
    if (value < (1 << 28)) return 3;
    // N=4: 35 data bits
    if (value < (@as(u64, 1) << 35)) return 4;
    // N=5: 42 data bits
    if (value < (@as(u64, 1) << 42)) return 5;
    // N=6: 49 data bits
    if (value < (@as(u64, 1) << 49)) return 6;
    // N=7: 56 data bits
    if (value < (@as(u64, 1) << 56)) return 7;
    // N=8: 64 data bits
    return 8;
}

/// Encode a u64 value in PrefixVarint format. Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    const n: u4 = extraBytesNeeded(value);
    const total: usize = @as(usize, n) + 1;

    if (buf.len < total) return Error.BufferTooSmall;

    if (n == 0) {
        // Single byte: 0xxxxxxx
        buf[0] = @intCast(value);
        return 1;
    }

    if (n == 8) {
        // Special case: 0xFF prefix + 8 raw LE bytes
        buf[0] = 0xFF;
        var v = value;
        for (1..9) |i| {
            buf[i] = @intCast(v & 0xFF);
            v >>= 8;
        }
        return 9;
    }

    // General case: N leading 1-bits, then a 0-bit, then data bits in first byte,
    // followed by N bytes in little-endian order.
    const data_bits: u4 = 7 - n; // bits available for data in the first byte
    const prefix_mask: u8 = @as(u8, 0xFF) << (@as(u3, @intCast(data_bits)) + 1);
    const data_mask: u8 = (@as(u8, 1) << @as(u3, @intCast(data_bits))) - 1;
    const shift_amount: u6 = @as(u6, n) * 8;
    const first_byte_data: u8 = @intCast((value >> shift_amount) & data_mask);
    buf[0] = prefix_mask | first_byte_data;

    // Write remaining N bytes in little-endian order
    var v = value;
    for (0..@as(usize, n)) |i| {
        buf[1 + i] = @intCast(v & 0xFF);
        v >>= 8;
    }

    return total;
}

/// Count the number of leading 1-bits in a byte.
fn countLeadingOnes(byte: u8) u4 {
    // Invert the byte and count leading zeros
    const inverted: u8 = ~byte;
    return @intCast(@clz(inverted));
}

/// Decode a PrefixVarint value from a buffer.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;

    const first = buf[0];
    const n: u4 = countLeadingOnes(first);
    const total: usize = @as(usize, n) + 1;

    if (buf.len < total) return Error.UnexpectedEndOfInput;

    if (n == 0) {
        // Single byte: 0xxxxxxx
        return DecodeResult{
            .value = first,
            .bytes_read = 1,
        };
    }

    if (n == 8) {
        // Special case: 0xFF prefix + 8 raw LE bytes
        var value: u64 = 0;
        for (0..8) |i| {
            value |= @as(u64, buf[1 + i]) << @as(u6, @intCast(i * 8));
        }
        return DecodeResult{
            .value = value,
            .bytes_read = 9,
        };
    }

    // General case: extract data bits from first byte, then read N LE bytes
    const data_bits: u4 = 7 - n;
    const data_mask: u8 = (@as(u8, 1) << @as(u3, @intCast(data_bits))) - 1;
    const shift_amount: u6 = @as(u6, n) * 8;
    var value: u64 = @as(u64, first & data_mask) << shift_amount;

    // Read N bytes in little-endian order
    for (0..@as(usize, n)) |i| {
        value |= @as(u64, buf[1 + i]) << @as(u6, @intCast(i * 8));
    }

    return DecodeResult{
        .value = value,
        .bytes_read = total,
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
// PrefixVarint Encode — exact byte sequences
// ---------------------------------------------------------------------------

test "PrefixVarint encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "PrefixVarint encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "PrefixVarint encode 127 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "PrefixVarint encode 128 = [0x80, 0x80]" {
    // N=1: prefix=0x80, data_bits=6, first_byte = 0x80 | (128 >> 8) = 0x80
    // remaining LE byte: 128 & 0xFF = 0x80
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80 }, result);
}

test "PrefixVarint encode 255 = [0x80, 0xFF]" {
    // N=1: first_byte = 0x80 | (255 >> 8) = 0x80, remaining = 0xFF
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(255, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0xFF }, result);
}

test "PrefixVarint encode 256 = [0x81, 0x00]" {
    // N=1: first_byte = 0x80 | (256 >> 8) = 0x81, remaining = 0x00
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(256, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x00 }, result);
}

test "PrefixVarint encode 1000 = [0x83, 0xE8]" {
    // N=1: 1000 = 0x3E8, first_byte = 0x80 | (1000 >> 8) = 0x80 | 3 = 0x83
    // remaining = 1000 & 0xFF = 0xE8
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0xE8 }, result);
}

test "PrefixVarint encode 16383 = [0xBF, 0xFF]" {
    // N=1: max 14-bit value, first_byte = 0x80 | (16383 >> 8) = 0x80 | 0x3F = 0xBF
    // remaining = 0xFF
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(16383, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xBF, 0xFF }, result);
}

test "PrefixVarint encode 16384 = [0xC0, 0x00, 0x40]" {
    // N=2: 16384 = 0x4000, prefix = 0xC0, data_bits = 5
    // first_byte = 0xC0 | (16384 >> 16) = 0xC0 | 0 = 0xC0
    // remaining 2 LE bytes of (16384 & 0xFFFF) = 0x4000 -> [0x00, 0x40]
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(16384, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0x00, 0x40 }, result);
}

test "PrefixVarint encode 65535 = [0xC0, 0xFF, 0xFF]" {
    // N=2: first_byte = 0xC0 | (65535 >> 16) = 0xC0
    // remaining LE: [0xFF, 0xFF]
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65535, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0xFF, 0xFF }, result);
}

test "PrefixVarint encode 65536 = [0xC1, 0x00, 0x00]" {
    // N=2: 65536 = 0x10000, first_byte = 0xC0 | (65536 >> 16) = 0xC0 | 1 = 0xC1
    // remaining LE: [0x00, 0x00]
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65536, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC1, 0x00, 0x00 }, result);
}

test "PrefixVarint encode 0xFFFFFFFF = [0xF0, 0xFF, 0xFF, 0xFF, 0xFF]" {
    // N=4: 32 bits, 35 available (11110xxx + 4 bytes)
    // first_byte = 0xF0 | (0xFFFFFFFF >> 32) = 0xF0 | 0 = 0xF0
    // remaining 4 LE bytes: [0xFF, 0xFF, 0xFF, 0xFF]
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF0, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

test "PrefixVarint encode 0xFFFFFFFFFFFFFFFF = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]" {
    // N=8: full 64-bit, first byte = 0xFF, followed by 8 LE bytes
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

// ---------------------------------------------------------------------------
// PrefixVarint Decode — exact byte sequences
// ---------------------------------------------------------------------------

test "PrefixVarint decode 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "PrefixVarint decode 1 from [0x01]" {
    const result = try decode(&[_]u8{0x01});
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "PrefixVarint decode 127 from [0x7F]" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "PrefixVarint decode 128 from [0x80, 0x80]" {
    const result = try decode(&[_]u8{ 0x80, 0x80 });
    try testing.expectEqual(@as(u64, 128), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "PrefixVarint decode 255 from [0x80, 0xFF]" {
    const result = try decode(&[_]u8{ 0x80, 0xFF });
    try testing.expectEqual(@as(u64, 255), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "PrefixVarint decode 256 from [0x81, 0x00]" {
    const result = try decode(&[_]u8{ 0x81, 0x00 });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "PrefixVarint decode 1000 from [0x83, 0xE8]" {
    const result = try decode(&[_]u8{ 0x83, 0xE8 });
    try testing.expectEqual(@as(u64, 1000), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "PrefixVarint decode 16383 from [0xBF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xBF, 0xFF });
    try testing.expectEqual(@as(u64, 16383), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "PrefixVarint decode 16384 from [0xC0, 0x00, 0x40]" {
    const result = try decode(&[_]u8{ 0xC0, 0x00, 0x40 });
    try testing.expectEqual(@as(u64, 16384), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "PrefixVarint decode 65535 from [0xC0, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xC0, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 65535), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "PrefixVarint decode 65536 from [0xC1, 0x00, 0x00]" {
    const result = try decode(&[_]u8{ 0xC1, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 65536), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "PrefixVarint decode 0xFFFFFFFF from [0xF0, 0xFF, 0xFF, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xF0, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "PrefixVarint decode 0xFFFFFFFFFFFFFFFF from [0xFF, 0xFF x8]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 9), result.bytes_read);
}

// ---------------------------------------------------------------------------
// PrefixVarint Roundtrip
// ---------------------------------------------------------------------------

test "PrefixVarint roundtrip spec values" {
    const values = [_]u64{
        0,
        1,
        127,
        128,
        255,
        256,
        1000,
        16383,
        16384,
        65535,
        65536,
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

test "PrefixVarint roundtrip powers of 2" {
    var buf: [16]u8 = undefined;
    var value: u64 = 1;
    for (0..64) |_| {
        const n = try encode(value, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
        value *|= 2;
    }
}

test "PrefixVarint roundtrip boundary values" {
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
        0x1FFFFF, // 2097151 = max 21-bit
        0x200000,
        0xFFFFFFF, // max 28-bit
        0x10000000,
        0x7FFFFFFFF, // max 35-bit
        0x800000000,
        0x3FFFFFFFFFF, // max 42-bit
        0x40000000000,
        0x1FFFFFFFFFFFF, // max 49-bit
        0x2000000000000,
        0xFFFFFFFFFFFFFF, // max 56-bit
        0x100000000000000,
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
// PrefixVarint Encoding size verification
// ---------------------------------------------------------------------------

test "PrefixVarint values 0-127 use exactly 1 byte" {
    var buf: [16]u8 = undefined;
    for (0..128) |v| {
        const n = try encode(@intCast(v), &buf);
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "PrefixVarint value 128 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(128, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "PrefixVarint value 16383 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(16383, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "PrefixVarint value 16384 uses exactly 3 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(16384, &buf);
    try testing.expectEqual(@as(usize, 3), n);
}

test "PrefixVarint value 2097151 uses exactly 3 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(2097151, &buf);
    try testing.expectEqual(@as(usize, 3), n);
}

test "PrefixVarint value 2097152 uses exactly 4 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(2097152, &buf);
    try testing.expectEqual(@as(usize, 4), n);
}

test "PrefixVarint value 0xFFFFFFFF uses exactly 5 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 5), n);
}

test "PrefixVarint value 0xFFFFFFFFFFFFFFFF uses exactly 9 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 9), n);
}

// ---------------------------------------------------------------------------
// PrefixVarint Error cases
// ---------------------------------------------------------------------------

test "PrefixVarint decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "PrefixVarint decode truncated 2-byte (only header)" {
    // 0x80 means N=1, need 1 more byte, but buffer ends
    const result = decode(&[_]u8{0x80});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "PrefixVarint decode truncated 3-byte (missing 1 byte)" {
    // 0xC0 means N=2, need 2 more bytes, but only 1 present
    const result = decode(&[_]u8{ 0xC0, 0x01 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "PrefixVarint decode truncated 9-byte (0xFF header, only 4 payload bytes)" {
    // 0xFF means N=8, need 8 more bytes, but only 4 present
    const result = decode(&[_]u8{ 0xFF, 0x01, 0x02, 0x03, 0x04 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "PrefixVarint encode buffer too small for 1-byte value" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "PrefixVarint encode buffer too small for 2-byte value" {
    var buf: [1]u8 = undefined;
    const result = encode(128, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "PrefixVarint encode buffer too small for 9-byte value" {
    var buf: [8]u8 = undefined;
    const result = encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "PrefixVarint decode ignores trailing bytes" {
    const result = try decode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

// ---------------------------------------------------------------------------
// PrefixVarint extraBytesNeeded helper
// ---------------------------------------------------------------------------

test "PrefixVarint extraBytesNeeded(0) = 0" {
    try testing.expectEqual(@as(u4, 0), extraBytesNeeded(0));
}

test "PrefixVarint extraBytesNeeded(127) = 0" {
    try testing.expectEqual(@as(u4, 0), extraBytesNeeded(127));
}

test "PrefixVarint extraBytesNeeded(128) = 1" {
    try testing.expectEqual(@as(u4, 1), extraBytesNeeded(128));
}

test "PrefixVarint extraBytesNeeded(16383) = 1" {
    try testing.expectEqual(@as(u4, 1), extraBytesNeeded(16383));
}

test "PrefixVarint extraBytesNeeded(16384) = 2" {
    try testing.expectEqual(@as(u4, 2), extraBytesNeeded(16384));
}

test "PrefixVarint extraBytesNeeded(2097151) = 2" {
    try testing.expectEqual(@as(u4, 2), extraBytesNeeded(2097151));
}

test "PrefixVarint extraBytesNeeded(2097152) = 3" {
    try testing.expectEqual(@as(u4, 3), extraBytesNeeded(2097152));
}

test "PrefixVarint extraBytesNeeded(0xFFFFFFF) = 3" {
    try testing.expectEqual(@as(u4, 3), extraBytesNeeded(0xFFFFFFF));
}

test "PrefixVarint extraBytesNeeded(0x10000000) = 4" {
    try testing.expectEqual(@as(u4, 4), extraBytesNeeded(0x10000000));
}

test "PrefixVarint extraBytesNeeded(0xFFFFFFFFFFFFFFFF) = 8" {
    try testing.expectEqual(@as(u4, 8), extraBytesNeeded(0xFFFFFFFFFFFFFFFF));
}
