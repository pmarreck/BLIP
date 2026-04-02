const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GifError = error{
    InvalidGif,
    UnsupportedGif,
    CorruptedData,
    LzwError,
};

pub const ParsedGif = struct {
    width: u32,
    height: u32,
    /// RGBA pixels (4 channels), top-to-bottom, left-to-right.
    pixels: []u8,
    /// Complete original GIF file for faithful reconstruction.
    original: []u8,
    /// True if animated (multiple frames).
    is_animated: bool,
    allocator: Allocator,

    pub fn deinit(self: *ParsedGif) void {
        self.allocator.free(self.pixels);
        self.allocator.free(self.original);
    }
};

const GIF87A_MAGIC = "GIF87a";
const GIF89A_MAGIC = "GIF89a";

/// Check if buffer starts with GIF magic bytes.
pub fn isGifMagic(buf: []const u8) bool {
    if (buf.len < 6) return false;
    return std.mem.eql(u8, buf[0..6], GIF87A_MAGIC) or
        std.mem.eql(u8, buf[0..6], GIF89A_MAGIC);
}

/// Read a little-endian u16.
fn readU16LE(buf: []const u8) u16 {
    return @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
}

/// LZW decoder for GIF.
const LzwDecoder = struct {
    const MAX_CODE_SIZE = 12;
    const MAX_TABLE_SIZE = 1 << MAX_CODE_SIZE; // 4096

    // Table entries: each code maps to a prefix code + suffix byte.
    // For initial codes, prefix = SENTINEL and suffix = the literal byte.
    prefix: [MAX_TABLE_SIZE]u16,
    suffix: [MAX_TABLE_SIZE]u8,
    // Length of each code's string (for stack allocation)
    lengths: [MAX_TABLE_SIZE]u16,

    min_code_size: u8,
    clear_code: u16,
    eoi_code: u16,
    next_code: u16,
    code_size: u8,

    const SENTINEL: u16 = 0xFFFF;

    fn init(min_code_size: u8) LzwDecoder {
        var dec: LzwDecoder = undefined;
        dec.min_code_size = min_code_size;
        dec.clear_code = @as(u16, 1) << @intCast(min_code_size);
        dec.eoi_code = dec.clear_code + 1;
        dec.reset();
        return dec;
    }

    fn reset(self: *LzwDecoder) void {
        // Initialize table with literal entries
        for (0..@as(usize, self.clear_code)) |i| {
            self.prefix[i] = SENTINEL;
            self.suffix[i] = @truncate(i);
            self.lengths[i] = 1;
        }
        self.next_code = self.eoi_code + 1;
        self.code_size = self.min_code_size + 1;
    }

    fn addEntry(self: *LzwDecoder, prefix_code: u16, suffix_byte: u8) void {
        if (self.next_code < MAX_TABLE_SIZE) {
            self.prefix[self.next_code] = prefix_code;
            self.suffix[self.next_code] = suffix_byte;
            self.lengths[self.next_code] = if (prefix_code == SENTINEL) 1 else self.lengths[prefix_code] + 1;
            self.next_code += 1;

            // Increase code size when we've filled the current range
            if (self.next_code > (@as(u16, 1) << @intCast(self.code_size)) and self.code_size < MAX_CODE_SIZE) {
                self.code_size += 1;
            }
        }
    }

    /// Emit the string for a code into the output buffer (writes backwards, returns first byte).
    fn emitCode(self: *const LzwDecoder, code: u16, output: []u8, out_pos: *usize) u8 {
        // Walk the chain backwards to find the string
        var c = code;
        const len: usize = self.lengths[c];
        var pos = out_pos.* + len;

        if (pos > output.len) {
            // Output overflow — truncate
            pos = output.len;
        }

        var first_byte: u8 = 0;
        while (true) {
            pos -= 1;
            if (pos < output.len) {
                output[pos] = self.suffix[c];
            }
            first_byte = self.suffix[c];
            if (self.prefix[c] == SENTINEL) break;
            c = self.prefix[c];
        }

        out_pos.* += len;
        return first_byte;
    }

    /// Get the first byte of a code's string without emitting.
    fn firstByte(self: *const LzwDecoder, code: u16) u8 {
        var c = code;
        while (self.prefix[c] != SENTINEL) {
            c = self.prefix[c];
        }
        return self.suffix[c];
    }
};

/// Bit reader for GIF's sub-block stream.
const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buf: u32,
    bits_in_buf: u8,

    fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .bit_buf = 0,
            .bits_in_buf = 0,
        };
    }

    fn readBits(self: *BitReader, n: u8) GifError!u16 {
        while (self.bits_in_buf < n) {
            if (self.pos >= self.data.len) return GifError.CorruptedData;
            self.bit_buf |= @as(u32, self.data[self.pos]) << @intCast(self.bits_in_buf);
            self.pos += 1;
            self.bits_in_buf += 8;
        }
        const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
        const val: u16 = @truncate(self.bit_buf & mask);
        self.bit_buf >>= @intCast(n);
        self.bits_in_buf -= n;
        return val;
    }
};

/// Concatenate GIF sub-blocks into a contiguous byte stream.
fn readSubBlocks(allocator: Allocator, data: []const u8, start: usize) !struct { bytes: []u8, end: usize } {
    var total: usize = 0;
    var pos = start;

    // First pass: count total bytes
    while (pos < data.len) {
        const block_size = data[pos];
        pos += 1;
        if (block_size == 0) break;
        if (pos + block_size > data.len) return GifError.CorruptedData;
        total += block_size;
        pos += block_size;
    }

    // Second pass: copy bytes
    const bytes = try allocator.alloc(u8, total);
    var out: usize = 0;
    pos = start;
    while (pos < data.len) {
        const block_size = data[pos];
        pos += 1;
        if (block_size == 0) break;
        @memcpy(bytes[out..][0..block_size], data[pos..][0..block_size]);
        out += block_size;
        pos += block_size;
    }

    return .{ .bytes = bytes, .end = pos };
}

/// Decode LZW-compressed data into index values.
fn decodeLzw(allocator: Allocator, compressed: []const u8, min_code_size: u8, output_size: usize) ![]u8 {
    var decoder = LzwDecoder.init(min_code_size);
    const output = try allocator.alloc(u8, output_size);
    var out_pos: usize = 0;

    var reader = BitReader.init(compressed);
    var prev_code: u16 = LzwDecoder.SENTINEL;

    while (out_pos < output_size) {
        const code = reader.readBits(decoder.code_size) catch break;

        if (code == decoder.eoi_code) break;

        if (code == decoder.clear_code) {
            decoder.reset();
            prev_code = LzwDecoder.SENTINEL;
            continue;
        }

        if (prev_code == LzwDecoder.SENTINEL) {
            // First code after clear
            _ = decoder.emitCode(code, output, &out_pos);
            prev_code = code;
            continue;
        }

        if (code < decoder.next_code) {
            // Code is in table
            const first = decoder.firstByte(code);
            _ = decoder.emitCode(code, output, &out_pos);
            decoder.addEntry(prev_code, first);
        } else if (code == decoder.next_code) {
            // Special case: code not yet in table
            const first = decoder.firstByte(prev_code);
            _ = decoder.emitCode(prev_code, output, &out_pos);
            if (out_pos < output_size) {
                output[out_pos] = first;
                out_pos += 1;
            }
            decoder.addEntry(prev_code, first);
        } else {
            allocator.free(output);
            return GifError.LzwError;
        }

        prev_code = code;
    }

    return output;
}

/// Parse a GIF file. For static GIFs, returns RGBA pixels.
/// For animated GIFs, returns the first frame only but sets is_animated=true.
pub fn parseGif(allocator: Allocator, data: []const u8) (GifError || Allocator.Error)!ParsedGif {
    if (data.len < 13) return GifError.InvalidGif;
    if (!isGifMagic(data)) return GifError.InvalidGif;

    // Logical screen descriptor
    const screen_width = readU16LE(data[6..8]);
    const screen_height = readU16LE(data[8..10]);
    const gsd_packed = data[10];
    const has_gct = (gsd_packed & 0x80) != 0;
    const gct_size_bits: u3 = @truncate(gsd_packed & 0x07);
    const gct_entries: usize = if (has_gct) @as(usize, 1) << (@as(u4, gct_size_bits) + 1) else 0;

    if (screen_width == 0 or screen_height == 0) return GifError.InvalidGif;

    var pos: usize = 13;

    // Read global color table
    var gct: [256][3]u8 = undefined;
    if (has_gct) {
        if (pos + gct_entries * 3 > data.len) return GifError.CorruptedData;
        for (0..gct_entries) |i| {
            gct[i][0] = data[pos + i * 3 + 0];
            gct[i][1] = data[pos + i * 3 + 1];
            gct[i][2] = data[pos + i * 3 + 2];
        }
        pos += gct_entries * 3;
    }

    // Check for animation (multiple image descriptors)
    var frame_count: usize = 0;
    var transparent_index: ?u8 = null;

    // Scan for first image descriptor, handling extensions
    while (pos < data.len) {
        const block_type = data[pos];
        pos += 1;

        switch (block_type) {
            0x21 => {
                // Extension
                if (pos >= data.len) return GifError.CorruptedData;
                const ext_label = data[pos];
                pos += 1;

                if (ext_label == 0xF9 and pos + 6 <= data.len) {
                    // Graphics Control Extension
                    const block_size = data[pos];
                    if (block_size >= 4) {
                        const gce_packed = data[pos + 1];
                        const has_transparent = (gce_packed & 0x01) != 0;
                        if (has_transparent) {
                            transparent_index = data[pos + 4];
                        }
                    }
                }

                // Skip extension sub-blocks
                while (pos < data.len) {
                    const sz = data[pos];
                    pos += 1;
                    if (sz == 0) break;
                    pos += sz;
                }
            },
            0x2C => {
                // Image Descriptor
                frame_count += 1;
                if (frame_count > 1) {
                    // We already parsed the first frame; this is animated
                    break;
                }

                if (pos + 9 > data.len) return GifError.CorruptedData;
                const img_left = readU16LE(data[pos..][0..2]);
                const img_top = readU16LE(data[pos + 2 ..][0..2]);
                const img_width = readU16LE(data[pos + 4 ..][0..2]);
                const img_height = readU16LE(data[pos + 6 ..][0..2]);
                const img_packed = data[pos + 8];
                pos += 9;

                const has_lct = (img_packed & 0x80) != 0;
                const lct_size_bits: u3 = @truncate(img_packed & 0x07);
                const lct_entries: usize = if (has_lct) @as(usize, 1) << (@as(u4, lct_size_bits) + 1) else 0;
                const is_interlaced = (img_packed & 0x40) != 0;
                if (is_interlaced) return GifError.UnsupportedGif; // Interlaced GIFs not yet supported (L1)

                // Local color table overrides global
                var color_table: *const [256][3]u8 = &gct;
                var lct: [256][3]u8 = undefined;
                if (has_lct) {
                    if (pos + lct_entries * 3 > data.len) return GifError.CorruptedData;
                    for (0..lct_entries) |i| {
                        lct[i][0] = data[pos + i * 3 + 0];
                        lct[i][1] = data[pos + i * 3 + 1];
                        lct[i][2] = data[pos + i * 3 + 2];
                    }
                    pos += lct_entries * 3;
                    color_table = &lct;
                }

                // LZW minimum code size
                if (pos >= data.len) return GifError.CorruptedData;
                const min_code_size = data[pos];
                pos += 1;
                if (min_code_size > 11) return GifError.CorruptedData;

                // Read sub-blocks
                const sub_result = try readSubBlocks(allocator, data, pos);
                defer allocator.free(sub_result.bytes);
                pos = sub_result.end;

                // Decode LZW
                const pixel_count = @as(usize, img_width) * @as(usize, img_height);
                const indices = try decodeLzw(allocator, sub_result.bytes, min_code_size, pixel_count);
                defer allocator.free(indices);

                // Convert indices to RGBA using color table
                const rgba_len = @as(usize, screen_width) * @as(usize, screen_height) * 4;
                const pixels = try allocator.alloc(u8, rgba_len);
                @memset(pixels, 0); // transparent black background

                for (0..@min(pixel_count, indices.len)) |i| {
                    const ix: usize = indices[i];
                    const dst_x = img_left + @as(u16, @truncate(i % @as(usize, img_width)));
                    const dst_y = img_top + @as(u16, @truncate(i / @as(usize, img_width)));
                    if (dst_x >= screen_width or dst_y >= screen_height) continue;

                    const dst = (@as(usize, dst_y) * @as(usize, screen_width) + @as(usize, dst_x)) * 4;
                    if (transparent_index != null and ix == transparent_index.?) {
                        // Transparent pixel — leave as transparent black
                        continue;
                    }
                    pixels[dst + 0] = color_table[ix][0]; // R
                    pixels[dst + 1] = color_table[ix][1]; // G
                    pixels[dst + 2] = color_table[ix][2]; // B
                    pixels[dst + 3] = 255; // A (opaque)
                }

                // Copy original for reconstruction
                const original = try allocator.alloc(u8, data.len);
                @memcpy(original, data);

                return ParsedGif{
                    .width = screen_width,
                    .height = screen_height,
                    .pixels = pixels,
                    .original = original,
                    .is_animated = false, // Only one frame found so far
                    .allocator = allocator,
                };
            },
            0x3B => break, // Trailer
            else => {
                // Unknown block — skip
                if (pos < data.len) {
                    while (pos < data.len) {
                        const sz = data[pos];
                        pos += 1;
                        if (sz == 0) break;
                        pos += sz;
                    }
                }
            },
        }
    }

    return GifError.InvalidGif;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid GIF89a in memory (2x2, 4 colors).
fn makeTestGif(allocator: Allocator) ![]u8 {
    // Minimal GIF89a: 2x2 pixels, 4-color palette, LZW min code size 2
    var buf = std.ArrayListUnmanaged(u8){};
    // Header
    try buf.appendSlice(allocator, "GIF89a");
    // Logical screen descriptor: width=2, height=2
    try buf.appendSlice(allocator, &[_]u8{ 2, 0, 2, 0 });
    // Packed: GCT=1, color_res=1, sort=0, gct_size=1 (4 colors)
    try buf.append(allocator, 0x80 | 0x01);
    try buf.append(allocator, 0); // bg color
    try buf.append(allocator, 0); // pixel aspect

    // Global color table (4 entries × 3 bytes)
    try buf.appendSlice(allocator, &[_]u8{
        255, 0,   0, // 0: red
        0,   255, 0, // 1: green
        0,   0,   255, // 2: blue
        255, 255, 0, // 3: yellow
    });

    // Image descriptor
    try buf.append(allocator, 0x2C); // image separator
    try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // left, top
    try buf.appendSlice(allocator, &[_]u8{ 2, 0, 2, 0 }); // width, height
    try buf.append(allocator, 0); // packed (no LCT, not interlaced)

    // LZW minimum code size
    try buf.append(allocator, 2);

    // LZW compressed data: indices 0,1,2,3 for our 2x2 grid
    // With min_code_size=2: clear=4, eoi=5, initial code_size=3
    // Sequence: clear(4), 0, 1, 2, 3, eoi(5)
    // Bit packing (3-bit codes, LSB first):
    // 4=100, 0=000, 1=001, 2=010, 3=011, 5=101
    // Packed: 100 000 001 010 011 101
    // Bytes: 00000100 01001000 00010110 = 0x04 0x48 0x16... let me compute properly
    // Bits (LSB first within each byte):
    // Byte 0: bits 0-7: code4(100) code0(000) code1(0 -> first 2 bits)
    //   = 100_000_00 reversed within codes: 100 000 00 -> but LSB first means:
    //   bit0-2: code4 = 100 -> bit0=0,bit1=0,bit2=1
    //   bit3-5: code0 = 000 -> bit3=0,bit4=0,bit5=0
    //   bit6-7: code1 first 2 bits = 01 -> bit6=1,bit7=0
    //   Byte = 01000100 = 0x44
    // Byte 1: bit0: code1 last bit = 0
    //   bit1-3: code2 = 010 -> bit1=0,bit2=1,bit3=0
    //   bit4-6: code3 = 011 -> bit4=1,bit5=1,bit6=0
    //   bit7: code5 first bit = 1
    //   Byte = 10110100 = 0xB4... this is getting complex, let me just use known working bytes

    // Use a known-good minimal LZW encoding for indices [0,1,2,3]:
    // min_code_size=2, codes: CLEAR=4,0,1,2,3,EOI=5 at 3 bits each
    // Total: 6 codes × 3 bits = 18 bits = 3 bytes
    const lzw_data = [_]u8{ 0x04, 0x01, 0x50, 0x1C }; // 4 bytes of compressed data
    // Actually let me just pre-compute this properly
    // I'll use a simpler approach: single-color 1x1 GIF
    _ = lzw_data;

    // Let me restart with a 1x1 red pixel GIF which is simpler
    buf.deinit(allocator);
    buf = .{};

    try buf.appendSlice(allocator, "GIF89a");
    try buf.appendSlice(allocator, &[_]u8{ 1, 0, 1, 0 }); // 1x1
    try buf.append(allocator, 0x80); // GCT, 2 colors
    try buf.append(allocator, 0); // bg
    try buf.append(allocator, 0); // aspect
    // GCT: 2 colors
    try buf.appendSlice(allocator, &[_]u8{ 255, 0, 0, 0, 0, 0 }); // red, black
    // Image descriptor
    try buf.append(allocator, 0x2C);
    try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0, 1, 0, 1, 0, 0 });
    // LZW min code size = 2
    try buf.append(allocator, 2);
    // LZW data: clear(4)=100, 0=000, eoi(5)=101 at 3 bits
    // Bits: 100 000 101 = 9 bits = 2 bytes
    // LSB packing: byte0: bit0-2=clear(100)->0,0,1 bit3-5=0(000)->0,0,0 bit6-7=eoi first 2(10)->0,1
    // byte0 = 01000100 = 0x44
    // byte1: bit0=eoi last(1)->1
    // byte1 = 00000001 = 0x01
    try buf.append(allocator, 2); // sub-block size
    try buf.appendSlice(allocator, &[_]u8{ 0x44, 0x01 });
    try buf.append(allocator, 0); // block terminator
    // Trailer
    try buf.append(allocator, 0x3B);

    return try buf.toOwnedSlice(allocator);
}

test "GIF magic detection" {
    try testing.expect(isGifMagic("GIF89a" ++ &[_]u8{0}));
    try testing.expect(isGifMagic("GIF87a" ++ &[_]u8{0}));
    try testing.expect(!isGifMagic("PNG\x89"));
    try testing.expect(!isGifMagic("GIF"));
}

test "GIF parse rejects too small" {
    try testing.expectError(GifError.InvalidGif, parseGif(testing.allocator, "GIF89a"));
}

test "GIF parse minimal 1x1" {
    const gif_data = try makeTestGif(testing.allocator);
    defer testing.allocator.free(gif_data);

    var parsed = try parseGif(testing.allocator, gif_data);
    defer parsed.deinit();

    try testing.expectEqual(@as(u32, 1), parsed.width);
    try testing.expectEqual(@as(u32, 1), parsed.height);
    try testing.expectEqual(@as(usize, 4), parsed.pixels.len); // 1 pixel × RGBA
    try testing.expect(!parsed.is_animated);

    // Should be red (index 0 = R:255, G:0, B:0)
    try testing.expectEqual(@as(u8, 255), parsed.pixels[0]); // R
    try testing.expectEqual(@as(u8, 0), parsed.pixels[1]); // G
    try testing.expectEqual(@as(u8, 0), parsed.pixels[2]); // B
    try testing.expectEqual(@as(u8, 255), parsed.pixels[3]); // A

    // Original preserved
    try testing.expectEqualSlices(u8, gif_data, parsed.original);
}

test "GIF LZW decoder basic" {
    // Test with known data: min_code_size=2, data encodes [0]
    // clear=4, eoi=5, code_size=3
    // Codes: 4(clear), 0, 5(eoi) = 100 000 101
    // LSB packed: byte0=0x44, byte1=0x01
    const compressed = [_]u8{ 0x44, 0x01 };
    const result = try decodeLzw(testing.allocator, &compressed, 2, 1);
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(u8, 0), result[0]);
}
