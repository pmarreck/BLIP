const std = @import("std");
const Allocator = std.mem.Allocator;
const ct = @import("container_types.zig");
const container = @import("container.zig");
const csum_mod = @import("checksum.zig");
const z7z = @import("z7z");
const bzip2z = @import("bzip2z");
const lz4 = @cImport({
    @cInclude("lz4.h");
    @cInclude("lz4frame.h");
});
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
        .bzip2 => {
            return bzip2z.bzip2.compress(allocator, data) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CompressionFailed,
            };
        },
        .lz4 => {
            // Use LZ4 frame API — handles arbitrary sizes (no 2 GB block limit)
            // and is self-describing (frame header stores content size).
            var prefs: lz4.LZ4F_preferences_t = std.mem.zeroes(lz4.LZ4F_preferences_t);
            prefs.frameInfo.contentSize = data.len;
            const bound = lz4.LZ4F_compressFrameBound(data.len, &prefs);
            if (lz4.LZ4F_isError(bound) != 0) return error.CompressionFailed;
            const dest_buf = try allocator.alloc(u8, bound);
            errdefer allocator.free(dest_buf);
            const compressed_size = lz4.LZ4F_compressFrame(
                dest_buf.ptr,
                dest_buf.len,
                data.ptr,
                data.len,
                &prefs,
            );
            if (lz4.LZ4F_isError(compressed_size) != 0) {
                allocator.free(dest_buf);
                return error.CompressionFailed;
            }
            const result = allocator.realloc(dest_buf, compressed_size) catch {
                return dest_buf[0..compressed_size];
            };
            return result;
        },
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
        .bzip2 => {
            // bzip2 is self-describing (stream contains its own length), decomp_len not needed
            return bzip2z.bzip2.decompress(allocator, data) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.DecompressionFailed,
            };
        },
        .lz4 => {
            // Use LZ4 frame API for decompression — self-describing, no size limit.
            // decomp_len from LP header is used as allocation hint.
            var dctx: ?*lz4.LZ4F_dctx = null;
            const create_err = lz4.LZ4F_createDecompressionContext(&dctx, lz4.LZ4F_VERSION);
            if (lz4.LZ4F_isError(create_err) != 0 or dctx == null) return error.DecompressionFailed;
            defer _ = lz4.LZ4F_freeDecompressionContext(dctx);

            const out_buf = try allocator.alloc(u8, @intCast(decomp_len));
            errdefer allocator.free(out_buf);

            var src_size = data.len;
            var dst_size = out_buf.len;
            const ret = lz4.LZ4F_decompress(dctx, out_buf.ptr, &dst_size, data.ptr, &src_size, null);
            if (lz4.LZ4F_isError(ret) != 0 or dst_size != @as(usize, @intCast(decomp_len))) {
                allocator.free(out_buf);
                return error.DecompressionFailed;
            }
            return out_buf;
        },
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

test "bzip2 compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, bzip2 compression! This is a test of the unified interface.";

    const compressed = try compress(allocator, .bzip2, original);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .bzip2, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "LZ4 compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, LZ4 compression! This is a test of the unified interface.";

    const compressed = try compress(allocator, .lz4, original);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .lz4, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "zstd compress returns UnsupportedCompression" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnsupportedCompression, compress(allocator, .zstd, "test"));
}

test "bzip2 compressContainer/decompressContainer round-trip" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, bzip2 container!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .bzip2, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZ4 compressContainer/decompressContainer round-trip" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, LZ4 container!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lz4, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
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
