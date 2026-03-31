const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DicomError = error{
    InvalidDicom,
    UnsupportedDicom,
    CorruptedData,
};

pub const DicomInfo = struct {
    width: u32,   // Columns (0028,0011)
    height: u32,  // Rows (0028,0010)
    bits_allocated: u16, // (0028,0100) — 8 or 16
    bits_stored: u16,    // (0028,0101)
    samples_per_pixel: u16, // (0028,0002) — 1 (grayscale) or 3 (RGB)
    photometric: []const u8, // MONOCHROME1, MONOCHROME2, RGB, etc.
};

pub const ParsedDicom = struct {
    info: DicomInfo,
    /// Raw pixel data (uncompressed).
    pixels: []u8,
    /// Compact metadata: non-pixel bytes.
    /// Format: [u32_le file_size][u32_le pixel_offset][u32_le pixel_size]
    ///         [pre_pixel_bytes][post_pixel_bytes]
    meta: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedDicom) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.meta);
    }
};

const DICM_MAGIC = "DICM";

/// Check if buffer starts with DICOM magic (128-byte preamble + "DICM").
pub fn isDicomMagic(buf: []const u8) bool {
    if (buf.len < 132) return false;
    return std.mem.eql(u8, buf[128..132], DICM_MAGIC);
}

fn readU16LE(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

fn readU32LE(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

/// Check if a VR is explicit (2-char ASCII tag).
fn isExplicitVR(vr: []const u8) bool {
    if (vr.len < 2) return false;
    return (vr[0] >= 'A' and vr[0] <= 'Z') and (vr[1] >= 'A' and vr[1] <= 'Z');
}

/// Parse a DICOM file, extract uncompressed pixel data.
/// Only supports uncompressed (native) transfer syntaxes.
pub fn parseDicom(allocator: Allocator, data: []const u8) (DicomError || Allocator.Error)!ParsedDicom {
    if (data.len < 256) return DicomError.InvalidDicom;
    if (!isDicomMagic(data)) return DicomError.InvalidDicom;

    var pos: usize = 132; // After preamble + magic
    var width: u32 = 0;
    var height: u32 = 0;
    var bits_allocated: u16 = 0;
    var bits_stored: u16 = 0;
    var samples_per_pixel: u16 = 1;
    var pixel_data_offset: usize = 0;
    var pixel_data_size: u32 = 0;
    var is_explicit_vr = true; // Start with explicit VR (meta header is always explicit)

    // Parse data elements
    while (pos + 8 <= data.len) {
        const group = readU16LE(data[pos..][0..2]);
        const element = readU16LE(data[pos + 2 ..][0..2]);

        // End of meta header marker — switch to implicit VR if needed
        if (group > 0x0002 and is_explicit_vr) {
            // Check if this looks like explicit VR
            is_explicit_vr = isExplicitVR(data[pos + 4 ..][0..2]);
        }

        var value_offset: usize = 0;
        var value_length: u32 = 0;

        if (is_explicit_vr) {
            if (pos + 8 > data.len) break;
            const vr = data[pos + 4 ..][0..2];

            // Long VRs: OB, OD, OF, OL, OW, SQ, UC, UN, UR, UT
            const is_long = (vr[0] == 'O' and (vr[1] == 'B' or vr[1] == 'D' or vr[1] == 'F' or
                vr[1] == 'L' or vr[1] == 'W')) or
                (vr[0] == 'S' and vr[1] == 'Q') or
                (vr[0] == 'U' and (vr[1] == 'C' or vr[1] == 'N' or vr[1] == 'R' or vr[1] == 'T'));

            if (is_long) {
                if (pos + 12 > data.len) break;
                value_length = readU32LE(data[pos + 8 ..][0..4]);
                value_offset = pos + 12;
            } else {
                if (pos + 8 > data.len) break;
                value_length = readU16LE(data[pos + 6 ..][0..2]);
                value_offset = pos + 8;
            }
        } else {
            // Implicit VR
            if (pos + 8 > data.len) break;
            value_length = readU32LE(data[pos + 4 ..][0..4]);
            value_offset = pos + 8;
        }

        // Handle undefined length (0xFFFFFFFF) — skip sequences
        if (value_length == 0xFFFFFFFF) {
            // Pixel data with encapsulated format — not supported
            if (group == 0x7FE0 and element == 0x0010)
                return DicomError.UnsupportedDicom;

            // Skip to sequence delimitation item
            var scan = value_offset;
            while (scan + 8 <= data.len) {
                const sg = readU16LE(data[scan..][0..2]);
                const se = readU16LE(data[scan + 2 ..][0..2]);
                if (sg == 0xFFFE and se == 0xE0DD) {
                    scan += 8;
                    break;
                }
                const il = readU32LE(data[scan + 4 ..][0..4]);
                scan += 8 + (if (il == 0xFFFFFFFF) 0 else @as(usize, il));
            }
            pos = scan;
            continue;
        }

        // Extract tag values
        if (group == 0x0028) {
            switch (element) {
                0x0010 => { // Rows
                    if (value_offset + 2 <= data.len)
                        height = readU16LE(data[value_offset..][0..2]);
                },
                0x0011 => { // Columns
                    if (value_offset + 2 <= data.len)
                        width = readU16LE(data[value_offset..][0..2]);
                },
                0x0002 => { // Samples Per Pixel
                    if (value_offset + 2 <= data.len)
                        samples_per_pixel = readU16LE(data[value_offset..][0..2]);
                },
                0x0100 => { // Bits Allocated
                    if (value_offset + 2 <= data.len)
                        bits_allocated = readU16LE(data[value_offset..][0..2]);
                },
                0x0101 => { // Bits Stored
                    if (value_offset + 2 <= data.len)
                        bits_stored = readU16LE(data[value_offset..][0..2]);
                },
                else => {},
            }
        }

        // Pixel Data tag (7FE0,0010)
        if (group == 0x7FE0 and element == 0x0010) {
            pixel_data_offset = value_offset;
            pixel_data_size = value_length;
        }

        pos = value_offset + value_length;
    }

    if (width == 0 or height == 0) return DicomError.InvalidDicom;
    if (bits_allocated != 8 and bits_allocated != 16) return DicomError.UnsupportedDicom;
    if (pixel_data_offset == 0 or pixel_data_size == 0) return DicomError.InvalidDicom;
    if (pixel_data_offset + pixel_data_size > data.len) return DicomError.CorruptedData;

    // Copy pixel data
    const pixels = try allocator.alloc(u8, pixel_data_size);
    @memcpy(pixels, data[pixel_data_offset..][0..pixel_data_size]);

    // Build compact metadata
    const pre_pixel_len = pixel_data_offset;
    const post_pixel_start = pixel_data_offset + pixel_data_size;
    const post_pixel_len = if (post_pixel_start < data.len) data.len - post_pixel_start else 0;
    const meta_prefix: usize = 12;
    const meta_len = meta_prefix + pre_pixel_len + post_pixel_len;
    const meta = try allocator.alloc(u8, meta_len);

    std.mem.writeInt(u32, meta[0..4], @intCast(data.len), .little);
    std.mem.writeInt(u32, meta[4..8], @intCast(pixel_data_offset), .little);
    std.mem.writeInt(u32, meta[8..12], pixel_data_size, .little);
    @memcpy(meta[meta_prefix..][0..pre_pixel_len], data[0..pre_pixel_len]);
    if (post_pixel_len > 0) @memcpy(meta[meta_prefix + pre_pixel_len ..], data[post_pixel_start..]);

    return ParsedDicom{
        .info = DicomInfo{
            .width = width,
            .height = height,
            .bits_allocated = bits_allocated,
            .bits_stored = if (bits_stored > 0) bits_stored else bits_allocated,
            .samples_per_pixel = samples_per_pixel,
            .photometric = &.{},
        },
        .pixels = pixels,
        .meta = meta,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn writeU16LE(buf: []u8, val: u16) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
}

fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @truncate(val);
    buf[1] = @truncate(val >> 8);
    buf[2] = @truncate(val >> 16);
    buf[3] = @truncate(val >> 24);
}

fn makeTestDicom(allocator: Allocator, width: u16, height: u16, bitsAlloc: u16) ![]u8 {
    const bps: usize = @as(usize, bitsAlloc) / 8;
    const pixel_size: u32 = @as(u32, width) * @as(u32, height) * @as(u32, @intCast(bps));

    // Preamble(128) + DICM(4) + meta elements + image elements + pixel data
    var buf_list = std.ArrayListUnmanaged(u8){};

    // 128-byte preamble
    try buf_list.appendNTimes(allocator, 0, 128);
    // DICM magic
    try buf_list.appendSlice(allocator, "DICM");

    // File Meta Information Group Length (0002,0000)
    const writeExplicitTag = struct {
        fn f(list: *std.ArrayListUnmanaged(u8), alloc: Allocator,
             group: u16, elem: u16, vr: []const u8, val: []const u8) !void {
            var tag: [4]u8 = undefined;
            writeU16LE(&tag, group);
            try list.appendSlice(alloc, tag[0..2]);
            writeU16LE(tag[0..2], elem);
            try list.appendSlice(alloc, tag[0..2]);
            try list.appendSlice(alloc, vr);
            var len_buf: [2]u8 = undefined;
            writeU16LE(&len_buf, @intCast(val.len));
            try list.appendSlice(alloc, &len_buf);
            try list.appendSlice(alloc, val);
        }
    }.f;

    const writeExplicitTagU16 = struct {
        fn f(list: *std.ArrayListUnmanaged(u8), alloc: Allocator,
             group: u16, elem: u16, vr: []const u8, val: u16) !void {
            var tag: [4]u8 = undefined;
            writeU16LE(&tag, group);
            try list.appendSlice(alloc, tag[0..2]);
            writeU16LE(tag[0..2], elem);
            try list.appendSlice(alloc, tag[0..2]);
            try list.appendSlice(alloc, vr);
            var len_buf: [2]u8 = undefined;
            writeU16LE(&len_buf, 2);
            try list.appendSlice(alloc, &len_buf);
            var val_buf: [2]u8 = undefined;
            writeU16LE(&val_buf, val);
            try list.appendSlice(alloc, &val_buf);
        }
    }.f;

    // Transfer Syntax UID — explicit VR little endian (1.2.840.10008.1.2.1)
    try writeExplicitTag(&buf_list, allocator, 0x0002, 0x0010, "UI", "1.2.840.10008.1.2.1\x00");

    // Image attributes
    try writeExplicitTagU16(&buf_list, allocator, 0x0028, 0x0002, "US", 1); // Samples Per Pixel
    try writeExplicitTagU16(&buf_list, allocator, 0x0028, 0x0010, "US", height); // Rows
    try writeExplicitTagU16(&buf_list, allocator, 0x0028, 0x0011, "US", width); // Columns
    try writeExplicitTagU16(&buf_list, allocator, 0x0028, 0x0100, "US", bitsAlloc); // Bits Allocated
    try writeExplicitTagU16(&buf_list, allocator, 0x0028, 0x0101, "US", bitsAlloc); // Bits Stored

    // Pixel Data (7FE0,0010) — OW, long form
    {
        var tag: [4]u8 = undefined;
        writeU16LE(tag[0..2], 0x7FE0);
        try buf_list.appendSlice(allocator, tag[0..2]);
        writeU16LE(tag[0..2], 0x0010);
        try buf_list.appendSlice(allocator, tag[0..2]);
        try buf_list.appendSlice(allocator, "OW");
        try buf_list.appendNTimes(allocator, 0, 2); // reserved
        var len_buf: [4]u8 = undefined;
        writeU32LE(&len_buf, pixel_size);
        try buf_list.appendSlice(allocator, &len_buf);
    }

    // Pixel data
    for (0..@as(usize, height)) |y| {
        for (0..@as(usize, width)) |x| {
            if (bitsAlloc == 8) {
                try buf_list.append(allocator, @truncate((x * 17 + y * 23) & 0xFF));
            } else {
                const val: u16 = @truncate((x * 137 + y * 53) & 0xFFFF);
                var vb: [2]u8 = undefined;
                writeU16LE(&vb, val);
                try buf_list.appendSlice(allocator, &vb);
            }
        }
    }

    return try buf_list.toOwnedSlice(allocator);
}

test "DICOM magic detection" {
    const dcm = try makeTestDicom(testing.allocator, 8, 8, 8);
    defer testing.allocator.free(dcm);
    try testing.expect(isDicomMagic(dcm));
}

test "DICOM magic rejects non-DICOM" {
    try testing.expect(!isDicomMagic(&[_]u8{ 'B', 'M', 0, 0 }));
    var zeros: [200]u8 = undefined;
    @memset(&zeros, 0);
    try testing.expect(!isDicomMagic(&zeros));
}

test "DICOM parse 8-bit grayscale" {
    const dcm = try makeTestDicom(testing.allocator, 16, 12, 8);
    defer testing.allocator.free(dcm);

    var parsed = try parseDicom(testing.allocator, dcm);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 16), parsed.info.width);
    try testing.expectEqual(@as(u32, 12), parsed.info.height);
    try testing.expectEqual(@as(u16, 8), parsed.info.bits_allocated);
    try testing.expectEqual(@as(usize, 16 * 12), parsed.pixels.len);
}

test "DICOM parse 16-bit grayscale" {
    const dcm = try makeTestDicom(testing.allocator, 8, 8, 16);
    defer testing.allocator.free(dcm);

    var parsed = try parseDicom(testing.allocator, dcm);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 8), parsed.info.width);
    try testing.expectEqual(@as(u32, 8), parsed.info.height);
    try testing.expectEqual(@as(u16, 16), parsed.info.bits_allocated);
    try testing.expectEqual(@as(usize, 8 * 8 * 2), parsed.pixels.len);
}

test "DICOM metadata reconstruction info" {
    const dcm = try makeTestDicom(testing.allocator, 8, 8, 8);
    defer testing.allocator.free(dcm);

    var parsed = try parseDicom(testing.allocator, dcm);
    defer parsed.deinit();

    const file_size = std.mem.readInt(u32, parsed.meta[0..4], .little);
    try testing.expectEqual(@as(u32, @intCast(dcm.len)), file_size);
}
