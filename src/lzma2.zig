const std = @import("std");
const Allocator = std.mem.Allocator;
const container = @import("container.zig");
const ct = @import("container_types.zig");
const csum_mod = @import("checksum.zig");
const build_options = @import("build_options");
const compression = if (build_options.enable_compression)
    @import("compression.zig")
else
    @import("compression_stub.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const LPContainerError = container.LPContainerError;

/// Compress arbitrary bytes (typically a serialized archive) into a DATA
/// container with the COMP=lzma2, DECOMP_LEN, and CSUM=blake3_128 attributes.
///
/// Delegates to the unified compression module.
/// Caller owns returned memory.
pub fn compressContainer(allocator: Allocator, container_bytes: []const u8) (Allocator.Error || ContainerError || compression.CompressionError)![]u8 {
    return compression.compressContainer(allocator, .lzma2, container_bytes, null, null, null, 0);
}

/// Decompress an LP container with COMP=lzma2 attribute, verifying checksum
/// before decompression.
///
/// Delegates to the unified compression module.
/// Caller owns returned memory.
pub fn decompressContainer(allocator: Allocator, buf: []const u8) (Allocator.Error || ContainerError || compression.CompressionError)![]u8 {
    return compression.decompressContainer(allocator, buf);
}

/// Quick check if a buffer starts with an LP container that has a COMP attribute.
/// Delegates to the unified compression module.
pub const isCompressed = compression.isCompressed;

/// Reader for zero-copy header inspection without decompressing.
pub const Lzma2Reader = struct {
    lp_view: container.LPContainerView,

    pub fn init(buf: []const u8) ContainerError!Lzma2Reader {
        const view = container.parseLPHeader(buf) catch |e| switch (e) {
            // Map LP-specific errors to ContainerError variants
            inline else => |err| return err,
        };
        if (view.comp_id == null) return ContainerError.InvalidContainerType;
        if (view.comp_id.? != .lzma2) return ContainerError.InvalidContainerType;
        return .{ .lp_view = view };
    }

    /// Verify the embedded checksum (BLAKE3-128 or other CSUM attribute).
    pub fn verifyChecksum(self: Lzma2Reader) bool {
        const csum_id = self.lp_view.csum_id orelse return true; // no checksum = valid
        const csum_len = ct.checksumLength(csum_id);
        const total: usize = @intCast(self.lp_view.total_length);
        const data_to_check = self.lp_view.buf[0 .. total - csum_len];
        return csum_mod.verify(csum_id, data_to_check, self.lp_view.checksumSlice());
    }

    /// Returns the size of the compressed payload (bytes).
    pub fn compressedSize(self: Lzma2Reader) usize {
        return self.lp_view.payloadSlice().len;
    }

    /// Returns the decompressed (original) size.
    pub fn uncompressedSize(self: Lzma2Reader) u64 {
        return self.lp_view.decomp_len orelse 0;
    }
};

/// Verify the embedded checksum of a compressed LP container.
pub fn verifyChecksum(buf: []const u8) ContainerError!bool {
    const reader = try Lzma2Reader.init(buf);
    return reader.verifyChecksum();
}

// =============================================================================
// Tests
// =============================================================================

test "LZMA2 round-trip: compress and decompress a DATA container" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, LZMA2!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    // Decompress and compare
    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 hash/checksum verification" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "integrity test");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    try testing.expect(try verifyChecksum(compressed));
}

test "LZMA2 checksum detects corruption" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "corrupt me");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    // Corrupt a byte in the compressed data (not in checksum area)
    compressed[compressed.len / 2] ^= 0xFF;

    try testing.expect(!(try verifyChecksum(compressed)));
}

test "LZMA2 wraps an ARRAY container" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");
    const array_mod = @import("array.zig");

    const elem1 = try leaf.serializeUtf8(allocator, "first");
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "second");
    defer allocator.free(elem2);

    const inner = try array_mod.serializeArray(allocator, &[_][]const u8{ elem1, elem2 });
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 Reader: header inspection without decompression" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const content = "Hello, world! This is some compressible text content.";
    const inner = try leaf.serializeData(allocator, content);
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const reader = try Lzma2Reader.init(compressed);
    try testing.expectEqual(@as(u64, inner.len), reader.uncompressedSize());
    try testing.expect(reader.verifyChecksum());
    try testing.expect(reader.compressedSize() > 0);
}

test "LZMA2 compression shrinks compressible data" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    // Create a highly compressible payload (repeated text)
    var big_content: [4096]u8 = undefined;
    const pattern = "ABCDEFGHIJ";
    for (&big_content, 0..) |*byte, i| {
        byte.* = pattern[i % pattern.len];
    }

    const inner = try leaf.serializeData(allocator, &big_content);
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    // Compressed should be smaller than original
    try testing.expect(compressed.len < inner.len);

    // Round-trip
    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 empty container round-trip" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 rejects non-compressed container (no COMP attribute)" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const raw = try leaf.serializeData(allocator, "not compressed");
    defer allocator.free(raw);

    try testing.expectError(ContainerError.InvalidContainerType, decompressContainer(allocator, raw));
}

test "isCompressed returns true for LZMA2 container" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "test");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    try testing.expect(isCompressed(compressed));
}

test "isCompressed returns false for plain container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const plain = try leaf.serializeData(allocator, "test");
    defer allocator.free(plain);

    try testing.expect(!isCompressed(plain));
}

test "Verify LP attributes are correct (TYPE=data, COMP=lzma2, DECOMP_LEN present, CSUM=blake3_128)" {
    if (comptime !build_options.enable_compression) return;
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "attribute check");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const view = try container.parseLPHeader(compressed);
    try testing.expectEqual(ct.ContainerTypeId.data, view.type_id);
    try testing.expectEqual(@as(?ct.CompressionId, .lzma2), view.comp_id);
    try testing.expect(view.decomp_len != null);
    try testing.expectEqual(@as(u64, inner.len), view.decomp_len.?);
    try testing.expectEqual(@as(?ct.ChecksumId, .blake3_128), view.csum_id);
}
