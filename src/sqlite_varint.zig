const std = @import("std");

// SQLite Varint: A Huffman-inspired variable-length integer encoding.
//
// This is the encoding used internally by SQLite for record headers and page pointers.
// The first byte determines how many additional bytes follow, using threshold-based
// discrimination rather than bit-prefix patterns.
//
// Encoding rules:
//   Value <= 240:           1 byte:  [value]
//   Value <= 2287:          2 bytes: [(value-240)/256 + 241, (value-240) % 256]
//   Value <= 67823:         3 bytes: [249, (value-2288)/256, (value-2288) % 256]
//   Value <= 2^24 - 1:     4 bytes: [250, then 3 bytes big-endian]
//   Value <= 2^32 - 1:     5 bytes: [251, then 4 bytes big-endian]
//   Value <= 2^40 - 1:     6 bytes: [252, then 5 bytes big-endian]
//   Value <= 2^48 - 1:     7 bytes: [253, then 6 bytes big-endian]
//   Value <= 2^56 - 1:     8 bytes: [254, then 7 bytes big-endian]
//   Otherwise (up to 2^64-1): 9 bytes: [255, then 8 bytes big-endian]

pub const name = "SQLite";

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Encode a u64 value in SQLite varint format. Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    if (value <= 240) {
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }

    if (value <= 2287) {
        if (buf.len < 2) return Error.BufferTooSmall;
        const offset = value - 240;
        buf[0] = @intCast(offset / 256 + 241);
        buf[1] = @intCast(offset % 256);
        return 2;
    }

    if (value <= 67823) {
        if (buf.len < 3) return Error.BufferTooSmall;
        const offset = value - 2288;
        buf[0] = 249;
        buf[1] = @intCast(offset / 256);
        buf[2] = @intCast(offset % 256);
        return 3;
    }

    // For values requiring 4-9 bytes, the first byte is a marker (250-255)
    // followed by N big-endian bytes encoding the value directly.
    const byte_counts = [_]struct { max: u64, marker: u8, payload: usize }{
        .{ .max = (1 << 24) - 1, .marker = 250, .payload = 3 },
        .{ .max = (1 << 32) - 1, .marker = 251, .payload = 4 },
        .{ .max = (@as(u64, 1) << 40) - 1, .marker = 252, .payload = 5 },
        .{ .max = (@as(u64, 1) << 48) - 1, .marker = 253, .payload = 6 },
        .{ .max = (@as(u64, 1) << 56) - 1, .marker = 254, .payload = 7 },
        .{ .max = std.math.maxInt(u64), .marker = 255, .payload = 8 },
    };

    inline for (byte_counts) |entry| {
        if (value <= entry.max) {
            const total = 1 + entry.payload;
            if (buf.len < total) return Error.BufferTooSmall;
            buf[0] = entry.marker;
            // Write payload bytes in big-endian order
            inline for (0..entry.payload) |i| {
                const shift: u6 = @intCast((entry.payload - 1 - i) * 8);
                buf[1 + i] = @intCast((value >> shift) & 0xFF);
            }
            return total;
        }
    }

    unreachable;
}

/// Decode a SQLite varint value from a buffer.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;

    const first = buf[0];

    if (first <= 240) {
        return DecodeResult{
            .value = first,
            .bytes_read = 1,
        };
    }

    if (first <= 248) {
        // 2-byte form: value = 240 + 256*(first - 241) + second
        if (buf.len < 2) return Error.UnexpectedEndOfInput;
        const value: u64 = 240 + 256 * @as(u64, first - 241) + buf[1];
        return DecodeResult{
            .value = value,
            .bytes_read = 2,
        };
    }

    if (first == 249) {
        // 3-byte form: value = 2288 + 256*second + third
        if (buf.len < 3) return Error.UnexpectedEndOfInput;
        const value: u64 = 2288 + 256 * @as(u64, buf[1]) + buf[2];
        return DecodeResult{
            .value = value,
            .bytes_read = 3,
        };
    }

    // first is 250-255: payload of (first - 247) bytes in big-endian
    const payload: usize = @as(usize, first) - 247;
    const total = 1 + payload;
    if (buf.len < total) return Error.UnexpectedEndOfInput;

    var value: u64 = 0;
    for (0..payload) |i| {
        value = (value << 8) | buf[1 + i];
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
// SQLite Varint Encode -- exact byte sequences
// ---------------------------------------------------------------------------

test "SQLite encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "SQLite encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "SQLite encode 127 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "SQLite encode 128 = [0x80]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x80}, result);
}

test "SQLite encode 240 = [0xF0]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(240, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0xF0}, result);
}

test "SQLite encode 241 = [0xF1, 0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(241, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF1, 0x01 }, result);
}

test "SQLite encode 256 = [0xF1, 0x10]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(256, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF1, 0x10 }, result);
}

test "SQLite encode 300 = [0xF1, 0x3C]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(300, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF1, 0x3C }, result);
}

test "SQLite encode 496 = [0xF2, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(496, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF2, 0x00 }, result);
}

test "SQLite encode 1000 = [0xF3, 0xF8]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF3, 0xF8 }, result);
}

test "SQLite encode 2287 = [0xF8, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(2287, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF8, 0xFF }, result);
}

test "SQLite encode 2288 = [0xF9, 0x00, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(2288, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF9, 0x00, 0x00 }, result);
}

test "SQLite encode 50000 = [0xF9, 0xBA, 0x60]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(50000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF9, 0xBA, 0x60 }, result);
}

test "SQLite encode 65535 = [0xF9, 0xF7, 0x0F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65535, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF9, 0xF7, 0x0F }, result);
}

test "SQLite encode 67823 = [0xF9, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(67823, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xF9, 0xFF, 0xFF }, result);
}

test "SQLite encode 67824 = [0xFA, 0x01, 0x08, 0xF0]" {
    // 67824 = 0x108F0 (note: spec said 0x10890 but that is 67728, not 67824)
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(67824, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFA, 0x01, 0x08, 0xF0 }, result);
}

test "SQLite encode 0xFFFFFF = [0xFA, 0xFF, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFA, 0xFF, 0xFF, 0xFF }, result);
}

test "SQLite encode 0x1000000 = [0xFB, 0x01, 0x00, 0x00, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0x1000000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFB, 0x01, 0x00, 0x00, 0x00 }, result);
}

test "SQLite encode 0xFFFFFFFF = [0xFB, 0xFF, 0xFF, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFB, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

test "SQLite encode 0xFFFFFFFFFFFFFFFF = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

// ---------------------------------------------------------------------------
// SQLite Varint Decode -- exact byte sequences
// ---------------------------------------------------------------------------

test "SQLite decode 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SQLite decode 1 from [0x01]" {
    const result = try decode(&[_]u8{0x01});
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SQLite decode 127 from [0x7F]" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SQLite decode 128 from [0x80]" {
    const result = try decode(&[_]u8{0x80});
    try testing.expectEqual(@as(u64, 128), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SQLite decode 240 from [0xF0]" {
    const result = try decode(&[_]u8{0xF0});
    try testing.expectEqual(@as(u64, 240), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "SQLite decode 241 from [0xF1, 0x01]" {
    const result = try decode(&[_]u8{ 0xF1, 0x01 });
    try testing.expectEqual(@as(u64, 241), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 256 from [0xF1, 0x10]" {
    const result = try decode(&[_]u8{ 0xF1, 0x10 });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 300 from [0xF1, 0x3C]" {
    const result = try decode(&[_]u8{ 0xF1, 0x3C });
    try testing.expectEqual(@as(u64, 300), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 496 from [0xF2, 0x00]" {
    const result = try decode(&[_]u8{ 0xF2, 0x00 });
    try testing.expectEqual(@as(u64, 496), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 1000 from [0xF3, 0xF8]" {
    const result = try decode(&[_]u8{ 0xF3, 0xF8 });
    try testing.expectEqual(@as(u64, 1000), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 2287 from [0xF8, 0xFF]" {
    const result = try decode(&[_]u8{ 0xF8, 0xFF });
    try testing.expectEqual(@as(u64, 2287), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "SQLite decode 2288 from [0xF9, 0x00, 0x00]" {
    const result = try decode(&[_]u8{ 0xF9, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 2288), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "SQLite decode 50000 from [0xF9, 0xBA, 0x60]" {
    const result = try decode(&[_]u8{ 0xF9, 0xBA, 0x60 });
    try testing.expectEqual(@as(u64, 50000), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "SQLite decode 65535 from [0xF9, 0xF7, 0x0F]" {
    const result = try decode(&[_]u8{ 0xF9, 0xF7, 0x0F });
    try testing.expectEqual(@as(u64, 65535), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "SQLite decode 67823 from [0xF9, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xF9, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 67823), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "SQLite decode 67824 from [0xFA, 0x01, 0x08, 0xF0]" {
    // 67824 = 0x108F0
    const result = try decode(&[_]u8{ 0xFA, 0x01, 0x08, 0xF0 });
    try testing.expectEqual(@as(u64, 67824), result.value);
    try testing.expectEqual(@as(usize, 4), result.bytes_read);
}

test "SQLite decode 0xFFFFFF from [0xFA, 0xFF, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xFA, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 4), result.bytes_read);
}

test "SQLite decode 0x1000000 from [0xFB, 0x01, 0x00, 0x00, 0x00]" {
    const result = try decode(&[_]u8{ 0xFB, 0x01, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 0x1000000), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "SQLite decode 0xFFFFFFFF from [0xFB, 0xFF, 0xFF, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0xFB, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "SQLite decode 0xFFFFFFFFFFFFFFFF from [0xFF, 0xFF x8]" {
    const result = try decode(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 9), result.bytes_read);
}

// ---------------------------------------------------------------------------
// SQLite Varint Roundtrip
// ---------------------------------------------------------------------------

test "SQLite roundtrip spec values" {
    const values = [_]u64{
        0,
        1,
        127,
        128,
        240,
        241,
        256,
        300,
        496,
        1000,
        2287,
        2288,
        50000,
        65535,
        67823,
        67824,
        0xFFFFFF,
        0x1000000,
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

test "SQLite roundtrip powers of 2" {
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

test "SQLite roundtrip boundary values" {
    const values = [_]u64{
        0,
        1,
        239,
        240, // max 1-byte
        241, // min 2-byte
        2287, // max 2-byte
        2288, // min 3-byte
        67823, // max 3-byte
        67824, // min 4-byte
        (1 << 24) - 1, // max 4-byte (0xFFFFFF)
        (1 << 24), // min 5-byte
        (1 << 32) - 1, // max 5-byte (0xFFFFFFFF)
        (1 << 32), // min 6-byte
        (@as(u64, 1) << 40) - 1, // max 6-byte
        (@as(u64, 1) << 40), // min 7-byte
        (@as(u64, 1) << 48) - 1, // max 7-byte
        (@as(u64, 1) << 48), // min 8-byte
        (@as(u64, 1) << 56) - 1, // max 8-byte
        (@as(u64, 1) << 56), // min 9-byte
        std.math.maxInt(u64), // max 9-byte
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
// SQLite Varint Encoding size verification
// ---------------------------------------------------------------------------

test "SQLite values 0-240 use exactly 1 byte" {
    var buf: [16]u8 = undefined;
    for (0..241) |v| {
        const n = try encode(@intCast(v), &buf);
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "SQLite value 241 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(241, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "SQLite value 2287 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(2287, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "SQLite value 2288 uses exactly 3 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(2288, &buf);
    try testing.expectEqual(@as(usize, 3), n);
}

test "SQLite value 67823 uses exactly 3 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(67823, &buf);
    try testing.expectEqual(@as(usize, 3), n);
}

test "SQLite value 67824 uses exactly 4 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(67824, &buf);
    try testing.expectEqual(@as(usize, 4), n);
}

test "SQLite value 0xFFFFFF uses exactly 4 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 4), n);
}

test "SQLite value 0x1000000 uses exactly 5 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0x1000000, &buf);
    try testing.expectEqual(@as(usize, 5), n);
}

test "SQLite value 0xFFFFFFFF uses exactly 5 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 5), n);
}

test "SQLite value 0xFFFFFFFFFFFFFFFF uses exactly 9 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 9), n);
}

// ---------------------------------------------------------------------------
// SQLite Varint Error cases
// ---------------------------------------------------------------------------

test "SQLite decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SQLite decode truncated 2-byte (only header)" {
    // 0xF1 means 2-byte form, but buffer has only 1 byte
    const result = decode(&[_]u8{0xF1});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SQLite decode truncated 3-byte (missing 1 byte)" {
    // 0xF9 means 3-byte form, need 2 more bytes, but only 1 present
    const result = decode(&[_]u8{ 0xF9, 0x01 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SQLite decode truncated 4-byte (missing payload)" {
    // 0xFA means 4-byte form, need 3 more bytes, but only 1 present
    const result = decode(&[_]u8{ 0xFA, 0x01 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SQLite decode truncated 9-byte (0xFF header, only 4 payload bytes)" {
    // 0xFF means 9-byte form, need 8 more bytes, but only 4 present
    const result = decode(&[_]u8{ 0xFF, 0x01, 0x02, 0x03, 0x04 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "SQLite encode buffer too small for 1-byte value" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "SQLite encode buffer too small for 2-byte value" {
    var buf: [1]u8 = undefined;
    const result = encode(241, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "SQLite encode buffer too small for 3-byte value" {
    var buf: [2]u8 = undefined;
    const result = encode(2288, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "SQLite encode buffer too small for 9-byte value" {
    var buf: [8]u8 = undefined;
    const result = encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "SQLite decode ignores trailing bytes" {
    const result = try decode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}
