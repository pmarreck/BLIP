const std = @import("std");
const Allocator = std.mem.Allocator;
const ct = @import("container_types.zig");
const container = @import("container.zig");
const csum_mod = @import("checksum.zig");
const z7z = @import("z7z");
const testing = std.testing;

const ContainerError = container.ContainerError;

pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    UnsupportedCompression,
};

/// Compress data using the specified algorithm.
/// Returns compressed bytes. Caller owns returned memory.
pub fn compress(allocator: Allocator, algo: ct.CompressionId, data: []const u8) (Allocator.Error || CompressionError)![]u8 {
    switch (algo) {
        .lzma2 => {
            return z7z.lzma2_encoder.compress(data, .{}, allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CompressionFailed,
            };
        },
        .bzip2 => return error.UnsupportedCompression,
        .lz4 => return error.UnsupportedCompression,
        .zstd => return error.UnsupportedCompression,
    }
}

/// Decompress data using the specified algorithm.
/// decomp_len is the expected decompressed size.
/// Returns decompressed bytes. Caller owns returned memory.
pub fn decompress(allocator: Allocator, algo: ct.CompressionId, data: []const u8, decomp_len: u64) (Allocator.Error || CompressionError)![]u8 {
    switch (algo) {
        .lzma2 => {
            const out_buf = try allocator.alloc(u8, @intCast(decomp_len));
            errdefer allocator.free(out_buf);
            var input_stream = std.io.fixedBufferStream(data);
            var output_stream = std.io.fixedBufferStream(out_buf);
            std.compress.lzma2.decompress(allocator, input_stream.reader(), output_stream.writer()) catch {
                allocator.free(out_buf);
                return error.DecompressionFailed;
            };
            if (output_stream.pos != @as(usize, @intCast(decomp_len))) {
                allocator.free(out_buf);
                return error.DecompressionFailed;
            }
            return out_buf;
        },
        .bzip2 => return error.UnsupportedCompression,
        .lz4 => return error.UnsupportedCompression,
        .zstd => return error.UnsupportedCompression,
    }
}

/// Wrap any serialized bytes in a compressed LP DATA container.
/// Produces: [BLIP(total)] [TYPE=data] [COMP=algo] [DECOMP_LEN=N] [CSUM=blake3_128] [VAL] [compressed] [BLAKE3-128]
/// Caller owns returned memory.
pub fn compressContainer(allocator: Allocator, algo: ct.CompressionId, container_bytes: []const u8) (Allocator.Error || ContainerError || CompressionError)![]u8 {
    const compressed = try compress(allocator, algo, container_bytes);
    defer allocator.free(compressed);

    const options: container.LPOptions = .{
        .comp_id = algo,
        .decomp_len = container_bytes.len,
        .csum_id = .blake3_128,
    };

    const total = container.computeLPLength(.data, compressed.len, options);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    const header_len = try container.writeLPHeader(buf, .data, total, options);
    @memcpy(buf[header_len..][0..compressed.len], compressed);

    const csum_len = ct.checksumLength(.blake3_128);
    const csum_result = csum_mod.compute(.blake3_128, buf[0..@as(usize, @intCast(total)) - csum_len]);
    @memcpy(buf[@as(usize, @intCast(total)) - csum_len..@as(usize, @intCast(total))], csum_result[0..csum_len]);

    return buf;
}

/// Decompress an LP container with COMP attribute.
/// Verifies checksum, then decompresses.
/// Returns the decompressed inner bytes. Caller owns returned memory.
pub fn decompressContainer(allocator: Allocator, buf: []const u8) (Allocator.Error || ContainerError || CompressionError)![]u8 {
    const view = try container.parseLPHeader(buf);

    const comp_id = view.comp_id orelse return error.InvalidContainerType;

    // Verify checksum if present
    if (view.csum_id) |csum_id| {
        const csum_bytes = view.checksumSlice();
        const csum_len = ct.checksumLength(csum_id);
        const data_to_check = buf[0..@as(usize, @intCast(view.total_length)) - csum_len];
        if (!csum_mod.verify(csum_id, data_to_check, csum_bytes)) {
            return error.HashMismatch;
        }
    }

    const decomp_len = view.decomp_len orelse return error.InvalidLength;
    const payload = view.payloadSlice();

    return decompress(allocator, comp_id, payload, decomp_len);
}

/// Quick check if buffer starts with a compressed LP container.
pub fn isCompressed(buf: []const u8) bool {
    const view = container.parseLPHeader(buf) catch return false;
    return view.comp_id != null;
}

// =============================================================================
// Tests
// =============================================================================

test "LZMA2 compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, compression module! This is a test of the unified interface.";

    const compressed = try compress(allocator, .lzma2, original);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .lzma2, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "bzip2 compress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, compress(allocator, .bzip2, "test"));
}

test "LZ4 compress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, compress(allocator, .lz4, "test"));
}

test "zstd compress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, compress(allocator, .zstd, "test"));
}

test "bzip2 decompress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, decompress(allocator, .bzip2, "test", 4));
}

test "LZ4 decompress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, decompress(allocator, .lz4, "test", 4));
}

test "zstd decompress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, decompress(allocator, .zstd, "test", 4));
}

test "compressContainer/decompressContainer round-trip with LZMA2" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, unified compression!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lzma2, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "isCompressed returns true for compressed container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "test");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lzma2, inner);
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

test "decompressContainer verifies checksum and rejects corruption" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "integrity check");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lzma2, inner);
    defer allocator.free(compressed);

    // Corrupt a byte in the middle (not in checksum area)
    compressed[compressed.len / 2] ^= 0xFF;

    try testing.expectError(error.HashMismatch, decompressContainer(allocator, compressed));
}

test "decompressContainer rejects non-compressed container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const plain = try leaf.serializeData(allocator, "not compressed");
    defer allocator.free(plain);

    try testing.expectError(error.InvalidContainerType, decompressContainer(allocator, plain));
}

test "compressContainer LP attributes are correct" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "attribute verification");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lzma2, inner);
    defer allocator.free(compressed);

    const view = try container.parseLPHeader(compressed);
    try testing.expectEqual(ct.ContainerTypeId.data, view.type_id);
    try testing.expectEqual(@as(?ct.CompressionId, .lzma2), view.comp_id);
    try testing.expect(view.decomp_len != null);
    try testing.expectEqual(@as(u64, inner.len), view.decomp_len.?);
    try testing.expectEqual(@as(?ct.ChecksumId, .blake3_128), view.csum_id);
}
