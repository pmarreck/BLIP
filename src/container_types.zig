const std = @import("std");
const testing = std.testing;
const blip = @import("blip.zig");

// =============================================================================
// v2 Attribute Sigils and Type IDs
// =============================================================================

/// Attribute sigils — identify attributes in the LP container envelope.
/// Each sigil is the second byte of a 2-byte sentinel (0x81 0xNN).
/// Sigils are sorted by value within a container: TYPE first, VAL last.
pub const AttributeSigil = enum(u7) {
    /// Container type ID (required, always first attribute)
    type_attr = 0x01,
    /// Compression algorithm ID
    comp = 0x10,
    /// Decompressed length (required when comp is present)
    decomp_len = 0x11,
    /// Checksum algorithm ID
    csum = 0x12,
    /// Encryption algorithm ID
    enc = 0x13,
    /// Segmentation metadata (v3): stream ID, segment index, total (or NIL)
    seg = 0x14,
    /// Digital signature (future)
    sig = 0x20,
    /// Value/payload (required, always last attribute)
    val = 0x7F,
};

/// Container type IDs — the value after a TYPE attribute sigil.
/// These are BLIP integers, so the namespace is effectively infinite.
/// Predefined types use IDs 1-7; user-defined types start at 8.
pub const ContainerTypeId = enum(u7) {
    array = 1,
    dict = 2,
    utf8 = 3,
    data = 4,
    file = 5,
    map = 6,
    dir = 7,
    /// Transport-layer wrapper around a slice of a larger BLIP byte stream (v3)
    segment = 9,
};

/// Compression algorithm IDs — the value after a COMP attribute sigil.
pub const CompressionId = enum(u7) {
    lzma2 = 1,
    bzip2 = 2,
    lz4 = 3,
    zstd = 4,
};

/// Checksum algorithm IDs — the value after a CSUM attribute sigil.
pub const ChecksumId = enum(u7) {
    crc32 = 1,
    xxhash64 = 2,
    blake3_128 = 3,
};

/// Encryption algorithm IDs — the value after an ENC attribute sigil.
pub const EncryptionId = enum(u7) {
    aes_256_gcm = 1,
    chacha20_poly1305 = 2,
};

/// Key derivation function IDs — used within the ENC attribute payload.
pub const KdfId = enum(u7) {
    argon2id = 1,
    pbkdf2_sha256 = 2,
};

/// Sentinel byte constant — first byte of every 2-byte sentinel.
pub const SENTINEL_BYTE: u8 = 0x81;

/// Reserved pad/end value — not a valid sigil.
pub const PAD_END_VALUE: u7 = 0x00;

/// Return the byte length of a checksum for the given algorithm.
pub fn checksumLength(id: ChecksumId) u8 {
    return switch (id) {
        .crc32 => 4,
        .xxhash64 => 8,
        .blake3_128 => 16,
    };
}

/// Return the byte length of an authentication tag for the given encryption algorithm.
pub fn authTagLength(id: EncryptionId) u8 {
    return switch (id) {
        .aes_256_gcm => 16,
        .chacha20_poly1305 => 16,
    };
}

/// Return the byte length of a nonce/IV for the given encryption algorithm.
pub fn encNonceLength(id: EncryptionId) u8 {
    return switch (id) {
        .aes_256_gcm => 12,
        .chacha20_poly1305 => 12,
    };
}

/// Salt length for key derivation (bytes).
pub const ENC_SALT_LEN: u8 = 16;

/// Produce the 2-byte sentinel for an attribute sigil.
pub fn attrSentinel(attr: AttributeSigil) [2]u8 {
    return .{ SENTINEL_BYTE, @intFromEnum(attr) };
}

/// Try to parse an AttributeSigil from a 2-byte buffer.
/// Returns null if the buffer is too short, has wrong first byte,
/// or the second byte isn't a valid sigil.
pub fn parseAttrSigil(buf: []const u8) ?AttributeSigil {
    if (buf.len < 2) return null;
    if (buf[0] != SENTINEL_BYTE) return null;
    return std.enums.fromInt(AttributeSigil, @as(u7, @truncate(buf[1])));
}

// =============================================================================
// v2 Tests
// =============================================================================

test "AttributeSigil values match design spec" {
    try testing.expectEqual(@as(u7, 0x01), @intFromEnum(AttributeSigil.type_attr));
    try testing.expectEqual(@as(u7, 0x10), @intFromEnum(AttributeSigil.comp));
    try testing.expectEqual(@as(u7, 0x11), @intFromEnum(AttributeSigil.decomp_len));
    try testing.expectEqual(@as(u7, 0x12), @intFromEnum(AttributeSigil.csum));
    try testing.expectEqual(@as(u7, 0x13), @intFromEnum(AttributeSigil.enc));
    try testing.expectEqual(@as(u7, 0x20), @intFromEnum(AttributeSigil.sig));
    try testing.expectEqual(@as(u7, 0x7F), @intFromEnum(AttributeSigil.val));
}

test "ContainerTypeId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(ContainerTypeId.array));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(ContainerTypeId.dict));
    try testing.expectEqual(@as(u7, 3), @intFromEnum(ContainerTypeId.utf8));
    try testing.expectEqual(@as(u7, 4), @intFromEnum(ContainerTypeId.data));
    try testing.expectEqual(@as(u7, 5), @intFromEnum(ContainerTypeId.file));
    try testing.expectEqual(@as(u7, 6), @intFromEnum(ContainerTypeId.map));
    try testing.expectEqual(@as(u7, 7), @intFromEnum(ContainerTypeId.dir));
}

test "CompressionId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(CompressionId.lzma2));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(CompressionId.bzip2));
    try testing.expectEqual(@as(u7, 3), @intFromEnum(CompressionId.lz4));
    try testing.expectEqual(@as(u7, 4), @intFromEnum(CompressionId.zstd));
}

test "ChecksumId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(ChecksumId.crc32));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(ChecksumId.xxhash64));
    try testing.expectEqual(@as(u7, 3), @intFromEnum(ChecksumId.blake3_128));
}

test "checksumLength returns correct byte lengths" {
    try testing.expectEqual(@as(u8, 4), checksumLength(.crc32));
    try testing.expectEqual(@as(u8, 8), checksumLength(.xxhash64));
    try testing.expectEqual(@as(u8, 16), checksumLength(.blake3_128));
}

test "attrSentinel produces correct bytes" {
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, &attrSentinel(.type_attr));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x10 }, &attrSentinel(.comp));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x11 }, &attrSentinel(.decomp_len));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x12 }, &attrSentinel(.csum));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x13 }, &attrSentinel(.enc));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x20 }, &attrSentinel(.sig));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x7F }, &attrSentinel(.val));
}

test "parseAttrSigil round-trips all sigils" {
    inline for (std.meta.fields(AttributeSigil)) |field| {
        const sigil: AttributeSigil = @enumFromInt(field.value);
        const sentinel = attrSentinel(sigil);
        try testing.expectEqual(sigil, parseAttrSigil(&sentinel).?);
    }
}

test "parseAttrSigil rejects invalid inputs" {
    // PAD_END is not a valid sigil
    try testing.expectEqual(@as(?AttributeSigil, null), parseAttrSigil(&[_]u8{ 0x81, 0x00 }));
    // Undefined sigil value
    try testing.expectEqual(@as(?AttributeSigil, null), parseAttrSigil(&[_]u8{ 0x81, 0x05 }));
    // Wrong first byte
    try testing.expectEqual(@as(?AttributeSigil, null), parseAttrSigil(&[_]u8{ 0x82, 0x01 }));
    // Too short
    try testing.expectEqual(@as(?AttributeSigil, null), parseAttrSigil(&[_]u8{0x81}));
    // Empty
    try testing.expectEqual(@as(?AttributeSigil, null), parseAttrSigil(&[_]u8{}));
}

test "all attribute sentinels are valid BLIP sentinels" {
    inline for (std.meta.fields(AttributeSigil)) |field| {
        const sigil: AttributeSigil = @enumFromInt(field.value);
        const sentinel = attrSentinel(sigil);
        try testing.expect(blip.isSentinel(&sentinel));
    }
}

test "attribute sigils are sorted (TYPE < COMP < DECOMP_LEN < CSUM < ENC < SIG < VAL)" {
    try testing.expect(@intFromEnum(AttributeSigil.type_attr) < @intFromEnum(AttributeSigil.comp));
    try testing.expect(@intFromEnum(AttributeSigil.comp) < @intFromEnum(AttributeSigil.decomp_len));
    try testing.expect(@intFromEnum(AttributeSigil.decomp_len) < @intFromEnum(AttributeSigil.csum));
    try testing.expect(@intFromEnum(AttributeSigil.csum) < @intFromEnum(AttributeSigil.enc));
    try testing.expect(@intFromEnum(AttributeSigil.enc) < @intFromEnum(AttributeSigil.sig));
    try testing.expect(@intFromEnum(AttributeSigil.sig) < @intFromEnum(AttributeSigil.val));
}

test "EncryptionId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(EncryptionId.aes_256_gcm));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(EncryptionId.chacha20_poly1305));
}

test "KdfId values match design spec" {
    try testing.expectEqual(@as(u7, 1), @intFromEnum(KdfId.argon2id));
    try testing.expectEqual(@as(u7, 2), @intFromEnum(KdfId.pbkdf2_sha256));
}

test "ENC sigil fits in sorted order" {
    try testing.expect(@intFromEnum(AttributeSigil.csum) < @intFromEnum(AttributeSigil.enc));
    try testing.expect(@intFromEnum(AttributeSigil.enc) < @intFromEnum(AttributeSigil.sig));
}

test "authTagLength returns correct sizes" {
    try testing.expectEqual(@as(u8, 16), authTagLength(.aes_256_gcm));
    try testing.expectEqual(@as(u8, 16), authTagLength(.chacha20_poly1305));
}

test "encNonceLength returns correct sizes" {
    try testing.expectEqual(@as(u8, 12), encNonceLength(.aes_256_gcm));
    try testing.expectEqual(@as(u8, 12), encNonceLength(.chacha20_poly1305));
}

// ---------------------------------------------------------------------------
// v3: SEGMENT type + SEG attribute sigil
// ---------------------------------------------------------------------------

test "SEG attribute sigil is 0x14" {
    try testing.expectEqual(@as(u7, 0x14), @intFromEnum(AttributeSigil.seg));
}

test "SEG sentinel is 0x81 0x14" {
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x14 }, &attrSentinel(.seg));
}

test "SEG sigil sort-order: ENC < SEG < SIG < VAL" {
    try testing.expect(@intFromEnum(AttributeSigil.enc) < @intFromEnum(AttributeSigil.seg));
    try testing.expect(@intFromEnum(AttributeSigil.seg) < @intFromEnum(AttributeSigil.sig));
    try testing.expect(@intFromEnum(AttributeSigil.sig) < @intFromEnum(AttributeSigil.val));
}

test "parseAttrSigil round-trips SEG sigil" {
    const sentinel = attrSentinel(.seg);
    try testing.expectEqual(AttributeSigil.seg, parseAttrSigil(&sentinel).?);
}

test "ContainerTypeId.segment is 9" {
    try testing.expectEqual(@as(u7, 9), @intFromEnum(ContainerTypeId.segment));
}

