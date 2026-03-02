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
        error.MissingSigil => -25,
        error.InvalidSigilOrder => -26,
        error.MissingDecompLen => -27,
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
    xh64: [8]u8, // Merkle hash for dirs (auto-computed by createFullArchive, can be zeroed)
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
    progress_fn: mini_blar.ProgressFn,
    phase_fn: mini_blar.PhaseFn,
    progress_ctx: ?*anyopaque,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const normalize = (flags & BLIP_ARCHIVE_ABSOLUTE_PATHS) == 0;

    var archive_entries = page_allocator.alloc(mini_blar.ArchiveEntry, entry_count) catch return -13;
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

    const result = mini_blar.createFullArchive(page_allocator, archive_entries, progress_fn, phase_fn, progress_ctx) catch |e| {
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

/// Get file content at the given index (zero-copy pointer into buf).
/// Only works for FILE entries (reads DATA container element 1).
export fn blip_archive_file_content(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
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
    const reader = mini_blar.ArchiveReader.init(buf[0..buf_len]) catch |e| return containerErrorCode(e);
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
    progress_fn: compression_mod.CompressProgressFn,
    phase_fn: compression_mod.PhaseFn,
    progress_ctx: ?*anyopaque,
    out_buf: *[*]u8,
    out_len: *usize,
) callconv(.c) i32 {
    const algo = std.meta.intToEnum(CompressionId, @as(u7, @truncate(algo_id))) catch return -32;
    const slice = buf[0..buf_len];
    const result = compression_mod.compressContainer(page_allocator, algo, slice, progress_fn, phase_fn, progress_ctx) catch |e| switch (e) {
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

test "C FFI: bzip2 compress+decompress multi-block archive" {
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
    const rc = blip_compress_container(&data, data.len, 2, null, null, null, &out_buf, &out_len);
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
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, null, null, null, &out_buf, &out_len));
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
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 2, 0, null, null, null, &out_buf, &out_len));
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
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create_full(&entries, 1, 0, null, null, null, &out_buf, &out_len));
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
