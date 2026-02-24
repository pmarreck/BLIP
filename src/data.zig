const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const XxHash64 = std.hash.XxHash64;

/// Serialize a DATA container (0x81 0x08): checksummed binary data.
/// Layout: [0x81 0x08][BLIP(total)][data_bytes][xxHash64(data_bytes) 8B LE]
/// Caller owns returned memory.
pub fn serializeData(allocator: Allocator, data_bytes: []const u8) (Allocator.Error || ContainerError)![]u8 {
    const value_len = data_bytes.len + 8; // data + 8-byte hash suffix
    const total = container.computeTotalLength(value_len);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    var pos: usize = 0;

    // Write type sentinel (DATA = 0x81 0x08)
    const sentinel = ct.typeSentinel(.data);
    buf[pos] = sentinel[0];
    buf[pos + 1] = sentinel[1];
    pos += 2;

    // Write BLIP(total)
    const total_written = blip.encode(total, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += total_written;

    // Write data bytes
    @memcpy(buf[pos..][0..data_bytes.len], data_bytes);
    pos += data_bytes.len;

    // Write xxHash64 of data_bytes (8 bytes, little-endian)
    const hash_value = XxHash64.hash(0, data_bytes);
    std.mem.writeInt(u64, buf[pos..][0..8], hash_value, .little);
    pos += 8;

    std.debug.assert(pos == total);
    return buf;
}

/// Read the data content from a DATA container (excludes the trailing 8-byte hash).
/// Returns a zero-copy slice into the buffer.
pub fn readDataContent(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .data) return ContainerError.InvalidContainerType;
    const value = view.valueSlice();
    if (value.len < 8) return ContainerError.InvalidLength;
    return value[0 .. value.len - 8];
}

/// Verify the embedded xxHash64 of a DATA container.
/// Returns true if the stored hash matches the computed hash over the data bytes.
pub fn verifyDataHash(buf: []const u8) ContainerError!bool {
    const view = try container.parseHeader(buf);
    if (view.container_type != .data) return ContainerError.InvalidContainerType;
    const value = view.valueSlice();
    if (value.len < 8) return ContainerError.InvalidLength;
    const data_bytes = value[0 .. value.len - 8];
    const hash_computed = XxHash64.hash(0, data_bytes);
    const hash_stored = std.mem.readInt(u64, value[value.len - 8 ..][0..8], .little);
    return hash_computed == hash_stored;
}

// =============================================================================
// Tests
// =============================================================================

test "DATA serialize round-trip: content extractable and hash verifies" {
    const allocator = testing.allocator;
    const content = "Hello, DATA container!";
    const result = try serializeData(allocator, content);
    defer allocator.free(result);

    // Verify sentinel
    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x08), result[1]);

    // Read back content
    const data = try readDataContent(result);
    try testing.expectEqualSlices(u8, content, data);

    // Verify hash
    try testing.expect(try verifyDataHash(result));
}

test "DATA empty content is valid" {
    const allocator = testing.allocator;
    const result = try serializeData(allocator, "");
    defer allocator.free(result);

    const data = try readDataContent(result);
    try testing.expectEqual(@as(usize, 0), data.len);
    try testing.expect(try verifyDataHash(result));
}

test "DATA hash verification detects corruption" {
    const allocator = testing.allocator;
    const result = try serializeData(allocator, "integrity test");
    defer allocator.free(result);

    // Corrupt a data byte (not the hash itself)
    const corrupt_pos = 4; // somewhere in the data section
    result[corrupt_pos] ^= 0xFF;

    try testing.expect(!(try verifyDataHash(result)));
}

test "DATA readDataContent rejects non-DATA container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");
    const utf8_buf = try leaf.serializeUtf8(allocator, "not data");
    defer allocator.free(utf8_buf);

    try testing.expectError(ContainerError.InvalidContainerType, readDataContent(utf8_buf));
}

test "DATA verifyDataHash rejects non-DATA container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");
    const utf8_buf = try leaf.serializeUtf8(allocator, "not data");
    defer allocator.free(utf8_buf);

    try testing.expectError(ContainerError.InvalidContainerType, verifyDataHash(utf8_buf));
}

test "DATA binary content round-trip" {
    const allocator = testing.allocator;
    const binary = [_]u8{ 0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 };
    const result = try serializeData(allocator, &binary);
    defer allocator.free(result);

    const data = try readDataContent(result);
    try testing.expectEqualSlices(u8, &binary, data);
    try testing.expect(try verifyDataHash(result));
}

test "DATA large content" {
    const allocator = testing.allocator;
    const content = try allocator.alloc(u8, 10240);
    defer allocator.free(content);
    for (content, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const result = try serializeData(allocator, content);
    defer allocator.free(result);

    const data = try readDataContent(result);
    try testing.expectEqualSlices(u8, content, data);
    try testing.expect(try verifyDataHash(result));
}
