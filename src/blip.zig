const std = @import("std");

// BLIP: Byte Length Integer Prefix encoding
// See BLIP_SPEC.md for the full specification.

pub const name = "BLIP";

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
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

/// Encode a u64 value in BLIP format. Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    // Immediate mode: values 0-127 fit in a single byte
    if (value < 128) {
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }

    // Length-prefixed mode
    const L = minBytes(value);

    // Encode L into header byte(s)
    var pos: usize = 0;
    if (L < 64) {
        // Single header byte: bit 7 = 1, C = 0, bits 5-0 = L
        if (buf.len < 1 + L) return Error.BufferTooSmall;
        buf[0] = @as(u8, 0x80) | @as(u8, @intCast(L));
        pos = 1;
    } else {
        // L >= 64: use continuation encoding for L
        // First byte: bit 7 = 1, C = 1, bits 5-0 = low 6 bits of L
        const first: u8 = 0x80 | 0x40 | @as(u8, @intCast(L & 0x3F));
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = first;
        pos = 1;

        var remaining = L >> 6;
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

    // Write raw value in little-endian
    var val = value;
    for (0..L) |i| {
        buf[pos + i] = @intCast(val & 0xFF);
        val >>= 8;
    }

    return pos + L;
}

/// Encode a value as a sentinel (overlong encoding). Value must be 0-127.
/// This encodes using L=1 length-prefixed mode instead of immediate mode.
pub fn encodeSentinel(value: u7, buf: []u8) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = 0x81; // bit 7 = 1, C = 0, L = 1
    buf[1] = @intCast(value);
    return 2;
}

/// Decode a BLIP-encoded value from a buffer.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;

    const first = buf[0];

    // Immediate mode: bit 7 = 0
    if (first & 0x80 == 0) {
        return DecodeResult{
            .value = first,
            .bytes_read = 1,
        };
    }

    // Length-prefixed mode
    var L: usize = first & 0x3F; // low 6 bits
    var header_bytes: usize = 1;

    // Check continuation flag (bit 6)
    if (first & 0x40 != 0) {
        // C = 1: more L bytes follow
        var shift: u6 = 6;
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
        };
    }

    if (L > 8) return Error.Overflow; // Can't fit in u64

    // Read little-endian value from L bytes
    var value: u64 = 0;
    for (0..L) |i| {
        value |= @as(u64, buf[header_bytes + i]) << @intCast(i * 8);
    }

    return DecodeResult{
        .value = value,
        .bytes_read = header_bytes + L,
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
// Re-export modules for benchmark access (avoids multi-module file conflicts)
// ---------------------------------------------------------------------------
pub const encoding = @import("encoding.zig");
pub const bignum_mod = @import("bignum.zig");
pub const mini_blar_mod = @import("mini_blar.zig");
pub const array_mod = @import("array.zig");
pub const data_mod = @import("data.zig");
pub const peek_mod = @import("peek.zig");
pub const poke_mod = @import("poke.zig");
pub const json_serde = @import("json_serde.zig");
pub const lzma2_mod = @import("lzma2.zig");

// ---------------------------------------------------------------------------
// Pull in tests from other encoding modules
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
    _ = @import("data.zig");
    _ = @import("peek.zig");
    _ = @import("poke.zig");
    _ = @import("mini_blar.zig");
    _ = @import("json_serde.zig");
    _ = @import("lzma2.zig");
}
