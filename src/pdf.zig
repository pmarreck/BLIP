const std = @import("std");
const Allocator = std.mem.Allocator;

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
