//! PrintableBinary - Encode binary data as printable UTF-8 and decode it back
//!
//! This is the core library with no I/O dependencies. It provides pure
//! encoding and decoding functions that can be integrated into any Zig project.
//!
//! ## Usage as a library
//! ```zig
//! const pb = @import("printable_binary");
//! 
//! // Encode
//! const encoded = try pb.encode(allocator, input_bytes, .{});
//! defer allocator.free(encoded);
//!
//! // Decode  
//! const decoded = try pb.decode(allocator, encoded_string, .{});
//! defer allocator.free(decoded);
//! ```

const std = @import("std");

/// Character map for encoding bytes 0-255 to UTF-8 sequences.
/// Index corresponds to byte value.
pub const character_map = [256][]const u8{
    "·",
    "¯",
    "«",
    "»",
    "ϟ",
    "¿",
    "¡",
    "ª",
    "⌫",
    "⇥",
    "¶",
    "↧",
    "§",
    "⏎",
    "ȯ",
    "ʘ",
    "Ɣ",
    "¹",
    "²",
    "º",
    "³",
    "µ",
    "ɨ",
    "⏹",
    "©",
    "¦",
    "Ƶ",
    "⎋",
    "Ξ",
    "ǁ",
    "ǀ",
    "¬",
    "␣",
    "ǃ",
    "˵",
    "♯",
    "Ꞩ",
    "‰",
    "⅋",
    "ʼ",
    "❨",
    "❩",
    "⁎",
    "⨦",
    "٫",
    "˗",
    ".",
    "⁄",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "꞉",
    ";",
    "˂",
    "꞊",
    "˃",
    "Ɂ",
    "@",
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "I",
    "J",
    "K",
    "L",
    "M",
    "N",
    "O",
    "P",
    "Q",
    "R",
    "S",
    "T",
    "U",
    "V",
    "W",
    "X",
    "Y",
    "Z",
    "⟦",
    "⧷",
    "⟧",
    "^",
    "_",
    "ˋ",
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "❴",
    "∣",
    "❵",
    "˜",
    "⌦",
    "ă",
    "Ă",
    "Ǎ",
    "ǟ",
    "Ǟ",
    "ȧ",
    "Ȧ",
    "ǡ",
    "ƀ",
    "Ƀ",
    "Ɓ",
    "ƃ",
    "Ƃ",
    "ć",
    "Ć",
    "ĉ",
    "Ĉ",
    "č",
    "Č",
    "ċ",
    "Ċ",
    "ď",
    "Ď",
    "Đ",
    "ȸ",
    "Ɗ",
    "ƌ",
    "Ƌ",
    "ȡ",
    "ĕ",
    "Ĕ",
    "Ě",
    "ė",
    "ȩ",
    "Ȩ",
    "ƒ",
    "Ƒ",
    "ǵ",
    "Ǵ",
    "ğ",
    "Ğ",
    "ǧ",
    "Ǧ",
    "ḡ",
    "Ḡ",
    "ĥ",
    "Ĥ",
    "ȟ",
    "Ȟ",
    "ƕ",
    "Ƕ",
    "ĭ",
    "Ĭ",
    "Ǐ",
    "İ",
    "ȉ",
    "ȋ",
    "ĵ",
    "Ĵ",
    "ǰ",
    "ǩ",
    "Ǩ",
    "ķ",
    "Ķ",
    "ƙ",
    "Ƙ",
    "ĺ",
    "Ĺ",
    "ľ",
    "Ľ",
    "ƚ",
    "Ƚ",
    "Ń",
    "ǹ",
    "Ň",
    "ņ",
    "Ņ",
    "ȵ",
    "ŏ",
    "Ŏ",
    "Ǒ",
    "ȫ",
    "Ȫ",
    "ȱ",
    "ƥ",
    "Ƥ",
    "ȹ",
    "ɋ",
    "ŕ",
    "Ŕ",
    "ř",
    "Ř",
    "ŗ",
    "Ŗ",
    "ś",
    "Ś",
    "š",
    "Š",
    "ş",
    "Ş",
    "ť",
    "Ť",
    "ţ",
    "Ţ",
    "ț",
    "Ț",
    "ŭ",
    "Ŭ",
    "Ǔ",
    "ű",
    "ȕ",
    "Ʉ",
    "Ṿ",
    "Ʋ",
    "ŵ",
    "Ŵ",
    "ŷ",
    "Ŷ",
    "Ÿ",
    "ȳ",
    "ƴ",
    "Ƴ",
    "ź",
    "Ź",
    "ž",
    "Ž",
    "ż",
    "Ż",
};

// =============================================================================
// Comptime-optimized encode/decode lookup structures
// =============================================================================

/// Flat character map for cache-friendly encoding.
/// All character bytes packed into a single contiguous buffer (~700 bytes)
/// instead of 256 fat pointers (4KB) pointing to scattered string literals.
const FlatMapEntry = struct {
    offset: u16,
    len: u8,
};

const flat_map_data_len: usize = blk: {
    var total: usize = 0;
    for (0..256) |i| {
        total += character_map[i].len;
    }
    break :blk total;
};

const flat_map_data: [flat_map_data_len]u8 = blk: {
    @setEvalBranchQuota(100000);
    var data: [flat_map_data_len]u8 = undefined;
    var offset: usize = 0;
    for (0..256) |i| {
        const src = character_map[i];
        for (src) |byte| {
            data[offset] = byte;
            offset += 1;
        }
    }
    break :blk data;
};

const flat_map_entries: [256]FlatMapEntry = blk: {
    @setEvalBranchQuota(100000);
    var entries: [256]FlatMapEntry = undefined;
    var offset: u16 = 0;
    for (0..256) |i| {
        entries[i] = .{ .offset = offset, .len = @intCast(character_map[i].len) };
        offset += @intCast(character_map[i].len);
    }
    break :blk entries;
};

/// Direct O(1) decode lookup for 1-byte UTF-8 sequences
const decode_1byte: [256]?u8 = blk: {
    @setEvalBranchQuota(100000);
    var table = [_]?u8{null} ** 256;
    for (0..256) |i| {
        if (character_map[i].len == 1) {
            table[character_map[i][0]] = @intCast(i);
        }
    }
    break :blk table;
};

/// Direct O(1) decode lookup for 2-byte UTF-8 sequences
/// Indexed by [first_byte & 0x1F][second_byte & 0x3F]
const decode_2byte: [32][64]?u8 = blk: {
    @setEvalBranchQuota(100000);
    var table = [_][64]?u8{[_]?u8{null} ** 64} ** 32;
    for (0..256) |i| {
        if (character_map[i].len == 2) {
            const b0 = character_map[i][0];
            const b1 = character_map[i][1];
            table[b0 & 0x1F][b1 & 0x3F] = @intCast(i);
        }
    }
    break :blk table;
};

/// Sorted lookup table for 3-byte UTF-8 sequences (binary search on ~30 entries)
const Decode3Entry = struct {
    codepoint: u16,
    value: u8,
};

const decode_3byte_count: usize = blk: {
    var count: usize = 0;
    for (0..256) |i| {
        if (character_map[i].len == 3) count += 1;
    }
    break :blk count;
};

const decode_3byte_table: [decode_3byte_count]Decode3Entry = blk: {
    @setEvalBranchQuota(100000);
    var entries: [decode_3byte_count]Decode3Entry = undefined;
    var idx: usize = 0;
    for (0..256) |i| {
        if (character_map[i].len == 3) {
            const b = character_map[i];
            const cp: u16 = (@as(u16, b[0] & 0x0F) << 12) |
                (@as(u16, b[1] & 0x3F) << 6) |
                @as(u16, b[2] & 0x3F);
            entries[idx] = .{ .codepoint = cp, .value = @intCast(i) };
            idx += 1;
        }
    }
    // Insertion sort by codepoint
    for (0..decode_3byte_count) |i| {
        var j = i;
        while (j > 0 and entries[j].codepoint < entries[j - 1].codepoint) {
            const tmp = entries[j];
            entries[j] = entries[j - 1];
            entries[j - 1] = tmp;
            j -= 1;
        }
    }
    break :blk entries;
};

fn decode3ByteLookup(bytes: []const u8) ?u8 {
    if (bytes.len < 3) return null;
    const cp: u16 = (@as(u16, bytes[0] & 0x0F) << 12) |
        (@as(u16, bytes[1] & 0x3F) << 6) |
        @as(u16, bytes[2] & 0x3F);
    var left: usize = 0;
    var right: usize = decode_3byte_count;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (decode_3byte_table[mid].codepoint == cp) {
            return decode_3byte_table[mid].value;
        } else if (decode_3byte_table[mid].codepoint < cp) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return null;
}

/// Encoding options
pub const EncodeOptions = struct {
    /// Preserve literal spaces (don't encode to ␣)
    spaces: bool = false,
    /// Preserve literal tabs (don't encode to ⇥)
    tabs: bool = false,
    /// Preserve literal CR/LF (don't encode to ⏎/↧)
    crlf: bool = false,
    /// Set of bytes to preserve as-is (not encoded)
    preserve_chars: []const u8 = &.{},
};

/// Decoding options
pub const DecodeOptions = struct {
    /// Treat literal spaces as data (decode them to space bytes)
    spaces: bool = false,
    /// Strip whitespace before decoding (for formatted input)
    strip_whitespace: bool = false,
};

/// Format options for grouping encoded output
pub const FormatOptions = struct {
    /// Characters per group
    group_size: usize = 8,
    /// Groups per line
    groups_per_line: usize = 10,
    /// Use tabs instead of spaces between groups
    use_tabs: bool = false,
};

// =============================================================================
// Range API — pure function for resolving byte-range arguments
// =============================================================================

/// Warning codes returned by applyRange
pub const RangeWarning = enum(c_uint) {
    none = 0,
    start_exceeds_input = 1,
    empty_range = 2,
    end_clamped = 3,
};

/// Result of applying a byte range to an input
pub const RangeResult = extern struct {
    offset: usize, // byte offset to start from
    length: usize, // number of bytes in range
    warning: RangeWarning,
};

/// Resolve optional start/end byte-range arguments against an input length.
/// Pure function — no I/O, no allocations.
///
/// Semantics:
///  - start/end are inclusive byte offsets (matching CLI --start/--end)
///  - Negative start counts from end of input
///  - If start is null, defaults to 0; if end is null, defaults to input_len - 1
///  - OOB end is clamped with a warning
///  - start >= input_len or start > end yields an empty range with a warning
pub fn applyRange(input_len: usize, opt_start: ?i64, opt_end: ?i64) RangeResult {
    if (input_len == 0) {
        return RangeResult{ .offset = 0, .length = 0, .warning = .none };
    }

    const ilen: i64 = @intCast(input_len);
    var start: i64 = opt_start orelse 0;
    var end_val: i64 = opt_end orelse (ilen - 1);

    // Handle negative start (from end)
    if (start < 0) {
        start = ilen + start;
        if (start < 0) start = 0;
    }

    if (start >= ilen) {
        return RangeResult{ .offset = 0, .length = 0, .warning = .start_exceeds_input };
    }

    if (start > end_val) {
        return RangeResult{ .offset = 0, .length = 0, .warning = .empty_range };
    }

    var warning: RangeWarning = .none;
    if (end_val >= ilen) {
        end_val = ilen - 1;
        warning = .end_clamped;
    }

    const s: usize = @intCast(start);
    const e: usize = @intCast(end_val);
    return RangeResult{ .offset = s, .length = e - s + 1, .warning = warning };
}

// Decode tables (decode_1byte, decode_2byte, decode_3byte_table) are defined
// above, after character_map. They replace the old O(log n) binary search
// with O(1) direct table lookups for 1-byte and 2-byte sequences.

// =============================================================================
// Double-Encoding Detection
// =============================================================================

/// High-confidence set: bytes whose PB glyph differs from the raw byte.
/// Computed at comptime from the character map.
const high_confidence_set: [256]bool = blk: {
    @setEvalBranchQuota(100000);
    var set = [_]bool{false} ** 256;
    for (0..256) |i| {
        const mapping = character_map[i];
        if (mapping.len != 1 or mapping[0] != @as(u8, @intCast(i))) {
            set[i] = true;
        }
    }
    break :blk set;
};

/// Result of double-encoding detection
pub const DoubleEncodeInfo = extern struct {
    detected: c_int, // 0 = not detected, 1 = detected
    confidence: f32, // 0.0 to 1.0 — ratio of high-confidence glyphs
};

/// Detect whether input appears to be already printable-binary encoded.
/// Iterates input as UTF-8 characters, checks each against the decode map,
/// and if matched, checks whether the decoded byte is in the high-confidence set.
/// Returns detection result with confidence ratio.
pub fn detectDoubleEncode(input: []const u8, threshold: f32) DoubleEncodeInfo {
    if (input.len == 0) {
        return DoubleEncodeInfo{ .detected = 0, .confidence = 0.0 };
    }

    var glyph_count: usize = 0;
    var char_count: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const seq_len = utf8SeqLen(input[i]);
        const remaining = input.len - i;
        const actual_len: usize = if (seq_len > remaining) remaining else seq_len;

        char_count += 1;

        // Try to decode this UTF-8 character via the PB decode map
        if (decodeLookup(input[i .. i + actual_len])) |byte_val| {
            if (high_confidence_set[byte_val]) {
                glyph_count += 1;
            }
        }

        i += actual_len;
    }

    if (char_count == 0) {
        return DoubleEncodeInfo{ .detected = 0, .confidence = 0.0 };
    }

    const confidence: f32 = @as(f32, @floatFromInt(glyph_count)) / @as(f32, @floatFromInt(char_count));
    return DoubleEncodeInfo{
        .detected = if (confidence >= threshold) @as(c_int, 1) else @as(c_int, 0),
        .confidence = confidence,
    };
}

/// C ABI export for double-encoding detection
export fn pb_detect_double_encode(input: [*]const u8, input_len: usize, threshold: f32) callconv(.c) DoubleEncodeInfo {
    const slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    return detectDoubleEncode(slice, threshold);
}

/// Get UTF-8 sequence length from first byte
pub fn utf8SeqLen(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

fn decodeLookup(bytes: []const u8) ?u8 {
    switch (bytes.len) {
        1 => return decode_1byte[bytes[0]],
        2 => return decode_2byte[bytes[0] & 0x1F][bytes[1] & 0x3F],
        3 => return decode3ByteLookup(bytes),
        else => return null,
    }
}

/// Encode binary data to printable UTF-8.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn encode(allocator: std.mem.Allocator, input: []const u8, options: EncodeOptions) ![]u8 {
    if (input.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    // Pre-allocate worst case: every byte → max 3-byte UTF-8
    var result = try allocator.alloc(u8, input.len * 3);
    errdefer allocator.free(result);

    // Build preserve set
    var preserve_set = [_]bool{false} ** 256;
    for (options.preserve_chars) |c| {
        preserve_set[c] = true;
    }

    var pos: usize = 0;
    for (input) |byte| {
        if (options.spaces and byte == ' ') {
            result[pos] = ' ';
            pos += 1;
        } else if (options.tabs and byte == '\t') {
            result[pos] = '\t';
            pos += 1;
        } else if (options.crlf and (byte == '\n' or byte == '\r')) {
            result[pos] = byte;
            pos += 1;
        } else if (preserve_set[byte]) {
            result[pos] = byte;
            pos += 1;
        } else {
            const entry = flat_map_entries[byte];
            const len: usize = entry.len;
            @memcpy(result[pos..][0..len], flat_map_data[entry.offset..][0..len]);
            pos += len;
        }
    }

    // Shrink to actual size
    const final = try allocator.alloc(u8, pos);
    @memcpy(final, result[0..pos]);
    allocator.free(result);
    return final;
}

/// Decode printable UTF-8 back to binary data.
/// Unrecognized UTF-8 characters pass through unchanged.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn decode(allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) ![]u8 {
    if (input.len == 0) {
        return try allocator.alloc(u8, 0);
    }

    // Optionally strip whitespace (pre-allocated buffer, no ArrayList)
    var cleaned: []const u8 = undefined;
    var cleaned_buf: ?[]u8 = null;
    defer if (cleaned_buf) |buf| allocator.free(buf);

    if (options.strip_whitespace) {
        var buf = try allocator.alloc(u8, input.len);
        var buf_len: usize = 0;
        for (input) |c| {
            const skip = if (options.spaces)
                (c == '\n' or c == '\r' or c == '\t')
            else
                (c == '\n' or c == '\r' or c == '\t' or c == ' ');
            if (!skip) {
                buf[buf_len] = c;
                buf_len += 1;
            }
        }
        cleaned_buf = buf;
        cleaned = buf[0..buf_len];
    } else {
        cleaned = input;
    }

    // Pre-allocate output buffer (decode output <= input size)
    var result = try allocator.alloc(u8, cleaned.len);
    errdefer allocator.free(result);

    var i: usize = 0;
    var pos: usize = 0;
    while (i < cleaned.len) {
        // Handle literal spaces in spaces mode
        if (options.spaces and cleaned[i] == ' ') {
            result[pos] = ' ';
            pos += 1;
            i += 1;
            continue;
        }

        const seq_len = utf8SeqLen(cleaned[i]);
        const remaining = cleaned.len - i;
        const actual_len: usize = if (seq_len > remaining) remaining else seq_len;

        // Direct table lookup — O(1) for 1-byte and 2-byte, no inner loop
        if (actual_len == seq_len) {
            if (decodeLookup(cleaned[i .. i + actual_len])) |byte| {
                result[pos] = byte;
                pos += 1;
                i += actual_len;
                continue;
            }
        }

        // Pass through unrecognized or truncated UTF-8 sequences
        @memcpy(result[pos..][0..actual_len], cleaned[i..][0..actual_len]);
        pos += actual_len;
        i += actual_len;
    }

    // Shrink to actual size
    const final = try allocator.alloc(u8, pos);
    @memcpy(final, result[0..pos]);
    allocator.free(result);
    return final;
}

/// Format encoded output into groups for readability.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn format(allocator: std.mem.Allocator, input: []const u8, options: FormatOptions) ![]u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    const separator: u8 = if (options.use_tabs) '\t' else ' ';
    var char_count: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const seq_len = utf8SeqLen(input[i]);
        const remaining = input.len - i;
        const actual_len: usize = if (seq_len > remaining) remaining else seq_len;

        try result.appendSlice(allocator, input[i .. i + actual_len]);
        char_count += 1;
        i += actual_len;

        if (char_count % options.group_size == 0 and i < input.len) {
            if ((char_count / options.group_size) % options.groups_per_line == 0) {
                try result.append(allocator, '\n');
            } else {
                try result.append(allocator, separator);
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Get the mapping for a specific byte value
pub fn getMapping(byte: u8) []const u8 {
    return character_map[byte];
}

/// Comptime verification that all 256 mappings exist and are valid UTF-8
pub fn verifyMappings() bool {
    @setEvalBranchQuota(100000);
    for (0..256) |i| {
        const mapping = character_map[i];
        if (mapping.len == 0) return false;
        // Verify it's valid UTF-8
        if (!std.unicode.utf8ValidateSlice(mapping)) return false;
    }
    return true;
}

comptime {
    if (!verifyMappings()) {
        @compileError("Character map validation failed - not all 256 bytes have valid UTF-8 mappings");
    }
}

// =============================================================================
// FFI Validation API
// =============================================================================

/// Whitespace handling flags for validation (bitfield)
pub const WhitespaceFlags = enum(c_uint) {
    reject_all = 0,
    allow_space = 1 << 0,
    allow_tab = 1 << 1,
    allow_lf = 1 << 2,
    allow_cr = 1 << 3,
    allow_all = 0x0F,
};

/// Result of validating a printable-binary encoded string
pub const ValidationResult = extern struct {
    is_valid: c_int, // 0 = invalid, 1 = valid
    error_position: i64, // -1 if valid, else byte offset of first invalid char
    error_codepoint: u32, // The invalid codepoint, or 0 if valid
};

/// Decode a UTF-8 sequence to a Unicode codepoint
fn decodeUtf8Codepoint(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;

    const first = bytes[0];
    if (first < 0x80) {
        return first;
    } else if (first < 0xE0) {
        if (bytes.len < 2) return null;
        if ((bytes[1] & 0xC0) != 0x80) return null;
        return (@as(u32, first & 0x1F) << 6) | (bytes[1] & 0x3F);
    } else if (first < 0xF0) {
        if (bytes.len < 3) return null;
        if ((bytes[1] & 0xC0) != 0x80 or (bytes[2] & 0xC0) != 0x80) return null;
        return (@as(u32, first & 0x0F) << 12) | (@as(u32, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
    } else {
        if (bytes.len < 4) return null;
        if ((bytes[1] & 0xC0) != 0x80 or (bytes[2] & 0xC0) != 0x80 or (bytes[3] & 0xC0) != 0x80) return null;
        return (@as(u32, first & 0x07) << 18) | (@as(u32, bytes[1] & 0x3F) << 12) | (@as(u32, bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F);
    }
}

/// Validate that a string contains only valid printable-binary encoded characters.
/// Returns validation result with position and codepoint of first error if invalid.
pub fn validate(input: []const u8, ws_flags: c_uint) ValidationResult {
    var i: usize = 0;

    while (i < input.len) {
        const byte = input[i];

        // Check whitespace handling
        if (byte == ' ') {
            if ((ws_flags & @intFromEnum(WhitespaceFlags.allow_space)) != 0) {
                i += 1;
                continue;
            }
        } else if (byte == '\t') {
            if ((ws_flags & @intFromEnum(WhitespaceFlags.allow_tab)) != 0) {
                i += 1;
                continue;
            }
        } else if (byte == '\n') {
            if ((ws_flags & @intFromEnum(WhitespaceFlags.allow_lf)) != 0) {
                i += 1;
                continue;
            }
        } else if (byte == '\r') {
            if ((ws_flags & @intFromEnum(WhitespaceFlags.allow_cr)) != 0) {
                i += 1;
                continue;
            }
        }

        // Determine UTF-8 sequence length
        const seq_len = utf8SeqLen(byte);
        const remaining = input.len - i;

        // Check for truncated UTF-8 sequence
        if (seq_len > remaining) {
            const codepoint = decodeUtf8Codepoint(input[i..]) orelse 0xFFFD;
            return ValidationResult{
                .is_valid = 0,
                .error_position = @intCast(i),
                .error_codepoint = codepoint,
            };
        }

        const seq = input[i .. i + seq_len];

        // Validate UTF-8 continuation bytes
        for (seq[1..]) |cont_byte| {
            if ((cont_byte & 0xC0) != 0x80) {
                const codepoint = decodeUtf8Codepoint(seq) orelse 0xFFFD;
                return ValidationResult{
                    .is_valid = 0,
                    .error_position = @intCast(i),
                    .error_codepoint = codepoint,
                };
            }
        }

        // Look up in decode map
        if (decodeLookup(seq) == null) {
            const codepoint = decodeUtf8Codepoint(seq) orelse 0xFFFD;
            return ValidationResult{
                .is_valid = 0,
                .error_position = @intCast(i),
                .error_codepoint = codepoint,
            };
        }

        i += seq_len;
    }

    return ValidationResult{
        .is_valid = 1,
        .error_position = -1,
        .error_codepoint = 0,
    };
}

/// C ABI export for validation function
export fn pb_validate(input: [*]const u8, input_len: usize, ws_flags: c_uint) callconv(.c) ValidationResult {
    const slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    return validate(slice, ws_flags);
}

/// C ABI export for range resolution function
export fn pb_apply_range(input_len: usize, has_start: c_int, start: i64, has_end: c_int, end: i64) callconv(.c) RangeResult {
    const opt_start: ?i64 = if (has_start != 0) start else null;
    const opt_end: ?i64 = if (has_end != 0) end else null;
    return applyRange(input_len, opt_start, opt_end);
}

// =============================================================================
// FFI Encode/Decode/Format API
// =============================================================================

/// Encode flags for C ABI (matches EncodeOptions)
pub const EncodeFlags = enum(c_uint) {
    none = 0,
    preserve_spaces = 1 << 0,
    preserve_tabs = 1 << 1,
    preserve_crlf = 1 << 2,
    preserve_all_whitespace = 0x07,
    skip_double_encode_check = 1 << 3,
};

/// Decode flags for C ABI (matches DecodeOptions)
pub const DecodeFlags = enum(c_uint) {
    none = 0,
    spaces_mode = 1 << 0,
    strip_whitespace = 1 << 1,
};

/// Result structure for FFI functions that return allocated data
pub const FFIResult = extern struct {
    data: ?[*]u8, // NULL on error
    len: usize, // Length of data, or 0 on error
    error_code: c_int, // 0 = success, non-zero = error
};

// Use page allocator for FFI - simple and doesn't require libc
const ffi_allocator = std.heap.page_allocator;

/// Free memory allocated by pb_encode, pb_decode, or pb_format
export fn pb_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    if (ptr) |p| {
        ffi_allocator.free(p[0..len]);
    }
}

/// C ABI export for encode function
/// Caller must call pb_free() on result.data when done
export fn pb_encode(
    input: [*]const u8,
    input_len: usize,
    flags: c_uint,
    preserve_chars: ?[*]const u8,
    preserve_chars_len: usize,
) callconv(.c) FFIResult {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    const preserve_slice = if (preserve_chars != null and preserve_chars_len > 0)
        preserve_chars.?[0..preserve_chars_len]
    else
        &[_]u8{};

    const options = EncodeOptions{
        .spaces = (flags & @intFromEnum(EncodeFlags.preserve_spaces)) != 0,
        .tabs = (flags & @intFromEnum(EncodeFlags.preserve_tabs)) != 0,
        .crlf = (flags & @intFromEnum(EncodeFlags.preserve_crlf)) != 0,
        .preserve_chars = preserve_slice,
    };

    const result = encode(ffi_allocator, input_slice, options) catch {
        return FFIResult{ .data = null, .len = 0, .error_code = 1 };
    };

    return FFIResult{
        .data = result.ptr,
        .len = result.len,
        .error_code = 0,
    };
}

/// C ABI export for decode function
/// Caller must call pb_free() on result.data when done
export fn pb_decode(
    input: [*]const u8,
    input_len: usize,
    flags: c_uint,
) callconv(.c) FFIResult {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};

    const options = DecodeOptions{
        .spaces = (flags & @intFromEnum(DecodeFlags.spaces_mode)) != 0,
        .strip_whitespace = (flags & @intFromEnum(DecodeFlags.strip_whitespace)) != 0,
    };

    const result = decode(ffi_allocator, input_slice, options) catch {
        return FFIResult{ .data = null, .len = 0, .error_code = 1 };
    };

    return FFIResult{
        .data = result.ptr,
        .len = result.len,
        .error_code = 0,
    };
}

/// C ABI export for format function
/// Caller must call pb_free() on result.data when done
export fn pb_format(
    input: [*]const u8,
    input_len: usize,
    group_size: usize,
    groups_per_line: usize,
    use_tabs: c_int,
) callconv(.c) FFIResult {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};

    const options = FormatOptions{
        .group_size = if (group_size > 0) group_size else 8,
        .groups_per_line = if (groups_per_line > 0) groups_per_line else 10,
        .use_tabs = use_tabs != 0,
    };

    const result = format(ffi_allocator, input_slice, options) catch {
        return FFIResult{ .data = null, .len = 0, .error_code = 1 };
    };

    return FFIResult{
        .data = result.ptr,
        .len = result.len,
        .error_code = 0,
    };
}

/// Get the mapping for a byte value (returns pointer to static data, do not free)
export fn pb_get_mapping(byte: u8) callconv(.c) [*]const u8 {
    return character_map[byte].ptr;
}

/// Get the length of a mapping for a byte value
export fn pb_get_mapping_len(byte: u8) callconv(.c) usize {
    return character_map[byte].len;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "applyRange: no range specified returns full input" {
    const r = applyRange(100, null, null);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 100), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

test "applyRange: explicit start and end" {
    const r = applyRange(100, 10, 19);
    try std.testing.expectEqual(@as(usize, 10), r.offset);
    try std.testing.expectEqual(@as(usize, 10), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

test "applyRange: negative start counts from end" {
    const r = applyRange(100, -10, null);
    try std.testing.expectEqual(@as(usize, 90), r.offset);
    try std.testing.expectEqual(@as(usize, 10), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

test "applyRange: negative start beyond input clamps to 0" {
    const r = applyRange(10, -20, null);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 10), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

test "applyRange: start exceeds input length" {
    const r = applyRange(10, 15, null);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 0), r.length);
    try std.testing.expectEqual(RangeWarning.start_exceeds_input, r.warning);
}

test "applyRange: start equals input length" {
    const r = applyRange(10, 10, null);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 0), r.length);
    try std.testing.expectEqual(RangeWarning.start_exceeds_input, r.warning);
}

test "applyRange: start > end yields empty range" {
    const r = applyRange(100, 50, 40);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 0), r.length);
    try std.testing.expectEqual(RangeWarning.empty_range, r.warning);
}

test "applyRange: end exceeds input is clamped" {
    const r = applyRange(10, 5, 20);
    try std.testing.expectEqual(@as(usize, 5), r.offset);
    try std.testing.expectEqual(@as(usize, 5), r.length);
    try std.testing.expectEqual(RangeWarning.end_clamped, r.warning);
}

test "applyRange: zero-length input returns empty" {
    const r = applyRange(0, null, null);
    try std.testing.expectEqual(@as(usize, 0), r.offset);
    try std.testing.expectEqual(@as(usize, 0), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

test "applyRange: single byte range" {
    const r = applyRange(100, 42, 42);
    try std.testing.expectEqual(@as(usize, 42), r.offset);
    try std.testing.expectEqual(@as(usize, 1), r.length);
    try std.testing.expectEqual(RangeWarning.none, r.warning);
}

// =============================================================================
// Double-Encoding Detection Tests
// =============================================================================

test "detectDoubleEncode: empty input returns not detected" {
    const r = detectDoubleEncode("", 0.05);
    try std.testing.expectEqual(@as(c_int, 0), r.detected);
    try std.testing.expect(r.confidence == 0.0);
}

test "detectDoubleEncode: pure ASCII not detected" {
    const r = detectDoubleEncode("Hello World this is plain ASCII text", 0.05);
    try std.testing.expectEqual(@as(c_int, 0), r.detected);
}

test "detectDoubleEncode: encoded control chars detected" {
    // Encode bytes 0x00-0x0F — all are high-confidence
    const allocator = std.testing.allocator;
    var input_bytes: [16]u8 = undefined;
    for (0..16) |i| {
        input_bytes[i] = @intCast(i);
    }
    const encoded = try encode(allocator, &input_bytes, .{});
    defer allocator.free(encoded);

    const r = detectDoubleEncode(encoded, 0.05);
    try std.testing.expectEqual(@as(c_int, 1), r.detected);
    try std.testing.expect(r.confidence > 0.5);
}

test "detectDoubleEncode: low percentage not detected" {
    // One middle-dot (·, PB for NUL) among many plain ASCII chars
    const input = "This is mostly ASCII with one middot \xc2\xb7 character in a very long string of text that goes on and on";
    const r = detectDoubleEncode(input, 0.05);
    try std.testing.expectEqual(@as(c_int, 0), r.detected);
}

test "detectDoubleEncode: threshold boundary" {
    // 6 high-confidence glyphs among ~94 ASCII chars = ~6.4%
    // · = \xc2\xb7, ¯ = \xc2\xaf, « = \xc2\xab, » = \xc2\xbb, ϟ = \xcf\x9f, ¿ = \xc2\xbf
    const input = "aaaaaaaaaa\xc2\xb7\xc2\xaf\xc2\xab\xc2\xbb\xcf\x9f\xc2\xbfaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const r = detectDoubleEncode(input, 0.05);
    try std.testing.expectEqual(@as(c_int, 1), r.detected);
    try std.testing.expect(r.confidence > 0.05);
}

// =============================================================================
// Encode/Decode Correctness Tests (optimization regression suite)
// =============================================================================

test "encode: empty input returns empty output" {
    const allocator = std.testing.allocator;
    const result = try encode(allocator, "", .{});
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decode: empty input returns empty output" {
    const allocator = std.testing.allocator;
    const result = try decode(allocator, "", .{});
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "encode: single byte roundtrips for all 256 values" {
    const allocator = std.testing.allocator;
    for (0..256) |i| {
        const byte = [_]u8{@intCast(i)};
        const encoded = try encode(allocator, &byte, .{});
        defer allocator.free(encoded);
        // Encoded must be valid UTF-8
        try std.testing.expect(std.unicode.utf8ValidateSlice(encoded));
        // Must roundtrip
        const decoded = try decode(allocator, encoded, .{});
        defer allocator.free(decoded);
        try std.testing.expectEqual(@as(usize, 1), decoded.len);
        try std.testing.expectEqual(byte[0], decoded[0]);
    }
}

test "encode/decode: full 256-byte roundtrip" {
    const allocator = std.testing.allocator;
    var input: [256]u8 = undefined;
    for (0..256) |i| {
        input[i] = @intCast(i);
    }
    const encoded = try encode(allocator, &input, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded));

    const decoded = try decode(allocator, encoded, .{});
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "encode: ASCII passthrough characters are preserved" {
    const allocator = std.testing.allocator;
    // Characters 0x2E (.), 0x30-0x39 (0-9), 0x3B (;), 0x40 (@),
    // 0x41-0x5A (A-Z), 0x5E (^), 0x5F (_), 0x61-0x7A (a-z)
    const input = "Hello.World@123";
    const encoded = try encode(allocator, input, .{});
    defer allocator.free(encoded);
    // These ASCII chars should pass through (their map entry equals themselves)
    try std.testing.expectEqualStrings("Hello.World@123", encoded);
}

test "encode: spaces option preserves literal spaces" {
    const allocator = std.testing.allocator;
    const input = "A B";
    const with_spaces = try encode(allocator, input, .{ .spaces = true });
    defer allocator.free(with_spaces);
    try std.testing.expect(std.mem.indexOf(u8, with_spaces, " ") != null);

    const without_spaces = try encode(allocator, input, .{});
    defer allocator.free(without_spaces);
    // Without spaces option, space (0x20) becomes ␣
    try std.testing.expect(std.mem.indexOf(u8, without_spaces, " ") == null);
}

test "decode: unrecognized UTF-8 passes through" {
    const allocator = std.testing.allocator;
    // Use a valid UTF-8 character that's NOT in the decode map
    // The emoji snowman (☃ = E2 98 83) should not be in the PB map
    const input = "\xe2\x98\x83";
    const decoded = try decode(allocator, input, .{});
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "decode: mixed known and unknown UTF-8" {
    const allocator = std.testing.allocator;
    // "Hello" in PB + an unknown character + "World" in PB
    const hello_encoded = try encode(allocator, "Hello", .{});
    defer allocator.free(hello_encoded);
    const world_encoded = try encode(allocator, "World", .{});
    defer allocator.free(world_encoded);

    // Interleave with snowman
    var mixed: std.ArrayListUnmanaged(u8) = .{};
    defer mixed.deinit(allocator);
    try mixed.appendSlice(allocator, hello_encoded);
    try mixed.appendSlice(allocator, "\xe2\x98\x83"); // snowman
    try mixed.appendSlice(allocator, world_encoded);

    const decoded = try decode(allocator, mixed.items, .{});
    defer allocator.free(decoded);
    // Should get: Hello + snowman bytes + World
    try std.testing.expect(std.mem.startsWith(u8, decoded, "Hello"));
    try std.testing.expect(std.mem.endsWith(u8, decoded, "World"));
}

test "encode/decode: large input roundtrip (64KB)" {
    const allocator = std.testing.allocator;
    const size = 64 * 1024;
    var input = try allocator.alloc(u8, size);
    defer allocator.free(input);
    // Fill with a repeating pattern covering all byte values
    for (0..size) |i| {
        input[i] = @intCast(i % 256);
    }

    const encoded = try encode(allocator, input, .{});
    defer allocator.free(encoded);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded));

    const decoded = try decode(allocator, encoded, .{});
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "decode: strip whitespace option" {
    const allocator = std.testing.allocator;
    const input = "Hello";
    const encoded = try encode(allocator, input, .{});
    defer allocator.free(encoded);

    // Insert whitespace
    var with_ws: std.ArrayListUnmanaged(u8) = .{};
    defer with_ws.deinit(allocator);
    try with_ws.appendSlice(allocator, encoded);
    try with_ws.insertSlice(allocator, 2, "\n  \t");

    const decoded = try decode(allocator, with_ws.items, .{ .strip_whitespace = true });
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("Hello", decoded);
}

test "format: basic grouping" {
    const allocator = std.testing.allocator;
    const input = "ABCDEFGHIJKLMNOP"; // 16 ASCII chars
    const formatted = try format(allocator, input, .{ .group_size = 4, .groups_per_line = 2 });
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("ABCD EFGH\nIJKL MNOP", formatted);
}

test "decodeLookup: every character_map entry has a valid reverse lookup" {
    for (0..256) |i| {
        const utf8 = character_map[i];
        const result = decodeLookup(utf8);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(@as(u8, @intCast(i)), result.?);
    }
}
