//! FLAC encoder wrapper — uses libFLAC C API via @cImport.
//! Encodes raw PCM audio to FLAC format, decodes FLAC back to PCM.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const c = if (build_options.enable_flac) @cImport({
    @cInclude("FLAC/stream_encoder.h");
    @cInclude("FLAC/stream_decoder.h");
}) else struct {};

pub const FlacError = error{
    EncoderFailed,
    DecoderFailed,
    UnsupportedFormat,
    OutOfMemory,
};

/// In-memory write context for FLAC encoder.
const WriteContext = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    allocator: Allocator,
    ok: bool = true,
};

/// FLAC stream write callback — appends data to in-memory buffer.
fn flacWriteCallback(
    _: [*c]const c.FLAC__StreamEncoder,
    buffer: [*c]const u8,
    bytes: usize,
    _: u32, // samples
    _: u32, // current_frame
    client_data: ?*anyopaque,
) callconv(.c) c_uint {
    const ctx: *WriteContext = @ptrCast(@alignCast(client_data.?));
    ctx.buf.appendSlice(ctx.allocator, buffer[0..bytes]) catch {
        ctx.ok = false;
        return 1; // FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR
    };
    return 0; // FLAC__STREAM_ENCODER_WRITE_STATUS_OK
}

/// Encode raw PCM samples to FLAC format in memory.
/// Samples must be interleaved, little-endian.
/// Returns owned FLAC data slice.
pub fn encodePcmToFlac(
    allocator: Allocator,
    samples: []const u8,
    num_channels: u16,
    sample_rate: u32,
    bits_per_sample: u16,
    num_sample_frames: u32,
) (FlacError || Allocator.Error)![]u8 {
    if (!build_options.enable_flac) return FlacError.UnsupportedFormat;

    if (bits_per_sample != 16 and bits_per_sample != 24 and bits_per_sample != 8)
        return FlacError.UnsupportedFormat;

    const encoder = c.FLAC__stream_encoder_new() orelse return FlacError.OutOfMemory;
    defer c.FLAC__stream_encoder_delete(encoder);

    _ = c.FLAC__stream_encoder_set_channels(encoder, num_channels);
    _ = c.FLAC__stream_encoder_set_bits_per_sample(encoder, bits_per_sample);
    _ = c.FLAC__stream_encoder_set_sample_rate(encoder, sample_rate);
    _ = c.FLAC__stream_encoder_set_compression_level(encoder, 5); // balanced
    _ = c.FLAC__stream_encoder_set_total_samples_estimate(encoder, num_sample_frames);
    _ = c.FLAC__stream_encoder_set_verify(encoder, 1); // verify encoding

    var ctx = WriteContext{ .allocator = allocator };

    const init_status = c.FLAC__stream_encoder_init_stream(
        encoder,
        flacWriteCallback,
        null, // seek callback
        null, // tell callback
        null, // metadata callback
        @ptrCast(&ctx),
    );

    if (init_status != 0) { // FLAC__STREAM_ENCODER_INIT_STATUS_OK = 0
        ctx.buf.deinit(allocator);
        return FlacError.EncoderFailed;
    }

    // Convert interleaved PCM bytes to FLAC's FLAC__int32 format
    const bytes_per_sample: usize = @as(usize, bits_per_sample) / 8;
    const total_samples = @as(usize, num_sample_frames) * @as(usize, num_channels);
    const int32_buf = try allocator.alloc(i32, total_samples);
    defer allocator.free(int32_buf);

    for (0..total_samples) |i| {
        const offset = i * bytes_per_sample;
        if (offset + bytes_per_sample > samples.len) break;

        int32_buf[i] = switch (bits_per_sample) {
            8 => @as(i32, samples[offset]) - 128, // unsigned 8-bit to signed
            16 => @as(i32, @as(i16, @bitCast([2]u8{ samples[offset], samples[offset + 1] }))),
            24 => blk: {
                const lo: u32 = samples[offset];
                const mid: u32 = samples[offset + 1];
                const hi: u32 = samples[offset + 2];
                const val: u32 = lo | (mid << 8) | (hi << 16);
                // Sign extend from 24-bit
                break :blk if (val & 0x800000 != 0)
                    @as(i32, @bitCast(val | 0xFF000000))
                else
                    @as(i32, @intCast(val));
            },
            else => 0,
        };
    }

    // Process in chunks of 4096 frames
    const chunk_size: u32 = 4096;
    var frames_done: u32 = 0;
    while (frames_done < num_sample_frames) {
        const remaining = num_sample_frames - frames_done;
        const this_chunk = @min(remaining, chunk_size);
        const start = @as(usize, frames_done) * @as(usize, num_channels);

        const ok = c.FLAC__stream_encoder_process_interleaved(
            encoder,
            @ptrCast(int32_buf.ptr + start),
            this_chunk,
        );
        if (ok == 0) {
            ctx.buf.deinit(allocator);
            return FlacError.EncoderFailed;
        }
        frames_done += this_chunk;
    }

    const finish_ok = c.FLAC__stream_encoder_finish(encoder);
    if (finish_ok == 0 or !ctx.ok) {
        ctx.buf.deinit(allocator);
        return FlacError.EncoderFailed;
    }

    return try ctx.buf.toOwnedSlice(allocator);
}

/// In-memory read/write context for FLAC decoder.
const DecodeContext = struct {
    input: []const u8,
    input_pos: usize = 0,
    output: std.ArrayListUnmanaged(u8) = .{},
    allocator: Allocator,
    channels: u32 = 0,
    sample_rate: u32 = 0,
    bps: u32 = 0,
    total_samples: u64 = 0,
    ok: bool = true,
};

fn flacDecReadCallback(
    _: [*c]const c.FLAC__StreamDecoder,
    buffer: [*c]u8,
    bytes: [*c]usize,
    client_data: ?*anyopaque,
) callconv(.c) c_uint {
    const ctx: *DecodeContext = @ptrCast(@alignCast(client_data.?));
    const avail = ctx.input.len - ctx.input_pos;
    if (avail == 0) {
        bytes.* = 0;
        return 1; // END_OF_STREAM
    }
    const to_read = @min(avail, bytes.*);
    @memcpy(buffer[0..to_read], ctx.input[ctx.input_pos..][0..to_read]);
    ctx.input_pos += to_read;
    bytes.* = to_read;
    return 0; // OK
}

fn flacDecWriteCallback(
    _: [*c]const c.FLAC__StreamDecoder,
    frame: [*c]const c.FLAC__Frame,
    buffer: [*c]const [*c]const i32,
    client_data: ?*anyopaque,
) callconv(.c) c_uint {
    const ctx: *DecodeContext = @ptrCast(@alignCast(client_data.?));
    const fr = frame[0];
    const blocksize = fr.header.blocksize;
    const channels = fr.header.channels;
    const bps = fr.header.bits_per_sample;
    const bytes_per_sample: usize = (@as(usize, bps) + 7) / 8;

    for (0..blocksize) |s| {
        for (0..channels) |ch| {
            const sample = buffer[ch][s];
            switch (bps) {
                8 => {
                    const val: u8 = @intCast(@as(i32, sample) + 128);
                    ctx.output.append(ctx.allocator, val) catch {
                        ctx.ok = false;
                        return 1;
                    };
                },
                16 => {
                    const val: u16 = @bitCast(@as(i16, @intCast(sample)));
                    ctx.output.appendSlice(ctx.allocator, &[2]u8{
                        @truncate(val), @truncate(val >> 8),
                    }) catch {
                        ctx.ok = false;
                        return 1;
                    };
                },
                24 => {
                    const val: u32 = @bitCast(sample);
                    ctx.output.appendSlice(ctx.allocator, &[3]u8{
                        @truncate(val), @truncate(val >> 8), @truncate(val >> 16),
                    }) catch {
                        ctx.ok = false;
                        return 1;
                    };
                },
                else => {
                    _ = bytes_per_sample;
                },
            }
        }
    }
    return 0;
}

fn flacDecMetadataCallback(
    _: [*c]const c.FLAC__StreamDecoder,
    metadata: [*c]const c.FLAC__StreamMetadata,
    client_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *DecodeContext = @ptrCast(@alignCast(client_data.?));
    const meta = metadata[0];
    if (meta.type == 0) { // FLAC__METADATA_TYPE_STREAMINFO
        ctx.channels = meta.data.stream_info.channels;
        ctx.sample_rate = meta.data.stream_info.sample_rate;
        ctx.bps = meta.data.stream_info.bits_per_sample;
        ctx.total_samples = meta.data.stream_info.total_samples;
    }
}

fn flacDecErrorCallback(
    _: [*c]const c.FLAC__StreamDecoder,
    _: c_uint,
    client_data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *DecodeContext = @ptrCast(@alignCast(client_data.?));
    ctx.ok = false;
}

/// Decode FLAC data back to raw PCM samples.
pub fn decodeFlacToPcm(
    allocator: Allocator,
    flac_data: []const u8,
    out_channels: *u32,
    out_sample_rate: *u32,
    out_bps: *u32,
    out_total_samples: *u64,
) (FlacError || Allocator.Error)![]u8 {
    if (!build_options.enable_flac) return FlacError.UnsupportedFormat;

    const decoder = c.FLAC__stream_decoder_new() orelse return FlacError.OutOfMemory;
    defer c.FLAC__stream_decoder_delete(decoder);

    var ctx = DecodeContext{ .input = flac_data, .allocator = allocator };

    const init_status = c.FLAC__stream_decoder_init_stream(
        decoder,
        flacDecReadCallback,
        null, null, null, // seek, tell, length
        null, // eof
        flacDecWriteCallback,
        flacDecMetadataCallback,
        flacDecErrorCallback,
        @ptrCast(&ctx),
    );

    if (init_status != 0) {
        ctx.output.deinit(allocator);
        return FlacError.DecoderFailed;
    }

    const ok = c.FLAC__stream_decoder_process_until_end_of_stream(decoder);
    if (ok == 0 or !ctx.ok) {
        ctx.output.deinit(allocator);
        return FlacError.DecoderFailed;
    }

    _ = c.FLAC__stream_decoder_finish(decoder);

    out_channels.* = ctx.channels;
    out_sample_rate.* = ctx.sample_rate;
    out_bps.* = ctx.bps;
    out_total_samples.* = ctx.total_samples;

    return try ctx.output.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "FLAC encode/decode 16-bit stereo roundtrip" {
    if (!build_options.enable_flac) return error.SkipZigTest;

    const num_channels: u16 = 2;
    const sample_rate: u32 = 44100;
    const bps: u16 = 16;
    const num_frames: u32 = 4410; // 0.1 seconds

    // Generate test PCM data
    const total_samples = @as(usize, num_frames) * @as(usize, num_channels);
    const bytes_per_sample: usize = 2;
    const pcm_len = total_samples * bytes_per_sample;
    const pcm = try testing.allocator.alloc(u8, pcm_len);
    defer testing.allocator.free(pcm);

    for (0..num_frames) |s| {
        for (0..num_channels) |ch| {
            const idx = (s * num_channels + ch) * bytes_per_sample;
            const val: i16 = @intCast(@mod(@as(i32, @intCast(s * 137 + ch * 53)), 32768) - 16384);
            const uval: u16 = @bitCast(val);
            pcm[idx] = @truncate(uval);
            pcm[idx + 1] = @truncate(uval >> 8);
        }
    }

    // Encode
    const flac_data = try encodePcmToFlac(testing.allocator, pcm, num_channels, sample_rate, bps, num_frames);
    defer testing.allocator.free(flac_data);

    try testing.expect(flac_data.len > 0);
    try testing.expect(flac_data.len < pcm_len); // FLAC should be smaller

    // Decode
    var dec_channels: u32 = 0;
    var dec_rate: u32 = 0;
    var dec_bps: u32 = 0;
    var dec_total: u64 = 0;
    const decoded = try decodeFlacToPcm(testing.allocator, flac_data, &dec_channels, &dec_rate, &dec_bps, &dec_total);
    defer testing.allocator.free(decoded);

    try testing.expectEqual(@as(u32, num_channels), dec_channels);
    try testing.expectEqual(sample_rate, dec_rate);
    try testing.expectEqual(@as(u32, bps), dec_bps);
    try testing.expectEqual(@as(u64, num_frames), dec_total);
    try testing.expectEqualSlices(u8, pcm, decoded);
}
