/// Pure in-memory ZIP reader/writer for transparent container expansion.
///
/// Supports:
/// - Reading ZIP entries from a `[]const u8` buffer (central directory parsing)
/// - Extracting individual entries (store + deflate methods)
/// - Creating ZIP archives in memory (store + deflate)
/// - Detecting encrypted entries and zip64 format
///
/// Limitations:
/// - No zip64 support (returns error for zip64 archives)
/// - Only store (method 0) and deflate (method 8) are supported
/// - Encrypted entries detected but not decrypted
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const zip = std.zip;
const flate = std.compress.flate;
const Crc32 = std.hash.crc.Crc32;

const ManagedList = std.array_list.Managed(u8);

pub const ZipError = error{
    InvalidZip,
    EncryptedZip,
    Zip64Unsupported,
    UnsupportedMethod,
    BadCrc32,
    DecompressFailed,
    CompressFailed,
    OutOfMemory,
    TruncatedData,
};

pub const ZipEntry = struct {
    filename: []const u8, // zero-copy into source buffer
    compression_method: u16, // 0=store, 8=deflate
    uncompressed_size: u64,
    compressed_size: u64,
    crc32: u32,
    last_modification_time: u16, // MS-DOS time
    last_modification_date: u16, // MS-DOS date
    is_dir: bool,
    compressed_data: []const u8, // zero-copy slice into source buffer
    external_attributes: u32,
};

pub const ZipWriteEntry = struct {
    filename: []const u8,
    content: []const u8, // uncompressed
    compression_method: u16, // 0=store, 8=deflate
    last_modification_time: u16,
    last_modification_date: u16,
    external_attributes: u32,
};

/// Check if buffer starts with ZIP magic bytes (PK\x03\x04).
pub fn isZipMagic(buf: []const u8) bool {
    if (buf.len < 4) return false;
    return std.mem.eql(u8, buf[0..4], &zip.local_file_header_sig);
}

/// Check if any entry in the ZIP is encrypted.
/// Returns false if the buffer is not a valid zip.
pub fn hasEncryptedEntries(allocator: Allocator, buf: []const u8) ZipError!bool {
    _ = allocator;
    const end_record = findEndRecord(buf) orelse return error.InvalidZip;

    if (end_record.need_zip64()) return error.Zip64Unsupported;

    const cd_offset = end_record.central_directory_offset;
    const cd_size = end_record.central_directory_size;
    if (cd_offset + cd_size > buf.len) return error.TruncatedData;

    var pos: usize = cd_offset;
    var i: u16 = 0;
    while (i < end_record.record_count_total) : (i += 1) {
        if (pos + @sizeOf(zip.CentralDirectoryFileHeader) > buf.len) return error.TruncatedData;
        const header: *align(1) const zip.CentralDirectoryFileHeader = @ptrCast(buf[pos..][0..@sizeOf(zip.CentralDirectoryFileHeader)]);
        if (!std.mem.eql(u8, &header.signature, &zip.central_file_header_sig)) return error.InvalidZip;

        if (header.flags.encrypted) return true;

        pos += @sizeOf(zip.CentralDirectoryFileHeader) + header.filename_len + header.extra_len + header.comment_len;
    }
    return false;
}

/// Find end record in a buffer, returning null if not found.
fn findEndRecord(buf: []const u8) ?zip.EndRecord {
    const pos = std.mem.lastIndexOf(u8, buf, &zip.end_record_sig) orelse return null;
    if (pos + @sizeOf(zip.EndRecord) > buf.len) return null;
    const record: *align(1) const zip.EndRecord = @ptrCast(buf[pos..][0..@sizeOf(zip.EndRecord)]);
    return record.*;
}

/// Read all entries from a ZIP buffer. Returns array of ZipEntry with zero-copy
/// slices into the source buffer. Caller owns the returned slice (free with allocator.free).
pub fn readEntries(allocator: Allocator, buf: []const u8) ZipError![]ZipEntry {
    const end_record = findEndRecord(buf) orelse return error.InvalidZip;

    if (end_record.need_zip64()) return error.Zip64Unsupported;

    const count = end_record.record_count_total;
    const cd_offset = end_record.central_directory_offset;

    var entries = allocator.alloc(ZipEntry, count) catch return error.OutOfMemory;
    errdefer allocator.free(entries);

    var pos: usize = cd_offset;
    for (0..count) |i| {
        if (pos + @sizeOf(zip.CentralDirectoryFileHeader) > buf.len) return error.TruncatedData;
        const cd: *align(1) const zip.CentralDirectoryFileHeader = @ptrCast(buf[pos..][0..@sizeOf(zip.CentralDirectoryFileHeader)]);
        if (!std.mem.eql(u8, &cd.signature, &zip.central_file_header_sig)) return error.InvalidZip;

        if (cd.flags.encrypted) return error.EncryptedZip;

        const method: u16 = @intFromEnum(cd.compression_method);
        if (method != 0 and method != 8) return error.UnsupportedMethod;

        // Get filename from central directory
        const name_start = pos + @sizeOf(zip.CentralDirectoryFileHeader);
        if (name_start + cd.filename_len > buf.len) return error.TruncatedData;
        const filename = buf[name_start..][0..cd.filename_len];

        // Find compressed data from local file header
        const local_offset: usize = cd.local_file_header_offset;
        if (local_offset + @sizeOf(zip.LocalFileHeader) > buf.len) return error.TruncatedData;
        const local: *align(1) const zip.LocalFileHeader = @ptrCast(buf[local_offset..][0..@sizeOf(zip.LocalFileHeader)]);
        if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig)) return error.InvalidZip;

        const data_start = local_offset + @sizeOf(zip.LocalFileHeader) + local.filename_len + local.extra_len;
        const comp_size: usize = cd.compressed_size;
        if (data_start + comp_size > buf.len) return error.TruncatedData;

        entries[i] = .{
            .filename = filename,
            .compression_method = method,
            .uncompressed_size = cd.uncompressed_size,
            .compressed_size = comp_size,
            .crc32 = cd.crc32,
            .last_modification_time = cd.last_modification_time,
            .last_modification_date = cd.last_modification_date,
            .is_dir = filename.len > 0 and filename[filename.len - 1] == '/',
            .compressed_data = buf[data_start..][0..comp_size],
            .external_attributes = cd.external_file_attributes,
        };

        pos = name_start + cd.filename_len + cd.extra_len + cd.comment_len;
    }

    return entries;
}

/// Extract (decompress) a single ZIP entry. Returns uncompressed data.
/// Caller owns the returned slice.
pub fn extractEntry(allocator: Allocator, entry: ZipEntry) ZipError![]u8 {
    if (entry.uncompressed_size == 0 and entry.compressed_data.len == 0) {
        return allocator.alloc(u8, 0) catch return error.OutOfMemory;
    }

    switch (entry.compression_method) {
        0 => {
            // Store — just copy
            const result = allocator.alloc(u8, entry.compressed_data.len) catch return error.OutOfMemory;
            @memcpy(result, entry.compressed_data);
            // Verify CRC32
            if (Crc32.hash(result) != entry.crc32) {
                allocator.free(result);
                return error.BadCrc32;
            }
            return result;
        },
        8 => {
            // Deflate — decompress using direct mode (empty buffer → no intermediate
            // staging). The allocating writer from allocRemaining handles growth.
            // Indirect mode uses a fixed-capacity internal writer that panics on
            // overflow for large deflate matches — direct mode avoids this entirely.
            var source_reader = std.Io.Reader.fixed(entry.compressed_data);
            var empty_buf: [0]u8 = .{};
            var decompress_state = flate.Decompress.init(&source_reader, .raw, &empty_buf);

            const result = decompress_state.reader.allocRemaining(allocator, .unlimited) catch
                return error.DecompressFailed;

            // Verify CRC32
            if (Crc32.hash(result) != entry.crc32) {
                allocator.free(result);
                return error.BadCrc32;
            }

            return result;
        },
        else => return error.UnsupportedMethod,
    }
}

/// Create a ZIP archive in memory from the given entries.
/// Returns the complete ZIP file as a byte slice. Caller owns returned memory.
pub fn createZip(allocator: Allocator, entries: []const ZipWriteEntry) ZipError![]u8 {
    var result = ManagedList.init(allocator);
    errdefer result.deinit();

    // Track local header offsets for central directory
    const offsets = allocator.alloc(u32, entries.len) catch return error.OutOfMemory;
    defer allocator.free(offsets);

    const compressed_bufs = allocator.alloc(?[]u8, entries.len) catch return error.OutOfMemory;
    defer {
        for (compressed_bufs) |maybe_buf| {
            if (maybe_buf) |b| allocator.free(b);
        }
        allocator.free(compressed_bufs);
    }
    @memset(compressed_bufs, null);

    const crcs = allocator.alloc(u32, entries.len) catch return error.OutOfMemory;
    defer allocator.free(crcs);

    const comp_sizes = allocator.alloc(u32, entries.len) catch return error.OutOfMemory;
    defer allocator.free(comp_sizes);

    // Pre-compute CRC32 and compress where needed
    for (entries, 0..) |entry, i| {
        crcs[i] = Crc32.hash(entry.content);
        if (entry.compression_method == 8 and entry.content.len > 0) {
            // Deflate compress using Simple huffman
            compressed_bufs[i] = deflateCompress(allocator, entry.content) catch return error.CompressFailed;
            comp_sizes[i] = @intCast(compressed_bufs[i].?.len);
        } else {
            comp_sizes[i] = @intCast(entry.content.len);
        }
    }

    // Write local file headers + data
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(result.items.len);

        const content_data: []const u8 = if (entry.compression_method == 8 and compressed_bufs[i] != null)
            compressed_bufs[i].?
        else
            entry.content;

        // Local file header (30 bytes + filename)
        const header = zip.LocalFileHeader{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = if (entry.compression_method == 8) 20 else 10,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = @enumFromInt(entry.compression_method),
            .last_modification_time = entry.last_modification_time,
            .last_modification_date = entry.last_modification_date,
            .crc32 = crcs[i],
            .compressed_size = comp_sizes[i],
            .uncompressed_size = @intCast(entry.content.len),
            .filename_len = @intCast(entry.filename.len),
            .extra_len = 0,
        };

        result.appendSlice(std.mem.asBytes(&header)) catch return error.OutOfMemory;
        result.appendSlice(entry.filename) catch return error.OutOfMemory;
        result.appendSlice(content_data) catch return error.OutOfMemory;
    }

    // Write central directory
    const cd_start: u32 = @intCast(result.items.len);
    for (entries, 0..) |entry, i| {
        const cd = zip.CentralDirectoryFileHeader{
            .signature = zip.central_file_header_sig,
            .version_made_by = 0x031E, // Unix, version 3.0
            .version_needed_to_extract = if (entry.compression_method == 8) 20 else 10,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = @enumFromInt(entry.compression_method),
            .last_modification_time = entry.last_modification_time,
            .last_modification_date = entry.last_modification_date,
            .crc32 = crcs[i],
            .compressed_size = comp_sizes[i],
            .uncompressed_size = @intCast(entry.content.len),
            .filename_len = @intCast(entry.filename.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = entry.external_attributes,
            .local_file_header_offset = offsets[i],
        };

        result.appendSlice(std.mem.asBytes(&cd)) catch return error.OutOfMemory;
        result.appendSlice(entry.filename) catch return error.OutOfMemory;
    }

    const cd_size: u32 = @intCast(result.items.len - cd_start);

    // Write end record
    const end_record = zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(entries.len),
        .record_count_total = @intCast(entries.len),
        .central_directory_size = cd_size,
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };

    result.appendSlice(std.mem.asBytes(&end_record)) catch return error.OutOfMemory;

    return result.toOwnedSlice() catch return error.OutOfMemory;
}

/// Encode data as raw deflate using stored blocks.
/// Produces a valid deflate stream that decompresses to the original data.
/// No actual compression — BLIP's LZMA2/zstd handles real compression.
fn deflateCompress(allocator: Allocator, data: []const u8) ![]u8 {
    const max_block: usize = 65535;
    const num_blocks = if (data.len == 0) 1 else (data.len + max_block - 1) / max_block;
    // Each block: 1 byte header + 2 bytes LEN + 2 bytes NLEN + data
    const out_size = num_blocks * 5 + data.len;
    var result = try allocator.alloc(u8, out_size);
    errdefer allocator.free(result);

    var pos: usize = 0;
    var out_pos: usize = 0;
    var block_idx: usize = 0;
    while (block_idx < num_blocks) : (block_idx += 1) {
        const remaining = data.len - pos;
        const block_len: u16 = @intCast(@min(remaining, max_block));
        const is_final: u8 = if (block_idx == num_blocks - 1) 1 else 0;

        // Block header: BFINAL=is_final, BTYPE=00 (stored)
        result[out_pos] = is_final; // BFINAL | (BTYPE << 1), BTYPE=0
        out_pos += 1;

        // LEN (little-endian u16)
        std.mem.writeInt(u16, result[out_pos..][0..2], block_len, .little);
        out_pos += 2;

        // NLEN = one's complement of LEN
        std.mem.writeInt(u16, result[out_pos..][0..2], ~block_len, .little);
        out_pos += 2;

        // Raw data
        @memcpy(result[out_pos..][0..block_len], data[pos..][0..block_len]);
        out_pos += block_len;
        pos += block_len;
    }

    return result;
}

// =============================================================================
// Tests
// =============================================================================

// Helper: create a minimal stored ZIP in memory for testing
fn makeTestStoredZip(allocator: Allocator) ![]u8 {
    const filename = "hello.txt";
    const content = "Hello, World!";
    const crc = Crc32.hash(content);

    var result = ManagedList.init(allocator);

    // Local file header
    const local = zip.LocalFileHeader{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 10,
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .store,
        .last_modification_time = 0x4A3B,
        .last_modification_date = 0x5C6D,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = filename.len,
        .extra_len = 0,
    };
    try result.appendSlice(std.mem.asBytes(&local));
    try result.appendSlice(filename);
    try result.appendSlice(content);

    // Central directory
    const cd = zip.CentralDirectoryFileHeader{
        .signature = zip.central_file_header_sig,
        .version_made_by = 0x031E,
        .version_needed_to_extract = 10,
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .store,
        .last_modification_time = 0x4A3B,
        .last_modification_date = 0x5C6D,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = filename.len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0o100644 << 16,
        .local_file_header_offset = 0,
    };
    const cd_start: u32 = @intCast(result.items.len);
    try result.appendSlice(std.mem.asBytes(&cd));
    try result.appendSlice(filename);

    const cd_size: u32 = @intCast(result.items.len - cd_start);

    // End record
    const end_rec = zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = cd_size,
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };
    try result.appendSlice(std.mem.asBytes(&end_rec));

    return result.toOwnedSlice();
}

// Helper: create a multi-entry ZIP with both store and deflate entries
fn makeTestMultiEntryZip(allocator: Allocator) ![]u8 {
    const entries = [_]ZipWriteEntry{
        .{
            .filename = "first.txt",
            .content = "First file content",
            .compression_method = 0,
            .last_modification_time = 0x4A3B,
            .last_modification_date = 0x5C6D,
            .external_attributes = 0o100644 << 16,
        },
        .{
            .filename = "subdir/",
            .content = "",
            .compression_method = 0,
            .last_modification_time = 0x4A3B,
            .last_modification_date = 0x5C6D,
            .external_attributes = 0o40755 << 16,
        },
        .{
            .filename = "subdir/second.txt",
            .content = "Second file in subdirectory",
            .compression_method = 0,
            .last_modification_time = 0x4A3C,
            .last_modification_date = 0x5C6E,
            .external_attributes = 0o100644 << 16,
        },
    };
    return createZip(allocator, &entries);
}

// Helper: create ZIP with encrypted entry
fn makeTestEncryptedZip(allocator: Allocator) ![]u8 {
    var result = ManagedList.init(allocator);

    const filename = "secret.txt";
    const content = "encrypted data";
    const crc = Crc32.hash(content);

    // Local file header with encrypted flag
    const local = zip.LocalFileHeader{
        .signature = zip.local_file_header_sig,
        .version_needed_to_extract = 20,
        .flags = @bitCast(@as(u16, 1)), // encrypted bit set
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = filename.len,
        .extra_len = 0,
    };
    try result.appendSlice(std.mem.asBytes(&local));
    try result.appendSlice(filename);
    try result.appendSlice(content);

    // Central directory with encrypted flag
    const cd_start: u32 = @intCast(result.items.len);
    const cd = zip.CentralDirectoryFileHeader{
        .signature = zip.central_file_header_sig,
        .version_made_by = 0x031E,
        .version_needed_to_extract = 20,
        .flags = @bitCast(@as(u16, 1)), // encrypted bit set
        .compression_method = .store,
        .last_modification_time = 0,
        .last_modification_date = 0,
        .crc32 = crc,
        .compressed_size = content.len,
        .uncompressed_size = content.len,
        .filename_len = filename.len,
        .extra_len = 0,
        .comment_len = 0,
        .disk_number = 0,
        .internal_file_attributes = 0,
        .external_file_attributes = 0,
        .local_file_header_offset = 0,
    };
    try result.appendSlice(std.mem.asBytes(&cd));
    try result.appendSlice(filename);

    const cd_size: u32 = @intCast(result.items.len - cd_start);

    // End record
    const end_rec = zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = 1,
        .record_count_total = 1,
        .central_directory_size = cd_size,
        .central_directory_offset = cd_start,
        .comment_len = 0,
    };
    try result.appendSlice(std.mem.asBytes(&end_rec));

    return result.toOwnedSlice();
}

// Test 1: isZipMagic detects PK header
test "isZipMagic detects PK header" {
    try testing.expect(isZipMagic(&[_]u8{ 'P', 'K', 3, 4, 0, 0 }));
    try testing.expect(isZipMagic(&[_]u8{ 'P', 'K', 3, 4 }));
}

// Test 2: isZipMagic rejects non-zip
test "isZipMagic rejects non-zip data" {
    try testing.expect(!isZipMagic(&[_]u8{ 0x7f, 'E', 'L', 'F' })); // ELF
    try testing.expect(!isZipMagic(&[_]u8{ 'P', 'K', 5, 6 })); // end record sig, not local
    try testing.expect(!isZipMagic(&[_]u8{ 'P', 'K' })); // too short
    try testing.expect(!isZipMagic(&[_]u8{})); // empty
}

// Test 3: readEntries on minimal stored zip
test "readEntries on stored zip returns correct entry" {
    const allocator = testing.allocator;
    const zip_data = try makeTestStoredZip(allocator);
    defer allocator.free(zip_data);

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("hello.txt", entries[0].filename);
    try testing.expectEqual(@as(u16, 0), entries[0].compression_method);
    try testing.expectEqual(@as(u64, 13), entries[0].uncompressed_size);
    try testing.expectEqual(@as(u64, 13), entries[0].compressed_size);
    try testing.expect(!entries[0].is_dir);
}

// Test 4: extractEntry store method returns content
test "extractEntry store method returns correct content" {
    const allocator = testing.allocator;
    const zip_data = try makeTestStoredZip(allocator);
    defer allocator.free(zip_data);

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);

    const content = try extractEntry(allocator, entries[0]);
    defer allocator.free(content);

    try testing.expectEqualStrings("Hello, World!", content);
}

// Test 5: createZip roundtrip with store
test "createZip roundtrip with store method" {
    const allocator = testing.allocator;

    const write_entries = [_]ZipWriteEntry{
        .{
            .filename = "test.txt",
            .content = "Test content here",
            .compression_method = 0,
            .last_modification_time = 0x1234,
            .last_modification_date = 0x5678,
            .external_attributes = 0o100644 << 16,
        },
    };

    const zip_data = try createZip(allocator, &write_entries);
    defer allocator.free(zip_data);

    // Verify it's a valid zip
    try testing.expect(isZipMagic(zip_data));

    // Read back
    const read_entries = try readEntries(allocator, zip_data);
    defer allocator.free(read_entries);

    try testing.expectEqual(@as(usize, 1), read_entries.len);
    try testing.expectEqualStrings("test.txt", read_entries[0].filename);
    try testing.expectEqual(@as(u16, 0), read_entries[0].compression_method);

    const content = try extractEntry(allocator, read_entries[0]);
    defer allocator.free(content);
    try testing.expectEqualStrings("Test content here", content);
}

// Test 6: createZip roundtrip with deflate
test "createZip roundtrip with deflate method" {
    const allocator = testing.allocator;

    const write_entries = [_]ZipWriteEntry{
        .{
            .filename = "deflated.txt",
            .content = "This content will be compressed with deflate" ** 10,
            .compression_method = 8,
            .last_modification_time = 0x1234,
            .last_modification_date = 0x5678,
            .external_attributes = 0o100644 << 16,
        },
    };

    const zip_data = try createZip(allocator, &write_entries);
    defer allocator.free(zip_data);

    try testing.expect(isZipMagic(zip_data));

    const read_entries = try readEntries(allocator, zip_data);
    defer allocator.free(read_entries);

    try testing.expectEqual(@as(usize, 1), read_entries.len);
    try testing.expectEqual(@as(u16, 8), read_entries[0].compression_method);
    // Our deflate uses stored blocks, so compressed >= uncompressed.
    // The important thing is the roundtrip works correctly.

    const content = try extractEntry(allocator, read_entries[0]);
    defer allocator.free(content);
    try testing.expectEqualStrings("This content will be compressed with deflate" ** 10, content);
}

// Test 7: multi-entry zip preserves entry order
test "multi-entry zip preserves entry order" {
    const allocator = testing.allocator;
    const zip_data = try makeTestMultiEntryZip(allocator);
    defer allocator.free(zip_data);

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("first.txt", entries[0].filename);
    try testing.expectEqualStrings("subdir/", entries[1].filename);
    try testing.expectEqualStrings("subdir/second.txt", entries[2].filename);
}

// Test 8: encrypted entry detection
test "hasEncryptedEntries detects encrypted zip" {
    const allocator = testing.allocator;
    const zip_data = try makeTestEncryptedZip(allocator);
    defer allocator.free(zip_data);

    const has_encrypted = try hasEncryptedEntries(allocator, zip_data);
    try testing.expect(has_encrypted);
}

test "hasEncryptedEntries returns false for normal zip" {
    const allocator = testing.allocator;
    const zip_data = try makeTestStoredZip(allocator);
    defer allocator.free(zip_data);

    const has_encrypted = try hasEncryptedEntries(allocator, zip_data);
    try testing.expect(!has_encrypted);
}

// Test 9: empty zip (0 entries)
test "empty zip with zero entries" {
    const allocator = testing.allocator;

    const zip_data = try createZip(allocator, &[_]ZipWriteEntry{});
    defer allocator.free(zip_data);

    // Empty zip starts with end record, not local file header
    try testing.expect(!isZipMagic(zip_data));

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

// Test 10: directory entry (trailing /)
test "directory entry detected by trailing slash" {
    const allocator = testing.allocator;
    const zip_data = try makeTestMultiEntryZip(allocator);
    defer allocator.free(zip_data);

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);

    // First entry is a file
    try testing.expect(!entries[0].is_dir);
    // Second entry is a directory
    try testing.expect(entries[1].is_dir);
    // Third entry is a file in subdir
    try testing.expect(!entries[2].is_dir);
}

// Test: timestamps preserved in roundtrip
test "timestamps preserved in roundtrip" {
    const allocator = testing.allocator;

    const write_entries = [_]ZipWriteEntry{
        .{
            .filename = "dated.txt",
            .content = "time test",
            .compression_method = 0,
            .last_modification_time = 0xABCD,
            .last_modification_date = 0x1234,
            .external_attributes = 0o100755 << 16,
        },
    };

    const zip_data = try createZip(allocator, &write_entries);
    defer allocator.free(zip_data);

    const entries = try readEntries(allocator, zip_data);
    defer allocator.free(entries);

    try testing.expectEqual(@as(u16, 0xABCD), entries[0].last_modification_time);
    try testing.expectEqual(@as(u16, 0x1234), entries[0].last_modification_date);
    try testing.expectEqual(@as(u32, 0o100755 << 16), entries[0].external_attributes);
}

// Test: readEntries on invalid data returns error
test "readEntries rejects invalid data" {
    const allocator = testing.allocator;

    const result = readEntries(allocator, "not a zip file at all");
    try testing.expectError(error.InvalidZip, result);
}
