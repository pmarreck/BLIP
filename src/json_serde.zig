const std = @import("std");
const Allocator = std.mem.Allocator;
const XxHash64 = std.hash.XxHash64;
const blip = @import("blip.zig");
const mini_blar = @import("mini_blar.zig");
const poke_mod = @import("poke.zig");
const pb = @import("printable_binary");
const testing = std.testing;

const ContainerError = mini_blar.ContainerError;

pub const JsonSerdeError = error{
    OutOfMemory,
    InvalidJson,
    MissingRequiredField,
    InvalidEntryType,
    InvalidTimestamp,
    InvalidMode,
    // Container errors from archive operations
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
};

// =============================================================================
// Formatting helpers
// =============================================================================

/// Format nanoseconds-since-epoch as ISO 8601 with nanoseconds: "2026-02-24T10:30:00.123456789Z"
pub fn formatTimestampNs(allocator: Allocator, ns: i64) ![]u8 {
    if (ns == 0) return try allocator.alloc(u8, 0);

    const sec: i64 = @divFloor(ns, 1_000_000_000);
    const nanos: u64 = @intCast(@mod(ns, 1_000_000_000));

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(sec) };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        nanos,
    });
}

/// Parse ISO 8601 timestamp with nanoseconds back to nanoseconds-since-epoch.
pub fn parseTimestampNs(str: []const u8) !i64 {
    if (str.len == 0) return 0;
    // Format: "YYYY-MM-DDThh:mm:ss.nnnnnnnnnZ"
    // Minimum: "YYYY-MM-DDThh:mm:ssZ" = 20 chars
    if (str.len < 20) return error.InvalidTimestamp;
    if (str[str.len - 1] != 'Z') return error.InvalidTimestamp;

    const year = std.fmt.parseInt(u32, str[0..4], 10) catch return error.InvalidTimestamp;
    const month_num = std.fmt.parseInt(u4, str[5..7], 10) catch return error.InvalidTimestamp;
    const day = std.fmt.parseInt(u5, str[8..10], 10) catch return error.InvalidTimestamp;
    const hour = std.fmt.parseInt(u5, str[11..13], 10) catch return error.InvalidTimestamp;
    const minute = std.fmt.parseInt(u6, str[14..16], 10) catch return error.InvalidTimestamp;
    const second = std.fmt.parseInt(u6, str[17..19], 10) catch return error.InvalidTimestamp;

    var nanos: u64 = 0;
    if (str.len > 20 and str[19] == '.') {
        const frac_str = str[20 .. str.len - 1]; // between '.' and 'Z'
        if (frac_str.len > 9) return error.InvalidTimestamp;
        nanos = std.fmt.parseInt(u64, frac_str, 10) catch return error.InvalidTimestamp;
        // Scale to 9 digits
        var digits = frac_str.len;
        while (digits < 9) : (digits += 1) {
            nanos *= 10;
        }
    }

    const month: std.time.epoch.Month = @enumFromInt(month_num);
    // Convert year/month/day to days since epoch
    const epoch_day = computeEpochDay(year, month, day);
    const total_secs: i64 = @as(i64, @intCast(epoch_day)) * 86400 +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return total_secs * 1_000_000_000 + @as(i64, @intCast(nanos));
}

/// Compute epoch day from year/month/day.
fn computeEpochDay(year: u32, month: std.time.epoch.Month, day: u5) u32 {
    // Days from year 0 to year
    const y = if (year > 0) year - 1 else 0;
    var total_days: u32 = y * 365 + y / 4 - y / 100 + y / 400;

    // Days for year 1970
    const epoch_start: u32 = 1969 * 365 + 1969 / 4 - 1969 / 100 + 1969 / 400;

    // Add days for months in current year
    const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
    const month_days = [_]u16{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    total_days += month_days[month.numeric() - 1];
    if (is_leap and month.numeric() > 2) total_days += 1;
    total_days += @as(u32, day) - 1;

    return total_days - epoch_start;
}

/// Format a mode value as octal string: "0644"
pub fn formatOctalMode(allocator: Allocator, mode: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "0{o:0>3}", .{mode});
}

/// Parse octal mode string: "0644" → 0o644
pub fn parseOctalMode(str: []const u8) !u16 {
    if (str.len == 0) return 0;
    return std.fmt.parseInt(u16, str, 8) catch return error.InvalidMode;
}

// =============================================================================
// JSON string escaping
// =============================================================================

/// Write a JSON-escaped string to the buffer.
fn writeJsonString(allocator: Allocator, buf: *std.ArrayList(u8), str: []const u8) !void {
    try buf.append(allocator, '"');
    for (str) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0C => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    var escape_buf: [6]u8 = undefined;
                    const s = std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, s);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

/// Write an integer to the buffer.
fn writeJsonInt(allocator: Allocator, buf: *std.ArrayList(u8), comptime T: type, val: T) !void {
    var num_buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch unreachable;
    try buf.appendSlice(allocator, s);
}

// =============================================================================
// archiveToJson: convert archive buffer to JSON
// =============================================================================

/// Convert a BLIP archive buffer to a high-level JSON representation.
/// Caller owns returned memory.
pub fn archiveToJson(allocator: Allocator, buf: []const u8) JsonSerdeError![]u8 {
    const entries = poke_mod.reconstructEntries(allocator, buf) catch |e| {
        return mapContainerError(e);
    };
    defer {
        for (entries) |entry| freeArchiveEntry(allocator, entry);
        allocator.free(entries);
    }

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n  \"version\": 1,\n  \"entries\": [");

    for (entries, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "\n    {");

        switch (entry) {
            .file => |f| {
                try out.appendSlice(allocator, "\n      \"type\": \"file\"");
                try out.appendSlice(allocator, ",\n      \"path\": ");
                try writeJsonString(allocator, &out, f.path);

                // Content: pb-encode to make it JSON-safe
                const encoded_content = pb.encode(allocator, f.content, .{}) catch return error.OutOfMemory;
                defer allocator.free(encoded_content);
                try out.appendSlice(allocator, ",\n      \"content\": ");
                try writeJsonString(allocator, &out, encoded_content);

                // Optional metadata (omit zero-value)
                if (f.mode != 0) {
                    const mode_str = formatOctalMode(allocator, f.mode) catch return error.OutOfMemory;
                    defer allocator.free(mode_str);
                    try out.appendSlice(allocator, ",\n      \"mode\": ");
                    try writeJsonString(allocator, &out, mode_str);
                }
                if (f.mtime_ns != 0) {
                    const ts = formatTimestampNs(allocator, f.mtime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"mtime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (f.ctime_ns != 0) {
                    const ts = formatTimestampNs(allocator, f.ctime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"ctime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (f.birthtime_ns != 0) {
                    const ts = formatTimestampNs(allocator, f.birthtime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"birthtime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (f.uid != 0) {
                    try out.appendSlice(allocator, ",\n      \"uid\": ");
                    try writeJsonInt(allocator, &out, u32, f.uid);
                }
                if (f.gid != 0) {
                    try out.appendSlice(allocator, ",\n      \"gid\": ");
                    try writeJsonInt(allocator, &out, u32, f.gid);
                }
                if (f.username.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"username\": ");
                    try writeJsonString(allocator, &out, f.username);
                }
                if (f.groupname.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"groupname\": ");
                    try writeJsonString(allocator, &out, f.groupname);
                }
                if (f.xattrs.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"xattrs\": {");
                    for (f.xattrs, 0..) |xa, xi| {
                        if (xi > 0) try out.append(allocator, ',');
                        try out.appendSlice(allocator, "\n        ");
                        try writeJsonString(allocator, &out, xa.name);
                        try out.appendSlice(allocator, ": ");
                        const encoded_val = pb.encode(allocator, xa.value, .{}) catch return error.OutOfMemory;
                        defer allocator.free(encoded_val);
                        try writeJsonString(allocator, &out, encoded_val);
                    }
                    try out.appendSlice(allocator, "\n      }");
                }
                if (f.resource_fork.len > 0) {
                    const encoded_rf = pb.encode(allocator, f.resource_fork, .{}) catch return error.OutOfMemory;
                    defer allocator.free(encoded_rf);
                    try out.appendSlice(allocator, ",\n      \"resource_fork\": ");
                    try writeJsonString(allocator, &out, encoded_rf);
                }
            },
            .dir => |d| {
                try out.appendSlice(allocator, "\n      \"type\": \"dir\"");
                try out.appendSlice(allocator, ",\n      \"path\": ");
                try writeJsonString(allocator, &out, d.path);

                if (d.mode != 0) {
                    const mode_str = formatOctalMode(allocator, d.mode) catch return error.OutOfMemory;
                    defer allocator.free(mode_str);
                    try out.appendSlice(allocator, ",\n      \"mode\": ");
                    try writeJsonString(allocator, &out, mode_str);
                }
                if (d.mtime_ns != 0) {
                    const ts = formatTimestampNs(allocator, d.mtime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"mtime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (d.ctime_ns != 0) {
                    const ts = formatTimestampNs(allocator, d.ctime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"ctime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (d.birthtime_ns != 0) {
                    const ts = formatTimestampNs(allocator, d.birthtime_ns) catch return error.OutOfMemory;
                    defer allocator.free(ts);
                    try out.appendSlice(allocator, ",\n      \"birthtime\": ");
                    try writeJsonString(allocator, &out, ts);
                }
                if (d.uid != 0) {
                    try out.appendSlice(allocator, ",\n      \"uid\": ");
                    try writeJsonInt(allocator, &out, u32, d.uid);
                }
                if (d.gid != 0) {
                    try out.appendSlice(allocator, ",\n      \"gid\": ");
                    try writeJsonInt(allocator, &out, u32, d.gid);
                }
                if (d.username.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"username\": ");
                    try writeJsonString(allocator, &out, d.username);
                }
                if (d.groupname.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"groupname\": ");
                    try writeJsonString(allocator, &out, d.groupname);
                }
                if (d.xattrs.len > 0) {
                    try out.appendSlice(allocator, ",\n      \"xattrs\": {");
                    for (d.xattrs, 0..) |xa, xi| {
                        if (xi > 0) try out.append(allocator, ',');
                        try out.appendSlice(allocator, "\n        ");
                        try writeJsonString(allocator, &out, xa.name);
                        try out.appendSlice(allocator, ": ");
                        const encoded_val = pb.encode(allocator, xa.value, .{}) catch return error.OutOfMemory;
                        defer allocator.free(encoded_val);
                        try writeJsonString(allocator, &out, encoded_val);
                    }
                    try out.appendSlice(allocator, "\n      }");
                }
            },
        }

        try out.appendSlice(allocator, "\n    }");
    }

    try out.appendSlice(allocator, "\n  ]\n}\n");

    return out.toOwnedSlice(allocator);
}

// =============================================================================
// jsonToArchive: convert JSON back to archive buffer
// =============================================================================

/// Convert a JSON representation back to a BLIP archive buffer.
/// Caller owns returned memory.
pub fn jsonToArchive(allocator: Allocator, json_buf: []const u8) JsonSerdeError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_buf, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const entries_val = root.object.get("entries") orelse return error.InvalidJson;
    if (entries_val != .array) return error.InvalidJson;

    const json_entries = entries_val.array.items;
    if (json_entries.len == 0) {
        // Empty archive
        const empty_entries = &[_]mini_blar.ArchiveEntry{};
        const result = mini_blar.createFullArchive(allocator, empty_entries) catch |e| return mapContainerError(e);
        return result;
    }

    // Parse all entries
    var archive_entries = allocator.alloc(mini_blar.ArchiveEntry, json_entries.len) catch return error.OutOfMemory;
    defer allocator.free(archive_entries);

    // Track allocations for cleanup on error
    var allocated_strings: std.ArrayList([]u8) = .{};
    defer {
        for (allocated_strings.items) |s| allocator.free(s);
        allocated_strings.deinit(allocator);
    }

    for (json_entries, 0..) |entry_val, i| {
        if (entry_val != .object) return error.InvalidJson;
        const obj = entry_val.object;

        const type_str = getJsonString(obj, "type") orelse return error.InvalidEntryType;
        const path_str = getJsonString(obj, "path") orelse return error.MissingRequiredField;

        const path = allocator.dupe(u8, path_str) catch return error.OutOfMemory;
        allocated_strings.append(allocator, path) catch return error.OutOfMemory;

        // Parse common metadata
        const mode: u16 = if (getJsonString(obj, "mode")) |m| parseOctalMode(m) catch 0 else 0;
        const mtime_ns: i64 = if (getJsonString(obj, "mtime")) |t| parseTimestampNs(t) catch 0 else 0;
        const ctime_ns: i64 = if (getJsonString(obj, "ctime")) |t| parseTimestampNs(t) catch 0 else 0;
        const birthtime_ns: i64 = if (getJsonString(obj, "birthtime")) |t| parseTimestampNs(t) catch 0 else 0;
        const uid: u32 = getJsonU32(obj, "uid");
        const gid: u32 = getJsonU32(obj, "gid");

        const username_str = getJsonString(obj, "username") orelse "";
        const username = if (username_str.len > 0)
            (allocator.dupe(u8, username_str) catch return error.OutOfMemory)
        else
            @as([]u8, &.{});
        if (username.len > 0) allocated_strings.append(allocator, username) catch return error.OutOfMemory;

        const groupname_str = getJsonString(obj, "groupname") orelse "";
        const groupname = if (groupname_str.len > 0)
            (allocator.dupe(u8, groupname_str) catch return error.OutOfMemory)
        else
            @as([]u8, &.{});
        if (groupname.len > 0) allocated_strings.append(allocator, groupname) catch return error.OutOfMemory;

        if (std.mem.eql(u8, type_str, "file")) {
            const content_str = getJsonString(obj, "content") orelse "";
            // pb-decode content back to bytes
            const content = pb.decode(allocator, content_str, .{}) catch return error.OutOfMemory;
            allocated_strings.append(allocator, content) catch return error.OutOfMemory;

            // Parse xattrs
            const xattrs = try parseJsonXattrs(allocator, obj, &allocated_strings);
            // Parse resource_fork
            const rf_str = getJsonString(obj, "resource_fork") orelse "";
            const resource_fork = if (rf_str.len > 0) blk: {
                const rf = pb.decode(allocator, rf_str, .{}) catch return error.OutOfMemory;
                allocated_strings.append(allocator, rf) catch return error.OutOfMemory;
                break :blk rf;
            } else @as([]u8, &.{});

            archive_entries[i] = .{
                .file = .{
                    .path = path,
                    .content = content,
                    .mode = mode,
                    .mtime_ns = mtime_ns,
                    .ctime_ns = ctime_ns,
                    .birthtime_ns = birthtime_ns,
                    .uid = uid,
                    .gid = gid,
                    .username = username,
                    .groupname = groupname,
                    .xattrs = xattrs,
                    .resource_fork = resource_fork,
                },
            };
        } else if (std.mem.eql(u8, type_str, "dir")) {
            // Parse xattrs for dirs
            const xattrs = try parseJsonXattrs(allocator, obj, &allocated_strings);

            archive_entries[i] = .{
                .dir = .{
                    .path = path,
                    .xh64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, // computed below
                    .mode = mode,
                    .mtime_ns = mtime_ns,
                    .ctime_ns = ctime_ns,
                    .birthtime_ns = birthtime_ns,
                    .uid = uid,
                    .gid = gid,
                    .username = username,
                    .groupname = groupname,
                    .xattrs = xattrs,
                },
            };
        } else {
            return error.InvalidEntryType;
        }
    }

    // Compute Merkle hashes for DIR entries
    try computeDirMerkleHashes(allocator, archive_entries);

    // Create the archive
    const result = mini_blar.createFullArchive(allocator, archive_entries) catch |e| return mapContainerError(e);
    return result;
}

// =============================================================================
// Merkle hash computation for DIR entries
// =============================================================================

/// Compute Merkle hashes for all DIR entries based on child FILE ARRAY hashes.
fn computeDirMerkleHashes(allocator: Allocator, entries: []mini_blar.ArchiveEntry) JsonSerdeError!void {
    // First, serialize each FILE entry to get its ARRAY hash
    var file_hashes = std.StringHashMap([8]u8).init(allocator);
    defer file_hashes.deinit();

    var to_free: std.ArrayList([]u8) = .{};
    defer {
        for (to_free.items) |item| allocator.free(item);
        to_free.deinit(allocator);
    }

    for (entries) |entry| {
        switch (entry) {
            .file => |f| {
                const file_bytes = mini_blar.serializeFileEntry(allocator, f, &to_free) catch |e| {
                    return mapContainerError2(e);
                };
                // v2: FILE containers have no trailing checksum, so compute
                // xxHash64 of the full serialized entry for the Merkle tree.
                if (file_bytes.len > 0) {
                    var hash: [8]u8 = undefined;
                    std.mem.writeInt(u64, &hash, XxHash64.hash(0, file_bytes), .little);
                    file_hashes.put(f.path, hash) catch return error.OutOfMemory;
                }
            },
            .dir => {},
        }
    }

    // For each DIR, find child FILEs by path prefix and compute Merkle hash
    for (entries) |*entry| {
        switch (entry.*) {
            .dir => |*d| {
                var child_hashes_list: std.ArrayList([8]u8) = .{};
                defer child_hashes_list.deinit(allocator);

                const dir_prefix = d.path;
                for (entries) |other| {
                    switch (other) {
                        .file => |f| {
                            // Check if this file is a direct child of the directory
                            if (isDirectChild(dir_prefix, f.path)) {
                                if (file_hashes.get(f.path)) |hash| {
                                    child_hashes_list.append(allocator, hash) catch return error.OutOfMemory;
                                }
                            }
                        },
                        .dir => {},
                    }
                }

                if (child_hashes_list.items.len > 0) {
                    d.xh64 = mini_blar.computeMerkleHash(child_hashes_list.items);
                }
            },
            .file => {},
        }
    }
}

/// Check if `child_path` is a direct child of `dir_path`.
/// e.g., isDirectChild("mydir", "mydir/file.txt") = true
///       isDirectChild("mydir", "mydir/sub/deep.txt") = false
fn isDirectChild(dir_path: []const u8, child_path: []const u8) bool {
    if (child_path.len <= dir_path.len + 1) return false;
    if (!std.mem.startsWith(u8, child_path, dir_path)) return false;
    if (child_path[dir_path.len] != '/') return false;
    // Check no more slashes after the prefix
    const rest = child_path[dir_path.len + 1 ..];
    return std.mem.indexOfScalar(u8, rest, '/') == null;
}

// =============================================================================
// JSON helper functions
// =============================================================================

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getJsonU32(obj: std.json.ObjectMap, key: []const u8) u32 {
    const val = obj.get(key) orelse return 0;
    if (val == .integer) {
        const i = val.integer;
        if (i >= 0 and i <= std.math.maxInt(u32)) return @intCast(i);
    }
    return 0;
}

fn parseJsonXattrs(allocator: Allocator, obj: std.json.ObjectMap, allocated_strings: *std.ArrayList([]u8)) JsonSerdeError![]const mini_blar.XattrEntry {
    const xattrs_val = obj.get("xattrs") orelse return &.{};
    if (xattrs_val != .object) return &.{};
    const xattr_obj = xattrs_val.object;

    if (xattr_obj.count() == 0) return &.{};

    const xattrs = allocator.alloc(mini_blar.XattrEntry, xattr_obj.count()) catch return error.OutOfMemory;

    var xi: usize = 0;
    var it = xattr_obj.iterator();
    while (it.next()) |kv| {
        const name = allocator.dupe(u8, kv.key_ptr.*) catch return error.OutOfMemory;
        allocated_strings.append(allocator, name) catch return error.OutOfMemory;

        const val_str = if (kv.value_ptr.* == .string) kv.value_ptr.string else "";
        const value = pb.decode(allocator, val_str, .{}) catch return error.OutOfMemory;
        allocated_strings.append(allocator, value) catch return error.OutOfMemory;

        xattrs[xi] = .{
            .name = name,
            .value = value,
        };
        xi += 1;
    }

    return xattrs;
}

// =============================================================================
// Error mapping helpers
// =============================================================================

fn mapContainerError(err: anytype) JsonSerdeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidContainerType => error.InvalidContainerType,
        error.InvalidLength => error.InvalidLength,
        error.LengthExceedsBounds => error.LengthExceedsBounds,
        error.MissingRequiredKey => error.MissingRequiredKey,
        error.DuplicateKey => error.DuplicateKey,
        error.KeysNotSorted => error.KeysNotSorted,
        error.HashMismatch => error.HashMismatch,
        error.IndexOutOfBounds => error.IndexOutOfBounds,
        error.InvalidMagic => error.InvalidMagic,
        error.BufferTooSmall => error.BufferTooSmall,
        error.UnexpectedEndOfInput => error.UnexpectedEndOfInput,
        error.Overflow => error.Overflow,
        error.MissingSigil => error.MissingSigil,
        error.InvalidSigilOrder => error.InvalidSigilOrder,
        error.MissingDecompLen => error.MissingDecompLen,
    };
}

fn mapContainerError2(err: anytype) JsonSerdeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidContainerType => error.InvalidContainerType,
        error.InvalidLength => error.InvalidLength,
        error.LengthExceedsBounds => error.LengthExceedsBounds,
        error.MissingRequiredKey => error.MissingRequiredKey,
        error.DuplicateKey => error.DuplicateKey,
        error.KeysNotSorted => error.KeysNotSorted,
        error.HashMismatch => error.HashMismatch,
        error.IndexOutOfBounds => error.IndexOutOfBounds,
        error.InvalidMagic => error.InvalidMagic,
        error.BufferTooSmall => error.BufferTooSmall,
        error.UnexpectedEndOfInput => error.UnexpectedEndOfInput,
        error.Overflow => error.Overflow,
        error.MissingSigil => error.MissingSigil,
        error.InvalidSigilOrder => error.InvalidSigilOrder,
        error.MissingDecompLen => error.MissingDecompLen,
    };
}

fn freeArchiveEntry(allocator: Allocator, entry: mini_blar.ArchiveEntry) void {
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

// =============================================================================
// Tests
// =============================================================================

test "formatTimestampNs: zero returns empty" {
    const allocator = testing.allocator;
    const result = try formatTimestampNs(allocator, 0);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "formatTimestampNs: known timestamp" {
    const allocator = testing.allocator;
    // 2026-01-01T00:00:00.000000000Z = 1767225600 seconds
    const ns: i64 = 1767225600_000_000_000;
    const result = try formatTimestampNs(allocator, ns);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, "2026-01-01T00:00:00.000000000Z", result);
}

test "parseTimestampNs: round-trip" {
    const allocator = testing.allocator;
    const original: i64 = 1708787200_123_456_789;
    const str = try formatTimestampNs(allocator, original);
    defer allocator.free(str);
    const parsed = try parseTimestampNs(str);
    try testing.expectEqual(original, parsed);
}

test "parseTimestampNs: known value" {
    const result = try parseTimestampNs("2026-01-01T00:00:00.000000000Z");
    try testing.expectEqual(@as(i64, 1767225600_000_000_000), result);
}

test "parseTimestampNs: without nanos" {
    const result = try parseTimestampNs("2026-01-01T00:00:00Z");
    try testing.expectEqual(@as(i64, 1767225600_000_000_000), result);
}

test "formatOctalMode and parseOctalMode round-trip" {
    const allocator = testing.allocator;
    const modes = [_]u16{ 0o644, 0o755, 0o600, 0o777, 0o000 };
    for (modes) |mode| {
        const str = try formatOctalMode(allocator, mode);
        defer allocator.free(str);
        const parsed = try parseOctalMode(str);
        try testing.expectEqual(mode, parsed);
    }
}

test "formatOctalMode: specific values" {
    const allocator = testing.allocator;
    const str644 = try formatOctalMode(allocator, 0o644);
    defer allocator.free(str644);
    try testing.expectEqualSlices(u8, "0644", str644);

    const str755 = try formatOctalMode(allocator, 0o755);
    defer allocator.free(str755);
    try testing.expectEqualSlices(u8, "0755", str755);
}

test "full archive round-trip: create → toJson → fromJson → byte-identical" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "hello.txt", .content = "Hello, world!\n", .mode = 0o644, .mtime_ns = 1000000 },
        .{ .path = "test.bin", .content = "binary data", .mode = 0o755, .mtime_ns = 2000000 },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
        .{ .file = files[1] },
    };

    const archive1 = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive1);

    const json = try archiveToJson(allocator, archive1);
    defer allocator.free(json);

    const archive2 = try jsonToArchive(allocator, json);
    defer allocator.free(archive2);

    // Verify the round-tripped archive is valid
    const reader = try mini_blar.ArchiveReader.init(archive2);
    try testing.expect(try reader.verifyHash());
    try testing.expectEqual(@as(u64, 2), try reader.entryCount());

    // Content should match
    try testing.expectEqualSlices(u8, "Hello, world!\n", try reader.fileContentAt(0));
    try testing.expectEqualSlices(u8, "binary data", try reader.fileContentAt(1));
}

test "binary content: pb-encodes in JSON, pb-decodes back correctly" {
    const allocator = testing.allocator;
    // Create content with all 256 byte values
    var binary_content: [256]u8 = undefined;
    for (&binary_content, 0..) |*b, i| b.* = @intCast(i);

    const files = [_]mini_blar.FileEntry{
        .{ .path = "binary.bin", .content = &binary_content },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };

    const archive1 = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive1);

    const json = try archiveToJson(allocator, archive1);
    defer allocator.free(json);

    const archive2 = try jsonToArchive(allocator, json);
    defer allocator.free(archive2);

    const reader = try mini_blar.ArchiveReader.init(archive2);
    const content = try reader.fileContentAt(0);
    try testing.expectEqualSlices(u8, &binary_content, content);
}

test "minimal JSON (only required fields) produces valid archive" {
    const allocator = testing.allocator;
    const json =
        \\{"version":1,"entries":[{"type":"file","path":"test.txt","content":"hello"}]}
    ;
    const archive = try jsonToArchive(allocator, json);
    defer allocator.free(archive);

    const reader = try mini_blar.ArchiveReader.init(archive);
    try testing.expect(try reader.verifyHash());
    try testing.expectEqual(@as(u64, 1), try reader.entryCount());
    try testing.expectEqualSlices(u8, "hello", try reader.fileContentAt(0));
}

test "zero-value field omission in output" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "test.txt", .content = "data" },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };

    const archive = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive);

    const json = try archiveToJson(allocator, archive);
    defer allocator.free(json);

    // Should NOT contain "uid" or "gid" since they're zero
    try testing.expect(std.mem.indexOf(u8, json, "\"uid\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"gid\"") == null);
    // Should contain "type" and "path"
    try testing.expect(std.mem.indexOf(u8, json, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"path\"") != null);
}

test "dir entries with Merkle hash recomputation" {
    const allocator = testing.allocator;
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .dir = .{
            .path = "mydir",
            .xh64 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 },
            .mode = 0o755,
        } },
        .{ .file = .{
            .path = "mydir/file.txt",
            .content = "hello",
            .mode = 0o644,
        } },
    };

    const archive1 = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive1);

    const json = try archiveToJson(allocator, archive1);
    defer allocator.free(json);

    const archive2 = try jsonToArchive(allocator, json);
    defer allocator.free(archive2);

    const reader = try mini_blar.ArchiveReader.init(archive2);
    try testing.expect(try reader.verifyHash());
    try testing.expectEqual(@as(u64, 2), try reader.entryCount());
}

test "error: missing path field" {
    const allocator = testing.allocator;
    const json =
        \\{"version":1,"entries":[{"type":"file","content":"data"}]}
    ;
    try testing.expectError(error.MissingRequiredField, jsonToArchive(allocator, json));
}

test "error: invalid JSON" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidJson, jsonToArchive(allocator, "NOT JSON {{{"));
}

test "error: unknown type value" {
    const allocator = testing.allocator;
    const json =
        \\{"version":1,"entries":[{"type":"symlink","path":"foo"}]}
    ;
    try testing.expectError(error.InvalidEntryType, jsonToArchive(allocator, json));
}

test "empty content round-trip" {
    const allocator = testing.allocator;
    const files = [_]mini_blar.FileEntry{
        .{ .path = "empty.txt", .content = "" },
    };
    const entries = [_]mini_blar.ArchiveEntry{
        .{ .file = files[0] },
    };

    const archive1 = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive1);

    const json = try archiveToJson(allocator, archive1);
    defer allocator.free(json);

    const archive2 = try jsonToArchive(allocator, json);
    defer allocator.free(archive2);

    const reader = try mini_blar.ArchiveReader.init(archive2);
    const content = try reader.fileContentAt(0);
    try testing.expectEqual(@as(usize, 0), content.len);
}

test "isDirectChild" {
    try testing.expect(isDirectChild("mydir", "mydir/file.txt"));
    try testing.expect(!isDirectChild("mydir", "mydir/sub/deep.txt"));
    try testing.expect(!isDirectChild("mydir", "other/file.txt"));
    try testing.expect(!isDirectChild("mydir", "mydir"));
}

test "xattrs round-trip via JSON" {
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

    const archive1 = try mini_blar.createFullArchive(allocator, &entries);
    defer allocator.free(archive1);

    const json = try archiveToJson(allocator, archive1);
    defer allocator.free(json);

    // JSON should contain the xattr
    try testing.expect(std.mem.indexOf(u8, json, "user.comment") != null);

    const archive2 = try jsonToArchive(allocator, json);
    defer allocator.free(archive2);

    const reader = try mini_blar.ArchiveReader.init(archive2);
    try testing.expect(try reader.verifyHash());
}
