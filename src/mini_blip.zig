const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
pub const leaf = @import("leaf.zig");
pub const array_mod = @import("array.zig");
pub const dict_mod = @import("dict.zig");
pub const data_mod = @import("data.zig");
const testing = std.testing;

pub const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;
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
};

/// An xattr key-value pair.
pub const XattrEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// A directory entry to be included in a full BLIP archive.
pub const DirEntry = struct {
    path: []const u8, // directory path (UTF-8)
    xh64: [8]u8, // pre-computed Merkle hash
    mode: u16 = 0,
    mtime_ns: i64 = 0,
    ctime_ns: i64 = 0,
    birthtime_ns: i64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    username: []const u8 = &.{},
    groupname: []const u8 = &.{},
    xattrs: []const XattrEntry = &.{},
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

/// The magic bytes identifying a miniBLIP archive: "BLIP" + version 1.
const MAGIC: *const [5]u8 = "BLIP\x01";

/// Serialize a FILE entry as an ARRAY-based container.
/// Layout: FILE (0x81 0x05, ARRAY layout)
///   [0]: DICT — metadata (required keys: pa, md, mt)
///   [1]: DATA — content + embedded xxHash64
///   [2]: DICT — forks (optional, only if xattrs or resource fork present)
/// Caller owns returned memory.
pub fn serializeFileEntry(allocator: Allocator, file: FileEntry, to_free: *std.ArrayList([]u8)) (Allocator.Error || ContainerError)![]const u8 {
    // --- Element 0: metadata DICT ---
    // Build metadata key-value pairs with 2-char keys in canonical order:
    // bt < ct < gi < gn < md < mt < pa < ui < un
    var meta_pairs_buf: [9]dict_mod.KeyValue = undefined;
    var meta_count: usize = 0;

    // bt (birthtime)
    if (file.birthtime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "bt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, file.birthtime_ns, .little);
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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

    // md (mode) — required
    {
        const key = try leaf.serializeUtf8(allocator, "md");
        try to_free.append(allocator, key);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, file.mode, .little);
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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

    // ui (uid)
    if (file.uid != 0) {
        const key = try leaf.serializeUtf8(allocator, "ui");
        try to_free.append(allocator, key);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, file.uid, .little);
        const val = try leaf.serializeRaw(allocator, &bytes);
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

    const metadata_dict = try dict_mod.serializeDict(allocator, meta_pairs_buf[0..meta_count]);
    try to_free.append(allocator, metadata_dict);

    // --- Element 1: DATA container ---
    const data_container = try data_mod.serializeData(allocator, file.content);
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
            const val = try leaf.serializeRaw(allocator, xa.value);
            try to_free.append(allocator, val);
            fork_pairs[fi] = .{ .key = key, .value = val };
            fi += 1;
        }
        if (file.resource_fork.len > 0) {
            const key = try leaf.serializeUtf8(allocator, "rf");
            try to_free.append(allocator, key);
            const val = try leaf.serializeRaw(allocator, file.resource_fork);
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
        const file_bytes = try array_mod.serializeArrayLike(allocator, &elements, .file);
        try to_free.append(allocator, file_bytes);
        return file_bytes;
    } else {
        const elements = [_][]const u8{ metadata_dict, data_container };
        const file_bytes = try array_mod.serializeArrayLike(allocator, &elements, .file);
        try to_free.append(allocator, file_bytes);
        return file_bytes;
    }
}

/// Serialize a single DirEntry into a DIR container with 2-char keys.
fn serializeDirEntry(allocator: Allocator, dir: DirEntry, to_free: *std.ArrayList([]u8)) (Allocator.Error || ContainerError)![]const u8 {
    // Build key-value pairs with 2-char keys in canonical order:
    // bt < ct < gi < gn < md < mt < pa < ui < un < xa < xh
    var pairs_buf: [11]dict_mod.KeyValue = undefined;
    var pair_count: usize = 0;

    // bt (birthtime)
    if (dir.birthtime_ns != 0) {
        const key = try leaf.serializeUtf8(allocator, "bt");
        try to_free.append(allocator, key);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, dir.birthtime_ns, .little);
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
        const val = try leaf.serializeRaw(allocator, &bytes);
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
            const xa_val = try leaf.serializeRaw(allocator, xa.value);
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
        const val = try leaf.serializeRaw(allocator, &dir.xh64);
        try to_free.append(allocator, val);
        pairs_buf[pair_count] = .{ .key = key, .value = val };
        pair_count += 1;
    }

    const dir_bytes = try dict_mod.serializeDir(allocator, pairs_buf[0..pair_count]);
    try to_free.append(allocator, dir_bytes);
    return dir_bytes;
}

/// Create a miniBLIP archive from a list of file entries.
/// Files are sorted by path in canonical byte order.
/// Returns the complete archive as a byte slice. Caller owns returned memory.
pub fn createArchive(allocator: Allocator, files: []const FileEntry) (Allocator.Error || ContainerError)![]u8 {
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

    // Serialize each file into a FILE container (ARRAY-based)
    var file_elements: std.ArrayList([]const u8) = .{};
    defer file_elements.deinit(allocator);

    for (sorted_files) |file| {
        const file_bytes = try serializeFileEntry(allocator, file, &to_free);
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

/// Create a full BLIP archive from a list of file and/or directory entries.
/// Entries are sorted by path in canonical byte order.
/// Returns the complete archive as a byte slice. Caller owns returned memory.
pub fn createFullArchive(allocator: Allocator, entries: []const ArchiveEntry) (Allocator.Error || ContainerError)![]u8 {
    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    // Copy entries into a sortable array, sort by path
    const sorted_entries = try allocator.alloc(ArchiveEntry, entries.len);
    defer allocator.free(sorted_entries);
    @memcpy(sorted_entries, entries);

    std.mem.sort(ArchiveEntry, sorted_entries, {}, struct {
        fn lessThan(_: void, a: ArchiveEntry, b: ArchiveEntry) bool {
            return std.mem.order(u8, a.getPath(), b.getPath()) == .lt;
        }
    }.lessThan);

    // Serialize each entry as FILE or DIR container
    var entry_elements: std.ArrayList([]const u8) = .{};
    defer entry_elements.deinit(allocator);

    for (sorted_entries) |entry| {
        switch (entry) {
            .file => |file| {
                const file_bytes = try serializeFileEntry(allocator, file, &to_free);
                try entry_elements.append(allocator, file_bytes);
            },
            .dir => |dir| {
                const dir_bytes = try serializeDirEntry(allocator, dir, &to_free);
                try entry_elements.append(allocator, dir_bytes);
            },
        }
    }

    // Serialize magic: RAW("BLIP\x01")
    const magic_bytes = try leaf.serializeRaw(allocator, MAGIC);
    try to_free.append(allocator, magic_bytes);

    // Serialize body array (containing all entries)
    const body_array = try array_mod.serializeArray(allocator, entry_elements.items);
    try to_free.append(allocator, body_array);

    // Serialize outer array: [magic, body_array]
    const outer_elements = [_][]const u8{ magic_bytes, body_array };
    const result = try array_mod.serializeArray(allocator, &outer_elements);

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
    pub fn verifyMagic(self: ArchiveReader) ContainerError!bool {
        if (self.outer.elementCount() < 1) return false;
        const view = try self.outer.elementAt(0);
        if (view.container_type != .raw) return false;
        const value = view.valueSlice();
        return std.mem.eql(u8, value, MAGIC);
    }

    /// Returns the number of entries in the archive.
    pub fn entryCount(self: ArchiveReader) ContainerError!u64 {
        if (self.outer.elementCount() < 2) return 0;
        const body_view = try self.outer.elementAt(1);
        const body_start = @intFromPtr(body_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const body_end = body_start + @as(usize, @intCast(body_view.total_length));
        const body_buf = self.buf[body_start..body_end];
        const body_reader = try array_mod.ArrayReader.init(body_buf);
        return body_reader.elementCount();
    }

    /// Alias for entryCount.
    pub fn fileCount(self: ArchiveReader) ContainerError!u64 {
        return self.entryCount();
    }

    /// Get the container type of an entry at the given index.
    pub fn entryTypeAt(self: ArchiveReader, index: u64) ContainerError!ct.ContainerType {
        const body_view = try self.outer.elementAt(1);
        const body_start = @intFromPtr(body_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const body_end = body_start + @as(usize, @intCast(body_view.total_length));
        const body_buf = self.buf[body_start..body_end];
        const body_reader = try array_mod.ArrayReader.init(body_buf);

        const entry_view = try body_reader.elementAt(index);
        return entry_view.container_type;
    }

    /// Get raw bytes of the entry at the given index.
    fn entryBufAt(self: ArchiveReader, index: u64) ContainerError![]const u8 {
        const body_view = try self.outer.elementAt(1);
        const body_start = @intFromPtr(body_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const body_end = body_start + @as(usize, @intCast(body_view.total_length));
        const body_buf = self.buf[body_start..body_end];
        const body_reader = try array_mod.ArrayReader.init(body_buf);

        const entry_view = try body_reader.elementAt(index);
        const entry_start = @intFromPtr(entry_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const entry_end = entry_start + @as(usize, @intCast(entry_view.total_length));
        return self.buf[entry_start..entry_end];
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
            const meta_start = @intFromPtr(meta_view.buf.ptr) - @intFromPtr(self.buf.ptr);
            const meta_end = meta_start + @as(usize, @intCast(meta_view.total_length));
            const meta_buf = self.buf[meta_start..meta_end];
            const meta_reader = try dict_mod.DictReader.init(meta_buf);
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
    /// Reads the DATA container (element 1 of the FILE ARRAY) and returns data minus hash.
    pub fn fileContentAt(self: ArchiveReader, index: u64) ContainerError![]const u8 {
        const arr = try self.fileArrayAt(index);
        const data_view = try arr.elementAt(1);
        const data_start = @intFromPtr(data_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const data_end = data_start + @as(usize, @intCast(data_view.total_length));
        const data_buf = self.buf[data_start..data_end];
        return data_mod.readDataContent(data_buf);
    }

    /// Verify a FILE entry's DATA hash and ARRAY hash.
    pub fn verifyFileAt(self: ArchiveReader, index: u64) ContainerError!bool {
        const entry_buf = try self.entryBufAt(index);
        const entry_type = try self.entryTypeAt(index);

        if (entry_type == .dir) {
            // For DIR entries, verify the container hash
            const dict_reader = try dict_mod.DictReader.init(entry_buf);
            return dict_reader.verifyHash();
        }

        // FILE: verify both ARRAY hash and DATA hash
        const arr = try array_mod.ArrayReader.init(entry_buf);
        const arr_hash_ok = try arr.verifyHash();
        if (!arr_hash_ok) return false;

        // Verify the DATA container's embedded hash
        const data_view = try arr.elementAt(1);
        const data_start = @intFromPtr(data_view.buf.ptr) - @intFromPtr(self.buf.ptr);
        const data_end = data_start + @as(usize, @intCast(data_view.total_length));
        const data_buf = self.buf[data_start..data_end];
        return data_mod.verifyDataHash(data_buf);
    }

    /// Verify the outer array's xxHash64 integrity check.
    pub fn verifyHash(self: ArchiveReader) ContainerError!bool {
        return self.outer.verifyHash();
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
    try testing.expect(try reader.verifyHash());
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
    try testing.expect(try reader.verifyHash());

    // Verify entry type is FILE
    try testing.expectEqual(ContainerType.file, try reader.entryTypeAt(0));

    // Read back path
    const path = try reader.entryPathAt(0);
    try testing.expectEqualSlices(u8, "hello.txt", path);

    // Read back content
    const content = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, "Hello, world!\n", content);

    // Verify hashes
    try testing.expect(try reader.verifyFileAt(0));
}

test "multi-file archive: path sorting preserved" {
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

    // Verify sorted order: a, b, c
    try testing.expectEqualSlices(u8, "src/a.zig", try reader.entryPathAt(0));
    try testing.expectEqualSlices(u8, "src/b.zig", try reader.entryPathAt(1));
    try testing.expectEqualSlices(u8, "src/c.zig", try reader.entryPathAt(2));

    try testing.expectEqualSlices(u8, "a content", try reader.fileContentAt(0));
    try testing.expectEqualSlices(u8, "b content", try reader.fileContentAt(1));
    try testing.expectEqualSlices(u8, "c content", try reader.fileContentAt(2));
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
        .{ .file = .{ .path = "src/main.zig", .content = "pub fn main() void {}", .mode = 0o644 } },
        .{ .dir = .{ .path = "src", .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 }, .mode = 0o755 } },
    };
    const archive = try createFullArchive(allocator, &entries);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    try testing.expect(try reader.verifyMagic());
    try testing.expect(try reader.verifyHash());
    try testing.expectEqual(@as(u64, 2), try reader.entryCount());

    // Entries sorted: "src" < "src/main.zig"
    try testing.expectEqual(ContainerType.dir, try reader.entryTypeAt(0));
    try testing.expectEqual(ContainerType.file, try reader.entryTypeAt(1));

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
    try testing.expect(try reader.verifyHash());
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
    try testing.expectEqual(ContainerType.dict, meta_view.container_type);

    // Parse metadata dict
    const buf = reader.buf;
    const meta_start = @intFromPtr(meta_view.buf.ptr) - @intFromPtr(buf.ptr);
    const meta_end = meta_start + @as(usize, @intCast(meta_view.total_length));
    const meta_buf = buf[meta_start..meta_end];
    const meta_reader = try dict_mod.DictReader.init(meta_buf);

    // Verify md (mode)
    const md_idx = (try meta_reader.findKey("md")).?;
    const md_val = try leaf.readRaw(try meta_reader.valueAt(md_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, md_val[0..2], .little));

    // Verify mt (mtime)
    const mt_idx = (try meta_reader.findKey("mt")).?;
    const mt_val = try leaf.readRaw(try meta_reader.valueAt(mt_idx));
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
    const archive = try createFullArchive(allocator, &entries);
    defer allocator.free(archive);

    const reader = try ArchiveReader.init(archive);
    const dict_reader = try reader.dirDictAt(0);
    try testing.expect(try dict_reader.verifyHash());

    // Verify 2-char keys
    const pa_idx = (try dict_reader.findKey("pa")).?;
    try testing.expectEqualSlices(u8, "mydir", try leaf.readUtf8(try dict_reader.valueAt(pa_idx)));

    const md_idx = (try dict_reader.findKey("md")).?;
    const md_val = try leaf.readRaw(try dict_reader.valueAt(md_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, md_val[0..2], .little));

    const xh_idx = (try dict_reader.findKey("xh")).?;
    const xh_val = try leaf.readRaw(try dict_reader.valueAt(xh_idx));
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
    try testing.expectEqual(ContainerType.dict, forks_view.container_type);
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
