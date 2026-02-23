const std = @import("std");

// LEB128: Unsigned and Signed variable-length integer encoding.
// Each byte carries 7 data bits (bits 6-0) and 1 continuation bit (bit 7).
// Bit 7 = 1 means more bytes follow; bit 7 = 0 means last byte.

pub const name = "LEB128";

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

/// Encode a u64 value in LEB128 format. Returns number of bytes written.
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

/// Decode an unsigned LEB128 value from a buffer.
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
            // No continuation bit: this is the last byte.
            return DecodeResult{
                .value = value,
                .bytes_read = pos,
            };
        }
        shift +|= 7; // saturating add
    }
}

/// Encode an i64 value in SLEB128 format. Returns number of bytes written.
pub fn signedEncode(value: i64, buf: []u8) Error!usize {
    var v = value;
    var pos: usize = 0;
    while (true) {
        if (pos >= buf.len) return Error.BufferTooSmall;
        // Extract low 7 bits (use bitwise AND on the unsigned representation)
        const byte: u8 = @intCast(@as(u7, @truncate(@as(u64, @bitCast(v)))));
        // Arithmetic right shift to consume the 7 bits
        v >>= 7;
        // Check if we can stop: the remaining value must be either all 0s (positive)
        // or all 1s (negative), AND the sign bit (bit 6) of the current byte must
        // match the sign of the value.
        const sign_bit_set = (byte & 0x40) != 0;
        if ((v == 0 and !sign_bit_set) or (v == -1 and sign_bit_set)) {
            buf[pos] = byte;
            return pos + 1;
        } else {
            buf[pos] = byte | 0x80; // set continuation bit
            pos += 1;
        }
    }
}

/// Decode a signed LEB128 (SLEB128) value from a buffer.
pub fn signedDecode(buf: []const u8) Error!SignedDecodeResult {
    var value: i64 = 0;
    var shift: u8 = 0;
    var pos: usize = 0;
    var last_byte: u8 = 0;
    while (true) {
        if (pos >= buf.len) return Error.UnexpectedEndOfInput;
        const byte = buf[pos];
        pos += 1;
        last_byte = byte;

        // Check for overflow: we can hold at most 64 bits.
        if (shift >= 64) {
            return Error.Overflow;
        }

        // OR in the 7 data bits. For signed, we work with i64 directly.
        // We need to be careful: shift the unsigned 7-bit value, then OR.
        value |= @as(i64, @bitCast(@as(u64, byte & 0x7F) << @as(u6, @intCast(shift))));
        shift +|= 7;

        if (byte & 0x80 == 0) {
            // No continuation bit: last byte.
            // Sign-extend if the sign bit (bit 6) of the last byte is set
            // and we haven't filled all 64 bits yet.
            if (shift < 64 and (last_byte & 0x40) != 0) {
                // Sign extend: fill remaining high bits with 1s
                // Create a mask of all 1s above the shift position
                value |= @as(i64, @bitCast(@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(shift))));
            }
            return SignedDecodeResult{
                .value = value,
                .bytes_read = pos,
            };
        }
    }
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
// LEB128 Unsigned Encode — exact byte sequences from spec
// ---------------------------------------------------------------------------

test "LEB128 encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "LEB128 encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "LEB128 encode 127 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "LEB128 encode 128 = [0x80, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, result);
}

test "LEB128 encode 255 = [0xFF, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(255, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x01 }, result);
}

test "LEB128 encode 256 = [0x80, 0x02]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(256, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x02 }, result);
}

test "LEB128 encode 300 = [0xAC, 0x02]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(300, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, result);
}

test "LEB128 encode 16383 = [0xFF, 0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(16383, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x7F }, result);
}

test "LEB128 encode 16384 = [0x80, 0x80, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(16384, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80, 0x01 }, result);
}

test "LEB128 encode 65535 = [0xFF, 0xFF, 0x03]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65535, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0x03 }, result);
}

test "LEB128 encode 0xFFFFFFFF = [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, result);
}

test "LEB128 encode 0xFFFFFFFFFFFFFFFF = [0xFF x9, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 }, result);
}

// ---------------------------------------------------------------------------
// LEB128 Unsigned Decode — exact byte sequences
// ---------------------------------------------------------------------------

test "LEB128 decode 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "LEB128 decode 1 from [0x01]" {
    const result = try decode(&[_]u8{0x01});
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "LEB128 decode 127 from [0x7F]" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "LEB128 decode 128 from [0x80, 0x01]" {
    const result = try decode(&[_]u8{ 0x80, 0x01 });
    try testing.expectEqual(@as(u64, 128), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "LEB128 decode 255 from [0xFF, 0x01]" {
    const result = try decode(&[_]u8{ 0xFF, 0x01 });
    try testing.expectEqual(@as(u64, 255), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "LEB128 decode 256 from [0x80, 0x02]" {
    const result = try decode(&[_]u8{ 0x80, 0x02 });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "LEB128 decode 300 from [0xAC, 0x02]" {
    const result = try decode(&[_]u8{ 0xAC, 0x02 });
    try testing.expectEqual(@as(u64, 300), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "LEB128 decode 16383 from [0xFF, 0x7F]" {
    const result = try decode(&[_]u8{ 0xFF, 0x7F });
    try testing.expectEqual(@as(u64, 16383), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "LEB128 decode 16384 from [0x80, 0x80, 0x01]" {
    const result = try decode(&[_]u8{ 0x80, 0x80, 0x01 });
    try testing.expectEqual(@as(u64, 16384), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "LEB128 decode 65535 from [0xFF, 0xFF, 0x03]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0x03 });
    try testing.expectEqual(@as(u64, 65535), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "LEB128 decode 0xFFFFFFFF from [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F });
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "LEB128 decode 0xFFFFFFFFFFFFFFFF from [0xFF x9, 0x01]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 10), result.bytes_read);
}

// ---------------------------------------------------------------------------
// LEB128 Unsigned Roundtrip
// ---------------------------------------------------------------------------

test "LEB128 roundtrip spec values" {
    const values = [_]u64{
        0,
        1,
        127,
        128,
        255,
        256,
        300,
        16383,
        16384,
        65535,
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

test "LEB128 roundtrip powers of 2" {
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

test "LEB128 roundtrip boundary values" {
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
// LEB128 Error cases
// ---------------------------------------------------------------------------

test "LEB128 decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "LEB128 decode truncated (continuation bit set, no more bytes)" {
    const result = decode(&[_]u8{0x80});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "LEB128 encode buffer too small" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "LEB128 encode 128 into 1-byte buffer too small" {
    var buf: [1]u8 = undefined;
    const result = encode(128, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "LEB128 decode overflow (too many bytes for u64)" {
    // 11 bytes with continuation, exceeding 64 bits
    const result = decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03 });
    try testing.expectError(Error.Overflow, result);
}

test "LEB128 decode ignores trailing bytes" {
    const result = try decode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

// ---------------------------------------------------------------------------
// SLEB128 Signed Encode — exact byte sequences from spec
// ---------------------------------------------------------------------------

test "SLEB128 encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "SLEB128 encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "SLEB128 encode -1 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "SLEB128 encode 63 = [0x3F]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(63, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x3F}, result);
}

test "SLEB128 encode 64 = [0xC0, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(64, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0x00 }, result);
}

test "SLEB128 encode -64 = [0x40]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-64, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x40}, result);
}

test "SLEB128 encode -65 = [0xBF, 0x7F]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-65, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xBF, 0x7F }, result);
}

test "SLEB128 encode -128 = [0x80, 0x7F]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x7F }, result);
}

test "SLEB128 encode -129 = [0xFF, 0x7E]" {
    var buf: [16]u8 = undefined;
    const result = signedEncodeToSlice(-129, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x7E }, result);
}

// ---------------------------------------------------------------------------
// SLEB128 Signed Decode — exact byte sequences
// ---------------------------------------------------------------------------

test "SLEB128 decode 0 from [0x00]" {
    const result = try signedDecode(&[_]u8{0x00});
    try testing.expectEqual(@as(i64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SLEB128 decode 1 from [0x01]" {
    const result = try signedDecode(&[_]u8{0x01});
    try testing.expectEqual(@as(i64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SLEB128 decode -1 from [0x7F]" {
    const result = try signedDecode(&[_]u8{0x7F});
    try testing.expectEqual(@as(i64, -1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SLEB128 decode 63 from [0x3F]" {
    const result = try signedDecode(&[_]u8{0x3F});
    try testing.expectEqual(@as(i64, 63), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SLEB128 decode 64 from [0xC0, 0x00]" {
    const result = try signedDecode(&[_]u8{ 0xC0, 0x00 });
    try testing.expectEqual(@as(i64, 64), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SLEB128 decode -64 from [0x40]" {
    const result = try signedDecode(&[_]u8{0x40});
    try testing.expectEqual(@as(i64, -64), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SLEB128 decode -65 from [0xBF, 0x7F]" {
    const result = try signedDecode(&[_]u8{ 0xBF, 0x7F });
    try testing.expectEqual(@as(i64, -65), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SLEB128 decode -128 from [0x80, 0x7F]" {
    const result = try signedDecode(&[_]u8{ 0x80, 0x7F });
    try testing.expectEqual(@as(i64, -128), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SLEB128 decode -129 from [0xFF, 0x7E]" {
    const result = try signedDecode(&[_]u8{ 0xFF, 0x7E });
    try testing.expectEqual(@as(i64, -129), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

// ---------------------------------------------------------------------------
// SLEB128 Signed Roundtrip
// ---------------------------------------------------------------------------

test "SLEB128 roundtrip spec values" {
    const values = [_]i64{
        0,
        1,
        -1,
        63,
        64,
        -64,
        -65,
        -128,
        -129,
        127,
        128,
        -256,
        -32768,
        32767,
        std.math.maxInt(i64),
        std.math.minInt(i64),
    };
    var buf: [16]u8 = undefined;
    for (values) |value| {
        const n = try signedEncode(value, &buf);
        const result = try signedDecode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

test "SLEB128 roundtrip negative powers of 2" {
    var buf: [16]u8 = undefined;
    var value: i64 = -1;
    for (0..63) |_| {
        const n = try signedEncode(value, &buf);
        const result = try signedDecode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
        value *|= 2;
    }
}

test "SLEB128 roundtrip positive powers of 2" {
    var buf: [16]u8 = undefined;
    var value: i64 = 1;
    for (0..62) |_| {
        const n = try signedEncode(value, &buf);
        const result = try signedDecode(buf[0..n]);
        try testing.expectEqual(value, result.value);
        try testing.expectEqual(n, result.bytes_read);
        value *|= 2;
    }
}

// ---------------------------------------------------------------------------
// SLEB128 Error cases
// ---------------------------------------------------------------------------

test "SLEB128 decode empty buffer returns UnexpectedEndOfInput" {
    const result = signedDecode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SLEB128 decode truncated (continuation bit set, no more bytes)" {
    const result = signedDecode(&[_]u8{0x80});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SLEB128 encode buffer too small" {
    var buf: [0]u8 = undefined;
    const result = signedEncode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "SLEB128 decode ignores trailing bytes" {
    const result = try signedDecode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(i64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}
