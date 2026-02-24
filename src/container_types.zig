const std = @import("std");
const testing = std.testing;
const blip = @import("blip.zig");

/// Container type tags — BLIP sentinel values used as type identifiers.
/// Each type is the second byte of a 2-byte sentinel (0x81 0xNN).
pub const ContainerType = enum(u7) {
    array = 0x01,
    dict = 0x02,
    utf8 = 0x03,
    raw = 0x04,
    file = 0x05,
    map = 0x06,
    dir = 0x07,
    data = 0x08,
};

/// Sentinel byte constants for each container type.
pub const SENTINEL_BYTE: u8 = 0x81;
pub const PAD_END_VALUE: u7 = 0x00;

/// Convert a ContainerType to its 2-byte sentinel.
pub fn typeSentinel(ct: ContainerType) [2]u8 {
    return .{ SENTINEL_BYTE, @intFromEnum(ct) };
}

/// Try to parse a ContainerType from the first 2 bytes of a buffer.
/// Returns null if not a valid container sentinel.
pub fn parseType(buf: []const u8) ?ContainerType {
    if (buf.len < 2) return null;
    if (buf[0] != SENTINEL_BYTE) return null;
    return std.meta.intToEnum(ContainerType, @as(u7, @truncate(buf[1]))) catch null;
}

// =============================================================================
// Tests
// =============================================================================

test "typeSentinel produces correct bytes" {
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x01 }, &typeSentinel(.array));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02 }, &typeSentinel(.dict));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03 }, &typeSentinel(.utf8));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04 }, &typeSentinel(.raw));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x05 }, &typeSentinel(.file));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x06 }, &typeSentinel(.map));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x07 }, &typeSentinel(.dir));
}

test "parseType round-trips all container types" {
    inline for (std.meta.fields(ContainerType)) |field| {
        const ct: ContainerType = @enumFromInt(field.value);
        const sentinel = typeSentinel(ct);
        try testing.expectEqual(ct, parseType(&sentinel).?);
    }
}

test "parseType rejects invalid sentinels" {
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x81, 0x00 })); // PAD_END
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x81, 0x7F })); // undefined
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{ 0x82, 0x01 })); // wrong first byte
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{0x81})); // too short
    try testing.expectEqual(@as(?ContainerType, null), parseType(&[_]u8{})); // empty
}

test "all type sentinels are valid BLIP sentinels" {
    inline for (std.meta.fields(ContainerType)) |field| {
        const ct: ContainerType = @enumFromInt(field.value);
        const sentinel = typeSentinel(ct);
        try testing.expect(blip.isSentinel(&sentinel));
    }
}
