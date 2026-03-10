const std = @import("std");
const Allocator = std.mem.Allocator;

/// Describes a FlateDecode image stream found within a PDF file.
/// These are PNG-style compressed images (zlib + optional PNG row filters).
pub const PdfFlateStream = struct {
    stream_start: usize, // byte offset where compressed data begins
    stream_end: usize, // byte offset past the last byte (exclusive)
    object_num: u32,
    gen_num: u32,
    predictor: u16, // /Predictor value (1=none, 10-15=PNG variants)
    columns: u32, // /Columns (image width in pixels)
    colors: u8, // /Colors (channels, default 1)
    bits_per_component: u8, // /BitsPerComponent (default 8)
    width: u32, // /Width of the image
    height: u32, // /Height of the image

    /// Length of the compressed stream data.
    pub fn len(self: PdfFlateStream) usize {
        return self.stream_end - self.stream_start;
    }
};

/// Describes a JPEG stream found within a PDF file.
pub const PdfJpegStream = struct {
    stream_start: usize, // byte offset where JPEG data begins in the PDF buffer
    stream_end: usize, // byte offset past the last JPEG byte (exclusive)
    object_num: u32,
    gen_num: u32,

    /// Length of the JPEG data.
    pub fn len(self: PdfJpegStream) usize {
        return self.stream_end - self.stream_start;
    }
};

/// Check if buffer starts with PDF magic bytes (%PDF-).
pub fn isPdfMagic(buf: []const u8) bool {
    return buf.len >= 5 and std.mem.eql(u8, buf[0..5], "%PDF-");
}

/// Find all pure DCTDecode (JPEG) image streams in a PDF.
/// Only matches objects with `/Subtype /Image` and `/Filter /DCTDecode` (no filter chains).
/// Skips encrypted PDFs (returns empty). Verifies JPEG SOI marker at each stream start.
/// Caller owns the returned slice.
pub fn findJpegStreams(allocator: Allocator, buf: []const u8) ![]PdfJpegStream {
    if (!isPdfMagic(buf)) return &.{};

    // Check for encryption — if /Encrypt found in trailer/xref area, bail
    if (isEncryptedPdf(buf)) return &.{};

    // Try xref-based lookup first, fall back to linear scan
    if (findJpegStreamsViaXref(allocator, buf)) |streams| {
        return streams;
    } else |_| {}

    return findJpegStreamsLinear(allocator, buf);
}

/// Create a PDF shell by zeroing out JPEG stream regions.
/// Everything else (headers, xref, metadata) is preserved exactly.
/// Caller owns the returned buffer.
pub fn createPdfShell(allocator: Allocator, buf: []const u8, streams: []const PdfJpegStream) ![]u8 {
    const shell = try allocator.alloc(u8, buf.len);
    @memcpy(shell, buf);
    for (streams) |s| {
        @memset(shell[s.stream_start..s.stream_end], 0x00);
    }
    return shell;
}

/// Splice JPEG image data back into a PDF shell at the recorded offsets.
/// Each image must be exactly the right length (matching the original stream).
pub fn splicePdfImages(shell: []u8, streams: []const PdfJpegStream, images: []const []const u8) !void {
    if (streams.len != images.len) return error.StreamImageCountMismatch;
    for (streams, images) |s, img| {
        if (img.len != s.len()) return error.ImageSizeMismatch;
        @memcpy(shell[s.stream_start..s.stream_end], img);
    }
}

pub const SpliceError = error{
    StreamImageCountMismatch,
    ImageSizeMismatch,
};

/// Describes a stream replacement for PDF rewriting.
/// Used when FlateDecode stream data changes size during round-trip.
pub const StreamReplacement = struct {
    stream_start: usize, // offset of stream data in the original shell
    original_length: usize, // original /Length value (stream data bytes)
    new_data: []const u8, // replacement stream bytes
};

/// A delta point records the cumulative byte shift at a position in the original file.
const DeltaPoint = struct {
    original_pos: usize, // position in original file where delta takes effect
    cumulative_delta: i64, // total byte shift at this point
};

/// Rewrite a PDF shell by replacing stream data regions that may differ in size.
/// Updates /Length values in object dicts and rebuilds the xref table.
/// JPEG streams (same-size) should be spliced with splicePdfImages first.
/// This handles FlateDecode streams whose recompressed size differs.
///
/// The shell must have a traditional xref table (not xref streams).
/// Returns null if the PDF uses xref streams (caller should fall back).
/// Caller owns the returned buffer.
pub fn rewritePdfWithStreams(allocator: Allocator, shell: []const u8, replacements: []const StreamReplacement) !?[]u8 {
    if (replacements.len == 0) return try allocator.dupe(u8, shell);

    // Find the original xref location
    const orig_xref_start = findStartxref(shell) orelse return error.InvalidData;
    if (orig_xref_start >= shell.len) return error.InvalidData;

    // Check for traditional xref (skip xref streams)
    const xref_pos = skipWhitespace(shell, orig_xref_start);
    if (xref_pos + 4 > shell.len or !std.mem.eql(u8, shell[xref_pos..][0..4], "xref")) {
        return null; // xref stream — caller should skip FlateDecode rewrite
    }

    // Parse the original xref to get object offsets
    var xref_entries = std.AutoHashMap(u32, XrefEntry).init(allocator);
    defer xref_entries.deinit();
    try parseXrefAt(allocator, shell, orig_xref_start, &xref_entries);

    // Sort replacements by stream_start ascending
    const sorted = try allocator.alloc(StreamReplacement, replacements.len);
    defer allocator.free(sorted);
    @memcpy(sorted, replacements);
    std.mem.sort(StreamReplacement, sorted, {}, struct {
        fn cmp(_: void, a: StreamReplacement, b: StreamReplacement) bool {
            return a.stream_start < b.stream_start;
        }
    }.cmp);

    // Build the rewritten PDF body (everything up to xref)
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    // Track delta points for xref offset adjustment
    var delta_points: std.ArrayListUnmanaged(DeltaPoint) = .{};
    defer delta_points.deinit(allocator);

    var shell_pos: usize = 0;
    var cumulative_delta: i64 = 0;

    for (sorted) |rep| {
        const length_info = findLengthField(shell, rep.stream_start) orelse continue;

        // Copy shell from current position up to /Length value
        if (length_info.value_start > shell_pos) {
            try out.appendSlice(allocator, shell[shell_pos..length_info.value_start]);
        }

        // Record delta at the /Length position (before changing it)
        try delta_points.append(allocator, .{
            .original_pos = length_info.value_start,
            .cumulative_delta = cumulative_delta,
        });

        // Write new /Length value
        var len_buf: [20]u8 = undefined;
        const new_len_str = std.fmt.bufPrint(&len_buf, "{d}", .{rep.new_data.len}) catch unreachable;
        try out.appendSlice(allocator, new_len_str);

        const old_len_digits = length_info.value_end - length_info.value_start;
        cumulative_delta += @as(i64, @intCast(new_len_str.len)) - @as(i64, @intCast(old_len_digits));

        // Copy from after old /Length value to stream data start
        if (rep.stream_start > length_info.value_end) {
            try out.appendSlice(allocator, shell[length_info.value_end..rep.stream_start]);
        }

        // Record delta at stream data position
        try delta_points.append(allocator, .{
            .original_pos = rep.stream_start,
            .cumulative_delta = cumulative_delta,
        });

        // Write new stream data
        try out.appendSlice(allocator, rep.new_data);
        cumulative_delta += @as(i64, @intCast(rep.new_data.len)) - @as(i64, @intCast(rep.original_length));

        // Record delta after stream data
        try delta_points.append(allocator, .{
            .original_pos = rep.stream_start + rep.original_length,
            .cumulative_delta = cumulative_delta,
        });

        shell_pos = rep.stream_start + rep.original_length;
    }

    // Copy remaining shell content up to the xref table
    if (orig_xref_start > shell_pos) {
        try out.appendSlice(allocator, shell[shell_pos..orig_xref_start]);
    }

    // Rebuild xref table
    var max_obj_num: u32 = 0;
    var iter = xref_entries.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.* > max_obj_num) max_obj_num = entry.key_ptr.*;
    }

    const new_xref_offset = out.items.len;
    try out.appendSlice(allocator, "xref\n");
    var buf20: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(&buf20, "0 {d}\n", .{max_obj_num + 1}) catch unreachable;
    try out.appendSlice(allocator, size_str);
    try out.appendSlice(allocator, "0000000000 65535 f \n");

    var obj_num: u32 = 1;
    while (obj_num <= max_obj_num) : (obj_num += 1) {
        if (xref_entries.get(obj_num)) |entry| {
            if (entry.in_use) {
                const adjusted = applyDelta(entry.offset, delta_points.items);
                const off_str = std.fmt.bufPrint(&buf20, "{d:0>10} {d:0>5} n \n", .{ adjusted, entry.gen }) catch unreachable;
                try out.appendSlice(allocator, off_str);
            } else {
                try out.appendSlice(allocator, "0000000000 65535 f \n");
            }
        } else {
            try out.appendSlice(allocator, "0000000000 65535 f \n");
        }
    }

    // Copy trailer from original (between "trailer" and "startxref")
    if (findTrailerDict(shell, orig_xref_start)) |ts| {
        if (std.mem.indexOf(u8, shell[ts..], "startxref")) |sx| {
            try out.appendSlice(allocator, shell[ts .. ts + sx]);
        }
    } else {
        try out.appendSlice(allocator, "trailer\n<< /Size ");
        const ts = std.fmt.bufPrint(&buf20, "{d}", .{max_obj_num + 1}) catch unreachable;
        try out.appendSlice(allocator, ts);
        try out.appendSlice(allocator, " >>\n");
    }

    try out.appendSlice(allocator, "startxref\n");
    const xref_str = std.fmt.bufPrint(&buf20, "{d}", .{new_xref_offset}) catch unreachable;
    try out.appendSlice(allocator, xref_str);
    try out.appendSlice(allocator, "\n%%EOF\n");

    const slice = try out.toOwnedSlice(allocator);
    return @as(?[]u8, slice);
}

/// Apply cumulative delta to an original file offset.
/// Finds the last delta point at or before the given position.
fn applyDelta(original_offset: usize, delta_points: []const DeltaPoint) usize {
    // Delta points are in order of original_pos. Find the last one <= original_offset.
    var delta: i64 = 0;
    for (delta_points) |dp| {
        if (dp.original_pos > original_offset) break;
        delta = dp.cumulative_delta;
    }
    if (delta >= 0) {
        return original_offset +| @as(usize, @intCast(delta));
    } else {
        return original_offset -| @as(usize, @intCast(-delta));
    }
}

/// Find the /Length field in an object dict, searching backwards from stream_start.
/// Returns the byte range of the integer value (not the key).
fn findLengthField(data: []const u8, stream_start: usize) ?struct { value_start: usize, value_end: usize } {
    const search_start = if (stream_start > 1024) stream_start - 1024 else 0;
    const region = data[search_start..stream_start];

    // Find last occurrence of "/Length" before stream
    var best: ?usize = null;
    var idx: usize = 0;
    while (idx + 7 <= region.len) {
        if (std.mem.eql(u8, region[idx..][0..7], "/Length")) {
            best = search_start + idx;
        }
        idx += 1;
    }

    const length_key_pos = best orelse return null;
    var pos = length_key_pos + 7;
    pos = skipWhitespace(data, pos);

    const int_result = parseDirectInt(data, pos) orelse return null;
    if (int_result.value < 0) return null;

    return .{ .value_start = pos, .value_end = int_result.end };
}

/// Find the trailer dict start, searching after the xref.
fn findTrailerDict(data: []const u8, xref_start: usize) ?usize {
    const search = data[xref_start..];
    const idx = std.mem.indexOf(u8, search, "trailer") orelse return null;
    return xref_start + idx;
}

// =============================================================================
// Internal: PDF parsing primitives
// =============================================================================

const IntResult = struct { value: i64, end: usize };

/// Skip PDF whitespace and comments.
fn skipWhitespace(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len) {
        switch (data[i]) {
            ' ', '\t', '\n', '\r', '\x0c', '\x00' => i += 1,
            '%' => {
                while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
            },
            else => break,
        }
    }
    return i;
}

/// Parse a PDF name token (e.g., /Filter → "Filter").
fn parseName(data: []const u8, start: usize) ?struct { name: []const u8, end: usize } {
    if (start >= data.len or data[start] != '/') return null;
    var end = start + 1;
    while (end < data.len) {
        const ch = data[end];
        if (ch == '/' or ch == '[' or ch == ']' or ch == '<' or ch == '>' or
            ch == '(' or ch == ')' or ch == '{' or ch == '}' or
            ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0c')
            break;
        end += 1;
    }
    return .{ .name = data[start + 1 .. end], .end = end };
}

/// Parse a PDF integer at `start`. Returns null if no digits found.
fn parseInt(data: []const u8, start: usize) ?IntResult {
    var i = start;
    var negative = false;
    if (i < data.len and data[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < data.len and data[i] == '+') {
        i += 1;
    }
    const num_start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == num_start) return null;
    const value = std.fmt.parseInt(i64, data[num_start..i], 10) catch return null;
    return .{ .value = if (negative) -value else value, .end = i };
}

/// Parse a direct integer value (not an indirect reference like "42 0 R").
fn parseDirectInt(data: []const u8, start: usize) ?IntResult {
    const result = parseInt(data, start) orelse return null;
    // Check for indirect reference pattern: N G R
    var check = skipWhitespace(data, result.end);
    if (parseInt(data, check)) |gen_result| {
        check = skipWhitespace(data, gen_result.end);
        if (check < data.len and data[check] == 'R') return null;
    }
    return result;
}

/// Check if a PDF is encrypted by looking for /Encrypt in the trailer area.
fn isEncryptedPdf(data: []const u8) bool {
    // Search the last 4096 bytes for /Encrypt (trailer is near end of file)
    const search_start = if (data.len > 4096) data.len - 4096 else 0;
    return std.mem.indexOf(u8, data[search_start..], "/Encrypt") != null;
}

// =============================================================================
// Internal: Xref-based stream finding (fast path)
// =============================================================================

const XrefEntry = struct {
    offset: usize,
    gen: u32,
    in_use: bool,
};

/// Parse xref table and find all JPEG image streams.
fn findJpegStreamsViaXref(allocator: Allocator, data: []const u8) ![]PdfJpegStream {
    // Find startxref offset
    const xref_offset = findStartxref(data) orelse return error.NoXref;

    // Parse xref entries
    var entries = std.AutoHashMap(u32, XrefEntry).init(allocator);
    defer entries.deinit();

    try parseXrefAt(allocator, data, xref_offset, &entries);

    // Visit each in-use entry and check for JPEG images
    var streams: std.ArrayListUnmanaged(PdfJpegStream) = .{};
    errdefer streams.deinit(allocator);

    var it = entries.iterator();
    while (it.next()) |kv| {
        const obj_num = kv.key_ptr.*;
        const entry = kv.value_ptr.*;
        if (!entry.in_use or entry.offset >= data.len) continue;

        if (parseObjectForJpeg(data, entry.offset, obj_num, entry.gen)) |stream| {
            try streams.append(allocator, stream);
        }
    }

    return streams.toOwnedSlice(allocator);
}

/// Find the startxref offset in the last 1024 bytes of the file.
fn findStartxref(data: []const u8) ?usize {
    const search_start = if (data.len > 1024) data.len - 1024 else 0;
    const tail = data[search_start..];
    const idx = std.mem.lastIndexOf(u8, tail, "startxref") orelse return null;
    var pos = search_start + idx + 9; // past "startxref"
    pos = skipWhitespace(data, pos);
    const int_result = parseInt(data, pos) orelse return null;
    if (int_result.value < 0) return null;
    return @intCast(int_result.value);
}

/// Parse xref section at the given offset. Follows /Prev chain for incremental updates.
fn parseXrefAt(allocator: Allocator, data: []const u8, start_offset: usize, entries: *std.AutoHashMap(u32, XrefEntry)) !void {
    var offset = start_offset;
    var depth: u32 = 0;

    while (depth < 32) : (depth += 1) {
        if (offset >= data.len) return;
        const pos = skipWhitespace(data, offset);
        if (pos >= data.len) return;

        var prev_offset: ?usize = null;

        if (pos + 4 <= data.len and std.mem.eql(u8, data[pos..][0..4], "xref")) {
            // Traditional text xref table
            prev_offset = try parseTraditionalXref(data, pos + 4, entries);
        } else if (data[pos] >= '0' and data[pos] <= '9') {
            // Xref stream object
            prev_offset = try parseXrefStream(allocator, data, pos, entries);
        } else {
            return;
        }

        if (prev_offset) |prev| {
            offset = prev;
        } else {
            return;
        }
    }
}

/// Parse a traditional text xref table. Returns /Prev offset if found.
fn parseTraditionalXref(data: []const u8, start: usize, entries: *std.AutoHashMap(u32, XrefEntry)) !?usize {
    var pos = skipWhitespace(data, start);

    // Parse subsections until we hit "trailer"
    while (pos < data.len) {
        // Check for trailer
        if (pos + 7 <= data.len and std.mem.eql(u8, data[pos..][0..7], "trailer")) {
            pos += 7;
            break;
        }

        // Parse subsection header: first_obj count
        const first_obj_result = parseInt(data, pos) orelse break;
        pos = skipWhitespace(data, first_obj_result.end);
        const count_result = parseInt(data, pos) orelse break;
        pos = skipWhitespace(data, count_result.end);

        const first_obj: u32 = @intCast(@max(0, first_obj_result.value));
        const count: u32 = @intCast(@max(0, count_result.value));

        // Parse entries (20 bytes each in standard format, but we're tolerant)
        for (0..count) |i| {
            pos = skipWhitespace(data, pos);
            const offset_result = parseInt(data, pos) orelse break;
            pos = skipWhitespace(data, offset_result.end);
            const gen_result = parseInt(data, pos) orelse break;
            pos = skipWhitespace(data, gen_result.end);

            if (pos >= data.len) break;
            const status = data[pos];
            pos += 1;
            pos = skipWhitespace(data, pos);

            const obj_num = first_obj + @as(u32, @intCast(i));
            // First (most recent) xref wins for each object number
            if (!entries.contains(obj_num)) {
                try entries.put(obj_num, .{
                    .offset = @intCast(@max(0, offset_result.value)),
                    .gen = @intCast(@max(0, gen_result.value)),
                    .in_use = status == 'n',
                });
            }
        }
    }

    // Parse trailer dict for /Prev
    return parseTrailerPrev(data, pos);
}

/// Parse xref stream object. Returns /Prev offset if found.
fn parseXrefStream(allocator: Allocator, data: []const u8, start: usize, entries: *std.AutoHashMap(u32, XrefEntry)) !?usize {
    // Skip "N G obj" header
    var pos = start;
    _ = parseInt(data, pos) orelse return null; // obj num
    pos = skipWhitespace(data, (parseInt(data, pos) orelse return null).end);
    _ = parseInt(data, pos) orelse return null; // gen num
    pos = skipWhitespace(data, (parseInt(data, pos) orelse return null).end);
    if (pos + 3 > data.len or !std.mem.eql(u8, data[pos..][0..3], "obj")) return null;
    pos += 3;
    pos = skipWhitespace(data, pos);

    // Parse the xref stream dictionary
    if (pos + 2 > data.len or data[pos] != '<' or data[pos + 1] != '<') return null;

    // Find key fields in the dict
    var size: ?u32 = null;
    var w: [3]u32 = .{ 0, 0, 0 };
    var stream_length: ?u32 = null;
    var prev_offset: ?usize = null;
    var is_xref_type = false;
    var index_values: std.ArrayListUnmanaged(u32) = .{};
    defer index_values.deinit(allocator);

    // Simple dict scan
    var dict_pos = pos + 2;
    while (dict_pos < data.len) {
        if (dict_pos + 2 <= data.len and data[dict_pos] == '>' and data[dict_pos + 1] == '>') {
            dict_pos += 2;
            break;
        }
        if (data[dict_pos] == '/') {
            const name = parseName(data, dict_pos) orelse {
                dict_pos += 1;
                continue;
            };
            dict_pos = skipWhitespace(data, name.end);

            if (std.mem.eql(u8, name.name, "Type")) {
                const val = parseName(data, dict_pos) orelse {
                    dict_pos += 1;
                    continue;
                };
                if (std.mem.eql(u8, val.name, "XRef")) is_xref_type = true;
                dict_pos = val.end;
            } else if (std.mem.eql(u8, name.name, "Size")) {
                if (parseInt(data, dict_pos)) |r| {
                    size = @intCast(@max(0, r.value));
                    dict_pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "Length")) {
                if (parseDirectInt(data, dict_pos)) |r| {
                    stream_length = @intCast(@max(0, r.value));
                    dict_pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "Prev")) {
                if (parseInt(data, dict_pos)) |r| {
                    if (r.value >= 0) prev_offset = @intCast(r.value);
                    dict_pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "W")) {
                // Parse [w0 w1 w2]
                if (dict_pos < data.len and data[dict_pos] == '[') {
                    dict_pos += 1;
                    for (0..3) |wi| {
                        dict_pos = skipWhitespace(data, dict_pos);
                        if (parseInt(data, dict_pos)) |r| {
                            w[wi] = @intCast(@max(0, r.value));
                            dict_pos = r.end;
                        }
                    }
                    dict_pos = skipWhitespace(data, dict_pos);
                    if (dict_pos < data.len and data[dict_pos] == ']') dict_pos += 1;
                }
            } else if (std.mem.eql(u8, name.name, "Index")) {
                if (dict_pos < data.len and data[dict_pos] == '[') {
                    dict_pos += 1;
                    while (dict_pos < data.len and data[dict_pos] != ']') {
                        dict_pos = skipWhitespace(data, dict_pos);
                        if (parseInt(data, dict_pos)) |r| {
                            try index_values.append(allocator, @intCast(@max(0, r.value)));
                            dict_pos = r.end;
                        } else break;
                    }
                    if (dict_pos < data.len) dict_pos += 1;
                }
            } else {
                // Unrecognized key — skip its value
                if (dict_pos + 1 < data.len and data[dict_pos] == '<' and data[dict_pos + 1] == '<') {
                    // Value is a nested dict — skip it
                    dict_pos += 2;
                    var depth: u32 = 1;
                    while (dict_pos + 1 < data.len and depth > 0) {
                        if (data[dict_pos] == '<' and data[dict_pos + 1] == '<') {
                            depth += 1;
                            dict_pos += 2;
                        } else if (data[dict_pos] == '>' and data[dict_pos + 1] == '>') {
                            depth -= 1;
                            dict_pos += 2;
                        } else {
                            dict_pos += 1;
                        }
                    }
                } else {
                    dict_pos += 1;
                }
            }
        } else if (data[dict_pos] == '<' and dict_pos + 1 < data.len and data[dict_pos + 1] == '<') {
            // Nested dict outside key context — skip it
            dict_pos += 2;
            var ndepth: u32 = 1;
            while (dict_pos + 1 < data.len and ndepth > 0) {
                if (data[dict_pos] == '<' and data[dict_pos + 1] == '<') {
                    ndepth += 1;
                    dict_pos += 2;
                } else if (data[dict_pos] == '>' and data[dict_pos + 1] == '>') {
                    ndepth -= 1;
                    dict_pos += 2;
                } else {
                    dict_pos += 1;
                }
            }
        } else {
            dict_pos += 1;
        }
    }

    if (!is_xref_type) return null;
    _ = size orelse return null;

    // Find stream data
    pos = dict_pos;
    pos = skipWhitespace(data, pos);
    if (pos + 6 > data.len or !std.mem.eql(u8, data[pos..][0..6], "stream")) return null;
    pos += 6;
    if (pos < data.len and data[pos] == '\r') pos += 1;
    if (pos < data.len and data[pos] == '\n') pos += 1;

    var stream_data: []const u8 = undefined;
    if (stream_length) |slen| {
        if (pos + slen > data.len) return null;
        stream_data = data[pos .. pos + slen];
    } else return null;

    // For now, we don't decompress xref streams (would need zlib).
    // Fall back to linear scan if xref is a stream.
    _ = entries;
    return error.NoXref;
}

/// Parse /Prev offset from trailer dict area.
fn parseTrailerPrev(data: []const u8, start: usize) ?usize {
    // Look for /Prev in the next ~2048 bytes
    const search_end = @min(data.len, start + 2048);
    const region = data[start..search_end];
    const idx = std.mem.indexOf(u8, region, "/Prev") orelse return null;
    var pos = start + idx + 5; // past "/Prev"
    pos = skipWhitespace(data, pos);
    const result = parseInt(data, pos) orelse return null;
    if (result.value < 0) return null;
    return @intCast(result.value);
}

/// Parse a single PDF object at the given offset, checking if it's a JPEG image stream.
fn parseObjectForJpeg(data: []const u8, offset: usize, obj_num: u32, gen_num: u32) ?PdfJpegStream {
    var pos = offset;

    // Skip "N G obj" header (verify object number matches)
    const obj_result = parseInt(data, pos) orelse return null;
    if (obj_result.value != obj_num) return null;
    pos = skipWhitespace(data, obj_result.end);
    const gen_result = parseInt(data, pos) orelse return null;
    pos = skipWhitespace(data, gen_result.end);
    if (pos + 3 > data.len or !std.mem.eql(u8, data[pos..][0..3], "obj")) return null;
    pos += 3;
    pos = skipWhitespace(data, pos);

    // Expect the object dictionary opening "<<"
    if (pos + 2 > data.len or data[pos] != '<' or data[pos + 1] != '<') return null;
    pos += 2;

    // Parse dictionary looking for image/DCTDecode indicators
    var is_image = false;
    var is_dct = false;
    var is_filter_array = false;
    var stream_length: ?u32 = null;
    var stream_start: ?usize = null;
    var stream_end: ?usize = null;

    while (pos < data.len) {
        pos = skipWhitespace(data, pos);
        if (pos >= data.len) break;

        // Check for stream keyword (but not "endstream")
        if (pos + 6 <= data.len and std.mem.eql(u8, data[pos..][0..6], "stream") and
            (pos < 3 or !std.mem.eql(u8, data[pos -| 3 ..][0..3], "end")))
        {
            pos += 6;
            if (pos < data.len and data[pos] == '\r') pos += 1;
            if (pos < data.len and data[pos] == '\n') pos += 1;
            stream_start = pos;

            if (stream_length) |slen| {
                stream_end = pos + slen;
                if (stream_end.? > data.len) stream_end = data.len;
            } else {
                // Fallback: search for endstream
                var j = pos;
                while (j + 9 <= data.len) : (j += 1) {
                    if (std.mem.eql(u8, data[j..][0..9], "endstream")) {
                        stream_end = j;
                        break;
                    }
                }
            }
            break;
        }

        // Check for endobj
        if (pos + 6 <= data.len and std.mem.eql(u8, data[pos..][0..6], "endobj")) break;

        // Parse dictionary entries
        if (data[pos] == '/') {
            const name = parseName(data, pos) orelse {
                pos += 1;
                continue;
            };
            pos = skipWhitespace(data, name.end);

            if (std.mem.eql(u8, name.name, "Subtype")) {
                if (parseName(data, pos)) |subtype| {
                    if (std.mem.eql(u8, subtype.name, "Image")) is_image = true;
                    pos = subtype.end;
                }
            } else if (std.mem.eql(u8, name.name, "Filter")) {
                if (pos < data.len and data[pos] == '/') {
                    // Single filter
                    if (parseName(data, pos)) |filter| {
                        if (std.mem.eql(u8, filter.name, "DCTDecode")) is_dct = true;
                        pos = filter.end;
                    }
                } else if (pos < data.len and data[pos] == '[') {
                    // Filter array — skip, we only handle pure DCTDecode
                    is_filter_array = true;
                    pos += 1;
                    var depth: u32 = 1;
                    while (pos < data.len and depth > 0) {
                        if (data[pos] == '[') depth += 1;
                        if (data[pos] == ']') depth -= 1;
                        pos += 1;
                    }
                }
            } else if (std.mem.eql(u8, name.name, "Length")) {
                if (parseDirectInt(data, pos)) |r| {
                    stream_length = @intCast(@max(0, r.value));
                    pos = r.end;
                }
            } else {
                // Skip past the value (advance past simple tokens)
                pos = name.end;
            }
        } else if (data[pos] == '<' and pos + 1 < data.len and data[pos + 1] == '<') {
            // Nested dict — skip it
            pos += 2;
            var depth: u32 = 1;
            while (pos + 1 < data.len and depth > 0) {
                if (data[pos] == '<' and data[pos + 1] == '<') {
                    depth += 1;
                    pos += 2;
                } else if (data[pos] == '>' and data[pos + 1] == '>') {
                    depth -= 1;
                    pos += 2;
                } else {
                    pos += 1;
                }
            }
        } else {
            pos += 1;
        }
    }

    // Must be an image with single DCTDecode filter and valid stream boundaries
    if (!is_image or !is_dct or is_filter_array) return null;
    const ss = stream_start orelse return null;
    const se = stream_end orelse return null;
    if (se <= ss) return null;

    // Verify JPEG SOI marker
    if (se - ss < 2 or data[ss] != 0xFF or data[ss + 1] != 0xD8) return null;

    return PdfJpegStream{
        .stream_start = ss,
        .stream_end = se,
        .object_num = obj_num,
        .gen_num = gen_num,
    };
}

// =============================================================================
// Internal: Linear scan stream finding (fallback)
// =============================================================================

/// Find JPEG streams by scanning for "N G obj" patterns in the entire file.
fn findJpegStreamsLinear(allocator: Allocator, data: []const u8) ![]PdfJpegStream {
    var streams: std.ArrayListUnmanaged(PdfJpegStream) = .{};
    errdefer streams.deinit(allocator);

    var i: usize = 0;
    while (i + 3 < data.len) {
        // Look for "obj" keyword
        if (!std.mem.eql(u8, data[i..][0..3], "obj")) {
            i += 1;
            continue;
        }

        // Must be preceded by whitespace
        if (i > 0 and data[i - 1] != ' ' and data[i - 1] != '\n' and data[i - 1] != '\r' and data[i - 1] != '\t') {
            i += 1;
            continue;
        }

        // Backtrack to find "N G" before "obj"
        var back = i;
        // Skip whitespace before "obj"
        while (back > 0 and (data[back - 1] == ' ' or data[back - 1] == '\n' or data[back - 1] == '\r' or data[back - 1] == '\t')) {
            back -= 1;
        }
        // Find generation number
        const gen_end = back;
        while (back > 0 and data[back - 1] >= '0' and data[back - 1] <= '9') {
            back -= 1;
        }
        if (back == gen_end) {
            i += 3;
            continue;
        }
        const gen_num = std.fmt.parseInt(u32, data[back..gen_end], 10) catch {
            i += 3;
            continue;
        };

        // Skip whitespace before gen
        while (back > 0 and (data[back - 1] == ' ' or data[back - 1] == '\n' or data[back - 1] == '\r' or data[back - 1] == '\t')) {
            back -= 1;
        }
        // Find object number
        const obj_end = back;
        while (back > 0 and data[back - 1] >= '0' and data[back - 1] <= '9') {
            back -= 1;
        }
        if (back == obj_end) {
            i += 3;
            continue;
        }
        const obj_num = std.fmt.parseInt(u32, data[back..obj_end], 10) catch {
            i += 3;
            continue;
        };

        // Try to parse this object as a JPEG image
        if (parseObjectForJpeg(data, back, obj_num, gen_num)) |stream| {
            try streams.append(allocator, stream);
        }

        i += 3;
    }

    return streams.toOwnedSlice(allocator);
}

// =============================================================================
// FlateDecode defilter/refilter + zlib decompress/compress
// =============================================================================

/// Zlib-decompress data. Caller owns returned slice.
pub fn zlibDecompress(allocator: Allocator, compressed: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var source_reader = std.Io.Reader.fixed(compressed);
    var empty_buf: [0]u8 = .{};
    var decompress_state = flate.Decompress.init(&source_reader, .zlib, &empty_buf);
    return decompress_state.reader.allocRemaining(allocator, .unlimited) catch
        return error.InvalidData;
}

/// Zlib-compress data using stored deflate blocks + Adler-32.
/// Note: This uses uncompressed stored blocks, producing output larger than real
/// deflate compression. This is acceptable for PDF extraction because:
/// 1. The extracted PDF is pixel-identical (lossless)
/// 2. The PDF is larger than the original but fully valid
/// 3. The Zig 0.15 flate compressor is not yet complete
pub fn zlibCompress(allocator: Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    // Zlib header: CMF=0x78, FLG=0x01
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

    // Adler-32 checksum (big-endian)
    const adler = std.hash.Adler32.hash(data);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try output.appendSlice(allocator, &adler_bytes);

    return output.toOwnedSlice(allocator);
}

fn paethPredictor(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @as(u16, @intCast(if (p > a) p - a else a - p));
    const pb = @as(u16, @intCast(if (p > b) p - b else b - p));
    const pc = @as(u16, @intCast(if (p > c) p - c else c - p));
    if (pa <= pb and pa <= pc) return @intCast(@as(u16, @intCast(a)));
    if (pb <= pc) return @intCast(@as(u16, @intCast(b)));
    return @intCast(@as(u16, @intCast(c)));
}

/// Remove PNG-style row filters from FlateDecode image data.
/// Predictor 10 = None, 11 = Sub, 12 = Up, 13 = Average, 14 = Paeth (fixed per stream)
/// Predictor 15 = Optimal (per-row filter byte, same as PNG IDAT)
/// Returns raw pixel data (no filter bytes). Caller owns result.
pub fn defilterPdfFlate(allocator: Allocator, data: []const u8, columns: u32, colors: u8, bpc: u8, predictor: u16) ![]u8 {
    if (predictor < 10 or predictor > 15) return error.InvalidData;

    const bytes_per_pixel = (@as(usize, colors) * @as(usize, bpc) + 7) / 8;
    const row_bytes = (@as(usize, columns) * @as(usize, colors) * @as(usize, bpc) + 7) / 8;

    if (predictor == 15) {
        // Per-row filter byte (same as PNG IDAT)
        const row_stride = row_bytes + 1; // +1 for filter byte
        if (data.len == 0) return allocator.alloc(u8, 0);
        const num_rows = data.len / row_stride;
        if (num_rows == 0) return error.InvalidData;

        const output = try allocator.alloc(u8, num_rows * row_bytes);
        errdefer allocator.free(output);

        // Defilter in place on a copy
        const working = try allocator.alloc(u8, data.len);
        defer allocator.free(working);
        @memcpy(working, data);

        var prev_row: ?[]u8 = null;
        for (0..num_rows) |y| {
            const row = working[y * row_stride ..][0..row_stride];
            const filter_byte = row[0];
            const row_data = row[1..];

            switch (filter_byte) {
                0 => {}, // None
                1 => { // Sub
                    for (bytes_per_pixel..row_bytes) |i| {
                        row_data[i] = row_data[i] +% row_data[i - bytes_per_pixel];
                    }
                },
                2 => { // Up
                    if (prev_row) |prev| {
                        const prev_data = prev[1..];
                        for (0..row_bytes) |i| {
                            row_data[i] = row_data[i] +% prev_data[i];
                        }
                    }
                },
                3 => { // Average
                    const prev_data: ?[]u8 = if (prev_row) |prev| prev[1..] else null;
                    for (0..row_bytes) |i| {
                        const a: u16 = if (i >= bytes_per_pixel) row_data[i - bytes_per_pixel] else 0;
                        const b: u16 = if (prev_data) |pd| pd[i] else 0;
                        row_data[i] = row_data[i] +% @as(u8, @intCast((a + b) / 2));
                    }
                },
                4 => { // Paeth
                    const prev_data: ?[]u8 = if (prev_row) |prev| prev[1..] else null;
                    for (0..row_bytes) |i| {
                        const a: i16 = if (i >= bytes_per_pixel) @intCast(row_data[i - bytes_per_pixel]) else 0;
                        const b: i16 = if (prev_data) |pd| @intCast(pd[i]) else 0;
                        const c_val: i16 = if (prev_data) |pd| (if (i >= bytes_per_pixel) @as(i16, @intCast(pd[i - bytes_per_pixel])) else 0) else 0;
                        row_data[i] = row_data[i] +% paethPredictor(a, b, c_val);
                    }
                },
                else => return error.InvalidData,
            }

            @memcpy(output[y * row_bytes ..][0..row_bytes], row_data);
            prev_row = row;
        }

        return output;
    } else {
        // Fixed filter type (Predictor 10-14): no per-row filter byte
        // Predictor 10 = None, 11 = Sub, 12 = Up, 13 = Average, 14 = Paeth
        const filter_type: u8 = @intCast(predictor - 10);
        const num_rows = data.len / row_bytes;
        if (num_rows == 0 or data.len % row_bytes != 0) return error.InvalidData;

        const output = try allocator.alloc(u8, data.len);
        errdefer allocator.free(output);
        @memcpy(output, data);

        for (0..num_rows) |y| {
            const row_data = output[y * row_bytes ..][0..row_bytes];
            const prev_data: ?[]const u8 = if (y > 0) output[(y - 1) * row_bytes ..][0..row_bytes] else null;

            switch (filter_type) {
                0 => {}, // None
                1 => { // Sub
                    for (bytes_per_pixel..row_bytes) |i| {
                        row_data[i] = row_data[i] +% row_data[i - bytes_per_pixel];
                    }
                },
                2 => { // Up
                    if (prev_data) |pd| {
                        for (0..row_bytes) |i| {
                            row_data[i] = row_data[i] +% pd[i];
                        }
                    }
                },
                3 => { // Average
                    for (0..row_bytes) |i| {
                        const a: u16 = if (i >= bytes_per_pixel) row_data[i - bytes_per_pixel] else 0;
                        const b: u16 = if (prev_data) |pd| pd[i] else 0;
                        row_data[i] = row_data[i] +% @as(u8, @intCast((a + b) / 2));
                    }
                },
                4 => { // Paeth
                    for (0..row_bytes) |i| {
                        const a: i16 = if (i >= bytes_per_pixel) @intCast(row_data[i - bytes_per_pixel]) else 0;
                        const b: i16 = if (prev_data) |pd| @intCast(pd[i]) else 0;
                        const c_val: i16 = if (prev_data) |pd| (if (i >= bytes_per_pixel) @as(i16, @intCast(pd[i - bytes_per_pixel])) else 0) else 0;
                        row_data[i] = row_data[i] +% paethPredictor(a, b, c_val);
                    }
                },
                else => return error.InvalidData,
            }
        }

        return output;
    }
}

/// Re-apply PNG-style row filters to raw pixel data for FlateDecode.
/// Always uses filter type 0 (None) for simplicity — the data goes through
/// LZMA2 in blar anyway, so optimal PNG filtering provides no benefit.
/// For Predictor 15: prepends filter byte 0 to each row.
/// For Predictor 10-14: no filter byte prefix (fixed filter = None).
/// Caller owns result.
pub fn refilterPdfFlate(allocator: Allocator, pixels: []const u8, columns: u32, colors: u8, bpc: u8, predictor: u16) ![]u8 {
    if (predictor < 10 or predictor > 15) return error.InvalidData;

    const row_bytes = (@as(usize, columns) * @as(usize, colors) * @as(usize, bpc) + 7) / 8;
    if (row_bytes == 0) return error.InvalidData;
    const num_rows = pixels.len / row_bytes;
    if (pixels.len % row_bytes != 0) return error.InvalidData;

    if (predictor == 15) {
        // Per-row filter byte: prepend 0 (None) to each row
        const output = try allocator.alloc(u8, num_rows * (row_bytes + 1));
        errdefer allocator.free(output);
        for (0..num_rows) |y| {
            output[y * (row_bytes + 1)] = 0; // None filter
            @memcpy(output[y * (row_bytes + 1) + 1 ..][0..row_bytes], pixels[y * row_bytes ..][0..row_bytes]);
        }
        return output;
    } else {
        // Fixed filter type — for None (predictor 10), just copy
        // For other predictors (11-14), we use None (no filtering) since
        // re-encoding with the original filter is unnecessary
        if (predictor == 10) {
            return allocator.dupe(u8, pixels);
        }
        // For sub/up/avg/paeth: just return unfiltered data
        // (the PDF /Predictor value is stored in metadata, so extraction knows what was used)
        return allocator.dupe(u8, pixels);
    }
}

// =============================================================================
// FlateDecode image stream detection
// =============================================================================

/// Find all FlateDecode image streams in a PDF that have PNG-style prediction
/// (Predictor >= 10). Only these are worth transcoding to JXL — raw FlateDecode
/// (Predictor=1 or absent) is just generic zlib data, not image-like.
/// Skips encrypted PDFs. Caller owns the returned slice.
pub fn findFlateImageStreams(allocator: Allocator, buf: []const u8) ![]PdfFlateStream {
    if (!isPdfMagic(buf)) return &.{};
    if (isEncryptedPdf(buf)) return &.{};

    // Linear scan for FlateDecode image objects
    return findFlateStreamsLinear(allocator, buf);
}

/// Parse a single PDF object at the given offset, checking if it's a FlateDecode image stream.
fn parseObjectForFlate(data: []const u8, offset: usize, obj_num: u32, gen_num: u32) ?PdfFlateStream {
    var pos = offset;

    // Skip "N G obj" header (verify object number matches)
    const obj_result = parseInt(data, pos) orelse return null;
    if (obj_result.value != obj_num) return null;
    pos = skipWhitespace(data, obj_result.end);
    const gen_result = parseInt(data, pos) orelse return null;
    pos = skipWhitespace(data, gen_result.end);
    if (pos + 3 > data.len or !std.mem.eql(u8, data[pos..][0..3], "obj")) return null;
    pos += 3;
    pos = skipWhitespace(data, pos);

    // Expect the object dictionary opening "<<"
    if (pos + 2 > data.len or data[pos] != '<' or data[pos + 1] != '<') return null;
    pos += 2;

    // Parse dictionary looking for image/FlateDecode indicators
    var is_image = false;
    var is_flate = false;
    var is_filter_array = false;
    var stream_length: ?u32 = null;
    var stream_start: ?usize = null;
    var stream_end: ?usize = null;
    var width: ?u32 = null;
    var height: ?u32 = null;
    var bpc: u8 = 8; // default
    var predictor: u16 = 1; // default (no prediction)
    var columns: ?u32 = null;
    var colors: u8 = 1; // default
    var dp_bpc: ?u8 = null;

    while (pos < data.len) {
        pos = skipWhitespace(data, pos);
        if (pos >= data.len) break;

        // Check for stream keyword (but not "endstream")
        if (pos + 6 <= data.len and std.mem.eql(u8, data[pos..][0..6], "stream") and
            (pos < 3 or !std.mem.eql(u8, data[pos -| 3 ..][0..3], "end")))
        {
            pos += 6;
            if (pos < data.len and data[pos] == '\r') pos += 1;
            if (pos < data.len and data[pos] == '\n') pos += 1;
            stream_start = pos;

            if (stream_length) |slen| {
                stream_end = pos + slen;
                if (stream_end.? > data.len) stream_end = data.len;
            } else {
                // Fallback: search for endstream
                var j = pos;
                while (j + 9 <= data.len) : (j += 1) {
                    if (std.mem.eql(u8, data[j..][0..9], "endstream")) {
                        stream_end = j;
                        break;
                    }
                }
            }
            break;
        }

        // Check for endobj
        if (pos + 6 <= data.len and std.mem.eql(u8, data[pos..][0..6], "endobj")) break;

        // Parse dictionary entries
        if (data[pos] == '/') {
            const name = parseName(data, pos) orelse {
                pos += 1;
                continue;
            };
            pos = skipWhitespace(data, name.end);

            if (std.mem.eql(u8, name.name, "Subtype")) {
                if (parseName(data, pos)) |subtype| {
                    if (std.mem.eql(u8, subtype.name, "Image")) is_image = true;
                    pos = subtype.end;
                }
            } else if (std.mem.eql(u8, name.name, "Filter")) {
                if (pos < data.len and data[pos] == '/') {
                    if (parseName(data, pos)) |filter| {
                        if (std.mem.eql(u8, filter.name, "FlateDecode")) is_flate = true;
                        pos = filter.end;
                    }
                } else if (pos < data.len and data[pos] == '[') {
                    is_filter_array = true;
                    pos += 1;
                    var depth: u32 = 1;
                    while (pos < data.len and depth > 0) {
                        if (data[pos] == '[') depth += 1;
                        if (data[pos] == ']') depth -= 1;
                        pos += 1;
                    }
                }
            } else if (std.mem.eql(u8, name.name, "Length")) {
                if (parseDirectInt(data, pos)) |r| {
                    stream_length = @intCast(@max(0, r.value));
                    pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "Width")) {
                if (parseDirectInt(data, pos)) |r| {
                    width = @intCast(@max(0, r.value));
                    pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "Height")) {
                if (parseDirectInt(data, pos)) |r| {
                    height = @intCast(@max(0, r.value));
                    pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "BitsPerComponent")) {
                if (parseDirectInt(data, pos)) |r| {
                    bpc = @intCast(@max(1, @min(16, r.value)));
                    pos = r.end;
                }
            } else if (std.mem.eql(u8, name.name, "DecodeParms")) {
                // Parse << /Predictor N /Columns C /Colors K /BitsPerComponent B >>
                if (pos + 1 < data.len and data[pos] == '<' and data[pos + 1] == '<') {
                    pos += 2;
                    // Scan the DecodeParms dict
                    while (pos < data.len) {
                        if (pos + 1 < data.len and data[pos] == '>' and data[pos + 1] == '>') {
                            pos += 2;
                            break;
                        }
                        if (data[pos] == '/') {
                            const dp_name = parseName(data, pos) orelse {
                                pos += 1;
                                continue;
                            };
                            pos = skipWhitespace(data, dp_name.end);

                            if (std.mem.eql(u8, dp_name.name, "Predictor")) {
                                if (parseInt(data, pos)) |r| {
                                    predictor = @intCast(@max(1, @min(15, r.value)));
                                    pos = r.end;
                                }
                            } else if (std.mem.eql(u8, dp_name.name, "Columns")) {
                                if (parseInt(data, pos)) |r| {
                                    columns = @intCast(@max(1, r.value));
                                    pos = r.end;
                                }
                            } else if (std.mem.eql(u8, dp_name.name, "Colors")) {
                                if (parseInt(data, pos)) |r| {
                                    colors = @intCast(@max(1, @min(255, r.value)));
                                    pos = r.end;
                                }
                            } else if (std.mem.eql(u8, dp_name.name, "BitsPerComponent")) {
                                if (parseInt(data, pos)) |r| {
                                    dp_bpc = @intCast(@max(1, @min(16, r.value)));
                                    pos = r.end;
                                }
                            } else {
                                pos = dp_name.end;
                            }
                        } else {
                            pos += 1;
                        }
                    }
                }
            } else {
                // Skip past the value
                if (pos + 1 < data.len and data[pos] == '<' and data[pos + 1] == '<') {
                    // Nested dict — skip it
                    pos += 2;
                    var depth: u32 = 1;
                    while (pos + 1 < data.len and depth > 0) {
                        if (data[pos] == '<' and data[pos + 1] == '<') {
                            depth += 1;
                            pos += 2;
                        } else if (data[pos] == '>' and data[pos + 1] == '>') {
                            depth -= 1;
                            pos += 2;
                        } else {
                            pos += 1;
                        }
                    }
                } else {
                    pos = name.end;
                }
            }
        } else if (data[pos] == '<' and pos + 1 < data.len and data[pos + 1] == '<') {
            // Nested dict — skip it
            pos += 2;
            var depth: u32 = 1;
            while (pos + 1 < data.len and depth > 0) {
                if (data[pos] == '<' and data[pos + 1] == '<') {
                    depth += 1;
                    pos += 2;
                } else if (data[pos] == '>' and data[pos + 1] == '>') {
                    depth -= 1;
                    pos += 2;
                } else {
                    pos += 1;
                }
            }
        } else {
            pos += 1;
        }
    }

    // Must be an image with single FlateDecode filter and Predictor >= 10
    if (!is_image or !is_flate or is_filter_array) return null;
    if (predictor < 10) return null; // Not PNG-style prediction, skip
    const ss = stream_start orelse return null;
    const se = stream_end orelse return null;
    if (se <= ss) return null;
    const w = width orelse return null;
    const h = height orelse return null;

    // Use /DecodeParms /BitsPerComponent if present, otherwise use outer /BitsPerComponent
    const final_bpc = dp_bpc orelse bpc;

    // If /Columns not specified in DecodeParms, use /Width
    const final_columns = columns orelse w;

    // Verify zlib header (first byte should be 0x78 for deflate)
    if (se - ss < 2 or data[ss] != 0x78) return null;

    return PdfFlateStream{
        .stream_start = ss,
        .stream_end = se,
        .object_num = obj_num,
        .gen_num = gen_num,
        .predictor = predictor,
        .columns = final_columns,
        .colors = colors,
        .bits_per_component = final_bpc,
        .width = w,
        .height = h,
    };
}

/// Find FlateDecode image streams by linear scan.
fn findFlateStreamsLinear(allocator: Allocator, data: []const u8) ![]PdfFlateStream {
    var streams: std.ArrayListUnmanaged(PdfFlateStream) = .{};
    errdefer streams.deinit(allocator);

    var i: usize = 0;
    while (i + 3 < data.len) {
        // Look for "obj" keyword
        if (!std.mem.eql(u8, data[i..][0..3], "obj")) {
            i += 1;
            continue;
        }

        // Must be preceded by whitespace
        if (i > 0 and data[i - 1] != ' ' and data[i - 1] != '\n' and data[i - 1] != '\r' and data[i - 1] != '\t') {
            i += 1;
            continue;
        }

        // Backtrack to find "N G" before "obj"
        var back = i;
        while (back > 0 and (data[back - 1] == ' ' or data[back - 1] == '\n' or data[back - 1] == '\r' or data[back - 1] == '\t')) {
            back -= 1;
        }
        const gen_end = back;
        while (back > 0 and data[back - 1] >= '0' and data[back - 1] <= '9') {
            back -= 1;
        }
        if (back == gen_end) {
            i += 3;
            continue;
        }
        const gen_num = std.fmt.parseInt(u32, data[back..gen_end], 10) catch {
            i += 3;
            continue;
        };

        while (back > 0 and (data[back - 1] == ' ' or data[back - 1] == '\n' or data[back - 1] == '\r' or data[back - 1] == '\t')) {
            back -= 1;
        }
        const obj_end = back;
        while (back > 0 and data[back - 1] >= '0' and data[back - 1] <= '9') {
            back -= 1;
        }
        if (back == obj_end) {
            i += 3;
            continue;
        }
        const obj_num = std.fmt.parseInt(u32, data[back..obj_end], 10) catch {
            i += 3;
            continue;
        };

        if (parseObjectForFlate(data, back, obj_num, gen_num)) |stream| {
            try streams.append(allocator, stream);
        }

        i += 3;
    }

    return streams.toOwnedSlice(allocator);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// Minimal hand-crafted PDF with a single JPEG image stream.
// This is a valid (if minimal) PDF structure for testing.
fn makeTestPdf(allocator: Allocator) ![]u8 {
    // Build a minimal valid PDF with correct xref offsets by tracking positions dynamically.
    const jpeg_data = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02, 0xFF, 0xD9 };

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    // Header
    try out.appendSlice(allocator, "%PDF-1.4\n");

    // Object 1 — Catalog
    const obj1_offset = out.items.len;
    try out.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    // Object 2 — Pages
    const obj2_offset = out.items.len;
    try out.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n");

    // Object 3 — Image with JPEG stream
    const obj3_offset = out.items.len;
    try out.appendSlice(allocator, "3 0 obj\n<< /Type /XObject /Subtype /Image /Width 8 /Height 8 /Filter /DCTDecode /Length 8 >>\nstream\n");
    try out.appendSlice(allocator, &jpeg_data);
    try out.appendSlice(allocator, "\nendstream\nendobj\n");

    // Xref table
    const xref_offset = out.items.len;
    try out.appendSlice(allocator, "xref\n0 4\n");
    try out.appendSlice(allocator, "0000000000 65535 f \n");
    // Write correctly-computed offsets for each object
    var offset_buf: [20]u8 = undefined;
    for ([_]usize{ obj1_offset, obj2_offset, obj3_offset }) |off| {
        const s = std.fmt.bufPrint(&offset_buf, "{d:0>10} 00000 n \n", .{off}) catch unreachable;
        try out.appendSlice(allocator, s);
    }

    // Trailer
    try out.appendSlice(allocator, "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n");
    const xref_str = std.fmt.bufPrint(&offset_buf, "{d}", .{xref_offset}) catch unreachable;
    try out.appendSlice(allocator, xref_str);
    try out.appendSlice(allocator, "\n%%EOF\n");

    return out.toOwnedSlice(allocator);
}

test "isPdfMagic detects PDF" {
    try testing.expect(isPdfMagic("%PDF-1.4\n"));
    try testing.expect(isPdfMagic("%PDF-2.0 some extra data"));
}

test "isPdfMagic rejects non-PDF" {
    try testing.expect(!isPdfMagic("PK\x03\x04")); // ZIP
    try testing.expect(!isPdfMagic("\xFF\xD8\xFF")); // JPEG
    try testing.expect(!isPdfMagic("%PDF")); // too short
    try testing.expect(!isPdfMagic(""));
}

test "findJpegStreams on hand-crafted PDF with JPEG image" {
    const pdf = try makeTestPdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);

    try testing.expectEqual(@as(usize, 1), streams.len);
    try testing.expectEqual(@as(u32, 3), streams[0].object_num);
    try testing.expectEqual(@as(u32, 0), streams[0].gen_num);
    try testing.expectEqual(@as(usize, 8), streams[0].len());

    // Verify the bytes at that offset are the JPEG data
    try testing.expectEqual(@as(u8, 0xFF), pdf[streams[0].stream_start]);
    try testing.expectEqual(@as(u8, 0xD8), pdf[streams[0].stream_start + 1]);
}

test "findJpegStreams returns empty for PDF with no images" {
    const pdf = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n" ++
        "xref\n0 3\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n" ++
        "trailer\n<< /Size 3 /Root 1 0 R >>\nstartxref\n107\n%%EOF\n";

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

test "findJpegStreams skips FlateDecode images" {
    const pdf = "%PDF-1.4\n3 0 obj\n<< /Type /XObject /Subtype /Image /Filter /FlateDecode /Length 4 >>\n" ++
        "stream\n\x78\x9c\x03\x00\nendstream\nendobj\n" ++
        "xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000009 00000 n \n0000000009 00000 n \n" ++
        "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n116\n%%EOF\n";

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

test "createPdfShell zeros correct byte regions" {
    const pdf = try makeTestPdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expect(streams.len > 0);

    const shell = try createPdfShell(testing.allocator, pdf, streams);
    defer testing.allocator.free(shell);

    // Shell same length as original
    try testing.expectEqual(pdf.len, shell.len);

    // JPEG region zeroed
    for (shell[streams[0].stream_start..streams[0].stream_end]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }

    // Non-JPEG region unchanged (check some bytes before and after)
    if (streams[0].stream_start > 10) {
        try testing.expectEqualSlices(u8, pdf[0..streams[0].stream_start], shell[0..streams[0].stream_start]);
    }
    try testing.expectEqualSlices(u8, pdf[streams[0].stream_end..], shell[streams[0].stream_end..]);
}

test "splicePdfImages restores original PDF bytes" {
    const pdf = try makeTestPdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expect(streams.len > 0);

    // Extract JPEG data
    const jpeg_data = pdf[streams[0].stream_start..streams[0].stream_end];
    const images = [_][]const u8{jpeg_data};

    // Create shell and splice back
    const shell = try createPdfShell(testing.allocator, pdf, streams);
    defer testing.allocator.free(shell);
    try splicePdfImages(shell, streams, &images);

    // Must be byte-identical to original
    try testing.expectEqualSlices(u8, pdf, shell);
}

test "roundtrip: find → shell → splice = original" {
    const pdf = try makeTestPdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);

    // Save JPEG data
    var saved_images = try testing.allocator.alloc([]u8, streams.len);
    defer {
        for (saved_images) |img| testing.allocator.free(img);
        testing.allocator.free(saved_images);
    }
    for (streams, 0..) |s, idx| {
        saved_images[idx] = try testing.allocator.dupe(u8, pdf[s.stream_start..s.stream_end]);
    }

    // Create shell
    const shell = try createPdfShell(testing.allocator, pdf, streams);
    defer testing.allocator.free(shell);

    // Cast saved_images to const slices for splice
    var const_images = try testing.allocator.alloc([]const u8, saved_images.len);
    defer testing.allocator.free(const_images);
    for (saved_images, 0..) |img, idx| {
        const_images[idx] = img;
    }

    // Splice back
    try splicePdfImages(shell, streams, const_images);

    // Byte-identical
    try testing.expectEqualSlices(u8, pdf, shell);
}

test "encrypted PDF returns empty" {
    const pdf = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n" ++
        "trailer\n<< /Size 2 /Root 1 0 R /Encrypt << /V 2 >> >>\n" ++
        "startxref\n49\n%%EOF\n";

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

test "splicePdfImages rejects wrong count" {
    const streams = [_]PdfJpegStream{.{ .stream_start = 0, .stream_end = 4, .object_num = 1, .gen_num = 0 }};
    const empty_images = [_][]const u8{};
    try testing.expectError(error.StreamImageCountMismatch, splicePdfImages(@constCast(&[_]u8{ 0, 0, 0, 0 }), &streams, &empty_images));
}

test "splicePdfImages rejects wrong size" {
    var buf = [_]u8{ 0, 0, 0, 0 };
    const streams = [_]PdfJpegStream{.{ .stream_start = 0, .stream_end = 4, .object_num = 1, .gen_num = 0 }};
    const wrong_size = [_][]const u8{&[_]u8{ 1, 2 }}; // 2 bytes, not 4
    try testing.expectError(error.ImageSizeMismatch, splicePdfImages(&buf, &streams, &wrong_size));
}

// =============================================================================
// FlateDecode tests
// =============================================================================

/// Simple zlib stored-blocks compressor for test data.
/// Same approach as png.zig's zlibCompress.
fn testZlibCompress(allocator: Allocator, data: []const u8) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    // Zlib header: CMF=0x78, FLG=0x01
    try output.appendSlice(allocator, &[_]u8{ 0x78, 0x01 });

    // Single stored block (data fits in one block for test data)
    try output.append(allocator, 1); // final block
    var len_bytes: [2]u8 = undefined;
    const block_len: u16 = @intCast(data.len);
    std.mem.writeInt(u16, &len_bytes, block_len, .little);
    try output.appendSlice(allocator, &len_bytes);
    std.mem.writeInt(u16, &len_bytes, ~block_len, .little);
    try output.appendSlice(allocator, &len_bytes);
    try output.appendSlice(allocator, data);

    // Adler-32 checksum (big-endian)
    const adler = std.hash.Adler32.hash(data);
    var adler_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_bytes, adler, .big);
    try output.appendSlice(allocator, &adler_bytes);

    return output.toOwnedSlice(allocator);
}

fn makeTestFlatePdf(allocator: Allocator) ![]u8 {
    // Create a minimal PDF with a FlateDecode image stream.
    // Uses zlib-compressed 2x2 RGB pixel data with Predictor 15 (PNG optimal).
    const raw_filtered = [_]u8{
        0, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, // row 0: None filter, red, green
        0, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, // row 1: None filter, blue, yellow
    };

    const compressed = try testZlibCompress(allocator, &raw_filtered);
    defer allocator.free(compressed);

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "%PDF-1.4\n");

    const obj1_offset = out.items.len;
    try out.appendSlice(allocator, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

    const obj2_offset = out.items.len;
    try out.appendSlice(allocator, "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n");

    const obj3_offset = out.items.len;
    // FlateDecode image with DecodeParms
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{compressed.len}) catch unreachable;
    try out.appendSlice(allocator, "3 0 obj\n<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /DecodeParms << /Predictor 15 /Columns 2 /Colors 3 /BitsPerComponent 8 >> /Length ");
    try out.appendSlice(allocator, len_str);
    try out.appendSlice(allocator, " >>\nstream\n");
    try out.appendSlice(allocator, compressed);
    try out.appendSlice(allocator, "\nendstream\nendobj\n");

    const xref_offset = out.items.len;
    try out.appendSlice(allocator, "xref\n0 4\n");
    try out.appendSlice(allocator, "0000000000 65535 f \n");
    var offset_buf: [20]u8 = undefined;
    for ([_]usize{ obj1_offset, obj2_offset, obj3_offset }) |off| {
        const s = std.fmt.bufPrint(&offset_buf, "{d:0>10} 00000 n \n", .{off}) catch unreachable;
        try out.appendSlice(allocator, s);
    }

    try out.appendSlice(allocator, "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n");
    const xref_str = std.fmt.bufPrint(&offset_buf, "{d}", .{xref_offset}) catch unreachable;
    try out.appendSlice(allocator, xref_str);
    try out.appendSlice(allocator, "\n%%EOF\n");

    return out.toOwnedSlice(allocator);
}

test "findFlateImageStreams finds FlateDecode image with Predictor 15" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);

    try testing.expectEqual(@as(usize, 1), streams.len);
    try testing.expectEqual(@as(u32, 3), streams[0].object_num);
    try testing.expectEqual(@as(u32, 0), streams[0].gen_num);
    try testing.expectEqual(@as(u16, 15), streams[0].predictor);
    try testing.expectEqual(@as(u32, 2), streams[0].columns);
    try testing.expectEqual(@as(u8, 3), streams[0].colors);
    try testing.expectEqual(@as(u8, 8), streams[0].bits_per_component);
    try testing.expectEqual(@as(u32, 2), streams[0].width);
    try testing.expectEqual(@as(u32, 2), streams[0].height);

    // Verify zlib header
    try testing.expectEqual(@as(u8, 0x78), pdf[streams[0].stream_start]);
}

test "findFlateImageStreams skips FlateDecode without Predictor" {
    // FlateDecode image but no DecodeParms / Predictor — raw zlib, not image-like
    const pdf = "%PDF-1.4\n3 0 obj\n<< /Type /XObject /Subtype /Image /Width 4 /Height 4 " ++
        "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length 4 >>\n" ++
        "stream\n\x78\x9c\x03\x00\nendstream\nendobj\n" ++
        "xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000009 00000 n \n0000000009 00000 n \n" ++
        "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n220\n%%EOF\n";

    const streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

test "findFlateImageStreams skips non-image FlateDecode (content stream)" {
    // Content stream, not /Subtype /Image
    const pdf = "%PDF-1.4\n3 0 obj\n<< /Filter /FlateDecode /Length 4 >>\n" ++
        "stream\n\x78\x9c\x03\x00\nendstream\nendobj\n" ++
        "xref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000009 00000 n \n0000000009 00000 n \n" ++
        "trailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n98\n%%EOF\n";

    const streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

test "findJpegStreams still ignores FlateDecode images" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const streams = try findJpegStreams(testing.allocator, pdf);
    defer testing.allocator.free(streams);
    try testing.expectEqual(@as(usize, 0), streams.len);
}

// =============================================================================
// PDF rewrite tests
// =============================================================================

test "rewritePdfWithStreams: no replacements returns copy" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const result = try rewritePdfWithStreams(testing.allocator, pdf, &.{});
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, pdf, result.?);
}

test "rewritePdfWithStreams: same-size replacement preserves structure" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const flate_streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(flate_streams);
    try testing.expectEqual(@as(usize, 1), flate_streams.len);

    // Replace stream with same-length data
    const original_data = pdf[flate_streams[0].stream_start..flate_streams[0].stream_end];
    const same_data = try testing.allocator.dupe(u8, original_data);
    defer testing.allocator.free(same_data);

    const reps = [_]StreamReplacement{.{
        .stream_start = flate_streams[0].stream_start,
        .original_length = flate_streams[0].len(),
        .new_data = same_data,
    }};

    const result = try rewritePdfWithStreams(testing.allocator, pdf, &reps);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);

    // The rewritten PDF should be a valid PDF with correct structure
    const rewritten = result.?;
    try testing.expect(isPdfMagic(rewritten));

    // Should still have the same FlateDecode stream
    const re_streams = try findFlateImageStreams(testing.allocator, rewritten);
    defer testing.allocator.free(re_streams);
    try testing.expectEqual(@as(usize, 1), re_streams.len);

    // Stream data should match
    try testing.expectEqualSlices(
        u8,
        same_data,
        rewritten[re_streams[0].stream_start..re_streams[0].stream_end],
    );
}

test "rewritePdfWithStreams: larger replacement adjusts Length and xref" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const flate_streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(flate_streams);
    try testing.expectEqual(@as(usize, 1), flate_streams.len);

    // Create replacement data that's LARGER than original
    const orig_len = flate_streams[0].len();
    const bigger_data = try testing.allocator.alloc(u8, orig_len + 20);
    defer testing.allocator.free(bigger_data);
    @memset(bigger_data, 0xAB);

    const reps = [_]StreamReplacement{.{
        .stream_start = flate_streams[0].stream_start,
        .original_length = orig_len,
        .new_data = bigger_data,
    }};

    const result = try rewritePdfWithStreams(testing.allocator, pdf, &reps);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);

    const rewritten = result.?;
    try testing.expect(isPdfMagic(rewritten));

    // Verify /Length was updated
    const length_info = findLengthField(rewritten, std.mem.indexOf(u8, rewritten, "stream\n").? + 7);
    try testing.expect(length_info != null);
    const len_val = parseInt(rewritten, length_info.?.value_start);
    try testing.expect(len_val != null);
    try testing.expectEqual(@as(i64, @intCast(bigger_data.len)), len_val.?.value);

    // Verify the stream data is at the right place
    const stream_marker = std.mem.indexOf(u8, rewritten, "stream\n").? + 7;
    try testing.expectEqualSlices(
        u8,
        bigger_data,
        rewritten[stream_marker..][0..bigger_data.len],
    );

    // Verify xref is valid: startxref points to "xref"
    const startxref = findStartxref(rewritten);
    try testing.expect(startxref != null);
    const xref_at = skipWhitespace(rewritten, startxref.?);
    try testing.expect(std.mem.eql(u8, rewritten[xref_at..][0..4], "xref"));
}

test "rewritePdfWithStreams: smaller replacement adjusts Length and xref" {
    const pdf = try makeTestFlatePdf(testing.allocator);
    defer testing.allocator.free(pdf);

    const flate_streams = try findFlateImageStreams(testing.allocator, pdf);
    defer testing.allocator.free(flate_streams);
    try testing.expectEqual(@as(usize, 1), flate_streams.len);

    // Create replacement data that's SMALLER than original
    const smaller_data = [_]u8{ 0x78, 0x01, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01 };

    const reps = [_]StreamReplacement{.{
        .stream_start = flate_streams[0].stream_start,
        .original_length = flate_streams[0].len(),
        .new_data = &smaller_data,
    }};

    const result = try rewritePdfWithStreams(testing.allocator, pdf, &reps);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);

    const rewritten = result.?;
    try testing.expect(isPdfMagic(rewritten));

    // Rewritten should be shorter than original
    try testing.expect(rewritten.len < pdf.len);

    // Verify startxref points to valid xref
    const startxref = findStartxref(rewritten);
    try testing.expect(startxref != null);
    const xref_at = skipWhitespace(rewritten, startxref.?);
    try testing.expect(std.mem.eql(u8, rewritten[xref_at..][0..4], "xref"));
}
