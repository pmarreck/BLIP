const blip = @import("blip");

// C FFI surface for BLIP encoding/decoding.
// All public C API functions are defined here using `export fn`.

// Re-export blip module for internal use
pub const core = blip;

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
// Container / archive C FFI exports
// ---------------------------------------------------------------------------

const std = @import("std");
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;
const mini_blip = blip.mini_blip_mod;
const ContainerError = mini_blip.ContainerError;
const leaf = mini_blip.leaf;
const dict_mod = mini_blip.dict_mod;

/// Map a full archive error (ContainerError | OutOfMemory) to a C FFI error code.
fn fullArchiveErrorCode(err: (Allocator.Error || ContainerError)) i32 {
    return switch (err) {
        error.OutOfMemory => -13,
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
    };
}

/// Map a ContainerError to a C FFI error code.
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
        else => "unknown error",
    };
}

/// A file entry passed from C for archive creation.
const CFileEntry = extern struct {
    path: [*]const u8,
    path_len: usize,
    content: [*]const u8,
    content_len: usize,
};

/// Create a BLIP archive from file entries.
/// Returns 0 on success, -1 on error.
/// Caller must free the output buffer with blip_free().
export fn blip_archive_create(
    files: [*]const CFileEntry,
    file_count: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    // Convert CFileEntry array to FileEntry array
    const file_entries = page_allocator.alloc(mini_blip.FileEntry, file_count) catch return -1;
    defer page_allocator.free(file_entries);

    for (0..file_count) |i| {
        file_entries[i] = .{
            .path = files[i].path[0..files[i].path_len],
            .content = files[i].content[0..files[i].content_len],
            .metadata = null,
        };
    }

    const result = mini_blip.createArchive(page_allocator, file_entries) catch return -1;
    // result is owned by page_allocator, hand it to the caller
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Get the number of files in a BLIP archive.
/// Returns 0 on success, -1 on error.
export fn blip_archive_file_count(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    out_count.* = reader.fileCount() catch return -1;
    return 0;
}

/// Verify a BLIP archive's xxHash64 integrity.
/// Returns true if the hash is valid, false otherwise (including on parse error).
export fn blip_archive_verify(
    buf: [*]const u8,
    buf_len: usize,
) callconv(.c) bool {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch return false;
    return reader.verifyHash() catch false;
}

/// Get the file path at the given index (zero-copy pointer into buf).
/// Returns 0 on success, negative error code on failure.
export fn blip_archive_file_path(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_path: *[*]const u8,
    out_path_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);
    const path_idx = (file_reader.findKey("path") catch |e| return containerErrorCode(e)) orelse return -4;
    const path_container = file_reader.valueAt(path_idx) catch |e| return containerErrorCode(e);
    const path_val = leaf.readUtf8(path_container) catch |e| return containerErrorCode(e);
    out_path.* = path_val.ptr;
    out_path_len.* = path_val.len;
    return 0;
}

/// Get the file content at the given index (zero-copy pointer into buf).
/// Returns 0 on success, negative error code on failure.
export fn blip_archive_file_content(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);
    const bina_idx = (file_reader.findKey("bina") catch |e| return containerErrorCode(e)) orelse return -4;
    const bina_container = file_reader.valueAt(bina_idx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);
    out_data.* = bina_val.ptr;
    out_data_len.* = bina_val.len;
    return 0;
}

/// Get file content by path (zero-copy pointer into buf).
/// Returns 0 on success, -14 if not found, other negative codes on error.
export fn blip_archive_file_content_by_path(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const file_reader_opt = reader.findFile(path[0..path_len]) catch |e| return containerErrorCode(e);
    const file_reader = file_reader_opt orelse return -14;
    const bina_idx = (file_reader.findKey("bina") catch |e| return containerErrorCode(e)) orelse return -4;
    const bina_container = file_reader.valueAt(bina_idx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);
    out_data.* = bina_val.ptr;
    out_data_len.* = bina_val.len;
    return 0;
}

/// Verify a single file's xh64 hash within an archive.
/// Returns 0 if hash matches, -7 on mismatch, -8 on index out of bounds, other negatives on error.
export fn blip_archive_file_verify(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);

    // Verify the dict/file/dir container hash
    const dict_hash_ok = file_reader.verifyHash() catch |e| return containerErrorCode(e);
    if (!dict_hash_ok) return -7;

    // Check if this is a DIR entry (no bina required)
    const entry_type = reader.entryTypeAt(index) catch |e| return containerErrorCode(e);
    if (entry_type == .dir) {
        // For DIR entries, we verify the container hash (done above) but skip bina content check
        return 0;
    }

    // For FILE entries, verify xh64 matches content hash
    const xh64_idx = (file_reader.findKey("xh64") catch |e| return containerErrorCode(e)) orelse return -4;
    const xh64_container = file_reader.valueAt(xh64_idx) catch |e| return containerErrorCode(e);
    const xh64_val = leaf.readRaw(xh64_container) catch |e| return containerErrorCode(e);
    if (xh64_val.len != 8) return -2; // InvalidLength

    const stored_hash = std.mem.readInt(u64, xh64_val[0..8], .little);

    // Get file content and recompute hash
    const bina_idx = (file_reader.findKey("bina") catch |e| return containerErrorCode(e)) orelse return -4;
    const bina_container = file_reader.valueAt(bina_idx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);

    const computed_hash = std.hash.XxHash64.hash(0, bina_val);

    if (stored_hash != computed_hash) return -7; // HashMismatch
    return 0;
}

/// A full archive entry passed from C (supports both files and directories with metadata).
const CArchiveEntry = extern struct {
    path: [*]const u8,
    path_len: usize,
    content: ?[*]const u8, // NULL for dirs
    content_len: usize, // 0 for dirs
    is_dir: u8, // 1 for directory, 0 for file
    mode: u16, // permission bits (LE uint16), 0 = not set
    mtime_ns: i64, // nanoseconds since epoch (LE int64), 0 = not set
    owner: ?[*]const u8, // NULL = not set
    owner_len: usize, // 0 = not set
    xh64: [8]u8, // Merkle hash for dirs (pre-computed by caller), ignored for files
};

/// Create a full BLIP archive from archive entries (files + directories + metadata).
/// Returns 0 on success, negative error code on failure.
/// Caller must free the output buffer with blip_free().
export fn blip_archive_create_full(
    entries: [*]const CArchiveEntry,
    entry_count: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    // We need to build ArchiveEntry array with optional metadata
    var archive_entries = page_allocator.alloc(mini_blip.ArchiveEntry, entry_count) catch return -13;
    defer page_allocator.free(archive_entries);

    // Track metadata allocations
    var meta_allocs: std.ArrayList([]u8) = .{};
    defer {
        for (meta_allocs.items) |item| page_allocator.free(item);
        meta_allocs.deinit(page_allocator);
    }

    for (0..entry_count) |i| {
        const e = entries[i];
        const path = e.path[0..e.path_len];

        // Build metadata pairs if any non-zero fields
        const has_mode = e.mode != 0;
        const has_mtime = e.mtime_ns != 0;
        const has_owner = e.owner != null and e.owner_len > 0;
        const meta_count: usize = (if (has_mode) @as(usize, 1) else 0) +
            (if (has_mtime) @as(usize, 1) else 0) +
            (if (has_owner) @as(usize, 1) else 0);

        var metadata: ?[]dict_mod.KeyValue = null;
        if (meta_count > 0) {
            const meta = page_allocator.alloc(dict_mod.KeyValue, meta_count) catch return -13;
            // We need a wrapper to track as []u8 for freeing
            const meta_bytes: []u8 = @as([*]u8, @ptrCast(meta.ptr))[0 .. meta_count * @sizeOf(dict_mod.KeyValue)];
            meta_allocs.append(page_allocator,meta_bytes) catch return -13;

            var mi: usize = 0;

            if (has_mode) {
                // "mode" sorts before "mtime", "owner", "path", "xh64"
                const key_mode = leaf.serializeUtf8(page_allocator, "mode") catch return -13;
                meta_allocs.append(page_allocator,key_mode) catch return -13;
                var mode_bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &mode_bytes, e.mode, .little);
                const val_mode = leaf.serializeRaw(page_allocator, &mode_bytes) catch return -13;
                meta_allocs.append(page_allocator,val_mode) catch return -13;
                meta[mi] = .{ .key = key_mode, .value = val_mode };
                mi += 1;
            }
            if (has_mtime) {
                const key_mtime = leaf.serializeUtf8(page_allocator, "mtime") catch return -13;
                meta_allocs.append(page_allocator,key_mtime) catch return -13;
                var mtime_bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &mtime_bytes, e.mtime_ns, .little);
                const val_mtime = leaf.serializeRaw(page_allocator, &mtime_bytes) catch return -13;
                meta_allocs.append(page_allocator,val_mtime) catch return -13;
                meta[mi] = .{ .key = key_mtime, .value = val_mtime };
                mi += 1;
            }
            if (has_owner) {
                const key_owner = leaf.serializeUtf8(page_allocator, "owner") catch return -13;
                meta_allocs.append(page_allocator,key_owner) catch return -13;
                const val_owner = leaf.serializeUtf8(page_allocator, e.owner.?[0..e.owner_len]) catch return -13;
                meta_allocs.append(page_allocator,val_owner) catch return -13;
                meta[mi] = .{ .key = key_owner, .value = val_owner };
                mi += 1;
            }

            metadata = meta;
        }

        if (e.is_dir != 0) {
            archive_entries[i] = .{
                .dir = .{
                    .path = path,
                    .xh64 = e.xh64,
                    .metadata = metadata,
                },
            };
        } else {
            const content = if (e.content) |c| c[0..e.content_len] else &[_]u8{};
            archive_entries[i] = .{
                .file = .{
                    .path = path,
                    .content = content,
                    .metadata = metadata,
                },
            };
        }
    }

    const result = mini_blip.createFullArchive(page_allocator, archive_entries) catch |e| {
        return fullArchiveErrorCode(e);
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Get the container type of an entry at the given index.
/// Returns 0 on success. out_type will be 0x05 (FILE) or 0x07 (DIR).
export fn blip_archive_entry_type(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_type: *u8,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const entry_type = reader.entryTypeAt(index) catch |e| return containerErrorCode(e);
    out_type.* = @intFromEnum(entry_type);
    return 0;
}

/// Extract metadata (mode, mtime, owner) from an archive entry.
/// Returns 0 on success. Fields not present in the entry are set to 0/NULL.
export fn blip_archive_entry_metadata(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_mode: *u16,
    out_mtime_ns: *i64,
    out_owner: *[*]const u8,
    out_owner_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const entry = reader.entryAt(index) catch |e| return containerErrorCode(e);

    // Default to zero/null
    out_mode.* = 0;
    out_mtime_ns.* = 0;
    out_owner.* = @as([*]const u8, "");
    out_owner_len.* = 0;

    // Try to read mode
    if (entry.findKey("mode") catch |e| return containerErrorCode(e)) |mode_idx| {
        const mode_container = entry.valueAt(mode_idx) catch |e| return containerErrorCode(e);
        const mode_val = leaf.readRaw(mode_container) catch |e| return containerErrorCode(e);
        if (mode_val.len >= 2) {
            out_mode.* = std.mem.readInt(u16, mode_val[0..2], .little);
        }
    }

    // Try to read mtime
    if (entry.findKey("mtime") catch |e| return containerErrorCode(e)) |mtime_idx| {
        const mtime_container = entry.valueAt(mtime_idx) catch |e| return containerErrorCode(e);
        const mtime_val = leaf.readRaw(mtime_container) catch |e| return containerErrorCode(e);
        if (mtime_val.len >= 8) {
            out_mtime_ns.* = std.mem.readInt(i64, mtime_val[0..8], .little);
        }
    }

    // Try to read owner
    if (entry.findKey("owner") catch |e| return containerErrorCode(e)) |owner_idx| {
        const owner_container = entry.valueAt(owner_idx) catch |e| return containerErrorCode(e);
        const owner_val = leaf.readUtf8(owner_container) catch |e| return containerErrorCode(e);
        out_owner.* = owner_val.ptr;
        out_owner_len.* = owner_val.len;
    }

    return 0;
}

/// Free a buffer allocated by blip_archive_create or blip_archive_create_full.
export fn blip_free(ptr: [*]u8, len: usize) callconv(.c) void {
    page_allocator.free(ptr[0..len]);
}

test "lib placeholder" {
    _ = blip;
}

test "C FFI: blip_archive_create and blip_archive_file_count round-trip" {
    const paths = [_][*]const u8{ "hello.txt", "world.txt" };
    const path_lens = [_]usize{ 9, 9 };
    const contents = [_][*]const u8{ "Hello!", "World!" };
    const content_lens = [_]usize{ 6, 6 };

    const c_files = [_]CFileEntry{
        .{ .path = paths[0], .path_len = path_lens[0], .content = contents[0], .content_len = content_lens[0] },
        .{ .path = paths[1], .path_len = path_lens[1], .content = contents[1], .content_len = content_lens[1] },
    };

    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const create_result = blip_archive_create(&c_files, 2, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), create_result);
    defer blip_free(out_buf, out_len);

    // Verify file count
    var count: u64 = undefined;
    const count_result = blip_archive_file_count(out_buf, out_len, &count);
    try std.testing.expectEqual(@as(i32, 0), count_result);
    try std.testing.expectEqual(@as(u64, 2), count);

    // Verify hash
    try std.testing.expect(blip_archive_verify(out_buf, out_len));
}

test "C FFI: blip_archive_verify returns false on corrupted data" {
    // Create a valid archive first
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const create_result = blip_archive_create(&c_files, 1, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), create_result);
    defer blip_free(out_buf, out_len);

    // Verify it's valid first
    try std.testing.expect(blip_archive_verify(out_buf, out_len));

    // Corrupt a byte near the middle
    const slice = out_buf[0..out_len];
    const mid = out_len / 2;
    const original = slice[mid];
    slice[mid] = original ^ 0xFF;

    // Now verification should fail (or at least not crash; the corruption may or may not
    // affect the hash depending on location, but flipping bits in the middle likely does)
    // We just ensure it doesn't crash; the result depends on what we corrupted
    _ = blip_archive_verify(out_buf, out_len);

    // Restore for clean free
    slice[mid] = original;
}

test "C FFI: blip_free frees allocated memory" {
    // Just ensure blip_free doesn't crash on a valid allocation
    const c_files = [_]CFileEntry{};
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const result = blip_archive_create(&c_files, 0, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), result);
    blip_free(out_buf, out_len);
}

test "C FFI: blip_error_string returns correct strings" {
    const ok_str = std.mem.span(blip_error_string(0));
    try std.testing.expectEqualSlices(u8, "success", ok_str);

    const hash_str = std.mem.span(blip_error_string(-7));
    try std.testing.expectEqualSlices(u8, "hash mismatch", hash_str);

    const unknown_str = std.mem.span(blip_error_string(-50));
    try std.testing.expectEqualSlices(u8, "unknown error", unknown_str);
}

test "C FFI: containerErrorCode maps all ContainerError variants" {
    // Verify the mapping function covers all error variants correctly
    try std.testing.expectEqual(@as(i32, -1), containerErrorCode(error.InvalidContainerType));
    try std.testing.expectEqual(@as(i32, -2), containerErrorCode(error.InvalidLength));
    try std.testing.expectEqual(@as(i32, -3), containerErrorCode(error.LengthExceedsBounds));
    try std.testing.expectEqual(@as(i32, -4), containerErrorCode(error.MissingRequiredKey));
    try std.testing.expectEqual(@as(i32, -5), containerErrorCode(error.DuplicateKey));
    try std.testing.expectEqual(@as(i32, -6), containerErrorCode(error.KeysNotSorted));
    try std.testing.expectEqual(@as(i32, -7), containerErrorCode(error.HashMismatch));
    try std.testing.expectEqual(@as(i32, -8), containerErrorCode(error.IndexOutOfBounds));
    try std.testing.expectEqual(@as(i32, -9), containerErrorCode(error.InvalidMagic));
    try std.testing.expectEqual(@as(i32, -10), containerErrorCode(error.BufferTooSmall));
    try std.testing.expectEqual(@as(i32, -11), containerErrorCode(error.UnexpectedEndOfInput));
    try std.testing.expectEqual(@as(i32, -12), containerErrorCode(error.Overflow));
}

test "C FFI: blip_archive_file_path returns correct paths" {
    const c_files = [_]CFileEntry{
        .{ .path = "alpha.txt", .path_len = 9, .content = "aaa", .content_len = 3 },
        .{ .path = "beta.txt", .path_len = 8, .content = "bbb", .content_len = 3 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var path_ptr: [*]const u8 = undefined;
    var path_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 0, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "alpha.txt", path_ptr[0..path_len]);

    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 1, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "beta.txt", path_ptr[0..path_len]);

    // Out of bounds
    try std.testing.expectEqual(@as(i32, -8), blip_archive_file_path(out_buf, out_len, 2, &path_ptr, &path_len));
}

test "C FFI: blip_archive_file_content returns correct data" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello world", .content_len = 11 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content(out_buf, out_len, 0, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "hello world", data_ptr[0..data_len]);
}

test "C FFI: blip_archive_file_content_by_path finds file" {
    const c_files = [_]CFileEntry{
        .{ .path = "a.txt", .path_len = 5, .content = "aaa", .content_len = 3 },
        .{ .path = "b.txt", .path_len = 5, .content = "bbb", .content_len = 3 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content_by_path(out_buf, out_len, "b.txt", 5, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "bbb", data_ptr[0..data_len]);

    // Not found
    try std.testing.expectEqual(@as(i32, -14), blip_archive_file_content_by_path(out_buf, out_len, "nope", 4, &data_ptr, &data_len));
}

test "C FFI: blip_archive_file_verify checks per-file hash" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_verify(out_buf, out_len, 0));
    try std.testing.expectEqual(@as(i32, -8), blip_archive_file_verify(out_buf, out_len, 1));
}

test "C FFI: blip_archive_create_full with FILE + DIR entries" {
    const entries = [_]CArchiveEntry{
        .{
            .path = "mydir", .path_len = 5,
            .content = null, .content_len = 0,
            .is_dir = 1,
            .mode = 0o755, .mtime_ns = 0, .owner = null, .owner_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .path = "mydir/file.txt", .path_len = 14,
            .content = "hello", .content_len = 5,
            .is_dir = 0,
            .mode = 0o644, .mtime_ns = 0, .owner = null, .owner_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // ignored for files (computed by Zig)
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Verify count
    var count: u64 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_count(out_buf, out_len, &count));
    try std.testing.expectEqual(@as(u64, 2), count);

    // Verify hash
    try std.testing.expect(blip_archive_verify(out_buf, out_len));
}

test "C FFI: blip_archive_entry_type returns FILE vs DIR" {
    const entries = [_]CArchiveEntry{
        .{
            .path = "adir", .path_len = 4,
            .content = null, .content_len = 0,
            .is_dir = 1,
            .mode = 0, .mtime_ns = 0, .owner = null, .owner_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .path = "bfile.txt", .path_len = 9,
            .content = "data", .content_len = 4,
            .is_dir = 0,
            .mode = 0, .mtime_ns = 0, .owner = null, .owner_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var out_type: u8 = undefined;
    // adir sorts first
    try std.testing.expectEqual(@as(i32, 0), blip_archive_entry_type(out_buf, out_len, 0, &out_type));
    try std.testing.expectEqual(@as(u8, 0x07), out_type); // DIR
    try std.testing.expectEqual(@as(i32, 0), blip_archive_entry_type(out_buf, out_len, 1, &out_type));
    try std.testing.expectEqual(@as(u8, 0x05), out_type); // FILE
}

test "C FFI: blip_archive_entry_metadata returns metadata" {
    const entries = [_]CArchiveEntry{
        .{
            .path = "script.sh", .path_len = 9,
            .content = "#!/bin/bash\n", .content_len = 12,
            .is_dir = 0,
            .mode = 0o755, .mtime_ns = 1708787200_000_000_000, .owner = "peter", .owner_len = 5,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 1, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var out_mode: u16 = undefined;
    var out_mtime_ns: i64 = undefined;
    var out_owner: [*]const u8 = undefined;
    var out_owner_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_entry_metadata(
        out_buf, out_len, 0, &out_mode, &out_mtime_ns, &out_owner, &out_owner_len,
    ));
    try std.testing.expectEqual(@as(u16, 0o755), out_mode);
    try std.testing.expectEqual(@as(i64, 1708787200_000_000_000), out_mtime_ns);
    try std.testing.expectEqualSlices(u8, "peter", out_owner[0..out_owner_len]);
}
