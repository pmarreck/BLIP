const std = @import("std");
const Allocator = std.mem.Allocator;
const container = @import("container.zig");
const ct = @import("container_types.zig");
const csum = @import("checksum.zig");
const testing = std.testing;

const ContainerTypeId = ct.ContainerTypeId;
const ChecksumId = ct.ChecksumId;
const LPOptions = container.LPOptions;
const LPContainerError = container.LPContainerError;

/// Error set for leaf serialization.
pub const LeafError = Allocator.Error || LPContainerError;

/// Internal helper: serialize a leaf container in v2 LP format.
///
/// Layout: [BLIP(total_length)] [0x81 0x01] [BLIP(type_id)] [optional CSUM attr] [0x81 0x7F] [payload] [checksum?]
///
/// Caller owns returned memory.
fn serializeLeaf(allocator: Allocator, type_id: ContainerTypeId, payload: []const u8, options: LPOptions) LeafError![]u8 {
    const total = container.computeLPLength(type_id, payload.len, options);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    // Write LP header (total_length + attributes + VAL sentinel)
    const header_len = try container.writeLPHeader(buf, type_id, total, options);

    // Copy payload bytes after header
    @memcpy(buf[header_len .. header_len + payload.len], payload);

    // If checksum is requested, compute over bytes[0..total-csum_len] and append
    if (options.csum_id) |csum_id| {
        const csum_len = ct.checksumLength(csum_id);
        const csum_offset = @as(usize, @intCast(total)) - csum_len;
        const hash = csum.compute(csum_id, buf[0..csum_offset]);
        @memcpy(buf[csum_offset..@intCast(total)], hash[0..csum_len]);
    }

    return buf;
}

/// Serialize a UTF-8 string as a UTF8 container (type_id=3) in v2 LP format.
/// No checksum by default (inner container convention).
/// Caller owns returned memory.
pub fn serializeUtf8(allocator: Allocator, text: []const u8) LeafError![]u8 {
    return serializeLeaf(allocator, .utf8, text, .{});
}

/// Serialize binary data as a DATA container (type_id=4) in v2 LP format.
/// No checksum by default (inner container convention).
/// Caller owns returned memory.
pub fn serializeData(allocator: Allocator, data_bytes: []const u8) LeafError![]u8 {
    return serializeLeaf(allocator, .data, data_bytes, .{});
}

/// Serialize a UTF-8 string with custom LP options (e.g., checksum).
/// Caller owns returned memory.
pub fn serializeUtf8WithOptions(allocator: Allocator, text: []const u8, options: LPOptions) LeafError![]u8 {
    return serializeLeaf(allocator, .utf8, text, options);
}

/// Serialize binary data with custom LP options (e.g., checksum).
/// Caller owns returned memory.
pub fn serializeDataWithOptions(allocator: Allocator, data_bytes: []const u8, options: LPOptions) LeafError![]u8 {
    return serializeLeaf(allocator, .data, data_bytes, options);
}

/// Read the payload value from a leaf container (UTF8 or DATA).
/// Does not validate container type. Returns the payload excluding any checksum bytes.
pub fn readLeafValue(buf: []const u8) LPContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    return view.payloadSlice();
}

/// Read a UTF8 container. Returns the string bytes (zero-copy).
/// Validates that the container type is UTF8.
pub fn readUtf8(buf: []const u8) LPContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    if (view.type_id != .utf8) return container.ContainerError.InvalidContainerType;
    return view.payloadSlice();
}

/// Read a DATA container. Returns the data bytes (zero-copy).
/// Validates that the container type is DATA.
pub fn readData(buf: []const u8) LPContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    if (view.type_id != .data) return container.ContainerError.InvalidContainerType;
    return view.payloadSlice();
}

/// Verify the embedded checksum of a leaf container.
/// If the container has no CSUM attribute, returns true (nothing to check).
/// If CSUM is present, recomputes the checksum and compares.
pub fn verifyLeafChecksum(buf: []const u8) LPContainerError!bool {
    const view = try container.parseLPHeader(buf);
    const csum_id = view.csum_id orelse return true; // No checksum = valid
    const csum_len = ct.checksumLength(csum_id);
    const csum_offset = @as(usize, @intCast(view.total_length)) - csum_len;
    return csum.verify(csum_id, buf[0..csum_offset], view.checksumSlice());
}

// =============================================================================
// Backward-compatibility shims (v1 -> v2 migration)
//
// These aliases allow unmigrated modules (array.zig, dict.zig, peek.zig,
// poke.zig, mini_blar.zig, lzma2.zig, lib.zig) to continue using the old
// names until they are individually migrated to v2 LP format.
// =============================================================================

/// Legacy alias: serializeRaw -> serializeData.
/// Deprecated: use serializeData() instead.
pub const serializeRaw = serializeData;

/// Legacy alias: readRaw -> readData.
/// Deprecated: use readData() instead.
pub const readRaw = readData;

/// Legacy alias: readDataContent -> readData.
/// Deprecated: use readData() instead.
/// Note: in v1, readDataContent stripped the 8-byte xxHash64 suffix.
/// In v2 LP format, checksums are handled via the CSUM attribute and
/// readData() returns only the payload (excluding checksum bytes).
pub const readDataContent = readData;

/// Legacy alias: verifyDataHash -> verifyLeafChecksum.
/// Deprecated: use verifyLeafChecksum() instead.
/// Note: in v1, this verified the inline xxHash64. In v2, this verifies
/// the CSUM attribute checksum (returns true if no checksum present).
pub const verifyDataHash = verifyLeafChecksum;

// =============================================================================
// Tests — v2 LP format
// =============================================================================

test "serializeUtf8 'hello' produces correct LP bytes" {
    const allocator = testing.allocator;
    // Expected: [BLIP(11)] [0x81 0x01] [0x03] [0x81 0x7F] "hello"
    // total = 1 + 2+1 + 2 + 5 = 11
    // BLIP(11) = 0x0B (immediate)
    const result = try serializeUtf8(allocator, "hello");
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 11), result.len);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x0B, // BLIP(11)
        0x81, 0x01, // TYPE sentinel
        0x03, // type_id = utf8(3)
        0x81, 0x7F, // VAL sentinel
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // "hello"
    }, result);
}

test "serializeUtf8 empty string" {
    const allocator = testing.allocator;
    // total = 1 + 2+1 + 2 + 0 = 6
    const result = try serializeUtf8(allocator, "");
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 6), result.len);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x06, // BLIP(6)
        0x81, 0x01, // TYPE sentinel
        0x03, // type_id = utf8(3)
        0x81, 0x7F, // VAL sentinel
    }, result);
}

test "serializeData 3 bytes" {
    const allocator = testing.allocator;
    // total = 1 + 2+1 + 2 + 3 = 9
    const result = try serializeData(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE });
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 9), result.len);
    // Check TYPE is data(4)
    try testing.expectEqual(@as(u8, 0x04), result[3]);
    try testing.expectEqualSlices(u8, &[_]u8{
        0x09, // BLIP(9)
        0x81, 0x01, // TYPE sentinel
        0x04, // type_id = data(4)
        0x81, 0x7F, // VAL sentinel
        0xDE, 0xAD, 0xBE, // payload
    }, result);
}

test "readUtf8 round-trip" {
    const allocator = testing.allocator;
    const serialized = try serializeUtf8(allocator, "hello world");
    defer allocator.free(serialized);
    const text = try readUtf8(serialized);
    try testing.expectEqualSlices(u8, "hello world", text);
}

test "readData round-trip" {
    const allocator = testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const serialized = try serializeData(allocator, &data);
    defer allocator.free(serialized);
    const read_data = try readData(serialized);
    try testing.expectEqualSlices(u8, &data, read_data);
}

test "readLeafValue works for both types" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "abc");
    defer allocator.free(utf8);
    const data_buf = try serializeData(allocator, "xyz");
    defer allocator.free(data_buf);
    try testing.expectEqualSlices(u8, "abc", try readLeafValue(utf8));
    try testing.expectEqualSlices(u8, "xyz", try readLeafValue(data_buf));
}

test "readUtf8 rejects DATA container" {
    const allocator = testing.allocator;
    const data_buf = try serializeData(allocator, "test");
    defer allocator.free(data_buf);
    try testing.expectError(container.ContainerError.InvalidContainerType, readUtf8(data_buf));
}

test "readData rejects UTF8 container" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "test");
    defer allocator.free(utf8);
    try testing.expectError(container.ContainerError.InvalidContainerType, readData(utf8));
}

test "serializeDataWithOptions with BLAKE3-128 checksum" {
    const allocator = testing.allocator;
    const result = try serializeDataWithOptions(allocator, "test", .{ .csum_id = .blake3_128 });
    defer allocator.free(result);
    // Without checksum: total = 1 + 2+1 + 2 + 4 = 10
    // With BLAKE3-128: add 2 (CSUM sentinel) + 1 (CSUM id) + 16 (checksum bytes) = 19 extra
    // total = 1 + 2+1 + 2+1 + 2 + 4 + 16 = 29
    // BLIP(29) = 0x1D (immediate)
    try testing.expectEqual(@as(usize, 29), result.len);
    try testing.expect(try verifyLeafChecksum(result));
}

test "serializeDataWithOptions with xxHash64 checksum" {
    const allocator = testing.allocator;
    const result = try serializeDataWithOptions(allocator, "test", .{ .csum_id = .xxhash64 });
    defer allocator.free(result);
    // With xxHash64: add 2 (CSUM sentinel) + 1 (CSUM id) + 8 (checksum bytes) = 11 extra
    // total = 1 + 2+1 + 2+1 + 2 + 4 + 8 = 21
    try testing.expectEqual(@as(usize, 21), result.len);
    try testing.expect(try verifyLeafChecksum(result));
}

test "serializeUtf8WithOptions with CRC32 checksum" {
    const allocator = testing.allocator;
    const result = try serializeUtf8WithOptions(allocator, "hello", .{ .csum_id = .crc32 });
    defer allocator.free(result);
    // total = 1 + 2+1 + 2+1 + 2 + 5 + 4 = 18
    try testing.expectEqual(@as(usize, 18), result.len);
    try testing.expect(try verifyLeafChecksum(result));
    // Round-trip the payload
    const text = try readUtf8(result);
    try testing.expectEqualSlices(u8, "hello", text);
}

test "verifyLeafChecksum returns true for no checksum" {
    const allocator = testing.allocator;
    const result = try serializeData(allocator, "test");
    defer allocator.free(result);
    try testing.expect(try verifyLeafChecksum(result));
}

test "verifyLeafChecksum detects corruption" {
    const allocator = testing.allocator;
    const result = try serializeDataWithOptions(allocator, "test data", .{ .csum_id = .blake3_128 });
    defer allocator.free(result);
    // Corrupt a payload byte (somewhere in the middle, after header but before checksum)
    const view = try container.parseLPHeader(result);
    result[view.val_offset] ^= 0xFF;
    try testing.expect(!(try verifyLeafChecksum(result)));
}

test "serializeUtf8 large string crosses BLIP boundary" {
    const allocator = testing.allocator;
    // 121 bytes of data -> total for LP format:
    // attr_overhead = 2 (TYPE sentinel) + 1 (BLIP(3)) + 2 (VAL sentinel) = 5
    // total = blip_size(total) + 5 + 121
    // Try total = 1 + 5 + 121 = 127. blip_size(127) = 1. Yes!
    const data = [_]u8{0x41} ** 121;
    const result = try serializeUtf8(allocator, &data);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 127), result.len);
    // Verify round-trip
    const text = try readUtf8(result);
    try testing.expectEqual(@as(usize, 121), text.len);

    // 122 bytes of data -> total crosses the BLIP boundary
    // total = blip_size(total) + 5 + 122
    // Try total = 1 + 127 = 128. blip_size(128) = 2. No (1 != 2).
    // Try total = 2 + 127 = 129. blip_size(129) = 2. Yes!
    const data2 = [_]u8{0x41} ** 122;
    const result2 = try serializeUtf8(allocator, &data2);
    defer allocator.free(result2);
    try testing.expectEqual(@as(usize, 129), result2.len);
    const text2 = try readUtf8(result2);
    try testing.expectEqual(@as(usize, 122), text2.len);
}

test "serializeData empty content" {
    const allocator = testing.allocator;
    const result = try serializeData(allocator, "");
    defer allocator.free(result);
    // total = 1 + 2+1 + 2 + 0 = 6
    try testing.expectEqual(@as(usize, 6), result.len);
    const data = try readData(result);
    try testing.expectEqual(@as(usize, 0), data.len);
}

test "serializeData binary round-trip" {
    const allocator = testing.allocator;
    const binary = [_]u8{ 0x00, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01 };
    const result = try serializeData(allocator, &binary);
    defer allocator.free(result);
    const data = try readData(result);
    try testing.expectEqualSlices(u8, &binary, data);
}

test "serializeData large content" {
    const allocator = testing.allocator;
    const content = try allocator.alloc(u8, 10240);
    defer allocator.free(content);
    for (content, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }
    const result = try serializeData(allocator, content);
    defer allocator.free(result);
    const data = try readData(result);
    try testing.expectEqualSlices(u8, content, data);
}

test "checksum round-trip with all checksum algorithms" {
    const allocator = testing.allocator;
    const payload = "The quick brown fox jumps over the lazy dog";
    inline for (std.meta.fields(ChecksumId)) |field| {
        const id: ChecksumId = @enumFromInt(field.value);
        const result = try serializeDataWithOptions(allocator, payload, .{ .csum_id = id });
        defer allocator.free(result);
        try testing.expect(try verifyLeafChecksum(result));
        const data = try readData(result);
        try testing.expectEqualSlices(u8, payload, data);
    }
}
