const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const z7z = @import("z7z");
const testing = std.testing;

const ContainerError = container.ContainerError;
const XxHash64 = std.hash.XxHash64;

pub const Lzma2Error = error{
    CompressionFailed,
    DecompressionFailed,
};

/// Serialize an LZMA2 container (0x81 0x09): compressed wrapper for any container.
/// Layout: [0x81 0x09][BLIP(total)][BLIP(uncompressed_size)][lzma2_data][xxHash64 8B LE]
/// Hash covers everything from container start to total - 8 (i.e. the compressed data).
/// Caller owns returned memory.
pub fn compressContainer(allocator: Allocator, container_bytes: []const u8) (Allocator.Error || ContainerError || Lzma2Error)![]u8 {
    // Compress with LZMA2
    const compressed = z7z.lzma2_encoder.compress(container_bytes, .{}, allocator) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Lzma2Error.CompressionFailed,
    };
    defer allocator.free(compressed);

    const uncompressed_size: u64 = container_bytes.len;
    const uncomp_encoded_size = blip.encodedSize(uncompressed_size);

    // value = BLIP(uncompressed_size) + compressed_data + 8 (hash)
    const value_len: u64 = uncomp_encoded_size + compressed.len + 8;
    const total = container.computeTotalLength(value_len);

    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    var pos: usize = 0;

    // Write type sentinel (LZMA2 = 0x81 0x09)
    const sentinel = ct.typeSentinel(.lzma2);
    buf[pos] = sentinel[0];
    buf[pos + 1] = sentinel[1];
    pos += 2;

    // Write BLIP(total)
    const total_written = blip.encode(total, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += total_written;

    // Write BLIP(uncompressed_size)
    const uncomp_written = blip.encode(uncompressed_size, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += uncomp_written;

    // Write compressed data
    @memcpy(buf[pos..][0..compressed.len], compressed);
    pos += compressed.len;

    // Write xxHash64 over everything except the hash itself
    const hash_value = XxHash64.hash(0, buf[0 .. @as(usize, @intCast(total)) - 8]);
    std.mem.writeInt(u64, buf[pos..][0..8], hash_value, .little);
    pos += 8;

    std.debug.assert(pos == total);
    return buf;
}

/// Decompress an LZMA2 container, returning the inner container bytes.
/// Verifies xxHash64 before decompressing.
/// Caller owns returned memory.
pub fn decompressContainer(allocator: Allocator, buf: []const u8) (Allocator.Error || ContainerError || Lzma2Error)![]u8 {
    const view = try container.parseHeader(buf);
    if (view.container_type != .lzma2) return ContainerError.InvalidContainerType;

    const total: usize = @intCast(view.total_length);

    // Verify hash first
    if (total < 8) return ContainerError.InvalidLength;
    const hash_computed = XxHash64.hash(0, buf[0 .. total - 8]);
    const hash_stored = std.mem.readInt(u64, buf[total - 8 ..][0..8], .little);
    if (hash_computed != hash_stored) return ContainerError.HashMismatch;

    // Parse uncompressed size
    const value = view.valueSlice();
    if (value.len < 9) return ContainerError.InvalidLength; // at minimum: 1 byte uncomp_size + 0 bytes data + 8 bytes hash
    const uncomp_result = blip.decode(value) catch return ContainerError.InvalidLength;
    const uncompressed_size: usize = @intCast(uncomp_result.value);

    // Extract compressed data (between uncompressed_size field and hash)
    const compressed_start = uncomp_result.bytes_read;
    if (value.len < compressed_start + 8) return ContainerError.InvalidLength;
    const compressed_data = value[compressed_start .. value.len - 8];

    // Decompress using Zig stdlib LZMA2 decoder
    const out_buf = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(out_buf);

    var input_stream = std.io.fixedBufferStream(compressed_data);
    var output_stream = std.io.fixedBufferStream(out_buf);

    std.compress.lzma2.decompress(allocator, input_stream.reader(), output_stream.writer()) catch {
        allocator.free(out_buf);
        return Lzma2Error.DecompressionFailed;
    };

    if (output_stream.pos != uncompressed_size) {
        allocator.free(out_buf);
        return Lzma2Error.DecompressionFailed;
    }

    return out_buf;
}

/// Reader for zero-copy header inspection without decompressing.
pub const Lzma2Reader = struct {
    buf: []const u8,
    total: usize,
    uncompressed_size: u64,
    compressed_data_offset: usize,
    compressed_data_len: usize,

    pub fn init(buf: []const u8) (ContainerError || Lzma2Error)!Lzma2Reader {
        const view = try container.parseHeader(buf);
        if (view.container_type != .lzma2) return ContainerError.InvalidContainerType;

        const total: usize = @intCast(view.total_length);
        const value = view.valueSlice();
        if (value.len < 9) return ContainerError.InvalidLength;

        const uncomp_result = blip.decode(value) catch return ContainerError.InvalidLength;
        const compressed_start = view.value_offset + uncomp_result.bytes_read;
        const compressed_len = total - 8 - compressed_start;

        return .{
            .buf = buf,
            .total = total,
            .uncompressed_size = uncomp_result.value,
            .compressed_data_offset = compressed_start,
            .compressed_data_len = compressed_len,
        };
    }

    pub fn verifyHash(self: Lzma2Reader) bool {
        const hash_computed = XxHash64.hash(0, self.buf[0 .. self.total - 8]);
        const hash_stored = std.mem.readInt(u64, self.buf[self.total - 8 ..][0..8], .little);
        return hash_computed == hash_stored;
    }

    pub fn compressedSize(self: Lzma2Reader) usize {
        return self.compressed_data_len;
    }
};

/// Verify the embedded xxHash64 of an LZMA2 container.
pub fn verifyHash(buf: []const u8) (ContainerError || Lzma2Error)!bool {
    const reader = try Lzma2Reader.init(buf);
    return reader.verifyHash();
}

// =============================================================================
// Tests
// =============================================================================

test "LZMA2 round-trip: compress and decompress a RAW container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeRaw(allocator, "Hello, LZMA2!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    // Verify sentinel
    try testing.expectEqual(@as(u8, 0x81), compressed[0]);
    try testing.expectEqual(@as(u8, 0x09), compressed[1]);

    // Decompress and compare
    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 hash verification" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeRaw(allocator, "integrity test");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    try testing.expect(try verifyHash(compressed));
}

test "LZMA2 hash detects corruption" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeRaw(allocator, "corrupt me");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    // Corrupt a byte in the compressed data
    compressed[compressed.len / 2] ^= 0xFF;

    try testing.expect(!(try verifyHash(compressed)));
}

test "LZMA2 wraps an ARRAY container" {
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
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const content = "Hello, world! This is some compressible text content.";
    const inner = try leaf.serializeRaw(allocator, content);
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const reader = try Lzma2Reader.init(compressed);
    try testing.expectEqual(@as(u64, inner.len), reader.uncompressed_size);
    try testing.expect(reader.verifyHash());
    try testing.expect(reader.compressedSize() > 0);
}

test "LZMA2 compression actually shrinks compressible data" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    // Create a highly compressible payload (repeated text)
    var big_content: [4096]u8 = undefined;
    const pattern = "ABCDEFGHIJ";
    for (&big_content, 0..) |*byte, i| {
        byte.* = pattern[i % pattern.len];
    }

    const inner = try leaf.serializeRaw(allocator, &big_content);
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
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeRaw(allocator, "");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, inner);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);
    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "LZMA2 rejects non-LZMA2 container" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const raw = try leaf.serializeRaw(allocator, "not lzma2");
    defer allocator.free(raw);

    try testing.expectError(ContainerError.InvalidContainerType, decompressContainer(allocator, raw));
}
