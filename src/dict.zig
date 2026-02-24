const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const leaf = @import("leaf.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerType = ct.ContainerType;
const XxHash64 = std.hash.XxHash64;

/// A pre-serialized key-value pair for dictionary construction.
/// Both key and value must already be complete TLV containers.
pub const KeyValue = struct {
    key: []const u8, // pre-serialized UTF8 or RAW container bytes
    value: []const u8, // pre-serialized container of any type
};

/// Extract the value payload bytes from a key container (UTF8 or RAW).
/// Strips the TLV header and returns just the key text/bytes.
pub fn extractKeyBytes(key_container: []const u8) ContainerError![]const u8 {
    const view = try container.parseHeader(key_container);
    return view.valueSlice();
}

/// Compare two key byte slices in canonical byte order (memcmp/lexicographic).
/// Returns .lt, .eq, or .gt.
fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Internal helper: serialize a dict-like container (DICT, FILE, or MAP).
fn serializeDictLike(
    allocator: Allocator,
    pairs: []const KeyValue,
    container_type: ContainerType,
) (Allocator.Error || ContainerError)![]u8 {
    const n: u64 = pairs.len;

    // Compute total data size (sum of all key + value byte lengths)
    var data_size: u64 = 0;
    for (pairs) |pair| {
        data_size += pair.key.len;
        data_size += pair.value.len;
    }

    // Fixpoint iteration to determine S (total encoding size) and I (index_offset encoding size)
    var S: usize = 1; // initial guess for blip.encodedSize(total)
    var I: usize = 1; // initial guess for blip.encodedSize(index_offset)

    var total: u64 = undefined;
    var index_offset: u64 = undefined;

    // Offset storage for key and value offsets (interleaved: key_0, val_0, key_1, val_1, ...)
    var stack_offsets: [2048]u64 = undefined; // 1024 pairs max on stack
    var heap_offsets: ?[]u64 = null;
    defer if (heap_offsets) |ho| allocator.free(ho);

    const offset_count = pairs.len * 2;
    const offset_storage: []u64 = if (offset_count <= 2048)
        stack_offsets[0..offset_count]
    else blk: {
        heap_offsets = try allocator.alloc(u64, offset_count);
        break :blk heap_offsets.?;
    };

    for (0..10) |_| {
        const header_size: u64 = 2 + S + I;

        // Compute key/value offsets from container start
        var running_offset: u64 = header_size;
        for (pairs, 0..) |pair, k| {
            offset_storage[k * 2] = running_offset; // key offset
            running_offset += pair.key.len;
            offset_storage[k * 2 + 1] = running_offset; // value offset
            running_offset += pair.value.len;
        }

        index_offset = running_offset; // = header_size + data_size

        // Compute index section size: BLIP(N) + sum of interleaved BLIP(key_off) BLIP(val_off)
        var index_size: u64 = blip.encodedSize(n);
        for (offset_storage[0..offset_count]) |off| {
            index_size += blip.encodedSize(off);
        }

        total = running_offset + index_size + 8; // data + index + hash

        const S_new = blip.encodedSize(total);
        const I_new = blip.encodedSize(index_offset);

        if (S_new == S and I_new == I) break;
        S = S_new;
        I = I_new;
    }

    // Allocate the exact buffer
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    var pos: usize = 0;

    // Write type sentinel
    const sentinel = ct.typeSentinel(container_type);
    buf[pos] = sentinel[0];
    buf[pos + 1] = sentinel[1];
    pos += 2;

    // Write BLIP(total)
    const total_written = blip.encode(total, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += total_written;

    // Write BLIP(index_offset)
    const idx_off_written = blip.encode(index_offset, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += idx_off_written;

    // Write data section (interleaved key, value pairs)
    for (pairs) |pair| {
        @memcpy(buf[pos..][0..pair.key.len], pair.key);
        pos += pair.key.len;
        @memcpy(buf[pos..][0..pair.value.len], pair.value);
        pos += pair.value.len;
    }

    // Write index section: BLIP(N), then interleaved BLIP(key_off), BLIP(val_off), ...
    const n_written = blip.encode(n, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += n_written;

    for (offset_storage[0..offset_count]) |off| {
        const off_written = blip.encode(off, buf[pos..]) catch return ContainerError.BufferTooSmall;
        pos += off_written;
    }

    // Write xxHash64 (8 bytes, little-endian)
    const hash_value = XxHash64.hash(0, buf[0 .. total - 8]);
    std.mem.writeInt(u64, buf[pos..][0..8], hash_value, .little);
    pos += 8;

    std.debug.assert(pos == total);

    return buf;
}

/// Serialize an ordered set of key-value pairs as a DICT container (0x81 0x02).
/// Keys must already be in canonical byte order and must be unique.
/// Caller owns returned memory.
pub fn serializeDict(allocator: Allocator, pairs: []const KeyValue) (Allocator.Error || ContainerError)![]u8 {
    // Validate key ordering and uniqueness
    try validateKeyOrder(pairs);
    return serializeDictLike(allocator, pairs, .dict);
}

/// Serialize an ordered set of key-value pairs as a FILE container (0x81 0x05).
/// Same as serializeDict but validates required keys: "bina", "path", "xh64".
/// Caller owns returned memory.
pub fn serializeFile(allocator: Allocator, pairs: []const KeyValue) (Allocator.Error || ContainerError)![]u8 {
    // Validate key ordering and uniqueness
    try validateKeyOrder(pairs);

    // Check that required keys exist
    var has_bina = false;
    var has_path = false;
    var has_xh64 = false;

    for (pairs) |pair| {
        const key_bytes = try extractKeyBytes(pair.key);
        if (std.mem.eql(u8, key_bytes, "bina")) has_bina = true;
        if (std.mem.eql(u8, key_bytes, "path")) has_path = true;
        if (std.mem.eql(u8, key_bytes, "xh64")) has_xh64 = true;
    }

    if (!has_bina) return ContainerError.MissingRequiredKey;
    if (!has_path) return ContainerError.MissingRequiredKey;
    if (!has_xh64) return ContainerError.MissingRequiredKey;

    return serializeDictLike(allocator, pairs, .file);
}

/// Serialize an ordered set of key-value pairs as a DIR container (0x81 0x07).
/// Same as serializeDict but validates required keys: "path", "xh64".
/// Does NOT require "bina" (directories have no binary content).
/// Caller owns returned memory.
pub fn serializeDir(allocator: Allocator, pairs: []const KeyValue) (Allocator.Error || ContainerError)![]u8 {
    // Validate key ordering and uniqueness
    try validateKeyOrder(pairs);

    // Check that required keys exist
    var has_path = false;
    var has_xh64 = false;

    for (pairs) |pair| {
        const key_bytes = try extractKeyBytes(pair.key);
        if (std.mem.eql(u8, key_bytes, "path")) has_path = true;
        if (std.mem.eql(u8, key_bytes, "xh64")) has_xh64 = true;
    }

    if (!has_path) return ContainerError.MissingRequiredKey;
    if (!has_xh64) return ContainerError.MissingRequiredKey;

    return serializeDictLike(allocator, pairs, .dir);
}

/// Validate that keys in the pairs array are in canonical byte order and unique.
fn validateKeyOrder(pairs: []const KeyValue) ContainerError!void {
    if (pairs.len < 2) return;

    var prev_key = try extractKeyBytes(pairs[0].key);
    for (pairs[1..]) |pair| {
        const cur_key = try extractKeyBytes(pair.key);
        const ord = compareKeys(prev_key, cur_key);
        if (ord == .eq) return ContainerError.DuplicateKey;
        if (ord == .gt) return ContainerError.KeysNotSorted;
        prev_key = cur_key;
    }
}

/// Reader for DICT, FILE, and MAP containers. Provides random access to key-value pairs via the index.
pub const DictReader = struct {
    buf: []const u8,
    total_length: u64,
    header_size: usize, // bytes consumed by type + BLIP(total) + BLIP(index_offset)
    index_offset: u64,
    count: u64,
    index_start: usize, // byte position right after BLIP(N) was decoded (where interleaved pairs start)

    /// Parse a DICT, FILE, or MAP container from a buffer.
    /// buf must start at the container's first byte (type sentinel).
    pub fn init(buf: []const u8) ContainerError!DictReader {
        // Parse outer header: type + total_length
        const view = try container.parseHeader(buf);
        if (view.container_type != .dict and view.container_type != .file and view.container_type != .map and view.container_type != .dir) {
            return ContainerError.InvalidContainerType;
        }

        const total_length = view.total_length;
        const value_start = view.value_offset;

        // Read index_offset from the value payload
        if (value_start >= total_length) return ContainerError.UnexpectedEndOfInput;
        const idx_result = blip.decode(buf[value_start..@intCast(total_length)]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const index_offset = idx_result.value;
        const header_size = value_start + idx_result.bytes_read;

        // Validate index_offset
        if (index_offset >= total_length) return ContainerError.InvalidLength;

        // Jump to index section and read N (pair count)
        const idx_start: usize = @intCast(index_offset);
        if (idx_start >= total_length) return ContainerError.UnexpectedEndOfInput;
        const n_result = blip.decode(buf[idx_start..@intCast(total_length)]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };

        return DictReader{
            .buf = buf,
            .total_length = total_length,
            .header_size = header_size,
            .index_offset = index_offset,
            .count = n_result.value,
            .index_start = idx_start + n_result.bytes_read,
        };
    }

    /// Returns the number of key-value pairs in the dictionary.
    pub fn pairCount(self: DictReader) u64 {
        return self.count;
    }

    /// Get the key container bytes at the given pair index.
    /// Returns the full key TLV container slice.
    pub fn keyAt(self: DictReader, index: u64) ContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        const total: usize = @intCast(self.total_length);
        var pos: usize = self.index_start;

        // Skip index * 2 BLIP-encoded offsets to get to pair[index]'s key offset
        const skip_count = index * 2;
        for (0..skip_count) |_| {
            const skip_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Decode the key offset
        const key_off_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const key_offset: usize = @intCast(key_off_result.value);

        // Jump to key and parse its header to determine extent
        if (key_offset >= total) return ContainerError.IndexOutOfBounds;
        const key_view = try container.parseHeader(self.buf[key_offset..total]);
        const key_total: usize = @intCast(key_view.total_length);
        return self.buf[key_offset .. key_offset + key_total];
    }

    /// Get the value container bytes at the given pair index.
    /// Returns the full value TLV container slice.
    pub fn valueAt(self: DictReader, index: u64) ContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        const total: usize = @intCast(self.total_length);
        var pos: usize = self.index_start;

        // Skip index * 2 BLIP-encoded offsets to get to pair[index]'s key offset
        const skip_count = index * 2;
        for (0..skip_count) |_| {
            const skip_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Skip the key offset
        const key_skip = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        pos += key_skip.bytes_read;

        // Decode the value offset
        const val_off_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const val_offset: usize = @intCast(val_off_result.value);

        // Jump to value and parse its header to determine extent
        if (val_offset >= total) return ContainerError.IndexOutOfBounds;
        const val_view = try container.parseHeader(self.buf[val_offset..total]);
        const val_total: usize = @intCast(val_view.total_length);
        return self.buf[val_offset .. val_offset + val_total];
    }

    /// Linear scan to find a key by its value bytes.
    /// Returns the pair index or null if not found.
    pub fn findKey(self: DictReader, key_bytes: []const u8) ContainerError!?u64 {
        for (0..self.count) |i| {
            const key_container = try self.keyAt(i);
            const extracted = try extractKeyBytes(key_container);
            if (std.mem.eql(u8, extracted, key_bytes)) {
                return i;
            }
        }
        return null;
    }

    /// Verify the xxHash64 integrity check.
    /// Returns true if the stored hash matches the computed hash.
    pub fn verifyHash(self: DictReader) ContainerError!bool {
        const total: usize = @intCast(self.total_length);
        if (total < 8) return ContainerError.InvalidLength;

        const hash_computed = XxHash64.hash(0, self.buf[0 .. total - 8]);
        const hash_stored = std.mem.readInt(u64, self.buf[total - 8 ..][0..8], .little);
        return hash_computed == hash_stored;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "empty dict" {
    const allocator = testing.allocator;
    const pairs = [_]KeyValue{};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    // Should start with DICT sentinel
    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x02), result[1]);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 0), reader.pairCount());
    try testing.expect(try reader.verifyHash());
}

test "single key-value pair (UTF8 key -> RAW value)" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "name");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, &[_]u8{ 0xDE, 0xAD });
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Read back the key
    const key_out = try reader.keyAt(0);
    const key_text = try leaf.readUtf8(key_out);
    try testing.expectEqualSlices(u8, "name", key_text);

    // Read back the value
    const val_out = try reader.valueAt(0);
    const val_data = try leaf.readRaw(val_out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, val_data);
}

test "multiple pairs - verify canonical key ordering is enforced" {
    const allocator = testing.allocator;
    // Keys in canonical byte order: "a" < "b" < "c"
    const key_a = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(key_b);
    const key_c = try leaf.serializeUtf8(allocator, "c");
    defer allocator.free(key_c);

    const val_1 = try leaf.serializeRaw(allocator, "one");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeRaw(allocator, "two");
    defer allocator.free(val_2);
    const val_3 = try leaf.serializeRaw(allocator, "three");
    defer allocator.free(val_3);

    const pairs = [_]KeyValue{
        .{ .key = key_a, .value = val_1 },
        .{ .key = key_b, .value = val_2 },
        .{ .key = key_c, .value = val_3 },
    };
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.pairCount());
    try testing.expect(try reader.verifyHash());
}

test "serializeDict rejects out-of-order keys -> KeysNotSorted" {
    const allocator = testing.allocator;
    const key_b = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(key_b);
    const key_a = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(key_a);

    const val = try leaf.serializeRaw(allocator, "x");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_b, .value = val },
        .{ .key = key_a, .value = val },
    };
    try testing.expectError(ContainerError.KeysNotSorted, serializeDict(allocator, &pairs));
}

test "serializeDict rejects duplicate keys -> DuplicateKey" {
    const allocator = testing.allocator;
    const key_a1 = try leaf.serializeUtf8(allocator, "same");
    defer allocator.free(key_a1);
    const key_a2 = try leaf.serializeUtf8(allocator, "same");
    defer allocator.free(key_a2);

    const val = try leaf.serializeRaw(allocator, "x");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_a1, .value = val },
        .{ .key = key_a2, .value = val },
    };
    try testing.expectError(ContainerError.DuplicateKey, serializeDict(allocator, &pairs));
}

test "DictReader.findKey finds existing key" {
    const allocator = testing.allocator;
    const key_alpha = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(key_alpha);
    const key_beta = try leaf.serializeUtf8(allocator, "beta");
    defer allocator.free(key_beta);

    const val_1 = try leaf.serializeRaw(allocator, "one");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeRaw(allocator, "two");
    defer allocator.free(val_2);

    const pairs = [_]KeyValue{
        .{ .key = key_alpha, .value = val_1 },
        .{ .key = key_beta, .value = val_2 },
    };
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    const idx = (try reader.findKey("beta")).?;
    try testing.expectEqual(@as(u64, 1), idx);
}

test "DictReader.findKey returns null for missing key" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "exists");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    const found = try reader.findKey("missing");
    try testing.expectEqual(@as(?u64, null), found);
}

test "DictReader.keyAt and valueAt for each pair in multi-pair dict" {
    const allocator = testing.allocator;
    const key_a = try leaf.serializeUtf8(allocator, "aaa");
    defer allocator.free(key_a);
    const key_b = try leaf.serializeUtf8(allocator, "bbb");
    defer allocator.free(key_b);
    const key_c = try leaf.serializeUtf8(allocator, "ccc");
    defer allocator.free(key_c);

    const val_1 = try leaf.serializeUtf8(allocator, "first");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeUtf8(allocator, "second");
    defer allocator.free(val_2);
    const val_3 = try leaf.serializeUtf8(allocator, "third");
    defer allocator.free(val_3);

    const pairs = [_]KeyValue{
        .{ .key = key_a, .value = val_1 },
        .{ .key = key_b, .value = val_2 },
        .{ .key = key_c, .value = val_3 },
    };
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);

    // Pair 0
    try testing.expectEqualSlices(u8, "aaa", try leaf.readUtf8(try reader.keyAt(0)));
    try testing.expectEqualSlices(u8, "first", try leaf.readUtf8(try reader.valueAt(0)));

    // Pair 1
    try testing.expectEqualSlices(u8, "bbb", try leaf.readUtf8(try reader.keyAt(1)));
    try testing.expectEqualSlices(u8, "second", try leaf.readUtf8(try reader.valueAt(1)));

    // Pair 2
    try testing.expectEqualSlices(u8, "ccc", try leaf.readUtf8(try reader.keyAt(2)));
    try testing.expectEqualSlices(u8, "third", try leaf.readUtf8(try reader.valueAt(2)));
}

test "keyAt out of bounds -> IndexOutOfBounds" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.keyAt(1));
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.keyAt(100));
}

test "valueAt out of bounds -> IndexOutOfBounds" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.valueAt(1));
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.valueAt(100));
}

test "FILE with all 3 required keys - successful round-trip" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "bina" < "path" < "xh64"
    const key_bina = try leaf.serializeUtf8(allocator, "bina");
    defer allocator.free(key_bina);
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val_bina = try leaf.serializeRaw(allocator, "Hello, world!\n");
    defer allocator.free(val_bina);
    const val_path = try leaf.serializeUtf8(allocator, "hello.txt");
    defer allocator.free(val_path);
    const hash_bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const val_xh64 = try leaf.serializeRaw(allocator, &hash_bytes);
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_bina, .value = val_bina },
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    const result = try serializeFile(allocator, &pairs);
    defer allocator.free(result);

    // Verify FILE sentinel
    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x05), result[1]);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify we can find all required keys
    try testing.expect((try reader.findKey("bina")) != null);
    try testing.expect((try reader.findKey("path")) != null);
    try testing.expect((try reader.findKey("xh64")) != null);
}

test "FILE missing 'path' -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_bina = try leaf.serializeUtf8(allocator, "bina");
    defer allocator.free(key_bina);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val = try leaf.serializeRaw(allocator, "data");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_bina, .value = val },
        .{ .key = key_xh64, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeFile(allocator, &pairs));
}

test "FILE missing 'bina' -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val = try leaf.serializeRaw(allocator, "data");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_path, .value = val },
        .{ .key = key_xh64, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeFile(allocator, &pairs));
}

test "FILE missing 'xh64' -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_bina = try leaf.serializeUtf8(allocator, "bina");
    defer allocator.free(key_bina);
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);

    const val = try leaf.serializeRaw(allocator, "data");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_bina, .value = val },
        .{ .key = key_path, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeFile(allocator, &pairs));
}

test "verifyHash valid for dict" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expect(try reader.verifyHash());
}

test "verifyHash detects corruption in dict" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    // Corrupt a byte in the middle (not the hash itself)
    const corrupt_pos = result.len / 2;
    result[corrupt_pos] ^= 0xFF;

    const reader = try DictReader.init(result);
    const valid = try reader.verifyHash();
    try testing.expect(!valid);
}

test "round-trip: serialize dict -> DictReader -> extract all pairs -> compare" {
    const allocator = testing.allocator;

    const keys_text = [_][]const u8{ "alpha", "beta", "gamma", "omega" };
    const vals_text = [_][]const u8{ "first", "second", "third", "fourth" };

    var keys: [4][]u8 = undefined;
    var vals: [4][]u8 = undefined;
    var k_count: usize = 0;
    var v_count: usize = 0;

    defer {
        for (keys[0..k_count]) |k| allocator.free(k);
        for (vals[0..v_count]) |v| allocator.free(v);
    }

    for (keys_text) |kt| {
        keys[k_count] = try leaf.serializeUtf8(allocator, kt);
        k_count += 1;
    }
    for (vals_text) |vt| {
        vals[v_count] = try leaf.serializeUtf8(allocator, vt);
        v_count += 1;
    }

    var pairs: [4]KeyValue = undefined;
    for (0..4) |i| {
        pairs[i] = .{ .key = keys[i], .value = vals[i] };
    }

    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 4), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    for (keys_text, vals_text, 0..) |kt, vt, i| {
        const key_out = try reader.keyAt(@intCast(i));
        const val_out = try reader.valueAt(@intCast(i));
        try testing.expectEqualSlices(u8, kt, try leaf.readUtf8(key_out));
        try testing.expectEqualSlices(u8, vt, try leaf.readUtf8(val_out));
    }
}

test "key ordering spec examples: 'a' < 'aa' < 'ab' < 'b'" {
    const allocator = testing.allocator;

    const key_a = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(key_a);
    const key_aa = try leaf.serializeUtf8(allocator, "aa");
    defer allocator.free(key_aa);
    const key_ab = try leaf.serializeUtf8(allocator, "ab");
    defer allocator.free(key_ab);
    const key_b = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(key_b);

    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    // This should succeed (correct canonical order)
    const pairs = [_]KeyValue{
        .{ .key = key_a, .value = val },
        .{ .key = key_aa, .value = val },
        .{ .key = key_ab, .value = val },
        .{ .key = key_b, .value = val },
    };
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 4), reader.pairCount());

    // Verify key order from reading
    try testing.expectEqualSlices(u8, "a", try extractKeyBytes(try reader.keyAt(0)));
    try testing.expectEqualSlices(u8, "aa", try extractKeyBytes(try reader.keyAt(1)));
    try testing.expectEqualSlices(u8, "ab", try extractKeyBytes(try reader.keyAt(2)));
    try testing.expectEqualSlices(u8, "b", try extractKeyBytes(try reader.keyAt(3)));
}

test "extractKeyBytes for UTF8 key" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(key);

    const bytes = try extractKeyBytes(key);
    try testing.expectEqualSlices(u8, "hello", bytes);
}

test "extractKeyBytes for RAW key" {
    const allocator = testing.allocator;
    const key = try leaf.serializeRaw(allocator, &[_]u8{ 0x01, 0x02, 0x03 });
    defer allocator.free(key);

    const bytes = try extractKeyBytes(key);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, bytes);
}

test "DictReader works for FILE containers" {
    const allocator = testing.allocator;

    const key_bina = try leaf.serializeUtf8(allocator, "bina");
    defer allocator.free(key_bina);
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val_bina = try leaf.serializeRaw(allocator, "file content");
    defer allocator.free(val_bina);
    const val_path = try leaf.serializeUtf8(allocator, "src/main.zig");
    defer allocator.free(val_path);
    const val_xh64 = try leaf.serializeRaw(allocator, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 });
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_bina, .value = val_bina },
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    const result = try serializeFile(allocator, &pairs);
    defer allocator.free(result);

    // DictReader should work for FILE type
    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Find and verify the path value
    const path_idx = (try reader.findKey("path")).?;
    const path_val = try reader.valueAt(path_idx);
    try testing.expectEqualSlices(u8, "src/main.zig", try leaf.readUtf8(path_val));
}

test "dict with many pairs (10+) verifying all are accessible" {
    const allocator = testing.allocator;

    // Create 12 key-value pairs with keys in canonical byte order
    const key_names = [_][]const u8{
        "aaa", "bbb", "ccc", "ddd", "eee", "fff",
        "ggg", "hhh", "iii", "jjj", "kkk", "lll",
    };
    const val_texts = [_][]const u8{
        "v01", "v02", "v03", "v04", "v05", "v06",
        "v07", "v08", "v09", "v10", "v11", "v12",
    };

    var keys: [12][]u8 = undefined;
    var vals: [12][]u8 = undefined;
    var k_count: usize = 0;
    var v_count: usize = 0;
    defer {
        for (keys[0..k_count]) |k| allocator.free(k);
        for (vals[0..v_count]) |v| allocator.free(v);
    }

    for (key_names) |kn| {
        keys[k_count] = try leaf.serializeUtf8(allocator, kn);
        k_count += 1;
    }
    for (val_texts) |vt| {
        vals[v_count] = try leaf.serializeUtf8(allocator, vt);
        v_count += 1;
    }

    var pairs: [12]KeyValue = undefined;
    for (0..12) |i| {
        pairs[i] = .{ .key = keys[i], .value = vals[i] };
    }

    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 12), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify all 12 pairs
    for (key_names, val_texts, 0..) |kn, vt, i| {
        const key_out = try reader.keyAt(@intCast(i));
        const val_out = try reader.valueAt(@intCast(i));
        try testing.expectEqualSlices(u8, kn, try leaf.readUtf8(key_out));
        try testing.expectEqualSlices(u8, vt, try leaf.readUtf8(val_out));
    }

    // Also verify findKey for a few
    try testing.expectEqual(@as(?u64, 0), try reader.findKey("aaa"));
    try testing.expectEqual(@as(?u64, 5), try reader.findKey("fff"));
    try testing.expectEqual(@as(?u64, 11), try reader.findKey("lll"));
    try testing.expectEqual(@as(?u64, null), try reader.findKey("zzz"));
}

test "DictReader rejects non-dict container" {
    const allocator = testing.allocator;
    const utf8_buf = try leaf.serializeUtf8(allocator, "not a dict");
    defer allocator.free(utf8_buf);

    try testing.expectError(ContainerError.InvalidContainerType, DictReader.init(utf8_buf));
}

test "empty dict: total length matches buffer length" {
    const allocator = testing.allocator;
    const pairs = [_]KeyValue{};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, result.len), reader.total_length);
}

test "FILE with additional optional keys" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "bina" < "mode" < "path" < "xh64"
    const key_bina = try leaf.serializeUtf8(allocator, "bina");
    defer allocator.free(key_bina);
    const key_mode = try leaf.serializeUtf8(allocator, "mode");
    defer allocator.free(key_mode);
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val_bina = try leaf.serializeRaw(allocator, "content");
    defer allocator.free(val_bina);
    const val_mode = try leaf.serializeRaw(allocator, &[_]u8{ 0x01, 0xA4 }); // 0o644
    defer allocator.free(val_mode);
    const val_path = try leaf.serializeUtf8(allocator, "README.md");
    defer allocator.free(val_path);
    const val_xh64 = try leaf.serializeRaw(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_bina, .value = val_bina },
        .{ .key = key_mode, .value = val_mode },
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    const result = try serializeFile(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 4), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify optional key "mode" is accessible
    const mode_idx = (try reader.findKey("mode")).?;
    const mode_val = try reader.valueAt(mode_idx);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xA4 }, try leaf.readRaw(mode_val));
}

test "verifyHash with corrupted hash bytes in dict" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeRaw(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    // Corrupt the last byte (part of the hash)
    result[result.len - 1] ^= 0x01;

    const reader = try DictReader.init(result);
    const valid = try reader.verifyHash();
    try testing.expect(!valid);
}

test "dict with RAW keys" {
    const allocator = testing.allocator;

    // RAW keys: 0x01 < 0x02 < 0x03
    const key_1 = try leaf.serializeRaw(allocator, &[_]u8{0x01});
    defer allocator.free(key_1);
    const key_2 = try leaf.serializeRaw(allocator, &[_]u8{0x02});
    defer allocator.free(key_2);
    const key_3 = try leaf.serializeRaw(allocator, &[_]u8{0x03});
    defer allocator.free(key_3);

    const val = try leaf.serializeUtf8(allocator, "val");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_1, .value = val },
        .{ .key = key_2, .value = val },
        .{ .key = key_3, .value = val },
    };
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify RAW key bytes
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, try extractKeyBytes(try reader.keyAt(0)));
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, try extractKeyBytes(try reader.keyAt(1)));
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, try extractKeyBytes(try reader.keyAt(2)));
}

// =============================================================================
// DIR container tests
// =============================================================================

test "DIR with path+xh64 round-trip (sentinel 0x81 0x07, hash verifies)" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "path" < "xh64"
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val_path = try leaf.serializeUtf8(allocator, "src/lib");
    defer allocator.free(val_path);
    const hash_bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };
    const val_xh64 = try leaf.serializeRaw(allocator, &hash_bytes);
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    // Verify DIR sentinel
    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x07), result[1]);

    // DictReader should work for DIR type
    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 2), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify keys
    try testing.expect((try reader.findKey("path")) != null);
    try testing.expect((try reader.findKey("xh64")) != null);
}

test "DIR missing path -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);
    const val = try leaf.serializeRaw(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_xh64, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeDir(allocator, &pairs));
}

test "DIR missing xh64 -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const val = try leaf.serializeUtf8(allocator, "some/dir");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_path, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeDir(allocator, &pairs));
}

test "DIR with optional metadata keys (mode, mtime, owner)" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "mode" < "mtime" < "owner" < "path" < "xh64"
    const key_mode = try leaf.serializeUtf8(allocator, "mode");
    defer allocator.free(key_mode);
    const key_mtime = try leaf.serializeUtf8(allocator, "mtime");
    defer allocator.free(key_mtime);
    const key_owner = try leaf.serializeUtf8(allocator, "owner");
    defer allocator.free(key_owner);
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    var mode_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mode_bytes, 0o755, .little);
    const val_mode = try leaf.serializeRaw(allocator, &mode_bytes);
    defer allocator.free(val_mode);

    var mtime_bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &mtime_bytes, 1708787200_000_000_000, .little);
    const val_mtime = try leaf.serializeRaw(allocator, &mtime_bytes);
    defer allocator.free(val_mtime);

    const val_owner = try leaf.serializeUtf8(allocator, "peter");
    defer allocator.free(val_owner);
    const val_path = try leaf.serializeUtf8(allocator, "src/lib");
    defer allocator.free(val_path);
    const val_xh64 = try leaf.serializeRaw(allocator, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 });
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_mode, .value = val_mode },
        .{ .key = key_mtime, .value = val_mtime },
        .{ .key = key_owner, .value = val_owner },
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 5), reader.pairCount());
    try testing.expect(try reader.verifyHash());

    // Verify optional metadata is accessible
    const mode_idx = (try reader.findKey("mode")).?;
    const mode_val = try leaf.readRaw(try reader.valueAt(mode_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, mode_val[0..2], .little));

    const owner_idx = (try reader.findKey("owner")).?;
    const owner_val = try leaf.readUtf8(try reader.valueAt(owner_idx));
    try testing.expectEqualSlices(u8, "peter", owner_val);
}

test "DIR does NOT require bina" {
    const allocator = testing.allocator;

    // DIR with just path + xh64 (no bina) should succeed
    const key_path = try leaf.serializeUtf8(allocator, "path");
    defer allocator.free(key_path);
    const key_xh64 = try leaf.serializeUtf8(allocator, "xh64");
    defer allocator.free(key_xh64);

    const val_path = try leaf.serializeUtf8(allocator, "mydir");
    defer allocator.free(val_path);
    const val_xh64 = try leaf.serializeRaw(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val_xh64);

    const pairs = [_]KeyValue{
        .{ .key = key_path, .value = val_path },
        .{ .key = key_xh64, .value = val_xh64 },
    };
    // This should NOT return MissingRequiredKey (bina is NOT required for DIR)
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x07), result[1]);
}
