const std = @import("std");
const Allocator = std.mem.Allocator;
const container = @import("container.zig");
const ct = @import("container_types.zig");
const array_mod = @import("array.zig");
const dict_mod = @import("dict.zig");
const data_mod = @import("leaf.zig"); // data.zig merged into leaf.zig (v2 migration)
const leaf = @import("leaf.zig");
const pb = @import("printable_binary");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerTypeId = ct.ContainerTypeId;

// =============================================================================
// Path parsing types
// =============================================================================

pub const PathSegment = union(enum) {
    index: u64,
    key: []const u8,
};

pub const Accessor = enum {
    none,
    type_name,
    count,
    hash,
    keys,
};

pub const ParsedPath = struct {
    segments: []PathSegment,
    accessor: Accessor,
};

pub const PathError = error{
    UnclosedBracket,
    EmptyBracket,
    InvalidIndex,
    UnexpectedCharacter,
    OutOfMemory,
};

// =============================================================================
// Path parsing
// =============================================================================

/// Parse a path string like "[1][0][pa].keys" into segments + accessor.
/// Caller owns the returned segment array (allocated with the provided allocator).
pub fn parsePath(allocator: Allocator, path_str: []const u8) PathError!ParsedPath {
    var segments: std.ArrayListUnmanaged(PathSegment) = .empty;
    errdefer segments.deinit(allocator);

    var accessor: Accessor = .none;
    var i: usize = 0;

    while (i < path_str.len) {
        if (path_str[i] == '[') {
            // Find the closing bracket
            const start = i + 1;
            var end = start;
            while (end < path_str.len and path_str[end] != ']') {
                end += 1;
            }
            if (end >= path_str.len) return PathError.UnclosedBracket;
            if (start == end) return PathError.EmptyBracket;

            const content = path_str[start..end];

            // Try to parse as integer index
            if (isAllDigits(content)) {
                const index = std.fmt.parseInt(u64, content, 10) catch return PathError.InvalidIndex;
                segments.append(allocator, .{ .index = index }) catch return PathError.OutOfMemory;
            } else {
                // Treat as key
                segments.append(allocator, .{ .key = content }) catch return PathError.OutOfMemory;
            }

            i = end + 1; // skip past ']'
        } else if (path_str[i] == '.') {
            // Parse accessor
            const rest = path_str[i + 1 ..];
            if (std.mem.eql(u8, rest, "type")) {
                accessor = .type_name;
            } else if (std.mem.eql(u8, rest, "count")) {
                accessor = .count;
            } else if (std.mem.eql(u8, rest, "hash")) {
                accessor = .hash;
            } else if (std.mem.eql(u8, rest, "keys")) {
                accessor = .keys;
            } else {
                return PathError.UnexpectedCharacter;
            }
            break; // accessor is always terminal
        } else {
            return PathError.UnexpectedCharacter;
        }
    }

    return ParsedPath{
        .segments = segments.toOwnedSlice(allocator) catch return PathError.OutOfMemory,
        .accessor = accessor,
    };
}

fn isAllDigits(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Free a ParsedPath allocated by parsePath.
pub fn freeParsedPath(allocator: Allocator, path: *ParsedPath) void {
    allocator.free(path.segments);
    path.segments = &.{};
}

// =============================================================================
// Navigation
// =============================================================================

/// Navigate through a container hierarchy following the given path segments.
/// Returns a slice of the buffer pointing at the target container.
/// The returned slice starts at the container's first byte (type sentinel)
/// and extends through total_length bytes.
pub fn navigate(buf: []const u8, segments: []const PathSegment) ContainerError![]const u8 {
    var current = buf;

    for (segments) |seg| {
        const view = try container.parseLPHeader(current);

        switch (seg) {
            .index => |idx| {
                // For ARRAY/FILE containers, use ArrayReader
                switch (view.type_id) {
                    .array, .file => {
                        const reader = try array_mod.ArrayReader.init(current[0..@intCast(view.total_length)]);
                        const elem_view = try reader.elementAt(idx);
                        // Get the element slice from the buffer
                        const elem_offset = @intFromPtr(elem_view.buf.ptr) - @intFromPtr(current.ptr);
                        current = current[elem_offset..][0..@intCast(elem_view.total_length)];
                    },
                    // For DICT/MAP/DIR, index means pair index — we need to distinguish
                    // key access from value access. Since [N] on a dict doesn't make sense
                    // in the path syntax (we use [key] for dicts), treat numeric index on
                    // dict-like as accessing the value at pair index N.
                    .dict, .map, .dir => {
                        const dict_reader = try dict_mod.DictReader.init(current[0..@intCast(view.total_length)]);
                        const val_container = try dict_reader.valueAt(idx);
                        const val_offset = @intFromPtr(val_container.ptr) - @intFromPtr(current.ptr);
                        const val_view = try container.parseLPHeader(val_container);
                        current = current[val_offset..][0..@intCast(val_view.total_length)];
                    },
                    .utf8, .data, .segment => return ContainerError.InvalidContainerType,
                }
            },
            .key => |key_bytes| {
                // For DICT/MAP/DIR containers, use DictReader to find by key
                switch (view.type_id) {
                    .dict, .map, .dir => {
                        const dict_reader = try dict_mod.DictReader.init(current[0..@intCast(view.total_length)]);
                        const pair_idx = (try dict_reader.findKey(key_bytes)) orelse return ContainerError.IndexOutOfBounds;
                        const val_container = try dict_reader.valueAt(pair_idx);
                        const val_offset = @intFromPtr(val_container.ptr) - @intFromPtr(current.ptr);
                        const val_view = try container.parseLPHeader(val_container);
                        current = current[val_offset..][0..@intCast(val_view.total_length)];
                    },
                    .array, .file, .utf8, .data, .segment => return ContainerError.InvalidContainerType,
                }
            },
        }
    }

    return current;
}

// =============================================================================
// Container accessors
// =============================================================================

/// Get element/pair count for a container.
/// For ARRAY/FILE: returns element count.
/// For DICT/MAP/DIR: returns pair count.
pub fn containerCount(buf: []const u8) ContainerError!u64 {
    const view = try container.parseLPHeader(buf);
    switch (view.type_id) {
        .array, .file => {
            const reader = try array_mod.ArrayReader.init(buf[0..@intCast(view.total_length)]);
            return reader.elementCount();
        },
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            return reader.pairCount();
        },
        .utf8, .data, .segment => return ContainerError.InvalidContainerType,
    }
}

/// Read the checksum from a container (v2 LP format).
/// Returns the first 8 bytes of whatever checksum is present.
/// Returns error if the container has no checksum attribute.
pub fn containerHash(buf: []const u8) ContainerError![8]u8 {
    const view = try container.parseLPHeader(buf);
    const csum_slice = view.checksumSlice();
    var hash: [8]u8 = .{0} ** 8;
    if (csum_slice.len == 0) return ContainerError.InvalidLength;
    const copy_len = @min(csum_slice.len, 8);
    @memcpy(hash[0..copy_len], csum_slice[0..copy_len]);
    return hash;
}

/// Get the key payload bytes at a given pair index from a DICT/MAP/DIR container.
/// Returns the raw key bytes (stripped of TLV header).
pub fn containerKeyAt(buf: []const u8, index: u64) ContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    switch (view.type_id) {
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            const key_container = try reader.keyAt(index);
            return dict_mod.extractKeyBytes(key_container);
        },
        .array, .file, .utf8, .data, .segment => return ContainerError.InvalidContainerType,
    }
}

/// Get pair count from a DICT/MAP/DIR container.
pub fn containerKeyCount(buf: []const u8) ContainerError!u64 {
    const view = try container.parseLPHeader(buf);
    switch (view.type_id) {
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            return reader.pairCount();
        },
        .array, .file, .utf8, .data, .segment => return ContainerError.InvalidContainerType,
    }
}

/// Get the container type name as a string.
pub fn containerTypeName(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    return switch (view.type_id) {
        .array => "ARRAY",
        .dict => "DICT",
        .utf8 => "UTF8",
        .data => "DATA",
        .file => "FILE",
        .map => "MAP",
        .dir => "DIR",
        .segment => "SEGMENT",
    };
}

// =============================================================================
// Peek display: full formatting logic (moved from C blar_common.h)
// =============================================================================

pub const PeekFlags = packed struct(u32) {
    json: bool = false, // --json
    raw: bool = false, // --raw
    hex: bool = false, // --hex
    is_tty: bool = false, // caller sets if stdout isatty
    _padding: u28 = 0,
};

pub const PeekResult = struct {
    stdout_buf: []const u8,
    stderr_buf: []const u8,
    is_error: bool,
    allocator: Allocator,

    pub fn deinit(self: *PeekResult) void {
        if (self.stdout_buf.len > 0) self.allocator.free(self.stdout_buf);
        if (self.stderr_buf.len > 0) self.allocator.free(self.stderr_buf);
    }
};

/// Extract the payload bytes from a leaf container (UTF8 or DATA).
/// In v2 LP format, payloadSlice() already excludes checksum bytes.
pub fn extractPayload(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseLPHeader(buf);
    switch (view.type_id) {
        .utf8, .data => return view.payloadSlice(),
        .array, .dict, .file, .map, .dir, .segment => return ContainerError.InvalidContainerType,
    }
}

/// Format an i64 nanoseconds-since-epoch timestamp as ISO 8601.
/// Returns allocated string like "2024-02-24T12:00:00.000000000Z".
pub fn formatTimestamp(allocator: Allocator, ns: i64) ![]u8 {
    // Convert nanoseconds to seconds + fractional nanos
    var secs = @divTrunc(ns, 1_000_000_000);
    var nanos = @mod(ns, 1_000_000_000);
    if (nanos < 0) {
        secs -= 1;
        nanos += 1_000_000_000;
    }

    // Convert epoch seconds to date/time components (UTC)
    // Using a simple algorithm for gmtime
    const days_since_epoch = @divTrunc(secs, 86400);
    const time_of_day = @mod(secs, 86400);
    const hours = @divTrunc(time_of_day, 3600);
    const rem_after_hours = @mod(time_of_day, 3600);
    const minutes = @divTrunc(rem_after_hours, 60);
    const seconds = @mod(rem_after_hours, 60);

    // Civil date from days since epoch (1970-01-01 = day 0)
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    const z = days_since_epoch + 719468;
    const era: i64 = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097; // day of era [0, 146096]
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const d: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    // Cast to unsigned for formatting (no '+' prefix)
    const uyear: u64 = @intCast(year);
    const umonth: u64 = @intCast(m);
    const uday: u64 = @intCast(d);
    const uhours: u64 = @intCast(hours);
    const uminutes: u64 = @intCast(minutes);
    const useconds: u64 = @intCast(seconds);
    const unanos: u64 = @intCast(nanos);

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        uyear, umonth, uday, uhours, uminutes, useconds, unanos,
    });
}

/// Format bytes as hex string "0123abcd...".
pub fn formatHex(allocator: Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, i| {
        const hex = "0123456789abcdef";
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

/// Extract the last key segment from a navigation path string.
/// Returns the key string if the last segment is a non-numeric key, null otherwise.
pub fn lastKeyFromPath(nav_path: []const u8) ?[]const u8 {
    if (nav_path.len < 3) return null;
    if (nav_path[nav_path.len - 1] != ']') return null;

    // Find the matching '['
    var i = nav_path.len - 2;
    while (i > 0 and nav_path[i] != '[') : (i -= 1) {}
    if (nav_path[i] != '[') return null;

    const key = nav_path[i + 1 .. nav_path.len - 1];
    if (key.len == 0) return null;

    // Check if it's all digits (then it's an index, not a key)
    for (key) |c| {
        if (c < '0' or c > '9') return key;
    }
    return null; // all digits = index
}

/// Printable-binary identity check.
/// Encodes bytes through printable-binary; if output == input, no encoding was needed.
/// Returns: .output = encoded bytes (caller owns), .needed_encoding = true if different.
pub const PbCheckResult = struct {
    output: []u8,
    needed_encoding: bool,
};

pub fn pbIdentityCheck(allocator: Allocator, bytes: []const u8) !PbCheckResult {
    const encoded = try pb.encode(allocator, bytes, .{});
    const needed = !std.mem.eql(u8, bytes, encoded);
    return .{ .output = encoded, .needed_encoding = needed };
}

/// Format a value for a known metadata key, or return null if not recognized.
/// Handles: md (mode), mt/ct/bt (timestamps), ui/gi (IDs), xh (hash),
/// pa/un/gn (UTF8 strings).
pub fn formatKnownKey(
    allocator: Allocator,
    key: []const u8,
    type_id: ContainerTypeId,
    payload: []const u8,
    json_mode: bool,
) Allocator.Error!?[]u8 {
    if (key.len != 2) return null;

    // md: mode (u16 LE) → octal
    if (std.mem.eql(u8, key, "md") and type_id == .data and payload.len == 2) {
        const m = std.mem.readInt(u16, payload[0..2], .little);
        if (json_mode) {
            return try std.fmt.allocPrint(allocator, "{d}", .{m});
        } else {
            return try std.fmt.allocPrint(allocator, "{o:0>4}", .{m});
        }
    }

    // mt, ct, bt: timestamps (i64 LE nanoseconds) → ISO 8601
    if (type_id == .data and payload.len == 8 and
        (std.mem.eql(u8, key, "mt") or std.mem.eql(u8, key, "ct") or std.mem.eql(u8, key, "bt")))
    {
        const ns = std.mem.readInt(i64, payload[0..8], .little);
        if (json_mode) {
            return try std.fmt.allocPrint(allocator, "{d}", .{ns});
        } else {
            return try formatTimestamp(allocator, ns);
        }
    }

    // ui, gi: IDs (u32 LE) → decimal
    if (type_id == .data and payload.len == 4 and
        (std.mem.eql(u8, key, "ui") or std.mem.eql(u8, key, "gi")))
    {
        const id = std.mem.readInt(u32, payload[0..4], .little);
        return try std.fmt.allocPrint(allocator, "{d}", .{id});
    }

    // xh: hash (8 bytes) → hex
    if (std.mem.eql(u8, key, "xh") and type_id == .data and payload.len == 8) {
        return try formatHex(allocator, payload);
    }

    // pa, un, gn: UTF8 strings
    if (type_id == .utf8 and
        (std.mem.eql(u8, key, "pa") or std.mem.eql(u8, key, "un") or std.mem.eql(u8, key, "gn")))
    {
        if (json_mode) {
            return try std.fmt.allocPrint(allocator, "\"{s}\"", .{payload});
        } else {
            return try std.fmt.allocPrint(allocator, "{s}", .{payload});
        }
    }

    return null;
}

/// Main peek display function — all formatting logic in pure Zig.
/// Takes a BLIP buffer, navigation path, and flags.
/// Returns stdout and stderr buffers (caller owns via PeekResult.deinit()).
pub fn peekDisplay(
    allocator: Allocator,
    buf: []const u8,
    path: []const u8,
    flags: PeekFlags,
) !PeekResult {
    var stdout_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stderr_list.deinit(allocator);

    // Parse path into segments + accessor
    var parsed = parsePath(allocator, path) catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try stderr_list.appendSlice(allocator, "error: invalid path\n");
                return PeekResult{
                    .stdout_buf = try stdout_list.toOwnedSlice(allocator),
                    .stderr_buf = try stderr_list.toOwnedSlice(allocator),
                    .is_error = true,
                    .allocator = allocator,
                };
            },
        }
    };
    defer freeParsedPath(allocator, &parsed);

    // Navigate to target container
    const target = navigate(buf, parsed.segments) catch |e| {
        const msg = switch (e) {
            error.IndexOutOfBounds => "error: index out of bounds\n",
            error.InvalidContainerType => "error: invalid container type\n",
            else => "error: navigation failed\n",
        };
        try stderr_list.appendSlice(allocator, msg);
        return PeekResult{
            .stdout_buf = try stdout_list.toOwnedSlice(allocator),
            .stderr_buf = try stderr_list.toOwnedSlice(allocator),
            .is_error = true,
            .allocator = allocator,
        };
    };

    // Get container info
    const view = try container.parseLPHeader(target);
    const ctype = view.type_id;

    // Dispatch on accessor
    switch (parsed.accessor) {
        .type_name => {
            const name = containerTypeName(target) catch "UNKNOWN";
            if (flags.json) {
                try stdout_list.appendSlice(allocator, "\"");
                try stdout_list.appendSlice(allocator, name);
                try stdout_list.appendSlice(allocator, "\"\n");
            } else {
                try stdout_list.appendSlice(allocator, name);
                try stdout_list.appendSlice(allocator, "\n");
            }
        },
        .count => {
            const count = try containerCount(target);
            const s = try std.fmt.allocPrint(allocator, "{d}\n", .{count});
            defer allocator.free(s);
            try stdout_list.appendSlice(allocator, s);
        },
        .hash => {
            const hash = try containerHash(target);
            const hex = try formatHex(allocator, &hash);
            defer allocator.free(hex);
            if (flags.json) {
                try stdout_list.appendSlice(allocator, "\"");
                try stdout_list.appendSlice(allocator, hex);
                try stdout_list.appendSlice(allocator, "\"\n");
            } else {
                try stdout_list.appendSlice(allocator, hex);
                try stdout_list.appendSlice(allocator, "\n");
            }
        },
        .keys => {
            const count = try containerCount(target);
            if (flags.json) {
                try stdout_list.appendSlice(allocator, "[");
                for (0..count) |i| {
                    const key_bytes = try containerKeyAt(target, i);
                    if (i > 0) try stdout_list.appendSlice(allocator, ",");
                    try stdout_list.appendSlice(allocator, "\"");
                    try stdout_list.appendSlice(allocator, key_bytes);
                    try stdout_list.appendSlice(allocator, "\"");
                }
                try stdout_list.appendSlice(allocator, "]\n");
            } else {
                for (0..count) |i| {
                    const key_bytes = try containerKeyAt(target, i);
                    try stdout_list.appendSlice(allocator, key_bytes);
                    try stdout_list.appendSlice(allocator, "\n");
                }
            }
        },
        .none => {
            // --raw mode: output raw payload bytes
            if (flags.raw) {
                try handleRawMode(allocator, target, ctype, flags, &stdout_list, &stderr_list);
            } else if (flags.hex) {
                try handleHexMode(allocator, target, ctype, &stdout_list);
            } else {
                try handleDefaultMode(allocator, target, ctype, path, flags, &stdout_list, &stderr_list);
            }
        },
    }

    return PeekResult{
        .stdout_buf = try stdout_list.toOwnedSlice(allocator),
        .stderr_buf = try stderr_list.toOwnedSlice(allocator),
        .is_error = false,
        .allocator = allocator,
    };
}

fn handleRawMode(
    allocator: Allocator,
    target: []const u8,
    ctype: ContainerTypeId,
    flags: PeekFlags,
    stdout_list: *std.ArrayListUnmanaged(u8),
    stderr_list: *std.ArrayListUnmanaged(u8),
) !void {
    switch (ctype) {
        .utf8, .data => {
            const payload = try extractPayload(target);
            if (flags.is_tty) {
                // Pipe through printable-binary for terminal safety
                const encoded = try pb.encode(allocator, payload, .{});
                defer allocator.free(encoded);
                try stdout_list.appendSlice(allocator, encoded);
                try stderr_list.appendSlice(allocator, "Warning: binary data piped through printable-binary for terminal safety\n");
            } else {
                try stdout_list.appendSlice(allocator, payload);
            }
        },
        .array, .file, .dict, .map, .dir => {
            // Container type: output raw container bytes
            try stdout_list.appendSlice(allocator, target);
        },
        .segment => {
            // SEGMENT containers are transport-layer wrappers; raw mode emits them as-is.
            try stdout_list.appendSlice(allocator, target);
        },
    }
}

fn handleHexMode(
    allocator: Allocator,
    target: []const u8,
    ctype: ContainerTypeId,
    stdout_list: *std.ArrayListUnmanaged(u8),
) !void {
    switch (ctype) {
        .utf8, .data, .segment => {
            const payload = try extractPayload(target);
            const hex = try formatHex(allocator, payload);
            defer allocator.free(hex);
            try stdout_list.appendSlice(allocator, "0x");
            try stdout_list.appendSlice(allocator, hex);
            try stdout_list.appendSlice(allocator, "\n");
        },
        .array, .file, .dict, .map, .dir => {
            // For containers, hex-dump the checksum (first 8 bytes)
            const hash = containerHash(target) catch {
                try stdout_list.appendSlice(allocator, "0x\n");
                return;
            };
            const hex = try formatHex(allocator, &hash);
            defer allocator.free(hex);
            try stdout_list.appendSlice(allocator, "0x");
            try stdout_list.appendSlice(allocator, hex);
            try stdout_list.appendSlice(allocator, "\n");
        },
    }
}

fn handleDefaultMode(
    allocator: Allocator,
    target: []const u8,
    ctype: ContainerTypeId,
    path: []const u8,
    flags: PeekFlags,
    stdout_list: *std.ArrayListUnmanaged(u8),
    stderr_list: *std.ArrayListUnmanaged(u8),
) !void {
    // Determine the navigation portion of the path (before accessor, which is already stripped)
    const nav_path = path;

    // Check for semantic display of known metadata keys
    if (lastKeyFromPath(nav_path)) |last_key| {
        if (ctype == .utf8 or ctype == .data) {
            const payload = extractPayload(target) catch null;
            if (payload) |p| {
                const formatted = try formatKnownKey(allocator, last_key, ctype, p, flags.json);
                if (formatted) |f| {
                    defer allocator.free(f);
                    try stdout_list.appendSlice(allocator, f);
                    try stdout_list.appendSlice(allocator, "\n");
                    return;
                }
            }
        }
    }

    // Default display by container type
    switch (ctype) {
        .utf8 => {
            const payload = try extractPayload(target);
            if (flags.json) {
                // JSON string: use printable-binary identity check
                const check = try pbIdentityCheck(allocator, payload);
                defer allocator.free(check.output);
                try stdout_list.appendSlice(allocator, "\"");
                if (check.needed_encoding) {
                    try stdout_list.appendSlice(allocator, check.output);
                    try stderr_list.appendSlice(allocator, "Warning: value contained non-printable bytes, encoded via printable-binary\n");
                } else {
                    try stdout_list.appendSlice(allocator, payload);
                }
                try stdout_list.appendSlice(allocator, "\"\n");
            } else {
                try stdout_list.appendSlice(allocator, payload);
                try stdout_list.appendSlice(allocator, "\n");
            }
        },
        .data => {
            const payload = try extractPayload(target);
            if (flags.json) {
                // JSON: hex-encode data bytes
                const hex = try formatHex(allocator, payload);
                defer allocator.free(hex);
                try stdout_list.appendSlice(allocator, "\"");
                try stdout_list.appendSlice(allocator, hex);
                try stdout_list.appendSlice(allocator, "\"\n");
            } else {
                // Default: printable-binary encode + stderr size info
                const encoded = try pb.encode(allocator, payload, .{});
                defer allocator.free(encoded);
                try stdout_list.appendSlice(allocator, encoded);
                try stdout_list.appendSlice(allocator, "\n");
                const info = try std.fmt.allocPrint(allocator, "(DATA, {d} bytes)\n", .{payload.len});
                defer allocator.free(info);
                try stderr_list.appendSlice(allocator, info);
            }
        },
        .array, .file => {
            const count = containerCount(target) catch 0;
            const name = containerTypeName(target) catch "UNKNOWN";
            if (flags.json) {
                const s = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"count\":{d}}}\n", .{ name, count });
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            } else {
                const s = try std.fmt.allocPrint(allocator, "{s} ({d} elements)\n", .{ name, count });
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            }
        },
        .dict, .map, .dir => {
            const count = containerCount(target) catch 0;
            const name = containerTypeName(target) catch "UNKNOWN";
            if (flags.json) {
                const s = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\",\"count\":{d}}}\n", .{ name, count });
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            } else {
                const s = try std.fmt.allocPrint(allocator, "{s} ({d} pairs)\n", .{ name, count });
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            }
        },
        .segment => {
            // SEGMENT containers are transport-layer wrappers; default display
            // just identifies them — full reassembly is the caller's job.
            const name = containerTypeName(target) catch "SEGMENT";
            if (flags.json) {
                const s = try std.fmt.allocPrint(allocator, "{{\"type\":\"{s}\"}}\n", .{name});
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            } else {
                const s = try std.fmt.allocPrint(allocator, "{s} (transport segment)\n", .{name});
                defer allocator.free(s);
                try stdout_list.appendSlice(allocator, s);
            }
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

test "parsePath: empty string -> empty segments, no accessor" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, "");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 0), result.segments.len);
    try testing.expectEqual(Accessor.none, result.accessor);
}

test "parsePath: [0] -> [index(0)], no accessor" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, "[0]");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 1), result.segments.len);
    try testing.expectEqual(@as(u64, 0), result.segments[0].index);
    try testing.expectEqual(Accessor.none, result.accessor);
}

test "parsePath: [1][0][pa] -> [index(1), index(0), key(pa)], no accessor" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, "[1][0][pa]");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 3), result.segments.len);
    try testing.expectEqual(@as(u64, 1), result.segments[0].index);
    try testing.expectEqual(@as(u64, 0), result.segments[1].index);
    try testing.expectEqualSlices(u8, "pa", result.segments[2].key);
    try testing.expectEqual(Accessor.none, result.accessor);
}

test "parsePath: [1][0].type -> [index(1), index(0)], accessor=type_name" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, "[1][0].type");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 2), result.segments.len);
    try testing.expectEqual(@as(u64, 1), result.segments[0].index);
    try testing.expectEqual(@as(u64, 0), result.segments[1].index);
    try testing.expectEqual(Accessor.type_name, result.accessor);
}

test "parsePath: [1][0][0].keys -> [index(1), index(0), index(0)], accessor=keys" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, "[1][0][0].keys");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 3), result.segments.len);
    try testing.expectEqual(@as(u64, 1), result.segments[0].index);
    try testing.expectEqual(@as(u64, 0), result.segments[1].index);
    try testing.expectEqual(@as(u64, 0), result.segments[2].index);
    try testing.expectEqual(Accessor.keys, result.accessor);
}

test "parsePath: .count -> empty segments, accessor=count" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, ".count");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 0), result.segments.len);
    try testing.expectEqual(Accessor.count, result.accessor);
}

test "parsePath: .hash -> empty segments, accessor=hash" {
    const allocator = testing.allocator;
    var result = try parsePath(allocator, ".hash");
    defer freeParsedPath(allocator, &result);
    try testing.expectEqual(@as(usize, 0), result.segments.len);
    try testing.expectEqual(Accessor.hash, result.accessor);
}

test "parsePath: [abc -> error (unclosed bracket)" {
    const allocator = testing.allocator;
    const result = parsePath(allocator, "[abc");
    try testing.expectError(PathError.UnclosedBracket, result);
}

test "parsePath: [] -> error (empty bracket)" {
    const allocator = testing.allocator;
    const result = parsePath(allocator, "[]");
    try testing.expectError(PathError.EmptyBracket, result);
}

test "navigate: create a mini archive, navigate to known containers" {
    const allocator = testing.allocator;

    // Build: ARRAY[ UTF8("magic"), ARRAY[ UTF8("inner") ] ]
    const magic = try leaf.serializeUtf8(allocator, "magic");
    defer allocator.free(magic);

    const inner_elem = try leaf.serializeUtf8(allocator, "inner");
    defer allocator.free(inner_elem);
    const inner_elems = [_][]const u8{inner_elem};
    const inner_array = try array_mod.serializeArray(allocator, &inner_elems);
    defer allocator.free(inner_array);

    const outer_elems = [_][]const u8{ magic, inner_array };
    const archive = try array_mod.serializeArray(allocator, &outer_elems);
    defer allocator.free(archive);

    // Navigate to [0] -> should be UTF8 "magic"
    const seg0 = [_]PathSegment{.{ .index = 0 }};
    const result0 = try navigate(archive, &seg0);
    const type0 = try containerTypeName(result0);
    try testing.expectEqualSlices(u8, "UTF8", type0);
    const val0 = try leaf.readUtf8(result0);
    try testing.expectEqualSlices(u8, "magic", val0);

    // Navigate to [1] -> should be ARRAY
    const seg1 = [_]PathSegment{.{ .index = 1 }};
    const result1 = try navigate(archive, &seg1);
    const type1 = try containerTypeName(result1);
    try testing.expectEqualSlices(u8, "ARRAY", type1);

    // Navigate to [1][0] -> should be UTF8 "inner"
    const seg10 = [_]PathSegment{ .{ .index = 1 }, .{ .index = 0 } };
    const result10 = try navigate(archive, &seg10);
    const val10 = try leaf.readUtf8(result10);
    try testing.expectEqualSlices(u8, "inner", val10);
}

test "navigate: dict key lookup" {
    const allocator = testing.allocator;

    // Build a DICT with keys "aa" and "bb"
    const key_aa = try leaf.serializeUtf8(allocator, "aa");
    defer allocator.free(key_aa);
    const key_bb = try leaf.serializeUtf8(allocator, "bb");
    defer allocator.free(key_bb);
    const val_1 = try leaf.serializeUtf8(allocator, "first");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeUtf8(allocator, "second");
    defer allocator.free(val_2);

    const pairs = [_]dict_mod.KeyValue{
        .{ .key = key_aa, .value = val_1 },
        .{ .key = key_bb, .value = val_2 },
    };
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    // Navigate to [bb] -> should be UTF8 "second"
    const seg = [_]PathSegment{.{ .key = "bb" }};
    const result = try navigate(dict_buf, &seg);
    const val = try leaf.readUtf8(result);
    try testing.expectEqualSlices(u8, "second", val);
}

test "containerCount on ARRAY -> correct element count" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "c");
    defer allocator.free(elem2);

    const elements = [_][]const u8{ elem0, elem1, elem2 };
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    try testing.expectEqual(@as(u64, 3), try containerCount(arr));
}

test "containerCount on DICT -> correct pair count" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]dict_mod.KeyValue{.{ .key = key, .value = val }};
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    try testing.expectEqual(@as(u64, 1), try containerCount(dict_buf));
}

test "containerHash on ARRAY with BLAKE3-128 checksum" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .blake3_128 });
    defer allocator.free(arr);

    const hash = try containerHash(arr);
    // Verify checksum is valid
    const reader = try array_mod.ArrayReader.init(arr);
    try testing.expect(try reader.verifyChecksum());

    // containerHash returns first 8 bytes of the 16-byte BLAKE3-128 checksum
    try testing.expectEqualSlices(u8, arr[arr.len - 16 ..][0..8], &hash);
}

test "containerKeyAt on DICT -> returns correct key bytes" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "beta");
    defer allocator.free(key_b);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]dict_mod.KeyValue{
        .{ .key = key_a, .value = val },
        .{ .key = key_b, .value = val },
    };
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    try testing.expectEqualSlices(u8, "alpha", try containerKeyAt(dict_buf, 0));
    try testing.expectEqualSlices(u8, "beta", try containerKeyAt(dict_buf, 1));
}

test "containerTypeName returns correct names" {
    const allocator = testing.allocator;

    // UTF8
    const utf8 = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(utf8);
    try testing.expectEqualSlices(u8, "UTF8", try containerTypeName(utf8));

    // DATA
    const data = try leaf.serializeData(allocator, "data");
    defer allocator.free(data);
    try testing.expectEqualSlices(u8, "DATA", try containerTypeName(data));

    // ARRAY
    const elements = [_][]const u8{utf8};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);
    try testing.expectEqualSlices(u8, "ARRAY", try containerTypeName(arr));

    // DICT
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);
    const pairs = [_]dict_mod.KeyValue{.{ .key = key, .value = val }};
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);
    try testing.expectEqualSlices(u8, "DICT", try containerTypeName(dict_buf));
}

test "containerKeyCount on DICT -> correct pair count" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "aa");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "bb");
    defer allocator.free(key_b);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]dict_mod.KeyValue{
        .{ .key = key_a, .value = val },
        .{ .key = key_b, .value = val },
    };
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    try testing.expectEqual(@as(u64, 2), try containerKeyCount(dict_buf));
}

test "navigate: FILE container (ARRAY layout) traversal" {
    const allocator = testing.allocator;

    // Build a FILE: ARRAY-like [metadata_dict, data_container]
    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const val_pa = try leaf.serializeUtf8(allocator, "test.txt");
    defer allocator.free(val_pa);

    const meta_pairs = [_]dict_mod.KeyValue{
        .{ .key = key_pa, .value = val_pa },
    };
    const meta_dict = try dict_mod.serializeDict(allocator, &meta_pairs);
    defer allocator.free(meta_dict);

    const data_container = try data_mod.serializeData(allocator, "hello");
    defer allocator.free(data_container);

    const file_elems = [_][]const u8{ meta_dict, data_container };
    const file_container = try array_mod.serializeArrayLike(allocator, &file_elems, .file, .{});
    defer allocator.free(file_container);

    // FILE type
    try testing.expectEqualSlices(u8, "FILE", try containerTypeName(file_container));

    // [0] -> DICT (metadata)
    const seg0 = [_]PathSegment{.{ .index = 0 }};
    const meta_result = try navigate(file_container, &seg0);
    try testing.expectEqualSlices(u8, "DICT", try containerTypeName(meta_result));

    // [0][pa] -> UTF8 "test.txt"
    const seg0pa = [_]PathSegment{ .{ .index = 0 }, .{ .key = "pa" } };
    const pa_result = try navigate(file_container, &seg0pa);
    try testing.expectEqualSlices(u8, "test.txt", try leaf.readUtf8(pa_result));

    // [1] -> DATA
    const seg1 = [_]PathSegment{.{ .index = 1 }};
    const data_result = try navigate(file_container, &seg1);
    try testing.expectEqualSlices(u8, "DATA", try containerTypeName(data_result));

    // Count
    try testing.expectEqual(@as(u64, 2), try containerCount(file_container));
}

test "containerHash on DATA with xxHash64 checksum" {
    const allocator = testing.allocator;
    const data_container = try leaf.serializeDataWithOptions(allocator, "test content", .{ .csum_id = .xxhash64 });
    defer allocator.free(data_container);

    const hash = try containerHash(data_container);
    // xxHash64 checksum is 8 bytes, so containerHash returns all 8 bytes
    try testing.expectEqualSlices(u8, data_container[data_container.len - 8 ..], &hash);
    // And that the checksum verifies
    try testing.expect(try leaf.verifyLeafChecksum(data_container));
}

test "containerHash on container without checksum returns error" {
    const allocator = testing.allocator;
    // serializeData without options has no checksum
    const data_container = try data_mod.serializeData(allocator, "test content");
    defer allocator.free(data_container);

    try testing.expectError(ContainerError.InvalidLength, containerHash(data_container));
}

// =============================================================================
// Peek display tests
// =============================================================================

test "extractPayload: UTF8 container" {
    const allocator = testing.allocator;
    const utf8 = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(utf8);
    const payload = try extractPayload(utf8);
    try testing.expectEqualSlices(u8, "hello", payload);
}

test "extractPayload: DATA container excludes trailing hash" {
    const allocator = testing.allocator;
    const data = try data_mod.serializeData(allocator, "test");
    defer allocator.free(data);
    const payload = try extractPayload(data);
    try testing.expectEqualSlices(u8, "test", payload);
}

test "extractPayload: ARRAY returns error" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(elem);
    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);
    try testing.expectError(ContainerError.InvalidContainerType, extractPayload(arr));
}

test "formatTimestamp: known epoch value" {
    const allocator = testing.allocator;
    // 2024-02-24 12:00:00 UTC = 1708776000 seconds
    const ns: i64 = 1708776000 * 1_000_000_000;
    const result = try formatTimestamp(allocator, ns);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "2024-02-24T12:00:00.000000000Z", result);
}

test "formatTimestamp: epoch zero" {
    const allocator = testing.allocator;
    const result = try formatTimestamp(allocator, 0);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "1970-01-01T00:00:00.000000000Z", result);
}

test "formatHex: basic" {
    const allocator = testing.allocator;
    const result = try formatHex(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "deadbeef", result);
}

test "formatHex: empty" {
    const allocator = testing.allocator;
    const result = try formatHex(allocator, &[_]u8{});
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "lastKeyFromPath: [foo][bar] -> bar" {
    try testing.expectEqualSlices(u8, "bar", lastKeyFromPath("[foo][bar]").?);
}

test "lastKeyFromPath: [0][pa] -> pa" {
    try testing.expectEqualSlices(u8, "pa", lastKeyFromPath("[0][pa]").?);
}

test "lastKeyFromPath: [0][1] -> null (numeric)" {
    try testing.expectEqual(@as(?[]const u8, null), lastKeyFromPath("[0][1]"));
}

test "lastKeyFromPath: empty -> null" {
    try testing.expectEqual(@as(?[]const u8, null), lastKeyFromPath(""));
}

test "pbIdentityCheck: passthrough ASCII needs no encoding" {
    const allocator = testing.allocator;
    // Only characters that printable-binary maps to themselves (alphanums, ., ;, @, ^, _)
    const result = try pbIdentityCheck(allocator, "HelloWorld.123");
    defer allocator.free(result.output);
    try testing.expect(!result.needed_encoding);
}

test "pbIdentityCheck: binary input needs encoding" {
    const allocator = testing.allocator;
    const result = try pbIdentityCheck(allocator, &[_]u8{ 0x00, 0xFF, 0x01 });
    defer allocator.free(result.output);
    try testing.expect(result.needed_encoding);
}

test "formatKnownKey: md as octal" {
    const allocator = testing.allocator;
    var mode_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mode_bytes, 0o755, .little);
    const result = (try formatKnownKey(allocator, "md", .data, &mode_bytes, false)).?;
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "0755", result);
}

test "formatKnownKey: md as json decimal" {
    const allocator = testing.allocator;
    var mode_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mode_bytes, 0o644, .little);
    const result = (try formatKnownKey(allocator, "md", .data, &mode_bytes, true)).?;
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "420", result);
}

test "formatKnownKey: ui as decimal" {
    const allocator = testing.allocator;
    var uid_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &uid_bytes, 501, .little);
    const result = (try formatKnownKey(allocator, "ui", .data, &uid_bytes, false)).?;
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "501", result);
}

test "formatKnownKey: unknown key returns null" {
    const allocator = testing.allocator;
    const result = try formatKnownKey(allocator, "zz", .data, "test", false);
    try testing.expectEqual(@as(?[]u8, null), result);
}

test "peekDisplay: .type accessor on ARRAY" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);
    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, ".type", .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, "ARRAY\n", result.stdout_buf);
    try testing.expect(!result.is_error);
}

test "peekDisplay: .count accessor on ARRAY" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(elem1);
    const elements = [_][]const u8{ elem0, elem1 };
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, ".count", .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, "2\n", result.stdout_buf);
}

test "peekDisplay: .hash accessor on ARRAY with checksum" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);
    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .blake3_128 });
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, ".hash", .{});
    defer result.deinit();
    // containerHash returns 8 bytes -> 16 hex chars + newline
    try testing.expectEqual(@as(usize, 17), result.stdout_buf.len);
    try testing.expectEqual(@as(u8, '\n'), result.stdout_buf[16]);
}

test "peekDisplay: .keys accessor on DICT" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "aa");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "bb");
    defer allocator.free(key_b);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);
    const pairs = [_]dict_mod.KeyValue{
        .{ .key = key_a, .value = val },
        .{ .key = key_b, .value = val },
    };
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    var result = try peekDisplay(allocator, dict_buf, ".keys", .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, "aa\nbb\n", result.stdout_buf);
}

test "peekDisplay: .keys --json on DICT" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "aa");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "bb");
    defer allocator.free(key_b);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);
    const pairs = [_]dict_mod.KeyValue{
        .{ .key = key_a, .value = val },
        .{ .key = key_b, .value = val },
    };
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    var result = try peekDisplay(allocator, dict_buf, ".keys", .{ .json = true });
    defer result.deinit();
    try testing.expectEqualSlices(u8, "[\"aa\",\"bb\"]\n", result.stdout_buf);
}

test "peekDisplay: UTF8 default display" {
    const allocator = testing.allocator;
    const utf8 = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(utf8);

    var result = try peekDisplay(allocator, utf8, "", .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, "hello\n", result.stdout_buf);
}

test "peekDisplay: UTF8 --json display" {
    const allocator = testing.allocator;
    const utf8 = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(utf8);

    var result = try peekDisplay(allocator, utf8, "", .{ .json = true });
    defer result.deinit();
    try testing.expectEqualSlices(u8, "\"hello\"\n", result.stdout_buf);
}

test "peekDisplay: DATA --raw without tty" {
    const allocator = testing.allocator;
    const data = try data_mod.serializeData(allocator, "hello");
    defer allocator.free(data);

    var result = try peekDisplay(allocator, data, "", .{ .raw = true });
    defer result.deinit();
    try testing.expectEqualSlices(u8, "hello", result.stdout_buf);
    try testing.expectEqual(@as(usize, 0), result.stderr_buf.len);
}

test "peekDisplay: DATA --raw with tty -> printable-binary + warning" {
    const allocator = testing.allocator;
    const data = try data_mod.serializeData(allocator, &[_]u8{ 0x00, 0x01, 0x02 });
    defer allocator.free(data);

    var result = try peekDisplay(allocator, data, "", .{ .raw = true, .is_tty = true });
    defer result.deinit();
    try testing.expect(result.stdout_buf.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.stderr_buf, "Warning:") != null);
}

test "peekDisplay: --hex mode on DATA" {
    const allocator = testing.allocator;
    const data = try data_mod.serializeData(allocator, &[_]u8{ 0xDE, 0xAD });
    defer allocator.free(data);

    var result = try peekDisplay(allocator, data, "", .{ .hex = true });
    defer result.deinit();
    try testing.expectEqualSlices(u8, "0xdead\n", result.stdout_buf);
}

test "peekDisplay: ARRAY default summary" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(elem1);
    const elements = [_][]const u8{ elem0, elem1 };
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, "", .{});
    defer result.deinit();
    try testing.expectEqualSlices(u8, "ARRAY (2 elements)\n", result.stdout_buf);
}

test "peekDisplay: DICT --json summary" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);
    const pairs = [_]dict_mod.KeyValue{.{ .key = key, .value = val }};
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    var result = try peekDisplay(allocator, dict_buf, "", .{ .json = true });
    defer result.deinit();
    try testing.expectEqualSlices(u8, "{\"type\":\"DICT\",\"count\":1}\n", result.stdout_buf);
}

test "peekDisplay: error on invalid path" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);
    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, "[abc", .{});
    defer result.deinit();
    try testing.expect(result.is_error);
    try testing.expect(result.stderr_buf.len > 0);
}

test "peekDisplay: error on out-of-bounds index" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);
    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    var result = try peekDisplay(allocator, arr, "[99]", .{});
    defer result.deinit();
    try testing.expect(result.is_error);
    try testing.expect(std.mem.indexOf(u8, result.stderr_buf, "out of bounds") != null);
}
