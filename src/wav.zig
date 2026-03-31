const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WavError = error{
    InvalidWav,
    UnsupportedWav,
    CorruptedData,
};

pub const WavInfo = struct {
    num_channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    /// Total number of sample frames (samples per channel).
    num_samples: u32,
};

pub const ParsedWav = struct {
    info: WavInfo,
    /// Raw PCM sample data (interleaved, little-endian).
    samples: []u8,
    /// Complete original WAV file for faithful reconstruction.
    /// WAV has complex chunk structure that can't easily be reconstructed
    /// from PCM alone (extra chunks, padding, etc).
    original: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedWav) void {
        self.allocator.free(self.samples);
        self.allocator.free(self.original);
    }
};

const RIFF_MAGIC = [_]u8{ 'R', 'I', 'F', 'F' };
const WAVE_MAGIC = [_]u8{ 'W', 'A', 'V', 'E' };

/// Check if buffer starts with WAV magic (RIFF....WAVE).
pub fn isWavMagic(buf: []const u8) bool {
    if (buf.len < 12) return false;
    return std.mem.eql(u8, buf[0..4], &RIFF_MAGIC) and
        std.mem.eql(u8, buf[8..12], &WAVE_MAGIC);
}

fn readU16LE(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32LE(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

/// Parse a WAV file into audio info + raw PCM samples.
/// Only supports uncompressed PCM (format tag 1), 8/16/24/32-bit.
pub fn parseWav(allocator: Allocator, data: []const u8) (WavError || Allocator.Error)!ParsedWav {
    if (data.len < 44) return WavError.InvalidWav;
    if (!isWavMagic(data)) return WavError.InvalidWav;

    // Walk RIFF chunks to find fmt and data
    var pos: usize = 12; // after RIFF header + WAVE
    var fmt_found = false;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;

    var data_offset: usize = 0;
    var data_size: u32 = 0;

    while (pos + 8 <= data.len) {
        const chunk_id = data[pos..][0..4];
        const chunk_size = readU32LE(data[pos + 4 ..][0..4]);
        pos += 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16 or pos + 16 > data.len) return WavError.CorruptedData;
            const format_tag = readU16LE(data[pos..][0..2]);
            if (format_tag != 1) return WavError.UnsupportedWav; // Only PCM

            num_channels = readU16LE(data[pos + 2 ..][0..2]);
            sample_rate = readU32LE(data[pos + 4 ..][0..4]);
            // bytes 8..11: byte rate (skip)
            // bytes 12..13: block align (skip)
            bits_per_sample = readU16LE(data[pos + 14 ..][0..2]);

            if (num_channels == 0 or sample_rate == 0) return WavError.InvalidWav;
            if (bits_per_sample != 8 and bits_per_sample != 16 and
                bits_per_sample != 24 and bits_per_sample != 32)
                return WavError.UnsupportedWav;

            fmt_found = true;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = pos;
            data_size = chunk_size;
        }

        // Advance to next chunk (word-aligned)
        pos += (@as(usize, chunk_size) + 1) & ~@as(usize, 1);
    }

    if (!fmt_found or data_offset == 0) return WavError.InvalidWav;
    if (data_offset + data_size > data.len) return WavError.CorruptedData;

    const bytes_per_sample = @as(u32, bits_per_sample) / 8;
    const block_align = @as(u32, num_channels) * bytes_per_sample;
    const num_samples = if (block_align > 0) data_size / block_align else 0;

    // Copy PCM data
    const samples = try allocator.alloc(u8, data_size);
    @memcpy(samples, data[data_offset..][0..data_size]);

    // Build compact metadata: non-PCM bytes only
    // Format: [u32_le total_file_size][u32_le data_chunk_offset][u32_le data_chunk_size]
    //         [pre_data_bytes][post_data_bytes]
    const pre_data_len = data_offset;
    const post_data_start = data_offset + data_size;
    const post_data_len = if (post_data_start < data.len) data.len - post_data_start else 0;
    const meta_prefix: usize = 12; // 3 x u32
    const meta_len = meta_prefix + pre_data_len + post_data_len;
    const original = try allocator.alloc(u8, meta_len);

    const file_size_u32: u32 = @intCast(data.len);
    const data_off_u32: u32 = @intCast(data_offset);
    std.mem.writeInt(u32, original[0..4], file_size_u32, .little);
    std.mem.writeInt(u32, original[4..8], data_off_u32, .little);
    std.mem.writeInt(u32, original[8..12], data_size, .little);
    if (pre_data_len > 0) @memcpy(original[meta_prefix..][0..pre_data_len], data[0..pre_data_len]);
    if (post_data_len > 0) @memcpy(original[meta_prefix + pre_data_len..], data[post_data_start..]);

    return ParsedWav{
        .info = WavInfo{
            .num_channels = num_channels,
            .sample_rate = sample_rate,
            .bits_per_sample = bits_per_sample,
            .num_samples = num_samples,
        },
        .samples = samples,
        .original = original,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestWav(allocator: Allocator, num_channels: u16, sample_rate: u32, bps: u16, num_samples: u32) ![]u8 {
    const bytes_per_sample = @as(u32, bps) / 8;
    const block_align = @as(u32, num_channels) * bytes_per_sample;
    const data_size = num_samples * block_align;
    const file_size: u32 = 36 + data_size; // RIFF header(8) + WAVE(4) + fmt(24) + data(8) + samples

    const buf = try allocator.alloc(u8, 44 + data_size);
    @memset(buf, 0);

    // RIFF header
    @memcpy(buf[0..4], "RIFF");
    const riff_size: u32 = file_size - 8;
    buf[4] = @truncate(riff_size);
    buf[5] = @truncate(riff_size >> 8);
    buf[6] = @truncate(riff_size >> 16);
    buf[7] = @truncate(riff_size >> 24);
    @memcpy(buf[8..12], "WAVE");

    // fmt chunk
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 16; // chunk size
    buf[20] = 1; // PCM format
    buf[22] = @truncate(num_channels);
    buf[23] = @truncate(num_channels >> 8);
    buf[24] = @truncate(sample_rate);
    buf[25] = @truncate(sample_rate >> 8);
    buf[26] = @truncate(sample_rate >> 16);
    buf[27] = @truncate(sample_rate >> 24);
    const byte_rate = sample_rate * block_align;
    buf[28] = @truncate(byte_rate);
    buf[29] = @truncate(byte_rate >> 8);
    buf[30] = @truncate(byte_rate >> 16);
    buf[31] = @truncate(byte_rate >> 24);
    buf[32] = @truncate(block_align);
    buf[33] = @truncate(block_align >> 8);
    buf[34] = @truncate(bps);
    buf[35] = @truncate(bps >> 8);

    // data chunk
    @memcpy(buf[36..40], "data");
    buf[40] = @truncate(data_size);
    buf[41] = @truncate(data_size >> 8);
    buf[42] = @truncate(data_size >> 16);
    buf[43] = @truncate(data_size >> 24);

    // Fill with a sine-like pattern
    const samples_buf = buf[44..];
    for (0..num_samples) |s| {
        for (0..num_channels) |ch| {
            const offset = (s * @as(usize, num_channels) + ch) * @as(usize, bytes_per_sample);
            if (bps == 16) {
                const val: i16 = @intCast(@mod(@as(i32, @intCast(s * 137 + ch * 53)), 32768) - 16384);
                const uval: u16 = @bitCast(val);
                samples_buf[offset] = @truncate(uval);
                samples_buf[offset + 1] = @truncate(uval >> 8);
            } else if (bps == 8) {
                samples_buf[offset] = @truncate((s * 137 + ch * 53) & 0xFF);
            }
        }
    }

    return buf;
}

test "WAV magic detection" {
    const wav = try makeTestWav(testing.allocator, 2, 44100, 16, 100);
    defer testing.allocator.free(wav);
    try testing.expect(isWavMagic(wav));
}

test "WAV magic rejects non-WAV" {
    try testing.expect(!isWavMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    try testing.expect(!isWavMagic("RIFF\x00\x00\x00\x00AVI "));
}

test "WAV parse stereo 16-bit" {
    const wav = try makeTestWav(testing.allocator, 2, 44100, 16, 1000);
    defer testing.allocator.free(wav);

    var parsed = try parseWav(testing.allocator, wav);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 2), parsed.info.num_channels);
    try testing.expectEqual(@as(u32, 44100), parsed.info.sample_rate);
    try testing.expectEqual(@as(u16, 16), parsed.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 1000), parsed.info.num_samples);
    try testing.expectEqual(@as(usize, 1000 * 2 * 2), parsed.samples.len);
    // Compact metadata: first 4 bytes = file size
    const stored_size = std.mem.readInt(u32, parsed.original[0..4], .little);
    try testing.expectEqual(@as(u32, @intCast(wav.len)), stored_size);
}

test "WAV parse mono 8-bit" {
    const wav = try makeTestWav(testing.allocator, 1, 22050, 8, 500);
    defer testing.allocator.free(wav);

    var parsed = try parseWav(testing.allocator, wav);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 1), parsed.info.num_channels);
    try testing.expectEqual(@as(u32, 22050), parsed.info.sample_rate);
    try testing.expectEqual(@as(u16, 8), parsed.info.bits_per_sample);
    try testing.expectEqual(@as(u32, 500), parsed.info.num_samples);
}

test "WAV rejects non-PCM" {
    const wav = try makeTestWav(testing.allocator, 1, 44100, 16, 100);
    defer testing.allocator.free(wav);
    wav[20] = 3; // IEEE float format tag
    try testing.expectError(WavError.UnsupportedWav, parseWav(testing.allocator, wav));
}
