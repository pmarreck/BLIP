const std = @import("std");

// Protobuf Varint: Unsigned LEB128 encoding plus ZigZag encoding for signed integers.
// Protobuf uses ZigZag to map signed integers to unsigned before LEB128 encoding,
// so that small-magnitude values (positive or negative) produce small encoded sizes.

pub const name = "Protobuf";

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub const SignedDecodeResult = struct {
    value: i64,
    bytes_read: usize,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Encode a u64 value in Protobuf varint format (identical to LEB128 unsigned).
/// Returns the number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    var v = value;
    var pos: usize = 0;
    while (true) {
        if (pos >= buf.len) return Error.BufferTooSmall;
        const byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            buf[pos] = byte;
            return pos + 1;
        } else {
            buf[pos] = byte | 0x80; // set continuation bit
            pos += 1;
        }
    }
}

/// Decode an unsigned Protobuf varint from a buffer (identical to LEB128 unsigned).
pub fn decode(buf: []const u8) Error!DecodeResult {
    var value: u64 = 0;
    var shift: u8 = 0;
    var pos: usize = 0;
    while (true) {
        if (pos >= buf.len) return Error.UnexpectedEndOfInput;
        const byte = buf[pos];
        pos += 1;

        // Check for overflow: if shift >= 64, any nonzero data bits overflow.
        // Also, at shift == 63, only bit 0 of the 7 data bits can be set (value bit 63).
        if (shift >= 64) {
            return Error.Overflow;
        }
        if (shift == 63 and (byte & 0x7F) > 1) {
            return Error.Overflow;
        }

        value |= @as(u64, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) {
            return DecodeResult{
                .value = value,
                .bytes_read = pos,
            };
        }
        shift +|= 7; // saturating add
    }
}

/// ZigZag encode: map signed to unsigned so small magnitudes stay small.
/// zigzag_encode(n) = (n << 1) ^ (n >> 63)   (arithmetic shift right)
pub fn zigzagEncode(value: i64) u64 {
    // (n << 1) ^ (n >> 63) using bitcast to work in u64 space
    const shifted_left: u64 = @bitCast(value << 1);
    const sign_fill: u64 = @bitCast(value >> 63); // arithmetic shift: all 0s or all 1s
    return shifted_left ^ sign_fill;
}

/// ZigZag decode: map unsigned back to signed.
/// zigzag_decode(n) = (n >> 1) ^ -(n & 1)
pub fn zigzagDecode(value: u64) i64 {
    const half: u64 = value >> 1;
    const sign_mask: u64 = 0 -% (value & 1); // -(n & 1) using wrapping negation
    return @bitCast(half ^ sign_mask);
}

/// Signed encode: ZigZag the value then LEB128 encode it.
pub fn signedEncode(value: i64, buf: []u8) Error!usize {
    return encode(zigzagEncode(value), buf);
}

/// Signed decode: LEB128 decode then un-ZigZag the result.
pub fn signedDecode(buf: []const u8) Error!SignedDecodeResult {
    const result = try decode(buf);
    return SignedDecodeResult{
        .value = zigzagDecode(result.value),
        .bytes_read = result.bytes_read,
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

/// Helper: signed encode a value and return the bytes as a slice
fn signedEncodeToSlice(value: i64, buf: []u8) []const u8 {
    const n = signedEncode(value, buf) catch unreachable;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// ZigZag Encode
// ---------------------------------------------------------------------------

test "Protobuf zigzagEncode(0) = 0" {
    try testing.expectEqual(@as(u64, 0), zigzagEncode(0));
}

test "Protobuf zigzagEncode(-1) = 1" {
    try testing.expectEqual(@as(u64, 1), zigzagEncode(-1));
}

test "Protobuf zigzagEncode(1) = 2" {
    try testing.expectEqual(@as(u64, 2), zigzagEncode(1));
}

test "Protobuf zigzagEncode(-2) = 3" {
    try testing.expectEqual(@as(u64, 3), zigzagEncode(-2));
}

test "Protobuf zigzagEncode(2) = 4" {
    try testing.expectEqual(@as(u64, 4), zigzagEncode(2));
}

test "Protobuf zigzagEncode(2147483647) = 4294967294" {
    try testing.expectEqual(@as(u64, 4294967294), zigzagEncode(2147483647));
}

test "Protobuf zigzagEncode(-2147483648) = 4294967295" {
    try testing.expectEqual(@as(u64, 4294967295), zigzagEncode(-2147483648));
}

test "Protobuf zigzagEncode(maxInt(i64)) = 0xFFFFFFFFFFFFFFFE" {
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFE), zigzagEncode(std.math.maxInt(i64)));
}

test "Protobuf zigzagEncode(minInt(i64)) = 0xFFFFFFFFFFFFFFFF" {
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), zigzagEncode(std.math.minInt(i64)));
}

// ---------------------------------------------------------------------------
// ZigZag Decode (inverse of encode)
// ---------------------------------------------------------------------------

test "Protobuf zigzagDecode(0) = 0" {
    try testing.expectEqual(@as(i64, 0), zigzagDecode(0));
}

test "Protobuf zigzagDecode(1) = -1" {
    try testing.expectEqual(@as(i64, -1), zigzagDecode(1));
}

test "Protobuf zigzagDecode(2) = 1" {
    try testing.expectEqual(@as(i64, 1), zigzagDecode(2));
}

test "Protobuf zigzagDecode(3) = -2" {
    try testing.expectEqual(@as(i64, -2), zigzagDecode(3));
}

test "Protobuf zigzagDecode(4) = 2" {
    try testing.expectEqual(@as(i64, 2), zigzagDecode(4));
}

test "Protobuf zigzagDecode(4294967294) = 2147483647" {
    try testing.expectEqual(@as(i64, 2147483647), zigzagDecode(4294967294));
}

test "Protobuf zigzagDecode(4294967295) = -2147483648" {
    try testing.expectEqual(@as(i64, -2147483648), zigzagDecode(4294967295));
}

test "Protobuf zigzagDecode(0xFFFFFFFFFFFFFFFE) = maxInt(i64)" {
    try testing.expectEqual(std.math.maxInt(i64), zigzagDecode(0xFFFFFFFFFFFFFFFE));
}

test "Protobuf zigzagDecode(0xFFFFFFFFFFFFFFFF) = minInt(i64)" {
    try testing.expectEqual(std.math.minInt(i64), zigzagDecode(0xFFFFFFFFFFFFFFFF));
}

// ---------------------------------------------------------------------------
// ZigZag Roundtrip
// ---------------------------------------------------------------------------

test "Protobuf zigzag roundtrip for range of values" {
    const values = [_]i64{
        0, 1, -1, 2, -2, 63, -64, 127, -128, 255, -256,
        2147483647, -2147483648,
        std.math.maxInt(i64), std.math.minInt(i64),
    };
    for (values) |v| {
        try testing.expectEqual(v, zigzagDecode(zigzagEncode(v)));
    }
}

// ---------------------------------------------------------------------------
// Protobuf Unsigned Encode — exact byte sequences (same as LEB128)
// ---------------------------------------------------------------------------

test "Protobuf encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "Protobuf encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "Protobuf encode 127 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "Protobuf encode 128 = [0x80, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, result);
}

test "Protobuf encode 300 = [0xAC, 0x02]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(300, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, result);
}

test "Protobuf encode 0xFFFFFFFFFFFFFFFF = [0xFF x9, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }, result);
}

// ---------------------------------------------------------------------------
// Protobuf Unsigned Decode — exact byte sequences
// ---------------------------------------------------------------------------

test "Protobuf decode 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "Protobuf decode 300 from [0xAC, 0x02]" {
    const result = try decode(&[_]u8{ 0xAC, 0x02 });
    try testing.expectEqual(@as(u64, 300), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "Protobuf decode 0xFFFFFFFFFFFFFFFF from [0xFF x9, 0x01]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 10), result.bytes_read);
}

// ---------------------------------------------------------------------------
// Protobuf Unsigned Roundtrip
// ---------------------------------------------------------------------------

test "Protobuf unsigned roundtrip" {
    const values = [_]u64{
        0, 1, 127, 128, 255, 256, 300, 16383, 16384, 65535,
        0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF,
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
// Protobuf Signed Encode (ZigZag + LEB128) — exact byte sequences
// ---------------------------------------------------------------------------

test "Protobuf signedEncode(0) = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "Protobuf signedEncode(-1) = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "Protobuf signedEncode(1) = [0x02]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, result);
}

test "Protobuf signedEncode(-2) = [0x03]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-2, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, result);
}

test "Protobuf signedEncode(150) = [0xAC, 0x02]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(150, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, result);
}

test "Protobuf signedEncode(-150) = [0xAB, 0x02]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-150, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0x02 }, result);
}

// ---------------------------------------------------------------------------
// Protobuf Signed Decode
// ---------------------------------------------------------------------------

test "Protobuf signedDecode [0x00] = 0" {
    const result = try signedDecode(&[_]u8{0x00});
    try testing.expectEqual(@as(i64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "Protobuf signedDecode [0x01] = -1" {
    const result = try signedDecode(&[_]u8{0x01});
    try testing.expectEqual(@as(i64, -1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "Protobuf signedDecode [0x02] = 1" {
    const result = try signedDecode(&[_]u8{0x02});
    try testing.expectEqual(@as(i64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "Protobuf signedDecode [0x03] = -2" {
    const result = try signedDecode(&[_]u8{0x03});
    try testing.expectEqual(@as(i64, -2), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "Protobuf signedDecode [0xAC, 0x02] = 150" {
    const result = try signedDecode(&[_]u8{ 0xAC, 0x02 });
    try testing.expectEqual(@as(i64, 150), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "Protobuf signedDecode [0xAB, 0x02] = -150" {
    const result = try signedDecode(&[_]u8{ 0xAB, 0x02 });
    try testing.expectEqual(@as(i64, -150), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

// ---------------------------------------------------------------------------
// Protobuf Signed Roundtrip
// ---------------------------------------------------------------------------

test "Protobuf signed roundtrip" {
    const values = [_]i64{
        0, 1, -1, 2, -2, 150, -150,
        63, -64, 127, -128, 255, -256,
        2147483647, -2147483648,
        std.math.maxInt(i64), std.math.minInt(i64),
    };
    var buf: [16]u8 = undefined;
    for (values) |value| {
        const n = try signedEncode(value, &buf);
        const result = try signedDecode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

// ---------------------------------------------------------------------------
// Error cases
// ---------------------------------------------------------------------------

test "Protobuf decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "Protobuf decode truncated returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{0x80});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "Protobuf encode buffer too small" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "Protobuf decode overflow" {
    const result = decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03 });
    try testing.expectError(Error.Overflow, result);
}

test "Protobuf signedDecode empty buffer returns UnexpectedEndOfInput" {
    const result = signedDecode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "Protobuf signedEncode buffer too small" {
    var buf: [0]u8 = undefined;
    const result = signedEncode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "Protobuf decode ignores trailing bytes" {
    const result = try decode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}
