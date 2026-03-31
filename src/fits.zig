const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FitsError = error{
    InvalidFits,
    UnsupportedFits,
    CorruptedData,
};

pub const FitsInfo = struct {
    width: u32,  // NAXIS1
    height: u32, // NAXIS2
    bitpix: i32, // 8, 16, 32, -32, -64
    channels: u32, // NAXIS3 or 1
};

pub const ParsedFits = struct {
    info: FitsInfo,
    /// Raw pixel data (unchanged — FITS stores big-endian).
    pixels: []u8,
    /// Compact metadata: header blocks (non-pixel data).
    /// Format: [u32_be total_file_size][u32_be pixel_offset][u32_be pixel_size]
    ///         [header_bytes][post_pixel_bytes]
    meta: []u8,
    allocator: Allocator,

    pub fn deinit(self: *ParsedFits) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.meta);
    }
};

const FITS_MAGIC = "SIMPLE  =                    T";

/// Check if buffer starts with FITS magic.
pub fn isFitsMagic(buf: []const u8) bool {
    if (buf.len < 30) return false;
    return std.mem.eql(u8, buf[0..30], FITS_MAGIC);
}

/// Parse a keyword from a FITS header card (80 bytes).
fn parseCard(card: []const u8) struct { key: []const u8, value: ?i64 } {
    if (card.len < 8) return .{ .key = "", .value = null };

    // Key is first 8 chars, trimmed
    var key_end: usize = 8;
    while (key_end > 0 and card[key_end - 1] == ' ') key_end -= 1;

    if (card.len < 10 or card[8] != '=' or card[9] != ' ')
        return .{ .key = card[0..key_end], .value = null };

    // Value starts at column 10
    var val_start: usize = 10;
    while (val_start < card.len and card[val_start] == ' ') val_start += 1;

    // Parse integer value
    var negative = false;
    if (val_start < card.len and card[val_start] == '-') {
        negative = true;
        val_start += 1;
    }

    var val: i64 = 0;
    var has_digits = false;
    while (val_start < card.len) {
        const c = card[val_start];
        if (c >= '0' and c <= '9') {
            val = val * 10 + @as(i64, c - '0');
            has_digits = true;
        } else break;
        val_start += 1;
    }

    if (!has_digits) return .{ .key = card[0..key_end], .value = null };
    return .{ .key = card[0..key_end], .value = if (negative) -val else val };
}

/// Parse a FITS file into pixel data + header metadata.
/// Only supports simple 2D or 3D images (NAXIS <= 3), BITPIX 8/16.
pub fn parseFits(allocator: Allocator, data: []const u8) (FitsError || Allocator.Error)!ParsedFits {
    if (data.len < 2880) return FitsError.InvalidFits;
    if (!isFitsMagic(data)) return FitsError.InvalidFits;

    // Parse header cards (80 bytes each, in 2880-byte blocks)
    var naxis: i64 = 0;
    var naxis1: i64 = 0;
    var naxis2: i64 = 0;
    var naxis3: i64 = 1;
    var bitpix: i64 = 0;
    var header_end: usize = 0;

    var pos: usize = 0;
    var found_end = false;
    while (pos < data.len and !found_end) {
        // Process 2880-byte block
        const block_end = @min(pos + 2880, data.len);
        var card_pos = pos;
        while (card_pos + 80 <= block_end) {
            const card = data[card_pos..][0..80];
            const parsed = parseCard(card);

            if (std.mem.eql(u8, parsed.key, "BITPIX")) bitpix = parsed.value orelse 0;
            if (std.mem.eql(u8, parsed.key, "NAXIS")) naxis = parsed.value orelse 0;
            if (std.mem.eql(u8, parsed.key, "NAXIS1")) naxis1 = parsed.value orelse 0;
            if (std.mem.eql(u8, parsed.key, "NAXIS2")) naxis2 = parsed.value orelse 0;
            if (std.mem.eql(u8, parsed.key, "NAXIS3")) naxis3 = parsed.value orelse 1;

            if (std.mem.eql(u8, parsed.key, "END")) {
                found_end = true;
                break;
            }
            card_pos += 80;
        }
        // Advance to next 2880-byte boundary
        pos = (block_end + 2879) / 2880 * 2880;
    }

    if (!found_end) return FitsError.InvalidFits;
    header_end = pos;

    if (naxis < 2 or naxis > 3) return FitsError.UnsupportedFits;
    if (naxis1 <= 0 or naxis2 <= 0) return FitsError.InvalidFits;

    // Only handle 8-bit and 16-bit integer data for JXL transcoding
    if (bitpix != 8 and bitpix != 16) return FitsError.UnsupportedFits;

    const bytes_per_pixel: usize = @intCast(@divExact(@as(i64, @intCast(@abs(bitpix))), 8));
    const width: u32 = @intCast(naxis1);
    const height: u32 = @intCast(naxis2);
    const channels: u32 = @intCast(naxis3);

    const pixel_size = @as(usize, width) * @as(usize, height) * @as(usize, channels) * bytes_per_pixel;
    if (header_end + pixel_size > data.len) return FitsError.CorruptedData;

    // Copy pixel data
    const pixels = try allocator.alloc(u8, pixel_size);
    @memcpy(pixels, data[header_end..][0..pixel_size]);

    // Build compact metadata
    const post_pixel_start = header_end + pixel_size;
    const post_pixel_len = if (post_pixel_start < data.len) data.len - post_pixel_start else 0;
    const meta_prefix: usize = 12;
    const meta_len = meta_prefix + header_end + post_pixel_len;
    const meta = try allocator.alloc(u8, meta_len);

    std.mem.writeInt(u32, meta[0..4], @intCast(data.len), .big);
    std.mem.writeInt(u32, meta[4..8], @intCast(header_end), .big);
    std.mem.writeInt(u32, meta[8..12], @intCast(pixel_size), .big);
    @memcpy(meta[meta_prefix..][0..header_end], data[0..header_end]);
    if (post_pixel_len > 0) @memcpy(meta[meta_prefix + header_end ..], data[post_pixel_start..]);

    return ParsedFits{
        .info = FitsInfo{
            .width = width,
            .height = height,
            .bitpix = @intCast(bitpix),
            .channels = channels,
        },
        .pixels = pixels,
        .meta = meta,
        .allocator = allocator,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTestFits(allocator: Allocator, width: u32, height: u32, bitpix: i32) ![]u8 {
    const bytes_per_pixel: usize = @intCast(@divExact(@as(i32, @intCast(@abs(bitpix))), 8));
    const pixel_size = @as(usize, width) * @as(usize, height) * bytes_per_pixel;
    const header_size: usize = 2880; // one header block
    // Total padded to 2880-byte boundary
    const total = header_size + ((pixel_size + 2879) / 2880) * 2880;

    const buf = try allocator.alloc(u8, total);
    @memset(buf, ' '); // FITS pads with spaces

    // Write header cards
    var off: usize = 0;
    const writeCard = struct {
        fn f(b: []u8, o: *usize, key: []const u8, val: []const u8) void {
            var card: [80]u8 = [_]u8{' '} ** 80;
            @memcpy(card[0..key.len], key);
            card[8] = '=';
            card[9] = ' ';
            // Right-justify value in columns 10-29
            const start = 30 - val.len;
            @memcpy(card[start..][0..val.len], val);
            @memcpy(b[o.*..][0..80], &card);
            o.* += 80;
        }
    }.f;

    writeCard(buf, &off, "SIMPLE", "T");

    var bp_buf: [20]u8 = undefined;
    const bp_str = std.fmt.bufPrint(&bp_buf, "{d}", .{bitpix}) catch unreachable;
    writeCard(buf, &off, "BITPIX", bp_str);
    writeCard(buf, &off, "NAXIS", "2");

    var w_buf: [20]u8 = undefined;
    const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{width}) catch unreachable;
    writeCard(buf, &off, "NAXIS1", w_str);

    var h_buf: [20]u8 = undefined;
    const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{height}) catch unreachable;
    writeCard(buf, &off, "NAXIS2", h_str);

    // END card
    var end_card: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(end_card[0..3], "END");
    @memcpy(buf[off..][0..80], &end_card);

    // Pixel data
    const pixels = buf[header_size..][0..pixel_size];
    for (0..height) |y| {
        for (0..width) |x| {
            const idx = (y * width + x) * bytes_per_pixel;
            if (bitpix == 8) {
                pixels[idx] = @truncate((x * 17 + y * 23) & 0xFF);
            } else if (bitpix == 16) {
                // Big-endian 16-bit
                const val: u16 = @truncate((x * 137 + y * 53) & 0xFFFF);
                pixels[idx] = @truncate(val >> 8);
                pixels[idx + 1] = @truncate(val);
            }
        }
    }

    return buf;
}

test "FITS magic detection" {
    const fits = try makeTestFits(testing.allocator, 8, 8, 8);
    defer testing.allocator.free(fits);
    try testing.expect(isFitsMagic(fits));
}

test "FITS magic rejects non-FITS" {
    try testing.expect(!isFitsMagic("SIMPLE  = F"));
    try testing.expect(!isFitsMagic(&[_]u8{ 'P', 'K' }));
}

test "FITS parse 8-bit image" {
    const fits = try makeTestFits(testing.allocator, 16, 12, 8);
    defer testing.allocator.free(fits);

    var parsed = try parseFits(testing.allocator, fits);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 16), parsed.info.width);
    try testing.expectEqual(@as(u32, 12), parsed.info.height);
    try testing.expectEqual(@as(i32, 8), parsed.info.bitpix);
    try testing.expectEqual(@as(usize, 16 * 12), parsed.pixels.len);
}

test "FITS parse 16-bit image" {
    const fits = try makeTestFits(testing.allocator, 8, 8, 16);
    defer testing.allocator.free(fits);

    var parsed = try parseFits(testing.allocator, fits);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 8), parsed.info.width);
    try testing.expectEqual(@as(u32, 8), parsed.info.height);
    try testing.expectEqual(@as(i32, 16), parsed.info.bitpix);
    try testing.expectEqual(@as(usize, 8 * 8 * 2), parsed.pixels.len);
}

test "FITS metadata reconstruction" {
    const fits = try makeTestFits(testing.allocator, 8, 8, 8);
    defer testing.allocator.free(fits);

    var parsed = try parseFits(testing.allocator, fits);
    defer parsed.deinit();

    // Verify file size in metadata
    const file_size = std.mem.readInt(u32, parsed.meta[0..4], .big);
    try testing.expectEqual(@as(u32, @intCast(fits.len)), file_size);
}
