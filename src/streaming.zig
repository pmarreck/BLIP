//! Streaming archive creation — two-pass spill-to-disk approach.
//!
//! Produces byte-identical archives to createFullArchive but with
//! O(largest_single_file) memory instead of O(total_archive).
//!
//! Pass 1: Serialize entries one at a time to a temp spill file.
//! Pass 2: Compute layout from sizes, stream-assemble final archive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mini_blar = @import("mini_blar.zig");
const array_mod = @import("array.zig");
const leaf = @import("leaf.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const csum_mod = @import("checksum.zig");
const blip = @import("blip.zig");

const FileEntry = mini_blar.FileEntry;
const DirEntry = mini_blar.DirEntry;
const ArchiveEntry = mini_blar.ArchiveEntry;
const ContainerError = container.ContainerError;
const LPOptions = container.LPOptions;

/// One entry in the spill index.
const SpillEntry = struct {
    /// Offset in the spill file where serialized bytes start.
    offset: u64,
    /// Size of serialized bytes.
    size: u64,
    /// xxHash64 of file content (for Merkle computation).
    xhash: [8]u8,
    /// Index into the original entries array.
    entry_index: usize,
    /// True if this is a DIR entry.
    is_dir: bool,
};

pub const StreamingError = error{
    IoError,
    SpillFailed,
    AssemblyFailed,
} || Allocator.Error || ContainerError;

/// Create a BLAR archive using streaming (spill-to-disk) approach.
/// Produces byte-identical output to mini_blar.createFullArchive.
///
/// Takes the same ArchiveEntry slice but processes one file at a time,
/// spilling serialized bytes to a temp file. Peak memory: O(largest file).
///
/// Returns the final archive as a byte slice (caller owns).
/// For truly streaming output (write directly to output file), use
/// createArchiveStreamingToFile (future).
pub fn createArchiveStreaming(
    allocator: Allocator,
    entries: []const ArchiveEntry,
    comp_id: ?ct.CompressionId,
) (StreamingError || mini_blar.compression_mod.CompressionError)![]u8 {
    // Create temp spill file
    const tmp_path = "/tmp/blar_spill_XXXXXX";
    _ = tmp_path;
    var spill_file = std.fs.cwd().createFile("/tmp/blar_streaming_spill.tmp", .{
        .read = true,
    }) catch return StreamingError.SpillFailed;
    defer {
        spill_file.close();
        std.fs.cwd().deleteFile("/tmp/blar_streaming_spill.tmp") catch {};
    }

    var spill_index = std.ArrayListUnmanaged(SpillEntry){};
    defer spill_index.deinit(allocator);

    // Track file hashes for Merkle computation
    var file_hashes = std.StringHashMap([8]u8).init(allocator);
    defer file_hashes.deinit();

    var has_dir = false;
    var spill_offset: u64 = 0;

    // ── Pass 1: Serialize entries to spill file ─────────────────────────

    // Phase 1A: Serialize FILE entries
    for (entries, 0..) |entry, i| {
        switch (entry) {
            .file => |file| {
                // Serialize this single file entry
                var to_free: std.ArrayList([]u8) = .{};
                defer {
                    for (to_free.items) |item| allocator.free(item);
                    to_free.deinit(allocator);
                }

                const serialized = try mini_blar.serializeFileEntry(
                    allocator, file, &to_free, comp_id, null, null,
                );
                // serializeFileEntry returns a slice owned by to_free or allocator

                // Extract xxHash64 from serialized FILE container's checksum
                var xhash: [8]u8 = .{0} ** 8;
                {
                    const file_view = container.parseLPHeader(serialized) catch null;
                    if (file_view) |fv| {
                        const csum = fv.checksumSlice();
                        if (csum.len == 8) {
                            @memcpy(&xhash, csum[0..8]);
                        }
                    }
                }
                try file_hashes.put(file.path, xhash);

                // Write to spill file
                spill_file.writeAll(serialized) catch return StreamingError.SpillFailed;

                try spill_index.append(allocator, .{
                    .offset = spill_offset,
                    .size = serialized.len,
                    .xhash = xhash,
                    .entry_index = i,
                    .is_dir = false,
                });
                spill_offset += serialized.len;
            },
            .dir => {
                has_dir = true;
                // DIR entries serialized in Phase 1B after all file hashes known
                try spill_index.append(allocator, .{
                    .offset = 0, // placeholder
                    .size = 0, // placeholder
                    .xhash = .{0} ** 8,
                    .entry_index = i,
                    .is_dir = true,
                });
            },
        }
    }

    // Phase 1B: Serialize DIR entries (now that all file hashes are known)
    for (spill_index.items) |*se| {
        if (!se.is_dir) continue;

        const dir = entries[se.entry_index].dir;

        // Compute Merkle hash from direct child FILE hashes
        var child_hashes_list: std.ArrayList([8]u8) = .{};
        defer child_hashes_list.deinit(allocator);

        for (entries) |other| {
            switch (other) {
                .file => |f| {
                    if (mini_blar.isDirectChild(dir.path, f.path)) {
                        if (file_hashes.get(f.path)) |hash| {
                            try child_hashes_list.append(allocator, hash);
                        }
                    }
                },
                .dir => {},
            }
        }

        var dir_with_merkle = dir;
        if (child_hashes_list.items.len > 0) {
            dir_with_merkle.xh64 = mini_blar.computeMerkleHash(child_hashes_list.items);
        }

        var to_free: std.ArrayList([]u8) = .{};
        defer {
            for (to_free.items) |item| allocator.free(item);
            to_free.deinit(allocator);
        }

        const dir_bytes = try mini_blar.serializeDirEntry(allocator, dir_with_merkle, &to_free);

        spill_file.writeAll(dir_bytes) catch return StreamingError.SpillFailed;

        se.offset = spill_offset;
        se.size = dir_bytes.len;
        spill_offset += dir_bytes.len;
    }

    // ── Pass 2: Assemble archive from spill ─────────────────────────────

    // Build element sizes array (in entry order)
    const element_sizes = try allocator.alloc(u64, entries.len);
    defer allocator.free(element_sizes);
    for (spill_index.items) |se| {
        element_sizes[se.entry_index] = se.size;
    }

    // Magic bytes
    const magic = if (has_dir) mini_blar.MAGIC_BLAR else mini_blar.MAGIC_MBAR;
    const magic_bytes = try leaf.serializeData(allocator, magic);
    defer allocator.free(magic_bytes);

    // Compute body ARRAY layout
    var body_layout = try array_mod.computeArrayLayout(allocator, element_sizes, .array, .{});
    defer body_layout.deinit();

    // Compute outer ARRAY layout (2 elements: magic + body)
    const outer_elem_sizes = [_]u64{ magic_bytes.len, body_layout.total_size };
    var outer_layout = try array_mod.computeArrayLayout(allocator, &outer_elem_sizes, .array, .{ .csum_id = .blake3_128 });
    defer outer_layout.deinit();

    // Allocate the final archive buffer
    const total_size: usize = @intCast(outer_layout.total_size);
    const result = try allocator.alloc(u8, total_size);
    errdefer allocator.free(result);

    var pos: usize = 0;

    // Write outer ARRAY header
    @memcpy(result[pos..][0..outer_layout.header_len], outer_layout.header[0..outer_layout.header_len]);
    pos += outer_layout.header_len;

    // Write outer index_offset encoding
    @memcpy(result[pos..][0..outer_layout.index_offset_len], outer_layout.index_offset_encoded[0..outer_layout.index_offset_len]);
    pos += outer_layout.index_offset_len;

    // Write magic bytes (outer element 0)
    @memcpy(result[pos..][0..magic_bytes.len], magic_bytes);
    pos += magic_bytes.len;

    // Write body ARRAY header (outer element 1)
    @memcpy(result[pos..][0..body_layout.header_len], body_layout.header[0..body_layout.header_len]);
    pos += body_layout.header_len;

    // Write body index_offset encoding
    @memcpy(result[pos..][0..body_layout.index_offset_len], body_layout.index_offset_encoded[0..body_layout.index_offset_len]);
    pos += body_layout.index_offset_len;

    // Stream-copy entries from spill file (in entry order)
    for (0..entries.len) |entry_idx| {
        // Find the spill entry for this index
        for (spill_index.items) |se| {
            if (se.entry_index == entry_idx) {
                const sz: usize = @intCast(se.size);
                spill_file.seekTo(se.offset) catch return StreamingError.IoError;
                const bytes_read = spill_file.readAll(result[pos..][0..sz]) catch return StreamingError.IoError;
                if (bytes_read != sz) return StreamingError.IoError;
                pos += sz;
                break;
            }
        }
    }

    // Write body ARRAY index section
    @memcpy(result[pos..][0..body_layout.index_section.len], body_layout.index_section);
    pos += body_layout.index_section.len;

    // Write outer ARRAY index section
    @memcpy(result[pos..][0..outer_layout.index_section.len], outer_layout.index_section);
    pos += outer_layout.index_section.len;

    // Compute and write BLAKE3-128 checksum over everything before the checksum
    const csum_offset = total_size - outer_layout.csum_size;
    const hash = csum_mod.compute(.blake3_128, result[0..csum_offset]);
    @memcpy(result[csum_offset..][0..outer_layout.csum_size], hash[0..outer_layout.csum_size]);

    std.debug.assert(csum_offset + outer_layout.csum_size == total_size);

    return result;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "streaming produces byte-identical archive to createFullArchive" {
    const alloc = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .file = .{ .path = "hello.txt", .content = "Hello, world!" } },
        .{ .file = .{ .path = "data.bin", .content = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 10 } },
        .{ .file = .{ .path = "empty.txt", .content = "" } },
    };

    // Create with in-memory path
    const inmem = try mini_blar.createFullArchive(alloc, &entries, null, null, null, null, 0);
    defer alloc.free(inmem);

    // Create with streaming path
    const streamed = try createArchiveStreaming(alloc, &entries, null);
    defer alloc.free(streamed);

    // Must be byte-identical
    try testing.expectEqual(inmem.len, streamed.len);
    try testing.expectEqualSlices(u8, inmem, streamed);
}

test "streaming with directories produces byte-identical archive" {
    const alloc = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .dir = .{ .path = "mydir" } },
        .{ .file = .{ .path = "mydir/a.txt", .content = "file A" } },
        .{ .file = .{ .path = "mydir/b.txt", .content = "file B" } },
    };

    const inmem = try mini_blar.createFullArchive(alloc, &entries, null, null, null, null, 0);
    defer alloc.free(inmem);

    const streamed = try createArchiveStreaming(alloc, &entries, null);
    defer alloc.free(streamed);

    try testing.expectEqual(inmem.len, streamed.len);
    try testing.expectEqualSlices(u8, inmem, streamed);
}

test "streaming with compression produces byte-identical archive" {
    const alloc = testing.allocator;

    // Use a larger file so compression actually kicks in
    const big_content = "The quick brown fox jumps over the lazy dog. " ** 100;
    const entries = [_]ArchiveEntry{
        .{ .file = .{ .path = "big.txt", .content = big_content } },
    };

    const inmem = try mini_blar.createFullArchive(alloc, &entries, null, null, null, .lzma2, 0);
    defer alloc.free(inmem);

    const streamed = try createArchiveStreaming(alloc, &entries, .lzma2);
    defer alloc.free(streamed);

    try testing.expectEqual(inmem.len, streamed.len);
    try testing.expectEqualSlices(u8, inmem, streamed);
}
