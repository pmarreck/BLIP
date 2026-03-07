const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PngError = error{
    InvalidPng,
    UnsupportedPng,
    CorruptedData,
};

pub const PngColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

pub const PngInfo = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: PngColorType,
    channels: u8, // derived: 1/2/3/4
    bytes_per_sample: u8, // 1 (8-bit) or 2 (16-bit)
    interlace_method: u8, // 0=none, 1=Adam7
};

pub const ParsedPng = struct {
    info: PngInfo,
    pixels: []u8, // defiltered, deinterlaced raw pixels
    pre_idat: []u8, // PNG sig + all chunks before first IDAT
    post_idat: []u8, // all chunks after last IDAT through IEND
    allocator: Allocator,

    pub fn deinit(self: *ParsedPng) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.pre_idat);
        self.allocator.free(self.post_idat);
    }
};

const PNG_SIGNATURE = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Check if buffer starts with PNG signature.
pub fn isPngMagic(buf: []const u8) bool {
    return buf.len >= 8 and std.mem.eql(u8, buf[0..8], &PNG_SIGNATURE);
}

/// Parse IHDR chunk data (13 bytes).
fn parseIhdr(data: []const u8) PngError!PngInfo {
    if (data.len < 13) return PngError.InvalidPng;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const bit_depth = data[8];
    const color_type_raw = data[9];
    const interlace_method = data[12];

    if (width == 0 or height == 0) return PngError.InvalidPng;

    const color_type: PngColorType = std.meta.intToEnum(PngColorType, color_type_raw) catch
        return PngError.UnsupportedPng;

    const channels: u8 = switch (color_type) {
        .grayscale => 1,
        .rgb => 3,
        .indexed => 1, // palette indices
        .grayscale_alpha => 2,
        .rgba => 4,
    };

    const bytes_per_sample: u8 = if (bit_depth == 16) 2 else 1;

    return PngInfo{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .channels = channels,
        .bytes_per_sample = bytes_per_sample,
        .interlace_method = interlace_method,
    };
}

/// Paeth predictor for PNG row filtering.
fn paethPredictor(a_i: i16, b_i: i16, c_i: i16) u8 {
    const p = a_i + b_i - c_i;
    const pa = @as(u16, @intCast(if (p - a_i < 0) -(p - a_i) else p - a_i));
    const pb = @as(u16, @intCast(if (p - b_i < 0) -(p - b_i) else p - b_i));
    const pc = @as(u16, @intCast(if (p - c_i < 0) -(p - c_i) else p - c_i));
    if (pa <= pb and pa <= pc) return @intCast(@as(u16, @intCast(a_i)));
    if (pb <= pc) return @intCast(@as(u16, @intCast(b_i)));
    return @intCast(@as(u16, @intCast(c_i)));
}

/// Defilter a single row of PNG data.
fn defilterRow(row: []u8, prev_row: ?[]const u8, bpp: usize) PngError!void {
    if (row.len == 0) return;
    const filter_byte = row[0];
    const data = row[1..];
    const stride = data.len;

    switch (filter_byte) {
        0 => {},
        1 => { // Sub
            for (bpp..stride) |i| {
                data[i] = data[i] +% data[i - bpp];
            }
        },
        2 => { // Up
            if (prev_row) |prev| {
                const prev_data = prev[1..];
                for (0..stride) |i| {
                    data[i] = data[i] +% prev_data[i];
                }
            }
        },
        3 => { // Average
            const prev_data: ?[]const u8 = if (prev_row) |prev| prev[1..] else null;
            for (0..stride) |i| {
                const a: u16 = if (i >= bpp) data[i - bpp] else 0;
                const b: u16 = if (prev_data) |pd| pd[i] else 0;
                data[i] = data[i] +% @as(u8, @intCast((a + b) / 2));
            }
        },
        4 => { // Paeth
            const prev_data: ?[]const u8 = if (prev_row) |prev| prev[1..] else null;
            for (0..stride) |i| {
                const a: i16 = if (i >= bpp) @intCast(data[i - bpp]) else 0;
                const b: i16 = if (prev_data) |pd| @intCast(pd[i]) else 0;
                const c_val: i16 = if (prev_data) |pd| (if (i >= bpp) @as(i16, @intCast(pd[i - bpp])) else 0) else 0;
                data[i] = data[i] +% paethPredictor(a, b, c_val);
            }
        },
        else => return PngError.CorruptedData,
    }
}

/// Unpack sub-byte bit depths (1, 2, 4) to 8-bit per sample.
fn unpackSubByte(allocator: Allocator, data: []const u8, width: u32, height: u32, bit_depth: u8, channels: u8) ![]u8 {
    const pixels_per_byte: u32 = 8 / @as(u32, bit_depth);
    const out_stride = @as(usize, width) * @as(usize, channels);
    const output = try allocator.alloc(u8, out_stride * @as(usize, height));
    errdefer allocator.free(output);

    const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;

    for (0..height) |y| {
        const in_row_stride = (@as(usize, width) * @as(usize, channels) * @as(usize, bit_depth) + 7) / 8;
        const in_row = data[y * in_row_stride ..][0..in_row_stride];
        const out_row = output[y * out_stride ..][0..out_stride];

        var pixel_idx: usize = 0;
        for (in_row) |byte| {
            var shift: u8 = 8 - bit_depth;
            for (0..pixels_per_byte) |_| {
                if (pixel_idx >= out_stride) break;
                out_row[pixel_idx] = (byte >> @intCast(shift)) & mask;
                pixel_idx += 1;
                if (shift < bit_depth) break;
                shift -= bit_depth;
            }
        }
    }

    return output;
}

/// Adam7 interlace pass dimensions
const Adam7Pass = struct { x_offset: u32, y_offset: u32, x_step: u32, y_step: u32 };
const adam7_passes = [7]Adam7Pass{
    .{ .x_offset = 0, .y_offset = 0, .x_step = 8, .y_step = 8 },
    .{ .x_offset = 4, .y_offset = 0, .x_step = 8, .y_step = 8 },
    .{ .x_offset = 0, .y_offset = 4, .x_step = 4, .y_step = 8 },
    .{ .x_offset = 2, .y_offset = 0, .x_step = 4, .y_step = 4 },
    .{ .x_offset = 0, .y_offset = 2, .x_step = 2, .y_step = 4 },
    .{ .x_offset = 1, .y_offset = 0, .x_step = 2, .y_step = 2 },
    .{ .x_offset = 0, .y_offset = 1, .x_step = 1, .y_step = 2 },
};

fn adam7PassSize(width: u32, height: u32, pass: Adam7Pass) struct { w: u32, h: u32 } {
    if (width == 0 or height == 0) return .{ .w = 0, .h = 0 };
    const w = (width -| pass.x_offset +| (pass.x_step - 1)) / pass.x_step;
    const h = (height -| pass.y_offset +| (pass.y_step - 1)) / pass.y_step;
    return .{ .w = if (pass.x_offset >= width) 0 else w, .h = if (pass.y_offset >= height) 0 else h };
}

/// Zlib-decompress data into a caller-owned buffer.
fn zlibDecompress(allocator: Allocator, compressed: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var source_reader = std.Io.Reader.fixed(compressed);
    var empty_buf: [0]u8 = .{};
    var decompress_state = flate.Decompress.init(&source_reader, .zlib, &empty_buf);
    return decompress_state.reader.allocRemaining(allocator, .unlimited) catch
        return PngError.CorruptedData;
}

/// Zlib-compress data using stored deflate blocks + Adler-32.
/// Produces valid zlib output. No actual compression (stored blocks only),
/// which is fine since PNG pixel data goes through JXL for real compression.
fn zlibCompress(allocator: Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    // Zlib header: CMF=0x78 (deflate, window=32K), FLG=0x01
    // (0x78*256 + 0x01) % 31 == 0
    try output.appendSlice(allocator, &[_]u8{ 0x78, 0x01 });

    // Raw deflate stored blocks
    const max_block: usize = 65535;
    const num_blocks: usize = if (data.len == 0) 1 else (data.len + max_block - 1) / max_block;

    var pos: usize = 0;
    var block_idx: usize = 0;
    while (block_idx < num_blocks) : (block_idx += 1) {
        const remaining = data.len - pos;
        const block_len: u16 = @intCast(@min(remaining, max_block));
        const is_final: u8 = if (block_idx == num_blocks - 1) 1 else 0;

        try output.append(allocator, is_final);
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, block_len, .little);
        try output.appendSlice(allocator, &len_bytes);
        std.mem.writeInt(u16, &len_bytes, ~block_len, .little);
        try output.appendSlice(allocator, &len_bytes);
        if (block_len > 0) {
            try output.appendSlice(allocator, data[pos..][0..block_len]);
        }
        pos += block_len;
    }

    // Adler-32 checksum (big-endian, per zlib spec)
    const adler = std.hash.Adler32.hash(data);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try output.appendSlice(allocator, &adler_bytes);

    return output.toOwnedSlice(allocator);
}

/// Parse a PNG file into pixels and metadata.
pub fn parsePng(allocator: Allocator, png_bytes: []const u8) (PngError || Allocator.Error || error{CorruptedData})!ParsedPng {
    if (!isPngMagic(png_bytes)) return PngError.InvalidPng;
    if (png_bytes.len < 8 + 12 + 13) return PngError.InvalidPng;

    var pos: usize = 8;
    var info: ?PngInfo = null;
    var idat_data: std.ArrayList(u8) = .{};
    defer idat_data.deinit(allocator);
    var first_idat_pos: ?usize = null;
    var last_idat_end: ?usize = null;

    while (pos + 12 <= png_bytes.len) {
        if (pos + 4 > png_bytes.len) break;
        const chunk_len = std.mem.readInt(u32, png_bytes[pos..][0..4], .big);
        const chunk_type = png_bytes[pos + 4 ..][0..4];
        const chunk_start = pos;
        const data_start = pos + 8;
        const data_end = data_start + chunk_len;
        const chunk_end = data_end + 4;

        if (chunk_end > png_bytes.len) return PngError.InvalidPng;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            info = try parseIhdr(png_bytes[data_start..data_end]);
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (first_idat_pos == null) first_idat_pos = chunk_start;
            last_idat_end = chunk_end;
            try idat_data.appendSlice(allocator, png_bytes[data_start..data_end]);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (last_idat_end == null) last_idat_end = chunk_start;
            const pre_end = first_idat_pos orelse return PngError.InvalidPng;
            const post_start = last_idat_end.?;

            const pre_idat = try allocator.dupe(u8, png_bytes[0..pre_end]);
            errdefer allocator.free(pre_idat);
            const post_idat = try allocator.dupe(u8, png_bytes[post_start..chunk_end]);
            errdefer allocator.free(post_idat);

            const png_info = info orelse return PngError.InvalidPng;

            const raw_data = try zlibDecompress(allocator, idat_data.items);
            defer allocator.free(raw_data);

            const bpp = computeBpp(png_info);
            var pixels: []u8 = undefined;

            if (png_info.interlace_method == 1) {
                pixels = try deinterlaceAdam7(allocator, raw_data, png_info, bpp);
            } else {
                const row_bytes = computeRowBytes(png_info);
                const filtered_row_len = 1 + row_bytes;
                const expected_len = @as(usize, png_info.height) * filtered_row_len;

                if (raw_data.len < expected_len) return PngError.CorruptedData;

                const mutable = try allocator.dupe(u8, raw_data[0..expected_len]);
                defer allocator.free(mutable);

                var prev_row: ?[]const u8 = null;
                for (0..png_info.height) |y| {
                    const row = mutable[y * filtered_row_len ..][0..filtered_row_len];
                    try defilterRow(row, prev_row, bpp);
                    prev_row = row;
                }

                pixels = try allocator.alloc(u8, @as(usize, png_info.height) * row_bytes);
                errdefer allocator.free(pixels);

                for (0..png_info.height) |y| {
                    const src = mutable[y * filtered_row_len + 1 ..][0..row_bytes];
                    const dst = pixels[y * row_bytes ..][0..row_bytes];
                    @memcpy(dst, src);
                }
            }
            errdefer allocator.free(pixels);

            if (png_info.bit_depth < 8) {
                const unpacked = try unpackSubByte(allocator, pixels, png_info.width, png_info.height, png_info.bit_depth, png_info.channels);
                allocator.free(pixels);
                pixels = unpacked;
            }

            return ParsedPng{
                .info = png_info,
                .pixels = pixels,
                .pre_idat = pre_idat,
                .post_idat = post_idat,
                .allocator = allocator,
            };
        }

        pos = chunk_end;
    }

    return PngError.InvalidPng;
}

fn computeBpp(info_arg: PngInfo) usize {
    if (info_arg.bit_depth < 8) return 1;
    return @as(usize, info_arg.channels) * @as(usize, info_arg.bytes_per_sample);
}

fn computeRowBytes(info_arg: PngInfo) usize {
    if (info_arg.bit_depth < 8) {
        return (@as(usize, info_arg.width) * @as(usize, info_arg.channels) * @as(usize, info_arg.bit_depth) + 7) / 8;
    }
    return @as(usize, info_arg.width) * @as(usize, info_arg.channels) * @as(usize, info_arg.bytes_per_sample);
}

fn computeRowBytesForWidth(info_arg: PngInfo, width: u32) usize {
    if (info_arg.bit_depth < 8) {
        return (@as(usize, width) * @as(usize, info_arg.channels) * @as(usize, info_arg.bit_depth) + 7) / 8;
    }
    return @as(usize, width) * @as(usize, info_arg.channels) * @as(usize, info_arg.bytes_per_sample);
}

fn deinterlaceAdam7(allocator: Allocator, raw_data: []const u8, info_arg: PngInfo, bpp: usize) ![]u8 {
    const full_row_bytes = computeRowBytes(info_arg);
    const full_pixels = try allocator.alloc(u8, @as(usize, info_arg.height) * full_row_bytes);
    errdefer allocator.free(full_pixels);
    @memset(full_pixels, 0);

    var data_pos: usize = 0;

    for (adam7_passes) |pass| {
        const pass_size = adam7PassSize(info_arg.width, info_arg.height, pass);
        if (pass_size.w == 0 or pass_size.h == 0) continue;

        const pass_row_bytes = computeRowBytesForWidth(info_arg, pass_size.w);
        const filtered_row_len = 1 + pass_row_bytes;

        const pass_data_len = @as(usize, pass_size.h) * filtered_row_len;
        if (data_pos + pass_data_len > raw_data.len) return PngError.CorruptedData;

        const mutable = try allocator.dupe(u8, raw_data[data_pos..][0..pass_data_len]);
        defer allocator.free(mutable);

        var prev_row: ?[]const u8 = null;
        for (0..pass_size.h) |y| {
            const row = mutable[y * filtered_row_len ..][0..filtered_row_len];
            try defilterRow(row, prev_row, bpp);
            prev_row = row;
        }

        for (0..pass_size.h) |py| {
            const src_row = mutable[py * filtered_row_len + 1 ..][0..pass_row_bytes];
            const dest_y = @as(usize, pass.y_offset) + py * @as(usize, pass.y_step);
            if (dest_y >= info_arg.height) continue;

            if (info_arg.bit_depth >= 8) {
                const pixel_bytes = @as(usize, info_arg.channels) * @as(usize, info_arg.bytes_per_sample);
                for (0..pass_size.w) |px| {
                    const dest_x = @as(usize, pass.x_offset) + px * @as(usize, pass.x_step);
                    if (dest_x >= info_arg.width) continue;
                    const src_off = px * pixel_bytes;
                    const dst_off = dest_y * full_row_bytes + dest_x * pixel_bytes;
                    @memcpy(full_pixels[dst_off..][0..pixel_bytes], src_row[src_off..][0..pixel_bytes]);
                }
            } else {
                for (0..pass_size.w) |px| {
                    const dest_x = @as(usize, pass.x_offset) + px * @as(usize, pass.x_step);
                    if (dest_x >= info_arg.width) continue;
                    const bd: u3 = @intCast(info_arg.bit_depth);
                    const src_byte_idx = (px * @as(usize, info_arg.bit_depth)) / 8;
                    const src_bit_off: u3 = @intCast(7 - ((px * @as(usize, info_arg.bit_depth)) % 8));
                    const mask = (@as(u8, 1) << bd) - 1;
                    const shift = if (src_bit_off + 1 >= bd) src_bit_off + 1 - bd else 0;
                    const val = (src_row[src_byte_idx] >> @intCast(shift)) & mask;
                    const dst_byte_idx = (dest_x * @as(usize, info_arg.bit_depth)) / 8;
                    const dst_bit_off: u3 = @intCast(7 - ((dest_x * @as(usize, info_arg.bit_depth)) % 8));
                    const dst_shift = if (dst_bit_off + 1 >= bd) dst_bit_off + 1 - bd else 0;
                    const dst_off = dest_y * full_row_bytes + dst_byte_idx;
                    full_pixels[dst_off] = (full_pixels[dst_off] & ~(@as(u8, mask) << @intCast(dst_shift))) | (val << @intCast(dst_shift));
                }
            }
        }

        data_pos += pass_data_len;
    }

    return full_pixels;
}

/// Compute CRC32 for PNG chunk (type + data).
fn computeChunkCrc(chunk_type: []const u8, data: []const u8) u32 {
    var crc = std.hash.crc.Crc32IsoHdlc.init();
    crc.update(chunk_type);
    crc.update(data);
    return crc.final();
}

/// Encode raw pixels + pre/post IDAT metadata back to a PNG file.
pub fn encodePng(allocator: Allocator, pixels: []const u8, info_arg: PngInfo, pre_idat: []const u8, post_idat: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    // Write pre_idat (may need to patch IHDR if interlaced)
    if (info_arg.interlace_method == 1 and pre_idat.len >= 8 + 25) {
        const ihdr_data_start: usize = 8 + 4 + 4; // sig + length + "IHDR"
        const ihdr_data_end: usize = ihdr_data_start + 13;
        try output.appendSlice(allocator, pre_idat[0..ihdr_data_end]);
        // Patch interlace method to 0
        output.items[ihdr_data_start + 12] = 0;
        // Recompute CRC
        const ihdr_crc = computeChunkCrc(output.items[8 + 4 .. 8 + 8], output.items[ihdr_data_start..ihdr_data_end]);
        var crc_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc_bytes, ihdr_crc, .big);
        try output.appendSlice(allocator, &crc_bytes);
        // Copy rest of pre_idat (after IHDR chunk)
        const after_ihdr = 8 + 4 + 4 + 13 + 4;
        if (after_ihdr < pre_idat.len) {
            try output.appendSlice(allocator, pre_idat[after_ihdr..]);
        }
    } else {
        try output.appendSlice(allocator, pre_idat);
    }

    const pixel_row_bytes = @as(usize, info_arg.width) * @as(usize, info_arg.channels) * @as(usize, info_arg.bytes_per_sample);

    // Build filtered data: filter byte 0 (None) + raw row data
    var filtered: std.ArrayList(u8) = .{};
    defer filtered.deinit(allocator);

    for (0..info_arg.height) |y| {
        try filtered.append(allocator, 0);
        try filtered.appendSlice(allocator, pixels[y * pixel_row_bytes ..][0..pixel_row_bytes]);
    }

    // Zlib compress
    const compressed = try zlibCompress(allocator, filtered.items);
    defer allocator.free(compressed);

    // Write IDAT chunk
    var idat_len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &idat_len_bytes, @intCast(compressed.len), .big);
    try output.appendSlice(allocator, &idat_len_bytes);
    try output.appendSlice(allocator, "IDAT");
    try output.appendSlice(allocator, compressed);
    const idat_crc = computeChunkCrc("IDAT", compressed);
    var idat_crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &idat_crc_bytes, idat_crc, .big);
    try output.appendSlice(allocator, &idat_crc_bytes);

    // Write post_idat
    try output.appendSlice(allocator, post_idat);

    return output.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "isPngMagic detects PNG signature" {
    try testing.expect(isPngMagic(&PNG_SIGNATURE));
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..8], &PNG_SIGNATURE);
    try testing.expect(isPngMagic(&buf));
}

test "isPngMagic rejects non-PNG" {
    try testing.expect(!isPngMagic(&[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }));
    try testing.expect(!isPngMagic(&[_]u8{ 0x50, 0x4B, 0x03, 0x04 }));
    try testing.expect(!isPngMagic(&[_]u8{}));
    try testing.expect(!isPngMagic(&[_]u8{ 0x89, 0x50, 0x4E }));
}

fn writeChunk(out: *std.ArrayList(u8), allocator: Allocator, chunk_type: *const [4]u8, data: []const u8) !void {
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len_bytes);
    try out.appendSlice(allocator, chunk_type);
    try out.appendSlice(allocator, data);
    const crc = computeChunkCrc(chunk_type, data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc, .big);
    try out.appendSlice(allocator, &crc_bytes);
}

fn makeTestIdat(allocator: Allocator, raw: []const u8) ![]u8 {
    return zlibCompress(allocator, raw);
}

fn makeMinimalPng(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &PNG_SIGNATURE);

    const ihdr_data = [13]u8{
        0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
    };
    try writeChunk(&out, allocator, "IHDR", &ihdr_data);

    const raw_row = [_]u8{ 0, 255, 0, 0, 255 };
    const compressed = try makeTestIdat(allocator, &raw_row);
    defer allocator.free(compressed);
    try writeChunk(&out, allocator, "IDAT", compressed);
    try writeChunk(&out, allocator, "IEND", &[_]u8{});

    return out.toOwnedSlice(allocator);
}

test "parsePng on minimal 1x1 RGBA8 PNG" {
    const png_data = try makeMinimalPng(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 1), parsed.info.width);
    try testing.expectEqual(@as(u32, 1), parsed.info.height);
    try testing.expectEqual(@as(u8, 4), parsed.info.channels);
    try testing.expectEqual(@as(u8, 8), parsed.info.bit_depth);
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, parsed.pixels);
}

test "parsePng preserves pre-IDAT and post-IDAT chunks" {
    const png_data = try makeMinimalPng(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    try testing.expect(parsed.pre_idat.len > 0);
    try testing.expect(std.mem.startsWith(u8, parsed.pre_idat, &PNG_SIGNATURE));
    try testing.expect(parsed.post_idat.len > 0);
    try testing.expect(parsed.post_idat.len >= 12);
}

test "parsePng rejects non-PNG" {
    const result = parsePng(testing.allocator, &[_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 });
    try testing.expectError(PngError.InvalidPng, result);
}

test "parsePng rejects truncated PNG" {
    const result = parsePng(testing.allocator, &PNG_SIGNATURE);
    try testing.expectError(PngError.InvalidPng, result);
}

test "encodePng roundtrip: pixels -> PNG -> parse -> same pixels" {
    const png_data = try makeMinimalPng(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    const re_encoded = try encodePng(testing.allocator, parsed.pixels, parsed.info, parsed.pre_idat, parsed.post_idat);
    defer testing.allocator.free(re_encoded);

    var reparsed = try parsePng(testing.allocator, re_encoded);
    defer reparsed.deinit();

    try testing.expectEqualSlices(u8, parsed.pixels, reparsed.pixels);
    try testing.expectEqual(parsed.info.width, reparsed.info.width);
    try testing.expectEqual(parsed.info.height, reparsed.info.height);
    try testing.expectEqual(parsed.info.channels, reparsed.info.channels);
}

fn make2x2RgbPng(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &PNG_SIGNATURE);
    const ihdr_data = [13]u8{ 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0 };
    try writeChunk(&out, allocator, "IHDR", &ihdr_data);

    const raw = [_]u8{
        0, 255, 0,   0,   0,   255, 0,
        0, 0,   0,   255, 255, 255, 255,
    };
    const compressed = try makeTestIdat(allocator, &raw);
    defer allocator.free(compressed);
    try writeChunk(&out, allocator, "IDAT", compressed);
    try writeChunk(&out, allocator, "IEND", &[_]u8{});

    return out.toOwnedSlice(allocator);
}

test "parsePng on 2x2 RGB8 PNG" {
    const png_data = try make2x2RgbPng(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 2), parsed.info.width);
    try testing.expectEqual(@as(u32, 2), parsed.info.height);
    try testing.expectEqual(@as(u8, 3), parsed.info.channels);
    try testing.expectEqualSlices(u8, &[_]u8{
        255, 0,   0,   0,   255, 0,
        0,   0,   255, 255, 255, 255,
    }, parsed.pixels);
}

test "row defilter: Sub filter" {
    var row = [_]u8{ 1, 10, 20, 30, 5, 7, 9 };
    try defilterRow(&row, null, 3);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 10, 20, 30, 15, 27, 39 }, &row);
}

test "row defilter: Up filter" {
    var prev = [_]u8{ 0, 100, 200, 50 };
    var row = [_]u8{ 2, 10, 20, 30 };
    try defilterRow(&row, &prev, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 2, 110, 220, 80 }, &row);
}

test "row defilter: Average filter" {
    var prev = [_]u8{ 0, 20, 40, 60, 80 };
    var row = [_]u8{ 3, 10, 10, 10, 10 };
    try defilterRow(&row, &prev, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 3, 20, 40, 60, 80 }, &row);
}

test "row defilter: Paeth filter" {
    var prev = [_]u8{ 0, 10, 20, 30 };
    var row = [_]u8{ 4, 5, 5, 5 };
    try defilterRow(&row, &prev, 1);
    try testing.expectEqualSlices(u8, &[_]u8{ 4, 15, 25, 35 }, &row);
}

fn makePngWithText(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &PNG_SIGNATURE);
    const ihdr_data = [13]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    try writeChunk(&out, allocator, "IHDR", &ihdr_data);
    try writeChunk(&out, allocator, "tEXt", "Comment\x00test");

    const raw_row = [_]u8{ 0, 128, 128, 128, 255 };
    const compressed = try makeTestIdat(allocator, &raw_row);
    defer allocator.free(compressed);
    try writeChunk(&out, allocator, "IDAT", compressed);
    try writeChunk(&out, allocator, "IEND", &[_]u8{});

    return out.toOwnedSlice(allocator);
}

test "parsePng preserves tEXt chunk in pre_idat" {
    const png_data = try makePngWithText(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    try testing.expect(std.mem.indexOf(u8, parsed.pre_idat, "tEXt") != null);
    try testing.expect(std.mem.indexOf(u8, parsed.pre_idat, "Comment") != null);
}

test "encodePng roundtrip preserves tEXt metadata" {
    const png_data = try makePngWithText(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    const re_encoded = try encodePng(testing.allocator, parsed.pixels, parsed.info, parsed.pre_idat, parsed.post_idat);
    defer testing.allocator.free(re_encoded);

    try testing.expect(std.mem.indexOf(u8, re_encoded, "Comment") != null);

    var reparsed = try parsePng(testing.allocator, re_encoded);
    defer reparsed.deinit();
    try testing.expectEqualSlices(u8, parsed.pixels, reparsed.pixels);
}

fn make1x1GrayPng(allocator: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &PNG_SIGNATURE);
    const ihdr_data = [13]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 };
    try writeChunk(&out, allocator, "IHDR", &ihdr_data);

    const raw_row = [_]u8{ 0, 128 };
    const compressed = try makeTestIdat(allocator, &raw_row);
    defer allocator.free(compressed);
    try writeChunk(&out, allocator, "IDAT", compressed);
    try writeChunk(&out, allocator, "IEND", &[_]u8{});

    return out.toOwnedSlice(allocator);
}

test "parsePng on 1x1 grayscale PNG" {
    const png_data = try make1x1GrayPng(testing.allocator);
    defer testing.allocator.free(png_data);

    var parsed = try parsePng(testing.allocator, png_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u8, 1), parsed.info.channels);
    try testing.expectEqual(PngColorType.grayscale, parsed.info.color_type);
    try testing.expectEqualSlices(u8, &[_]u8{128}, parsed.pixels);
}
