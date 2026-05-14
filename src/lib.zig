const std = @import("std");
const blip = @import("blip");
const pb = @import("printable_binary");

const peek_mod = blip.peek_mod;
const segmentation_mod = blip.segmentation_mod;
const container_mod = blip.container_mod;
const ct = blip.container_types;

const page_allocator = std.heap.page_allocator;

const ContainerError = container_mod.ContainerError;

// Re-export blip module for internal use.
pub const core = blip;

// ---------------------------------------------------------------------------
// Varint encode / decode
// ---------------------------------------------------------------------------

/// Encode a u64 value into BLIP format.
/// Returns number of bytes written, or -1 on error.
export fn blip_encode(value: u64, out_buf: [*]u8, out_cap: usize) callconv(.c) i32 {
    const buf = out_buf[0..out_cap];
    const n = blip.encode(value, buf) catch return -1;
    return @intCast(n);
}

/// Decode a BLIP value from encoded bytes.
/// Returns bytes consumed, or -1 on error. Decoded value stored in out_value.
export fn blip_decode(encoded: [*]const u8, encoded_len: usize, out_value: *u64) callconv(.c) i32 {
    const buf = encoded[0..encoded_len];
    const result = blip.decode(buf) catch return -1;
    out_value.* = result.value;
    return @intCast(result.bytes_read);
}

/// Check if encoded bytes represent a sentinel.
export fn blip_is_sentinel(encoded: [*]const u8, encoded_len: usize) callconv(.c) bool {
    return blip.isSentinel(encoded[0..encoded_len]);
}

/// Get the encoded size for a value without actually encoding.
export fn blip_encoded_size(value: u64) callconv(.c) i32 {
    var buf: [16]u8 = undefined;
    const n = blip.encode(value, &buf) catch return -1;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

fn containerErrorCode(err: ContainerError) i32 {
    return switch (err) {
        error.InvalidContainerType => -1,
        error.InvalidLength => -2,
        error.LengthExceedsBounds => -3,
        error.MissingRequiredKey => -4,
        error.DuplicateKey => -5,
        error.KeysNotSorted => -6,
        error.HashMismatch => -7,
        error.IndexOutOfBounds => -8,
        error.InvalidMagic => -9,
        error.BufferTooSmall => -10,
        error.UnexpectedEndOfInput => -11,
        error.Overflow => -12,
        error.MissingSigil => -25,
        error.InvalidSigilOrder => -26,
        error.MissingDecompLen => -27,
    };
}

/// Get a human-readable error string for an error code.
export fn blip_error_string(error_code: i32) callconv(.c) [*:0]const u8 {
    return switch (error_code) {
        0 => "success",
        -1 => "invalid container type",
        -2 => "invalid length",
        -3 => "length exceeds bounds",
        -4 => "missing required key",
        -5 => "duplicate key",
        -6 => "keys not sorted",
        -7 => "hash mismatch",
        -8 => "index out of bounds",
        -9 => "invalid magic",
        -10 => "buffer too small",
        -11 => "unexpected end of input",
        -12 => "overflow",
        -13 => "allocation failure",
        -14 => "not found",
        -15 => "invalid path",
        -25 => "missing attribute sigil",
        -26 => "invalid attribute sigil order",
        -27 => "missing decompressed length",
        -50 => "invalid segment",
        -51 => "missing segments",
        -52 => "inconsistent segment total",
        -53 => "segment sequence gap",
        -54 => "duplicate segment value mismatch",
        else => "unknown error",
    };
}

/// Free a buffer that BLIP allocated for the caller (page-allocator-backed).
export fn blip_free(ptr: [*]u8, len: usize) callconv(.c) void {
    page_allocator.free(ptr[0..len]);
}

// ---------------------------------------------------------------------------
// Peek / navigation
// ---------------------------------------------------------------------------

/// Navigate to a container within a BLIP buffer using a path expression.
/// Path syntax: [N] for array index, [key] for dict key.
/// Returns 0 on success. out_type receives the v2 container type ID (1-7).
/// out_data/out_data_len receive a zero-copy pointer to the container bytes.
export fn blip_peek(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    out_type: *u8,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const path_str = path[0..path_len];

    var parsed = peek_mod.parsePath(page_allocator, path_str) catch return -15;
    defer peek_mod.freeParsedPath(page_allocator, &parsed);

    const result = peek_mod.navigate(slice, parsed.segments) catch |e| return containerErrorCode(e);

    const lp_view = container_mod.parseLPHeader(result) catch |e| return containerErrorCode(e);
    out_type.* = @intFromEnum(lp_view.type_id);
    out_data.* = result.ptr;
    out_data_len.* = result.len;
    return 0;
}

/// Get element/pair count for an array-like or dict-like container.
export fn blip_container_count(
    buf: [*]const u8,
    len: usize,
    out_count: *u64,
) callconv(.c) i32 {
    out_count.* = peek_mod.containerCount(buf[0..len]) catch |e| return containerErrorCode(e);
    return 0;
}

/// Get the trailing xxHash64 from a container.
export fn blip_container_hash(
    buf: [*]const u8,
    len: usize,
    out_hash: [*]u8,
) callconv(.c) i32 {
    const hash = peek_mod.containerHash(buf[0..len]) catch |e| return containerErrorCode(e);
    @memcpy(out_hash[0..8], &hash);
    return 0;
}

/// Get the key payload bytes at the given pair index from a dict-like container.
export fn blip_container_key_at(
    buf: [*]const u8,
    len: usize,
    index: u64,
    out_key: *[*]const u8,
    out_key_len: *usize,
) callconv(.c) i32 {
    const key_bytes = peek_mod.containerKeyAt(buf[0..len], index) catch |e| return containerErrorCode(e);
    out_key.* = key_bytes.ptr;
    out_key_len.* = key_bytes.len;
    return 0;
}

/// Full peek display: navigate + format output in Zig core.
/// Returns 0 on success, negative error code on failure.
/// Caller must free stdout/stderr buffers with blip_free().
export fn blip_peek_display(
    buf_ptr: [*]const u8,
    buf_len: usize,
    path_ptr: [*]const u8,
    path_len: usize,
    flags: u32,
    out_stdout_ptr: *[*]const u8,
    out_stdout_len: *usize,
    out_stderr_ptr: *[*]const u8,
    out_stderr_len: *usize,
) callconv(.c) i32 {
    const slice = buf_ptr[0..buf_len];
    const path_str = path_ptr[0..path_len];
    const peek_flags: peek_mod.PeekFlags = @bitCast(flags);

    var result = peek_mod.peekDisplay(page_allocator, slice, path_str, peek_flags) catch return -13;

    out_stdout_ptr.* = result.stdout_buf.ptr;
    out_stdout_len.* = result.stdout_buf.len;
    out_stderr_ptr.* = result.stderr_buf.ptr;
    out_stderr_len.* = result.stderr_buf.len;

    const had_error = result.is_error;

    // Prevent deinit from freeing the buffers we just handed off.
    result.stdout_buf = &.{};
    result.stderr_buf = &.{};

    return if (had_error) @as(i32, -1) else @as(i32, 0);
}

// ---------------------------------------------------------------------------
// Printable-binary
// ---------------------------------------------------------------------------

/// Decode a printable-binary UTF-8 buffer back to raw bytes.
/// Caller must free the output buffer with blip_free().
export fn blip_decode_printable_binary(
    encoded: [*]const u8,
    encoded_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pb.decode(page_allocator, encoded[0..encoded_len], .{}) catch return -1;
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Encode binary data as printable-binary UTF-8.
/// Caller must free the output buffer with blip_free().
export fn blip_encode_printable_binary(
    input: [*]const u8,
    input_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    const encoded = pb.encode(page_allocator, input_slice, .{}) catch return -13;
    out_buf.* = encoded.ptr;
    out_len.* = encoded.len;
    return 0;
}

// ---------------------------------------------------------------------------
// SEGMENT (Layer 5 transport-fragmentation primitive)
// ---------------------------------------------------------------------------

const CSegment = extern struct {
    data: [*]const u8,
    len: usize,
};

fn segErrorCode(e: anyerror) i32 {
    return switch (e) {
        error.NotASegment => -50,
        error.InvalidSegment => -50,
        error.MissingSegments => -51,
        error.InconsistentTotal => -52,
        error.SequenceGap => -53,
        error.DuplicateSegmentValueMismatch => -54,
        error.OutOfMemory => -13,
        else => -1,
    };
}

/// Chunk an arbitrary byte buffer into SEGMENT containers of at most `max_payload` bytes each.
/// On success returns 0 and writes:
///   *out_segments: array of CSegment (length *out_count)
///   *out_count:    number of segments
/// Caller must free with blip_segment_array_free(*out_segments, *out_count).
export fn blip_segment_chunk(
    data: [*]const u8,
    data_len: usize,
    max_payload: usize,
    stream_id: u64,
    csum_id: u8,
    out_segments: *[*]CSegment,
    out_count: *usize,
) callconv(.c) i32 {
    const cid: ?ct.ChecksumId = if (csum_id == 0) null else (std.enums.fromInt(ct.ChecksumId, @as(u7, @truncate(csum_id))) orelse return -50);
    const segs = segmentation_mod.chunkBytes(page_allocator, data[0..data_len], max_payload, stream_id, cid) catch |e| return segErrorCode(e);
    const arr = page_allocator.alloc(CSegment, segs.len) catch {
        for (segs) |s| page_allocator.free(s);
        page_allocator.free(segs);
        return -13;
    };
    for (segs, 0..) |s, i| arr[i] = .{ .data = s.ptr, .len = s.len };
    page_allocator.free(segs);
    out_segments.* = arr.ptr;
    out_count.* = arr.len;
    return 0;
}

/// Free an array of CSegment returned by blip_segment_chunk, including each
/// segment's data buffer.
export fn blip_segment_array_free(segments: [*]CSegment, count: usize) callconv(.c) void {
    for (0..count) |i| page_allocator.free(segments[i].data[0..segments[i].len]);
    page_allocator.free(segments[0..count]);
}

/// Reassemble a list of SEGMENT-container byte slices into the original payload.
/// On success returns 0 and writes the reassembled bytes to *out_buf / *out_len.
/// Caller must free with blip_free.
export fn blip_segment_reassemble(
    segments: [*]const CSegment,
    count: usize,
    expected_stream_id: u64,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    if (count == 0) return -51;
    const slices = page_allocator.alloc([]const u8, count) catch return -13;
    defer page_allocator.free(slices);
    for (0..count) |i| slices[i] = segments[i].data[0..segments[i].len];
    const out = segmentation_mod.reassemble(page_allocator, slices, expected_stream_id) catch |e| return segErrorCode(e);
    out_buf.* = out.ptr;
    out_len.* = out.len;
    return 0;
}

/// Quick check: does this byte slice parse as a SEGMENT container?
/// Returns 0 = not a segment, 1 = is a segment, negative = parse error.
export fn blip_segment_is_segment(data: [*]const u8, data_len: usize) callconv(.c) i32 {
    const info = segmentation_mod.parseSegment(data[0..data_len]) catch |e| switch (e) {
        error.NotASegment => return 0,
        else => return -50,
    };
    _ = info;
    return 1;
}

/// Read just the (I, M, N) header from a SEGMENT container, without reassembly.
/// `out_total` receives the N value; if N is NIL, *out_total_is_nil is set to 1.
/// Returns 0 on success, negative on error.
export fn blip_segment_header(
    data: [*]const u8,
    data_len: usize,
    out_stream_id: *u64,
    out_seg_index: *u64,
    out_total: *u64,
    out_total_is_nil: *u8,
) callconv(.c) i32 {
    const info = segmentation_mod.parseSegment(data[0..data_len]) catch |e| return segErrorCode(e);
    out_stream_id.* = info.stream_id;
    out_seg_index.* = info.seg_index;
    if (info.total) |n| {
        out_total.* = n;
        out_total_is_nil.* = 0;
    } else {
        out_total.* = 0;
        out_total_is_nil.* = 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// xxHash64 helper
// ---------------------------------------------------------------------------

/// Compute xxhash64 of a byte buffer. Returns the 64-bit hash (host-native order).
/// Compatible with `xxhsum -H64`.
export fn blip_xxhash64(data: [*]const u8, data_len: usize) callconv(.c) u64 {
    return std.hash.XxHash64.hash(0, data[0..data_len]);
}
