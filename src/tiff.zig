const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TiffError = error{
    InvalidTiff,
    UnsupportedTiff,
    CorruptedData,
};

/// Byte order for TIFF file.
pub const ByteOrder = enum { little, big };

/// TIFF tag IDs we care about.
const TAG_IMAGE_WIDTH = 256;
const TAG_IMAGE_LENGTH = 257;
const TAG_BITS_PER_SAMPLE = 258;
const TAG_COMPRESSION = 259;
const TAG_PHOTOMETRIC = 262;
const TAG_STRIP_OFFSETS = 273;
const TAG_SAMPLES_PER_PIXEL = 277;
const TAG_ROWS_PER_STRIP = 278;
const TAG_STRIP_BYTE_COUNTS = 279;
const TAG_PLANAR_CONFIGURATION = 284;

/// Parsed TIFF info needed for JXL transcoding and reconstruction.
pub const TiffInfo = struct {
    width: u32,
    height: u32,
    bits_per_sample: u16,
    samples_per_pixel: u16,
    compression: u16, // 1=none, 5=LZW, 8=deflate, etc.
    photometric: u16, // 1=min-is-black, 2=RGB, etc.
};

pub const ParsedTiff = struct {
    info: TiffInfo,
    /// Raw decompressed pixels in native channel order (RGB or gray).
    pixels: []u8,
    /// Non-pixel bytes of the TIFF file (header, IFDs, metadata).
    /// Format: [u32_le total_file_size][u32_le num_strips]
    ///         [u32_le strip_offset, u32_le strip_size] * num_strips
    ///         [remaining non-pixel bytes = full file with pixel regions zeroed]
    meta: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedTiff) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.meta);
    }
};

const TIFF_LE_MAGIC = [_]u8{ 'I', 'I', 42, 0 };
const TIFF_BE_MAGIC = [_]u8{ 'M', 'M', 0, 42 };

/// Check if buffer starts with TIFF magic bytes.
pub fn isTiffMagic(buf: []const u8) bool {
    if (buf.len < 4) return false;
    return (buf[0] == 'I' and buf[1] == 'I' and buf[2] == 42 and buf[3] == 0) or
        (buf[0] == 'M' and buf[1] == 'M' and buf[2] == 0 and buf[3] == 42);
}

/// Read u16 with given byte order.
fn readU16(buf: []const u8, order: ByteOrder) u16 {
    return switch (order) {
        .little => @as(u16, buf[0]) | (@as(u16, buf[1]) << 8),
        .big => (@as(u16, buf[0]) << 8) | @as(u16, buf[1]),
    };
}

/// Read u32 with given byte order.
fn readU32(buf: []const u8, order: ByteOrder) u32 {
    return switch (order) {
        .little => @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) |
            (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24),
        .big => (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) |
            (@as(u32, buf[2]) << 8) | @as(u32, buf[3]),
    };
}

/// Read a TIFF tag value (handles inline short/long and offset-based values).
fn readTagValue(data: []const u8, ifd_entry: []const u8, order: ByteOrder) u32 {
    const typ = readU16(ifd_entry[2..4], order);
    const count = readU32(ifd_entry[4..8], order);
    _ = count;

    switch (typ) {
        3 => { // SHORT
            return @as(u32, readU16(ifd_entry[8..10], order));
        },
        4 => { // LONG
            return readU32(ifd_entry[8..12], order);
        },
        1 => { // BYTE
            return @as(u32, ifd_entry[8]);
        },
        else => {
            // For other types, try to read as long from value/offset field
            _ = data;
            return readU32(ifd_entry[8..12], order);
        },
    }
}

/// Read an array of TIFF tag values (strip offsets, strip byte counts).
fn readTagArray(allocator: Allocator, data: []const u8, ifd_entry: []const u8, order: ByteOrder) ![]u32 {
    const typ = readU16(ifd_entry[2..4], order);
    const count = readU32(ifd_entry[4..8], order);

    if (count == 0) return &.{};

    const values = try allocator.alloc(u32, count);

    // Determine if values are inline (fit in 4 bytes) or offset
    const value_size: usize = switch (typ) {
        1 => 1, // BYTE
        3 => 2, // SHORT
        4 => 4, // LONG
        else => 4,
    };

    const total_size = @as(usize, count) * value_size;
    const value_data: []const u8 = if (total_size <= 4)
        ifd_entry[8..12]
    else blk: {
        const offset = readU32(ifd_entry[8..12], order);
        if (@as(usize, offset) + total_size > data.len) {
            allocator.free(values);
            return TiffError.CorruptedData;
        }
        break :blk data[offset..][0..total_size];
    };

    for (0..count) |i| {
        values[i] = switch (typ) {
            1 => @as(u32, value_data[i]),
            3 => @as(u32, readU16(value_data[i * 2 ..][0..2], order)),
            4 => readU32(value_data[i * 4 ..][0..4], order),
            else => readU32(value_data[i * 4 ..][0..4], order),
        };
    }

    return values;
}

/// Parse a TIFF file, extract raw pixel data.
/// Only supports uncompressed (compression=1) baseline TIFF.
pub fn parseTiff(allocator: Allocator, data: []const u8) (TiffError || Allocator.Error)!ParsedTiff {
    if (data.len < 8) return TiffError.InvalidTiff;
    if (!isTiffMagic(data)) return TiffError.InvalidTiff;

    const order: ByteOrder = if (data[0] == 'I') .little else .big;

    // IFD offset
    const ifd_offset = readU32(data[4..8], order);
    if (@as(usize, ifd_offset) + 2 > data.len) return TiffError.CorruptedData;

    // Number of IFD entries
    const num_entries = readU16(data[ifd_offset..][0..2], order);
    const entries_start = @as(usize, ifd_offset) + 2;
    if (entries_start + @as(usize, num_entries) * 12 > data.len) return TiffError.CorruptedData;

    // Parse tags we need
    var width: u32 = 0;
    var height: u32 = 0;
    var bps: u16 = 8;
    var spp: u16 = 1;
    var compression: u16 = 1;
    var photometric: u16 = 1;
    var rows_per_strip: u32 = 0xFFFFFFFF;

    var strip_offsets_entry: ?[]const u8 = null;
    var strip_counts_entry: ?[]const u8 = null;

    for (0..num_entries) |i| {
        const entry = data[entries_start + i * 12 ..][0..12];
        const tag = readU16(entry[0..2], order);

        switch (tag) {
            TAG_IMAGE_WIDTH => width = readTagValue(data, entry, order),
            TAG_IMAGE_LENGTH => height = readTagValue(data, entry, order),
            TAG_BITS_PER_SAMPLE => bps = @truncate(readTagValue(data, entry, order)),
            TAG_COMPRESSION => compression = @truncate(readTagValue(data, entry, order)),
            TAG_PHOTOMETRIC => photometric = @truncate(readTagValue(data, entry, order)),
            TAG_SAMPLES_PER_PIXEL => spp = @truncate(readTagValue(data, entry, order)),
            TAG_ROWS_PER_STRIP => rows_per_strip = readTagValue(data, entry, order),
            TAG_STRIP_OFFSETS => strip_offsets_entry = entry,
            TAG_STRIP_BYTE_COUNTS => strip_counts_entry = entry,
            else => {},
        }
    }

    if (width == 0 or height == 0) return TiffError.InvalidTiff;

    // Only handle uncompressed TIFF for now
    if (compression != 1) return TiffError.UnsupportedTiff;

    // Only handle 8-bit and 16-bit
    if (bps != 8 and bps != 16) return TiffError.UnsupportedTiff;

    // Need strip offsets
    const strip_off_entry = strip_offsets_entry orelse return TiffError.InvalidTiff;
    const strip_cnt_entry = strip_counts_entry orelse return TiffError.InvalidTiff;

    const offsets = try readTagArray(allocator, data, strip_off_entry, order);
    defer allocator.free(offsets);
    const counts = try readTagArray(allocator, data, strip_cnt_entry, order);
    defer allocator.free(counts);

    if (offsets.len == 0 or offsets.len != counts.len) return TiffError.CorruptedData;

    // Calculate expected pixel data size
    const bytes_per_sample: usize = if (bps == 16) 2 else 1;
    const expected_pixels = @as(usize, width) * @as(usize, height) * @as(usize, spp) * bytes_per_sample;

    // Read all strips into contiguous pixel buffer
    const pixels = try allocator.alloc(u8, expected_pixels);
    var pix_offset: usize = 0;

    for (0..offsets.len) |i| {
        const strip_off: usize = offsets[i];
        const strip_len: usize = counts[i];
        if (strip_off + strip_len > data.len) {
            allocator.free(pixels);
            return TiffError.CorruptedData;
        }
        const copy_len = @min(strip_len, expected_pixels - pix_offset);
        @memcpy(pixels[pix_offset..][0..copy_len], data[strip_off..][0..copy_len]);
        pix_offset += copy_len;
    }

    // Build metadata: compact non-pixel data
    // Format: [u32_le total_file_size][u32_le num_strips]
    //         [u32_le offset, u32_le size] * num_strips
    //         [bytes before first strip][bytes between strips][bytes after last strip]
    // This avoids storing zeroed pixel data, saving significant space.
    const num_strips = offsets.len;

    // Find pixel data boundaries
    var first_pixel: usize = data.len;
    var last_pixel_end: usize = 0;
    for (0..num_strips) |i| {
        const strip_off: usize = offsets[i];
        const strip_end: usize = strip_off + counts[i];
        if (strip_off < first_pixel) first_pixel = strip_off;
        if (strip_end > last_pixel_end) last_pixel_end = strip_end;
    }

    // Non-pixel data: bytes before first pixel + bytes after last pixel
    const pre_pixel_len = first_pixel;
    const post_pixel_len = if (last_pixel_end < data.len) data.len - last_pixel_end else 0;
    const strip_map_len = num_strips * 8;
    // Format: [u32 file_size][u32 num_strips][u32 first_pixel_offset][u32 pre_len][u32 post_len]
    //         [strip_map: offset+size pairs]
    //         [pre_pixel_bytes][post_pixel_bytes]
    const fixed_header = 4 + 4 + 4 + 4 + 4; // 20 bytes
    const meta_len = fixed_header + strip_map_len + pre_pixel_len + post_pixel_len;
    const meta = try allocator.alloc(u8, meta_len);

    const file_size: u32 = @intCast(data.len);
    const ns: u32 = @intCast(num_strips);
    const fp: u32 = @intCast(first_pixel);
    const pre: u32 = @intCast(pre_pixel_len);
    const post: u32 = @intCast(post_pixel_len);
    std.mem.writeInt(u32, meta[0..4], file_size, .little);
    std.mem.writeInt(u32, meta[4..8], ns, .little);
    std.mem.writeInt(u32, meta[8..12], fp, .little);
    std.mem.writeInt(u32, meta[12..16], pre, .little);
    std.mem.writeInt(u32, meta[16..20], post, .little);

    // Strip map
    for (0..num_strips) |i| {
        std.mem.writeInt(u32, meta[20 + i * 8 ..][0..4], offsets[i], .little);
        std.mem.writeInt(u32, meta[20 + i * 8 + 4 ..][0..4], counts[i], .little);
    }

    // Pre-pixel bytes
    var moff: usize = 20 + strip_map_len;
    if (pre_pixel_len > 0) {
        @memcpy(meta[moff..][0..pre_pixel_len], data[0..pre_pixel_len]);
        moff += pre_pixel_len;
    }
    // Post-pixel bytes
    if (post_pixel_len > 0) {
        @memcpy(meta[moff..][0..post_pixel_len], data[last_pixel_end..]);
    }

    return ParsedTiff{
        .info = TiffInfo{
            .width = width,
            .height = height,
            .bits_per_sample = bps,
            .samples_per_pixel = spp,
            .compression = compression,
            .photometric = photometric,
        },
        .pixels = pixels,
        .meta = meta,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid uncompressed TIFF in memory.
fn makeTestTiff(allocator: Allocator, width: u32, height: u32) ![]u8 {
    const spp: u32 = 3; // RGB
    const pixel_data_len = width * height * spp;
    // Layout: header(8) + IFD(2 + 11*12 + 4) + pixel_data
    const ifd_entries: u32 = 11;
    const ifd_size = 2 + ifd_entries * 12 + 4; // count + entries + next_ifd
    // Actually, for single-strip, strip offset fits in the tag value field.
    // Let's use simple layout: header(8) + IFD + pixel_data
    const actual_pixel_offset: u32 = 8 + ifd_size;
    const total_size = @as(usize, actual_pixel_offset) + pixel_data_len;

    const buf = try allocator.alloc(u8, total_size);
    @memset(buf, 0);

    // TIFF header (little-endian)
    buf[0] = 'I';
    buf[1] = 'I';
    buf[2] = 42;
    buf[3] = 0;
    // IFD offset = 8
    buf[4] = 8;

    var off: usize = 8;

    // Number of IFD entries
    buf[off] = @truncate(ifd_entries);
    buf[off + 1] = @truncate(ifd_entries >> 8);
    off += 2;

    // Helper to write an IFD entry (tag, type, count, value)
    const writeEntry = struct {
        fn f(b: []u8, o: usize, tag: u16, typ: u16, count: u32, value: u32) void {
            b[o + 0] = @truncate(tag);
            b[o + 1] = @truncate(tag >> 8);
            b[o + 2] = @truncate(typ);
            b[o + 3] = @truncate(typ >> 8);
            b[o + 4] = @truncate(count);
            b[o + 5] = @truncate(count >> 8);
            b[o + 6] = @truncate(count >> 16);
            b[o + 7] = @truncate(count >> 24);
            b[o + 8] = @truncate(value);
            b[o + 9] = @truncate(value >> 8);
            b[o + 10] = @truncate(value >> 16);
            b[o + 11] = @truncate(value >> 24);
        }
    }.f;


    writeEntry(buf, off, TAG_IMAGE_WIDTH, 4, 1, width);
    off += 12;
    writeEntry(buf, off, TAG_IMAGE_LENGTH, 4, 1, height);
    off += 12;
    writeEntry(buf, off, TAG_BITS_PER_SAMPLE, 3, 1, 8);
    off += 12;
    writeEntry(buf, off, TAG_COMPRESSION, 3, 1, 1); // uncompressed
    off += 12;
    writeEntry(buf, off, TAG_PHOTOMETRIC, 3, 1, 2); // RGB
    off += 12;
    writeEntry(buf, off, TAG_STRIP_OFFSETS, 4, 1, actual_pixel_offset);
    off += 12;
    writeEntry(buf, off, TAG_SAMPLES_PER_PIXEL, 3, 1, spp);
    off += 12;
    writeEntry(buf, off, TAG_ROWS_PER_STRIP, 4, 1, height);
    off += 12;
    writeEntry(buf, off, TAG_STRIP_BYTE_COUNTS, 4, 1, pixel_data_len);
    off += 12;
    writeEntry(buf, off, TAG_PLANAR_CONFIGURATION, 3, 1, 1); // chunky
    off += 12;
    // Resolution unit (just for completeness)
    writeEntry(buf, off, 296, 3, 1, 2); // inches
    off += 12;

    // Next IFD = 0 (no more IFDs)
    // Already zero from memset

    // Fill pixel data with a pattern
    const pixels = buf[actual_pixel_offset..];
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * spp;
            pixels[idx + 0] = @truncate(x * 17); // R
            pixels[idx + 1] = @truncate(y * 23); // G
            pixels[idx + 2] = @truncate((x + y) * 13); // B
        }
    }

    return buf;
}

test "TIFF magic detection" {
    try testing.expect(isTiffMagic(&TIFF_LE_MAGIC));
    try testing.expect(isTiffMagic(&TIFF_BE_MAGIC));
    try testing.expect(!isTiffMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    try testing.expect(!isTiffMagic(&[_]u8{ 'P', 'K' }));
}

test "TIFF parse rejects too small" {
    try testing.expectError(TiffError.InvalidTiff, parseTiff(testing.allocator, &[_]u8{ 'I', 'I', 42 }));
}

test "TIFF parse uncompressed RGB" {
    const tiff_data = try makeTestTiff(testing.allocator, 8, 6);
    defer testing.allocator.free(tiff_data);

    var parsed = try parseTiff(testing.allocator, tiff_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 8), parsed.info.width);
    try testing.expectEqual(@as(u32, 6), parsed.info.height);
    try testing.expectEqual(@as(u16, 8), parsed.info.bits_per_sample);
    try testing.expectEqual(@as(u16, 3), parsed.info.samples_per_pixel);
    try testing.expectEqual(@as(u16, 1), parsed.info.compression);
    try testing.expectEqual(@as(u16, 2), parsed.info.photometric);
    try testing.expectEqual(@as(usize, 8 * 6 * 3), parsed.pixels.len);

    // Check pixel values
    try testing.expectEqual(@as(u8, 0), parsed.pixels[0]); // R at (0,0) = 0*17
    try testing.expectEqual(@as(u8, 0), parsed.pixels[1]); // G at (0,0) = 0*23
    try testing.expectEqual(@as(u8, 0), parsed.pixels[2]); // B at (0,0) = 0*13
}

test "TIFF rejects compressed TIFF" {
    const tiff_data = try makeTestTiff(testing.allocator, 4, 4);
    defer testing.allocator.free(tiff_data);

    // Set compression to LZW (5)
    // Find the compression tag entry in the IFD
    // IFD starts at offset 8, entries at 10
    // Compression is entry index 3 (0-indexed), value at offset 10 + 3*12 + 8
    const comp_value_off = 10 + 3 * 12 + 8;
    tiff_data[comp_value_off] = 5; // LZW

    try testing.expectError(TiffError.UnsupportedTiff, parseTiff(testing.allocator, tiff_data));
}

test "TIFF metadata preserved for reconstruction" {
    const tiff_data = try makeTestTiff(testing.allocator, 4, 4);
    defer testing.allocator.free(tiff_data);

    var parsed = try parseTiff(testing.allocator, tiff_data);
    defer parsed.deinit();

    // Meta should contain the file template with strip map
    // First 4 bytes = file size
    const file_size = std.mem.readInt(u32, parsed.meta[0..4], .little);
    try testing.expectEqual(@as(u32, @intCast(tiff_data.len)), file_size);
    // Reconstructed file should be identical when pixels are written back
}
