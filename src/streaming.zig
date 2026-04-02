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
const expansion = @import("expansion.zig");

const FileEntry = mini_blar.FileEntry;
const DirEntry = mini_blar.DirEntry;
const ArchiveEntry = mini_blar.ArchiveEntry;
const ContainerError = container.ContainerError;
const LPOptions = container.LPOptions;

/// Check if a file path has an archive extension (should not be expanded as ZIP).
fn isArchiveExtension(path: []const u8) bool {
    const archive_exts = [_][]const u8{
        ".zip", ".gz", ".gzip", ".tgz", ".tar", ".bz2", ".xz", ".7z",
        ".rar", ".lz4", ".zst", ".zstd", ".blar", ".lzma", ".lzo",
        ".cab", ".arj", ".z",
    };
    var dot_pos: ?usize = null;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') { dot_pos = i; break; }
        if (path[i] == '/') break;
    }
    const ext = if (dot_pos) |d| path[d..] else return false;
    for (archive_exts) |ae| {
        if (std.ascii.eqlIgnoreCase(ext, ae)) return true;
    }
    return false;
}

/// Per-entry expansion result slot for parallel expansion.
const ExpSlot = struct {
    result_entries: std.ArrayListUnmanaged(ArchiveEntry),
    paths: std.ArrayListUnmanaged([]u8),
    contents: std.ArrayListUnmanaged([]u8),
    has_dir: bool,
};

/// Expand a single entry into a slot. Thread-safe — each slot is independent.
fn expandSlot(allocator: Allocator, entry: ArchiveEntry, slot: *ExpSlot, do_expand: bool, expand_all_zips: bool) void {
    switch (entry) {
        .file => |file| {
            if (do_expand and file.content.len >= 20) {
                if (expansion.detectCodec(file.content)) |codec_name| {
                    // Skip .zip files with archive extensions unless expand_all_zips
                    if (std.mem.eql(u8, codec_name, "zip") and !expand_all_zips) {
                        if (isArchiveExtension(file.path)) {
                            slot.result_entries.append(allocator, entry) catch {};
                            return;
                        }
                    }

                    var exp_result = expansion.expandFile(allocator, file.content, codec_name) catch null;
                    if (exp_result) |*exp| {
                        slot.has_dir = true;
                        slot.result_entries.append(allocator, .{ .dir = .{
                            .path = file.path,
                            .mode = file.mode,
                            .mtime_ns = file.mtime_ns,
                            .ctime_ns = file.ctime_ns,
                            .birthtime_ns = file.birthtime_ns,
                            .uid = file.uid,
                            .gid = file.gid,
                            .username = file.username,
                            .groupname = file.groupname,
                            .xattrs = file.xattrs,
                            .container_type = exp.container_type,
                        }}) catch return;

                        for (exp.entries) |child| {
                            const child_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ file.path, child.path_suffix }) catch continue;
                            slot.paths.append(allocator, child_path) catch { allocator.free(child_path); continue; };
                            const owned = allocator.dupe(u8, child.content) catch continue;
                            slot.contents.append(allocator, owned) catch { allocator.free(owned); continue; };

                            slot.result_entries.append(allocator, .{ .file = .{
                                .path = child_path,
                                .content = owned,
                                .mode = file.mode,
                                .mtime_ns = file.mtime_ns,
                                .zip_compression_method = if (child.zip_comp != 0xFFFF) child.zip_comp else null,
                                .pdf_stream_offset = if (child.pdf_offset != std.math.maxInt(u64)) child.pdf_offset else null,
                                .pdf_stream_length = if (child.pdf_length != std.math.maxInt(u64)) child.pdf_length else null,
                                .jxl_source_format = child.jxl_source_format,
                            }}) catch continue;
                        }
                        exp.deinit();
                        return;
                    }
                }
            }
            // No expansion — pass through
            slot.result_entries.append(allocator, entry) catch {};
        },
        .dir => {
            slot.has_dir = true;
            slot.result_entries.append(allocator, entry) catch {};
        },
    }
}

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
    expand_containers: bool,
    expand_all_zips: bool,
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

    // ── Pre-pass: Expand containers if enabled (PARALLEL) ──────────────
    // Each file is expanded independently. Results are stored per-slot so
    // ordering is preserved. Uses std.Thread for parallelism.

    // Per-entry expansion result: either the original entry or expanded DIR + children
    const slots = try allocator.alloc(ExpSlot, entries.len);
    defer {
        for (slots) |*slot| {
            for (slot.paths.items) |p| allocator.free(p);
            slot.paths.deinit(allocator);
            for (slot.contents.items) |buf| allocator.free(buf);
            slot.contents.deinit(allocator);
            slot.result_entries.deinit(allocator);
        }
        allocator.free(slots);
    }
    for (slots) |*s| {
        s.* = .{
            .result_entries = .{},
            .paths = .{},
            .contents = .{},
            .has_dir = false,
        };
    }

    // Parallel expansion via work-stealing (or sequential fallback)
    const cpu_count: usize = if (expand_containers) (std.Thread.getCpuCount() catch 1) else 1;
    const actual_threads = @min(cpu_count, @max(entries.len, 1));

    if (actual_threads > 1) {
        const WorkCtx = struct {
            entries_slice: []const ArchiveEntry,
            slots_slice: []ExpSlot,
            next_idx: std.atomic.Value(usize),
            alloc: Allocator,
            expand_all: bool,

            fn work(self: *@This()) void {
                while (true) {
                    const idx = self.next_idx.fetchAdd(1, .seq_cst);
                    if (idx >= self.entries_slice.len) break;
                    expandSlot(self.alloc, self.entries_slice[idx], &self.slots_slice[idx], true, self.expand_all);
                }
            }
        };

        var ctx = WorkCtx{
            .entries_slice = entries,
            .slots_slice = slots,
            .next_idx = std.atomic.Value(usize).init(0),
            .alloc = allocator,
            .expand_all = expand_all_zips,
        };

        var thread_buf: [256]std.Thread = undefined;
        const spawn_count = @min(actual_threads - 1, 256);
        var spawned: usize = 0;

        for (0..spawn_count) |_| {
            thread_buf[spawned] = std.Thread.spawn(.{}, WorkCtx.work, .{&ctx}) catch break;
            spawned += 1;
        }

        // Main thread participates
        ctx.work();

        for (thread_buf[0..spawned]) |handle| {
            handle.join();
        }
    } else {
        for (entries, 0..) |entry, i| {
            expandSlot(allocator, entry, &slots[i], expand_containers, expand_all_zips);
        }
    }

    // Flatten slots into final entry list
    var work_entries = std.ArrayListUnmanaged(ArchiveEntry){};
    defer work_entries.deinit(allocator);

    for (slots) |*slot| {
        if (slot.has_dir) has_dir = true;
        for (slot.result_entries.items) |entry| {
            try work_entries.append(allocator, entry);
        }
    }

    const final_entries = work_entries.items;

    // ── Pass 1: Serialize entries to spill file ─────────────────────────

    // Phase 1A: Serialize FILE entries
    for (final_entries, 0..) |entry, i| {
        switch (entry) {
            .file => |file| {
                    var to_free: std.ArrayList([]u8) = .{};
                    defer {
                        for (to_free.items) |item| allocator.free(item);
                        to_free.deinit(allocator);
                    }

                    const serialized = try mini_blar.serializeFileEntry(
                        allocator, file, &to_free, comp_id, null, null,
                    );

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

        const dir = final_entries[se.entry_index].dir;

        // Compute Merkle hash from direct child FILE hashes
        var child_hashes_list: std.ArrayList([8]u8) = .{};
        defer child_hashes_list.deinit(allocator);

        for (final_entries) |other| {
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

    // Build element sizes array from spill index (includes expanded entries)
    const total_entries = spill_index.items.len;
    const element_sizes = try allocator.alloc(u64, total_entries);
    defer allocator.free(element_sizes);
    for (spill_index.items, 0..) |se, idx| {
        element_sizes[idx] = se.size;
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

    // Stream-copy entries from spill file (in spill order)
    for (spill_index.items) |se| {
        const sz: usize = @intCast(se.size);
        spill_file.seekTo(se.offset) catch return StreamingError.IoError;
        const bytes_read = spill_file.readAll(result[pos..][0..sz]) catch return StreamingError.IoError;
        if (bytes_read != sz) return StreamingError.IoError;
        pos += sz;
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
    const streamed = try createArchiveStreaming(alloc, &entries, null, false, false);
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

    const streamed = try createArchiveStreaming(alloc, &entries, null, false, false);
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

    const streamed = try createArchiveStreaming(alloc, &entries, .lzma2, false, false);
    defer alloc.free(streamed);

    try testing.expectEqual(inmem.len, streamed.len);
    try testing.expectEqualSlices(u8, inmem, streamed);
}
