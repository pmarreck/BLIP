const std = @import("std");
const blip = @import("blip");
const encoding = blip.encoding;
const bignum = blip.bignum_mod;

// ============================================================================
// Configuration
// ============================================================================

const SEED: u64 = 0xB11B; // 0xBLIP
const THROUGHPUT_N: usize = 1_000_000;
const THROUGHPUT_RUNS: usize = 3;
const BIGNUM_ITERS: usize = 100_000;
const JUMP_COUNT: usize = 10_000;
const REGION_SIZE: usize = 16 * 1024 * 1024; // 16 MB per encoding
const MAGIC = "BLIPbm01";
const BENCH_FILENAME = "blip_bench_sparse.bin";

const doNotOptimizeAway = std.mem.doNotOptimizeAway;

// ============================================================================
// Distribution generators
// ============================================================================

const Distribution = enum {
    small,
    medium,
    bimodal,
    large,
};

fn genValue(dist: Distribution, rng: std.Random) u64 {
    return switch (dist) {
        .small => rng.intRangeAtMost(u64, 0, 127),
        .medium => rng.intRangeAtMost(u64, 0, 65535),
        .bimodal => blk: {
            const r = rng.intRangeAtMost(u64, 0, 9);
            if (r < 9) {
                break :blk rng.intRangeAtMost(u64, 0, 127);
            } else {
                break :blk rng.intRangeAtMost(u64, 16384, 0xFFFFFFFF);
            }
        },
        .large => rng.intRangeAtMost(u64, 0x100000000, 0xFFFFFFFFFFFFFFFF),
    };
}

// ============================================================================
// Helpers
// ============================================================================

const WriterType = @TypeOf(blk: {
    var buf: [1]u8 = undefined;
    break :blk std.fs.File.stderr().writer(&buf).interface;
});

/// Format a u64 with comma separators (e.g., 1,234,567).
fn fmtComma(value: u64, buf: []u8) []const u8 {
    var digits: [20]u8 = undefined;
    var dlen: usize = 0;
    var v = value;
    if (v == 0) {
        digits[0] = '0';
        dlen = 1;
    } else {
        while (v > 0) {
            digits[dlen] = @intCast((v % 10) + '0');
            dlen += 1;
            v /= 10;
        }
        // reverse
        var lo: usize = 0;
        var hi: usize = dlen - 1;
        while (lo < hi) {
            const tmp = digits[lo];
            digits[lo] = digits[hi];
            digits[hi] = tmp;
            lo += 1;
            hi -= 1;
        }
    }

    // Write with commas
    var out_i: usize = 0;
    for (0..dlen) |i| {
        if (i > 0 and (dlen - i) % 3 == 0) {
            buf[out_i] = ',';
            out_i += 1;
        }
        buf[out_i] = digits[i];
        out_i += 1;
    }
    return buf[0..out_i];
}

// ============================================================================
// Benchmark 1: Throughput
// ============================================================================

/// Print a fixed-point ns/op value: integer part and one decimal digit.
fn printNsPerOp(stderr: *WriterType, total_ns: u64, count: u64) !void {
    // Compute ns/op * 10 for one decimal place
    const tenths = (total_ns * 10) / count;
    const whole = tenths / 10;
    const frac = tenths % 10;
    try stderr.print(" | {d:>4}.{d}", .{ whole, frac });
}

fn benchThroughput(stderr: *WriterType, allocator: std.mem.Allocator) !void {
    try stderr.writeAll("\n--- Throughput (ns/op, 1M values, best of 3) ---\n");
    try stderr.writeAll("Encoding        | Sm enc | Sm dec | Md enc | Md dec | Bi enc | Bi dec | Lg enc | Lg dec\n");
    try stderr.writeAll("----------------+--------+--------+--------+--------+--------+--------+--------+--------\n");
    try stderr.flush();

    const dists = [_]Distribution{ .small, .medium, .bimodal, .large };

    // Heap-allocate the large working buffers (reused across all encodings/distributions)
    const values = try allocator.alloc(u64, THROUGHPUT_N);
    defer allocator.free(values);
    const encoded_buf = try allocator.alloc(u8, THROUGHPUT_N * 16);
    defer allocator.free(encoded_buf);
    const encoded_offsets = try allocator.alloc(u32, THROUGHPUT_N);
    defer allocator.free(encoded_offsets);

    inline for (encoding.all_encodings) |Enc| {
        try stderr.print("{s:<15}", .{Enc.name});

        for (dists) |dist| {
            // Pre-generate values with deterministic seed
            var prng = std.Random.DefaultPrng.init(SEED);
            const rng = prng.random();

            for (values) |*val| {
                val.* = genValue(dist, rng);
            }

            // --- Encode benchmark ---
            var best_enc_ns: u64 = std.math.maxInt(u64);
            for (0..THROUGHPUT_RUNS) |_| {
                var enc_pos: usize = 0;
                var timer = try std.time.Timer.start();
                for (values) |val| {
                    const n = Enc.encode(val, encoded_buf[enc_pos..]) catch unreachable;
                    enc_pos += n;
                }
                const elapsed = timer.read();
                doNotOptimizeAway(enc_pos);
                if (elapsed < best_enc_ns) best_enc_ns = elapsed;
            }

            // Final encode pass to record offsets for decode benchmark
            {
                var enc_pos: usize = 0;
                for (encoded_offsets, values) |*off, val| {
                    off.* = @intCast(enc_pos);
                    const n = Enc.encode(val, encoded_buf[enc_pos..]) catch unreachable;
                    enc_pos += n;
                }
            }

            // --- Decode benchmark ---
            var best_dec_ns: u64 = std.math.maxInt(u64);
            for (0..THROUGHPUT_RUNS) |_| {
                var checksum: u64 = 0;
                var timer = try std.time.Timer.start();
                for (encoded_offsets) |off| {
                    const result = Enc.decode(encoded_buf[off..]) catch unreachable;
                    checksum +%= result.value;
                }
                const elapsed = timer.read();
                doNotOptimizeAway(checksum);
                if (elapsed < best_dec_ns) best_dec_ns = elapsed;
            }

            try printNsPerOp(stderr, best_enc_ns, THROUGHPUT_N);
            try printNsPerOp(stderr, best_dec_ns, THROUGHPUT_N);
        }
        try stderr.writeByte('\n');
        try stderr.flush();
    }
}

// ============================================================================
// Benchmark 2: Bignum Math
// ============================================================================

/// For BLIP encoding, extract the raw LE payload bytes (after the header).
/// Returns the start index and length of the LE payload in the encoded buffer.
/// For immediate values (< 128), the payload is the single byte itself.
fn blipPayloadSlice(encoded_val: []const u8) struct { start: usize, len: usize } {
    if (encoded_val.len == 0) return .{ .start = 0, .len = 0 };

    const first = encoded_val[0];

    // Immediate mode: bit 7 = 0
    if (first & 0x80 == 0) {
        return .{ .start = 0, .len = 1 };
    }

    // Length-prefixed: determine header length
    // Bit 6: E (endianness), Bit 5: C (continuation), Bits 4-0: L
    var header_bytes: usize = 1;
    var L: usize = first & 0x1F;

    // Check continuation flag (bit 5)
    if (first & 0x20 != 0) {
        // C = 1: more L bytes follow
        var pos: usize = 1;
        while (pos < encoded_val.len) {
            const next = encoded_val[pos];
            pos += 1;
            if (next & 0x80 == 0) break;
        }
        header_bytes = pos;

        // Recompute full L
        L = first & 0x1F;
        var shift: u6 = 5;
        for (1..header_bytes) |i| {
            L |= @as(usize, encoded_val[i] & 0x7F) << shift;
            shift +|= 7;
        }
    }

    return .{ .start = header_bytes, .len = L };
}

/// Re-encode a BLIP value from raw LE payload bytes.
fn blipReencode(payload: []const u8, buf: []u8) !usize {
    // Trim trailing zeros to find effective length
    var eff_len = payload.len;
    while (eff_len > 1 and payload[eff_len - 1] == 0) {
        eff_len -= 1;
    }

    // Check if this could be an immediate value (single byte < 128)
    if (eff_len == 1 and payload[0] < 128) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = payload[0];
        return 1;
    }

    // Length-prefixed mode: header byte + L payload bytes
    const L = eff_len;
    if (L < 32) {
        if (buf.len < 1 + L) return error.BufferTooSmall;
        buf[0] = @as(u8, 0x80) | @as(u8, @intCast(L)); // E=0 (LE), C=0
        @memcpy(buf[1..][0..L], payload[0..L]);
        return 1 + L;
    }

    return error.BufferTooSmall;
}

fn benchBignum(stderr: *WriterType) !void {
    try stderr.writeAll("\n--- Bignum Add (ns/op, 100K iterations) ---\n");
    try stderr.print("{s:<15} | {s:>10} | {s:>10}\n", .{ "Encoding", "Roundtrip", "Direct LE" });
    try stderr.writeAll("----------------+------------+------------\n");
    try stderr.flush();

    const A: u64 = 0xDEADBEEFCAFEBABE;
    const B: u64 = 0x1234567890ABCDEF;

    inline for (encoding.all_encodings) |Enc| {
        try stderr.print("{s:<15}", .{Enc.name});

        // --- Roundtrip approach ---
        // Each iteration: decode A and B from their encoded forms, convert to LE,
        // add with bignum, re-encode. Feed output back as next A to create data dependency.
        var best_rt_ns: u64 = std.math.maxInt(u64);
        for (0..THROUGHPUT_RUNS) |_| {
            // Fresh encode of A for each run
            var cur_buf: [16]u8 = undefined;
            var cur_n = Enc.encode(A, &cur_buf) catch unreachable;
            var b_buf: [16]u8 = undefined;
            const b_n = Enc.encode(B, &b_buf) catch unreachable;

            var timer = try std.time.Timer.start();
            for (0..BIGNUM_ITERS) |_| {
                // Decode current A and constant B
                const da = Enc.decode(cur_buf[0..cur_n]) catch unreachable;
                const db = Enc.decode(b_buf[0..b_n]) catch unreachable;

                // Convert to LE bytes
                var le_a: [8]u8 = undefined;
                var le_b: [8]u8 = undefined;
                std.mem.writeInt(u64, &le_a, da.value, .little);
                std.mem.writeInt(u64, &le_b, db.value, .little);

                // Add
                var out: [16]u8 = undefined;
                const result_len = bignum.addLE(&le_a, &le_b, &out) catch unreachable;

                // Convert back to u64 (truncate to keep in u64 range)
                var sum: u64 = 0;
                const read_len = @min(result_len, 8);
                for (0..read_len) |i| {
                    sum |= @as(u64, out[i]) << @as(u6, @intCast(i * 8));
                }

                // Re-encode as the next iteration's A
                cur_n = Enc.encode(sum, &cur_buf) catch unreachable;
            }
            const elapsed = timer.read();
            doNotOptimizeAway(cur_buf);
            if (elapsed < best_rt_ns) best_rt_ns = elapsed;
        }

        // Print ns/op with one decimal place
        {
            const tenths = (best_rt_ns * 10) / BIGNUM_ITERS;
            const whole = tenths / 10;
            const frac = tenths % 10;
            try stderr.print(" | {d:>8}.{d}", .{ whole, frac });
        }

        // --- Direct LE (BLIP only) ---
        const is_blip = comptime std.mem.eql(u8, Enc.name, "BLIP");
        if (is_blip) {
            var best_direct_ns: u64 = std.math.maxInt(u64);
            for (0..THROUGHPUT_RUNS) |_| {
                // Fresh encode for each run
                var cur_buf: [16]u8 = undefined;
                var cur_n = Enc.encode(A, &cur_buf) catch unreachable;
                var b_buf: [16]u8 = undefined;
                const b_n = Enc.encode(B, &b_buf) catch unreachable;

                var timer = try std.time.Timer.start();
                for (0..BIGNUM_ITERS) |_| {
                    // Extract payload directly
                    const pa = blipPayloadSlice(cur_buf[0..cur_n]);
                    const pb = blipPayloadSlice(b_buf[0..b_n]);

                    // Add directly on payload bytes
                    var out: [16]u8 = undefined;
                    const result_len = bignum.addLE(
                        cur_buf[pa.start..][0..pa.len],
                        b_buf[pb.start..][0..pb.len],
                        &out,
                    ) catch unreachable;

                    // Re-encode BLIP from raw LE (feeds back as next A)
                    // Trim to 8 bytes max to stay in u64 range
                    const trim_len = @min(result_len, 8);
                    cur_n = blipReencode(out[0..trim_len], &cur_buf) catch unreachable;
                }
                const elapsed = timer.read();
                doNotOptimizeAway(cur_buf);
                if (elapsed < best_direct_ns) best_direct_ns = elapsed;
            }
            {
                const tenths = (best_direct_ns * 10) / BIGNUM_ITERS;
                const whole = tenths / 10;
                const frac = tenths % 10;
                try stderr.print(" | {d:>8}.{d}", .{ whole, frac });
            }
        } else {
            try stderr.writeAll(" |        N/A");
        }

        try stderr.writeByte('\n');
        try stderr.flush();
    }
}

// ============================================================================
// Benchmark 3: Random-Access Jumping
// ============================================================================

fn getSparsePath() []const u8 {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const S = struct {
        var path_buf: [4096]u8 = undefined;
    };
    var pos: usize = 0;
    @memcpy(S.path_buf[pos..][0..tmpdir.len], tmpdir);
    pos += tmpdir.len;
    if (pos > 0 and S.path_buf[pos - 1] != '/') {
        S.path_buf[pos] = '/';
        pos += 1;
    }
    @memcpy(S.path_buf[pos..][0..BENCH_FILENAME.len], BENCH_FILENAME);
    pos += BENCH_FILENAME.len;
    return S.path_buf[0..pos];
}

fn checkMagic(file_path: []const u8) bool {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return false;
    defer file.close();
    var buf: [8]u8 = undefined;
    const n = file.pread(&buf, 0) catch return false;
    if (n < 8) return false;
    return std.mem.eql(u8, buf[0..8], MAGIC);
}

fn generateSparseFile(file_path: []const u8, stderr: *WriterType, allocator: std.mem.Allocator) !void {
    try stderr.writeAll("  Generating sparse benchmark file...\n");
    try stderr.flush();

    const file = try std.fs.cwd().createFile(file_path, .{ .read = true });
    defer file.close();

    // Write magic header
    try file.pwriteAll(MAGIC, 0);

    // Heap-allocate positions array (10K * 8 = 80KB)
    const positions = try allocator.alloc(u64, JUMP_COUNT);
    defer allocator.free(positions);

    inline for (encoding.all_encodings, 0..) |Enc, enc_idx| {
        const region_start: u64 = @as(u64, enc_idx) * REGION_SIZE;

        var prng = std.Random.DefaultPrng.init(SEED +% enc_idx);
        const rng = prng.random();

        for (positions) |*p| {
            const min_pos = region_start + 256;
            const max_pos = region_start + REGION_SIZE - 16;
            p.* = rng.intRangeAtMost(u64, min_pos, max_pos);
        }

        std.mem.sort(u64, positions, {}, std.sort.asc(u64));

        for (1..JUMP_COUNT) |i| {
            if (positions[i] < positions[i - 1] + 16) {
                positions[i] = positions[i - 1] + 16;
            }
        }

        for (0..JUMP_COUNT) |i| {
            const next_pos = if (i + 1 < JUMP_COUNT) positions[i + 1] else positions[0];
            var enc_buf: [16]u8 = undefined;
            const n = Enc.encode(next_pos, &enc_buf) catch unreachable;
            try file.pwriteAll(enc_buf[0..n], positions[i]);
        }
    }

    try stderr.writeAll("  Done.\n");
    try stderr.flush();
}

fn benchRandomAccess(stderr: *WriterType, allocator: std.mem.Allocator) !void {
    try stderr.writeAll("\n--- Random-Access Jumps (jumps/sec, 10K chain) ---\n");
    try stderr.print("{s:<15} | {s:>15}\n", .{ "Encoding", "Jumps/sec" });
    try stderr.writeAll("----------------+-----------------\n");
    try stderr.flush();

    const file_path = getSparsePath();

    if (!checkMagic(file_path)) {
        try generateSparseFile(file_path, stderr, allocator);
    } else {
        try stderr.writeAll("  Reusing existing benchmark file.\n");
        try stderr.flush();
    }

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Heap-allocate positions for reconstruction
    const positions = try allocator.alloc(u64, JUMP_COUNT);
    defer allocator.free(positions);

    inline for (encoding.all_encodings, 0..) |Enc, enc_idx| {
        const region_start: u64 = @as(u64, enc_idx) * REGION_SIZE;

        var prng = std.Random.DefaultPrng.init(SEED +% enc_idx);
        const rng = prng.random();

        for (positions) |*p| {
            const min_pos = region_start + 256;
            const max_pos = region_start + REGION_SIZE - 16;
            p.* = rng.intRangeAtMost(u64, min_pos, max_pos);
        }
        std.mem.sort(u64, positions, {}, std.sort.asc(u64));
        for (1..JUMP_COUNT) |i| {
            if (positions[i] < positions[i - 1] + 16) {
                positions[i] = positions[i - 1] + 16;
            }
        }

        const start_pos = positions[0];

        // Benchmark: follow the chain
        var best_ns: u64 = std.math.maxInt(u64);
        for (0..THROUGHPUT_RUNS) |_| {
            var current_pos: u64 = start_pos;
            var timer = try std.time.Timer.start();
            for (0..JUMP_COUNT) |_| {
                var read_buf: [16]u8 = undefined;
                const bytes_read = file.pread(&read_buf, current_pos) catch break;
                if (bytes_read == 0) break;
                const result = Enc.decode(read_buf[0..bytes_read]) catch break;
                current_pos = result.value;
            }
            const elapsed = timer.read();
            doNotOptimizeAway(current_pos);
            if (elapsed < best_ns) best_ns = elapsed;
        }

        const jumps_per_sec = if (best_ns > 0) (JUMP_COUNT * 1_000_000_000) / best_ns else 0;
        var comma_buf: [32]u8 = undefined;
        const formatted = fmtComma(jumps_per_sec, &comma_buf);

        try stderr.print("{s:<15} | {s:>15}\n", .{ Enc.name, formatted });
        try stderr.flush();
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const allocator = std.heap.page_allocator;

    try stderr.writeAll("\n=== BLIP Benchmark Suite ===\n");
    try stderr.flush();

    try benchThroughput(stderr, allocator);
    try stderr.flush();

    try benchBignum(stderr);
    try stderr.flush();

    try benchRandomAccess(stderr, allocator);
    try stderr.flush();

    try stderr.writeByte('\n');
    try stderr.flush();
}

test "benchmark placeholder" {
    _ = blip;
    try std.testing.expect(true);
}
