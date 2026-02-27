const std = @import("std");
const ct = @import("container_types.zig");
const Blake3 = std.crypto.hash.Blake3;
const XxHash64 = std.hash.XxHash64;
const Crc32 = std.hash.crc.Crc32IsoHdlc;

/// Compute checksum of data using the given algorithm.
/// Returns a 16-byte buffer; only the first `ct.checksumLength(id)` bytes are meaningful.
pub fn compute(csum_id: ct.ChecksumId, data: []const u8) [16]u8 {
    var result: [16]u8 = .{0} ** 16;
    switch (csum_id) {
        .crc32 => {
            const hash = Crc32.hash(data);
            std.mem.writeInt(u32, result[0..4], hash, .little);
        },
        .xxhash64 => {
            const hash = XxHash64.hash(0, data);
            std.mem.writeInt(u64, result[0..8], hash, .little);
        },
        .blake3_128 => {
            var hasher = Blake3.init(.{});
            hasher.update(data);
            hasher.final(result[0..16]);
        },
    }
    return result;
}

/// Get a slice of just the meaningful checksum bytes from a 16-byte result.
pub fn slice(csum_id: ct.ChecksumId, result: *const [16]u8) []const u8 {
    const len = ct.checksumLength(csum_id);
    return result[0..len];
}

/// Verify a checksum: compute over data and compare against expected bytes.
pub fn verify(csum_id: ct.ChecksumId, data: []const u8, expected: []const u8) bool {
    const computed = compute(csum_id, data);
    const len = ct.checksumLength(csum_id);
    if (expected.len < len) return false;
    return std.mem.eql(u8, computed[0..len], expected[0..len]);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// ---------------------------------------------------------------------------
// CRC32 test vectors (CRC32/ISO-HDLC)
// ---------------------------------------------------------------------------

test "CRC32 of empty string" {
    const result = compute(.crc32, "");
    // CRC32("") = 0x00000000, little-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, result[0..4]);
    // Remaining bytes must be zero
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 12), result[4..16]);
}

test "CRC32 of 'hello'" {
    const result = compute(.crc32, "hello");
    // CRC32("hello") = 0x3610A686, little-endian = [0x86, 0xA6, 0x10, 0x36]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x86, 0xA6, 0x10, 0x36 }, result[0..4]);
}

// ---------------------------------------------------------------------------
// xxHash64 test vectors (seed=0)
// ---------------------------------------------------------------------------

test "xxHash64 of empty string" {
    const result = compute(.xxhash64, "");
    // xxHash64("", seed=0) = 0xEF46DB3751D8E999, little-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x99, 0xE9, 0xD8, 0x51, 0x37, 0xDB, 0x46, 0xEF }, result[0..8]);
    // Remaining bytes must be zero
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), result[8..16]);
}

test "xxHash64 of 'hello'" {
    const result = compute(.xxhash64, "hello");
    // xxHash64("hello", seed=0) = 0x26C7827D889F6DA3, little-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0xA3, 0x6D, 0x9F, 0x88, 0x7D, 0x82, 0xC7, 0x26 }, result[0..8]);
}

// ---------------------------------------------------------------------------
// BLAKE3-128 test vectors (first 16 bytes of BLAKE3 output)
// ---------------------------------------------------------------------------

test "BLAKE3-128 of empty string" {
    const result = compute(.blake3_128, "");
    // BLAKE3("") first 16 bytes = af1349b9f5f9a1a6a0404dea36dcc949
    try testing.expectEqualSlices(u8, &[_]u8{
        0xAF, 0x13, 0x49, 0xB9, 0xF5, 0xF9, 0xA1, 0xA6,
        0xA0, 0x40, 0x4D, 0xEA, 0x36, 0xDC, 0xC9, 0x49,
    }, &result);
}

test "BLAKE3-128 of 'hello'" {
    const result = compute(.blake3_128, "hello");
    // BLAKE3("hello") first 16 bytes = ea8f163db38682925e4491c5e58d4bb3
    try testing.expectEqualSlices(u8, &[_]u8{
        0xEA, 0x8F, 0x16, 0x3D, 0xB3, 0x86, 0x82, 0x92,
        0x5E, 0x44, 0x91, 0xC5, 0xE5, 0x8D, 0x4B, 0xB3,
    }, &result);
}

// ---------------------------------------------------------------------------
// slice() tests
// ---------------------------------------------------------------------------

test "slice returns correct length for CRC32" {
    var buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const s = slice(.crc32, &buf);
    try testing.expectEqual(@as(usize, 4), s.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, s);
}

test "slice returns correct length for xxHash64" {
    var buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const s = slice(.xxhash64, &buf);
    try testing.expectEqual(@as(usize, 8), s.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, s);
}

test "slice returns correct length for BLAKE3-128" {
    var buf = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    const s = slice(.blake3_128, &buf);
    try testing.expectEqual(@as(usize, 16), s.len);
    try testing.expectEqualSlices(u8, &buf, s);
}

// ---------------------------------------------------------------------------
// verify() round-trip tests
// ---------------------------------------------------------------------------

test "verify returns true for correct CRC32 checksum" {
    const result = compute(.crc32, "hello");
    try testing.expect(verify(.crc32, "hello", &result));
}

test "verify returns true for correct xxHash64 checksum" {
    const result = compute(.xxhash64, "hello");
    try testing.expect(verify(.xxhash64, "hello", &result));
}

test "verify returns true for correct BLAKE3-128 checksum" {
    const result = compute(.blake3_128, "hello");
    try testing.expect(verify(.blake3_128, "hello", &result));
}

test "verify returns false for wrong data (CRC32)" {
    const result = compute(.crc32, "hello");
    try testing.expect(!verify(.crc32, "world", &result));
}

test "verify returns false for wrong data (xxHash64)" {
    const result = compute(.xxhash64, "hello");
    try testing.expect(!verify(.xxhash64, "world", &result));
}

test "verify returns false for wrong data (BLAKE3-128)" {
    const result = compute(.blake3_128, "hello");
    try testing.expect(!verify(.blake3_128, "world", &result));
}

test "verify returns false for truncated expected bytes" {
    const result = compute(.crc32, "hello");
    // Only 2 bytes instead of 4 required for CRC32
    try testing.expect(!verify(.crc32, "hello", result[0..2]));
}

// ---------------------------------------------------------------------------
// Round-trip: compute then slice then verify
// ---------------------------------------------------------------------------

test "compute-slice-verify round-trip for all algorithms" {
    const data = "The quick brown fox jumps over the lazy dog";
    inline for (std.meta.fields(ct.ChecksumId)) |field| {
        const id: ct.ChecksumId = @enumFromInt(field.value);
        const result = compute(id, data);
        const meaningful = slice(id, &result);
        try testing.expect(verify(id, data, meaningful));
    }
}
