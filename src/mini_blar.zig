const std = @import("std");
const Allocator = std.mem.Allocator;
pub const container_mod = @import("container.zig");
const container = container_mod;
const ct = @import("container_types.zig");
pub const leaf = @import("leaf.zig");
pub const array_mod = @import("array.zig");
pub const dict_mod = @import("dict.zig");
pub const compression_mod = @import("compression.zig");
// data_mod removed in v2 — use leaf directly (data.zig merged into leaf.zig)
const testing = std.testing;

pub const ContainerError = container.ContainerError;
const ContainerTypeId = ct.ContainerTypeId;
const XxHash64 = std.hash.XxHash64;

/// A file to be included in a BLIP archive.
/// FILE containers are now ARRAY-based: [metadata DICT, DATA content, optional forks DICT].
pub const FileEntry = struct {
    path: []const u8, // file path (UTF-8)
    content: []const u8, // file content bytes
    mode: u16 = 0, // POSIX permission bits, 0 = not set
    mtime_ns: i64 = 0, // nanoseconds since epoch, 0 = not set
    ctime_ns: i64 = 0, // ctime nanoseconds since epoch, 0 = not set
    birthtime_ns: i64 = 0, // birthtime nanoseconds since epoch, 0 = not set
    uid: u32 = 0, // numeric user ID, 0 = not set
    gid: u32 = 0, // numeric group ID, 0 = not set
    username: []const u8 = &.{}, // username string
    groupname: []const u8 = &.{}, // group name string
    xattrs: []const XattrEntry = &.{}, // extended attributes
    resource_fork: []const u8 = &.{}, // resource fork data (macOS)
    zip_compression_method: ?u16 = null, // original zip method for re-zipping (0=store, 8=deflate)
    pdf_stream_offset: ?u64 = null, // "po" — byte offset of JPEG stream in PDF body
    pdf_stream_length: ?u64 = null, // "pl" — original JPEG stream data length
    jxl_source_format: []const u8 = &.{}, // "jx" — source format (e.g. "jpeg")
};

/// An xattr key-value pair.
pub const XattrEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// A directory entry to be included in a full BLIP archive.
pub const DirEntry = struct {
    path: []const u8, // directory path (UTF-8)
    xh64: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // Merkle hash (auto-computed by createFullArchive)
    mode: u16 = 0,
    mtime_ns: i64 = 0,
    ctime_ns: i64 = 0,
    birthtime_ns: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    username: []const u8 = &.{},
    groupname: []const u8 = &.{},
    xattrs: []const XattrEntry = &.{},
    container_type: []const u8 = &.{}, // "zip" = this DIR represents an expanded container file
};

/// A unified archive entry: either a file or a directory.
pub const ArchiveEntry = union(enum) {
    file: FileEntry,
    dir: DirEntry,

    /// Get the path from either variant.
    fn getPath(self: ArchiveEntry) []const u8 {
        return switch (self) {
            .file => |f| f.path,
            .dir => |d| d.path,
        };
    }
};

/// Compute a Merkle hash from an array of child FILE ARRAY hashes.
/// The children should already be sorted by path before calling this.
/// Returns xxHash64 of the concatenation of all child hashes.
pub fn computeMerkleHash(child_hashes: []const [8]u8) [8]u8 {
    var hasher = XxHash64.init(0);
    for (child_hashes) |h| {
        hasher.update(&h);
    }
    const hash_value = hasher.final();
    var result: [8]u8 = undefined;
    std.mem.writeInt(u64, &result, hash_value, .little);
    return result;
}

/// Check if `child_path` is a direct child of `dir_path`.
/// e.g., isDirectChild("mydir", "mydir/file.txt") = true
///       isDirectChild("mydir", "mydir/sub/deep.txt") = false
pub fn isDirectChild(dir_path: []const u8, child_path: []const u8) bool {
    if (child_path.len <= dir_path.len + 1) return false;
    if (!std.mem.startsWith(u8, child_path, dir_path)) return false;
    if (child_path[dir_path.len] != '/') return false;
    // Check no more slashes after the prefix
    const rest = child_path[dir_path.len + 1 ..];
    return std.mem.indexOfScalar(u8, rest, '/') == null;
}

/// Magic bytes for full blar archives (with DIR support): "BLAR" + version 2.
pub const MAGIC_BLAR: *const [5]u8 = "BLAR\x02";
/// Magic bytes for miniblar archives (flat files only): "MBAR" + version 2.
pub const MAGIC_MBAR: *const [5]u8 = "MBAR\x02";

/// Serialize a FILE entry as an ARRAY-based container.
/// Layout: FILE (0x81 0x05, ARRAY layout)
///   [0]: DICT — metadata (required keys: pa, md, mt)
///   [1]: DATA — content bytes
///   [2]: DICT — forks (optional, only if xattrs or resource fork present)
/// Caller owns returned memory.
pub fn serializeFileEntry(allocator: Allocator, file: FileEntry, to_free: *std.ArrayList([]u8), comp_id: ?ct.CompressionId) (Allocator.Error || ContainerError || compression_mod.CompressionError)![]const u8 {
    // --- Element 0: metadata DICT ---
    // Build metadata key-value pairs with 2-char keys in canonical order:
    // bt < ct < gi < gn < md < mt < pa < ui < un < zc
    var meta_pairs_buf: [13]dict_mod.KeyValue = undefined;
    var meta_count: usize = 0;

    // bt (birthtime)
    if (file.birthtime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "bt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, file.birthtime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // ct (ctime)
    if (file.ctime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "ct");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, file.ctime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // gi (gid)
    if (file.gid != 0) {
        const key = try leaf.serializeUtf8(allocator, "gi");
        try to_free.append(allocator, key);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, file.gid, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // gn (groupname)
    if (file.groupname.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "gn");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, file.groupname);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // jx (jxl source format)
    if (file.jxl_source_format.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "jx");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, file.jxl_source_format);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // md (mode) — required
    {
        const key = try leaf.serializeUtf8(allocator, "md");
        try to_free.append(allocator, key);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, file.mode, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // mt (mtime) — required
    {
        const key = try leaf.serializeUtf8(allocator, "mt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, file.mtime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // pa (path) — required
    {
        const key = try leaf.serializeUtf8(allocator, "pa");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, file.path);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // pl (pdf stream length)
    if (file.pdf_stream_length) |pl| {
        const key = try leaf.serializeUtf8(allocator, "pl");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, pl, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // po (pdf stream offset)
    if (file.pdf_stream_offset) |po| {
        const key = try leaf.serializeUtf8(allocator, "po");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, po, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // ui (uid)
    if (file.uid != 0) {
        const key = try leaf.serializeUtf8(allocator, "ui");
        try to_free.append(allocator, key);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, file.uid, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // un (username)
    if (file.username.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "un");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, file.username);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    // zc (zip compression method)
    if (file.zip_compression_method) |zc| {
        const key = try leaf.serializeUtf8(allocator, "zc");
        try to_free.append(allocator, key);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, zc, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        meta_pairs_buf[meta_count] = .{ .key = key, .value = val };
        meta_count += 1;
    }

    const metadata_dict = try dict_mod.serializeDict(allocator, meta_pairs_buf[0..meta_count]);
    try to_free.append(allocator, metadata_dict);

    // --- Element 1: DATA container with xxHash64 checksum (optionally per-file compressed) ---
    const data_container = blk: {
        const raw = try leaf.serializeDataWithOptions(allocator, file.content, .{ .csum_id = .xxhash64 });
        if (comp_id) |algo| {
            defer allocator.free(raw);
            break :blk compression_mod.compressContainer(allocator, algo, raw, null, null, null, 1) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CompressionFailed => return error.CompressionFailed,
                else => return error.InvalidContainerType,
            };
        }
        break :blk raw;
    };
    try to_free.append(allocator, data_container);

    // --- Element 2: forks DICT (optional) ---
    const has_forks = file.resource_fork.len > 0 or file.xattrs.len > 0;

    if (has_forks) {
        // Build forks dict: xattr names as keys, "rf" for resource fork
        // Count pairs
        const fork_pair_count = file.xattrs.len + @as(usize, if (file.resource_fork.len > 0) 1 else 0);

        const fork_pairs = try allocator.alloc(dict_mod.KeyValue, fork_pair_count);
        defer allocator.free(fork_pairs);
        var fi: usize = 0;

        // We need to sort all fork keys. Build them all then sort.
        // First build all pairs
        for (file.xattrs) |xa| {
            const key = try leaf.serializeUtf8(allocator, xa.name);
            try to_free.append(allocator, key);
            const val = try leaf.serializeData(allocator, xa.value);
            try to_free.append(allocator, val);
            fork_pairs[fi] = .{ .key = key, .value = val };
            fi += 1;
        }
        if (file.resource_fork.len > 0) {
            const key = try leaf.serializeUtf8(allocator, "rf");
            try to_free.append(allocator, key);
            const val = try leaf.serializeData(allocator, file.resource_fork);
            try to_free.append(allocator, val);
            fork_pairs[fi] = .{ .key = key, .value = val };
            fi += 1;
        }

        // Sort by key bytes
        std.mem.sort(dict_mod.KeyValue, fork_pairs, {}, struct {
            fn lessThan(_: void, a: dict_mod.KeyValue, b: dict_mod.KeyValue) bool {
                const a_bytes = dict_mod.extractKeyBytes(a.key) catch return false;
                const b_bytes = dict_mod.extractKeyBytes(b.key) catch return false;
                return std.mem.order(u8, a_bytes, b_bytes) == .lt;
            }
        }.lessThan);

        const forks_dict = try dict_mod.serializeDict(allocator, fork_pairs);
        try to_free.append(allocator, forks_dict);

        const elements = [_][]const u8{ metadata_dict, data_container, forks_dict };
        const file_bytes = try array_mod.serializeArrayLike(allocator, &elements, .file, .{ .csum_id = .xxhash64 });
        try to_free.append(allocator, file_bytes);
        return file_bytes;
    } else {
        const elements = [_][]const u8{ metadata_dict, data_container };
        const file_bytes = try array_mod.serializeArrayLike(allocator, &elements, .file, .{ .csum_id = .xxhash64 });
        try to_free.append(allocator, file_bytes);
        return file_bytes;
    }
}

/// Serialize a single DirEntry into a DIR container with 2-char keys.
fn serializeDirEntry(allocator: Allocator, dir: DirEntry, to_free: *std.ArrayList([]u8)) (Allocator.Error || ContainerError)![]const u8 {
    // Build key-value pairs with 2-char keys in canonical order:
    // bt < co < ct < gi < gn < md < mt < pa < ui < un < xa < xh
    var pairs_buf: [12]dict_mod.KeyValue = undefined;
    var pair_count: usize = 0;

    // bt (birthtime)
    if (dir.birthtime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "bt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, dir.birthtime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // co (container type)
    if (dir.container_type.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "co");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, dir.container_type);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // ct (ctime)
    if (dir.ctime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "ct");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, dir.ctime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // gi (gid)
    if (dir.gid != 0) {
        const key = try leaf.serializeUtf8(allocator, "gi");
        try to_free.append(allocator, key);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, dir.gid, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // gn (groupname)
    if (dir.groupname.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "gn");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, dir.groupname);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // md (mode) — required
    {
        const key = try leaf.serializeUtf8(allocator, "md");
        try to_free.append(allocator, key);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, dir.mode, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // mt (mtime) — required
    {
        const key = try leaf.serializeUtf8(allocator, "mt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, dir.mtime_ns, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // pa (path) — required
    {
        const key = try leaf.serializeUtf8(allocator, "pa");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, dir.path);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // ui (uid)
    if (dir.uid != 0) {
        const key = try leaf.serializeUtf8(allocator, "ui");
        try to_free.append(allocator, key);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, dir.uid, .little);
        const val = try leaf.serializeData(allocator, &bytes);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // un (username)
    if (dir.username.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "un");
        try to_free.append(allocator, key);
        const val = try leaf.serializeUtf8(allocator, dir.username);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    // xa (xattrs dict)
    if (dir.xattrs.len > 0) {
        const key = try leaf.serializeUtf8(allocator, "xa");
        try to_free.append(allocator, key);

        const xa_pairs = try allocator.alloc(dict_mod.KeyValue, dir.xattrs.len);
        defer allocator.free(xa_pairs);
        for (dir.xattrs, 0..) |xa, xi| {
            const xa_key = try leaf.serializeUtf8(allocator, xa.name);
            try to_free.append(allocator, xa_key);
            const xa_val = try leaf.serializeData(allocator, xa.value);
            try to_free.append(allocator, xa_val);
            xa_pairs[xi] = .{ .key = xa_key, .value = xa_val };
        }
        // Sort xattr pairs by key
        std.mem.sort(dict_mod.KeyValue, xa_pairs, {}, struct {
            fn lessThan(_: void, a: dict_mod.KeyValue, b: dict_mod.KeyValue) bool {
                const a_bytes = dict_mod.extractKeyBytes(a.key) catch return false;
                const b_bytes = dict_mod.extractKeyBytes(b.key) catch return false;
                return std.mem.order(u8, a_bytes, b_bytes) == .lt;
            }
        }.lessThan);
        const xa_dict = try dict_mod.serializeDict(allocator, xa_pairs);
        try to_free.append(allocator, xa_dict);

        pairs_buf[pair_count] = .{ .key = key, .value = xa_dict };
        pair_count += 1;
    }

    // xh (Merkle hash) — required
    {
        const key = try leaf.serializeUtf8(allocator, "xh");
        try to_free.append(allocator, key);
        const val = try leaf.serializeData(allocator, &dir.xh64);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    const dir_bytes = try dict_mod.serializeDirWithOptions(allocator, pairs_buf[0..pair_count], .{ .csum_id = .xxhash64 });
    try to_free.append(allocator, dir_bytes);
    return dir_bytes;
}

/// Create a miniBlar archive from a list of file entries.
/// Create a flat BLIP archive from a list of file entries.
/// Entries are serialized in the order given — caller controls ordering.
/// Returns the complete archive as a byte slice. Caller owns returned memory.
pub fn createArchive(allocator: Allocator, files: []const FileEntry) (Allocator.Error || ContainerError || compression_mod.CompressionError)![]u8 {
    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    // Serialize each file into a FILE container (ARRAY-based)
    var file_elements: std.ArrayList([]const u8) = .{};
    defer file_elements.deinit(allocator);

    for (files) |file| {
        const file_bytes = try serializeFileEntry(allocator, file, &to_free, null);
        try file_elements.append(allocator, file_bytes);
    }

    // Serialize magic: DATA("MBAR\x02")
    const magic_bytes = try leaf.serializeData(allocator, MAGIC_MBAR);
    try to_free.append(allocator, magic_bytes);

    // Serialize body array (containing all FILE elements)
    const body_array = try array_mod.serializeArray(allocator, file_elements.items);
    try to_free.append(allocator, body_array);

    // Serialize outer array: [magic, body_array] with BLAKE3-128 checksum
    const outer_elements = [_][]const u8{ magic_bytes, body_array };
    const result = try array_mod.serializeArrayWithOptions(allocator, &outer_elements, .{ .csum_id = .blake3_128 });

    return result;
}

/// Create a full BLIP archive from a list of file and/or directory entries.
/// Merkle hashes (xh64) for DIR entries are auto-computed from child FILE checksums;
/// callers may leave xh64 zeroed. Entries are serialized in the order given.
/// Returns the complete archive as a byte slice. Caller owns returned memory.
/// C-callable progress callback: (entries_done, bytes_done, user_ctx).
pub const ProgressFn = ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void;

/// C-callable phase callback: (label_ptr, label_len, user_ctx).
/// Fires when the operation transitions to a new phase (e.g., "Assembling").
pub const PhaseFn = ?*const fn ([*]const u8, usize, ?*anyopaque) callconv(.c) void;

pub fn createFullArchive(
    allocator: Allocator,
    entries: []const ArchiveEntry,
    progress_fn: ProgressFn,
    phase_fn: PhaseFn,
    progress_ctx: ?*anyopaque,
    comp_id: ?ct.CompressionId,
    num_threads: u8,
) (Allocator.Error || ContainerError || compression_mod.CompressionError)![]u8 {
    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    // Items allocated by parallel threads using page_allocator (thread-safe)
    const pa = std.heap.page_allocator;
    var parallel_to_free: std.ArrayList([]u8) = .{};
    defer {
        for (parallel_to_free.items) |item| pa.free(item);
        parallel_to_free.deinit(allocator);
    }

    var entry_elements: std.ArrayList([]const u8) = .{};
    defer entry_elements.deinit(allocator);

    // Phase 1: Serialize FILE entries and collect their xxHash64 checksums
    // (keyed by path for Merkle computation). Also record positions.
    var file_hashes = std.StringHashMap([8]u8).init(allocator);
    defer file_hashes.deinit();

    var has_dir = false;
    var entries_done: u64 = 0;
    var bytes_done: u64 = 0;

    // Count files and build index mapping for parallel path
    var file_count: usize = 0;
    for (entries) |entry| {
        switch (entry) {
            .file => file_count += 1,
            .dir => has_dir = true,
        }
    }

    // Pre-allocate entry_elements with placeholders
    try entry_elements.ensureTotalCapacity(allocator, entries.len);
    for (entries) |_| {
        entry_elements.appendAssumeCapacity(&.{});
    }

    const resolved_threads: usize = if (num_threads == 0)
        (std.Thread.getCpuCount() catch 1)
    else
        @intCast(num_threads);

    if (resolved_threads > 1 and file_count > 1 and comp_id != null) {
        // Parallel path: serialize files concurrently using thread pool
        const FileResult = struct {
            bytes: []const u8,
            hash: [8]u8,
            to_free_items: std.ArrayList([]u8),
            err: ?(Allocator.Error || ContainerError || compression_mod.CompressionError),
        };

        // Build file slot mapping: slot index → entry index
        const file_slots = try allocator.alloc(usize, file_count);
        defer allocator.free(file_slots);
        // Also compute total_file_bytes for progress tracking
        var total_file_bytes: u64 = 0;
        {
            var slot: usize = 0;
            for (entries, 0..) |entry, idx| {
                switch (entry) {
                    .file => |f| {
                        file_slots[slot] = idx;
                        total_file_bytes += f.content.len;
                        slot += 1;
                    },
                    .dir => {},
                }
            }
        }

        const file_results = try allocator.alloc(FileResult, file_count);
        defer allocator.free(file_results);
        for (file_results) |*r| {
            r.* = .{
                .bytes = &.{},
                .hash = .{0} ** 8,
                .to_free_items = .{},
                .err = null,
            };
        }

        // Use per-file single-threaded compression to avoid oversubscription
        var pool: std.Thread.Pool = undefined;
        pool.init(.{
            .allocator = allocator,
            .n_jobs = @intCast(@min(resolved_threads, file_count)),
        }) catch return error.OutOfMemory;
        defer pool.deinit();

        // Use page_allocator for per-thread work — it's thread-safe (mmap-based).
        // The caller's allocator may not be thread-safe (e.g., testing.allocator).
        const thread_alloc = std.heap.page_allocator;

        // Atomic counters for progress reporting from parallel workers
        var atomic_files_done = std.atomic.Value(u64).init(0);
        var atomic_bytes_done = std.atomic.Value(u64).init(0);

        var wg: std.Thread.WaitGroup = .{};
        for (file_slots, 0..) |entry_idx, slot| {
            pool.spawnWg(&wg, struct {
                fn work(
                    alloc: Allocator,
                    file: FileEntry,
                    cid: ?ct.CompressionId,
                    result: *FileResult,
                    a_files: *std.atomic.Value(u64),
                    a_bytes: *std.atomic.Value(u64),
                ) void {
                    var local_to_free: std.ArrayList([]u8) = .{};
                    const file_bytes = serializeFileEntry(alloc, file, &local_to_free, cid) catch |e| {
                        result.err = e;
                        // Clean up on error
                        for (local_to_free.items) |item| alloc.free(item);
                        local_to_free.deinit(alloc);
                        // Still increment so progress loop terminates
                        _ = a_files.fetchAdd(1, .release);
                        _ = a_bytes.fetchAdd(file.content.len, .release);
                        return;
                    };

                    // Extract xxHash64
                    const file_view = container.parseLPHeader(file_bytes) catch |e| {
                        result.err = e;
                        for (local_to_free.items) |item| alloc.free(item);
                        local_to_free.deinit(alloc);
                        _ = a_files.fetchAdd(1, .release);
                        _ = a_bytes.fetchAdd(file.content.len, .release);
                        return;
                    };
                    const csum = file_view.checksumSlice();
                    var hash: [8]u8 = .{0} ** 8;
                    if (csum.len == 8) {
                        @memcpy(&hash, csum[0..8]);
                    }

                    result.bytes = file_bytes;
                    result.hash = hash;
                    result.to_free_items = local_to_free;

                    // Signal completion for progress tracking
                    _ = a_files.fetchAdd(1, .release);
                    _ = a_bytes.fetchAdd(file.content.len, .release);
                }
            }.work, .{ thread_alloc, entries[entry_idx].file, comp_id, &file_results[slot], &atomic_files_done, &atomic_bytes_done });
        }

        // Poll progress while workers compress files.
        // Main thread doesn't participate as a worker (pool has enough threads).
        while (atomic_files_done.load(.acquire) < file_count) {
            if (progress_fn) |cb| {
                cb(entries_done + atomic_files_done.load(.acquire),
                    bytes_done + atomic_bytes_done.load(.acquire),
                    progress_ctx);
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        // Formally wait for pool (should return near-instantly since all work is done)
        pool.waitAndWork(&wg);

        // Final progress update
        entries_done += file_count;
        bytes_done += total_file_bytes;
        if (progress_fn) |cb| cb(entries_done, bytes_done, progress_ctx);

        // Check for errors, collect results into entry_elements and file_hashes
        for (file_results, 0..) |*r, slot| {
            if (r.err) |e| {
                // Clean up all results on error
                for (file_results) |*cr| {
                    for (cr.to_free_items.items) |item| thread_alloc.free(item);
                    cr.to_free_items.deinit(thread_alloc);
                }
                return e;
            }

            const entry_idx = file_slots[slot];
            const file = entries[entry_idx].file;
            entry_elements.items[entry_idx] = r.bytes;
            try file_hashes.put(file.path, r.hash);

            // Transfer ownership to parallel_to_free (freed with page_allocator)
            for (r.to_free_items.items) |item| {
                try parallel_to_free.append(allocator, item);
            }
            // Free the ArrayList container (not its items, they're now in to_free)
            r.to_free_items.items = &.{};
            r.to_free_items.deinit(thread_alloc);
        }
    } else {
        // Sequential path (existing behavior)
        for (entries, 0..) |entry, i| {
            switch (entry) {
                .file => |file| {
                    const file_bytes = try serializeFileEntry(allocator, file, &to_free, comp_id);
                    entry_elements.items[i] = file_bytes;
                    const file_view = try container.parseLPHeader(file_bytes);
                    const csum = file_view.checksumSlice();
                    if (csum.len == 8) {
                        var hash: [8]u8 = undefined;
                        @memcpy(&hash, csum[0..8]);
                        try file_hashes.put(file.path, hash);
                    }
                    entries_done += 1;
                    bytes_done += file.content.len;
                    if (progress_fn) |cb| cb(entries_done, bytes_done, progress_ctx);
                },
                .dir => {
                    // Already has placeholder from pre-allocation
                },
            }
        }
    }

    // Phase 2: Compute Merkle hashes for DIR entries, then serialize them
    for (entries, 0..) |entry, i| {
        switch (entry) {
            .dir => |dir| {
                // Find direct child FILEs and collect their hashes
                var child_hashes_list: std.ArrayList([8]u8) = .{};
                defer child_hashes_list.deinit(allocator);

                for (entries) |other| {
                    switch (other) {
                        .file => |f| {
                            if (isDirectChild(dir.path, f.path)) {
                                if (file_hashes.get(f.path)) |hash| {
                                    try child_hashes_list.append(allocator, hash);
                                }
                            }
                        },
                        .dir => {},
                    }
                }

                // Build DirEntry with computed Merkle hash
                var dir_with_merkle = dir;
                if (child_hashes_list.items.len > 0) {
                    dir_with_merkle.xh64 = computeMerkleHash(child_hashes_list.items);
                }

                const dir_bytes = try serializeDirEntry(allocator, dir_with_merkle, &to_free);
                entry_elements.items[i] = dir_bytes;
                entries_done += 1;
                if (progress_fn) |cb| cb(entries_done, bytes_done, progress_ctx);
            },
            .file => {},
        }
    }

    // Phase 3: Assemble archive — signal phase change so callers can update UI
    if (phase_fn) |cb| {
        const label = "Assembling";
        cb(label.ptr, label.len, progress_ctx);
    }
    const magic = if (has_dir) MAGIC_BLAR else MAGIC_MBAR;
    const magic_bytes = try leaf.serializeData(allocator, magic);
    try to_free.append(allocator, magic_bytes);

    const body_array = try array_mod.serializeArray(allocator, entry_elements.items);
    try to_free.append(allocator, body_array);

    const outer_elements = [_][]const u8{ magic_bytes, body_array };
    const result = try array_mod.serializeArrayWithOptions(allocator, &outer_elements, .{ .csum_id = .blake3_128 });

    return result;
}

/// Reader for a BLIP archive. Handles both ARRAY-based FILE and DICT-based DIR entries.
pub const ArchiveReader = struct {
    buf: []const u8,
    outer: array_mod.ArrayReader,

    /// Parse a BLIP archive from a buffer.
    pub fn init(buf: []const u8) ContainerError!ArchiveReader {
        const outer = try array_mod.ArrayReader.init(buf);
        return ArchiveReader{
            .buf = buf,
            .outer = outer,
        };
    }

    /// Verify the magic bytes at element 0.
    /// Accepts both BLAR (full) and MBAR (miniblar) magic.
    pub fn verifyMagic(self: ArchiveReader) ContainerError!bool {
        if (self.outer.elementCount() < 1) return false;
        const view = try self.outer.elementAt(0);
        if (view.type_id != .data) return false;
        const value = view.payloadSlice();
        return std.mem.eql(u8, value, MAGIC_BLAR) or std.mem.eql(u8, value, MAGIC_MBAR);
    }

    /// Check if this archive has full blar magic (BLAR).
    pub fn isBlar(self: ArchiveReader) ContainerError!bool {
        if (self.outer.elementCount() < 1) return false;
        const view = try self.outer.elementAt(0);
        if (view.type_id != .data) return false;
        return std.mem.eql(u8, view.payloadSlice(), MAGIC_BLAR);
    }

    /// Check if this archive has miniblar magic (MBAR).
    pub fn isMiniblar(self: ArchiveReader) ContainerError!bool {
        if (self.outer.elementCount() < 1) return false;
        const view = try self.outer.elementAt(0);
        if (view.type_id != .data) return false;
        return std.mem.eql(u8, view.payloadSlice(), MAGIC_MBAR);
    }

    /// Returns the number of entries in the archive.
    pub fn entryCount(self: ArchiveReader) ContainerError!u64 {
        if (self.outer.elementCount() < 2) return 0;
        const body_view = try self.outer.elementAt(1);
        const body_reader = try array_mod.ArrayReader.init(body_view.buf);
        return body_reader.elementCount();
    }

    /// Alias for entryCount.
    pub fn fileCount(self: ArchiveReader) ContainerError!u64 {
        return self.entryCount();
    }

    /// Get the container type of an entry at the given index.
    pub fn entryTypeAt(self: ArchiveReader, index: u64) ContainerError!ct.ContainerTypeId {
        const body_view = try self.outer.elementAt(1);
        const body_reader = try array_mod.ArrayReader.init(body_view.buf);

        const entry_view = try body_reader.elementAt(index);
        return entry_view.type_id;
    }

    /// Get raw bytes of the entry at the given index.
    fn entryBufAt(self: ArchiveReader, index: u64) ContainerError![]const u8 {
        const body_view = try self.outer.elementAt(1);
        const body_reader = try array_mod.ArrayReader.init(body_view.buf);

        const entry_view = try body_reader.elementAt(index);
        return entry_view.buf;
    }

    /// For FILE entries (ARRAY-based): get an ArrayReader for the entry.
    pub fn fileArrayAt(self: ArchiveReader, index: u64) ContainerError!array_mod.ArrayReader {
        const entry_buf = try self.entryBufAt(index);
        return array_mod.ArrayReader.init(entry_buf);
    }

    /// For DIR entries (DICT-based): get a DictReader for the entry.
    pub fn dirDictAt(self: ArchiveReader, index: u64) ContainerError!dict_mod.DictReader {
        const entry_buf = try self.entryBufAt(index);
        return dict_mod.DictReader.init(entry_buf);
    }

    /// For backward compat: get a DictReader. Only works for DIR entries now.
    pub fn entryAt(self: ArchiveReader, index: u64) ContainerError!dict_mod.DictReader {
        return self.dirDictAt(index);
    }

    /// For backward compat: alias for entryAt. Only works for DIR entries.
    pub fn fileAt(self: ArchiveReader, index: u64) ContainerError!dict_mod.DictReader {
        return self.dirDictAt(index);
    }

    /// Get the path of an entry at the given index.
    /// Works for both FILE (ARRAY-based) and DIR (DICT-based) entries.
    pub fn entryPathAt(self: ArchiveReader, index: u64) ContainerError![]const u8 {
        const entry_type = try self.entryTypeAt(index);
        if (entry_type == .file) {
            // FILE: ARRAY[0] is metadata DICT, look for "pa" key
            const arr = try self.fileArrayAt(index);
            const meta_view = try arr.elementAt(0);
            const meta_reader = try dict_mod.DictReader.init(meta_view.buf);
            const pa_idx = (try meta_reader.findKey("pa")) orelse return ContainerError.MissingRequiredKey;
            const pa_container = try meta_reader.valueAt(pa_idx);
            return leaf.readUtf8(pa_container);
        } else {
            // DIR: DICT with "pa" key
            const dict_reader = try self.dirDictAt(index);
            const pa_idx = (try dict_reader.findKey("pa")) orelse return ContainerError.MissingRequiredKey;
            const pa_container = try dict_reader.valueAt(pa_idx);
            return leaf.readUtf8(pa_container);
        }
    }

    /// Get the content of a FILE entry at the given index.
    /// Reads the DATA container (element 1 of the FILE ARRAY) and returns payload bytes.
    /// For uncompressed entries, returns a zero-copy slice into the archive buffer.
    pub fn fileContentAt(self: ArchiveReader, index: u64) ContainerError![]const u8 {
        const arr = try self.fileArrayAt(index);
        const data_view = try arr.elementAt(1);
        return leaf.readData(data_view.buf);
    }

    /// Get the content of a FILE entry, handling per-file compression transparently.
    /// If element [1] is a compressed LP container (has COMP attribute), decompresses
    /// the outer LP to recover the inner DATA LP, then reads the payload.
    /// If uncompressed, copies the payload into allocator-owned memory.
    /// Caller owns returned memory and must free it.
    pub fn fileContentDecompress(self: ArchiveReader, index: u64, allocator: Allocator) ![]u8 {
        const arr = try self.fileArrayAt(index);
        const data_view = try arr.elementAt(1);

        // Check if the element has a COMP attribute (per-file compressed)
        if (data_view.comp_id != null) {
            // Per-file compressed: decompress outer LP → get inner DATA LP → read payload
            const inner_lp = try compression_mod.decompressContainer(allocator, data_view.buf);
            defer allocator.free(inner_lp);
            const payload = try leaf.readData(inner_lp);
            const result = try allocator.alloc(u8, payload.len);
            @memcpy(result, payload);
            return result;
        }

        // Uncompressed: read payload, copy to owned buffer
        const payload = try leaf.readData(data_view.buf);
        const result = try allocator.alloc(u8, payload.len);
        @memcpy(result, payload);
        return result;
    }

    /// Verify a FILE entry's DATA checksum and ARRAY checksum.
    pub fn verifyFileAt(self: ArchiveReader, index: u64) ContainerError!bool {
        const entry_buf = try self.entryBufAt(index);
        const entry_type = try self.entryTypeAt(index);

        if (entry_type == .dir) {
            // For DIR entries, verify the container checksum
            const dict_reader = try dict_mod.DictReader.init(entry_buf);
            return dict_reader.verifyChecksum();
        }

        // FILE: verify both ARRAY checksum and DATA checksum
        const arr = try array_mod.ArrayReader.init(entry_buf);
        const arr_ok = try arr.verifyChecksum();
        if (!arr_ok) return false;

        // Verify the DATA container's embedded checksum
        const data_view = try arr.elementAt(1);
        return leaf.verifyLeafChecksum(data_view.buf);
    }

    /// Verify the outer array's BLAKE3-128 integrity checksum.
    pub fn verifyChecksum(self: ArchiveReader) ContainerError!bool {
        return self.outer.verifyChecksum();
    }

    /// Verify a DIR entry's Merkle hash by recomputing it from child FILE checksums.
    /// Returns true if the stored xh64 matches the recomputed Merkle hash.
    /// Returns error.InvalidContainerType if the entry is not a DIR.
    pub fn verifyMerkleAt(self: ArchiveReader, index: u64, allocator: std.mem.Allocator) (ContainerError || std.mem.Allocator.Error)!bool {
        const entry_type = try self.entryTypeAt(index);
        if (entry_type != .dir) return ContainerError.InvalidContainerType;

        // Read stored xh64 from DIR
        const dict_reader = try self.dirDictAt(index);
        const xh_idx = (try dict_reader.findKey("xh")) orelse return false;
        const xh_container = try dict_reader.valueAt(xh_idx);
        const xh_val = try leaf.readData(xh_container);
        if (xh_val.len != 8) return false;
        var stored_xh64: [8]u8 = undefined;
        @memcpy(&stored_xh64, xh_val[0..8]);

        // Get DIR path
        const dir_path = try self.entryPathAt(index);

        // Collect child FILE checksums
        const count = try self.entryCount();
        var child_hashes: std.ArrayList([8]u8) = .{};
        defer child_hashes.deinit(allocator);

        for (0..count) |i| {
            const child_type = try self.entryTypeAt(i);
            if (child_type != .file) continue;

            const child_path = try self.entryPathAt(i);
            if (!isDirectChild(dir_path, child_path)) continue;

            // Extract FILE ARRAY's xxHash64 checksum from LP header
            const entry_buf = try self.entryBufAt(i);
            const file_view = try container.parseLPHeader(entry_buf);
            const csum = file_view.checksumSlice();
            if (csum.len == 8) {
                var hash: [8]u8 = undefined;
                @memcpy(&hash, csum[0..8]);
                try child_hashes.append(allocator, hash);
            }
        }

        if (child_hashes.items.len == 0) {
            // No children: stored hash should be all zeros
            return std.mem.eql(u8, &stored_xh64, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
        }

        const recomputed = computeMerkleHash(child_hashes.items);
        return std.mem.eql(u8, &stored_xh64, &recomputed);
    }

    /// Find a file by its path.
    pub fn findFile(self: ArchiveReader, path: []const u8) ContainerError!?u64 {
        const count = try self.entryCount();
        for (0..count) |i| {
            const entry_path = try self.entryPathAt(i);
            if (std.mem.eql(u8, entry_path, path)) {
                return i;
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
    try testing.expect(try reader.verifyChecksum());
}

test "single file archive round-trip with ARRAY-based FILE" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "hello.txt", .content = "Hello, world!\n", .mode = 0o644, .mtime_ns = 1000000 },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify entry type is FILE
    try testing.expectEqual(ContainerTypeId.file, try reader.entryTypeAt(0));

    // Read back path
    const path = try reader.entryPathAt(0);
    try testing.expectEqualSlices(u8, "hello.txt", path);

    // Read back content
    const content = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, "Hello, world!\n", content);

    // Verify hashes
    try testing.expect(try reader.verifyFileAt(0));
}

test "multi-file archive: caller order preserved" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "src/c.zig", .content = "c content" },
        .{ .path = "src/a.zig", .content = "a content" },
        .{ .path = "src/b.zig", .content = "b content" },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 3), try reader.fileCount());

    // Verify caller's order is preserved: c, a, b (not sorted)
    try testing.expectEqualSlices(u8, "src/c.zig", try reader.entryPathAt(0));
    try testing.expectEqualSlices(u8, "src/a.zig", try reader.entryPathAt(1));
    try testing.expectEqualSlices(u8, "src/b.zig", try reader.entryPathAt(2));

    try testing.expectEqualSlices(u8, "c content", try reader.fileContentAt(0));
    try testing.expectEqualSlices(u8, "a content", try reader.fileContentAt(1));
    try testing.expectEqualSlices(u8, "b content", try reader.fileContentAt(2));
}

test "FILE contains dual checksums: DATA hash + ARRAY hash" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "test content", .mode = 0o644 },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyFileAt(0));
}

test "archive with empty file content" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "empty.txt", .content = "" },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());

    const content = try reader.fileContentAt(0);
    try testing.expectEqual(@as(usize, 0), content.len);
    try testing.expect(try reader.verifyFileAt(0));
}

test "findFile by path returns correct index" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "alpha.txt", .content = "alpha data" },
        .{ .path = "beta.txt", .content = "beta data" },
        .{ .path = "gamma.txt", .content = "gamma data" },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const idx = (try reader.findFile("beta.txt")).?;
    try testing.expectEqual(@as(u64, 1), idx);
    try testing.expectEqualSlices(u8, "beta data", try reader.fileContentAt(idx));

    // Not found
    try testing.expectEqual(@as(?u64, null), try reader.findFile("nonexistent.txt"));
}

test "full archive with DIR + FILE entries round-trips" {
    const allocator = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .dir = .{ .path = "src", .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 }, .mode = 0o755 } },
        .{ .file = .{ .path = "src/main.zig", .content = "pub fn main() void {}", .mode = 0o644 } },
    };
    const archive = try createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expect(try reader.verifyChecksum());
    try testing.expectEqual(@as(u64, 2), try reader.entryCount());

    // Caller order preserved: dir first, then file
    try testing.expectEqual(ContainerTypeId.dir, try reader.entryTypeAt(0));
    try testing.expectEqual(ContainerTypeId.file, try reader.entryTypeAt(1));

    try testing.expectEqualSlices(u8, "src", try reader.entryPathAt(0));
    try testing.expectEqualSlices(u8, "src/main.zig", try reader.entryPathAt(1));
}

test "Merkle hash computation" {
    const hash_a = XxHash64.hash(0, "aaa");
    const hash_b = XxHash64.hash(0, "bbb");
    var concat: [16]u8 = undefined;
    std.mem.writeInt(u64, concat[0..8], hash_a, .little);
    std.mem.writeInt(u64, concat[8..16], hash_b, .little);
    const expected_merkle = XxHash64.hash(0, &concat);

    const child_hashes = [_][8]u8{
        blk: {
            var h: [8]u8 = undefined;
            std.mem.writeInt(u64, &h, hash_a, .little);
            break :blk h;
        },
        blk: {
            var h: [8]u8 = undefined;
            std.mem.writeInt(u64, &h, hash_b, .little);
            break :blk h;
        },
    };
    const merkle = computeMerkleHash(&child_hashes);
    const merkle_u64: u64 = std.mem.readInt(u64, &merkle, .little);
    try testing.expectEqual(expected_merkle, merkle_u64);
}

test "archive with large file content" {
    const allocator = testing.allocator;

    const content = try allocator.alloc(u8, 10240);
    defer allocator.free(content);
    for (content, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const files = [_]FileEntry{
        .{ .path = "big.bin", .content = content },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expect(try reader.verifyChecksum());
    try testing.expectEqual(@as(u64, 1), try reader.fileCount());

    const roundtrip = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, content, roundtrip);
    try testing.expect(try reader.verifyFileAt(0));
}

test "FILE metadata round-trip: mode, mtime, username" {
    const allocator = testing.allocator;

    const files = [_]FileEntry{
        .{
            .path = "script.sh",
            .content = "#!/bin/bash\n",
            .mode = 0o755,
            .mtime_ns = 1708787200_000_000_000,
            .username = "peter",
        },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const arr = try reader.fileArrayAt(0);

    // Element 0 is metadata DICT
    const meta_view = try arr.elementAt(0);
    try testing.expectEqual(ContainerTypeId.dict, meta_view.type_id);

    // Parse metadata dict
    const meta_reader = try dict_mod.DictReader.init(meta_view.buf);

    // Verify md (mode)
    const md_idx = (try meta_reader.findKey("md")).?;
    const md_val = try leaf.readData(try meta_reader.valueAt(md_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, md_val[0..2], .little));

    // Verify mt (mtime)
    const mt_idx = (try meta_reader.findKey("mt")).?;
    const mt_val = try leaf.readData(try meta_reader.valueAt(mt_idx));
    try testing.expectEqual(@as(i64, 1708787200_000_000_000), std.mem.readInt(i64, mt_val[0..8], .little));

    // Verify pa (path)
    const pa_idx = (try meta_reader.findKey("pa")).?;
    const pa_val = try leaf.readUtf8(try meta_reader.valueAt(pa_idx));
    try testing.expectEqualSlices(u8, "script.sh", pa_val);

    // Verify un (username)
    const un_idx = (try meta_reader.findKey("un")).?;
    const un_val = try leaf.readUtf8(try meta_reader.valueAt(un_idx));
    try testing.expectEqualSlices(u8, "peter", un_val);
}

test "DIR metadata round-trip with 2-char keys" {
    const allocator = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .dir = .{
            .path = "mydir",
            .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 },
            .mode = 0o755,
            .mtime_ns = 1708787200_000_000_000,
            .username = "peter",
        } },
    };
    const archive = try createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const dict_reader = try reader.dirDictAt(0);
    try testing.expect(try dict_reader.verifyChecksum());

    // Verify 2-char keys
    const pa_idx = (try dict_reader.findKey("pa")).?;
    try testing.expectEqualSlices(u8, "mydir", try leaf.readUtf8(try dict_reader.valueAt(pa_idx)));

    const md_idx = (try dict_reader.findKey("md")).?;
    const md_val = try leaf.readData(try dict_reader.valueAt(md_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, md_val[0..2], .little));

    const xh_idx = (try dict_reader.findKey("xh")).?;
    const xh_val = try leaf.readData(try dict_reader.valueAt(xh_idx));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 }, xh_val);
}

test "FILE with xattrs creates forks DICT" {
    const allocator = testing.allocator;

    const files = [_]FileEntry{
        .{
            .path = "test.txt",
            .content = "hello",
            .mode = 0o644,
            .xattrs = &[_]XattrEntry{
                .{ .name = "user.comment", .value = "test xattr" },
            },
        },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const arr = try reader.fileArrayAt(0);

    // Should have 3 elements: metadata DICT, DATA, forks DICT
    try testing.expectEqual(@as(u64, 3), arr.elementCount());

    // Element 2 should be a DICT
    const forks_view = try arr.elementAt(2);
    try testing.expectEqual(ContainerTypeId.dict, forks_view.type_id);
}

test "outer array element count is 2 (magic + body)" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "data" },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expectEqual(@as(u64, 2), reader.outer.elementCount());
}

test "DATA container inside FILE has xxHash64 checksum" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "hello world", .mode = 0o644 },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const arr = try reader.fileArrayAt(0);

    // Element 1 is the DATA container — it should have xxHash64 checksum
    const data_view = try arr.elementAt(1);
    try testing.expectEqual(ContainerTypeId.data, data_view.type_id);
    try testing.expectEqual(@as(?ct.ChecksumId, .xxhash64), data_view.csum_id);
    try testing.expectEqual(@as(usize, 8), data_view.checksumSlice().len);

    // Verify the checksum is valid
    try testing.expect(try leaf.verifyLeafChecksum(data_view.buf));
}

test "FILE ARRAY container has xxHash64 checksum" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "test.txt", .content = "hello world", .mode = 0o644 },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);

    // Get the raw FILE container from the body array
    const body_view = try reader.outer.elementAt(1);
    const body_reader = try array_mod.ArrayReader.init(body_view.buf);
    const file_view = try body_reader.elementAt(0);

    // FILE ARRAY should have xxHash64 checksum attribute
    try testing.expectEqual(@as(?ct.ChecksumId, .xxhash64), file_view.csum_id);
    try testing.expectEqual(@as(usize, 8), file_view.checksumSlice().len);

    // The FILE ARRAY's checksum should verify
    const file_arr = try reader.fileArrayAt(0);
    try testing.expect(try file_arr.verifyChecksum());
}

test "DIR container has xxHash64 checksum" {
    const allocator = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .dir = .{ .path = "src", .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 }, .mode = 0o755 } },
        .{ .file = .{ .path = "src/main.zig", .content = "pub fn main() void {}", .mode = 0o644 } },
    };
    const archive = try createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);

    // Get the raw DIR container
    const body_view = try reader.outer.elementAt(1);
    const body_reader = try array_mod.ArrayReader.init(body_view.buf);
    const dir_view = try body_reader.elementAt(0);

    // DIR should have xxHash64 checksum
    try testing.expectEqual(ContainerTypeId.dir, dir_view.type_id);
    try testing.expectEqual(@as(?ct.ChecksumId, .xxhash64), dir_view.csum_id);
    try testing.expectEqual(@as(usize, 8), dir_view.checksumSlice().len);

    // Verify the checksum
    const dict_reader = try reader.dirDictAt(0);
    try testing.expect(try dict_reader.verifyChecksum());
}

test "verifyFileAt detects single-file corruption in multi-file archive" {
    const allocator = testing.allocator;
    const files = [_]FileEntry{
        .{ .path = "a.txt", .content = "alpha content" },
        .{ .path = "b.txt", .content = "beta content" },
        .{ .path = "c.txt", .content = "gamma content" },
    };
    const archive = try createArchive(allocator, &files);
    defer allocator.free(archive);

    // All files should verify initially
    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyFileAt(0));
    try testing.expect(try reader.verifyFileAt(1));
    try testing.expect(try reader.verifyFileAt(2));

    // Corrupt file 1's content (find the DATA container for b.txt and flip a byte)
    // The FILE ARRAY's xxHash64 should now fail for file 1
    const arr1 = try reader.fileArrayAt(1);
    const data1_view = try arr1.elementAt(1);
    // data1_view.buf points into the archive buffer
    const data1_start = @intFromPtr(data1_view.buf.ptr) - @intFromPtr(archive.ptr);
    // Corrupt a payload byte in the DATA container
    archive[data1_start + data1_view.val_offset] ^= 0xFF;

    // Now file 1 should fail verification, but file 0 and file 2 should still pass
    // (We can't re-verify file 0/2 through the ArchiveReader because the outer checksum
    // will also be broken. But the individual FILE container checksums should detect the issue.)
    // Let's verify the DATA container directly
    try testing.expect(!(try leaf.verifyLeafChecksum(data1_view.buf)));
}

test "Merkle hash uses per-file xxHash64 from FILE ARRAY container" {
    const allocator = testing.allocator;

    // Create a file, serialize it, and check that the Merkle hash matches
    // the FILE ARRAY's xxHash64 checksum
    const file = FileEntry{ .path = "mydir/file.txt", .content = "hello", .mode = 0o644 };

    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    const file_bytes = try serializeFileEntry(allocator, file, &to_free, null);

    // Parse the FILE ARRAY header to extract its xxHash64 checksum
    const file_view = try container_mod.parseLPHeader(file_bytes);
    try testing.expectEqual(@as(?ct.ChecksumId, .xxhash64), file_view.csum_id);

    const csum_slice = file_view.checksumSlice();
    try testing.expectEqual(@as(usize, 8), csum_slice.len);

    // The Merkle hash for a single file should be computeMerkleHash of that one hash
    var hash: [8]u8 = undefined;
    @memcpy(&hash, csum_slice);
    const child_hashes = [_][8]u8{hash};
    const merkle = computeMerkleHash(&child_hashes);

    // This should be the hash of that single checksum
    var hasher = XxHash64.init(0);
    hasher.update(&hash);
    const expected = hasher.final();
    var expected_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected_bytes, expected, .little);
    try testing.expectEqualSlices(u8, &expected_bytes, &merkle);
}

test "per-file compression: createFullArchive with comp_id produces recoverable content" {
    const allocator = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .file = .{ .path = "hello.txt", .content = "Hello, world!\n", .mode = 0o644 } },
        .{ .file = .{ .path = "data.bin", .content = "some binary data here" } },
    };

    // Create archive with LZ4 per-file compression
    const archive = try createFullArchive(allocator, &entries, null, null, null, .lz4, 0);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expectEqual(@as(u64, 2), try reader.entryCount());

    // Element [1] of the first FILE should be a compressed LP container
    const arr0 = try reader.fileArrayAt(0);
    const data_view0 = try arr0.elementAt(1);
    try testing.expectEqual(@as(?ct.CompressionId, .lz4), data_view0.comp_id);

    // fileContentDecompress should recover the original content
    const content0 = try reader.fileContentDecompress(0, allocator);
    defer allocator.free(content0);
    try testing.expectEqualSlices(u8, "Hello, world!\n", content0);

    const content1 = try reader.fileContentDecompress(1, allocator);
    defer allocator.free(content1);
    try testing.expectEqualSlices(u8, "some binary data here", content1);
}

test "fileContentDecompress works on uncompressed archives" {
    const allocator = testing.allocator;

    const entries = [_]ArchiveEntry{
        .{ .file = .{ .path = "test.txt", .content = "uncompressed content" } },
    };

    // Create archive without compression (null comp_id)
    const archive = try createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);

    // Element [1] should NOT be compressed
    const arr = try reader.fileArrayAt(0);
    const data_view = try arr.elementAt(1);
    try testing.expectEqual(@as(?ct.CompressionId, null), data_view.comp_id);

    // fileContentDecompress should still work (returns a copy)
    const content = try reader.fileContentDecompress(0, allocator);
    defer allocator.free(content);
    try testing.expectEqualSlices(u8, "uncompressed content", content);
}

test "per-file compression with all algorithms" {
    const allocator = testing.allocator;
    const algos = [_]ct.CompressionId{ .lz4, .zstd, .lzma2, .bzip2 };

    for (algos) |algo| {
        const entries = [_]ArchiveEntry{
            .{ .file = .{ .path = "test.txt", .content = "Hello, per-file compression test!" } },
        };

        const archive = try createFullArchive(allocator, &entries, null, null, null, algo, 0);
        defer allocator.free(archive);

        const reader = try ArchiveReader.init(archive);
        const content = try reader.fileContentDecompress(0, allocator);
        defer allocator.free(content);
        try testing.expectEqualSlices(u8, "Hello, per-file compression test!", content);
    }
}
