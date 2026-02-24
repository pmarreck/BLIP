const blip = @import("blip");
const pb = @import("printable_binary");

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
        -15 => "invalid path",
        else => "unknown error",
    };
}

/// Archive creation flags (must match BLIP_ARCHIVE_* in blip.h).
const BLIP_ARCHIVE_ABSOLUTE_PATHS: u32 = 0x0001;

/// Normalize a path by stripping leading "./" and "/" sequences (tar-style).
pub fn normalizePath(path: []const u8) []const u8 {
    var p = path;
    while (true) {
        if (p.len >= 2 and p[0] == '.' and p[1] == '/') {
            p = p[2..];
        } else if (p.len >= 1 and p[0] == '/') {
            p = p[1..];
        } else {
            break;
        }
    }
    if (p.len == 1 and p[0] == '.') {
        return p[1..];
    }
    return p;
}

export fn blip_normalize_path(
    path: [*]const u8,
    path_len: usize,
    out_path: *[*]const u8,
    out_path_len: *usize,
) callconv(.c) void {
    const input = path[0..path_len];
    const result = normalizePath(input);
    out_path.* = result.ptr;
    out_path_len.* = result.len;
}

/// A file entry passed from C for simple archive creation.
const CFileEntry = extern struct {
    path: [*]const u8,
    path_len: usize,
    content: [*]const u8,
    content_len: usize,
};

/// A full archive entry passed from C (supports both files and directories with metadata).
const CArchiveEntry = extern struct {
    path: [*]const u8,
    path_len: usize,
    content: ?[*]const u8, // NULL for dirs
    content_len: usize, // 0 for dirs
    is_dir: u8, // 1 for directory, 0 for file
    mode: u16, // permission bits (LE uint16), 0 = not set
    mtime_ns: i64, // nanoseconds since epoch, 0 = not set
    ctime_ns: i64,
    birthtime_ns: i64,
    uid: u32,
    gid: u32,
    owner: ?[*]const u8, // NULL = not set (username)
    owner_len: usize,
    groupname: ?[*]const u8, // NULL = not set
    groupname_len: usize,
    xh64: [8]u8, // Merkle hash for dirs (pre-computed by caller), ignored for files
};

/// Create a BLIP archive from simple file entries (no metadata beyond path+content).
export fn blip_archive_create(
    files: [*]const CFileEntry,
    file_count: usize,
    flags: u32,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const normalize = (flags & BLIP_ARCHIVE_ABSOLUTE_PATHS) == 0;

    const file_entries = page_allocator.alloc(mini_blip.FileEntry, file_count) catch return -13;
    defer page_allocator.free(file_entries);

    for (0..file_count) |i| {
        const raw_path = files[i].path[0..files[i].path_len];
        const path = if (normalize) normalizePath(raw_path) else raw_path;
        file_entries[i] = .{
            .path = path,
            .content = files[i].content[0..files[i].content_len],
        };
    }

    const result = mini_blip.createArchive(page_allocator, file_entries) catch return -1;
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Create a full BLIP archive from archive entries (files + directories + metadata).
export fn blip_archive_create_full(
    entries: [*]const CArchiveEntry,
    entry_count: usize,
    flags: u32,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const normalize = (flags & BLIP_ARCHIVE_ABSOLUTE_PATHS) == 0;

    var archive_entries = page_allocator.alloc(mini_blip.ArchiveEntry, entry_count) catch return -13;
    defer page_allocator.free(archive_entries);

    for (0..entry_count) |i| {
        const e = entries[i];
        const raw_path = e.path[0..e.path_len];
        const path = if (normalize) normalizePath(raw_path) else raw_path;

        const username: []const u8 = if (e.owner) |o| o[0..e.owner_len] else &.{};
        const gname: []const u8 = if (e.groupname) |g| g[0..e.groupname_len] else &.{};

        if (e.is_dir != 0) {
            archive_entries[i] = .{
                .dir = .{
                    .path = path,
                    .xh64 = e.xh64,
                    .mode = e.mode,
                    .mtime_ns = e.mtime_ns,
                    .ctime_ns = e.ctime_ns,
                    .birthtime_ns = e.birthtime_ns,
                    .uid = e.uid,
                    .gid = e.gid,
                    .username = username,
                    .groupname = gname,
                },
            };
        } else {
            const content = if (e.content) |c| c[0..e.content_len] else &[_]u8{};
            archive_entries[i] = .{
                .file = .{
                    .path = path,
                    .content = content,
                    .mode = e.mode,
                    .mtime_ns = e.mtime_ns,
                    .ctime_ns = e.ctime_ns,
                    .birthtime_ns = e.birthtime_ns,
                    .uid = e.uid,
                    .gid = e.gid,
                    .username = username,
                    .groupname = gname,
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

/// Get the number of entries in a BLIP archive.
export fn blip_archive_file_count(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    out_count.* = reader.entryCount() catch return -1;
    return 0;
}

/// Verify a BLIP archive's xxHash64 integrity.
export fn blip_archive_verify(
    buf: [*]const u8,
    buf_len: usize,
) callconv(.c) bool {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch return false;
    return reader.verifyHash() catch false;
}

/// Get the file path at the given index (zero-copy pointer into buf).
/// Works for both FILE (ARRAY-based) and DIR (DICT-based) entries.
export fn blip_archive_file_path(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_path: *[*]const u8,
    out_path_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const path_val = reader.entryPathAt(index) catch |e| return containerErrorCode(e);
    out_path.* = path_val.ptr;
    out_path_len.* = path_val.len;
    return 0;
}

/// Get file content at the given index (zero-copy pointer into buf).
/// Only works for FILE entries (reads DATA container element 1).
export fn blip_archive_file_content(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const content = reader.fileContentAt(index) catch |e| return containerErrorCode(e);
    out_data.* = content.ptr;
    out_data_len.* = content.len;
    return 0;
}

/// Get file content by path (zero-copy pointer into buf).
export fn blip_archive_file_content_by_path(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const idx = (reader.findFile(path[0..path_len]) catch |e| return containerErrorCode(e)) orelse return -14;
    const content = reader.fileContentAt(idx) catch |e| return containerErrorCode(e);
    out_data.* = content.ptr;
    out_data_len.* = content.len;
    return 0;
}

/// Verify a single entry's hash within an archive.
/// For FILE: verifies both DATA hash and ARRAY hash.
/// For DIR: verifies container hash.
export fn blip_archive_file_verify(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
) callconv(.c) i32 {
    const reader = mini_blip.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const ok = reader.verifyFileAt(index) catch |e| return containerErrorCode(e);
    if (!ok) return -7;
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

/// Extract metadata from an entry. Works for both FILE and DIR entries.
/// Uses 2-char keys (md, mt, un for mode, mtime, username).
export fn blip_archive_entry_metadata(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_mode: *u16,
    out_mtime_ns: *i64,
    out_owner: *[*]const u8,
    out_owner_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const reader = mini_blip.ArchiveReader.init(slice) catch |e| return containerErrorCode(e);

    // Default to zero/null
    out_mode.* = 0;
    out_mtime_ns.* = 0;
    out_owner.* = @as([*]const u8, "");
    out_owner_len.* = 0;

    const entry_type = reader.entryTypeAt(index) catch |e| return containerErrorCode(e);

    if (entry_type == .file) {
        // FILE: ARRAY[0] is metadata DICT
        const arr = reader.fileArrayAt(index) catch |e| return containerErrorCode(e);
        const meta_view = arr.elementAt(0) catch |e| return containerErrorCode(e);
        const meta_start = @intFromPtr(meta_view.buf.ptr) - @intFromPtr(slice.ptr);
        const meta_end = meta_start + @as(usize, @intCast(meta_view.total_length));
        const meta_buf = slice[meta_start..meta_end];
        const meta_reader = dict_mod.DictReader.init(meta_buf) catch |e| return containerErrorCode(e);

        readMetadataFromDict(meta_reader, out_mode, out_mtime_ns, out_owner, out_owner_len) catch |e| return containerErrorCode(e);
    } else {
        // DIR: direct DICT
        const dict_reader = reader.dirDictAt(index) catch |e| return containerErrorCode(e);
        readMetadataFromDict(dict_reader, out_mode, out_mtime_ns, out_owner, out_owner_len) catch |e| return containerErrorCode(e);
    }

    return 0;
}

fn readMetadataFromDict(
    dict_reader: dict_mod.DictReader,
    out_mode: *u16,
    out_mtime_ns: *i64,
    out_owner: *[*]const u8,
    out_owner_len: *usize,
) ContainerError!void {
    // Try to read md (mode)
    if (try dict_reader.findKey("md")) |md_idx| {
        const md_container = try dict_reader.valueAt(md_idx);
        const md_val = try leaf.readRaw(md_container);
        if (md_val.len >= 2) {
            out_mode.* = std.mem.readInt(u16, md_val[0..2], .little);
        }
    }

    // Try to read mt (mtime)
    if (try dict_reader.findKey("mt")) |mt_idx| {
        const mt_container = try dict_reader.valueAt(mt_idx);
        const mt_val = try leaf.readRaw(mt_container);
        if (mt_val.len >= 8) {
            out_mtime_ns.* = std.mem.readInt(i64, mt_val[0..8], .little);
        }
    }

    // Try to read un (username)
    if (try dict_reader.findKey("un")) |un_idx| {
        const un_container = try dict_reader.valueAt(un_idx);
        const un_val = try leaf.readUtf8(un_container);
        out_owner.* = un_val.ptr;
        out_owner_len.* = un_val.len;
    }
}

/// Free a buffer allocated by blip_archive_create or blip_archive_create_full.
export fn blip_free(ptr: [*]u8, len: usize) callconv(.c) void {
    page_allocator.free(ptr[0..len]);
}

// ---------------------------------------------------------------------------
// Peek / navigation C FFI exports
// ---------------------------------------------------------------------------

const peek_mod = blip.peek_mod;

/// Navigate to a container within a BLIP buffer using a path expression.
/// Path syntax: [N] for array index, [key] for dict key.
/// Returns 0 on success. out_type receives the container type byte (0x01-0x08).
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

    // Parse the path
    var parsed = peek_mod.parsePath(page_allocator, path_str) catch return -15;
    defer peek_mod.freeParsedPath(page_allocator, &parsed);

    // Navigate
    const result = peek_mod.navigate(slice, parsed.segments) catch |e| return containerErrorCode(e);

    // Get the type from the sentinel (first 2 bytes of any container)
    if (result.len < 2) return -11; // unexpected end of input
    // Type byte is result[1] (second byte of sentinel 0x81 0xNN)
    out_type.* = result[1];
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

test "lib placeholder" {
    _ = blip;
}

test "normalizePath strips leading ./ sequences" {
    try std.testing.expectEqualSlices(u8, "foo/bar.txt", normalizePath("./foo/bar.txt"));
    try std.testing.expectEqualSlices(u8, "foo", normalizePath("././foo"));
}

test "normalizePath strips leading / characters" {
    try std.testing.expectEqualSlices(u8, "tmp/bft/a.txt", normalizePath("/tmp/bft/a.txt"));
    try std.testing.expectEqualSlices(u8, "tmp/x", normalizePath("///tmp/x"));
}

test "normalizePath handles mixed ./ and /" {
    try std.testing.expectEqualSlices(u8, "foo", normalizePath("./foo"));
    try std.testing.expectEqualSlices(u8, "foo", normalizePath("/./foo"));
}

test "normalizePath no-op for already-clean paths" {
    try std.testing.expectEqualSlices(u8, "foo/bar.txt", normalizePath("foo/bar.txt"));
    try std.testing.expectEqualSlices(u8, "hello.txt", normalizePath("hello.txt"));
}

test "normalizePath handles edge cases" {
    try std.testing.expectEqualSlices(u8, "", normalizePath("./"));
    try std.testing.expectEqualSlices(u8, "", normalizePath("/"));
    try std.testing.expectEqualSlices(u8, "", normalizePath("."));
    try std.testing.expectEqualSlices(u8, "", normalizePath(""));
}

test "C FFI: blip_normalize_path works" {
    var out_path: [*]const u8 = undefined;
    var out_len: usize = undefined;
    blip_normalize_path("/tmp/bft/a.txt", 14, &out_path, &out_len);
    try std.testing.expectEqualSlices(u8, "tmp/bft/a.txt", out_path[0..out_len]);

    blip_normalize_path("./foo/bar", 9, &out_path, &out_len);
    try std.testing.expectEqualSlices(u8, "foo/bar", out_path[0..out_len]);
}

test "C FFI: blip_archive_create normalizes paths by default" {
    const c_files = [_]CFileEntry{
        .{ .path = "/tmp/test.txt", .path_len = 13, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var path_ptr: [*]const u8 = undefined;
    var path_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 0, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "tmp/test.txt", path_ptr[0..path_len]);
}

test "C FFI: blip_archive_create preserves absolute paths with flag" {
    const c_files = [_]CFileEntry{
        .{ .path = "/tmp/test.txt", .path_len = 13, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, BLIP_ARCHIVE_ABSOLUTE_PATHS, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var path_ptr: [*]const u8 = undefined;
    var path_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 0, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "/tmp/test.txt", path_ptr[0..path_len]);
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
    const create_result = blip_archive_create(&c_files, 2, 0, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), create_result);
    defer blip_free(out_buf, out_len);

    var count: u64 = undefined;
    const count_result = blip_archive_file_count(out_buf, out_len, &count);
    try std.testing.expectEqual(@as(i32, 0), count_result);
    try std.testing.expectEqual(@as(u64, 2), count);

    try std.testing.expect(blip_archive_verify(out_buf, out_len));
}

test "C FFI: blip_archive_verify returns false on corrupted data" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const create_result = blip_archive_create(&c_files, 1, 0, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), create_result);
    defer blip_free(out_buf, out_len);

    try std.testing.expect(blip_archive_verify(out_buf, out_len));

    const slice = out_buf[0..out_len];
    const mid = out_len / 2;
    const original = slice[mid];
    slice[mid] = original ^ 0xFF;
    _ = blip_archive_verify(out_buf, out_len);
    slice[mid] = original;
}

test "C FFI: blip_free frees allocated memory" {
    const c_files = [_]CFileEntry{};
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const result = blip_archive_create(&c_files, 0, 0, &out_buf, &out_len);
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
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var path_ptr: [*]const u8 = undefined;
    var path_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 0, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "alpha.txt", path_ptr[0..path_len]);

    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 1, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "beta.txt", path_ptr[0..path_len]);

    try std.testing.expectEqual(@as(i32, -8), blip_archive_file_path(out_buf, out_len, 2, &path_ptr, &path_len));
}

test "C FFI: blip_archive_file_content returns correct data" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello world", .content_len = 11 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
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
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content_by_path(out_buf, out_len, "b.txt", 5, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "bbb", data_ptr[0..data_len]);

    try std.testing.expectEqual(@as(i32, -14), blip_archive_file_content_by_path(out_buf, out_len, "nope", 4, &data_ptr, &data_len));
}

test "C FFI: blip_archive_file_verify checks per-file hash" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
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
            .mode = 0o755, .mtime_ns = 0, .ctime_ns = 0, .birthtime_ns = 0,
            .uid = 0, .gid = 0,
            .owner = null, .owner_len = 0,
            .groupname = null, .groupname_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .path = "mydir/file.txt", .path_len = 14,
            .content = "hello", .content_len = 5,
            .is_dir = 0,
            .mode = 0o644, .mtime_ns = 0, .ctime_ns = 0, .birthtime_ns = 0,
            .uid = 0, .gid = 0,
            .owner = null, .owner_len = 0,
            .groupname = null, .groupname_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var count: u64 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_count(out_buf, out_len, &count));
    try std.testing.expectEqual(@as(u64, 2), count);

    try std.testing.expect(blip_archive_verify(out_buf, out_len));
}

test "C FFI: blip_archive_entry_type returns FILE vs DIR" {
    const entries = [_]CArchiveEntry{
        .{
            .path = "adir", .path_len = 4,
            .content = null, .content_len = 0,
            .is_dir = 1,
            .mode = 0, .mtime_ns = 0, .ctime_ns = 0, .birthtime_ns = 0,
            .uid = 0, .gid = 0,
            .owner = null, .owner_len = 0,
            .groupname = null, .groupname_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .path = "bfile.txt", .path_len = 9,
            .content = "data", .content_len = 4,
            .is_dir = 0,
            .mode = 0, .mtime_ns = 0, .ctime_ns = 0, .birthtime_ns = 0,
            .uid = 0, .gid = 0,
            .owner = null, .owner_len = 0,
            .groupname = null, .groupname_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var out_type: u8 = undefined;
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
            .mode = 0o755, .mtime_ns = 1708787200_000_000_000, .ctime_ns = 0, .birthtime_ns = 0,
            .uid = 0, .gid = 0,
            .owner = "peter", .owner_len = 5,
            .groupname = null, .groupname_len = 0,
            .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 1, 0, &out_buf, &out_len));
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

// ---------------------------------------------------------------------------
// Peek FFI tests
// ---------------------------------------------------------------------------

test "C FFI: blip_peek navigates to known container" {
    // Create a simple archive with one file
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello", .content_len = 5 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Empty path -> outer ARRAY
    var out_type: u8 = undefined;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "", 0, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 0x01), out_type); // ARRAY

    // [1] -> body ARRAY
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1]", 3, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 0x01), out_type); // ARRAY

    // [1][0] -> FILE
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1][0]", 6, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 0x05), out_type); // FILE

    // [1][0][0] -> DICT (metadata)
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1][0][0]", 9, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 0x02), out_type); // DICT

    // [1][0][1] -> DATA (content)
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1][0][1]", 9, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 0x08), out_type); // DATA
}

test "C FFI: blip_container_count returns correct count" {
    const c_files = [_]CFileEntry{
        .{ .path = "a.txt", .path_len = 5, .content = "aaa", .content_len = 3 },
        .{ .path = "b.txt", .path_len = 5, .content = "bbb", .content_len = 3 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Navigate to [1] (body array) and get count
    var out_type: u8 = undefined;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1]", 3, &out_type, &data_ptr, &data_len));

    var count: u64 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_container_count(data_ptr, data_len, &count));
    try std.testing.expectEqual(@as(u64, 2), count);
}

test "C FFI: blip_container_hash returns correct hash bytes" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Get hash of outer array
    var hash: [8]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_container_hash(out_buf, out_len, &hash));
    // Hash should match last 8 bytes of the archive
    try std.testing.expectEqualSlices(u8, out_buf[out_len - 8 .. out_len], &hash);
}

test "C FFI: blip_container_key_at returns correct key" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Navigate to [1][0][0] (metadata dict)
    var out_type: u8 = undefined;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1][0][0]", 9, &out_type, &data_ptr, &data_len));

    // The "pa" key should be present. Keys are 2-char sorted, so "pa" should be findable.
    var key_ptr: [*]const u8 = undefined;
    var key_len: usize = undefined;

    // Get key count first
    var count: u64 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_container_count(data_ptr, data_len, &count));
    try std.testing.expect(count > 0);

    // Find "pa" among the keys
    var found_pa = false;
    for (0..count) |i| {
        try std.testing.expectEqual(@as(i32, 0), blip_container_key_at(data_ptr, data_len, i, &key_ptr, &key_len));
        if (key_len == 2 and key_ptr[0] == 'p' and key_ptr[1] == 'a') {
            found_pa = true;
            break;
        }
    }
    try std.testing.expect(found_pa);
}

test "C FFI: blip_encode_printable_binary round-trips" {
    const input = [_]u8{ 0x00, 0xFF, 0xDE, 0xAD };
    var encoded_buf: [*]u8 = undefined;
    var encoded_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_encode_printable_binary(&input, input.len, &encoded_buf, &encoded_len));
    defer blip_free(encoded_buf, encoded_len);

    // Encoded should be valid UTF-8 and non-empty
    try std.testing.expect(encoded_len > 0);
    try std.testing.expect(std.unicode.utf8ValidateSlice(encoded_buf[0..encoded_len]));
}

test "C FFI: blip_peek returns error for invalid path" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var out_type: u8 = undefined;
    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    // Invalid path syntax
    try std.testing.expectEqual(@as(i32, -15), blip_peek(out_buf, out_len, "[abc", 4, &out_type, &data_ptr, &data_len));
    // Out of bounds
    try std.testing.expectEqual(@as(i32, -8), blip_peek(out_buf, out_len, "[99]", 4, &out_type, &data_ptr, &data_len));
}
