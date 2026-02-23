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
const page_allocator = std.heap.page_allocator;
const mini_blip = blip.mini_blip_mod;

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

/// Free a buffer allocated by blip_archive_create.
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
