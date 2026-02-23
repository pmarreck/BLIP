const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;

/// Serialize a UTF-8 string as a UTF8 container (0x81 0x03).
/// Caller owns returned memory.
pub fn serializeUtf8(allocator: Allocator, text: []const u8) (Allocator.Error || ContainerError)![]u8 {
    return serializeLeaf(allocator, .utf8, text);
}

/// Serialize raw bytes as a RAW container (0x81 0x04).
/// Caller owns returned memory.
pub fn serializeRaw(allocator: Allocator, data: []const u8) (Allocator.Error || ContainerError)![]u8 {
    return serializeLeaf(allocator, .raw, data);
}

fn serializeLeaf(allocator: Allocator, leaf_type: ContainerType, data: []const u8) (Allocator.Error || ContainerError)![]u8 {
    const total = container.computeTotalLength(data.len);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);
    const header_len = try container.writeHeader(leaf_type, total, buf);
    @memcpy(buf[header_len..], data);
    return buf;
}

/// Read a UTF8 container. Returns the string bytes (zero-copy).
/// Validates that the container type is UTF8.
pub fn readUtf8(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .utf8) return ContainerError.InvalidContainerType;
    return view.valueSlice();
}

/// Read a RAW container. Returns the raw bytes (zero-copy).
/// Validates that the container type is RAW.
pub fn readRaw(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .raw) return ContainerError.InvalidContainerType;
    return view.valueSlice();
}

/// Read the value bytes from a leaf container (UTF8 or RAW).
/// Does not validate container type.
pub fn readLeafValue(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    return view.valueSlice();
}

// =============================================================================
// Tests
// =============================================================================

test "serializeUtf8 'hello' produces correct bytes" {
    const allocator = testing.allocator;
    const result = try serializeUtf8(allocator, "hello");
    defer allocator.free(result);
    // 0x81 0x03 = UTF8 type, 0x08 = total length 8 (2+1+5)
    // 0x68 0x65 0x6C 0x6C 0x6F = "hello"
    try testing.expectEqualSlices(u8, &[_]u8{
        0x81, 0x03, 0x08, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
    }, result);
}

test "serializeUtf8 empty string" {
    const allocator = testing.allocator;
    const result = try serializeUtf8(allocator, "");
    defer allocator.free(result);
    // total = 2 + 1 + 0 = 3
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x03, 0x03 }, result);
}

test "serializeRaw 3 bytes" {
    const allocator = testing.allocator;
    const result = try serializeRaw(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE });
    defer allocator.free(result);
    // total = 2 + 1 + 3 = 6
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x04, 0x06, 0xDE, 0xAD, 0xBE }, result);
}

test "readUtf8 round-trip" {
    const allocator = testing.allocator;
    const serialized = try serializeUtf8(allocator, "hello world");
    defer allocator.free(serialized);
    const text = try readUtf8(serialized);
    try testing.expectEqualSlices(u8, "hello world", text);
}

test "readRaw round-trip" {
    const allocator = testing.allocator;
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const serialized = try serializeRaw(allocator, &data);
    defer allocator.free(serialized);
    const read_data = try readRaw(serialized);
    try testing.expectEqualSlices(u8, &data, read_data);
}

test "readUtf8 rejects RAW container" {
    const allocator = testing.allocator;
    const raw = try serializeRaw(allocator, "test");
    defer allocator.free(raw);
    try testing.expectError(ContainerError.InvalidContainerType, readUtf8(raw));
}

test "readRaw rejects UTF8 container" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "test");
    defer allocator.free(utf8);
    try testing.expectError(ContainerError.InvalidContainerType, readRaw(utf8));
}

test "serializeUtf8 large string crosses BLIP boundary" {
    const allocator = testing.allocator;
    // 125 bytes of data -> total = 2 + 2 + 125 = 129 (needs 2-byte BLIP)
    const data = [_]u8{0x41} ** 125;
    const result = try serializeUtf8(allocator, &data);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 129), result.len);
    // Verify round-trip
    const text = try readUtf8(result);
    try testing.expectEqual(@as(usize, 125), text.len);
}

test "readLeafValue works for both types" {
    const allocator = testing.allocator;
    const utf8 = try serializeUtf8(allocator, "abc");
    defer allocator.free(utf8);
    const raw = try serializeRaw(allocator, "xyz");
    defer allocator.free(raw);
    try testing.expectEqualSlices(u8, "abc", try readLeafValue(utf8));
    try testing.expectEqualSlices(u8, "xyz", try readLeafValue(raw));
}

test "spec example: UTF8 'hello' = 0x81 0x03 0x08 + payload" {
    // From BLIP_CONTAINER_SPEC.md section UTF8 String
    const expected = [_]u8{ 0x81, 0x03, 0x08, 0x68, 0x65, 0x6C, 0x6C, 0x6F };
    const text = try readUtf8(&expected);
    try testing.expectEqualSlices(u8, "hello", text);
}
