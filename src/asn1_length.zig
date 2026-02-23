const std = @import("std");

// ASN.1 BER/DER Length Encoding
// Used in X.509 certificates, TLS, LDAP, SNMP, etc.
//
// Short form: If value < 128, single byte = value directly.
// Long form: First byte = 0x80 | N (N = number of following length bytes, 1-126),
//            then N bytes of value in big-endian order.
// Indefinite form (0x80 alone): Not supported — we only encode definite lengths.
// DER restriction: Must use shortest encoding (no overlong). We enforce this.

pub const name = "ASN.1";

pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
};

/// Compute the minimum number of bytes needed to represent a value in big-endian.
fn minBytes(value: u64) usize {
    if (value == 0) return 1;
    const bits = 64 - @clz(value);
    return (bits + 7) / 8;
}

/// Encode a u64 value in ASN.1 BER/DER length format. Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    // Short form: value < 128 → single byte
    if (value < 128) {
        if (buf.len < 1) return Error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }

    // Long form: header byte + N big-endian payload bytes
    const n = minBytes(value);
    const total = 1 + n; // 1 header byte + N payload bytes
    if (buf.len < total) return Error.BufferTooSmall;

    // Header: 0x80 | N
    buf[0] = @as(u8, 0x80) | @as(u8, @intCast(n));

    // Write value as big-endian into buf[1..1+n]
    // MSB first: buf[1] gets the most significant byte
    var v = value;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        buf[1 + i] = @intCast(v & 0xFF);
        v >>= 8;
    }

    return total;
}

/// Decode an ASN.1 BER/DER length value from a buffer.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return Error.UnexpectedEndOfInput;

    const first = buf[0];

    // Short form: bit 7 clear → value is the byte itself
    if (first & 0x80 == 0) {
        return DecodeResult{
            .value = first,
            .bytes_read = 1,
        };
    }

    // Long form: N = first & 0x7F = number of following bytes
    const n: usize = first & 0x7F;

    // N == 0 means indefinite form (0x80), which we don't support.
    // Also reject N > 8 since we only decode into u64.
    if (n == 0 or n > 8) return Error.Overflow;

    // Need n more bytes after the header
    if (buf.len < 1 + n) return Error.UnexpectedEndOfInput;

    // Read N bytes as big-endian unsigned integer
    var value: u64 = 0;
    for (0..n) |i| {
        value = (value << 8) | buf[1 + i];
    }

    return DecodeResult{
        .value = value,
        .bytes_read = 1 + n,
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
// ASN.1 Encode — exact byte sequences from spec
// ---------------------------------------------------------------------------

test "ASN.1 encode 0 = [0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "ASN.1 encode 1 = [0x01]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "ASN.1 encode 127 = [0x7F]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, result);
}

test "ASN.1 encode 128 = [0x81, 0x80]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, result);
}

test "ASN.1 encode 255 = [0x81, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(255, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, result);
}

test "ASN.1 encode 256 = [0x82, 0x01, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(256, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x01, 0x00 }, result);
}

test "ASN.1 encode 1000 = [0x82, 0x03, 0xE8]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(1000, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x03, 0xE8 }, result);
}

test "ASN.1 encode 65535 = [0x82, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65535, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xFF, 0xFF }, result);
}

test "ASN.1 encode 65536 = [0x83, 0x01, 0x00, 0x00]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(65536, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x01, 0x00, 0x00 }, result);
}

test "ASN.1 encode 0xFFFFFFFF = [0x84, 0xFF, 0xFF, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x84, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

test "ASN.1 encode 0xFFFFFFFFFFFFFFFF = [0x88, 0xFF x8]" {
    var buf: [16]u8 = undefined;
    const result = encodeToSlice(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, result);
}

// ---------------------------------------------------------------------------
// ASN.1 Decode — exact byte sequences
// ---------------------------------------------------------------------------

test "ASN.1 decode 0 from [0x00]" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "ASN.1 decode 1 from [0x01]" {
    const result = try decode(&[_]u8{0x01});
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "ASN.1 decode 127 from [0x7F]" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "ASN.1 decode 128 from [0x81, 0x80]" {
    const result = try decode(&[_]u8{ 0x81, 0x80 });
    try testing.expectEqual(@as(u64, 128), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "ASN.1 decode 255 from [0x81, 0xFF]" {
    const result = try decode(&[_]u8{ 0x81, 0xFF });
    try testing.expectEqual(@as(u64, 255), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
}

test "ASN.1 decode 256 from [0x82, 0x01, 0x00]" {
    const result = try decode(&[_]u8{ 0x82, 0x01, 0x00 });
    try testing.expectEqual(@as(u64, 256), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "ASN.1 decode 1000 from [0x82, 0x03, 0xE8]" {
    const result = try decode(&[_]u8{ 0x82, 0x03, 0xE8 });
    try testing.expectEqual(@as(u64, 1000), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "ASN.1 decode 65535 from [0x82, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0x82, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 65535), result.value);
    try testing.expectEqual(@as(usize, 3), result.bytes_read);
}

test "ASN.1 decode 65536 from [0x83, 0x01, 0x00, 0x00]" {
    const result = try decode(&[_]u8{ 0x83, 0x01, 0x00, 0x00 });
    try testing.expectEqual(@as(u64, 65536), result.value);
    try testing.expectEqual(@as(usize, 4), result.bytes_read);
}

test "ASN.1 decode 0xFFFFFFFF from [0x84, 0xFF, 0xFF, 0xFF, 0xFF]" {
    const result = try decode(&[_]u8{ 0x84, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 5), result.bytes_read);
}

test "ASN.1 decode 0xFFFFFFFFFFFFFFFF from [0x88, 0xFF x8]" {
    const result = try decode(&[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), result.value);
    try testing.expectEqual(@as(usize, 9), result.bytes_read);
}

// ---------------------------------------------------------------------------
// ASN.1 Roundtrip
// ---------------------------------------------------------------------------

test "ASN.1 roundtrip spec values" {
    const values = [_]u64{
        0,
        1,
        127,
        128,
        255,
        256,
        1000,
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

test "ASN.1 roundtrip powers of 2" {
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

test "ASN.1 roundtrip boundary values" {
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
// ASN.1 Error cases
// ---------------------------------------------------------------------------

test "ASN.1 decode empty buffer returns UnexpectedEndOfInput" {
    const result = decode(&[_]u8{});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "ASN.1 decode truncated long form (header only, no payload)" {
    // 0x81 says 1 byte follows, but buffer ends after header
    const result = decode(&[_]u8{0x81});
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "ASN.1 decode truncated long form (partial payload)" {
    // 0x82 says 2 bytes follow, but only 1 byte present
    const result = decode(&[_]u8{ 0x82, 0x01 });
    try testing.expectError(Error.UnexpectedEndOfInput, result);
}

test "ASN.1 encode buffer too small for short form" {
    var buf: [0]u8 = undefined;
    const result = encode(0, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "ASN.1 encode buffer too small for long form" {
    var buf: [1]u8 = undefined;
    const result = encode(128, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "ASN.1 encode buffer too small for long form (needs 3 bytes, has 2)" {
    var buf: [2]u8 = undefined;
    const result = encode(256, &buf);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "ASN.1 decode overflow (N > 8 bytes would exceed u64)" {
    // 0x89 = N=9, which would need 9 payload bytes — exceeds u64
    const result = decode(&[_]u8{ 0x89, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectError(Error.Overflow, result);
}

test "ASN.1 decode indefinite form (0x80) returns Overflow" {
    // 0x80 = indefinite form, not supported
    const result = decode(&[_]u8{0x80});
    try testing.expectError(Error.Overflow, result);
}

test "ASN.1 decode ignores trailing bytes" {
    const result = try decode(&[_]u8{ 0x01, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 1), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

// ---------------------------------------------------------------------------
// ASN.1 Encoding size verification
// ---------------------------------------------------------------------------

test "ASN.1 short form values use exactly 1 byte" {
    var buf: [16]u8 = undefined;
    for (0..128) |v| {
        const n = try encode(@intCast(v), &buf);
        try testing.expectEqual(@as(usize, 1), n);
    }
}

test "ASN.1 value 128 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(128, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "ASN.1 value 255 uses exactly 2 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(255, &buf);
    try testing.expectEqual(@as(usize, 2), n);
}

test "ASN.1 value 256 uses exactly 3 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(256, &buf);
    try testing.expectEqual(@as(usize, 3), n);
}

test "ASN.1 value 0xFFFFFFFF uses exactly 5 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 5), n);
}

test "ASN.1 value 0xFFFFFFFFFFFFFFFF uses exactly 9 bytes" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 9), n);
}

// ---------------------------------------------------------------------------
// ASN.1 minBytes helper
// ---------------------------------------------------------------------------

test "ASN.1 minBytes(0) = 1" {
    try testing.expectEqual(@as(usize, 1), minBytes(0));
}

test "ASN.1 minBytes(1) = 1" {
    try testing.expectEqual(@as(usize, 1), minBytes(1));
}

test "ASN.1 minBytes(127) = 1" {
    try testing.expectEqual(@as(usize, 1), minBytes(127));
}

test "ASN.1 minBytes(128) = 1" {
    try testing.expectEqual(@as(usize, 1), minBytes(128));
}

test "ASN.1 minBytes(255) = 1" {
    try testing.expectEqual(@as(usize, 1), minBytes(255));
}

test "ASN.1 minBytes(256) = 2" {
    try testing.expectEqual(@as(usize, 2), minBytes(256));
}

test "ASN.1 minBytes(65535) = 2" {
    try testing.expectEqual(@as(usize, 2), minBytes(65535));
}

test "ASN.1 minBytes(65536) = 3" {
    try testing.expectEqual(@as(usize, 3), minBytes(65536));
}

test "ASN.1 minBytes(0xFFFFFFFF) = 4" {
    try testing.expectEqual(@as(usize, 4), minBytes(0xFFFFFFFF));
}

test "ASN.1 minBytes(0xFFFFFFFFFFFFFFFF) = 8" {
    try testing.expectEqual(@as(usize, 8), minBytes(0xFFFFFFFFFFFFFFFF));
}
