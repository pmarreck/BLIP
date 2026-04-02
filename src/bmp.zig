const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BmpError = error{
    InvalidBmp,
    UnsupportedBmp,
    CorruptedData,
};

/// BMP file header (14 bytes) + DIB header info needed for reconstruction.
pub const BmpHeader = struct {
    /// Full original header bytes (file header + DIB header + optional color table + gap).
    /// Everything from byte 0 up to the pixel data offset.
    header_bytes: []u8,
    width: u32,
    height: u32,
    /// Absolute height (BMP can have negative height for top-down).
    abs_height: u32,
    top_down: bool,
    channels: u8, // 3 (24-bit) or 4 (32-bit)
    bits_per_pixel: u16,
    /// Bytes per row in the BMP file (padded to 4-byte boundary).
    row_stride: u32,
    allocator: Allocator,

    pub fn deinit(self: *BmpHeader) void {
        self.allocator.free(self.header_bytes);
    }
};

pub const ParsedBmp = struct {
    header: BmpHeader,
    /// Raw pixels in top-to-bottom, left-to-right order, RGB(A) channel order.
    /// No padding. Width * height * channels bytes.
    pixels: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedBmp) void {
        self.header.deinit();
        self.allocator.free(self.pixels);
    }
};

const BMP_MAGIC = [_]u8{ 'B', 'M' };

/// Check if buffer starts with BMP magic bytes.
pub fn isBmpMagic(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 'B' and buf[1] == 'M';
}

/// Read a little-endian u16 from a byte slice.
fn readU16LE(buf: []const u8) u16 {
    return std.mem.readInt(u16, buf[0..2], .little);
}

/// Read a little-endian u32 from a byte slice.
fn readU32LE(buf: []const u8) u32 {
    return std.mem.readInt(u32, buf[0..4], .little);
}

/// Read a little-endian i32 from a byte slice.
fn readI32LE(buf: []const u8) i32 {
    return @bitCast(std.mem.readInt(u32, buf[0..4], .little));
}
/// Parse a BMP file into header metadata + raw pixels.
/// Only supports uncompressed 24-bit and 32-bit BMPs (BI_RGB, compression=0).
pub fn parseBmp(allocator: Allocator, data: []const u8) (BmpError || Allocator.Error)!ParsedBmp {
    // BMP file header: 14 bytes minimum
    if (data.len < 54) return BmpError.InvalidBmp;
    if (!isBmpMagic(data)) return BmpError.InvalidBmp;

    // File header fields
    const pixel_offset = readU32LE(data[10..14]);
    if (pixel_offset >= data.len) return BmpError.CorruptedData;

    // DIB header size (at offset 14)
    const dib_size = readU32LE(data[14..18]);
    if (dib_size < 40) return BmpError.UnsupportedBmp; // Need at least BITMAPINFOHEADER

    // BITMAPINFOHEADER fields
    const width_i32 = readI32LE(data[18..22]);
    const height_i32 = readI32LE(data[22..26]);
    const bits_per_pixel = readU16LE(data[28..30]);
    const compression = readU32LE(data[30..34]);

    // We only handle uncompressed (BI_RGB = 0) and BITFIELDS (3) for 32-bit
    if (compression != 0 and compression != 3) return BmpError.UnsupportedBmp;

    // We only handle 24-bit and 32-bit
    if (bits_per_pixel != 24 and bits_per_pixel != 32) return BmpError.UnsupportedBmp;

    if (width_i32 <= 0) return BmpError.InvalidBmp;
    const width: u32 = @intCast(width_i32);
    const top_down = height_i32 < 0;
    const abs_height: u32 = if (top_down) @intCast(-height_i32) else @intCast(height_i32);

    if (width == 0 or abs_height == 0) return BmpError.InvalidBmp;

    const channels: u8 = if (bits_per_pixel == 32) 4 else 3;
    const bytes_per_pixel: u32 = @as(u32, channels);
    // BMP rows are padded to 4-byte boundaries
    const row_stride = (width * bytes_per_pixel + 3) & ~@as(u32, 3);

    const pixel_data_len = @as(usize, row_stride) * @as(usize, abs_height);
    if (pixel_offset + pixel_data_len > data.len) return BmpError.CorruptedData;

    // Copy header bytes (everything before pixel data)
    const header_bytes = try allocator.alloc(u8, pixel_offset);
    @memcpy(header_bytes, data[0..pixel_offset]);

    // Extract pixels: convert from BMP order (bottom-up, BGR) to top-down RGB
    const out_pixels_len = @as(usize, width) * @as(usize, abs_height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_pixels_len);

    const pixel_data = data[pixel_offset..];

    for (0..abs_height) |y| {
        // BMP is bottom-up by default (unless top_down)
        const src_row = if (top_down) y else abs_height - 1 - y;
        const src_offset = src_row * @as(usize, row_stride);
        const dst_offset = y * @as(usize, width) * @as(usize, channels);

        for (0..width) |x| {
            const src_px = src_offset + x * bytes_per_pixel;
            const dst_px = dst_offset + x * @as(usize, channels);
            // BMP stores BGR(A), convert to RGB(A)
            pixels[dst_px + 0] = pixel_data[src_px + 2]; // R
            pixels[dst_px + 1] = pixel_data[src_px + 1]; // G
            pixels[dst_px + 2] = pixel_data[src_px + 0]; // B
            if (channels == 4) {
                pixels[dst_px + 3] = pixel_data[src_px + 3]; // A
            }
        }
    }

    return ParsedBmp{
        .header = BmpHeader{
            .header_bytes = header_bytes,
            .width = width,
            .height = @intCast(abs_height),
            .abs_height = abs_height,
            .top_down = top_down,
            .channels = channels,
            .bits_per_pixel = bits_per_pixel,
            .row_stride = row_stride,
            .allocator = allocator,
        },
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Encode raw RGB(A) pixels + header back to a BMP file.
/// Pixels must be in top-to-bottom, left-to-right, RGB(A) order.
pub fn encodeBmp(allocator: Allocator, pixels: []const u8, header: BmpHeader) (BmpError || Allocator.Error)![]u8 {
    const width = header.width;
    const abs_height = header.abs_height;
    const channels: u32 = @as(u32, header.channels);
    const bytes_per_pixel = channels;
    const row_stride = header.row_stride;

    const expected_pixels = @as(usize, width) * @as(usize, abs_height) * @as(usize, channels);
    if (pixels.len != expected_pixels) return BmpError.CorruptedData;

    const pixel_data_len = @as(usize, row_stride) * @as(usize, abs_height);
    const total_len = header.header_bytes.len + pixel_data_len;

    const output = try allocator.alloc(u8, total_len);

    // Copy header
    @memcpy(output[0..header.header_bytes.len], header.header_bytes);

    // Update file size in header (bytes 2..6)
    const file_size: u32 = @intCast(total_len);
    output[2] = @truncate(file_size);
    output[3] = @truncate(file_size >> 8);
    output[4] = @truncate(file_size >> 16);
    output[5] = @truncate(file_size >> 24);

    // Write pixel data: convert from RGB(A) top-down to BGR(A) with row padding
    const pixel_out = output[header.header_bytes.len..];
    // Zero the pixel area first (handles row padding bytes)
    @memset(pixel_out, 0);

    for (0..abs_height) |y| {
        const src_row = if (header.top_down) y else abs_height - 1 - y;
        const src_offset = y * @as(usize, width) * @as(usize, channels);
        const dst_offset = src_row * @as(usize, row_stride);

        for (0..width) |x| {
            const src_px = src_offset + x * @as(usize, channels);
            const dst_px = dst_offset + x * @as(usize, bytes_per_pixel);
            // RGB(A) to BGR(A)
            pixel_out[dst_px + 0] = pixels[src_px + 2]; // B
            pixel_out[dst_px + 1] = pixels[src_px + 1]; // G
            pixel_out[dst_px + 2] = pixels[src_px + 0]; // R
            if (channels == 4) {
                pixel_out[dst_px + 3] = pixels[src_px + 3]; // A
            }
        }
    }

    return output;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid 24-bit BMP in memory for testing.
fn makeTestBmp24(allocator: Allocator, width: u32, height: u32, top_down: bool) ![]u8 {
    const channels: u32 = 3;
    const row_stride = (width * channels + 3) & ~@as(u32, 3);
    const pixel_data_len = row_stride * height;
    const header_size: u32 = 54; // 14 + 40
    const file_size = header_size + pixel_data_len;

    const buf = try allocator.alloc(u8, file_size);
    @memset(buf, 0);

    // File header
    buf[0] = 'B';
    buf[1] = 'M';
    // File size
    buf[2] = @truncate(file_size);
    buf[3] = @truncate(file_size >> 8);
    buf[4] = @truncate(file_size >> 16);
    buf[5] = @truncate(file_size >> 24);
    // Pixel data offset
    buf[10] = @truncate(header_size);
    buf[11] = @truncate(header_size >> 8);
    buf[12] = @truncate(header_size >> 16);
    buf[13] = @truncate(header_size >> 24);

    // DIB header (BITMAPINFOHEADER = 40 bytes)
    buf[14] = 40; // DIB header size
    // Width
    buf[18] = @truncate(width);
    buf[19] = @truncate(width >> 8);
    buf[20] = @truncate(width >> 16);
    buf[21] = @truncate(width >> 24);
    // Height (signed)
    const height_i32: i32 = if (top_down) -@as(i32, @intCast(height)) else @as(i32, @intCast(height));
    const height_u32: u32 = @bitCast(height_i32);
    buf[22] = @truncate(height_u32);
    buf[23] = @truncate(height_u32 >> 8);
    buf[24] = @truncate(height_u32 >> 16);
    buf[25] = @truncate(height_u32 >> 24);
    // Planes
    buf[26] = 1;
    // Bits per pixel
    buf[28] = 24;
    // Compression = 0 (BI_RGB)
    // Image size (can be 0 for BI_RGB)

    // Fill pixel data with a pattern: row-major BGR
    const pixels = buf[header_size..];
    for (0..height) |y| {
        for (0..width) |x| {
            const offset = y * @as(usize, row_stride) + x * 3;
            pixels[offset + 0] = @truncate(x); // B
            pixels[offset + 1] = @truncate(y); // G
            pixels[offset + 2] = @truncate(x + y); // R
        }
    }

    return buf;
}

test "BMP magic detection" {
    try testing.expect(isBmpMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    try testing.expect(!isBmpMagic(&[_]u8{ 'P', 'N', 'G', 0 }));
    try testing.expect(!isBmpMagic(&[_]u8{'B'}));
    try testing.expect(!isBmpMagic(&[_]u8{}));
}

test "BMP parse rejects too-small data" {
    const result = parseBmp(testing.allocator, &[_]u8{ 'B', 'M', 0, 0 });
    try testing.expectError(BmpError.InvalidBmp, result);
}

test "BMP parse rejects wrong magic" {
    var buf: [54]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 'P';
    buf[1] = 'K';
    const result = parseBmp(testing.allocator, &buf);
    try testing.expectError(BmpError.InvalidBmp, result);
}

test "BMP parse 24-bit bottom-up roundtrip" {
    const bmp_data = try makeTestBmp24(testing.allocator, 4, 3, false);
    defer testing.allocator.free(bmp_data);

    var parsed = try parseBmp(testing.allocator, bmp_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 4), parsed.header.width);
    try testing.expectEqual(@as(u32, 3), parsed.header.abs_height);
    try testing.expectEqual(@as(u8, 3), parsed.header.channels);
    try testing.expect(!parsed.header.top_down);

    // Encode back
    const re_encoded = try encodeBmp(testing.allocator, parsed.pixels, parsed.header);
    defer testing.allocator.free(re_encoded);

    // Must be byte-identical
    try testing.expectEqualSlices(u8, bmp_data, re_encoded);
}

test "BMP parse 24-bit top-down roundtrip" {
    const bmp_data = try makeTestBmp24(testing.allocator, 5, 4, true);
    defer testing.allocator.free(bmp_data);

    var parsed = try parseBmp(testing.allocator, bmp_data);
    defer parsed.deinit();

    try testing.expect(parsed.header.top_down);
    try testing.expectEqual(@as(u32, 5), parsed.header.width);
    try testing.expectEqual(@as(u32, 4), parsed.header.abs_height);

    const re_encoded = try encodeBmp(testing.allocator, parsed.pixels, parsed.header);
    defer testing.allocator.free(re_encoded);

    try testing.expectEqualSlices(u8, bmp_data, re_encoded);
}

test "BMP parse 24-bit odd width (row padding)" {
    // Width=3 → 9 bytes/row → padded to 12 bytes
    const bmp_data = try makeTestBmp24(testing.allocator, 3, 2, false);
    defer testing.allocator.free(bmp_data);

    var parsed = try parseBmp(testing.allocator, bmp_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 12), parsed.header.row_stride);
    try testing.expectEqual(@as(usize, 3 * 2 * 3), parsed.pixels.len);

    const re_encoded = try encodeBmp(testing.allocator, parsed.pixels, parsed.header);
    defer testing.allocator.free(re_encoded);

    try testing.expectEqualSlices(u8, bmp_data, re_encoded);
}

test "BMP pixel order: BGR to RGB conversion" {
    // 1x1 24-bit BMP, bottom-up
    const bmp_data = try makeTestBmp24(testing.allocator, 1, 1, false);
    defer testing.allocator.free(bmp_data);

    // Set pixel to known BGR values
    bmp_data[54] = 0x11; // B
    bmp_data[55] = 0x22; // G
    bmp_data[56] = 0x33; // R

    var parsed = try parseBmp(testing.allocator, bmp_data);
    defer parsed.deinit();

    // Parsed pixels should be RGB
    try testing.expectEqual(@as(u8, 0x33), parsed.pixels[0]); // R
    try testing.expectEqual(@as(u8, 0x22), parsed.pixels[1]); // G
    try testing.expectEqual(@as(u8, 0x11), parsed.pixels[2]); // B
}

test "BMP rejects compressed BMP (RLE)" {
    const bmp_data = try makeTestBmp24(testing.allocator, 4, 3, false);
    defer testing.allocator.free(bmp_data);

    // Set compression to BI_RLE8 = 1
    bmp_data[30] = 1;

    const result = parseBmp(testing.allocator, bmp_data);
    try testing.expectError(BmpError.UnsupportedBmp, result);
}

test "BMP rejects 8-bit indexed BMP" {
    const bmp_data = try makeTestBmp24(testing.allocator, 4, 3, false);
    defer testing.allocator.free(bmp_data);

    // Set bpp to 8
    bmp_data[28] = 8;

    const result = parseBmp(testing.allocator, bmp_data);
    try testing.expectError(BmpError.UnsupportedBmp, result);
}
