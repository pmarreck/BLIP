/// Compression stub — provides the same public API as compression.zig but
/// returns `error.UnsupportedCompression` for all operations. Used when
/// the `enable_compression` build option is false, allowing downstream
/// consumers to use BLIP's container format without pulling in z7z, bzip2z,
/// lz4, or zstd dependencies.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ct = @import("container_types.zig");
const container = @import("container.zig");

const ContainerError = container.ContainerError;

pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    UnsupportedCompression,
};

/// Progress callback for compression: (bytes_done, bytes_total, user_ctx).
pub const CompressProgressFn = ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void;

/// Phase callback: (label_ptr, label_len, user_ctx).
pub const PhaseFn = ?*const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;

pub fn compress(
    _: Allocator,
    _: ct.CompressionId,
    _: []const u8,
    _: CompressProgressFn,
    _: ?*anyopaque,
    _: u8,
) (Allocator.Error || CompressionError)![]u8 {
    return error.UnsupportedCompression;
}

pub fn decompress(_: Allocator, _: ct.CompressionId, _: []const u8, _: u64) (Allocator.Error || CompressionError)![]u8 {
    return error.UnsupportedCompression;
}

pub fn compressContainer(
    _: Allocator,
    _: ct.CompressionId,
    _: []const u8,
    _: CompressProgressFn,
    _: PhaseFn,
    _: ?*anyopaque,
    _: u8,
) (Allocator.Error || ContainerError || CompressionError)![]u8 {
    return error.UnsupportedCompression;
}

pub fn decompressContainer(_: Allocator, _: []const u8) (Allocator.Error || ContainerError || CompressionError)![]u8 {
    return error.UnsupportedCompression;
}

/// Quick check if buffer starts with a compressed LP container.
/// This works without compression libraries — it only parses the LP header.
pub fn isCompressed(buf: []const u8) bool {
    const view = container.parseLPHeader(buf) catch return false;
    return view.comp_id != null;
}

// =============================================================================
// Tests — verify stub returns UnsupportedCompression for all operations
// =============================================================================

const testing = std.testing;

test "compression stub: compress returns UnsupportedCompression" {
    try testing.expectError(error.UnsupportedCompression, compress(testing.allocator, .lzma2, "test data", null, null, 0));
}

test "compression stub: decompress returns UnsupportedCompression" {
    try testing.expectError(error.UnsupportedCompression, decompress(testing.allocator, .lzma2, "test data", 9));
}

test "compression stub: compressContainer returns UnsupportedCompression" {
    try testing.expectError(error.UnsupportedCompression, compressContainer(testing.allocator, .lzma2, "test data", null, null, null, 0));
}

test "compression stub: decompressContainer returns UnsupportedCompression" {
    try testing.expectError(error.UnsupportedCompression, decompressContainer(testing.allocator, "test data"));
}

test "compression stub: isCompressed returns false for plain data" {
    const leaf = @import("leaf.zig");
    const plain = try leaf.serializeData(testing.allocator, "hello");
    defer testing.allocator.free(plain);
    try testing.expect(!isCompressed(plain));
}
