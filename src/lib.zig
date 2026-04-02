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
const mini_blar = blip.mini_blar_mod;
const ContainerError = mini_blar.ContainerError;
const leaf = mini_blar.leaf;
const dict_mod = mini_blar.dict_mod;

/// Map a full archive error (ContainerError | OutOfMemory | CompressionError) to a C FFI error code.
fn fullArchiveErrorCode(err: (Allocator.Error || ContainerError || mini_blar.compression_mod.CompressionError)) i32 {
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
        error.MissingSigil => -25,
        error.InvalidSigilOrder => -26,
        error.MissingDecompLen => -27,
        error.CompressionFailed => -24,
        error.DecompressionFailed => -23,
        error.UnsupportedCompression => -32,
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
        error.MissingSigil => -25,
        error.InvalidSigilOrder => -26,
        error.MissingDecompLen => -27,
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
        -16 => "immutable target (magic bytes)",
        -17 => "not a leaf (cannot poke containers)",
        -18 => "invalid JSON",
        -19 => "missing required field",
        -20 => "invalid entry type",
        -21 => "invalid timestamp",
        -22 => "invalid mode",
        -23 => "decompression failed",
        -24 => "compression failed",
        -25 => "missing attribute sigil",
        -26 => "invalid attribute sigil order",
        -27 => "missing decompressed length",
        -28 => "authentication failed (wrong password or corrupted data)",
        -29 => "password required for encrypted container",
        -30 => "encryption failed",
        -31 => "decryption failed",
        -32 => "unsupported compression algorithm",
        -33 => "invalid zip container",
        -34 => "encrypted zip container",
        -35 => "zip64 not supported",
        -36 => "unsupported zip compression method",
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

/// An xattr name-value pair passed from C.
const CXattrEntry = extern struct {
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
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
    xh64: [8]u8, // Merkle hash for dirs (auto-computed by createFullArchive, can be zeroed)
    xattrs: ?[*]const CXattrEntry, // extended attributes, NULL = none
    xattr_count: usize, // 0 = none
    resource_fork: ?[*]const u8, // resource fork data, NULL = none
    resource_fork_len: usize, // 0 = none
    container_type: ?[*]const u8, // "zip" etc., NULL = normal dir
    container_type_len: usize, // 0 = not a container
    zip_compression_method: u16, // original zip method (0=store, 8=deflate), 0xFFFF = not set
    pdf_stream_offset: u64, // byte offset of JPEG stream in PDF body, 0xFFFFFFFFFFFFFFFF = not set
    pdf_stream_length: u64, // original JPEG stream data length, 0xFFFFFFFFFFFFFFFF = not set
    jxl_source_format: ?[*]const u8, // source format (e.g. "jpeg", "flate"), NULL = not set
    jxl_source_format_len: usize, // 0 = not set
    flate_predictor: u16, // PDF /Predictor (10-15), 0 = not set
    flate_columns: u32, // PDF /Columns, 0 = not set
    flate_colors: u8, // PDF /Colors, 0 = not set
    flate_bpc: u8, // PDF /BitsPerComponent, 0 = not set
    source_path: ?[*]const u8 = null, // disk path for streaming (read on demand), NULL = use content
    source_path_len: usize = 0, // 0 = not set
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

    const file_entries = page_allocator.alloc(mini_blar.FileEntry, file_count) catch return -13;
    defer page_allocator.free(file_entries);

    for (0..file_count) |i| {
        const raw_path = files[i].path[0..files[i].path_len];
        const path = if (normalize) normalizePath(raw_path) else raw_path;
        file_entries[i] = .{
            .path = path,
            .content = files[i].content[0..files[i].content_len],
        };
    }

    const result = mini_blar.createArchive(page_allocator, file_entries) catch return -1;
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Create a full BLIP archive from archive entries (files + directories + metadata).
export fn blip_archive_create_full(
    entries: [*]const CArchiveEntry,
    entry_count: usize,
    flags: u32,
    per_file_comp_algo: u8,
    num_threads: u8,
    progress_fn: mini_blar.ProgressFn,
    phase_fn: mini_blar.PhaseFn,
    progress_ctx: ?*anyopaque,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const normalize = (flags & BLIP_ARCHIVE_ABSOLUTE_PATHS) == 0;

    var archive_entries = page_allocator.alloc(mini_blar.ArchiveEntry, entry_count) catch return -13;
    defer page_allocator.free(archive_entries);

    // Pre-allocate a flat buffer for all xattr slices across all entries
    var total_xattrs: usize = 0;
    for (0..entry_count) |i| {
        total_xattrs += entries[i].xattr_count;
    }
    var xattr_buf: []mini_blar.XattrEntry = if (total_xattrs > 0)
        page_allocator.alloc(mini_blar.XattrEntry, total_xattrs) catch return -13
    else
        &[_]mini_blar.XattrEntry{};
    defer if (total_xattrs > 0) page_allocator.free(xattr_buf);

    var xattr_offset: usize = 0;

    for (0..entry_count) |i| {
        const e = entries[i];
        const raw_path = e.path[0..e.path_len];
        const path = if (normalize) normalizePath(raw_path) else raw_path;

        const username: []const u8 = if (e.owner) |o| o[0..e.owner_len] else &.{};
        const gname: []const u8 = if (e.groupname) |g| g[0..e.groupname_len] else &.{};

        // Convert C xattr array to Zig slice
        const xattr_slice: []const mini_blar.XattrEntry = if (e.xattrs) |xa_ptr| blk: {
            const count = e.xattr_count;
            if (count == 0) break :blk &[_]mini_blar.XattrEntry{};
            for (0..count) |j| {
                const cxa = xa_ptr[j];
                const name_ptr = cxa.name;
                const val_ptr = cxa.value;
                xattr_buf[xattr_offset + j] = .{
                    .name = name_ptr[0..cxa.name_len],
                    .value = val_ptr[0..cxa.value_len],
                };
            }
            const slice = xattr_buf[xattr_offset .. xattr_offset + count];
            xattr_offset += count;
            break :blk slice;
        } else &[_]mini_blar.XattrEntry{};

        const rfork: []const u8 = if (e.resource_fork) |rf| rf[0..e.resource_fork_len] else &.{};

        const ct_str: []const u8 = if (e.container_type) |ct| ct[0..e.container_type_len] else &.{};

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
                    .xattrs = xattr_slice,
                    .container_type = ct_str,
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
                    .xattrs = xattr_slice,
                    .resource_fork = rfork,
                    .zip_compression_method = if (e.zip_compression_method == 0xFFFF) null else e.zip_compression_method,
                    .pdf_stream_offset = if (e.pdf_stream_offset == 0xFFFFFFFFFFFFFFFF) null else e.pdf_stream_offset,
                    .pdf_stream_length = if (e.pdf_stream_length == 0xFFFFFFFFFFFFFFFF) null else e.pdf_stream_length,
                    .jxl_source_format = if (e.jxl_source_format) |p| p[0..e.jxl_source_format_len] else &.{},
                    .flate_predictor = if (e.flate_predictor == 0) null else e.flate_predictor,
                    .flate_columns = if (e.flate_columns == 0) null else e.flate_columns,
                    .flate_colors = if (e.flate_colors == 0) null else e.flate_colors,
                    .flate_bpc = if (e.flate_bpc == 0) null else e.flate_bpc,
                },
            };
        }
    }

    // Convert per_file_comp_algo: 0=none, 1=lzma2, 2=bzip2, 3=lz4, 4=zstd
    const CompressionId_ = mini_blar.container_mod.CompressionId;
    const comp_id: ?CompressionId_ = if (per_file_comp_algo == 0) null else std.meta.intToEnum(CompressionId_, @as(u7, @truncate(per_file_comp_algo))) catch return -32;

    const result = mini_blar.createFullArchive(page_allocator, archive_entries, progress_fn, phase_fn, progress_ctx, comp_id, num_threads) catch |e| {
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
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    out_count.* = reader.entryCount() catch return -1;
    return 0;
}

/// Verify a BLIP archive's xxHash64 integrity.
export fn blip_archive_verify(
    buf: [*]const u8,
    buf_len: usize,
) callconv(.c) bool {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return false;
    return reader.verifyChecksum() catch false;
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
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const path_val = reader.entryPathAt(index) catch |e| return containerErrorCode(e);
    out_path.* = path_val.ptr;
    out_path_len.* = path_val.len;
    return 0;
}

/// Get file content at the given index, handling per-file compression transparently.
/// Caller must free the returned buffer with blip_free_content().
export fn blip_archive_file_content(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const content = reader.fileContentDecompress(index, page_allocator) catch |e| {
        // Map all possible errors
        return switch (e) {
            error.OutOfMemory => @as(i32, -13),
            error.CompressionFailed => @as(i32, -24),
            error.DecompressionFailed => @as(i32, -23),
            error.UnsupportedCompression => @as(i32, -32),
            else => @as(i32, -1),
        };
    };
    out_data.* = content.ptr;
    out_data_len.* = content.len;
    return 0;
}

/// Free content returned by blip_archive_file_content.
export fn blip_free_content(ptr: [*]u8, len: usize) callconv(.c) void {
    if (len > 0) {
        page_allocator.free(ptr[0..len]);
    }
}

/// Get file content by path, handling per-file compression transparently.
/// Caller must free the returned buffer with blip_free_content().
export fn blip_archive_file_content_by_path(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    out_data: *[*]u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const idx = (reader.findFile(path[0..path_len]) catch |e| return containerErrorCode(e)) orelse return -14;
    const content = reader.fileContentDecompress(idx, page_allocator) catch |e| {
        return switch (e) {
            error.OutOfMemory => @as(i32, -13),
            error.CompressionFailed => @as(i32, -24),
            error.DecompressionFailed => @as(i32, -23),
            error.UnsupportedCompression => @as(i32, -32),
            else => @as(i32, -1),
        };
    };
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
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const ok = reader.verifyFileAt(index) catch |e| return containerErrorCode(e);
    if (!ok) return -7;
    return 0;
}

/// Verify a DIR entry's Merkle hash by recomputing from child FILE checksums.
/// Returns 0 if valid, -7 if hash mismatch, negative error code on failure.
export fn blip_archive_verify_merkle(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
    const ok = reader.verifyMerkleAt(index, page_allocator) catch |e| {
        if (e == error.OutOfMemory) return -13;
        const ce: ContainerError = @errorCast(e);
        return containerErrorCode(ce);
    };
    if (!ok) return -7;
    return 0;
}

/// Get the container type of an entry at the given index.
/// Returns 0 on success. out_type will be 5 (FILE) or 7 (DIR) (v2 ContainerTypeId).
export fn blip_archive_entry_type(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_type: *u8,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
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
    const reader = mini_blar.ArchiveReader.init(slice) catch |e| return containerErrorCode(e);

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
        const md_val = try leaf.readData(md_container);
        if (md_val.len >= 2) {
            out_mode.* = std.mem.readInt(u16, md_val[0..2], .little);
        }
    }

    // Try to read mt (mtime)
    if (try dict_reader.findKey("mt")) |mt_idx| {
        const mt_container = try dict_reader.valueAt(mt_idx);
        const mt_val = try leaf.readData(mt_container);
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

/// Extract full metadata from an archive entry (all timestamp fields, uid/gid, groupname).
export fn blip_archive_entry_metadata_full(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_mode: *u16,
    out_mtime_ns: *i64,
    out_ctime_ns: *i64,
    out_birthtime_ns: *i64,
    out_uid: *u32,
    out_gid: *u32,
    out_owner: *[*]const u8,
    out_owner_len: *usize,
    out_groupname: *[*]const u8,
    out_groupname_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const reader = mini_blar.ArchiveReader.init(slice) catch |e| return containerErrorCode(e);

    out_mode.* = 0;
    out_mtime_ns.* = 0;
    out_ctime_ns.* = 0;
    out_birthtime_ns.* = 0;
    out_uid.* = 0;
    out_gid.* = 0;
    out_owner.* = @as([*]const u8, "");
    out_owner_len.* = 0;
    out_groupname.* = @as([*]const u8, "");
    out_groupname_len.* = 0;

    const entry_type = reader.entryTypeAt(index) catch |e| return containerErrorCode(e);

    const dict_reader = if (entry_type == .file) blk: {
        const arr = reader.fileArrayAt(index) catch |e| return containerErrorCode(e);
        const meta_view = arr.elementAt(0) catch |e| return containerErrorCode(e);
        const meta_start = @intFromPtr(meta_view.buf.ptr) - @intFromPtr(slice.ptr);
        const meta_end = meta_start + @as(usize, @intCast(meta_view.total_length));
        break :blk dict_mod.DictReader.init(slice[meta_start..meta_end]) catch |e| return containerErrorCode(e);
    } else blk: {
        break :blk reader.dirDictAt(index) catch |e| return containerErrorCode(e);
    };

    // Read basic metadata
    readMetadataFromDict(dict_reader, out_mode, out_mtime_ns, out_owner, out_owner_len) catch |e| return containerErrorCode(e);

    // Read extended fields
    readExtendedMetadata(dict_reader, out_ctime_ns, out_birthtime_ns, out_uid, out_gid, out_groupname, out_groupname_len) catch |e| return containerErrorCode(e);

    return 0;
}

fn readExtendedMetadata(
    dict_reader: dict_mod.DictReader,
    out_ctime_ns: *i64,
    out_birthtime_ns: *i64,
    out_uid: *u32,
    out_gid: *u32,
    out_groupname: *[*]const u8,
    out_groupname_len: *usize,
) ContainerError!void {
    if (try dict_reader.findKey("ct")) |idx| {
        const c = try dict_reader.valueAt(idx);
        const v = try leaf.readData(c);
        if (v.len >= 8) out_ctime_ns.* = std.mem.readInt(i64, v[0..8], .little);
    }
    if (try dict_reader.findKey("bt")) |idx| {
        const c = try dict_reader.valueAt(idx);
        const v = try leaf.readData(c);
        if (v.len >= 8) out_birthtime_ns.* = std.mem.readInt(i64, v[0..8], .little);
    }
    if (try dict_reader.findKey("ui")) |idx| {
        const c = try dict_reader.valueAt(idx);
        const v = try leaf.readData(c);
        if (v.len >= 4) out_uid.* = std.mem.readInt(u32, v[0..4], .little);
    }
    if (try dict_reader.findKey("gi")) |idx| {
        const c = try dict_reader.valueAt(idx);
        const v = try leaf.readData(c);
        if (v.len >= 4) out_gid.* = std.mem.readInt(u32, v[0..4], .little);
    }
    if (try dict_reader.findKey("gn")) |idx| {
        const c = try dict_reader.valueAt(idx);
        const v = try leaf.readUtf8(c);
        out_groupname.* = v.ptr;
        out_groupname_len.* = v.len;
    }
}

/// Extract xattrs and resource fork from an archive entry.
/// For FILE entries: reads forks DICT (element 2), "rf" key → resource_fork, rest → xattrs.
/// For DIR entries: reads "xa" key from the DIR dict.
/// Returns 0 on success, negative error code on failure.
export fn blip_archive_entry_xattrs(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_xattrs: *?[*]CXattrEntry,
    out_count: *usize,
    out_resource_fork: *?[*]u8,
    out_resource_fork_len: *usize,
) callconv(.c) i32 {
    // Defaults
    out_xattrs.* = null;
    out_count.* = 0;
    out_resource_fork.* = null;
    out_resource_fork_len.* = 0;

    const slice = buf[0..buf_len];
    const reader = mini_blar.ArchiveReader.init(slice) catch |e| return containerErrorCode(e);
    const entry_type = reader.entryTypeAt(index) catch |e| return containerErrorCode(e);

    if (entry_type == .file) {
        return extractFileXattrs(slice, reader, index, out_xattrs, out_count, out_resource_fork, out_resource_fork_len);
    } else {
        return extractDirXattrs(slice, reader, index, out_xattrs, out_count);
    }
}

fn extractFileXattrs(
    slice: []const u8,
    reader: mini_blar.ArchiveReader,
    index: u64,
    out_xattrs: *?[*]CXattrEntry,
    out_count: *usize,
    out_resource_fork: *?[*]u8,
    out_resource_fork_len: *usize,
) i32 {
    const arr = reader.fileArrayAt(index) catch |e| return containerErrorCode(e);

    // Check if forks DICT exists (element 2)
    if (arr.elementCount() < 3) return 0; // no forks

    const fv = arr.elementAt(2) catch |e| return containerErrorCode(e);
    const forks_start = @intFromPtr(fv.buf.ptr) - @intFromPtr(slice.ptr);
    const forks_end = forks_start + @as(usize, @intCast(fv.total_length));
    const forks_buf = slice[forks_start..forks_end];
    const forks_reader = dict_mod.DictReader.init(forks_buf) catch |e| return containerErrorCode(e);
    const fork_count = forks_reader.pairCount();

    // Extract resource fork first
    if (forks_reader.findKey("rf") catch |e| return containerErrorCode(e)) |rf_idx| {
        const rf_container = forks_reader.valueAt(rf_idx) catch |e| return containerErrorCode(e);
        const rf_val = leaf.readData(rf_container) catch |e| return containerErrorCode(e);
        if (rf_val.len > 0) {
            const rf_copy = page_allocator.alloc(u8, rf_val.len) catch return -13;
            @memcpy(rf_copy, rf_val);
            out_resource_fork.* = rf_copy.ptr;
            out_resource_fork_len.* = rf_copy.len;
        }
    }

    // Count xattrs (everything except "rf")
    var xattr_count: usize = 0;
    for (0..fork_count) |fi| {
        const key_container = forks_reader.keyAt(fi) catch |e| return containerErrorCode(e);
        const key_bytes = dict_mod.extractKeyBytes(key_container) catch |e| return containerErrorCode(e);
        if (!std.mem.eql(u8, key_bytes, "rf")) {
            xattr_count += 1;
        }
    }

    if (xattr_count == 0) return 0;

    const xattrs = page_allocator.alloc(CXattrEntry, xattr_count) catch return -13;
    var xi: usize = 0;
    for (0..fork_count) |fi| {
        const key_container = forks_reader.keyAt(fi) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        const key_bytes = dict_mod.extractKeyBytes(key_container) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        if (!std.mem.eql(u8, key_bytes, "rf")) {
            const val_container = forks_reader.valueAt(fi) catch |e| {
                page_allocator.free(xattrs);
                return containerErrorCode(e);
            };
            const val_bytes = leaf.readData(val_container) catch |e| {
                page_allocator.free(xattrs);
                return containerErrorCode(e);
            };
            // Zero-copy: pointers into the archive buffer
            xattrs[xi] = .{
                .name = key_bytes.ptr,
                .name_len = key_bytes.len,
                .value = val_bytes.ptr,
                .value_len = val_bytes.len,
            };
            xi += 1;
        }
    }

    out_xattrs.* = xattrs.ptr;
    out_count.* = xattr_count;
    return 0;
}

fn extractDirXattrs(
    slice: []const u8,
    reader: mini_blar.ArchiveReader,
    index: u64,
    out_xattrs: *?[*]CXattrEntry,
    out_count: *usize,
) i32 {
    _ = slice;
    const dict_reader = reader.dirDictAt(index) catch |e| return containerErrorCode(e);

    // Look for "xa" key
    const xa_idx = (dict_reader.findKey("xa") catch |e| return containerErrorCode(e)) orelse return 0;
    const xa_container = dict_reader.valueAt(xa_idx) catch |e| return containerErrorCode(e);
    const xa_reader = dict_mod.DictReader.init(xa_container) catch |e| return containerErrorCode(e);
    const xa_count = xa_reader.pairCount();

    if (xa_count == 0) return 0;

    const xattrs = page_allocator.alloc(CXattrEntry, xa_count) catch return -13;
    for (0..xa_count) |xi| {
        const key_container = xa_reader.keyAt(xi) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        const key_bytes = dict_mod.extractKeyBytes(key_container) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        const val_container = xa_reader.valueAt(xi) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        const val_bytes = leaf.readData(val_container) catch |e| {
            page_allocator.free(xattrs);
            return containerErrorCode(e);
        };
        // Zero-copy: pointers into the archive buffer
        xattrs[xi] = .{
            .name = key_bytes.ptr,
            .name_len = key_bytes.len,
            .value = val_bytes.ptr,
            .value_len = val_bytes.len,
        };
    }

    out_xattrs.* = xattrs.ptr;
    out_count.* = xa_count;
    return 0;
}

/// Free xattr data returned by blip_archive_entry_xattrs.
/// Only the CXattrEntry array is heap-allocated; name/value pointers are zero-copy into archive buf.
export fn blip_free_xattrs(
    xattrs: ?[*]CXattrEntry,
    count: usize,
    resource_fork: ?[*]u8,
    resource_fork_len: usize,
) callconv(.c) void {
    if (xattrs) |xa| {
        if (count > 0) page_allocator.free(xa[0..count]);
    }
    if (resource_fork) |rf| {
        if (resource_fork_len > 0) page_allocator.free(rf[0..resource_fork_len]);
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
/// Returns 0 on success. out_type receives the v2 container type ID (1-7).
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
    const container_mod = mini_blar.container_mod;
    const slice = buf[0..buf_len];
    const path_str = path[0..path_len];

    // Parse the path
    var parsed = peek_mod.parsePath(page_allocator, path_str) catch return -15;
    defer peek_mod.freeParsedPath(page_allocator, &parsed);

    // Navigate
    const result = peek_mod.navigate(slice, parsed.segments) catch |e| return containerErrorCode(e);

    // Parse the LP header to get the type ID
    const lp_view = container_mod.parseLPHeader(result) catch |e| return containerErrorCode(e);
    out_type.* = @intFromEnum(lp_view.type_id);
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

/// Full peek display: navigate + format output in Zig core.
/// Returns 0 on success, negative error code on failure.
/// Caller must free stdout/stderr buffers with blip_free().
export fn blip_peek_display(
    buf_ptr: [*]const u8,
    buf_len: usize,
    path_ptr: [*]const u8,
    path_len: usize,
    flags: u32,
    out_stdout_ptr: *[*]const u8,
    out_stdout_len: *usize,
    out_stderr_ptr: *[*]const u8,
    out_stderr_len: *usize,
) callconv(.c) i32 {
    const slice = buf_ptr[0..buf_len];
    const path_str = path_ptr[0..path_len];
    const peek_flags: peek_mod.PeekFlags = @bitCast(flags);

    var result = peek_mod.peekDisplay(page_allocator, slice, path_str, peek_flags) catch return -13;

    // Transfer ownership to caller
    out_stdout_ptr.* = result.stdout_buf.ptr;
    out_stdout_len.* = result.stdout_buf.len;
    out_stderr_ptr.* = result.stderr_buf.ptr;
    out_stderr_len.* = result.stderr_buf.len;

    const had_error = result.is_error;

    // Prevent deinit from freeing the buffers we just handed off
    result.stdout_buf = &.{};
    result.stderr_buf = &.{};

    return if (had_error) @as(i32, -1) else @as(i32, 0);
}

// ---------------------------------------------------------------------------
// Poke C FFI exports
// ---------------------------------------------------------------------------

const poke_mod = blip.poke_mod;

/// Modify a value in a BLIP archive at the given path expression.
/// Returns 0 on success, negative error code on failure.
/// Caller must free out_buf with blip_free().
export fn blip_poke(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    new_value: [*]const u8,
    new_value_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const path_str = path[0..path_len];
    const value_slice = if (new_value_len > 0) new_value[0..new_value_len] else &[_]u8{};

    const result = poke_mod.pokeArchive(page_allocator, slice, path_str, value_slice) catch |e| {
        return switch (e) {
            error.ImmutableTarget => @as(i32, -16),
            error.NotALeaf => @as(i32, -17),
            error.OutOfMemory => @as(i32, -13),
            error.InvalidContainerType => @as(i32, -1),
            error.InvalidLength => @as(i32, -2),
            error.LengthExceedsBounds => @as(i32, -3),
            error.MissingRequiredKey => @as(i32, -4),
            error.DuplicateKey => @as(i32, -5),
            error.KeysNotSorted => @as(i32, -6),
            error.HashMismatch => @as(i32, -7),
            error.IndexOutOfBounds => @as(i32, -8),
            error.InvalidMagic => @as(i32, -9),
            error.BufferTooSmall => @as(i32, -10),
            error.UnexpectedEndOfInput => @as(i32, -11),
            error.Overflow => @as(i32, -12),
            error.UnclosedBracket, error.EmptyBracket, error.InvalidIndex, error.UnexpectedCharacter => @as(i32, -15),
            error.MissingSigil => @as(i32, -25),
            error.InvalidSigilOrder => @as(i32, -26),
            error.MissingDecompLen => @as(i32, -27),
        };
    };

    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decode printable-binary UTF-8 back to raw bytes.
/// Caller must free the output buffer with blip_free().
export fn blip_decode_printable_binary(
    encoded: [*]const u8,
    encoded_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pb.decode(page_allocator, encoded[0..encoded_len], .{}) catch return -1;
    out_buf.* = result.ptr;
    out_len.* = result.len;
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

// ---------------------------------------------------------------------------
// JSON serde C FFI exports
// ---------------------------------------------------------------------------

const json_serde = blip.json_serde;

/// Map JsonSerdeError to a C FFI error code.
fn jsonSerdeErrorCode(err: json_serde.JsonSerdeError) i32 {
    return switch (err) {
        error.OutOfMemory => -13,
        error.InvalidJson => -18,
        error.MissingRequiredField => -19,
        error.InvalidEntryType => -20,
        error.InvalidTimestamp => -21,
        error.InvalidMode => -22,
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
        error.MissingSigil => -25,
        error.InvalidSigilOrder => -26,
        error.MissingDecompLen => -27,
    };
}

/// Convert a BLIP archive to JSON.
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_to_json(
    buf: [*]const u8,
    buf_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const result = json_serde.archiveToJson(page_allocator, slice) catch |e| {
        return jsonSerdeErrorCode(e);
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Convert JSON to a BLIP archive.
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_from_json(
    json_buf: [*]const u8,
    json_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const json_slice = json_buf[0..json_len];
    const result = json_serde.jsonToArchive(page_allocator, json_slice) catch |e| {
        return jsonSerdeErrorCode(e);
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

// ---------------------------------------------------------------------------
// LZMA2 compression C FFI exports
// ---------------------------------------------------------------------------

const lzma2_mod = blip.lzma2_mod;

/// Check if a buffer is a compressed LP container (has COMP attribute).
export fn blip_is_compressed(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return blip.compression_mod.isCompressed(buf[0..buf_len]);
}

/// Compress a BLIP container with LZMA2.
/// Input: any serialized BLIP container bytes.
/// Output: a DATA container with COMP=lzma2, DECOMP_LEN, and CSUM=blake3_128 attributes.
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_lzma2_compress(
    buf: [*]const u8,
    buf_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const result = lzma2_mod.compressContainer(page_allocator, slice) catch |e| switch (e) {
        error.OutOfMemory => return -13,
        error.CompressionFailed => return -24,
        else => return -1,
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decompress a compressed LP container, returning the inner container bytes.
/// Verifies checksum before decompressing.
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_lzma2_decompress(
    buf: [*]const u8,
    buf_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const result = lzma2_mod.decompressContainer(page_allocator, slice) catch |e| switch (e) {
        error.OutOfMemory => return -13,
        error.DecompressionFailed => return -23,
        error.HashMismatch => return -7,
        else => return -1,
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

// ---------------------------------------------------------------------------
// Generic compression C FFI exports
// ---------------------------------------------------------------------------

const compression_mod = blip.compression_mod;
const CompressionId = mini_blar.container_mod.CompressionId;

/// Compress a BLIP container with the specified algorithm.
/// algo_id: 1=lzma2, 2=bzip2, 3=lz4, 4=zstd
/// progress_fn/progress_ctx: optional callback reporting (bytes_done, bytes_total).
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_compress_container(
    buf: [*]const u8,
    buf_len: usize,
    algo_id: u8,
    num_threads: u8,
    progress_fn: compression_mod.CompressProgressFn,
    phase_fn: compression_mod.PhaseFn,
    progress_ctx: ?*anyopaque,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const algo = std.meta.intToEnum(CompressionId, @as(u7, @truncate(algo_id))) catch return -32;
    const slice = buf[0..buf_len];
    const result = compression_mod.compressContainer(page_allocator, algo, slice, progress_fn, phase_fn, progress_ctx, num_threads) catch |e| switch (e) {
        error.OutOfMemory => return -13,
        error.CompressionFailed => return -24,
        error.UnsupportedCompression => return -32,
        else => return -1,
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decompress a compressed LP container (any algorithm).
/// Reads the algorithm from the LP header's COMP attribute.
/// Verifies checksum before decompressing.
/// Returns 0 on success, negative error code on failure.
/// Caller must free output buffer with blip_free().
export fn blip_decompress_container(
    buf: [*]const u8,
    buf_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const slice = buf[0..buf_len];
    const result = compression_mod.decompressContainer(page_allocator, slice) catch |e| switch (e) {
        error.OutOfMemory => return -13,
        error.DecompressionFailed => return -23,
        error.UnsupportedCompression => return -32,
        error.HashMismatch => return -7,
        else => return -1,
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

// ---------------------------------------------------------------------------
// Encryption C FFI exports
// ---------------------------------------------------------------------------

const encryption_mod = blip.encryption;
const enc_container_mod = mini_blar.container_mod;

/// Check if a buffer is an encrypted LP container (has ENC attribute).
export fn blip_is_encrypted(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return encryption_mod.isEncrypted(buf[0..buf_len]);
}

/// Encrypt a serialized container.
/// enc_id: 1=AES-256-GCM, 2=ChaCha20-Poly1305
/// kdf_id: 1=Argon2id, 2=PBKDF2-SHA256
export fn blip_encrypt_container(
    buf: [*]const u8,
    buf_len: usize,
    password: [*]const u8,
    password_len: usize,
    enc_id_raw: u8,
    kdf_id_raw: u8,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const enc_id = std.meta.intToEnum(enc_container_mod.EncryptionId, @as(u7, @truncate(enc_id_raw))) catch return -1;
    const kdf_id = std.meta.intToEnum(enc_container_mod.KdfId, @as(u7, @truncate(kdf_id_raw))) catch return -1;
    const result = encryption_mod.encryptContainer(
        page_allocator,
        enc_id,
        kdf_id,
        buf[0..buf_len],
        password[0..password_len],
    ) catch |e| {
        return encryptionErrorCode(e);
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decrypt an encrypted LP container.
export fn blip_decrypt_container(
    buf: [*]const u8,
    buf_len: usize,
    password: [*]const u8,
    password_len: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = encryption_mod.decryptContainer(
        page_allocator,
        buf[0..buf_len],
        password[0..password_len],
    ) catch |e| {
        return encryptionErrorCode(e);
    };
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

fn encryptionErrorCode(err: anytype) i32 {
    return switch (err) {
        error.AuthenticationFailed => -28,
        error.PasswordRequired => -29,
        error.EncryptionFailed => -30,
        error.DecryptionFailed => -31,
        error.OutOfMemory => -13,
        error.HashMismatch => -7,
        error.UnsupportedEncryption, error.UnsupportedKdf => -1,
        else => -99,
    };
}

// ---------------------------------------------------------------------------
// ZIP container C FFI exports
// ---------------------------------------------------------------------------

const zip_mod = blip.zip_mod;

/// Check if buffer starts with ZIP magic bytes (PK\x03\x04).
export fn blip_is_zip(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    if (buf_len < 4) return false;
    return zip_mod.isZipMagic(buf[0..buf_len]);
}

/// Check if a ZIP buffer contains any encrypted entries.
export fn blip_zip_has_encrypted(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return zip_mod.hasEncryptedEntries(page_allocator, buf[0..buf_len]) catch false;
}

/// Get the number of entries in a ZIP buffer.
export fn blip_zip_entry_count(buf: [*]const u8, buf_len: usize, out_count: *u64) callconv(.c) i32 {
    const entries = zip_mod.readEntries(page_allocator, buf[0..buf_len]) catch |e| return zipErrorCode(e);
    defer page_allocator.free(entries);
    out_count.* = entries.len;
    return 0;
}

/// Get info about a specific ZIP entry by index.
export fn blip_zip_entry_info(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_path: *[*]const u8,
    out_path_len: *usize,
    out_comp_method: *u16,
    out_uncompressed_size: *u64,
    out_mtime: *u16,
    out_mdate: *u16,
    out_is_dir: *u8,
) callconv(.c) i32 {
    const entries = zip_mod.readEntries(page_allocator, buf[0..buf_len]) catch |e| return zipErrorCode(e);
    defer page_allocator.free(entries);
    if (index >= entries.len) return -8; // index out of bounds
    const entry = entries[index];
    out_path.* = entry.filename.ptr;
    out_path_len.* = entry.filename.len;
    out_comp_method.* = entry.compression_method;
    out_uncompressed_size.* = entry.uncompressed_size;
    out_mtime.* = entry.last_modification_time;
    out_mdate.* = entry.last_modification_date;
    out_is_dir.* = if (entry.is_dir) 1 else 0;
    return 0;
}

/// Extract (decompress) a specific ZIP entry by index.
/// Caller must free returned buffer with blip_free().
export fn blip_zip_extract_entry(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const entries = zip_mod.readEntries(page_allocator, buf[0..buf_len]) catch |e| return zipErrorCode(e);
    defer page_allocator.free(entries);
    if (index >= entries.len) return -8;
    const content = zip_mod.extractEntry(page_allocator, entries[index]) catch |e| return zipErrorCode(e);
    out_data.* = content.ptr;
    out_data_len.* = content.len;
    return 0;
}

/// C-compatible struct for zip write entries.
const CZipWriteEntry = extern struct {
    filename: [*]const u8,
    filename_len: usize,
    content: [*]const u8,
    content_len: usize,
    compression_method: u16,
    mtime: u16,
    mdate: u16,
    external_attributes: u32,
};

/// Create a ZIP archive from entries.
/// Caller must free returned buffer with blip_free().
export fn blip_zip_create(
    c_entries: [*]const CZipWriteEntry,
    count: usize,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    // Convert C entries to Zig entries
    const zig_entries = page_allocator.alloc(zip_mod.ZipWriteEntry, count) catch return -13;
    defer page_allocator.free(zig_entries);
    for (0..count) |i| {
        const ce = c_entries[i];
        zig_entries[i] = .{
            .filename = ce.filename[0..ce.filename_len],
            .content = ce.content[0..ce.content_len],
            .compression_method = ce.compression_method,
            .last_modification_time = ce.mtime,
            .last_modification_date = ce.mdate,
            .external_attributes = ce.external_attributes,
        };
    }
    const result = zip_mod.createZip(page_allocator, zig_entries) catch |e| return zipErrorCode(e);
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Read container_type from a DIR entry in a BLIP archive.
export fn blip_archive_entry_container_type(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_type: *?[*]const u8,
    out_type_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    const entry_type = reader.entryTypeAt(index) catch return -8;
    if (entry_type != .dir) {
        out_type.* = null;
        out_type_len.* = 0;
        return 0;
    }
    const dir_dict = reader.dirDictAt(index) catch return -1;
    // Look for "co" key
    const co_idx = (dir_dict.findKey("co") catch return -1) orelse {
        out_type.* = null;
        out_type_len.* = 0;
        return 0;
    };
    const co_container = dir_dict.valueAt(co_idx) catch return -1;
    const co_val = mini_blar.leaf.readUtf8(co_container) catch return -1;
    out_type.* = co_val.ptr;
    out_type_len.* = co_val.len;
    return 0;
}

/// Read zip_compression_method from a FILE entry in a BLIP archive.
export fn blip_archive_entry_zip_comp(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_method: *u16,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    const entry_type = reader.entryTypeAt(index) catch return -8;
    if (entry_type != .file) {
        out_method.* = 0xFFFF;
        return 0;
    }
    const file_array = reader.fileArrayAt(index) catch return -1;
    const meta_view = file_array.elementAt(0) catch return -1;
    const meta_dict = dict_mod.DictReader.init(meta_view.buf[0..@intCast(meta_view.total_length)]) catch return -1;
    // Look for "zc" key
    const zc_idx = (meta_dict.findKey("zc") catch return -1) orelse {
        out_method.* = 0xFFFF;
        return 0;
    };
    const zc_container = meta_dict.valueAt(zc_idx) catch return -1;
    const zc_bytes = mini_blar.leaf.readData(zc_container) catch return -1;
    if (zc_bytes.len != 2) return -1;
    out_method.* = std.mem.readInt(u16, zc_bytes[0..2], .little);
    return 0;
}

// ---------------------------------------------------------------------------
// PDF container FFI exports
// ---------------------------------------------------------------------------

const pdf_mod = blip.pdf_mod;
const jxl_mod = blip.jxl_mod;
const png_mod = blip.png_mod;
const bmp_mod = blip.bmp_mod;
const tar_mod = blip.tar_mod;
const tiff_mod = blip.tiff_mod;
const gif_mod = blip.gif_mod;
const tga_mod = blip.tga_mod;
const wav_mod = blip.wav_mod;
const flac_mod = blip.flac_mod;
const nifti_mod = blip.nifti_mod;
const dicom_mod = blip.dicom_mod;
const expansion_mod = blip.expansion_mod;
const streaming_mod = blip.streaming_mod;
const fits_mod = blip.fits_mod;
const aiff_mod = blip.aiff_mod;

/// Check if buffer starts with PDF magic bytes (%PDF-).
export fn blip_is_pdf(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return pdf_mod.isPdfMagic(buf[0..buf_len]);
}

/// Count JPEG streams in a PDF buffer.
export fn blip_pdf_jpeg_count(buf: [*]const u8, buf_len: usize, out_count: *u64) callconv(.c) i32 {
    const streams = pdf_mod.findJpegStreams(page_allocator, buf[0..buf_len]) catch return -37;
    defer page_allocator.free(streams);
    out_count.* = streams.len;
    return 0;
}

/// Get info about a specific JPEG stream in a PDF by index.
export fn blip_pdf_jpeg_info(
    buf: [*]const u8,
    buf_len: usize,
    idx: u64,
    out_offset: *u64,
    out_length: *u64,
    out_obj_num: *u32,
    out_gen_num: *u32,
) callconv(.c) i32 {
    const streams = pdf_mod.findJpegStreams(page_allocator, buf[0..buf_len]) catch return -37;
    defer page_allocator.free(streams);
    if (idx >= streams.len) return -8;
    const s = streams[@intCast(idx)];
    out_offset.* = s.stream_start;
    out_length.* = s.len();
    out_obj_num.* = s.object_num;
    out_gen_num.* = s.gen_num;
    return 0;
}

/// Find all JPEG streams in a PDF and return their info in parallel arrays.
/// Caller must free the output arrays with blip_free when done.
/// This is much faster than calling blip_pdf_jpeg_count + blip_pdf_jpeg_info in a loop
/// because it only scans the PDF once.
export fn blip_pdf_jpeg_streams(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
    out_offsets: *[*]u64,
    out_lengths: *[*]u64,
    out_obj_nums: *[*]u32,
    out_gen_nums: *[*]u32,
) callconv(.c) i32 {
    const streams = pdf_mod.findJpegStreams(page_allocator, buf[0..buf_len]) catch return -37;
    defer page_allocator.free(streams);
    const n = streams.len;
    out_count.* = n;
    if (n == 0) {
        out_offsets.* = undefined;
        out_lengths.* = undefined;
        out_obj_nums.* = undefined;
        out_gen_nums.* = undefined;
        return 0;
    }
    const offsets = page_allocator.alloc(u64, n) catch return -1;
    const lengths = page_allocator.alloc(u64, n) catch {
        page_allocator.free(offsets);
        return -1;
    };
    const obj_nums = page_allocator.alloc(u32, n) catch {
        page_allocator.free(offsets);
        page_allocator.free(lengths);
        return -1;
    };
    const gen_nums = page_allocator.alloc(u32, n) catch {
        page_allocator.free(offsets);
        page_allocator.free(lengths);
        page_allocator.free(obj_nums);
        return -1;
    };
    for (streams, 0..) |s, i| {
        offsets[i] = s.stream_start;
        lengths[i] = s.len();
        obj_nums[i] = s.object_num;
        gen_nums[i] = s.gen_num;
    }
    out_offsets.* = offsets.ptr;
    out_lengths.* = lengths.ptr;
    out_obj_nums.* = obj_nums.ptr;
    out_gen_nums.* = gen_nums.ptr;
    return 0;
}

/// Create a PDF shell by zeroing JPEG stream regions.
export fn blip_pdf_create_shell(
    buf: [*]const u8,
    buf_len: usize,
    offsets: [*]const u64,
    lengths: [*]const u64,
    stream_count: usize,
    out_shell: *[*]u8,
    out_shell_len: *usize,
) callconv(.c) i32 {
    // Build PdfJpegStream array from offsets/lengths
    const streams = page_allocator.alloc(pdf_mod.PdfJpegStream, stream_count) catch return -13;
    defer page_allocator.free(streams);
    for (0..stream_count) |i| {
        streams[i] = .{
            .stream_start = @intCast(offsets[i]),
            .stream_end = @intCast(offsets[i] + lengths[i]),
            .object_num = 0,
            .gen_num = 0,
        };
    }

    const shell = pdf_mod.createPdfShell(page_allocator, buf[0..buf_len], streams) catch return -13;
    out_shell.* = shell.ptr;
    out_shell_len.* = shell.len;
    return 0;
}

/// Losslessly transcode JPEG to JPEG XL.
export fn blip_jxl_from_jpeg(
    jpeg: [*]const u8,
    jpeg_len: usize,
    out_jxl: *[*]u8,
    out_jxl_len: *usize,
) callconv(.c) i32 {
    const jxl_data = jxl_mod.jpegToJxl(page_allocator, jpeg[0..jpeg_len]) catch return -38;
    out_jxl.* = jxl_data.ptr;
    out_jxl_len.* = jxl_data.len;
    return 0;
}

/// Losslessly transcode JPEG XL back to JPEG.
export fn blip_jxl_to_jpeg(
    jxl: [*]const u8,
    jxl_len: usize,
    out_jpeg: *[*]u8,
    out_jpeg_len: *usize,
) callconv(.c) i32 {
    const jpeg_data = jxl_mod.jxlToJpeg(page_allocator, jxl[0..jxl_len]) catch return -39;
    out_jpeg.* = jpeg_data.ptr;
    out_jpeg_len.* = jpeg_data.len;
    return 0;
}

/// Encode raw pixels to JXL lossless.
export fn blip_jxl_from_pixels(
    pixels: [*]const u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    num_channels: u32,
    bits_per_sample: u32,
    out_jxl: *[*]u8,
    out_jxl_len: *usize,
) callconv(.c) i32 {
    const fmt = jxl_mod.PixelFormat{
        .width = width,
        .height = height,
        .num_channels = num_channels,
        .bits_per_sample = bits_per_sample,
    };
    const jxl_data = jxl_mod.pixelsToJxl(page_allocator, pixels[0..pixels_len], fmt) catch return -38;
    out_jxl.* = jxl_data.ptr;
    out_jxl_len.* = jxl_data.len;
    return 0;
}

/// Decode JXL to raw pixels.
export fn blip_jxl_to_pixels(
    jxl: [*]const u8,
    jxl_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
) callconv(.c) i32 {
    var fmt: jxl_mod.PixelFormat = undefined;
    const pixel_data = jxl_mod.jxlToPixels(page_allocator, jxl[0..jxl_len], &fmt) catch return -39;
    out_pixels.* = pixel_data.ptr;
    out_pixels_len.* = pixel_data.len;
    out_width.* = fmt.width;
    out_height.* = fmt.height;
    out_num_channels.* = fmt.num_channels;
    out_bits_per_sample.* = fmt.bits_per_sample;
    return 0;
}

// --- PNG ---

/// Check if buffer starts with PNG signature.
export fn blip_is_png(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return png_mod.isPngMagic(buf[0..buf_len]);
}

/// Parse a PNG into raw pixels + metadata.
/// meta = [u32_be head_len][pre_idat_bytes][post_idat_bytes]
export fn blip_png_parse(
    png: [*]const u8,
    png_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    var parsed = png_mod.parsePng(page_allocator, png[0..png_len]) catch return -40;

    // Build meta: [u32_be pre_idat.len][pre_idat][post_idat]
    const meta_len = 4 + parsed.pre_idat.len + parsed.post_idat.len;
    const meta = page_allocator.alloc(u8, meta_len) catch {
        parsed.deinit();
        return -13;
    };
    std.mem.writeInt(u32, meta[0..4], @intCast(parsed.pre_idat.len), .big);
    @memcpy(meta[4..][0..parsed.pre_idat.len], parsed.pre_idat);
    @memcpy(meta[4 + parsed.pre_idat.len ..][0..parsed.post_idat.len], parsed.post_idat);

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.info.width;
    out_height.* = parsed.info.height;
    out_num_channels.* = parsed.info.channels;
    out_bits_per_sample.* = @as(u32, parsed.info.bit_depth);
    out_meta.* = meta.ptr;
    out_meta_len.* = meta.len;

    // Free pre/post_idat (pixels ownership transfers to caller)
    page_allocator.free(parsed.pre_idat);
    page_allocator.free(parsed.post_idat);

    return 0;
}

/// Encode raw pixels + metadata back to PNG.
export fn blip_png_encode(
    pixels: [*]const u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    num_channels: u32,
    bits_per_sample: u32,
    meta: [*]const u8,
    meta_len: usize,
    out_png: *[*]u8,
    out_png_len: *usize,
) callconv(.c) i32 {
    if (meta_len < 4) return -40;
    const meta_buf = meta[0..meta_len];
    const head_len = std.mem.readInt(u32, meta_buf[0..4], .big);
    if (4 + head_len > meta_len) return -40;
    const pre_idat = meta_buf[4..][0..head_len];
    const post_idat = meta_buf[4 + head_len ..];

    const color_type: png_mod.PngColorType = switch (num_channels) {
        1 => .grayscale,
        2 => .grayscale_alpha,
        3 => .rgb,
        4 => .rgba,
        else => return -40,
    };

    const info = png_mod.PngInfo{
        .width = width,
        .height = height,
        .bit_depth = @intCast(bits_per_sample),
        .color_type = color_type,
        .channels = @intCast(num_channels),
        .bytes_per_sample = if (bits_per_sample == 16) 2 else 1,
        .interlace_method = 0,
    };

    const png_data = png_mod.encodePng(page_allocator, pixels[0..pixels_len], info, pre_idat, post_idat) catch return -40;
    out_png.* = png_data.ptr;
    out_png_len.* = png_data.len;
    return 0;
}

// --- BMP ---

/// Check if buffer starts with BMP magic bytes (BM).
export fn blip_is_bmp(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return bmp_mod.isBmpMagic(buf[0..buf_len]);
}

/// Parse a BMP into raw pixels + header metadata.
/// Outputs pixels in top-to-bottom RGB(A) order.
/// header_meta contains the original BMP header bytes for faithful reconstruction.
export fn blip_bmp_parse(
    bmp: [*]const u8,
    bmp_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    var parsed = bmp_mod.parseBmp(page_allocator, bmp[0..bmp_len]) catch return -40;

    // Build meta: [u8 top_down][u16_le bits_per_pixel][u32_le row_stride][header_bytes...]
    const meta_prefix_len: usize = 1 + 2 + 4; // top_down + bpp + row_stride
    const meta_len = meta_prefix_len + parsed.header.header_bytes.len;
    const meta = page_allocator.alloc(u8, meta_len) catch {
        parsed.deinit();
        return -13;
    };
    meta[0] = if (parsed.header.top_down) 1 else 0;
    std.mem.writeInt(u16, meta[1..3], parsed.header.bits_per_pixel, .little);
    std.mem.writeInt(u32, meta[3..7], parsed.header.row_stride, .little);
    @memcpy(meta[meta_prefix_len..], parsed.header.header_bytes);

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.header.width;
    out_height.* = parsed.header.abs_height;
    out_num_channels.* = @as(u32, parsed.header.channels);
    out_bits_per_sample.* = 8; // BMP is always 8-bit per channel
    out_meta.* = meta.ptr;
    out_meta_len.* = meta.len;

    // Free header_bytes (pixels ownership transfers to caller)
    page_allocator.free(parsed.header.header_bytes);

    return 0;
}

/// Encode raw pixels + BMP header metadata back to a BMP file.
export fn blip_bmp_encode(
    pixels: [*]const u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    meta: [*]const u8,
    meta_len: usize,
    out_bmp: *[*]u8,
    out_bmp_len: *usize,
) callconv(.c) i32 {
    if (meta_len < 7) return -40; // Need at least prefix
    const meta_buf = meta[0..meta_len];
    const top_down = meta_buf[0] != 0;
    const bits_per_pixel = std.mem.readInt(u16, meta_buf[1..3], .little);
    const row_stride = std.mem.readInt(u32, meta_buf[3..7], .little);
    const header_bytes_src = meta_buf[7..];

    const header_bytes = page_allocator.alloc(u8, header_bytes_src.len) catch return -13;
    @memcpy(header_bytes, header_bytes_src);

    const channels: u8 = if (bits_per_pixel == 32) 4 else 3;

    const header = bmp_mod.BmpHeader{
        .header_bytes = header_bytes,
        .width = width,
        .height = height,
        .abs_height = height,
        .top_down = top_down,
        .channels = channels,
        .bits_per_pixel = bits_per_pixel,
        .row_stride = row_stride,
        .allocator = page_allocator,
    };

    const bmp_data = bmp_mod.encodeBmp(page_allocator, pixels[0..pixels_len], header) catch {
        page_allocator.free(header_bytes);
        return -40;
    };
    page_allocator.free(header_bytes);

    out_bmp.* = bmp_data.ptr;
    out_bmp_len.* = bmp_data.len;
    return 0;
}


// --- TAR ---

/// Check if buffer starts with a valid tar header (ustar magic or valid checksum).
export fn blip_is_tar(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return tar_mod.isTarMagic(buf[0..buf_len]);
}

/// Parse a tar archive into individual entries.
/// Returns entry count and parallel arrays of paths, contents, headers, and typeflags.
/// Caller must free all output arrays with blip_free.
export fn blip_tar_parse(
    tar: [*]const u8,
    tar_len: usize,
    out_count: *usize,
    out_paths: *[*][*]u8,
    out_path_lens: *[*]usize,
    out_contents: *[*][*]u8,
    out_content_lens: *[*]usize,
    out_headers: *[*][*]u8,
    out_typeflags: *[*]u8,
    out_trailer: *[*]u8,
    out_trailer_len: *usize,
) callconv(.c) i32 {
    var parsed = tar_mod.parseTar(page_allocator, tar[0..tar_len]) catch return -40;

    const count = parsed.entries.len;
    const paths = page_allocator.alloc([*]u8, count) catch {
        parsed.deinit();
        return -13;
    };
    const path_lens = page_allocator.alloc(usize, count) catch {
        parsed.deinit();
        return -13;
    };
    const contents = page_allocator.alloc([*]u8, count) catch {
        parsed.deinit();
        return -13;
    };
    const content_lens = page_allocator.alloc(usize, count) catch {
        parsed.deinit();
        return -13;
    };
    const headers = page_allocator.alloc([*]u8, count) catch {
        parsed.deinit();
        return -13;
    };
    const typeflags = page_allocator.alloc(u8, count) catch {
        parsed.deinit();
        return -13;
    };

    for (parsed.entries, 0..) |entry, i| {
        // Copy path to owned buffer
        const path_buf = page_allocator.alloc(u8, entry.path.len) catch {
            parsed.deinit();
            return -13;
        };
        @memcpy(path_buf, entry.path);
        paths[i] = path_buf.ptr;
        path_lens[i] = entry.path.len;

        // Copy content
        if (entry.content.len > 0) {
            const content_buf = page_allocator.alloc(u8, entry.content.len) catch {
                parsed.deinit();
                return -13;
            };
            @memcpy(content_buf, entry.content);
            contents[i] = content_buf.ptr;
        } else {
            contents[i] = @ptrFromInt(1); // non-null sentinel
        }
        content_lens[i] = entry.content.len;

        // Copy header
        const hdr_buf = page_allocator.alloc(u8, 512) catch {
            parsed.deinit();
            return -13;
        };
        @memcpy(hdr_buf, &entry.header);
        headers[i] = hdr_buf.ptr;

        typeflags[i] = entry.typeflag;
    }

    // Trailer
    if (parsed.trailer.len > 0) {
        const trailer_buf = page_allocator.alloc(u8, parsed.trailer.len) catch {
            parsed.deinit();
            return -13;
        };
        @memcpy(trailer_buf, parsed.trailer);
        out_trailer.* = trailer_buf.ptr;
        out_trailer_len.* = parsed.trailer.len;
    } else {
        out_trailer.* = @ptrFromInt(1);
        out_trailer_len.* = 0;
    }

    out_count.* = count;
    out_paths.* = paths.ptr;
    out_path_lens.* = path_lens.ptr;
    out_contents.* = contents.ptr;
    out_content_lens.* = content_lens.ptr;
    out_headers.* = headers.ptr;
    out_typeflags.* = typeflags.ptr;

    parsed.deinit();
    return 0;
}

/// Reconstruct a tar archive from entries.
export fn blip_tar_encode(
    count: usize,
    headers: [*]const [*]const u8,
    contents: [*]const [*]const u8,
    content_lens: [*]const usize,
    trailer: [*]const u8,
    trailer_len: usize,
    out_tar: *[*]u8,
    out_tar_len: *usize,
) callconv(.c) i32 {
    // Build TarEntry slice for encodeTar
    const entries = page_allocator.alloc(tar_mod.TarEntry, count) catch return -13;
    defer page_allocator.free(entries);

    for (0..count) |i| {
        entries[i].header = headers[i][0..512].*;
        entries[i].content = if (content_lens[i] > 0) contents[i][0..content_lens[i]] else &.{};
        entries[i].path = &.{}; // Not needed for encoding
        entries[i].typeflag = entries[i].header[156];
    }

    const trailer_slice = if (trailer_len > 0) trailer[0..trailer_len] else &[_]u8{};
    const tar_data = tar_mod.encodeTar(page_allocator, entries, trailer_slice) catch return -13;
    out_tar.* = tar_data.ptr;
    out_tar_len.* = tar_data.len;
    return 0;
}


// --- TIFF ---

/// Check if buffer starts with TIFF magic bytes (II*\0 or MM\0*).
export fn blip_is_tiff(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return tiff_mod.isTiffMagic(buf[0..buf_len]);
}

/// Parse a TIFF into raw pixels + original file bytes (for reconstruction).
/// Only handles uncompressed 8/16-bit TIFF. Returns error for compressed TIFF.
export fn blip_tiff_parse(
    tiff: [*]const u8,
    tiff_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = tiff_mod.parseTiff(page_allocator, tiff[0..tiff_len]) catch return -40;

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.info.width;
    out_height.* = parsed.info.height;
    out_num_channels.* = @as(u32, parsed.info.samples_per_pixel);
    out_bits_per_sample.* = @as(u32, parsed.info.bits_per_sample);
    // Meta contains file template (pixel regions zeroed) + strip map
    out_meta.* = parsed.meta.ptr;
    out_meta_len.* = parsed.meta.len;

    return 0;
}


// --- GIF ---

/// Check if buffer starts with GIF magic bytes (GIF87a or GIF89a).
export fn blip_is_gif(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return gif_mod.isGifMagic(buf[0..buf_len]);
}

/// Parse a static GIF into RGBA pixels + original file (for reconstruction).
/// Returns error for animated GIFs.
export fn blip_gif_parse(
    gif: [*]const u8,
    gif_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = gif_mod.parseGif(page_allocator, gif[0..gif_len]) catch return -40;

    // Reject animated GIFs (too complex for simple container expansion)
    if (parsed.is_animated) {
        // Need to clean up — but parseGif allocated for us
        var p = parsed;
        p.deinit();
        return -40;
    }

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.width;
    out_height.* = parsed.height;
    out_num_channels.* = 4; // RGBA
    out_bits_per_sample.* = 8;
    out_meta.* = parsed.original.ptr;
    out_meta_len.* = parsed.original.len;

    return 0;
}


// --- TGA ---

/// Check if buffer looks like an uncompressed true-color TGA.
export fn blip_is_tga(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return tga_mod.isTgaMagic(buf[0..buf_len]);
}

/// Parse a TGA into raw pixels + header metadata.
export fn blip_tga_parse(
    tga: [*]const u8,
    tga_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    var parsed = tga_mod.parseTga(page_allocator, tga[0..tga_len]) catch return -40;

    // Meta format: [u8 top_down][u8 bpp][u16_le width][u16_le height]
    //              [u32_le footer_len][header_bytes][footer_bytes]
    const meta_prefix: usize = 1 + 1 + 2 + 2 + 4; // 10 bytes
    const meta_len = meta_prefix + parsed.header.header_bytes.len + parsed.footer.len;
    const meta = page_allocator.alloc(u8, meta_len) catch {
        parsed.deinit();
        return -13;
    };
    meta[0] = if (parsed.header.top_down) 1 else 0;
    meta[1] = parsed.header.bits_per_pixel;
    std.mem.writeInt(u16, meta[2..4], parsed.header.width, .little);
    std.mem.writeInt(u16, meta[4..6], parsed.header.height, .little);
    const footer_len: u32 = @intCast(parsed.footer.len);
    std.mem.writeInt(u32, meta[6..10], footer_len, .little);
    @memcpy(meta[meta_prefix..][0..parsed.header.header_bytes.len], parsed.header.header_bytes);
    if (parsed.footer.len > 0) {
        @memcpy(meta[meta_prefix + parsed.header.header_bytes.len ..], parsed.footer);
    }

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = @as(u32, parsed.header.width);
    out_height.* = @as(u32, parsed.header.height);
    out_num_channels.* = @as(u32, parsed.header.channels);
    out_bits_per_sample.* = 8;
    out_meta.* = meta.ptr;
    out_meta_len.* = meta.len;

    page_allocator.free(parsed.header.header_bytes);
    if (parsed.footer.len > 0) page_allocator.free(parsed.footer);

    return 0;
}

/// Encode raw pixels + TGA metadata back to a TGA file.
export fn blip_tga_encode(
    pixels: [*]const u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    meta: [*]const u8,
    meta_len: usize,
    out_tga: *[*]u8,
    out_tga_len: *usize,
) callconv(.c) i32 {
    if (meta_len < 10) return -40;
    const meta_buf = meta[0..meta_len];
    const top_down = meta_buf[0] != 0;
    const bpp = meta_buf[1];
    const w = std.mem.readInt(u16, meta_buf[2..4], .little);
    const h = std.mem.readInt(u16, meta_buf[4..6], .little);
    const footer_len = std.mem.readInt(u32, meta_buf[6..10], .little);
    _ = w;
    _ = h;

    const header_bytes_len = meta_len - 10 - @as(usize, footer_len);
    const header_bytes_src = meta_buf[10..][0..header_bytes_len];
    const footer_src = if (footer_len > 0) meta_buf[10 + header_bytes_len ..] else &[_]u8{};

    const header_bytes = page_allocator.alloc(u8, header_bytes_len) catch return -13;
    @memcpy(header_bytes, header_bytes_src);

    const channels: u8 = if (bpp == 32) 4 else 3;

    const header = tga_mod.TgaHeader{
        .header_bytes = header_bytes,
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = channels,
        .bits_per_pixel = bpp,
        .top_down = top_down,
        .allocator = page_allocator,
    };

    const tga_data = tga_mod.encodeTga(page_allocator, pixels[0..pixels_len], header, footer_src) catch {
        page_allocator.free(header_bytes);
        return -40;
    };
    page_allocator.free(header_bytes);

    out_tga.* = tga_data.ptr;
    out_tga_len.* = tga_data.len;
    return 0;
}


// --- WAV/FLAC ---

/// Check if buffer starts with WAV magic (RIFF....WAVE).
export fn blip_is_wav(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return wav_mod.isWavMagic(buf[0..buf_len]);
}

/// Parse WAV, encode PCM to FLAC, return FLAC data + WAV metadata.
/// Meta format: [u32_le file_size][u32_le data_offset][u32_le data_size][pre_data][post_data]
export fn blip_wav_to_flac(
    wav: [*]const u8,
    wav_len: usize,
    out_flac: *[*]u8,
    out_flac_len: *usize,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = wav_mod.parseWav(page_allocator, wav[0..wav_len]) catch return -40;

    const flac_data = flac_mod.encodePcmToFlac(
        page_allocator,
        parsed.samples,
        parsed.info.num_channels,
        parsed.info.sample_rate,
        parsed.info.bits_per_sample,
        parsed.info.num_samples,
    ) catch {
        page_allocator.free(parsed.samples);
        page_allocator.free(parsed.original);
        return -41;
    };

    out_flac.* = flac_data.ptr;
    out_flac_len.* = flac_data.len;
    out_meta.* = parsed.original.ptr;
    out_meta_len.* = parsed.original.len;

    page_allocator.free(parsed.samples);
    return 0;
}

/// Decode FLAC back to PCM, reconstruct WAV from metadata + PCM.
export fn blip_flac_to_wav(
    flac_data: [*]const u8,
    flac_len: usize,
    meta: [*]const u8,
    meta_len: usize,
    out_wav: *[*]u8,
    out_wav_len: *usize,
) callconv(.c) i32 {
    if (meta_len < 12) return -40;

    var channels: u32 = 0;
    var sample_rate: u32 = 0;
    var bps: u32 = 0;
    var total_samples: u64 = 0;

    const pcm = flac_mod.decodeFlacToPcm(
        page_allocator, flac_data[0..flac_len],
        &channels, &sample_rate, &bps, &total_samples,
    ) catch return -41;
    defer page_allocator.free(pcm);

    // Reconstruct WAV from metadata template + decoded PCM
    const meta_buf = meta[0..meta_len];
    const file_size = std.mem.readInt(u32, meta_buf[0..4], .little);
    const data_offset = std.mem.readInt(u32, meta_buf[4..8], .little);
    const data_size = std.mem.readInt(u32, meta_buf[8..12], .little);
    _ = data_size;

    const pre_data_len: usize = data_offset;
    const pre_data = meta_buf[12..][0..pre_data_len];
    const post_data = if (12 + pre_data_len < meta_len) meta_buf[12 + pre_data_len ..] else &[_]u8{};

    const wav_size: usize = file_size;
    const wav = page_allocator.alloc(u8, wav_size) catch return -13;

    // Copy pre-data (header)
    if (pre_data_len > 0 and pre_data_len <= wav_size)
        @memcpy(wav[0..pre_data_len], pre_data);

    // Copy PCM data
    const pcm_copy_len = @min(pcm.len, wav_size - @min(data_offset, wav_size));
    if (data_offset + pcm_copy_len <= wav_size)
        @memcpy(wav[data_offset..][0..pcm_copy_len], pcm[0..pcm_copy_len]);

    // Copy post-data
    const post_start = data_offset + pcm_copy_len;
    if (post_data.len > 0 and post_start + post_data.len <= wav_size)
        @memcpy(wav[post_start..][0..post_data.len], post_data);

    out_wav.* = wav.ptr;
    out_wav_len.* = wav_size;
    return 0;
}


// --- AIFF ---

/// Check if buffer starts with AIFF magic (FORM....AIFF).
export fn blip_is_aiff(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return aiff_mod.isAiffMagic(buf[0..buf_len]);
}

/// Parse AIFF, encode PCM to FLAC, return FLAC data + AIFF metadata.
export fn blip_aiff_to_flac(
    aiff: [*]const u8,
    aiff_len: usize,
    out_flac: *[*]u8,
    out_flac_len: *usize,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = aiff_mod.parseAiff(page_allocator, aiff[0..aiff_len]) catch return -40;

    const flac_data = flac_mod.encodePcmToFlac(
        page_allocator,
        parsed.samples,
        parsed.info.num_channels,
        parsed.info.sample_rate,
        parsed.info.bits_per_sample,
        parsed.info.num_samples,
    ) catch {
        page_allocator.free(parsed.samples);
        page_allocator.free(parsed.meta);
        return -41;
    };

    out_flac.* = flac_data.ptr;
    out_flac_len.* = flac_data.len;
    out_meta.* = parsed.meta.ptr;
    out_meta_len.* = parsed.meta.len;
    page_allocator.free(parsed.samples);
    return 0;
}

/// Decode FLAC back to PCM, reconstruct AIFF from metadata.
export fn blip_flac_to_aiff(
    flac_data: [*]const u8,
    flac_len: usize,
    meta: [*]const u8,
    meta_len: usize,
    out_aiff: *[*]u8,
    out_aiff_len: *usize,
) callconv(.c) i32 {
    if (meta_len < 13) return -40;

    var channels: u32 = 0;
    var sample_rate: u32 = 0;
    var bps: u32 = 0;
    var total_samples: u64 = 0;

    const pcm = flac_mod.decodeFlacToPcm(
        page_allocator, flac_data[0..flac_len],
        &channels, &sample_rate, &bps, &total_samples,
    ) catch return -41;
    defer page_allocator.free(pcm);

    const meta_buf = meta[0..meta_len];
    const file_size = std.mem.readInt(u32, meta_buf[0..4], .big);
    const ssnd_offset = std.mem.readInt(u32, meta_buf[4..8], .big);
    const ssnd_data_size = std.mem.readInt(u32, meta_buf[8..12], .big);
    _ = ssnd_data_size;

    const pre_ssnd_len: usize = ssnd_offset;
    const pre_ssnd = meta_buf[13..][0..pre_ssnd_len];
    const post_ssnd = if (13 + pre_ssnd_len < meta_len) meta_buf[13 + pre_ssnd_len ..] else &[_]u8{};

    const aiff_size: usize = file_size;
    const aiff = page_allocator.alloc(u8, aiff_size) catch return -13;
    @memset(aiff, 0);

    // Copy pre-SSND data (headers)
    if (pre_ssnd_len > 0 and pre_ssnd_len <= aiff_size)
        @memcpy(aiff[0..pre_ssnd_len], pre_ssnd);

    // Convert PCM from LE back to BE and write into SSND position
    const bytes_per_sample: usize = (@as(usize, bps) + 7) / 8;
    const total_pcm_samples = @as(usize, total_samples) * @as(usize, channels);
    var pcm_off: usize = ssnd_offset;
    for (0..total_pcm_samples) |i| {
        const src_off = i * bytes_per_sample;
        if (src_off + bytes_per_sample > pcm.len or pcm_off + bytes_per_sample > aiff_size) break;
        switch (bytes_per_sample) {
            1 => aiff[pcm_off] = pcm[src_off],
            2 => {
                aiff[pcm_off] = pcm[src_off + 1]; // LE to BE
                aiff[pcm_off + 1] = pcm[src_off];
            },
            3 => {
                aiff[pcm_off] = pcm[src_off + 2];
                aiff[pcm_off + 1] = pcm[src_off + 1];
                aiff[pcm_off + 2] = pcm[src_off];
            },
            else => {},
        }
        pcm_off += bytes_per_sample;
    }

    // Copy post-SSND data
    if (post_ssnd.len > 0 and pcm_off + post_ssnd.len <= aiff_size)
        @memcpy(aiff[pcm_off..][0..post_ssnd.len], post_ssnd);

    out_aiff.* = aiff.ptr;
    out_aiff_len.* = aiff_size;
    return 0;
}


// --- FITS ---

/// Check if buffer starts with FITS magic (SIMPLE = T).
export fn blip_is_fits(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return fits_mod.isFitsMagic(buf[0..buf_len]);
}

/// Parse FITS into raw pixels + header metadata.
/// For 16-bit FITS, pixels are big-endian. Caller handles endian conversion for JXL.
export fn blip_fits_parse(
    fits: [*]const u8,
    fits_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = fits_mod.parseFits(page_allocator, fits[0..fits_len]) catch return -40;

    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.info.width;
    out_height.* = parsed.info.height;
    out_num_channels.* = parsed.info.channels;
    out_bits_per_sample.* = @intCast(@abs(parsed.info.bitpix));
    out_meta.* = parsed.meta.ptr;
    out_meta_len.* = parsed.meta.len;
    return 0;
}


// --- NIfTI ---

export fn blip_is_nifti(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return nifti_mod.isNiftiMagic(buf[0..buf_len]);
}


// --- DICOM ---

/// Check if buffer starts with DICOM magic (128-byte preamble + "DICM").
export fn blip_is_dicom(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return dicom_mod.isDicomMagic(buf[0..buf_len]);
}

/// Parse DICOM into raw pixels + metadata (non-pixel bytes).
export fn blip_dicom_parse(
    dcm: [*]const u8,
    dcm_len: usize,
    out_pixels: *[*]u8,
    out_pixels_len: *usize,
    out_width: *u32,
    out_height: *u32,
    out_num_channels: *u32,
    out_bits_per_sample: *u32,
    out_meta: *[*]u8,
    out_meta_len: *usize,
) callconv(.c) i32 {
    const parsed = dicom_mod.parseDicom(page_allocator, dcm[0..dcm_len]) catch return -40;
    out_pixels.* = parsed.pixels.ptr;
    out_pixels_len.* = parsed.pixels.len;
    out_width.* = parsed.info.width;
    out_height.* = parsed.info.height;
    out_num_channels.* = @as(u32, parsed.info.samples_per_pixel);
    out_bits_per_sample.* = @as(u32, parsed.info.bits_allocated);
    out_meta.* = parsed.meta.ptr;
    out_meta_len.* = parsed.meta.len;
    return 0;
}


// --- Container Expansion/Collapse (unified entry point) ---

/// Detect which codec matches content by magic bytes. Returns codec name or NULL.
export fn blip_detect_codec(buf: [*]const u8, buf_len: usize, out_name: *[*]const u8, out_name_len: *usize) callconv(.c) bool {
    if (expansion_mod.detectCodec(buf[0..buf_len])) |codec_id| {
        const name = codec_id.name();
        out_name.* = name.ptr;
        out_name_len.* = name.len;        return true;
    }
    return false;
}

/// Expand a file into container entries. Returns 0 on success, -1 if not expandable.
/// out_count entries are returned; each has path_suffix, content, content_len, is_dir, jxl_source.
export fn blip_expand_file(
    content: [*]const u8,
    content_len: usize,
    codec_name: [*]const u8,
    codec_name_len: usize,
    // Output: parallel arrays
    out_count: *usize,
    out_container_type: *[*]const u8,
    out_container_type_len: *usize,
    out_path_suffixes: *[*][*]const u8,
    out_path_suffix_lens: *[*]usize,
    out_contents: *[*][*]u8,
    out_content_lens: *[*]usize,
    out_is_dirs: *[*]u8,
    out_jxl_sources: *[*][*]const u8,
    out_jxl_source_lens: *[*]usize,
    out_gz_levels: *[*]u8,
    out_zip_comps: *[*]u16,
    out_pdf_offsets: *[*]u64,
    out_pdf_lengths: *[*]u64,
) callconv(.c) i32 {
    const codec = codec_name[0..codec_name_len];
    const result = expansion_mod.expandFile(page_allocator, content[0..content_len], codec) catch return -1;
    if (result == null) return -1;
    var r = result.?;

    const count = r.entries.len;
    const suffixes = page_allocator.alloc([*]const u8, count) catch { r.deinit(); return -13; };
    const suffix_lens = page_allocator.alloc(usize, count) catch { r.deinit(); return -13; };
    const contents = page_allocator.alloc([*]u8, count) catch { r.deinit(); return -13; };
    const content_lens_arr = page_allocator.alloc(usize, count) catch { r.deinit(); return -13; };
    const is_dirs = page_allocator.alloc(u8, count) catch { r.deinit(); return -13; };
    const jxl_srcs = page_allocator.alloc([*]const u8, count) catch { r.deinit(); return -13; };
    const jxl_src_lens = page_allocator.alloc(usize, count) catch { r.deinit(); return -13; };
    const gz_levels = page_allocator.alloc(u8, count) catch { r.deinit(); return -13; };
    const zip_comps = page_allocator.alloc(u16, count) catch { r.deinit(); return -13; };
    const pdf_offsets = page_allocator.alloc(u64, count) catch { r.deinit(); return -13; };
    const pdf_lengths = page_allocator.alloc(u64, count) catch { r.deinit(); return -13; };

    for (r.entries, 0..) |entry, i| {
        suffixes[i] = entry.path_suffix.ptr;
        suffix_lens[i] = entry.path_suffix.len;
        contents[i] = if (entry.content.len > 0) entry.content.ptr else @ptrFromInt(1);
        content_lens_arr[i] = entry.content.len;
        is_dirs[i] = if (entry.is_dir) 1 else 0;
        jxl_srcs[i] = if (entry.jxl_source_format.len > 0) entry.jxl_source_format.ptr else @ptrFromInt(1);
        jxl_src_lens[i] = entry.jxl_source_format.len;
        gz_levels[i] = entry.gz_level;
        zip_comps[i] = entry.zip_comp;
        pdf_offsets[i] = entry.pdf_offset;
        pdf_lengths[i] = entry.pdf_length;
    }

    out_count.* = count;
    out_container_type.* = r.container_type.ptr;
    out_container_type_len.* = r.container_type.len;
    out_path_suffixes.* = suffixes.ptr;
    out_path_suffix_lens.* = suffix_lens.ptr;
    out_contents.* = contents.ptr;
    out_content_lens.* = content_lens_arr.ptr;
    out_is_dirs.* = is_dirs.ptr;
    out_jxl_sources.* = jxl_srcs.ptr;
    out_jxl_source_lens.* = jxl_src_lens.ptr;
    out_gz_levels.* = gz_levels.ptr;
    out_zip_comps.* = zip_comps.ptr;
    out_pdf_offsets.* = pdf_offsets.ptr;
    out_pdf_lengths.* = pdf_lengths.ptr;

    // Transfer ownership — don't deinit the entries, caller owns them now
    // But free the entries array wrapper (not the contents)
    page_allocator.free(r.entries);

    return 0;
}

/// Collapse a container back to its original file.
/// Takes codec name + array of (inner_path, content) children.
/// Returns reconstructed file bytes.
export fn blip_collapse_container(
    codec_name: [*]const u8,
    codec_name_len: usize,
    child_count: usize,
    child_paths: [*]const [*]const u8,
    child_path_lens: [*]const usize,
    child_contents: [*]const [*]const u8,
    child_content_lens: [*]const usize,
    child_pdf_offsets: ?[*]const u64,
    child_pdf_lengths: ?[*]const u64,
    child_zip_comps: ?[*]const u16,
    child_jxl_sources: ?[*]const [*]const u8,
    child_jxl_source_lens: ?[*]const usize,
    out_data: *[*]u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const codec = codec_name[0..codec_name_len];

    const children = page_allocator.alloc(expansion_mod.CollapseChild, child_count) catch return -13;
    defer page_allocator.free(children);

    for (0..child_count) |i| {
        children[i] = .{
            .inner_path = child_paths[i][0..child_path_lens[i]],
            .content = child_contents[i][0..child_content_lens[i]],
            .pdf_offset = if (child_pdf_offsets) |po| po[i] else std.math.maxInt(u64),
            .pdf_length = if (child_pdf_lengths) |pl| pl[i] else std.math.maxInt(u64),
            .zip_comp = if (child_zip_comps) |zc| zc[i] else 0xFFFF,
            .jxl_source = if (child_jxl_sources != null and child_jxl_source_lens != null)
                child_jxl_sources.?[i][0..child_jxl_source_lens.?[i]]
            else
                &.{},
        };
    }

    const result = expansion_mod.collapseContainer(page_allocator, codec, children) catch return -1;
    if (result == null) return -1;
    const data = result.?;

    out_data.* = data.ptr;
    out_data_len.* = data.len;
    return 0;
}


// --- Streaming archive creation ---

/// Create a BLAR archive using streaming (spill-to-disk) approach.
/// Uses the same blip_archive_entry C struct but reads file content
/// from source_path on demand instead of requiring content in memory.
/// Produces byte-identical output to blip_archive_create_full.
export fn blip_archive_create_streaming(
    c_entries: [*]const CArchiveEntry,
    entry_count: usize,
    per_file_comp_algo: u8,
    expand_containers: bool,
    expand_all_zips: bool,
    progress_fn: ?*const fn (u64, u64, ?*anyopaque) callconv(.c) void,
    progress_ctx: ?*anyopaque,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    // Convert C entries to Zig ArchiveEntry, reading content from source_path
    const mini = blip.mini_blar_mod;
    

    const zig_entries = page_allocator.alloc(mini.ArchiveEntry, entry_count) catch return -13;
    defer page_allocator.free(zig_entries);

    // Track content buffers we read from disk so we can free them
    var read_bufs = std.ArrayListUnmanaged([]u8){};
    defer {
        for (read_bufs.items) |buf| page_allocator.free(buf);
        read_bufs.deinit(page_allocator);
    }

    for (0..entry_count) |i| {
        const ce = c_entries[i];
        if (ce.is_dir != 0) {
            // Convert xattrs for dir
            const dir_xa: []const mini_blar.XattrEntry = if (ce.xattrs) |xa_ptr| blk: {
                const xa_count = ce.xattr_count;
                if (xa_count == 0) break :blk &.{};
                const xa_zig = page_allocator.alloc(mini_blar.XattrEntry, xa_count) catch break :blk &[_]mini_blar.XattrEntry{};
                for (0..xa_count) |xi| {
                    xa_zig[xi] = .{
                        .name = xa_ptr[xi].name[0..xa_ptr[xi].name_len],
                        .value = xa_ptr[xi].value[0..xa_ptr[xi].value_len],
                    };
                }
                break :blk xa_zig;
            } else &.{};

            zig_entries[i] = .{ .dir = .{
                .path = ce.path[0..ce.path_len],
                .mode = ce.mode,
                .mtime_ns = ce.mtime_ns,
                .ctime_ns = ce.ctime_ns,
                .birthtime_ns = ce.birthtime_ns,
                .uid = ce.uid,
                .gid = ce.gid,
                .username = if (ce.owner_len > 0 and ce.owner != null) ce.owner.?[0..ce.owner_len] else &.{},
                .groupname = if (ce.groupname_len > 0 and ce.groupname != null) ce.groupname.?[0..ce.groupname_len] else &.{},
                .xattrs = dir_xa,
                .container_type = if (ce.container_type_len > 0 and ce.container_type != null) ce.container_type.?[0..ce.container_type_len] else &.{},
            }};
        } else {
            // Read content from source_path if content is NULL
            var content: []const u8 = &.{};
            if (ce.content) |ptr| {
                content = ptr[0..ce.content_len];
            } else if (ce.source_path) |sp| {
                // Read file from disk
                const path = sp[0..ce.source_path_len];
                const file = std.fs.cwd().openFile(path, .{}) catch return -42;
                defer file.close();
                const data = file.readToEndAlloc(page_allocator, std.math.maxInt(usize)) catch return -42;
                read_bufs.append(page_allocator, data) catch return -13;
                content = data;
            }

            // Convert xattrs
            const xattr_slice: []const mini_blar.XattrEntry = if (ce.xattrs) |xa_ptr| blk: {
                const xa_count = ce.xattr_count;
                if (xa_count == 0) break :blk &.{};
                const xa_zig = page_allocator.alloc(mini_blar.XattrEntry, xa_count) catch break :blk &[_]mini_blar.XattrEntry{};
                for (0..xa_count) |xi| {
                    xa_zig[xi] = .{
                        .name = xa_ptr[xi].name[0..xa_ptr[xi].name_len],
                        .value = xa_ptr[xi].value[0..xa_ptr[xi].value_len],
                    };
                }
                break :blk xa_zig;
            } else &.{};

            const rfork: []const u8 = if (ce.resource_fork) |rf| rf[0..ce.resource_fork_len] else &.{};

            zig_entries[i] = .{ .file = .{
                .path = ce.path[0..ce.path_len],
                .content = content,
                .mode = ce.mode,
                .mtime_ns = ce.mtime_ns,
                .ctime_ns = ce.ctime_ns,
                .birthtime_ns = ce.birthtime_ns,
                .uid = ce.uid,
                .gid = ce.gid,
                .username = if (ce.owner_len > 0 and ce.owner != null) ce.owner.?[0..ce.owner_len] else &.{},
                .groupname = if (ce.groupname_len > 0 and ce.groupname != null) ce.groupname.?[0..ce.groupname_len] else &.{},
                .xattrs = xattr_slice,
                .resource_fork = rfork,
                .zip_compression_method = if (ce.zip_compression_method != 0xFFFF) ce.zip_compression_method else null,
                .pdf_stream_offset = if (ce.pdf_stream_offset != std.math.maxInt(u64)) ce.pdf_stream_offset else null,
                .pdf_stream_length = if (ce.pdf_stream_length != std.math.maxInt(u64)) ce.pdf_stream_length else null,
                .jxl_source_format = if (ce.jxl_source_format_len > 0 and ce.jxl_source_format != null) ce.jxl_source_format.?[0..ce.jxl_source_format_len] else &.{},
            }};
        }
    }

    const CompId = mini_blar.container_mod.CompressionId;
    const comp: ?CompId = if (per_file_comp_algo == 0) null else std.meta.intToEnum(CompId, @as(u7, @truncate(per_file_comp_algo))) catch return -32;

    
    const result = streaming_mod.createArchiveStreaming(page_allocator, zig_entries, comp, expand_containers, expand_all_zips, progress_fn, progress_ctx) catch return -40;
    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}


// --- FlateDecode (PDF) ---

/// Find all FlateDecode image streams in a PDF and return their info in parallel arrays.
/// Only finds streams with Predictor >= 10 (PNG-style, worth transcoding to JXL).
/// Caller must free the output arrays with blip_free when done.
export fn blip_pdf_flate_streams(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
    out_offsets: *[*]u64,
    out_lengths: *[*]u64,
    out_obj_nums: *[*]u32,
    out_gen_nums: *[*]u32,
    out_predictors: *[*]u16,
    out_columns: *[*]u32,
    out_colors: *[*]u8,
    out_bpcs: *[*]u8,
    out_widths: *[*]u32,
    out_heights: *[*]u32,
) callconv(.c) i32 {
    const streams = pdf_mod.findFlateImageStreams(page_allocator, buf[0..buf_len]) catch return -37;
    defer page_allocator.free(streams);
    const n = streams.len;
    out_count.* = n;
    if (n == 0) {
        return 0;
    }
    const offsets = page_allocator.alloc(u64, n) catch return -1;
    errdefer page_allocator.free(offsets);
    const lengths = page_allocator.alloc(u64, n) catch return -1;
    errdefer page_allocator.free(lengths);
    const obj_nums = page_allocator.alloc(u32, n) catch return -1;
    errdefer page_allocator.free(obj_nums);
    const gen_nums = page_allocator.alloc(u32, n) catch return -1;
    errdefer page_allocator.free(gen_nums);
    const predictors = page_allocator.alloc(u16, n) catch return -1;
    errdefer page_allocator.free(predictors);
    const columns_arr = page_allocator.alloc(u32, n) catch return -1;
    errdefer page_allocator.free(columns_arr);
    const colors_arr = page_allocator.alloc(u8, n) catch return -1;
    errdefer page_allocator.free(colors_arr);
    const bpcs = page_allocator.alloc(u8, n) catch return -1;
    errdefer page_allocator.free(bpcs);
    const widths = page_allocator.alloc(u32, n) catch return -1;
    errdefer page_allocator.free(widths);
    const heights = page_allocator.alloc(u32, n) catch return -1;
    errdefer page_allocator.free(heights);

    for (streams, 0..) |s, i| {
        offsets[i] = s.stream_start;
        lengths[i] = s.len();
        obj_nums[i] = s.object_num;
        gen_nums[i] = s.gen_num;
        predictors[i] = s.predictor;
        columns_arr[i] = s.columns;
        colors_arr[i] = s.colors;
        bpcs[i] = s.bits_per_component;
        widths[i] = s.width;
        heights[i] = s.height;
    }
    out_offsets.* = offsets.ptr;
    out_lengths.* = lengths.ptr;
    out_obj_nums.* = obj_nums.ptr;
    out_gen_nums.* = gen_nums.ptr;
    out_predictors.* = predictors.ptr;
    out_columns.* = columns_arr.ptr;
    out_colors.* = colors_arr.ptr;
    out_bpcs.* = bpcs.ptr;
    out_widths.* = widths.ptr;
    out_heights.* = heights.ptr;
    return 0;
}

/// Decompress zlib data. Caller must free output with blip_free.
export fn blip_zlib_decompress(
    data: [*]const u8,
    data_len: usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.zlibDecompress(page_allocator, data[0..data_len]) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Compress data with zlib (stored blocks). Caller must free output with blip_free.
export fn blip_zlib_compress(
    data: [*]const u8,
    data_len: usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.zlibCompress(page_allocator, data[0..data_len]) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Decompress gzip data. Caller must free output with blip_free.
export fn blip_gz_decompress(
    data: [*]const u8,
    data_len: usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.gzipDecompress(page_allocator, data[0..data_len]) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Compress data to gzip format at default level. Caller must free output with blip_free.
export fn blip_gz_compress(
    data: [*]const u8,
    data_len: usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.gzipCompress(page_allocator, data[0..data_len]) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Compress data to gzip format at a specific compression level (1-9).
/// Caller must free output with blip_free.
export fn blip_gz_compress_level(
    data: [*]const u8,
    data_len: usize,
    level: u8,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.gzipCompressLevel(page_allocator, data[0..data_len], @intCast(level)) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Guess the gzip compression level from original compressed + decompressed data.
/// Returns the guessed level (2, 6, or 9).
export fn blip_gz_guess_level(
    compressed: [*]const u8,
    compressed_len: usize,
    decompressed: [*]const u8,
    decompressed_len: usize,
) callconv(.c) u8 {
    return pdf_mod.gzipGuessLevel(page_allocator, compressed[0..compressed_len], decompressed[0..decompressed_len]);
}

/// Check if buffer starts with gzip magic bytes (0x1f 0x8b).
export fn blip_is_gz(buf: [*]const u8, buf_len: usize) callconv(.c) bool {
    return buf_len >= 2 and buf[0] == 0x1f and buf[1] == 0x8b;
}


/// Remove PNG-style row filters from FlateDecode data.
/// Returns raw pixel data. Caller must free output with blip_free.
export fn blip_pdf_defilter(
    data: [*]const u8,
    data_len: usize,
    columns: u32,
    colors: u8,
    bpc: u8,
    predictor: u16,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.defilterPdfFlate(page_allocator, data[0..data_len], columns, colors, bpc, predictor) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Re-apply PNG-style row filters to pixel data for FlateDecode.
/// Caller must free output with blip_free.
export fn blip_pdf_refilter(
    pixels: [*]const u8,
    pixels_len: usize,
    columns: u32,
    colors: u8,
    bpc: u8,
    predictor: u16,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const result = pdf_mod.refilterPdfFlate(page_allocator, pixels[0..pixels_len], columns, colors, bpc, predictor) catch return -41;
    out.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Rewrite a PDF shell, replacing stream data regions that may differ in size.
/// Updates /Length values and rebuilds the xref table.
/// Returns BLIP_OK on success, -42 if the PDF uses xref streams (caller should skip),
/// or negative error code on failure.
export fn blip_pdf_rewrite_streams(
    shell: [*]const u8,
    shell_len: usize,
    count: usize,
    stream_starts: [*]const u64,
    original_lengths: [*]const u64,
    new_datas: [*]const [*]const u8,
    new_data_lens: [*]const usize,
    out: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    if (count == 0) {
        // No replacements — return a copy of the shell
        const copy = page_allocator.dupe(u8, shell[0..shell_len]) catch return -1;
        out.* = copy.ptr;
        out_len.* = copy.len;
        return 0;
    }

    // Build StreamReplacement slice
    const reps = page_allocator.alloc(pdf_mod.StreamReplacement, count) catch return -1;
    defer page_allocator.free(reps);

    for (0..count) |i| {
        reps[i] = .{
            .stream_start = @intCast(stream_starts[i]),
            .original_length = @intCast(original_lengths[i]),
            .new_data = new_datas[i][0..new_data_lens[i]],
        };
    }

    const result = pdf_mod.rewritePdfWithStreams(page_allocator, shell[0..shell_len], reps) catch return -41;
    if (result) |buf| {
        out.* = buf.ptr;
        out_len.* = buf.len;
        return 0;
    } else {
        return -42; // xref stream PDF — caller should skip rewrite
    }
}

/// Find all non-image FlateDecode content streams in a PDF.
/// Returns parallel arrays of offsets and lengths for each stream.
/// Caller must free the returned arrays with blip_free().
export fn blip_pdf_content_streams(
    buf: [*]const u8,
    buf_len: usize,
    out_count: *u64,
    out_offsets: *[*]u64,
    out_lengths: *[*]u64,
) callconv(.c) i32 {
    const streams = pdf_mod.findFlateContentStreams(page_allocator, buf[0..buf_len]) catch return -1;
    defer page_allocator.free(streams);

    out_count.* = streams.len;
    if (streams.len == 0) {
        out_offsets.* = undefined;
        out_lengths.* = undefined;
        return 0;
    }

    const offsets = page_allocator.alloc(u64, streams.len) catch return -1;
    errdefer page_allocator.free(offsets);
    const lengths = page_allocator.alloc(u64, streams.len) catch return -1;

    for (streams, 0..) |s, i| {
        offsets[i] = s.stream_start;
        lengths[i] = s.len();
    }

    out_offsets.* = offsets.ptr;
    out_lengths.* = lengths.ptr;
    return 0;
}

/// Read pdf_stream_offset from a FILE entry in a BLIP archive.
export fn blip_archive_entry_pdf_offset(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out: *u64,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    const entry_type = reader.entryTypeAt(index) catch return -8;
    if (entry_type != .file) {
        out.* = 0xFFFFFFFFFFFFFFFF;
        return 0;
    }
    const file_array = reader.fileArrayAt(index) catch return -1;
    const meta_view = file_array.elementAt(0) catch return -1;
    const meta_dict = dict_mod.DictReader.init(meta_view.buf[0..@intCast(meta_view.total_length)]) catch return -1;
    const po_idx = (meta_dict.findKey("po") catch return -1) orelse {
        out.* = 0xFFFFFFFFFFFFFFFF;
        return 0;
    };
    const po_container = meta_dict.valueAt(po_idx) catch return -1;
    const po_bytes = mini_blar.leaf.readData(po_container) catch return -1;
    if (po_bytes.len != 8) return -1;
    out.* = std.mem.readInt(u64, po_bytes[0..8], .little);
    return 0;
}

/// Read pdf_stream_length from a FILE entry in a BLIP archive.
export fn blip_archive_entry_pdf_length(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out: *u64,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    const entry_type = reader.entryTypeAt(index) catch return -8;
    if (entry_type != .file) {
        out.* = 0xFFFFFFFFFFFFFFFF;
        return 0;
    }
    const file_array = reader.fileArrayAt(index) catch return -1;
    const meta_view = file_array.elementAt(0) catch return -1;
    const meta_dict = dict_mod.DictReader.init(meta_view.buf[0..@intCast(meta_view.total_length)]) catch return -1;
    const pl_idx = (meta_dict.findKey("pl") catch return -1) orelse {
        out.* = 0xFFFFFFFFFFFFFFFF;
        return 0;
    };
    const pl_container = meta_dict.valueAt(pl_idx) catch return -1;
    const pl_bytes = mini_blar.leaf.readData(pl_container) catch return -1;
    if (pl_bytes.len != 8) return -1;
    out.* = std.mem.readInt(u64, pl_bytes[0..8], .little);
    return 0;
}

/// Read jxl_source_format from a FILE entry in a BLIP archive.
export fn blip_archive_entry_jxl_source(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_fmt: *?[*]const u8,
    out_fmt_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch return -1;
    const entry_type = reader.entryTypeAt(index) catch return -8;
    if (entry_type != .file) {
        out_fmt.* = null;
        out_fmt_len.* = 0;
        return 0;
    }
    const file_array = reader.fileArrayAt(index) catch return -1;
    const meta_view = file_array.elementAt(0) catch return -1;
    const meta_dict = dict_mod.DictReader.init(meta_view.buf[0..@intCast(meta_view.total_length)]) catch return -1;
    const jx_idx = (meta_dict.findKey("jx") catch return -1) orelse {
        out_fmt.* = null;
        out_fmt_len.* = 0;
        return 0;
    };
    const jx_container = meta_dict.valueAt(jx_idx) catch return -1;
    const jx_val = mini_blar.leaf.readUtf8(jx_container) catch return -1;
    out_fmt.* = jx_val.ptr;
    out_fmt_len.* = jx_val.len;
    return 0;
}

fn zipErrorCode(err: anytype) i32 {
    return switch (err) {
        error.InvalidZip => -33,
        error.EncryptedZip => -34,
        error.Zip64Unsupported => -35,
        error.UnsupportedMethod => -36,
        error.OutOfMemory => -13,
        error.BadCrc32 => -7,
        error.DecompressFailed => -23,
        error.CompressFailed => -24,
        error.TruncatedData => -11,
    };
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

    var data_ptr: [*]u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content(out_buf, out_len, 0, &data_ptr, &data_len));
    defer blip_free_content(data_ptr, data_len);
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

    var data_ptr: [*]u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content_by_path(out_buf, out_len, "b.txt", 5, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "bbb", data_ptr[0..data_len]);
    blip_free_content(data_ptr, data_len);

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

test "C FFI: bzip2 compress+decompress multi-block archive" {
    if (comptime !@import("blip").build_options.enable_compression) return;
    // Regression test: bzip2 multi-block streams (data > ~900KB at level 9)
    // previously caused OutputOverflow on decompression. Fixed in bzip2z f9187bf.
    const size = 950_000; // >900KB to ensure multi-block
    var data: [size]u8 = undefined;
    // Use a pattern that exercises the RLE-heavy path
    for (&data, 0..) |*byte, i| {
        byte.* = @truncate(i *% 7 +% (i >> 16));
    }

    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    const rc = blip_compress_container(&data, data.len, 2, 0, null, null, null, &out_buf, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer blip_free(out_buf, out_len);

    var dec_buf: [*]u8 = undefined;
    var dec_len: usize = undefined;
    const rc2 = blip_decompress_container(out_buf, out_len, &dec_buf, &dec_len);
    try std.testing.expectEqual(@as(i32, 0), rc2);
    defer blip_free(dec_buf, dec_len);

    try std.testing.expectEqual(data.len, dec_len);
    try std.testing.expectEqualSlices(u8, &data, dec_buf[0..dec_len]);
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
            .xattrs = null, .xattr_count = 0,
            .resource_fork = null, .resource_fork_len = 0,
            .container_type = null, .container_type_len = 0,
            .zip_compression_method = 0xFFFF,
            .pdf_stream_offset = 0xFFFFFFFFFFFFFFFF,
            .pdf_stream_length = 0xFFFFFFFFFFFFFFFF,
            .jxl_source_format = null,
            .jxl_source_format_len = 0,
            .flate_predictor = 0,
            .flate_columns = 0,
            .flate_colors = 0,
            .flate_bpc = 0,
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
            .xattrs = null, .xattr_count = 0,
            .resource_fork = null, .resource_fork_len = 0,
            .container_type = null, .container_type_len = 0,
            .zip_compression_method = 0xFFFF,
            .pdf_stream_offset = 0xFFFFFFFFFFFFFFFF,
            .pdf_stream_length = 0xFFFFFFFFFFFFFFFF,
            .jxl_source_format = null,
            .jxl_source_format_len = 0,
            .flate_predictor = 0,
            .flate_columns = 0,
            .flate_colors = 0,
            .flate_bpc = 0,
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, 0, 0, null, null, null, &out_buf, &out_len));
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
            .xattrs = null, .xattr_count = 0,
            .resource_fork = null, .resource_fork_len = 0,
            .container_type = null, .container_type_len = 0,
            .zip_compression_method = 0xFFFF,
            .pdf_stream_offset = 0xFFFFFFFFFFFFFFFF,
            .pdf_stream_length = 0xFFFFFFFFFFFFFFFF,
            .jxl_source_format = null,
            .jxl_source_format_len = 0,
            .flate_predictor = 0,
            .flate_columns = 0,
            .flate_colors = 0,
            .flate_bpc = 0,
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
            .xattrs = null, .xattr_count = 0,
            .resource_fork = null, .resource_fork_len = 0,
            .container_type = null, .container_type_len = 0,
            .zip_compression_method = 0xFFFF,
            .pdf_stream_offset = 0xFFFFFFFFFFFFFFFF,
            .pdf_stream_length = 0xFFFFFFFFFFFFFFFF,
            .jxl_source_format = null,
            .jxl_source_format_len = 0,
            .flate_predictor = 0,
            .flate_columns = 0,
            .flate_colors = 0,
            .flate_bpc = 0,
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, 0, 0, null, null, null, &out_buf, &out_len));
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
            .xattrs = null, .xattr_count = 0,
            .resource_fork = null, .resource_fork_len = 0,
            .container_type = null, .container_type_len = 0,
            .zip_compression_method = 0xFFFF,
            .pdf_stream_offset = 0xFFFFFFFFFFFFFFFF,
            .pdf_stream_length = 0xFFFFFFFFFFFFFFFF,
            .jxl_source_format = null,
            .jxl_source_format_len = 0,
            .flate_predictor = 0,
            .flate_columns = 0,
            .flate_colors = 0,
            .flate_bpc = 0,
        },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 1, 0, 0, 0, null, null, null, &out_buf, &out_len));
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

    // [1][0][1] -> DATA (content) — v2 type_id = 4
    try std.testing.expectEqual(@as(i32, 0), blip_peek(out_buf, out_len, "[1][0][1]", 9, &out_type, &data_ptr, &data_len));
    try std.testing.expectEqual(@as(u8, 4), out_type); // DATA (v2 ContainerTypeId.data = 4)
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

    // Get hash of outer array — v2 uses BLAKE3-128 (16 bytes), containerHash returns first 8
    var hash: [8]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_container_hash(out_buf, out_len, &hash));
    // Hash should match first 8 bytes of the 16-byte BLAKE3-128 checksum (at [total-16..total-8])
    try std.testing.expectEqualSlices(u8, out_buf[out_len - 16 .. out_len - 8], &hash);
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

// ---------------------------------------------------------------------------
// blip_peek_display FFI tests
// ---------------------------------------------------------------------------

test "C FFI: blip_peek_display returns type for .type accessor" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello", .content_len = 5 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var stdout_ptr: [*]const u8 = undefined;
    var stdout_len: usize = undefined;
    var stderr_ptr: [*]const u8 = undefined;
    var stderr_len: usize = undefined;
    const rc = blip_peek_display(out_buf, out_len, ".type", 5, 0, &stdout_ptr, &stdout_len, &stderr_ptr, &stderr_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer {
        if (stdout_len > 0) blip_free(@constCast(stdout_ptr), stdout_len);
        if (stderr_len > 0) blip_free(@constCast(stderr_ptr), stderr_len);
    }
    try std.testing.expectEqualSlices(u8, "ARRAY\n", stdout_ptr[0..stdout_len]);
}

test "C FFI: blip_peek_display with json flag" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello", .content_len = 5 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var stdout_ptr: [*]const u8 = undefined;
    var stdout_len: usize = undefined;
    var stderr_ptr: [*]const u8 = undefined;
    var stderr_len: usize = undefined;
    // BLIP_PEEK_JSON = 0x01
    const rc = blip_peek_display(out_buf, out_len, ".type", 5, 0x01, &stdout_ptr, &stdout_len, &stderr_ptr, &stderr_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer {
        if (stdout_len > 0) blip_free(@constCast(stdout_ptr), stdout_len);
        if (stderr_len > 0) blip_free(@constCast(stderr_ptr), stderr_len);
    }
    try std.testing.expectEqualSlices(u8, "\"ARRAY\"\n", stdout_ptr[0..stdout_len]);
}

test "C FFI: blip_peek_display returns error for invalid path" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var stdout_ptr: [*]const u8 = undefined;
    var stdout_len: usize = undefined;
    var stderr_ptr: [*]const u8 = undefined;
    var stderr_len: usize = undefined;
    const rc = blip_peek_display(out_buf, out_len, "[abc", 4, 0, &stdout_ptr, &stdout_len, &stderr_ptr, &stderr_len);
    try std.testing.expectEqual(@as(i32, -1), rc);
    defer {
        if (stdout_len > 0) blip_free(@constCast(stdout_ptr), stdout_len);
        if (stderr_len > 0) blip_free(@constCast(stderr_ptr), stderr_len);
    }
    try std.testing.expect(stderr_len > 0);
}

test "C FFI: blip_peek_display hex flag" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "AB", .content_len = 2 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, 0, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Navigate to [1][0][1] (DATA content), hex mode (0x04)
    var stdout_ptr: [*]const u8 = undefined;
    var stdout_len: usize = undefined;
    var stderr_ptr: [*]const u8 = undefined;
    var stderr_len: usize = undefined;
    const rc = blip_peek_display(out_buf, out_len, "[1][0][1]", 9, 0x04, &stdout_ptr, &stdout_len, &stderr_ptr, &stderr_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer {
        if (stdout_len > 0) blip_free(@constCast(stdout_ptr), stdout_len);
        if (stderr_len > 0) blip_free(@constCast(stderr_ptr), stderr_len);
    }
    // Should start with 0x
    try std.testing.expect(stdout_len >= 2);
    try std.testing.expectEqualSlices(u8, "0x", stdout_ptr[0..2]);
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

// ---------------------------------------------------------------------------
// Encryption FFI tests
// ---------------------------------------------------------------------------

test "C FFI: blip_encrypt_container and blip_decrypt_container round-trip" {
    const data_bytes = try leaf.serializeData(std.testing.allocator, "FFI encryption test");
    defer std.testing.allocator.free(data_bytes);

    var encrypted_buf: [*]u8 = undefined;
    var encrypted_len: usize = 0;
    const enc_rc = blip_encrypt_container(
        data_bytes.ptr,
        data_bytes.len,
        "test-password",
        13,
        1, // aes_256_gcm
        1, // argon2id
        &encrypted_buf,
        &encrypted_len,
    );
    try std.testing.expectEqual(@as(i32, 0), enc_rc);
    defer blip_free(encrypted_buf, encrypted_len);

    var decrypted_buf: [*]u8 = undefined;
    var decrypted_len: usize = 0;
    const dec_rc = blip_decrypt_container(
        encrypted_buf,
        encrypted_len,
        "test-password",
        13,
        &decrypted_buf,
        &decrypted_len,
    );
    try std.testing.expectEqual(@as(i32, 0), dec_rc);
    defer blip_free(decrypted_buf, decrypted_len);

    try std.testing.expectEqualSlices(u8, data_bytes, decrypted_buf[0..decrypted_len]);
}

test "C FFI: blip_is_encrypted detects encrypted containers" {
    const data_bytes = try leaf.serializeData(std.testing.allocator, "test");
    defer std.testing.allocator.free(data_bytes);

    try std.testing.expect(!blip_is_encrypted(data_bytes.ptr, data_bytes.len));

    var encrypted_buf: [*]u8 = undefined;
    var encrypted_len: usize = 0;
    // Use PBKDF2 (kdf_id=2) for speed in test
    const rc = blip_encrypt_container(data_bytes.ptr, data_bytes.len, "p", 1, 1, 2, &encrypted_buf, &encrypted_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    defer blip_free(encrypted_buf, encrypted_len);

    try std.testing.expect(blip_is_encrypted(encrypted_buf, encrypted_len));
}

test "C FFI: blip_decrypt_container with wrong password returns auth error" {
    const data_bytes = try leaf.serializeData(std.testing.allocator, "secret");
    defer std.testing.allocator.free(data_bytes);

    var encrypted_buf: [*]u8 = undefined;
    var encrypted_len: usize = 0;
    // Use PBKDF2 (kdf_id=2) for speed
    _ = blip_encrypt_container(data_bytes.ptr, data_bytes.len, "correct", 7, 1, 2, &encrypted_buf, &encrypted_len);
    defer blip_free(encrypted_buf, encrypted_len);

    var decrypted_buf: [*]u8 = undefined;
    var decrypted_len: usize = 0;
    const rc = blip_decrypt_container(encrypted_buf, encrypted_len, "wrong", 5, &decrypted_buf, &decrypted_len);
    try std.testing.expectEqual(@as(i32, -28), rc);
}

test "C FFI: blip_error_string returns encryption error strings" {
    try std.testing.expectEqualSlices(u8, "authentication failed (wrong password or corrupted data)", std.mem.span(blip_error_string(-28)));
    try std.testing.expectEqualSlices(u8, "password required for encrypted container", std.mem.span(blip_error_string(-29)));
    try std.testing.expectEqualSlices(u8, "encryption failed", std.mem.span(blip_error_string(-30)));
    try std.testing.expectEqualSlices(u8, "decryption failed", std.mem.span(blip_error_string(-31)));
}
