const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const array_mod = @import("array.zig");
const dict_mod = @import("dict.zig");
// data_mod removed: data functionality merged into leaf.zig (v2 migration)
const leaf = @import("leaf.zig");
const mini_blar = @import("mini_blar.zig");
const peek = @import("peek.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerTypeId = ct.ContainerTypeId;

// =============================================================================
// Poke error types
// =============================================================================

pub const PokeError = error{
    ImmutableTarget, // Can't poke magic bytes
    NotALeaf, // Can't poke a container (ARRAY, FILE, DICT, etc.)
    OutOfMemory,
    // Container errors that can occur during navigation/reconstruction
    InvalidContainerType,
    InvalidLength,
    LengthExceedsBounds,
    MissingRequiredKey,
    DuplicateKey,
    KeysNotSorted,
    HashMismatch,
    IndexOutOfBounds,
    InvalidMagic,
    BufferTooSmall,
    UnexpectedEndOfInput,
    Overflow,
    // v2 LP-specific errors
    MissingSigil,
    InvalidSigilOrder,
    MissingDecompLen,
    // Path errors
    UnclosedBracket,
    EmptyBracket,
    InvalidIndex,
    UnexpectedCharacter,
};

// =============================================================================
// Path target classification
// =============================================================================

const PokeTarget = enum {
    immutable, // [0] magic — error
    container, // [1], [1][N] — error
    data_content, // [1][N][1] — replace DATA content
    metadata_leaf, // [1][N][0][key] — replace metadata value
};

/// Classify a path for poke purposes.
/// Returns the target type and validates that the path is pokeable.
fn classifyTarget(segments: []const peek.PathSegment) PokeTarget {
    if (segments.len == 0) return .container; // root
    if (segments.len == 1) {
        switch (segments[0]) {
            .index => |idx| {
                if (idx == 0) return .immutable; // [0] = magic
                return .container; // [1] = body array
            },
            .key => return .container,
        }
    }
    if (segments.len == 2) {
        // [1][N] — entry container (FILE/DIR), not pokeable
        return .container;
    }
    if (segments.len == 3) {
        // [1][N][M] — could be [1][N][0] (metadata dict) or [1][N][1] (DATA content)
        switch (segments[2]) {
            .index => |idx| {
                if (idx == 1) return .data_content; // [1][N][1] = DATA
                return .container; // [1][N][0] = metadata dict
            },
            .key => return .metadata_leaf, // shouldn't happen at this depth
        }
    }
    if (segments.len == 4) {
        // [1][N][0][key] — metadata leaf
        return .metadata_leaf;
    }
    // Deeper paths — treat as metadata leaf (generic leaf poke)
    return .metadata_leaf;
}

// =============================================================================
// Reconstruct entries from archive
// =============================================================================

/// Reconstruct a FileEntry from a FILE container in the archive.
fn reconstructFileEntry(allocator: Allocator, reader: mini_blar.ArchiveReader, index: u64) !mini_blar.FileEntry {
    // Get the path
    const path_slice = try reader.entryPathAt(index);
    const path = try allocator.dupe(u8, path_slice);

    // Get the content
    const content_slice = try reader.fileContentAt(index);
    const content = try allocator.dupe(u8, content_slice);

    // Read metadata from the DICT
    const arr = try reader.fileArrayAt(index);
    const meta_view = arr.elementAt(0) catch return mini_blar.FileEntry{
        .path = path,
        .content = content,
    };
    const meta_start = @intFromPtr(meta_view.buf.ptr) - @intFromPtr(reader.buf.ptr);
    const meta_end = meta_start + @as(usize, @intCast(meta_view.total_length));
    const meta_buf = reader.buf[meta_start..meta_end];
    const meta_reader = try dict_mod.DictReader.init(meta_buf);

    var entry = mini_blar.FileEntry{
        .path = path,
        .content = content,
    };

    // Read mode (md)
    if (try meta_reader.findKey("md")) |md_idx| {
        const md_container = try meta_reader.valueAt(md_idx);
        const md_val = try leaf.readData(md_container);
        if (md_val.len >= 2) {
            entry.mode = std.mem.readInt(u16, md_val[0..2], .little);
        }
    }

    // Read mtime (mt)
    if (try meta_reader.findKey("mt")) |mt_idx| {
        const mt_container = try meta_reader.valueAt(mt_idx);
        const mt_val = try leaf.readData(mt_container);
        if (mt_val.len >= 8) {
            entry.mtime_ns = std.mem.readInt(i64, mt_val[0..8], .little);
        }
    }

    // Read ctime (ct)
    if (try meta_reader.findKey("ct")) |ct_idx| {
        const ct_container = try meta_reader.valueAt(ct_idx);
        const ct_val = try leaf.readData(ct_container);
        if (ct_val.len >= 8) {
            entry.ctime_ns = std.mem.readInt(i64, ct_val[0..8], .little);
        }
    }

    // Read birthtime (bt)
    if (try meta_reader.findKey("bt")) |bt_idx| {
        const bt_container = try meta_reader.valueAt(bt_idx);
        const bt_val = try leaf.readData(bt_container);
        if (bt_val.len >= 8) {
            entry.birthtime_ns = std.mem.readInt(i64, bt_val[0..8], .little);
        }
    }

    // Read uid (ui)
    if (try meta_reader.findKey("ui")) |ui_idx| {
        const ui_container = try meta_reader.valueAt(ui_idx);
        const ui_val = try leaf.readData(ui_container);
        if (ui_val.len >= 4) {
            entry.uid = std.mem.readInt(u32, ui_val[0..4], .little);
        }
    }

    // Read gid (gi)
    if (try meta_reader.findKey("gi")) |gi_idx| {
        const gi_container = try meta_reader.valueAt(gi_idx);
        const gi_val = try leaf.readData(gi_container);
        if (gi_val.len >= 4) {
            entry.gid = std.mem.readInt(u32, gi_val[0..4], .little);
        }
    }

    // Read username (un)
    if (try meta_reader.findKey("un")) |un_idx| {
        const un_container = try meta_reader.valueAt(un_idx);
        const un_val = try leaf.readUtf8(un_container);
        entry.username = try allocator.dupe(u8, un_val);
    }

    // Read groupname (gn)
    if (try meta_reader.findKey("gn")) |gn_idx| {
        const gn_container = try meta_reader.valueAt(gn_idx);
        const gn_val = try leaf.readUtf8(gn_container);
        entry.groupname = try allocator.dupe(u8, gn_val);
    }

    // Read zip compression method (zc)
    if (try meta_reader.findKey("zc")) |zc_idx| {
        const zc_container = try meta_reader.valueAt(zc_idx);
        const zc_val = try leaf.readData(zc_container);
        if (zc_val.len >= 2) {
            entry.zip_compression_method = std.mem.readInt(u16, zc_val[0..2], .little);
        }
    }

    // Read jxl source format (jx)
    if (try meta_reader.findKey("jx")) |jx_idx| {
        const jx_container = try meta_reader.valueAt(jx_idx);
        const jx_val = try leaf.readUtf8(jx_container);
        entry.jxl_source_format = try allocator.dupe(u8, jx_val);
    }

    // Read pdf stream length (pl)
    if (try meta_reader.findKey("pl")) |pl_idx| {
        const pl_container = try meta_reader.valueAt(pl_idx);
        const pl_val = try leaf.readData(pl_container);
        if (pl_val.len >= 8) {
            entry.pdf_stream_length = std.mem.readInt(u64, pl_val[0..8], .little);
        }
    }

    // Read pdf stream offset (po)
    if (try meta_reader.findKey("po")) |po_idx| {
        const po_container = try meta_reader.valueAt(po_idx);
        const po_val = try leaf.readData(po_container);
        if (po_val.len >= 8) {
            entry.pdf_stream_offset = std.mem.readInt(u64, po_val[0..8], .little);
        }
    }

    // Read flate BitsPerComponent (fb)
    if (try meta_reader.findKey("fb")) |fb_idx| {
        const fb_container = try meta_reader.valueAt(fb_idx);
        const fb_val = try leaf.readData(fb_container);
        if (fb_val.len >= 1) {
            entry.flate_bpc = fb_val[0];
        }
    }

    // Read flate columns (fc)
    if (try meta_reader.findKey("fc")) |fc_idx| {
        const fc_container = try meta_reader.valueAt(fc_idx);
        const fc_val = try leaf.readData(fc_container);
        if (fc_val.len >= 4) {
            entry.flate_columns = std.mem.readInt(u32, fc_val[0..4], .little);
        }
    }

    // Read flate colors (fl)
    if (try meta_reader.findKey("fl")) |fl_idx| {
        const fl_container = try meta_reader.valueAt(fl_idx);
        const fl_val = try leaf.readData(fl_container);
        if (fl_val.len >= 1) {
            entry.flate_colors = fl_val[0];
        }
    }

    // Read flate predictor (fp)
    if (try meta_reader.findKey("fp")) |fp_idx| {
        const fp_container = try meta_reader.valueAt(fp_idx);
        const fp_val = try leaf.readData(fp_container);
        if (fp_val.len >= 2) {
            entry.flate_predictor = std.mem.readInt(u16, fp_val[0..2], .little);
        }
    }

    // Read xattrs and resource fork from forks dict (element 2 if present)
    const elem_count = arr.elementCount();
    if (elem_count >= 3) {
        const forks_view = arr.elementAt(2) catch null;
        if (forks_view) |fv| {
            if (fv.type_id == .dict) {
                const forks_start = @intFromPtr(fv.buf.ptr) - @intFromPtr(reader.buf.ptr);
                const forks_end = forks_start + @as(usize, @intCast(fv.total_length));
                const forks_buf = reader.buf[forks_start..forks_end];
                const forks_reader = try dict_mod.DictReader.init(forks_buf);
                const fork_count = forks_reader.pairCount();

                // Check for resource fork
                if (try forks_reader.findKey("rf")) |rf_idx| {
                    const rf_container = try forks_reader.valueAt(rf_idx);
                    const rf_val = try leaf.readData(rf_container);
                    entry.resource_fork = try allocator.dupe(u8, rf_val);
                }

                // Count and collect xattrs (everything except "rf")
                var xattr_count: usize = 0;
                for (0..fork_count) |fi| {
                    const key_container = try forks_reader.keyAt(fi);
                    const key_bytes = try dict_mod.extractKeyBytes(key_container);
                    if (!std.mem.eql(u8, key_bytes, "rf")) {
                        xattr_count += 1;
                    }
                }

                if (xattr_count > 0) {
                    const xattrs = try allocator.alloc(mini_blar.XattrEntry, xattr_count);
                    var xi: usize = 0;
                    for (0..fork_count) |fi| {
                        const key_container = try forks_reader.keyAt(fi);
                        const key_bytes = try dict_mod.extractKeyBytes(key_container);
                        if (!std.mem.eql(u8, key_bytes, "rf")) {
                            const val_container = try forks_reader.valueAt(fi);
                            const val_bytes = try leaf.readData(val_container);
                            xattrs[xi] = .{
                                .name = try allocator.dupe(u8, key_bytes),
                                .value = try allocator.dupe(u8, val_bytes),
                            };
                            xi += 1;
                        }
                    }
                    entry.xattrs = xattrs;
                }
            }
        }
    }

    return entry;
}

/// Reconstruct a DirEntry from a DIR container in the archive.
fn reconstructDirEntry(allocator: Allocator, reader: mini_blar.ArchiveReader, index: u64) !mini_blar.DirEntry {
    const dict_reader = try reader.dirDictAt(index);

    // Read path
    const pa_idx = (try dict_reader.findKey("pa")) orelse return ContainerError.MissingRequiredKey;
    const pa_container = try dict_reader.valueAt(pa_idx);
    const path_slice = try leaf.readUtf8(pa_container);
    const path = try allocator.dupe(u8, path_slice);

    var entry = mini_blar.DirEntry{
        .path = path,
        .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    // Read xh (Merkle hash)
    if (try dict_reader.findKey("xh")) |xh_idx| {
        const xh_container = try dict_reader.valueAt(xh_idx);
        const xh_val = try leaf.readData(xh_container);
        if (xh_val.len >= 8) {
            @memcpy(&entry.xh64, xh_val[0..8]);
        }
    }

    // Read mode (md)
    if (try dict_reader.findKey("md")) |md_idx| {
        const md_container = try dict_reader.valueAt(md_idx);
        const md_val = try leaf.readData(md_container);
        if (md_val.len >= 2) {
            entry.mode = std.mem.readInt(u16, md_val[0..2], .little);
        }
    }

    // Read mtime (mt)
    if (try dict_reader.findKey("mt")) |mt_idx| {
        const mt_container = try dict_reader.valueAt(mt_idx);
        const mt_val = try leaf.readData(mt_container);
        if (mt_val.len >= 8) {
            entry.mtime_ns = std.mem.readInt(i64, mt_val[0..8], .little);
        }
    }

    // Read ctime (ct)
    if (try dict_reader.findKey("ct")) |ct_idx| {
        const ct_container = try dict_reader.valueAt(ct_idx);
        const ct_val = try leaf.readData(ct_container);
        if (ct_val.len >= 8) {
            entry.ctime_ns = std.mem.readInt(i64, ct_val[0..8], .little);
        }
    }

    // Read birthtime (bt)
    if (try dict_reader.findKey("bt")) |bt_idx| {
        const bt_container = try dict_reader.valueAt(bt_idx);
        const bt_val = try leaf.readData(bt_container);
        if (bt_val.len >= 8) {
            entry.birthtime_ns = std.mem.readInt(i64, bt_val[0..8], .little);
        }
    }

    // Read uid (ui)
    if (try dict_reader.findKey("ui")) |ui_idx| {
        const ui_container = try dict_reader.valueAt(ui_idx);
        const ui_val = try leaf.readData(ui_container);
        if (ui_val.len >= 4) {
            entry.uid = std.mem.readInt(u32, ui_val[0..4], .little);
        }
    }

    // Read gid (gi)
    if (try dict_reader.findKey("gi")) |gi_idx| {
        const gi_container = try dict_reader.valueAt(gi_idx);
        const gi_val = try leaf.readData(gi_container);
        if (gi_val.len >= 4) {
            entry.gid = std.mem.readInt(u32, gi_val[0..4], .little);
        }
    }

    // Read username (un)
    if (try dict_reader.findKey("un")) |un_idx| {
        const un_container = try dict_reader.valueAt(un_idx);
        const un_val = try leaf.readUtf8(un_container);
        entry.username = try allocator.dupe(u8, un_val);
    }

    // Read groupname (gn)
    if (try dict_reader.findKey("gn")) |gn_idx| {
        const gn_container = try dict_reader.valueAt(gn_idx);
        const gn_val = try leaf.readUtf8(gn_container);
        entry.groupname = try allocator.dupe(u8, gn_val);
    }

    // Read container type (co)
    if (try dict_reader.findKey("co")) |co_idx| {
        const co_container = try dict_reader.valueAt(co_idx);
        const co_val = try leaf.readUtf8(co_container);
        entry.container_type = try allocator.dupe(u8, co_val);
    }

    // Read xattrs (xa)
    if (try dict_reader.findKey("xa")) |xa_idx| {
        const xa_container = try dict_reader.valueAt(xa_idx);
        const xa_reader = try dict_mod.DictReader.init(xa_container);
        const xa_count = xa_reader.pairCount();
        if (xa_count > 0) {
            const xattrs = try allocator.alloc(mini_blar.XattrEntry, xa_count);
            for (0..xa_count) |xi| {
                const key_container = try xa_reader.keyAt(xi);
                const key_bytes = try dict_mod.extractKeyBytes(key_container);
                const val_container = try xa_reader.valueAt(xi);
                const val_bytes = try leaf.readData(val_container);
                xattrs[xi] = .{
                    .name = try allocator.dupe(u8, key_bytes),
                    .value = try allocator.dupe(u8, val_bytes),
                };
            }
            entry.xattrs = xattrs;
        }
    }

    return entry;
}

/// Reconstruct all entries from an archive buffer into ArchiveEntry structs.
/// Caller owns all allocated memory (entries, paths, content, etc.).
pub fn reconstructEntries(allocator: Allocator, buf: []const u8) ![]mini_blar.ArchiveEntry {
    const reader = try mini_blar.ArchiveReader.init(buf);
    const count = try reader.entryCount();

    var entries = try allocator.alloc(mini_blar.ArchiveEntry, count);
    errdefer allocator.free(entries);

    for (0..count) |i| {
        const entry_type = try reader.entryTypeAt(i);
        if (entry_type == .dir) {
            entries[i] = .{ .dir = try reconstructDirEntry(allocator, reader, i) };
        } else {
            entries[i] = .{ .file = try reconstructFileEntry(allocator, reader, i) };
        }
    }

    return entries;
}

// =============================================================================
// Poke: modify archive and re-serialize
// =============================================================================

/// Poke a new value into an archive at the given path.
/// Returns a newly allocated archive buffer with the modification applied.
/// Caller owns returned memory.
pub fn pokeArchive(allocator: Allocator, buf: []const u8, path_str: []const u8, new_value: []const u8) PokeError![]u8 {
    // Parse path
    const parsed = peek.parsePath(allocator, path_str) catch |e| switch (e) {
        error.UnclosedBracket => return PokeError.UnclosedBracket,
        error.EmptyBracket => return PokeError.EmptyBracket,
        error.InvalidIndex => return PokeError.InvalidIndex,
        error.UnexpectedCharacter => return PokeError.UnexpectedCharacter,
        error.OutOfMemory => return PokeError.OutOfMemory,
    };
    defer {
        var p = parsed;
        peek.freeParsedPath(allocator, &p);
    }

    // Validate: no accessors allowed for poke
    if (parsed.accessor != .none) return PokeError.NotALeaf;

    // Classify target
    const target = classifyTarget(parsed.segments);
    switch (target) {
        .immutable => return PokeError.ImmutableTarget,
        .container => return PokeError.NotALeaf,
        .data_content, .metadata_leaf => {},
    }

    // Reconstruct all entries
    const entries = reconstructEntries(allocator, buf) catch |e| {
        return switch (e) {
            error.OutOfMemory => PokeError.OutOfMemory,
            error.InvalidContainerType => PokeError.InvalidContainerType,
            error.InvalidLength => PokeError.InvalidLength,
            error.LengthExceedsBounds => PokeError.LengthExceedsBounds,
            error.MissingRequiredKey => PokeError.MissingRequiredKey,
            error.DuplicateKey => PokeError.DuplicateKey,
            error.KeysNotSorted => PokeError.KeysNotSorted,
            error.HashMismatch => PokeError.HashMismatch,
            error.IndexOutOfBounds => PokeError.IndexOutOfBounds,
            error.InvalidMagic => PokeError.InvalidMagic,
            error.BufferTooSmall => PokeError.BufferTooSmall,
            error.UnexpectedEndOfInput => PokeError.UnexpectedEndOfInput,
            error.Overflow => PokeError.Overflow,
            error.MissingSigil => PokeError.MissingSigil,
            error.InvalidSigilOrder => PokeError.InvalidSigilOrder,
            error.MissingDecompLen => PokeError.MissingDecompLen,
        };
    };
    defer {
        for (entries) |entry| {
            switch (entry) {
                .file => |f| {
                    allocator.free(f.path);
                    allocator.free(f.content);
                    if (f.username.len > 0) allocator.free(f.username);
                    if (f.groupname.len > 0) allocator.free(f.groupname);
                    if (f.resource_fork.len > 0) allocator.free(f.resource_fork);
                    for (f.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (f.xattrs.len > 0) allocator.free(f.xattrs);
                },
                .dir => |d| {
                    allocator.free(d.path);
                    if (d.username.len > 0) allocator.free(d.username);
                    if (d.groupname.len > 0) allocator.free(d.groupname);
                    for (d.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (d.xattrs.len > 0) allocator.free(d.xattrs);
                },
            }
        }
        allocator.free(entries);
    }

    // Apply the modification
    // Entries are sorted by path in createFullArchive. The archive reader returns
    // them in archive order (which is sorted), so entry index N in the reader
    // corresponds to entry index N in our reconstructed array.
    switch (target) {
        .data_content => {
            // [1][N][1] — replace content bytes
            const entry_idx = parsed.segments[1].index;
            if (entry_idx >= entries.len) return PokeError.IndexOutOfBounds;

            switch (entries[entry_idx]) {
                .file => |*f| {
                    allocator.free(f.content);
                    f.content = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                },
                .dir => return PokeError.NotALeaf,
            }
        },
        .metadata_leaf => {
            // [1][N][0][key] — replace metadata value
            const entry_idx = parsed.segments[1].index;
            if (entry_idx >= entries.len) return PokeError.IndexOutOfBounds;

            const key = switch (parsed.segments[3]) {
                .key => |k| k,
                .index => return PokeError.NotALeaf,
            };

            switch (entries[entry_idx]) {
                .file => |*f| {
                    if (std.mem.eql(u8, key, "pa")) {
                        allocator.free(f.path);
                        f.path = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "md")) {
                        if (new_value.len >= 2) {
                            f.mode = std.mem.readInt(u16, new_value[0..2], .little);
                        }
                    } else if (std.mem.eql(u8, key, "mt")) {
                        if (new_value.len >= 8) {
                            f.mtime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "ct")) {
                        if (new_value.len >= 8) {
                            f.ctime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "bt")) {
                        if (new_value.len >= 8) {
                            f.birthtime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "ui")) {
                        if (new_value.len >= 4) {
                            f.uid = std.mem.readInt(u32, new_value[0..4], .little);
                        }
                    } else if (std.mem.eql(u8, key, "gi")) {
                        if (new_value.len >= 4) {
                            f.gid = std.mem.readInt(u32, new_value[0..4], .little);
                        }
                    } else if (std.mem.eql(u8, key, "un")) {
                        if (f.username.len > 0) allocator.free(f.username);
                        f.username = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "gn")) {
                        if (f.groupname.len > 0) allocator.free(f.groupname);
                        f.groupname = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "zc")) {
                        if (new_value.len >= 2) {
                            f.zip_compression_method = std.mem.readInt(u16, new_value[0..2], .little);
                        }
                    } else if (std.mem.eql(u8, key, "jx")) {
                        if (f.jxl_source_format.len > 0) allocator.free(f.jxl_source_format);
                        f.jxl_source_format = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "pl")) {
                        if (new_value.len >= 8) {
                            f.pdf_stream_length = std.mem.readInt(u64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "po")) {
                        if (new_value.len >= 8) {
                            f.pdf_stream_offset = std.mem.readInt(u64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "fp")) {
                        if (new_value.len >= 2) {
                            f.flate_predictor = std.mem.readInt(u16, new_value[0..2], .little);
                        }
                    } else if (std.mem.eql(u8, key, "fc")) {
                        if (new_value.len >= 4) {
                            f.flate_columns = std.mem.readInt(u32, new_value[0..4], .little);
                        }
                    } else if (std.mem.eql(u8, key, "fl")) {
                        if (new_value.len >= 1) {
                            f.flate_colors = new_value[0];
                        }
                    } else if (std.mem.eql(u8, key, "fb")) {
                        if (new_value.len >= 1) {
                            f.flate_bpc = new_value[0];
                        }
                    } else {
                        return PokeError.IndexOutOfBounds; // unknown key
                    }
                },
                .dir => |*d| {
                    if (std.mem.eql(u8, key, "pa")) {
                        allocator.free(d.path);
                        d.path = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "md")) {
                        if (new_value.len >= 2) {
                            d.mode = std.mem.readInt(u16, new_value[0..2], .little);
                        }
                    } else if (std.mem.eql(u8, key, "mt")) {
                        if (new_value.len >= 8) {
                            d.mtime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "ct")) {
                        if (new_value.len >= 8) {
                            d.ctime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "bt")) {
                        if (new_value.len >= 8) {
                            d.birthtime_ns = std.mem.readInt(i64, new_value[0..8], .little);
                        }
                    } else if (std.mem.eql(u8, key, "ui")) {
                        if (new_value.len >= 4) {
                            d.uid = std.mem.readInt(u32, new_value[0..4], .little);
                        }
                    } else if (std.mem.eql(u8, key, "gi")) {
                        if (new_value.len >= 4) {
                            d.gid = std.mem.readInt(u32, new_value[0..4], .little);
                        }
                    } else if (std.mem.eql(u8, key, "un")) {
                        if (d.username.len > 0) allocator.free(d.username);
                        d.username = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "gn")) {
                        if (d.groupname.len > 0) allocator.free(d.groupname);
                        d.groupname = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else if (std.mem.eql(u8, key, "co")) {
                        if (d.container_type.len > 0) allocator.free(d.container_type);
                        d.container_type = allocator.dupe(u8, new_value) catch return PokeError.OutOfMemory;
                    } else {
                        return PokeError.IndexOutOfBounds;
                    }
                },
            }
        },
        .immutable, .container => unreachable, // handled above
    }

    // Re-serialize the archive
    const result = mini_blar.createFullArchive(allocator, entries, null, null, null, null, 0) catch |e| {
        return switch (e) {
            error.OutOfMemory => PokeError.OutOfMemory,
            error.InvalidContainerType => PokeError.InvalidContainerType,
            error.InvalidLength => PokeError.InvalidLength,
            error.LengthExceedsBounds => PokeError.LengthExceedsBounds,
            error.MissingRequiredKey => PokeError.MissingRequiredKey,
            error.DuplicateKey => PokeError.DuplicateKey,
            error.KeysNotSorted => PokeError.KeysNotSorted,
            error.HashMismatch => PokeError.HashMismatch,
            error.IndexOutOfBounds => PokeError.IndexOutOfBounds,
            error.InvalidMagic => PokeError.InvalidMagic,
            error.BufferTooSmall => PokeError.BufferTooSmall,
            error.UnexpectedEndOfInput => PokeError.UnexpectedEndOfInput,
            error.Overflow => PokeError.Overflow,
            error.MissingSigil => PokeError.MissingSigil,
            error.InvalidSigilOrder => PokeError.InvalidSigilOrder,
            error.MissingDecompLen => PokeError.MissingDecompLen,
            error.CompressionFailed, error.DecompressionFailed, error.UnsupportedCompression => PokeError.InvalidContainerType,
        };
    };

    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "round-trip: create -> reconstruct -> re-create produces identical archive" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "hello.txt", .content = "Hello, world!\n", .mode = 0o644, .mtime_ns = 1000000 },
        .{ .path = "test.bin", .content = "binary data", .mode = 0o755, .mtime_ns = 2000000 },
    };

    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
        .{ .file = files[1] },
    };

    const archive1 = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive1);

    // Reconstruct
    const reconstructed = try reconstructEntries(allocator, archive1);
    defer {
        for (reconstructed) |entry| {
            switch (entry) {
                .file => |f| {
                    allocator.free(f.path);
                    allocator.free(f.content);
                    if (f.username.len > 0) allocator.free(f.username);
                    if (f.groupname.len > 0) allocator.free(f.groupname);
                    if (f.resource_fork.len > 0) allocator.free(f.resource_fork);
                    for (f.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (f.xattrs.len > 0) allocator.free(f.xattrs);
                },
                .dir => |d| {
                    allocator.free(d.path);
                    if (d.username.len > 0) allocator.free(d.username);
                    if (d.groupname.len > 0) allocator.free(d.groupname);
                    for (d.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (d.xattrs.len > 0) allocator.free(d.xattrs);
                },
            }
        }
        allocator.free(reconstructed);
    }

    // Re-create
    const archive2 = try mini_blar.createFullArchive(allocator, reconstructed, null, null, null, null, 0);
    defer allocator.free(archive2);

    // Should be byte-identical
    try testing.expectEqualSlices(u8, archive1, archive2);
}

test "poke content: change DATA, verify via peek" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "original", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    // Poke new content
    const poked = try pokeArchive(allocator, archive, "[1][0][1]", "modified");
    defer allocator.free(poked);

    // Read back content
    const reader = try mini_blar.ArchiveReader.init(poked);
    const content = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, "modified", content);

    // Verify integrity
    try testing.expect(try reader.verifyChecksum());
    try testing.expect(try reader.verifyFileAt(0));
}

test "poke metadata: change path, verify" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "old.txt", .content = "data", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    // Poke new path
    const poked = try pokeArchive(allocator, archive, "[1][0][0][pa]", "new.txt");
    defer allocator.free(poked);

    // Read back path
    const reader = try mini_blar.ArchiveReader.init(poked);
    const path = try reader.entryPathAt(0);
    try testing.expectEqualSlices(u8, "new.txt", path);

    // Content should be unchanged
    const content = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, "data", content);

    // Integrity
    try testing.expect(try reader.verifyChecksum());
}

test "poke empty value allowed" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "some data", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    const poked = try pokeArchive(allocator, archive, "[1][0][1]", "");
    defer allocator.free(poked);

    const reader = try mini_blar.ArchiveReader.init(poked);
    const content = try reader.fileContentAt(0);
    try testing.expectEqual(@as(usize, 0), content.len);
    try testing.expect(try reader.verifyChecksum());
}

test "poke error on non-leaf target" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "data", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    // [1][0] is a FILE container, not a leaf
    try testing.expectError(PokeError.NotALeaf, pokeArchive(allocator, archive, "[1][0]", "x"));
    // [1] is the body array
    try testing.expectError(PokeError.NotALeaf, pokeArchive(allocator, archive, "[1]", "x"));
    // root
    try testing.expectError(PokeError.NotALeaf, pokeArchive(allocator, archive, "", "x"));
}

test "poke error on magic bytes" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "data", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    try testing.expectError(PokeError.ImmutableTarget, pokeArchive(allocator, archive, "[0]", "x"));
}

test "poke multi-file: only target modified" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "a.txt", .content = "alpha", .mode = 0o644 },
        .{ .path = "b.txt", .content = "bravo", .mode = 0o644 },
        .{ .path = "c.txt", .content = "charlie", .mode = 0o644 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
        .{ .file = files[1] },
        .{ .file = files[2] },
    };
    const archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive);

    // Poke file 1 (b.txt)
    const poked = try pokeArchive(allocator, archive, "[1][1][1]", "BRAVO");
    defer allocator.free(poked);

    const reader = try mini_blar.ArchiveReader.init(poked);

    // File 0 unchanged
    try testing.expectEqualSlices(u8, "alpha", try reader.fileContentAt(0));
    // File 1 modified
    try testing.expectEqualSlices(u8, "BRAVO", try reader.fileContentAt(1));
    // File 2 unchanged
    try testing.expectEqualSlices(u8, "charlie", try reader.fileContentAt(2));

    // Verify all hashes
    try testing.expect(try reader.verifyChecksum());
    for (0..3) |i| {
        try testing.expect(try reader.verifyFileAt(i));
    }
}

test "poke integrity passes after every poke" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "original", .mode = 0o644, .mtime_ns = 1000000, .username = "user1" },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    var archive = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);

    // Poke content
    const poked1 = try pokeArchive(allocator, archive, "[1][0][1]", "new content");
    allocator.free(archive);
    archive = poked1;

    var reader = try mini_blar.ArchiveReader.init(archive);
    try testing.expect(try reader.verifyChecksum());
    try testing.expect(try reader.verifyFileAt(0));

    // Poke path
    const poked2 = try pokeArchive(allocator, archive, "[1][0][0][pa]", "renamed.txt");
    allocator.free(archive);
    archive = poked2;

    reader = try mini_blar.ArchiveReader.init(archive);
    try testing.expect(try reader.verifyChecksum());
    try testing.expect(try reader.verifyFileAt(0));

    allocator.free(archive);
}

test "reconstruct preserves FILE with xattrs" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{
            .path = "test.txt",
            .content = "hello",
            .mode = 0o644,
            .xattrs = &[_]mini_blar.XattrEntry{
                .{ .name = "user.comment", .value = "test xattr" },
            },
        },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };
    const archive1 = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive1);

    const reconstructed = try reconstructEntries(allocator, archive1);
    defer {
        for (reconstructed) |entry| {
            switch (entry) {
                .file => |f| {
                    allocator.free(f.path);
                    allocator.free(f.content);
                    if (f.username.len > 0) allocator.free(f.username);
                    if (f.groupname.len > 0) allocator.free(f.groupname);
                    if (f.resource_fork.len > 0) allocator.free(f.resource_fork);
                    for (f.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (f.xattrs.len > 0) allocator.free(f.xattrs);
                },
                .dir => |d| {
                    allocator.free(d.path);
                    if (d.username.len > 0) allocator.free(d.username);
                    if (d.groupname.len > 0) allocator.free(d.groupname);
                    for (d.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (d.xattrs.len > 0) allocator.free(d.xattrs);
                },
            }
        }
        allocator.free(reconstructed);
    }

    const archive2 = try mini_blar.createFullArchive(allocator, reconstructed, null, null, null, null, 0);
    defer allocator.free(archive2);

    try testing.expectEqualSlices(u8, archive1, archive2);
}

test "reconstruct preserves DIR entries" {
    const allocator = testing.allocator;
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .dir = .{
            .path = "mydir",
            .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 },
            .mode = 0o755,
            .mtime_ns = 1708787200_000_000_000,
            .username = "peter",
        } },
        .{ .file = .{
            .path = "mydir/file.txt",
            .content = "hello",
            .mode = 0o644,
        } },
    };
    const archive1 = try mini_blar.createFullArchive(allocator, &entries, null, null, null, null, 0);
    defer allocator.free(archive1);

    const reconstructed = try reconstructEntries(allocator, archive1);
    defer {
        for (reconstructed) |entry| {
            switch (entry) {
                .file => |f| {
                    allocator.free(f.path);
                    allocator.free(f.content);
                    if (f.username.len > 0) allocator.free(f.username);
                    if (f.groupname.len > 0) allocator.free(f.groupname);
                    if (f.resource_fork.len > 0) allocator.free(f.resource_fork);
                    for (f.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (f.xattrs.len > 0) allocator.free(f.xattrs);
                },
                .dir => |d| {
                    allocator.free(d.path);
                    if (d.username.len > 0) allocator.free(d.username);
                    if (d.groupname.len > 0) allocator.free(d.groupname);
                    for (d.xattrs) |xa| {
                        allocator.free(xa.name);
                        allocator.free(xa.value);
                    }
                    if (d.xattrs.len > 0) allocator.free(d.xattrs);
                },
            }
        }
        allocator.free(reconstructed);
    }

    const archive2 = try mini_blar.createFullArchive(allocator, reconstructed, null, null, null, null, 0);
    defer allocator.free(archive2);

    try testing.expectEqualSlices(u8, archive1, archive2);
}
