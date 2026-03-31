const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AiffError = error{
    InvalidAiff,
    UnsupportedAiff,
    CorruptedData,
};

pub const AiffInfo = struct {
    num_channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    num_samples: u32,
};

pub const ParsedAiff = struct {
    info: AiffInfo,
    /// Raw PCM samples converted to little-endian interleaved (same format as WAV).
    samples: []u8,
    /// Compact metadata: non-PCM bytes for reconstruction.
    /// Format: [u32_be total_file_size][u32_be ssnd_offset][u32_be ssnd_data_size]
    ///         [u8 ssnd_block_size_offset][pre_ssnd_data][post_ssnd_data]
    meta: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedAiff) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.meta);
    }
};

const FORM_MAGIC = [_]u8{ 'F', 'O', 'R', 'M' };
const AIFF_MAGIC = [_]u8{ 'A', 'I', 'F', 'F' };
const AIFF_C_MAGIC = [_]u8{ 'A', 'I', 'F', 'C' };

/// Check if buffer starts with AIFF magic (FORM....AIFF or FORM....AIFC).
pub fn isAiffMagic(buf: []const u8) bool {
    if (buf.len < 12) return false;
    return std.mem.eql(u8, buf[0..4], &FORM_MAGIC) and
        (std.mem.eql(u8, buf[8..12], &AIFF_MAGIC) or
        std.mem.eql(u8, buf[8..12], &AIFF_C_MAGIC));
}

fn readU16BE(buf: []const u8) u16 {
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

fn readU32BE(buf: []const u8) u32 {
    return (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) |
        (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);
}

/// Parse 80-bit IEEE 754 extended precision to u32 (for sample rate).
/// AIFF stores sample rate as 80-bit extended float.
fn parseExtended80(buf: []const u8) u32 {
    // Simple extraction: works for common rates (8000-192000 Hz)
    const sign = (buf[0] >> 7) & 1;
    _ = sign;
    const exponent = ((@as(u16, buf[0]) & 0x7F) << 8) | @as(u16, buf[1]);
    const mantissa_hi = readU32BE(buf[2..6]);

    if (exponent == 0 and mantissa_hi == 0) return 0;

    // Bias for 80-bit extended is 16383
    const exp_val: i32 = @as(i32, exponent) - 16383;
    // The mantissa has an explicit integer bit (bit 63)
    // For common sample rates, the value fits in u32
    if (exp_val < 0) return 0;
    if (exp_val > 31) return 0;

    // Shift mantissa right to get integer value
    const shift: u5 = @intCast(31 - exp_val);
    return mantissa_hi >> shift;
}

/// Parse an AIFF file into audio info + PCM samples (converted to LE).
/// Only supports uncompressed AIFF (not AIFF-C compressed).
pub fn parseAiff(allocator: Allocator, data: []const u8) (AiffError || Allocator.Error)!ParsedAiff {
    if (data.len < 54) return AiffError.InvalidAiff;
    if (!isAiffMagic(data)) return AiffError.InvalidAiff;

    // Reject AIFF-C (compressed) for now
    if (std.mem.eql(u8, data[8..12], &AIFF_C_MAGIC)) return AiffError.UnsupportedAiff;

    var pos: usize = 12;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var num_frames: u32 = 0;
    var ssnd_offset: usize = 0;
    var ssnd_data_size: u32 = 0;
    var ssnd_block_offset: u32 = 0;

    while (pos + 8 <= data.len) {
        const chunk_id = data[pos..][0..4];
        const chunk_size = readU32BE(data[pos + 4 ..][0..4]);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "COMM")) {
            if (chunk_size < 18 or pos + 18 > data.len) return AiffError.CorruptedData;
            num_channels = readU16BE(data[pos..][0..2]);
            num_frames = readU32BE(data[pos + 2 ..][0..4]);
            bits_per_sample = readU16BE(data[pos + 6 ..][0..2]);
            sample_rate = parseExtended80(data[pos + 8 ..][0..10]);

            if (num_channels == 0 or sample_rate == 0) return AiffError.InvalidAiff;
            if (bits_per_sample != 8 and bits_per_sample != 16 and bits_per_sample != 24)
                return AiffError.UnsupportedAiff;
        } else if (std.mem.eql(u8, chunk_id, "SSND")) {
            if (pos + 8 > data.len) return AiffError.CorruptedData;
            ssnd_block_offset = readU32BE(data[pos..][0..4]);
            // Skip the 8-byte SSND header (offset + blockSize fields)
            ssnd_offset = pos + 8 + @as(usize, ssnd_block_offset);
            ssnd_data_size = chunk_size - 8 - ssnd_block_offset;
        }

        // Advance (word-aligned)
        pos += (@as(usize, chunk_size) + 1) & ~@as(usize, 1);
    }

    if (num_channels == 0 or ssnd_offset == 0 or num_frames == 0) return AiffError.InvalidAiff;
    if (ssnd_offset + ssnd_data_size > data.len) return AiffError.CorruptedData;

    const bytes_per_sample: usize = (@as(usize, bits_per_sample) + 7) / 8;
    const expected_pcm = @as(usize, num_frames) * @as(usize, num_channels) * bytes_per_sample;

    // Convert big-endian PCM to little-endian
    const samples = try allocator.alloc(u8, expected_pcm);
    const src = data[ssnd_offset..][0..@min(ssnd_data_size, expected_pcm)];

    const total_sample_count = @as(usize, num_frames) * @as(usize, num_channels);
    for (0..total_sample_count) |i| {
        const off = i * bytes_per_sample;
        if (off + bytes_per_sample > src.len) break;

        switch (bytes_per_sample) {
            1 => samples[off] = src[off],
            2 => {
                // BE to LE
                samples[off] = src[off + 1];
                samples[off + 1] = src[off];
            },
            3 => {
                samples[off] = src[off + 2];
                samples[off + 1] = src[off + 1];
                samples[off + 2] = src[off];
            },
            else => {},
        }
    }

    // Build compact metadata: non-PCM bytes
    const pre_ssnd_len = ssnd_offset;
    const post_ssnd_start = ssnd_offset + @as(usize, ssnd_data_size);
    const post_ssnd_len = if (post_ssnd_start < data.len) data.len - post_ssnd_start else 0;
    const meta_prefix: usize = 13; // 3 x u32_be + 1 x u8
    const meta_len = meta_prefix + pre_ssnd_len + post_ssnd_len;
    const meta = try allocator.alloc(u8, meta_len);

    std.mem.writeInt(u32, meta[0..4], @intCast(data.len), .big);
    std.mem.writeInt(u32, meta[4..8], @intCast(ssnd_offset), .big);
    std.mem.writeInt(u32, meta[8..12], ssnd_data_size, .big);
    meta[12] = @truncate(ssnd_block_offset);
    if (pre_ssnd_len > 0) @memcpy(meta[meta_prefix..][0..pre_ssnd_len], data[0..pre_ssnd_len]);
    if (post_ssnd_len > 0) @memcpy(meta[meta_prefix + pre_ssnd_len ..], data[post_ssnd_start..]);

    return ParsedAiff{
        .info = AiffInfo{
            .num_channels = num_channels,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .num_samples = num_frames,
        },
        .samples = samples,
        .meta = meta,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeU16BE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val >> 8);
    buf[1] = @truncate(val);
}

fn writeU32BE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val >> 24);
    buf[1] = @truncate(val >> 16);
    buf[2] = @truncate(val >> 8);
    buf[3] = @truncate(val);
}

/// Encode a sample rate as 80-bit IEEE 754 extended.
fn encodeExtended80(rate: u32) [10]u8 {
    var result: [10]u8 = [_]u8{0} ** 10;
    if (rate == 0) return result;

    // Find position of highest bit
    var r = rate;
    var exp: u16 = 16383 + 31;
    while (r != 0 and (r & 0x80000000) == 0) {
        r <<= 1;
        exp -= 1;
    }

    result[0] = @truncate(exp >> 8);
    result[1] = @truncate(exp);
    writeU32BE(result[2..6], r);
    return result;
}

fn makeTestAiff(allocator: Allocator, channels: u16, rate: u32, bps: u16, frames: u32) ![]u8 {
    const bytes_per_sample = @as(u32, bps) / 8;
    const pcm_size = frames * @as(u32, channels) * bytes_per_sample;
    // SSND chunk: 8 (header) + 8 (offset + blockSize) + pcm
    const ssnd_chunk_size: u32 = 8 + pcm_size;
    // COMM chunk: 18 bytes
    const comm_chunk_size: u32 = 18;
    // Total FORM size: 4 (AIFF) + 8+comm + 8+ssnd
    const form_size: u32 = 4 + 8 + comm_chunk_size + 8 + ssnd_chunk_size;
    const total = 8 + form_size;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // FORM header
    @memcpy(buf[0..4], "FORM");
    writeU32BE(buf[4..8], form_size);
    @memcpy(buf[8..12], "AIFF");

    // COMM chunk
    var off: usize = 12;
    @memcpy(buf[off..][0..4], "COMM");
    writeU32BE(buf[off + 4 ..][0..4], comm_chunk_size);
    off += 8;
    writeU16BE(buf[off..][0..2], channels);
    writeU32BE(buf[off + 2 ..][0..4], frames);
    writeU16BE(buf[off + 6 ..][0..2], bps);
    const sr_ext = encodeExtended80(rate);
    @memcpy(buf[off + 8 ..][0..10], &sr_ext);
    off += comm_chunk_size;

    // SSND chunk
    @memcpy(buf[off..][0..4], "SSND");
    writeU32BE(buf[off + 4 ..][0..4], ssnd_chunk_size);
    off += 8;
    // offset=0, blockSize=0
    off += 8;

    // PCM data (big-endian)
    for (0..frames) |s| {
        for (0..channels) |ch| {
            if (bps == 16) {
                const val: i16 = @intCast(@mod(@as(i32, @intCast(s * 137 + ch * 53)), 32768) - 16384);
                const uval: u16 = @bitCast(val);
                buf[off] = @truncate(uval >> 8); // BE
                buf[off + 1] = @truncate(uval);
                off += 2;
            } else if (bps == 8) {
                buf[off] = @truncate((s * 137 + ch * 53) & 0xFF);
                off += 1;
            }
        }
    }

    return buf;
}

test "AIFF magic detection" {
    const aiff = try makeTestAiff(testing.allocator, 2, 44100, 16, 100);
    defer testing.allocator.free(aiff);
    try testing.expect(isAiffMagic(aiff));
}

test "AIFF magic rejects non-AIFF" {
    try testing.expect(!isAiffMagic("RIFF\x00\x00\x00\x00WAVE"));
    try testing.expect(!isAiffMagic(&[_]u8{ 'F', 'O', 'R', 'M' }));
}

test "AIFF parse stereo 16-bit" {
    const aiff = try makeTestAiff(testing.allocator, 2, 44100, 16, 1000);
    defer testing.allocator.free(aiff);

    var parsed = try parseAiff(testing.allocator, aiff);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 2), parsed.info.num_channels);
    try testing.expectEqual(@as(u32, 44100), parsed.info.sample_rate);
    try testing.expectEqual(@as(u16, 16), parsed.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 1000), parsed.info.num_samples);
    try testing.expectEqual(@as(usize, 1000 * 2 * 2), parsed.samples.len);
}

test "AIFF big-endian to little-endian conversion" {
    const aiff = try makeTestAiff(testing.allocator, 1, 44100, 16, 1);
    defer testing.allocator.free(aiff);

    // Set known BE sample value: 0x0123
    const ssnd_start = 12 + 8 + 18 + 8 + 8; // after all headers
    aiff[ssnd_start] = 0x01; // high byte (BE)
    aiff[ssnd_start + 1] = 0x23; // low byte (BE)

    var parsed = try parseAiff(testing.allocator, aiff);
    defer parsed.deinit();

    // Should be LE: 0x23, 0x01
    try testing.expectEqual(@as(u8, 0x23), parsed.samples[0]);
    try testing.expectEqual(@as(u8, 0x01), parsed.samples[1]);
}

test "AIFF extended80 sample rate parsing" {
    try testing.expectEqual(@as(u32, 44100), parseExtended80(&encodeExtended80(44100)));
    try testing.expectEqual(@as(u32, 48000), parseExtended80(&encodeExtended80(48000)));
    try testing.expectEqual(@as(u32, 22050), parseExtended80(&encodeExtended80(22050)));
    try testing.expectEqual(@as(u32, 96000), parseExtended80(&encodeExtended80(96000)));
}
