const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TgaError = error{
    InvalidTga,
    UnsupportedTga,
    CorruptedData,
};

pub const TgaHeader = struct {
    /// Full original header bytes (18 + id_length + color_map bytes).
    header_bytes: []u8,
    width: u16,
    height: u16,
    channels: u8, // 3 (24-bit) or 4 (32-bit)
    bits_per_pixel: u8,
    /// True if origin is top-left (bit 5 of image descriptor).
    top_down: bool,
    allocator: Allocator,

    pub fn deinit(self: *TgaHeader) void {
        self.allocator.free(self.header_bytes);
    }
};

pub const ParsedTga = struct {
    header: TgaHeader,
    /// Raw pixels in top-to-bottom, left-to-right, RGB(A) order.
    pixels: []u8,
    /// Footer bytes (TGA 2.0 footer, if present).
    footer: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedTga) void {
        self.header.deinit();
        self.allocator.free(self.pixels);
        if (self.footer.len > 0) self.allocator.free(self.footer);
    }
};

/// Check if buffer looks like a TGA file.
/// TGA has no magic number, so we check for valid header field values.
pub fn isTgaMagic(buf: []const u8) bool {
    if (buf.len < 18) return false;
    const image_type = buf[2];
    // Valid uncompressed types: 0 (no image), 1 (color-mapped), 2 (true-color), 3 (grayscale)
    // RLE types: 9, 10, 11
    // We only handle type 2 (uncompressed true-color)
    if (image_type != 2) return false;
    const bpp = buf[16];
    if (bpp != 24 and bpp != 32) return false;
    const width = @as(u16, buf[12]) | (@as(u16, buf[13]) << 8);
    const height = @as(u16, buf[14]) | (@as(u16, buf[15]) << 8);
    if (width == 0 or height == 0) return false;
    // Color map type must be 0 for true-color
    if (buf[1] != 0) return false;
    return true;
}

/// Parse a TGA file into header + raw pixels.
/// Only supports uncompressed true-color (type 2), 24-bit and 32-bit.
pub fn parseTga(allocator: Allocator, data: []const u8) (TgaError || Allocator.Error)!ParsedTga {
    if (data.len < 18) return TgaError.InvalidTga;

    const id_length: usize = data[0];
    const color_map_type = data[1];
    const image_type = data[2];

    // Only handle uncompressed true-color (type 2)
    if (image_type != 2) return TgaError.UnsupportedTga;
    if (color_map_type != 0) return TgaError.UnsupportedTga;

    const width = @as(u16, data[12]) | (@as(u16, data[13]) << 8);
    const height = @as(u16, data[14]) | (@as(u16, data[15]) << 8);
    const bpp = data[16];
    const descriptor = data[17];

    if (width == 0 or height == 0) return TgaError.InvalidTga;
    if (bpp != 24 and bpp != 32) return TgaError.UnsupportedTga;

    const channels: u8 = if (bpp == 32) 4 else 3;
    const top_down = (descriptor & 0x20) != 0;

    // Color map: for type 2, color_map_type should be 0, but check just in case
    const cm_first = @as(u16, data[3]) | (@as(u16, data[4]) << 8);
    _ = cm_first;
    const cm_length = @as(u16, data[5]) | (@as(u16, data[6]) << 8);
    const cm_entry_size = data[7];
    const cm_bytes: usize = if (color_map_type != 0)
        @as(usize, cm_length) * ((@as(usize, cm_entry_size) + 7) / 8)
    else
        0;

    // Header = 18 bytes + image ID + color map
    const header_size = 18 + id_length + cm_bytes;
    if (header_size > data.len) return TgaError.CorruptedData;

    // Pixel data
    const pixel_data_offset = header_size;
    const bytes_per_pixel: usize = @as(usize, channels);
    const pixel_data_len = @as(usize, width) * @as(usize, height) * bytes_per_pixel;

    if (pixel_data_offset + pixel_data_len > data.len) return TgaError.CorruptedData;

    // Copy header
    const header_bytes = try allocator.alloc(u8, header_size);
    @memcpy(header_bytes, data[0..header_size]);

    // Extract pixels: convert BGR(A) to RGB(A), handle row order
    const out_pixels_len = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_pixels_len);

    const pixel_data = data[pixel_data_offset..];

    for (0..height) |y| {
        const src_row = if (top_down) y else @as(usize, height) - 1 - y;
        const src_offset = src_row * @as(usize, width) * bytes_per_pixel;
        const dst_offset = y * @as(usize, width) * @as(usize, channels);

        for (0..width) |x| {
            const src_px = src_offset + x * bytes_per_pixel;
            const dst_px = dst_offset + x * @as(usize, channels);
            // TGA stores BGR(A), convert to RGB(A)
            pixels[dst_px + 0] = pixel_data[src_px + 2]; // R
            pixels[dst_px + 1] = pixel_data[src_px + 1]; // G
            pixels[dst_px + 2] = pixel_data[src_px + 0]; // B
            if (channels == 4) {
                pixels[dst_px + 3] = pixel_data[src_px + 3]; // A
            }
        }
    }

    // Check for TGA 2.0 footer (last 26 bytes ending with "TRUEVISION-XFILE.\0")
    const footer_sig = "TRUEVISION-XFILE.\x00";
    var footer: []u8 = &.{};
    if (data.len >= pixel_data_offset + pixel_data_len + 26) {
        const tail = data[data.len - 18 ..];
        if (std.mem.eql(u8, tail, footer_sig)) {
            const footer_start = pixel_data_offset + pixel_data_len;
            const footer_len = data.len - footer_start;
            footer = try allocator.alloc(u8, footer_len);
            @memcpy(footer, data[footer_start..]);
        }
    }

    return ParsedTga{
        .header = TgaHeader{
            .header_bytes = header_bytes,
            .width = width,
            .height = height,
            .channels = channels,
            .bits_per_pixel = bpp,
            .top_down = top_down,
            .allocator = allocator,
        },
        .pixels = pixels,
        .footer = footer,
        .allocator = allocator,
    };
}

/// Encode raw RGB(A) pixels + header back to a TGA file.
pub fn encodeTga(allocator: Allocator, pixels: []const u8, header: TgaHeader, footer: []const u8) (TgaError || Allocator.Error)![]u8 {
    const width: usize = header.width;
    const height: usize = header.height;
    const channels: usize = @as(usize, header.channels);
    const bytes_per_pixel = channels;

    const expected = width * height * channels;
    if (pixels.len != expected) return TgaError.CorruptedData;

    const pixel_data_len = width * height * bytes_per_pixel;
    const total = header.header_bytes.len + pixel_data_len + footer.len;
    const output = try allocator.alloc(u8, total);

    // Copy header
    @memcpy(output[0..header.header_bytes.len], header.header_bytes);

    // Write pixels: RGB(A) → BGR(A), handle row order
    const pixel_out = output[header.header_bytes.len..];

    for (0..height) |y| {
        const dst_row = if (header.top_down) y else height - 1 - y;
        const src_offset = y * width * channels;
        const dst_offset = dst_row * width * bytes_per_pixel;

        for (0..width) |x| {
            const src_px = src_offset + x * channels;
            const dst_px = dst_offset + x * bytes_per_pixel;
            pixel_out[dst_px + 0] = pixels[src_px + 2]; // B
            pixel_out[dst_px + 1] = pixels[src_px + 1]; // G
            pixel_out[dst_px + 2] = pixels[src_px + 0]; // R
            if (channels == 4) {
                pixel_out[dst_px + 3] = pixels[src_px + 3]; // A
            }
        }
    }

    // Copy footer
    if (footer.len > 0) {
        @memcpy(output[header.header_bytes.len + pixel_data_len ..], footer);
    }

    return output;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestTga24(allocator: Allocator, width: u16, height: u16, top_down: bool) ![]u8 {
    const bpp: u8 = 24;
    const pixel_data_len = @as(usize, width) * @as(usize, height) * 3;
    const total = 18 + pixel_data_len;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0);

    // TGA header (18 bytes)
    buf[0] = 0; // id_length
    buf[1] = 0; // color_map_type
    buf[2] = 2; // image_type (uncompressed true-color)
    // bytes 3..11: color map spec (all zeros)
    buf[12] = @truncate(width);
    buf[13] = @truncate(width >> 8);
    buf[14] = @truncate(height);
    buf[15] = @truncate(height >> 8);
    buf[16] = bpp;
    buf[17] = if (top_down) 0x20 else 0x00;

    // Pixel data (BGR)
    const pixels = buf[18..];
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = (y * @as(usize, width) + x) * 3;
            pixels[offset + 0] = @truncate(x); // B
            pixels[offset + 1] = @truncate(y); // G
            pixels[offset + 2] = @truncate(x + y); // R
        }
    }

    return buf;
}

test "TGA magic detection" {
    const tga = try makeTestTga24(testing.allocator, 4, 4, false);
    defer testing.allocator.free(tga);
    try testing.expect(isTgaMagic(tga));
}

test "TGA magic rejects non-TGA" {
    try testing.expect(!isTgaMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    // RLE type
    var rle: [18]u8 = undefined;
    @memset(&rle, 0);
    rle[2] = 10; // RLE true-color
    rle[16] = 24;
    rle[12] = 1;
    rle[14] = 1;
    try testing.expect(!isTgaMagic(&rle));
}

test "TGA parse 24-bit bottom-up roundtrip" {
    const tga_data = try makeTestTga24(testing.allocator, 8, 6, false);
    defer testing.allocator.free(tga_data);

    var parsed = try parseTga(testing.allocator, tga_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u16, 8), parsed.header.width);
    try testing.expectEqual(@as(u16, 6), parsed.header.height);
    try testing.expectEqual(@as(u8, 3), parsed.header.channels);
    try testing.expect(!parsed.header.top_down);

    const re_encoded = try encodeTga(testing.allocator, parsed.pixels, parsed.header, parsed.footer);
    defer testing.allocator.free(re_encoded);

    try testing.expectEqualSlices(u8, tga_data, re_encoded);
}

test "TGA parse 24-bit top-down roundtrip" {
    const tga_data = try makeTestTga24(testing.allocator, 5, 4, true);
    defer testing.allocator.free(tga_data);

    var parsed = try parseTga(testing.allocator, tga_data);
    defer parsed.deinit();

    try testing.expect(parsed.header.top_down);

    const re_encoded = try encodeTga(testing.allocator, parsed.pixels, parsed.header, parsed.footer);
    defer testing.allocator.free(re_encoded);

    try testing.expectEqualSlices(u8, tga_data, re_encoded);
}

test "TGA pixel order: BGR to RGB" {
    const tga_data = try makeTestTga24(testing.allocator, 1, 1, true);
    defer testing.allocator.free(tga_data);

    tga_data[18] = 0x11; // B
    tga_data[19] = 0x22; // G
    tga_data[20] = 0x33; // R

    var parsed = try parseTga(testing.allocator, tga_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u8, 0x33), parsed.pixels[0]); // R
    try testing.expectEqual(@as(u8, 0x22), parsed.pixels[1]); // G
    try testing.expectEqual(@as(u8, 0x11), parsed.pixels[2]); // B
}

test "TGA rejects RLE-compressed" {
    var buf: [18]u8 = undefined;
    @memset(&buf, 0);
    buf[2] = 10; // RLE true-color
    buf[16] = 24;
    buf[12] = 1;
    buf[14] = 1;
    try testing.expectError(TgaError.UnsupportedTga, parseTga(testing.allocator, &buf));
}
