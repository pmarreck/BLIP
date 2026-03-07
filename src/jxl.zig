const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("jxl/encode.h");
    @cInclude("jxl/decode.h");
    @cInclude("jxl/types.h");
});

pub const JxlError = error{
    EmptyInput,
    InvalidJpeg,
    InvalidPixelData,
    JxlEncoderCreateFailed,
    JxlEncoderConfigFailed,
    JxlEncodeFailed,
    JxlDecoderCreateFailed,
    JxlDecoderConfigFailed,
    JxlDecodeFailed,
};

/// Pixel format descriptor for raw pixel data.
pub const PixelFormat = struct {
    width: u32,
    height: u32,
    num_channels: u32, // 1 (gray), 2 (gray+alpha), 3 (RGB), 4 (RGBA)
    bits_per_sample: u32, // 8 or 16
};

/// Check if buffer starts with JPEG SOI marker (FF D8).
pub fn isJpegData(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 0xFF and buf[1] == 0xD8;
}

/// Losslessly transcode JPEG to JPEG XL.
/// The resulting JXL preserves JPEG metadata for bit-exact reconstruction.
/// Caller owns the returned slice.
pub fn jpegToJxl(allocator: Allocator, jpeg_bytes: []const u8) (JxlError || Allocator.Error)![]u8 {
    if (jpeg_bytes.len == 0) return JxlError.EmptyInput;
    if (!isJpegData(jpeg_bytes)) return JxlError.InvalidJpeg;

    const enc = c.JxlEncoderCreate(null) orelse return JxlError.JxlEncoderCreateFailed;
    defer c.JxlEncoderDestroy(enc);

    // Enable JPEG metadata storage for bit-exact roundtrip
    if (c.JxlEncoderStoreJPEGMetadata(enc, @intFromBool(true)) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncoderConfigFailed;

    const frame_settings = c.JxlEncoderFrameSettingsCreate(enc, null) orelse
        return JxlError.JxlEncoderCreateFailed;

    if (c.JxlEncoderAddJPEGFrame(frame_settings, jpeg_bytes.ptr, jpeg_bytes.len) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncodeFailed;

    c.JxlEncoderCloseInput(enc);

    // Collect output — start with input size as initial estimate
    var buf_size: usize = @max(jpeg_bytes.len, 4096);
    var output = try allocator.alloc(u8, buf_size);
    errdefer allocator.free(output);
    var written: usize = 0;

    while (true) {
        var next_out: [*c]u8 = output.ptr + written;
        var avail_out: usize = buf_size - written;

        const status = c.JxlEncoderProcessOutput(enc, &next_out, &avail_out);
        written = buf_size - avail_out;

        switch (status) {
            c.JXL_ENC_SUCCESS => break,
            c.JXL_ENC_NEED_MORE_OUTPUT => {
                buf_size *|= 2;
                output = try allocator.realloc(output, buf_size);
            },
            else => return JxlError.JxlEncodeFailed,
        }
    }

    // Shrink to actual size
    if (written < output.len) {
        if (allocator.realloc(output, written)) |shrunk| {
            return shrunk;
        } else |_| {
            return output[0..written];
        }
    }
    return output;
}

/// Losslessly transcode JPEG XL back to the original JPEG bytes.
/// Only works for JXL files that were created from JPEG with metadata preservation.
/// Returns bit-exact original JPEG. Caller owns the returned slice.
pub fn jxlToJpeg(allocator: Allocator, jxl_bytes: []const u8) (JxlError || Allocator.Error)![]u8 {
    if (jxl_bytes.len == 0) return JxlError.EmptyInput;

    const dec = c.JxlDecoderCreate(null) orelse return JxlError.JxlDecoderCreateFailed;
    defer c.JxlDecoderDestroy(dec);

    if (c.JxlDecoderSubscribeEvents(dec, c.JXL_DEC_JPEG_RECONSTRUCTION | c.JXL_DEC_FULL_IMAGE) != c.JXL_DEC_SUCCESS)
        return JxlError.JxlDecoderConfigFailed;

    if (c.JxlDecoderSetInput(dec, jxl_bytes.ptr, jxl_bytes.len) != c.JXL_DEC_SUCCESS)
        return JxlError.JxlDecoderConfigFailed;
    c.JxlDecoderCloseInput(dec);

    var jpeg_buf: ?[]u8 = null;
    errdefer if (jpeg_buf) |buf| allocator.free(buf);
    var jpeg_alloc_size: usize = 0;
    var jpeg_written: usize = 0;

    while (true) {
        const status = c.JxlDecoderProcessInput(dec);

        switch (status) {
            c.JXL_DEC_JPEG_RECONSTRUCTION => {
                // Allocate initial JPEG output buffer
                jpeg_alloc_size = @max(jxl_bytes.len * 2, 4096);
                jpeg_buf = try allocator.alloc(u8, jpeg_alloc_size);
                if (c.JxlDecoderSetJPEGBuffer(dec, jpeg_buf.?.ptr, jpeg_alloc_size) != c.JXL_DEC_SUCCESS)
                    return JxlError.JxlDecodeFailed;
            },
            c.JXL_DEC_JPEG_NEED_MORE_OUTPUT => {
                // Grow JPEG output buffer
                const remaining = c.JxlDecoderReleaseJPEGBuffer(dec);
                jpeg_written = jpeg_alloc_size - remaining;
                jpeg_alloc_size *|= 2;
                jpeg_buf = try allocator.realloc(jpeg_buf.?, jpeg_alloc_size);
                if (c.JxlDecoderSetJPEGBuffer(
                    dec,
                    jpeg_buf.?.ptr + jpeg_written,
                    jpeg_alloc_size - jpeg_written,
                ) != c.JXL_DEC_SUCCESS)
                    return JxlError.JxlDecodeFailed;
            },
            c.JXL_DEC_FULL_IMAGE => {
                // Decoding complete
                const remaining = c.JxlDecoderReleaseJPEGBuffer(dec);
                jpeg_written = jpeg_alloc_size - remaining;
                break;
            },
            c.JXL_DEC_SUCCESS => break,
            else => return JxlError.JxlDecodeFailed,
        }
    }

    if (jpeg_buf) |buf| {
        // Shrink to actual size
        if (jpeg_written < buf.len) {
            if (allocator.realloc(buf, jpeg_written)) |shrunk| {
                return shrunk;
            } else |_| {
                return buf[0..jpeg_written];
            }
        }
        return buf;
    }
    return JxlError.JxlDecodeFailed;
}

/// Encode raw pixel data to JXL lossless format.
/// Caller owns the returned slice.
pub fn pixelsToJxl(allocator: Allocator, pixels: []const u8, fmt: PixelFormat) (JxlError || Allocator.Error)![]u8 {
    if (pixels.len == 0) return JxlError.EmptyInput;
    if (fmt.width == 0 or fmt.height == 0) return JxlError.InvalidPixelData;
    if (fmt.num_channels < 1 or fmt.num_channels > 4) return JxlError.InvalidPixelData;
    if (fmt.bits_per_sample != 8 and fmt.bits_per_sample != 16) return JxlError.InvalidPixelData;

    const bytes_per_pixel = fmt.num_channels * (fmt.bits_per_sample / 8);
    const expected_len = @as(usize, fmt.width) * @as(usize, fmt.height) * bytes_per_pixel;
    if (pixels.len != expected_len) return JxlError.InvalidPixelData;

    const enc = c.JxlEncoderCreate(null) orelse return JxlError.JxlEncoderCreateFailed;
    defer c.JxlEncoderDestroy(enc);

    const frame_settings = c.JxlEncoderFrameSettingsCreate(enc, null) orelse
        return JxlError.JxlEncoderCreateFailed;

    // Set lossless mode
    if (c.JxlEncoderSetFrameLossless(frame_settings, @intFromBool(true)) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncoderConfigFailed;

    // Set basic info
    var info: c.JxlBasicInfo = undefined;
    c.JxlEncoderInitBasicInfo(&info);
    info.xsize = fmt.width;
    info.ysize = fmt.height;
    info.bits_per_sample = fmt.bits_per_sample;
    info.exponent_bits_per_sample = 0;

    const is_gray = fmt.num_channels == 1 or fmt.num_channels == 2;
    info.num_color_channels = if (is_gray) 1 else 3;

    const has_alpha = fmt.num_channels == 2 or fmt.num_channels == 4;
    if (has_alpha) {
        info.alpha_bits = fmt.bits_per_sample;
        info.alpha_exponent_bits = 0;
        info.num_extra_channels = 1;
    } else {
        info.alpha_bits = 0;
        info.alpha_exponent_bits = 0;
        info.num_extra_channels = 0;
    }

    // Use lossless: disable XYB transform
    info.uses_original_profile = @intFromBool(true);

    if (c.JxlEncoderSetBasicInfo(enc, &info) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncoderConfigFailed;

    // Set color encoding to sRGB
    var color: c.JxlColorEncoding = undefined;
    c.JxlColorEncodingSetToSRGB(&color, @intFromBool(is_gray));
    if (c.JxlEncoderSetColorEncoding(enc, &color) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncoderConfigFailed;

    // Set pixel format
    const pixel_format = c.JxlPixelFormat{
        .num_channels = fmt.num_channels,
        .data_type = if (fmt.bits_per_sample == 8) c.JXL_TYPE_UINT8 else c.JXL_TYPE_UINT16,
        .endianness = c.JXL_NATIVE_ENDIAN,
        .@"align" = 0,
    };

    if (c.JxlEncoderAddImageFrame(frame_settings, &pixel_format, pixels.ptr, pixels.len) != c.JXL_ENC_SUCCESS)
        return JxlError.JxlEncodeFailed;

    c.JxlEncoderCloseInput(enc);

    // Drain output
    var buf_size: usize = @max(pixels.len / 2, 4096);
    var output = try allocator.alloc(u8, buf_size);
    errdefer allocator.free(output);
    var written: usize = 0;

    while (true) {
        var next_out: [*c]u8 = output.ptr + written;
        var avail_out: usize = buf_size - written;

        const status = c.JxlEncoderProcessOutput(enc, &next_out, &avail_out);
        written = buf_size - avail_out;

        switch (status) {
            c.JXL_ENC_SUCCESS => break,
            c.JXL_ENC_NEED_MORE_OUTPUT => {
                buf_size *|= 2;
                output = try allocator.realloc(output, buf_size);
            },
            else => return JxlError.JxlEncodeFailed,
        }
    }

    // Shrink to actual size
    if (written < output.len) {
        if (allocator.realloc(output, written)) |shrunk| {
            return shrunk;
        } else |_| {
            return output[0..written];
        }
    }
    return output;
}

/// Decode JXL pixel data back to raw pixels.
/// Returns raw pixel buffer. out_fmt is populated with the image dimensions/format.
/// Caller owns the returned slice.
pub fn jxlToPixels(allocator: Allocator, jxl_bytes: []const u8, out_fmt: *PixelFormat) (JxlError || Allocator.Error)![]u8 {
    if (jxl_bytes.len == 0) return JxlError.EmptyInput;

    const dec = c.JxlDecoderCreate(null) orelse return JxlError.JxlDecoderCreateFailed;
    defer c.JxlDecoderDestroy(dec);

    if (c.JxlDecoderSubscribeEvents(dec, c.JXL_DEC_BASIC_INFO | c.JXL_DEC_FULL_IMAGE) != c.JXL_DEC_SUCCESS)
        return JxlError.JxlDecoderConfigFailed;

    if (c.JxlDecoderSetInput(dec, jxl_bytes.ptr, jxl_bytes.len) != c.JXL_DEC_SUCCESS)
        return JxlError.JxlDecoderConfigFailed;
    c.JxlDecoderCloseInput(dec);

    var pixel_buf: ?[]u8 = null;
    errdefer if (pixel_buf) |buf| allocator.free(buf);
    var basic_info: c.JxlBasicInfo = undefined;
    var info_set = false;

    while (true) {
        const status = c.JxlDecoderProcessInput(dec);

        switch (status) {
            c.JXL_DEC_BASIC_INFO => {
                if (c.JxlDecoderGetBasicInfo(dec, &basic_info) != c.JXL_DEC_SUCCESS)
                    return JxlError.JxlDecodeFailed;

                const has_alpha = basic_info.alpha_bits > 0;
                const is_gray = basic_info.num_color_channels == 1;
                const num_channels: u32 = if (is_gray)
                    (if (has_alpha) @as(u32, 2) else @as(u32, 1))
                else
                    (if (has_alpha) @as(u32, 4) else @as(u32, 3));
                const bps: u32 = if (basic_info.bits_per_sample > 8) 16 else 8;

                out_fmt.* = .{
                    .width = basic_info.xsize,
                    .height = basic_info.ysize,
                    .num_channels = num_channels,
                    .bits_per_sample = bps,
                };
                info_set = true;
            },
            c.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
                if (!info_set) return JxlError.JxlDecodeFailed;

                const bps = out_fmt.bits_per_sample;
                const bytes_per_pixel = out_fmt.num_channels * (bps / 8);
                const total = @as(usize, out_fmt.width) * @as(usize, out_fmt.height) * bytes_per_pixel;

                pixel_buf = try allocator.alloc(u8, total);

                const pixel_format = c.JxlPixelFormat{
                    .num_channels = out_fmt.num_channels,
                    .data_type = if (bps == 8) c.JXL_TYPE_UINT8 else c.JXL_TYPE_UINT16,
                    .endianness = c.JXL_NATIVE_ENDIAN,
                    .@"align" = 0,
                };

                if (c.JxlDecoderSetImageOutBuffer(dec, &pixel_format, pixel_buf.?.ptr, total) != c.JXL_DEC_SUCCESS)
                    return JxlError.JxlDecodeFailed;
            },
            c.JXL_DEC_FULL_IMAGE => break,
            c.JXL_DEC_SUCCESS => break,
            else => return JxlError.JxlDecodeFailed,
        }
    }

    if (pixel_buf) |buf| {
        return buf;
    }
    return JxlError.JxlDecodeFailed;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Minimal 8x8 red JPEG (286 bytes) — generated by ImageMagick
const test_jpeg = [_]u8{
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01,
    0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xdb, 0x00, 0x43,
    0x00, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x02, 0x02, 0x02, 0x03,
    0x03, 0x03, 0x03, 0x04, 0x06, 0x04, 0x04, 0x04, 0x04, 0x04, 0x08, 0x06,
    0x06, 0x05, 0x06, 0x09, 0x08, 0x0a, 0x0a, 0x09, 0x08, 0x09, 0x09, 0x0a,
    0x0c, 0x0f, 0x0c, 0x0a, 0x0b, 0x0e, 0x0b, 0x09, 0x09, 0x0d, 0x11, 0x0d,
    0x0e, 0x0f, 0x10, 0x10, 0x11, 0x10, 0x0a, 0x0c, 0x12, 0x13, 0x12, 0x10,
    0x13, 0x0f, 0x10, 0x10, 0x10, 0xff, 0xdb, 0x00, 0x43, 0x01, 0x03, 0x03,
    0x03, 0x04, 0x03, 0x04, 0x08, 0x04, 0x04, 0x08, 0x10, 0x0b, 0x09, 0x0b,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10,
    0x10, 0x10, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x08, 0x00, 0x08, 0x03,
    0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xc4, 0x00,
    0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0xff, 0xc4, 0x00, 0x14, 0x10,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xc4, 0x00, 0x15, 0x01, 0x01, 0x01,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x07, 0x09, 0xff, 0xc4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xff, 0xda, 0x00, 0x0c, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03,
    0x11, 0x00, 0x3f, 0x00, 0x3a, 0x03, 0x15, 0x4d, 0xff, 0xd9,
};

test "isJpegData detects JPEG SOI marker" {
    try testing.expect(isJpegData(&test_jpeg));
    try testing.expect(isJpegData(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE1 }));
}

test "isJpegData rejects non-JPEG" {
    try testing.expect(!isJpegData(&[_]u8{ 0x89, 0x50, 0x4E, 0x47 })); // PNG
    try testing.expect(!isJpegData(&[_]u8{ 0x50, 0x4B, 0x03, 0x04 })); // ZIP
    try testing.expect(!isJpegData(&[_]u8{0xFF})); // too short
    try testing.expect(!isJpegData(&[_]u8{})); // empty
}

test "jpegToJxl rejects empty input" {
    const result = jpegToJxl(testing.allocator, &[_]u8{});
    try testing.expectError(JxlError.EmptyInput, result);
}

test "jpegToJxl rejects non-JPEG input" {
    const result = jpegToJxl(testing.allocator, &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
    try testing.expectError(JxlError.InvalidJpeg, result);
}

test "jxlToJpeg rejects empty input" {
    const result = jxlToJpeg(testing.allocator, &[_]u8{});
    try testing.expectError(JxlError.EmptyInput, result);
}

test "JPEG → JXL → JPEG roundtrip is bit-exact" {
    // Encode JPEG → JXL
    const jxl_data = try jpegToJxl(testing.allocator, &test_jpeg);
    defer testing.allocator.free(jxl_data);

    // JXL output should be non-empty
    try testing.expect(jxl_data.len > 0);

    // Decode JXL → JPEG
    const recovered_jpeg = try jxlToJpeg(testing.allocator, jxl_data);
    defer testing.allocator.free(recovered_jpeg);

    // Must be bit-exact match
    try testing.expectEqualSlices(u8, &test_jpeg, recovered_jpeg);
}

test "JXL output is smaller than JPEG input (or at least produced)" {
    const jxl_data = try jpegToJxl(testing.allocator, &test_jpeg);
    defer testing.allocator.free(jxl_data);

    // For tiny images JXL might not be smaller, but it should be non-empty
    try testing.expect(jxl_data.len > 0);
    // For typical JPEGs, JXL should be smaller. Our test JPEG is tiny,
    // so just verify it produced valid output.
}

test "jxlToJpeg rejects invalid JXL data" {
    const result = jxlToJpeg(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectError(JxlError.JxlDecodeFailed, result);
}

// =============================================================================
// Pixel-level JXL tests
// =============================================================================

test "pixelsToJxl rejects empty input" {
    const result = pixelsToJxl(testing.allocator, &[_]u8{}, .{
        .width = 1,
        .height = 1,
        .num_channels = 4,
        .bits_per_sample = 8,
    });
    try testing.expectError(JxlError.EmptyInput, result);
}

test "pixelsToJxl rejects zero dimensions" {
    const result = pixelsToJxl(testing.allocator, &[_]u8{ 255, 0, 0, 255 }, .{
        .width = 0,
        .height = 1,
        .num_channels = 4,
        .bits_per_sample = 8,
    });
    try testing.expectError(JxlError.InvalidPixelData, result);
}

test "pixelsToJxl rejects mismatched pixel data length" {
    const result = pixelsToJxl(testing.allocator, &[_]u8{ 255, 0, 0 }, .{
        .width = 1,
        .height = 1,
        .num_channels = 4,
        .bits_per_sample = 8,
    });
    try testing.expectError(JxlError.InvalidPixelData, result);
}

test "2x2 RGBA8 pixel roundtrip is pixel-identical" {
    // 2x2 RGBA8: red, green, blue, white
    const pixels = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        255, 255, 255, 255, // white
    };
    const fmt = PixelFormat{ .width = 2, .height = 2, .num_channels = 4, .bits_per_sample = 8 };

    const jxl_data = try pixelsToJxl(testing.allocator, &pixels, fmt);
    defer testing.allocator.free(jxl_data);
    try testing.expect(jxl_data.len > 0);

    var out_fmt: PixelFormat = undefined;
    const recovered = try jxlToPixels(testing.allocator, jxl_data, &out_fmt);
    defer testing.allocator.free(recovered);

    try testing.expectEqual(fmt.width, out_fmt.width);
    try testing.expectEqual(fmt.height, out_fmt.height);
    try testing.expectEqual(fmt.num_channels, out_fmt.num_channels);
    try testing.expectEqual(fmt.bits_per_sample, out_fmt.bits_per_sample);
    try testing.expectEqualSlices(u8, &pixels, recovered);
}

test "8-bit grayscale pixel roundtrip" {
    // 2x2 grayscale
    const pixels = [_]u8{ 0, 128, 255, 64 };
    const fmt = PixelFormat{ .width = 2, .height = 2, .num_channels = 1, .bits_per_sample = 8 };

    const jxl_data = try pixelsToJxl(testing.allocator, &pixels, fmt);
    defer testing.allocator.free(jxl_data);

    var out_fmt: PixelFormat = undefined;
    const recovered = try jxlToPixels(testing.allocator, jxl_data, &out_fmt);
    defer testing.allocator.free(recovered);

    try testing.expectEqual(fmt.width, out_fmt.width);
    try testing.expectEqual(fmt.height, out_fmt.height);
    try testing.expectEqual(@as(u32, 1), out_fmt.num_channels);
    try testing.expectEqualSlices(u8, &pixels, recovered);
}

test "16-bit grayscale pixel roundtrip" {
    // 2x2 16-bit grayscale (native endian)
    var pixels: [8]u8 = undefined;
    std.mem.writeInt(u16, pixels[0..2], 0, .little);
    std.mem.writeInt(u16, pixels[2..4], 32768, .little);
    std.mem.writeInt(u16, pixels[4..6], 65535, .little);
    std.mem.writeInt(u16, pixels[6..8], 16384, .little);
    const fmt = PixelFormat{ .width = 2, .height = 2, .num_channels = 1, .bits_per_sample = 16 };

    const jxl_data = try pixelsToJxl(testing.allocator, &pixels, fmt);
    defer testing.allocator.free(jxl_data);

    var out_fmt: PixelFormat = undefined;
    const recovered = try jxlToPixels(testing.allocator, jxl_data, &out_fmt);
    defer testing.allocator.free(recovered);

    try testing.expectEqual(fmt.width, out_fmt.width);
    try testing.expectEqual(fmt.height, out_fmt.height);
    try testing.expectEqual(@as(u32, 16), out_fmt.bits_per_sample);
    try testing.expectEqualSlices(u8, &pixels, recovered);
}

test "jxlToPixels rejects invalid JXL data" {
    var out_fmt: PixelFormat = undefined;
    const result = jxlToPixels(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, &out_fmt);
    try testing.expectError(JxlError.JxlDecodeFailed, result);
}

test "JXL pixel output is smaller than raw pixels" {
    // 8x8 solid red RGBA — highly compressible
    var pixels: [8 * 8 * 4]u8 = undefined;
    for (0..64) |i| {
        pixels[i * 4 + 0] = 255; // R
        pixels[i * 4 + 1] = 0; // G
        pixels[i * 4 + 2] = 0; // B
        pixels[i * 4 + 3] = 255; // A
    }
    const fmt = PixelFormat{ .width = 8, .height = 8, .num_channels = 4, .bits_per_sample = 8 };

    const jxl_data = try pixelsToJxl(testing.allocator, &pixels, fmt);
    defer testing.allocator.free(jxl_data);

    try testing.expect(jxl_data.len < pixels.len);
}

test "RGB8 pixel roundtrip (no alpha)" {
    // 2x2 RGB8
    const pixels = [_]u8{
        255, 0,   0, // red
        0,   255, 0, // green
        0,   0,   255, // blue
        128, 128, 128, // gray
    };
    const fmt = PixelFormat{ .width = 2, .height = 2, .num_channels = 3, .bits_per_sample = 8 };

    const jxl_data = try pixelsToJxl(testing.allocator, &pixels, fmt);
    defer testing.allocator.free(jxl_data);

    var out_fmt: PixelFormat = undefined;
    const recovered = try jxlToPixels(testing.allocator, jxl_data, &out_fmt);
    defer testing.allocator.free(recovered);

    try testing.expectEqual(fmt.num_channels, out_fmt.num_channels);
    try testing.expectEqualSlices(u8, &pixels, recovered);
}
