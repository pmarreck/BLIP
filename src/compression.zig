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
const zstd = @cImport({
    @cInclude("zstd.h");
});
const testing = std.testing;

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

/// Compress data using the specified algorithm.
/// progress_fn/progress_ctx: optional callback reporting (bytes_done, bytes_total).
/// num_threads: 0=auto (detect CPU count), 1=single-threaded, N=use N threads.
/// Returns compressed bytes. Caller owns returned memory.
pub fn compress(
    allocator: Allocator,
    algo: ct.CompressionId,
    data: []const u8,
    progress_fn: CompressProgressFn,
    progress_ctx: ?*anyopaque,
    num_threads: u8,
) (Allocator.Error || CompressionError)![]u8 {
    switch (algo) {
        .lzma2 => {
            const params = z7z.lzma2_encoder.LevelParams.fromLevel(z7z.lzma2_encoder.LevelParams.DEFAULT_LEVEL);
            return z7z.lzma2_encoder.compress(data, params.dict_size, params.nice_len, .{
                .callback = progress_fn,
                .user_data = progress_ctx,
            }, allocator) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CompressionFailed,
            };
        },
        .bzip2 => {
            const result = bzip2z.bzip2.compressWithOptions(allocator, data, .{
                .threads = num_threads,
            }) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CompressionFailed,
            };
            if (progress_fn) |cb| cb(data.len, data.len, progress_ctx);
            return result;
        },
        .lz4 => {
            // Use LZ4 frame streaming API — compress in chunks for progress reporting.
            const chunk_size: usize = 4 * 1024 * 1024; // 4 MB chunks

            var prefs: lz4.LZ4F_preferences_t = std.mem.zeroes(lz4.LZ4F_preferences_t);
            prefs.frameInfo.contentSize = data.len;

            const bound = lz4.LZ4F_compressFrameBound(data.len, &prefs);
            if (lz4.LZ4F_isError(bound) != 0) return error.CompressionFailed;

            const dest_buf = try allocator.alloc(u8, bound);
            errdefer allocator.free(dest_buf);

            // Create streaming compression context
            var cctx: ?*lz4.LZ4F_cctx = null;
            if (lz4.LZ4F_isError(lz4.LZ4F_createCompressionContext(&cctx, lz4.LZ4F_VERSION)) != 0 or cctx == null) {
                allocator.free(dest_buf);
                return error.CompressionFailed;
            }
            defer _ = lz4.LZ4F_freeCompressionContext(cctx);

            // Write frame header
            var offset: usize = 0;
            const header_size = lz4.LZ4F_compressBegin(cctx, dest_buf.ptr, dest_buf.len, &prefs);
            if (lz4.LZ4F_isError(header_size) != 0) {
                allocator.free(dest_buf);
                return error.CompressionFailed;
            }
            offset += header_size;

            // Compress in chunks with progress
            var src_offset: usize = 0;
            while (src_offset < data.len) {
                const remaining = data.len - src_offset;
                const this_chunk = @min(remaining, chunk_size);

                const compressed = lz4.LZ4F_compressUpdate(
                    cctx,
                    dest_buf.ptr + offset,
                    dest_buf.len - offset,
                    data.ptr + src_offset,
                    this_chunk,
                    null,
                );
                if (lz4.LZ4F_isError(compressed) != 0) {
                    allocator.free(dest_buf);
                    return error.CompressionFailed;
                }

                offset += compressed;
                src_offset += this_chunk;

                if (progress_fn) |cb| cb(src_offset, data.len, progress_ctx);
            }

            // Finalize frame (end mark + checksum)
            const end_size = lz4.LZ4F_compressEnd(cctx, dest_buf.ptr + offset, dest_buf.len - offset, null);
            if (lz4.LZ4F_isError(end_size) != 0) {
                allocator.free(dest_buf);
                return error.CompressionFailed;
            }
            offset += end_size;

            // Shrink to actual compressed size
            const result = allocator.realloc(dest_buf, offset) catch {
                return dest_buf[0..offset];
            };
            return result;
        },
        .zstd => {
            // Use zstd CCtx API with chunked progress reporting and threading.
            const chunk_size: usize = 4 * 1024 * 1024; // 4 MB chunks
            const bound = zstd.ZSTD_compressBound(data.len);
            if (zstd.ZSTD_isError(bound) != 0) return error.CompressionFailed;

            const dest_buf = try allocator.alloc(u8, bound);
            errdefer allocator.free(dest_buf);

            // Always use CCtx so we can set nbWorkers for threading
            const cctx = zstd.ZSTD_createCCtx() orelse {
                allocator.free(dest_buf);
                return error.CompressionFailed;
            };
            defer _ = zstd.ZSTD_freeCCtx(cctx);

            _ = zstd.ZSTD_CCtx_setParameter(cctx, zstd.ZSTD_c_compressionLevel, 3);
            if (num_threads != 1) {
                const resolved: c_int = if (num_threads == 0)
                    @intCast(std.Thread.getCpuCount() catch 1)
                else
                    @intCast(num_threads);
                _ = zstd.ZSTD_CCtx_setParameter(cctx, zstd.ZSTD_c_nbWorkers, resolved);
            }

            if (data.len <= chunk_size) {
                // Small data: single-shot via CCtx
                const csize = zstd.ZSTD_compress2(cctx, dest_buf.ptr, bound, data.ptr, data.len);
                if (zstd.ZSTD_isError(csize) != 0) {
                    allocator.free(dest_buf);
                    return error.CompressionFailed;
                }
                if (progress_fn) |cb| cb(data.len, data.len, progress_ctx);
                const result = allocator.realloc(dest_buf, csize) catch {
                    return dest_buf[0..csize];
                };
                return result;
            }

            var out_buf = zstd.ZSTD_outBuffer{ .dst = dest_buf.ptr, .size = dest_buf.len, .pos = 0 };
            var src_offset: usize = 0;

            while (src_offset < data.len) {
                const remaining = data.len - src_offset;
                const this_chunk = @min(remaining, chunk_size);
                const is_last = (src_offset + this_chunk >= data.len);

                var in_buf = zstd.ZSTD_inBuffer{ .src = data.ptr + src_offset, .size = this_chunk, .pos = 0 };
                const directive: c_uint = if (is_last) zstd.ZSTD_e_end else zstd.ZSTD_e_continue;

                while (true) {
                    const ret = zstd.ZSTD_compressStream2(cctx, &out_buf, &in_buf, directive);
                    if (zstd.ZSTD_isError(ret) != 0) {
                        allocator.free(dest_buf);
                        return error.CompressionFailed;
                    }
                    if (is_last) {
                        if (ret == 0) break; // fully flushed
                    } else {
                        if (in_buf.pos >= in_buf.size) break;
                    }
                }

                src_offset += this_chunk;
                if (progress_fn) |cb| cb(src_offset, data.len, progress_ctx);
            }

            const result = allocator.realloc(dest_buf, out_buf.pos) catch {
                return dest_buf[0..out_buf.pos];
            };
            return result;
        },
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
            std.compress.lzma2.decompress(allocator, input_stream.reader(), output_stream.writer()) catch |e| {
                allocator.free(out_buf);
                return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.DecompressionFailed,
                };
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
        .zstd => {
            const out_buf = try allocator.alloc(u8, @intCast(decomp_len));
            errdefer allocator.free(out_buf);

            const dsize = zstd.ZSTD_decompress(out_buf.ptr, out_buf.len, data.ptr, data.len);
            if (zstd.ZSTD_isError(dsize) != 0 or dsize != @as(usize, @intCast(decomp_len))) {
                allocator.free(out_buf);
                return error.DecompressionFailed;
            }
            return out_buf;
        },
    }
}

/// Wrap any serialized bytes in a compressed LP DATA container.
/// Produces: [BLIP(total)] [TYPE=data] [COMP=algo] [DECOMP_LEN=N] [CSUM=blake3_128] [VAL] [compressed] [BLAKE3-128]
/// progress_fn/progress_ctx: optional callback for compression progress (bytes_done, bytes_total).
/// phase_fn: optional callback for phase transitions (e.g., "Finalizing").
/// Caller owns returned memory.
pub fn compressContainer(
    allocator: Allocator,
    algo: ct.CompressionId,
    container_bytes: []const u8,
    progress_fn: CompressProgressFn,
    phase_fn: PhaseFn,
    progress_ctx: ?*anyopaque,
    num_threads: u8,
) (Allocator.Error || ContainerError || CompressionError)![]u8 {
    const compressed = try compress(allocator, algo, container_bytes, progress_fn, progress_ctx, num_threads);
    defer allocator.free(compressed);

    // Signal phase change: wrapping compressed data in LP container + checksumming
    if (phase_fn) |cb| {
        const label = "Finalizing";
        cb(label.ptr, label.len, progress_ctx);
    }

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

    const compressed = try compress(allocator, .lzma2, original, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .lzma2, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "LZMA2 compress/decompress round-trip (large data, parallel path)" {
    const allocator = std.heap.page_allocator;

    // 2GB with mostly high-entropy data (like book archives with compressed content)
    const data_size: usize = 2 * 1024 * 1024 * 1024;
    const data = try allocator.alloc(u8, data_size);
    defer allocator.free(data);

    // Mostly random (high-entropy) with occasional compressible runs
    // This mimics book archives where most data is JPEG/compressed PDF streams
    var rng = std.Random.DefaultPrng.init(42);
    const random = rng.random();
    for (0..data_size) |i| {
        if (i % (512 * 1024) < 4096) {
            // 4KB compressible every 512KB (like metadata between compressed images)
            data[i] = @intCast(i % 256);
        } else {
            data[i] = random.int(u8);
        }
    }

    const compressed = try compress(allocator, .lzma2, data, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .lzma2, compressed, data_size);
    defer allocator.free(decompressed);

    try testing.expectEqual(data_size, decompressed.len);
    try testing.expectEqualSlices(u8, data, decompressed);
}

test "bzip2 compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, bzip2 compression! This is a test of the unified interface.";

    const compressed = try compress(allocator, .bzip2, original, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .bzip2, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "LZ4 compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, LZ4 compression! This is a test of the unified interface.";

    const compressed = try compress(allocator, .lz4, original, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .lz4, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "zstd compress/decompress round-trip (raw bytes)" {
    const allocator = testing.allocator;
    const original = "Hello, zstd compression! This is a test of the unified interface.";

    const compressed = try compress(allocator, .zstd, original, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, .zstd, compressed, original.len);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "bzip2 compressContainer/decompressContainer round-trip" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, bzip2 container!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .bzip2, inner, null, null, null, 0);
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

    const compressed = try compressContainer(allocator, .lz4, inner, null, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "zstd compressContainer/decompressContainer round-trip" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, zstd container!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .zstd, inner, null, null, null, 0);
    defer allocator.free(compressed);

    const decompressed = try decompressContainer(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, inner, decompressed);
}

test "compressContainer/decompressContainer round-trip with LZMA2" {
    const allocator = testing.allocator;
    const leaf = @import("leaf.zig");

    const inner = try leaf.serializeData(allocator, "Hello, unified compression!");
    defer allocator.free(inner);

    const compressed = try compressContainer(allocator, .lzma2, inner, null, null, null, 0);
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

    const compressed = try compressContainer(allocator, .lzma2, inner, null, null, null, 0);
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

    const compressed = try compressContainer(allocator, .lzma2, inner, null, null, null, 0);
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

    const compressed = try compressContainer(allocator, .lzma2, inner, null, null, null, 0);
    defer allocator.free(compressed);

    const view = try container.parseLPHeader(compressed);
    try testing.expectEqual(ct.ContainerTypeId.data, view.type_id);
    try testing.expectEqual(@as(?ct.CompressionId, .lzma2), view.comp_id);
    try testing.expect(view.decomp_len != null);
    try testing.expectEqual(@as(u64, inner.len), view.decomp_len.?);
    try testing.expectEqual(@as(?ct.ChecksumId, .blake3_128), view.csum_id);
}
