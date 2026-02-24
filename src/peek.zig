const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const array_mod = @import("array.zig");
const dict_mod = @import("dict.zig");
const data_mod = @import("data.zig");
const leaf = @import("leaf.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;
const XxHash64 = std.hash.XxHash64;

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
    var segments: std.ArrayListUnmanaged(PathSegment) = .{};
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
        const view = try container.parseHeader(current);

        switch (seg) {
            .index => |idx| {
                // For ARRAY/FILE containers, use ArrayReader
                switch (view.container_type) {
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
                        const val_view = try container.parseHeader(val_container);
                        current = current[val_offset..][0..@intCast(val_view.total_length)];
                    },
                    else => return ContainerError.InvalidContainerType,
                }
            },
            .key => |key_bytes| {
                // For DICT/MAP/DIR containers, use DictReader to find by key
                switch (view.container_type) {
                    .dict, .map, .dir => {
                        const dict_reader = try dict_mod.DictReader.init(current[0..@intCast(view.total_length)]);
                        const pair_idx = (try dict_reader.findKey(key_bytes)) orelse return ContainerError.IndexOutOfBounds;
                        const val_container = try dict_reader.valueAt(pair_idx);
                        const val_offset = @intFromPtr(val_container.ptr) - @intFromPtr(current.ptr);
                        const val_view = try container.parseHeader(val_container);
                        current = current[val_offset..][0..@intCast(val_view.total_length)];
                    },
                    else => return ContainerError.InvalidContainerType,
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
    const view = try container.parseHeader(buf);
    switch (view.container_type) {
        .array, .file => {
            const reader = try array_mod.ArrayReader.init(buf[0..@intCast(view.total_length)]);
            return reader.elementCount();
        },
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            return reader.pairCount();
        },
        else => return ContainerError.InvalidContainerType,
    }
}

/// Read the trailing xxHash64 from a container.
/// Works for ARRAY, DICT, MAP, FILE, DIR (all have trailing 8-byte hash).
/// For DATA, reads the embedded hash after the content bytes.
pub fn containerHash(buf: []const u8) ContainerError![8]u8 {
    const view = try container.parseHeader(buf);
    const total: usize = @intCast(view.total_length);
    if (total < 8) return ContainerError.InvalidLength;

    switch (view.container_type) {
        .array, .file, .dict, .map, .dir => {
            // Hash is the last 8 bytes of the container
            var hash: [8]u8 = undefined;
            @memcpy(&hash, buf[total - 8 .. total]);
            return hash;
        },
        .data => {
            // DATA hash is also the last 8 bytes of the value payload
            var hash: [8]u8 = undefined;
            @memcpy(&hash, buf[total - 8 .. total]);
            return hash;
        },
        else => return ContainerError.InvalidContainerType,
    }
}

/// Get the key payload bytes at a given pair index from a DICT/MAP/DIR container.
/// Returns the raw key bytes (stripped of TLV header).
pub fn containerKeyAt(buf: []const u8, index: u64) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    switch (view.container_type) {
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            const key_container = try reader.keyAt(index);
            return dict_mod.extractKeyBytes(key_container);
        },
        else => return ContainerError.InvalidContainerType,
    }
}

/// Get pair count from a DICT/MAP/DIR container.
pub fn containerKeyCount(buf: []const u8) ContainerError!u64 {
    const view = try container.parseHeader(buf);
    switch (view.container_type) {
        .dict, .map, .dir => {
            const reader = try dict_mod.DictReader.init(buf[0..@intCast(view.total_length)]);
            return reader.pairCount();
        },
        else => return ContainerError.InvalidContainerType,
    }
}

/// Get the container type name as a string.
pub fn containerTypeName(buf: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(buf);
    return switch (view.container_type) {
        .array => "ARRAY",
        .dict => "DICT",
        .utf8 => "UTF8",
        .raw => "RAW",
        .file => "FILE",
        .map => "MAP",
        .dir => "DIR",
        .data => "DATA",
    };
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
    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]dict_mod.KeyValue{.{ .key = key, .value = val }};
    const dict_buf = try dict_mod.serializeDict(allocator, &pairs);
    defer allocator.free(dict_buf);

    try testing.expectEqual(@as(u64, 1), try containerCount(dict_buf));
}

test "containerHash on ARRAY -> matches expected xxHash64" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);

    const hash = try containerHash(arr);
    // Verify it matches what ArrayReader reports
    const reader = try array_mod.ArrayReader.init(arr);
    try testing.expect(try reader.verifyHash());

    // The hash bytes should be the last 8 bytes of the array
    try testing.expectEqualSlices(u8, arr[arr.len - 8 ..], &hash);
}

test "containerKeyAt on DICT -> returns correct key bytes" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "beta");
    defer allocator.free(key_b);
    const val = try leaf.serializeRaw(allocator, "v");
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

    // RAW
    const raw = try leaf.serializeRaw(allocator, "data");
    defer allocator.free(raw);
    try testing.expectEqualSlices(u8, "RAW", try containerTypeName(raw));

    // ARRAY
    const elements = [_][]const u8{utf8};
    const arr = try array_mod.serializeArray(allocator, &elements);
    defer allocator.free(arr);
    try testing.expectEqualSlices(u8, "ARRAY", try containerTypeName(arr));

    // DICT
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "v");
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
    const val = try leaf.serializeRaw(allocator, "v");
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
    const file_container = try array_mod.serializeArrayLike(allocator, &file_elems, .file);
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

test "containerHash on DATA -> returns embedded hash" {
    const allocator = testing.allocator;
    const data_container = try data_mod.serializeData(allocator, "test content");
    defer allocator.free(data_container);

    const hash = try containerHash(data_container);
    // Verify it's the same as the last 8 bytes
    try testing.expectEqualSlices(u8, data_container[data_container.len - 8 ..], &hash);
    // And that the DATA hash verifies
    try testing.expect(try data_mod.verifyDataHash(data_container));
}
