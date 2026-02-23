const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const leaf = @import("leaf.zig");
const array_mod = @import("array.zig");
const dict_mod = @import("dict.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;
const XxHash64 = std.hash.XxHash64;

/// A file to be included in a miniBLIP archive.
pub const FileEntry = struct {
    path: []const u8, // file path (UTF-8)
    content: []const u8, // file content bytes
    metadata: ?[]const dict_mod.KeyValue, // optional extra k-v pairs (pre-serialized)
};

/// The magic bytes identifying a miniBLIP archive: "BLIP" + version 1.
const MAGIC: *const [5]u8 = "BLIP\x01";

/// Create a miniBLIP archive from a list of file entries.
/// Files are sorted by path in canonical byte order.
/// Returns the complete archive as a byte slice. Caller owns returned memory.
pub fn createArchive(allocator: Allocator, files: []const FileEntry) (Allocator.Error || ContainerError)![]u8 {
    // We need to track all intermediate allocations so we can free them
    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    // Copy files into a sortable array, sort by path
    const sorted_files = try allocator.alloc(FileEntry, files.len);
    defer allocator.free(sorted_files);
    @memcpy(sorted_files, files);

    std.mem.sort(FileEntry, sorted_files, {}, struct {
        fn lessThan(_: void, a: FileEntry, b: FileEntry) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    // Serialize each file into a FILE container
    var file_elements: std.ArrayList([]const u8) = .{};
    defer file_elements.deinit(allocator);

    for (sorted_files) |file| {
        // Serialize the 3 required key-value pairs
        const key_bina = try leaf.serializeUtf8(allocator, "bina");
        try to_free.append(allocator, key_bina);
        const val_bina = try leaf.serializeRaw(allocator, file.content);
        try to_free.append(allocator, val_bina);

        const key_path = try leaf.serializeUtf8(allocator, "path");
        try to_free.append(allocator, key_path);
        const val_path = try leaf.serializeUtf8(allocator, file.path);
        try to_free.append(allocator, val_path);

        const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
        try to_free.append(allocator, key_xh64);

        // Compute xxHash64 of file content
        const hash_value = XxHash64.hash(0, file.content);
        var hash_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &hash_bytes, hash_value, .little);
        const val_xh64 = try leaf.serializeRaw(allocator, &hash_bytes);
        try to_free.append(allocator, val_xh64);

        // Build the pairs list (keys already in canonical order: "bina" < "path" < "xh64")
        const base_pair_count: usize = 3;
        const meta_count: usize = if (file.metadata) |m| m.len else 0;
        const total_pairs = base_pair_count + meta_count;

        const pairs = try allocator.alloc(dict_mod.KeyValue, total_pairs);
        defer allocator.free(pairs);

        // We need to merge the base pairs with metadata pairs, keeping canonical key order.
        // Base keys: "bina", "path", "xh64"
        // Metadata keys could be anything, so we need to merge-sort them in.
        const base_pairs = [3]dict_mod.KeyValue{
            .{ .key = key_bina, .value = val_bina },
            .{ .key = key_path, .value = val_path },
            .{ .key = key_xh64, .value = val_xh64 },
        };

        if (meta_count == 0) {
            @memcpy(pairs, &base_pairs);
        } else {
            // Merge base pairs and metadata pairs into sorted order
            const meta = file.metadata.?;
            var bi: usize = 0;
            var mi: usize = 0;
            var pi: usize = 0;

            while (bi < base_pairs.len and mi < meta.len) {
                const base_key_bytes = try dict_mod.extractKeyBytes(base_pairs[bi].key);
                const meta_key_bytes = try dict_mod.extractKeyBytes(meta[mi].key);
                const ord = std.mem.order(u8, base_key_bytes, meta_key_bytes);
                if (ord == .lt or ord == .eq) {
                    pairs[pi] = base_pairs[bi];
                    bi += 1;
                } else {
                    pairs[pi] = meta[mi];
                    mi += 1;
                }
                pi += 1;
            }
            while (bi < base_pairs.len) {
                pairs[pi] = base_pairs[bi];
                bi += 1;
                pi += 1;
            }
            while (mi < meta.len) {
                pairs[pi] = meta[mi];
                mi += 1;
                pi += 1;
            }
        }

        const file_bytes = try dict_mod.serializeFile(allocator, pairs);
        try to_free.append(allocator, file_bytes);
        try file_elements.append(allocator, file_bytes);
    }

    // Serialize magic: RAW("BLIP\x01")
    const magic_bytes = try leaf.serializeRaw(allocator, MAGIC);
    try to_free.append(allocator, magic_bytes);

    // Serialize body array (containing all FILE elements)
    const body_array = try array_mod.serializeArray(allocator, file_elements.items);
    try to_free.append(allocator, body_array);

    // Serialize outer array: [magic, body_array]
    const outer_elements = [_][]const u8{ magic_bytes, body_array };
    const result = try array_mod.serializeArray(allocator, &outer_elements);

    return result;
}

/// Reader for a miniBLIP archive.
pub const ArchiveReader = struct {
    buf: []const u8,
    outer: array_mod.ArrayReader,

    /// Parse a miniBLIP archive from a buffer.
    pub fn init(buf: []const u8) ContainerError!ArchiveReader {
        const outer = try array_mod.ArrayReader.init(buf);
        return ArchiveReader{
            .buf = buf,
            .outer = outer,
        };
    }

    /// Verify the magic bytes at element 0.
    /// Returns true if element 0 is RAW("BLIP\x01").
    pub fn verifyMagic(self: ArchiveReader) ContainerError!bool {
        if (self.outer.elementCount() < 1) return false;
        const view = try self.outer.elementAt(0);
        if (view.container_type != .raw) return false;
        const value = view.valueSlice();
        return std.mem.eql(u8, value, MAGIC);
    }

    /// Returns the number of files in the archive.
    pub fn fileCount(self: ArchiveReader) ContainerError!u64 {
        if (self.outer.elementCount() < 2) return 0;
        const body_view = try self.outer.elementAt(1);
        // body_view gives us a ContainerView; we need to init an ArrayReader on it.
        // The buf in body_view starts at the body's position in the outer buffer.
        const body_start = @intFromPtr(body_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const body_end = body_start + @as(usize, @intCast(body_view.total_length));
        const body_buf = self.buf[body_start..body_end];
        const body_reader = try array_mod.ArrayReader.init(body_buf);
        return body_reader.elementCount();
    }

    /// Get a DictReader for the file at the given index in the body array.
    pub fn fileAt(self: ArchiveReader, index: u64) ContainerError!dict_mod.DictReader {
        const body_view = try self.outer.elementAt(1);
        const body_start = @intFromPtr(body_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const body_end = body_start + @as(usize, @intCast(body_view.total_length));
        const body_buf = self.buf[body_start..body_end];
        const body_reader = try array_mod.ArrayReader.init(body_buf);

        const file_view = try body_reader.elementAt(index);
        const file_start = @intFromPtr(file_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const file_end = file_start + @as(usize, @intCast(file_view.total_length));
        const file_buf = self.buf[file_start..file_end];
        return dict_mod.DictReader.init(file_buf);
    }

    /// Verify the outer array's xxHash64 integrity check.
    pub fn verifyHash(self: ArchiveReader) ContainerError!bool {
        return self.outer.verifyHash();
    }

    /// Find a file by its path. Returns a DictReader for the matching FILE, or null.
    pub fn findFile(self: ArchiveReader, path: []const u8) ContainerError!?dict_mod.DictReader {
        const count = try self.fileCount();
        for (0..count) |i| {
            const file_reader = try self.fileAt(i);
            // Look for "path" key
            const path_idx = try file_reader.findKey("path");
            if (path_idx) |idx| {
                const path_val_container = try file_reader.valueAt(idx);
                const path_val = try leaf.readUtf8(path_val_container);
                if (std.mem.eql(u8, path_val, path)) {
                    return file_reader;
                }
            }
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "empty archive (0 files) creates valid archive with magic + empty body" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{};
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expectEqual(@as(u64, 0), try reader.fileCount());
    try testing.expect(try reader.verifyHash());
}

test "single file archive round-trip" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "hello.txt", .content = "Hello, world!\n", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());
    try testing.expect(try reader.verifyHash());

    // Read back file
    const file_reader = try reader.fileAt(0);
    const path_idx = (try file_reader.findKey("path")).?;
    const path_val = try leaf.readUtf8(try file_reader.valueAt(path_idx));
    try testing.expectEqualSlices(u8, "hello.txt", path_val);

    const bina_idx = (try file_reader.findKey("bina")).?;
    const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
    try testing.expectEqualSlices(u8, "Hello, world!\n", bina_val);
}

test "multi-file archive (3 files) path sorting" {
    const allocator = testing.allocator;
    // Add files out of order; they should be sorted by path in the archive
    const files = [_]FileEntry{
        .{ .path = "src/c.zig", .content = "c content", .metadata = null },
        .{ .path = "src/a.zig", .content = "a content", .metadata = null },
        .{ .path = "src/b.zig", .content = "b content", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 3), try reader.fileCount());

    // Verify sorted order: a, b, c
    const expected_paths = [_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig" };
    const expected_contents = [_][]const u8{ "a content", "b content", "c content" };

    for (expected_paths, expected_contents, 0..) |expected_path, expected_content, i| {
        const file_reader = try reader.fileAt(i);
        const path_idx = (try file_reader.findKey("path")).?;
        const path_val = try leaf.readUtf8(try file_reader.valueAt(path_idx));
        try testing.expectEqualSlices(u8, expected_path, path_val);

        const bina_idx = (try file_reader.findKey("bina")).?;
        const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
        try testing.expectEqualSlices(u8, expected_content, bina_val);
    }
}

test "round-trip: createArchive -> ArchiveReader -> extract each file" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "README.md", .content = "# Hello", .metadata = null },
        .{ .path = "src/main.zig", .content = "pub fn main() void {}", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 2), try reader.fileCount());

    // Files should be sorted: "README.md" < "src/main.zig"
    {
        const fr = try reader.fileAt(0);
        const path_idx = (try fr.findKey("path")).?;
        try testing.expectEqualSlices(u8, "README.md", try leaf.readUtf8(try fr.valueAt(path_idx)));
        const bina_idx = (try fr.findKey("bina")).?;
        try testing.expectEqualSlices(u8, "# Hello", try leaf.readRaw(try fr.valueAt(bina_idx)));
    }
    {
        const fr = try reader.fileAt(1);
        const path_idx = (try fr.findKey("path")).?;
        try testing.expectEqualSlices(u8, "src/main.zig", try leaf.readUtf8(try fr.valueAt(path_idx)));
        const bina_idx = (try fr.findKey("bina")).?;
        try testing.expectEqualSlices(u8, "pub fn main() void {}", try leaf.readRaw(try fr.valueAt(bina_idx)));
    }
}

test "verifyMagic on valid archive returns true" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{};
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
}

test "verifyHash on valid archive returns true" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "test content", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyHash());
}

test "findFile by path returns correct DictReader" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "alpha.txt", .content = "alpha data", .metadata = null },
        .{ .path = "beta.txt", .content = "beta data", .metadata = null },
        .{ .path = "gamma.txt", .content = "gamma data", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const found = (try reader.findFile("beta.txt")).?;
    const bina_idx = (try found.findKey("bina")).?;
    const bina_val = try leaf.readRaw(try found.valueAt(bina_idx));
    try testing.expectEqualSlices(u8, "beta data", bina_val);
}

test "findFile nonexistent path returns null" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "exists.txt", .content = "data", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const found = try reader.findFile("nonexistent.txt");
    try testing.expectEqual(@as(?dict_mod.DictReader, null), found);
}

test "file content xxHash64 matches stored xh64 value" {
    const allocator = testing.allocator;
    const content = "The quick brown fox jumps over the lazy dog";
    const files = [_]FileEntry{
        .{ .path = "fox.txt", .content = content, .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const file_reader = try reader.fileAt(0);

    // Extract stored xh64 value
    const xh64_idx = (try file_reader.findKey("xh64")).?;
    const xh64_val = try leaf.readRaw(try file_reader.valueAt(xh64_idx));
    try testing.expectEqual(@as(usize, 8), xh64_val.len);
    const stored_hash = std.mem.readInt(u64, xh64_val[0..8], .little);

    // Compute expected hash
    const expected_hash = XxHash64.hash(0, content);
    try testing.expectEqual(expected_hash, stored_hash);

    // Also verify by extracting the content and re-hashing
    const bina_idx = (try file_reader.findKey("bina")).?;
    const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
    const recomputed_hash = XxHash64.hash(0, bina_val);
    try testing.expectEqual(stored_hash, recomputed_hash);
}

test "archive with metadata preserves extra key-value pairs" {
    const allocator = testing.allocator;

    // Create metadata: "mode" key with a RAW value
    // "mode" sorts between "bina" and "path" canonically: "bina" < "mode" < "path" < "xh64"
    const meta_key = try leaf.serializeUtf8(allocator, "mode");
    defer allocator.free(meta_key);
    const meta_val = try leaf.serializeRaw(allocator, &[_]u8{ 0x01, 0xA4 }); // 0o644
    defer allocator.free(meta_val);

    const metadata = [_]dict_mod.KeyValue{
        .{ .key = meta_key, .value = meta_val },
    };

    const files = [_]FileEntry{
        .{ .path = "script.sh", .content = "#!/bin/bash\n", .metadata = &metadata },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const file_reader = try reader.fileAt(0);

    // Should have 4 pairs: bina, mode, path, xh64
    try testing.expectEqual(@as(u64, 4), file_reader.pairCount());

    // Verify metadata is present
    const mode_idx = (try file_reader.findKey("mode")).?;
    const mode_val = try leaf.readRaw(try file_reader.valueAt(mode_idx));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xA4 }, mode_val);

    // Verify required keys still work
    try testing.expect((try file_reader.findKey("bina")) != null);
    try testing.expect((try file_reader.findKey("path")) != null);
    try testing.expect((try file_reader.findKey("xh64")) != null);
}

test "multiple files with same prefix sorted correctly" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "src/b.zig", .content = "b", .metadata = null },
        .{ .path = "src/a.zig", .content = "a", .metadata = null },
        .{ .path = "src/ab.zig", .content = "ab", .metadata = null },
        .{ .path = "src/aa.zig", .content = "aa", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 4), try reader.fileCount());

    // Expected canonical byte order: "src/a.zig" < "src/aa.zig" < "src/ab.zig" < "src/b.zig"
    const expected_paths = [_][]const u8{ "src/a.zig", "src/aa.zig", "src/ab.zig", "src/b.zig" };
    const expected_contents = [_][]const u8{ "a", "aa", "ab", "b" };

    for (expected_paths, expected_contents, 0..) |expected_path, expected_content, i| {
        const file_reader = try reader.fileAt(i);
        const path_idx = (try file_reader.findKey("path")).?;
        const path_val = try leaf.readUtf8(try file_reader.valueAt(path_idx));
        try testing.expectEqualSlices(u8, expected_path, path_val);

        const bina_idx = (try file_reader.findKey("bina")).?;
        const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
        try testing.expectEqualSlices(u8, expected_content, bina_val);
    }
}

test "archive with empty file content" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "empty.txt", .content = "", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());

    const file_reader = try reader.fileAt(0);
    const bina_idx = (try file_reader.findKey("bina")).?;
    const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
    try testing.expectEqual(@as(usize, 0), bina_val.len);

    // Empty content hash should be xxHash64 of empty input
    const xh64_idx = (try file_reader.findKey("xh64")).?;
    const xh64_val = try leaf.readRaw(try file_reader.valueAt(xh64_idx));
    const stored_hash = std.mem.readInt(u64, xh64_val[0..8], .little);
    const expected_hash = XxHash64.hash(0, "");
    try testing.expectEqual(expected_hash, stored_hash);
}

test "archive with large file content" {
    const allocator = testing.allocator;

    // Create a 10KB content buffer
    const content = try allocator.alloc(u8, 10240);
    defer allocator.free(content);
    for (content, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const files = [_]FileEntry{
        .{ .path = "big.bin", .content = content, .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expect(try reader.verifyHash());
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());

    // Verify content round-trips
    const file_reader = try reader.fileAt(0);
    const bina_idx = (try file_reader.findKey("bina")).?;
    const bina_val = try leaf.readRaw(try file_reader.valueAt(bina_idx));
    try testing.expectEqualSlices(u8, content, bina_val);
}

test "findFile on empty archive returns null" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{};
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const found = try reader.findFile("anything.txt");
    try testing.expectEqual(@as(?dict_mod.DictReader, null), found);
}

test "outer array element count is 2 (magic + body)" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "data", .metadata = null },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 2), reader.outer.elementCount());
}
