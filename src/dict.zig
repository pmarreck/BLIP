const std = @import("std");
const Allocator = std.mem.Allocator;
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const csum_mod = @import("checksum.zig");
const leaf = @import("leaf.zig");
const testing = std.testing;

const ContainerError = container.ContainerError;
const ContainerTypeId = ct.ContainerTypeId;
const ChecksumId = ct.ChecksumId;
const LPOptions = container.LPOptions;
const LPContainerView = container.LPContainerView;
const LPContainerError = container.LPContainerError;

/// A pre-serialized key-value pair for dictionary construction.
/// Both key and value must already be complete LP containers.
pub const KeyValue = struct {
    key: []const u8, // pre-serialized UTF8 or DATA container bytes
    value: []const u8, // pre-serialized container of any type
};

/// Extract the value payload bytes from a key container (UTF8 or DATA).
/// Strips the LP header and returns just the key text/bytes.
pub fn extractKeyBytes(key_container: []const u8) LPContainerError![]const u8 {
    const view = try container.parseLPHeader(key_container);
    return view.payloadSlice();
}

/// Compare two key byte slices in canonical byte order (memcmp/lexicographic).
/// Returns .lt, .eq, or .gt.
fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Internal helper: serialize a dict-like container (DICT, MAP, or DIR) in v2 LP format.
///
/// v2 LP layout:
///   [BLIP(total)] [TYPE attr] [opt CSUM attr] [VAL sentinel]
///   [BLIP(index_offset)] [key0 val0 key1 val1...] [INDEX_SECTION] [checksum?]
///
/// The VAL payload is: [BLIP(index_offset)] [key-value data...] [INDEX_SECTION]
/// Checksum bytes (if any) are appended after the index section, still inside
/// the container's total length.
fn serializeDictLike(
    allocator: Allocator,
    pairs: []const KeyValue,
    type_id: ContainerTypeId,
    options: LPOptions,
) (Allocator.Error || LPContainerError)![]u8 {
    const n: u64 = pairs.len;
    const csum_size: u64 = if (options.csum_id) |id| ct.checksumLength(id) else 0;

    // Compute total data size (sum of all key + value byte lengths)
    var data_size: u64 = 0;
    for (pairs) |pair| {
        data_size += pair.key.len;
        data_size += pair.value.len;
    }

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

    // Fixpoint iteration to resolve self-referential sizes.
    //
    // For a given I_size (BLIP encoding size of index_offset):
    //   1. index_section_size = BLIP(N) + sum(BLIP(offset[k]))
    //   2. val_payload_size = I_size + data_size + index_section_size
    //   3. total = computeLPLength(type_id, val_payload_size, options)
    //   4. val_offset = total - val_payload_size - csum_size
    //   5. element offsets = val_offset + I_size + cumulative[k]
    //   6. index_offset = val_offset + I_size + data_size
    //   7. I_size_new = BLIP_size(index_offset)
    //
    // We iterate until I_size and index_section_size stabilize.

    var I_size: usize = 1;
    var total: u64 = undefined;
    var index_offset: u64 = undefined;

    for (0..10) |_| {
        // Start with an estimated val_offset (use 0 initially, will converge)
        var val_offset: u64 = 0;

        // Inner loop: converge on val_offset for the current I_size
        for (0..10) |_| {
            // Compute key/value offsets from container start
            var running_offset: u64 = val_offset + I_size;
            for (pairs, 0..) |pair, k| {
                offset_storage[k * 2] = running_offset; // key offset
                running_offset += pair.key.len;
                offset_storage[k * 2 + 1] = running_offset; // value offset
                running_offset += pair.value.len;
            }
            index_offset = running_offset;

            // Compute index section size: BLIP(N) + sum of interleaved BLIP(key_off) BLIP(val_off)
            var index_section_size: u64 = blip.encodedSize(n);
            for (offset_storage[0..offset_count]) |off| {
                index_section_size += blip.encodedSize(off);
            }

            // Compute val_payload_size, total, and new val_offset
            const val_payload_size: u64 = I_size + data_size + index_section_size;
            total = container.computeLPLength(type_id, val_payload_size, options);
            const new_val_offset: u64 = total - val_payload_size - csum_size;

            if (new_val_offset == val_offset) break;
            val_offset = new_val_offset;
        }

        // Check if I_size is stable
        const I_size_new = blip.encodedSize(index_offset);
        if (I_size_new == I_size) break;
        I_size = I_size_new;
    }

    // Allocate the exact buffer
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);

    // Write LP header
    var pos: usize = try container.writeLPHeader(buf, type_id, total, options);

    // Write BLIP(index_offset) - first thing in VAL payload
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

    // Write checksum if requested
    if (options.csum_id) |csum_id| {
        const csum_len = ct.checksumLength(csum_id);
        const hash = csum_mod.compute(csum_id, buf[0..pos]);
        @memcpy(buf[pos..][0..csum_len], hash[0..csum_len]);
        pos += csum_len;
    }

    std.debug.assert(pos == total);

    return buf;
}

/// Serialize an ordered set of key-value pairs as a DICT container (type_id=2).
/// Keys must already be in canonical byte order and must be unique.
/// No checksum by default (inner container convention).
/// Caller owns returned memory.
pub fn serializeDict(allocator: Allocator, pairs: []const KeyValue) (Allocator.Error || LPContainerError)![]u8 {
    try validateKeyOrder(pairs);
    return serializeDictLike(allocator, pairs, .dict, .{});
}

/// Serialize an ordered set of key-value pairs as a DICT container with custom LP options.
/// Keys must already be in canonical byte order and must be unique.
/// Caller owns returned memory.
pub fn serializeDictWithOptions(allocator: Allocator, pairs: []const KeyValue, options: LPOptions) (Allocator.Error || LPContainerError)![]u8 {
    try validateKeyOrder(pairs);
    return serializeDictLike(allocator, pairs, .dict, options);
}

/// Serialize an ordered set of key-value pairs as a DIR container (type_id=7).
/// Same as serializeDict but validates required keys: "pa" and "xh".
/// Does NOT require content (directories have no binary content).
/// No checksum by default.
/// Caller owns returned memory.
pub fn serializeDir(allocator: Allocator, pairs: []const KeyValue) (Allocator.Error || LPContainerError)![]u8 {
    try validateKeyOrder(pairs);
    try validateDirRequiredKeys(pairs);
    return serializeDictLike(allocator, pairs, .dir, .{});
}

/// Serialize an ordered set of key-value pairs as a DIR container with custom LP options.
/// Caller owns returned memory.
pub fn serializeDirWithOptions(allocator: Allocator, pairs: []const KeyValue, options: LPOptions) (Allocator.Error || LPContainerError)![]u8 {
    try validateKeyOrder(pairs);
    try validateDirRequiredKeys(pairs);
    return serializeDictLike(allocator, pairs, .dir, options);
}

/// Validate that keys in the pairs array are in canonical byte order and unique.
fn validateKeyOrder(pairs: []const KeyValue) LPContainerError!void {
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

/// Validate that required DIR keys ("pa" and "xh") are present.
fn validateDirRequiredKeys(pairs: []const KeyValue) LPContainerError!void {
    var has_pa = false;
    var has_xh = false;

    for (pairs) |pair| {
        const key_bytes = try extractKeyBytes(pair.key);
        if (std.mem.eql(u8, key_bytes, "pa")) has_pa = true;
        if (std.mem.eql(u8, key_bytes, "xh")) has_xh = true;
    }

    if (!has_pa) return ContainerError.MissingRequiredKey;
    if (!has_xh) return ContainerError.MissingRequiredKey;
}

/// Reader for DICT, MAP, and DIR containers in v2 LP format.
/// Provides random access to key-value pairs via the index section.
pub const DictReader = struct {
    lp_view: LPContainerView,
    index_offset: u64,
    count: u64,
    /// Byte offset from container start to the first key-value pair (after BLIP(index_offset))
    header_size: usize,
    /// Byte offset from container start to the first index entry (after BLIP(N))
    index_start: usize,

    /// Parse a DICT, MAP, or DIR container from a buffer.
    /// buf must start at the container's first byte (BLIP total_length).
    pub fn init(buf: []const u8) LPContainerError!DictReader {
        const lp = try container.parseLPHeader(buf);
        if (lp.type_id != .dict and lp.type_id != .map and lp.type_id != .dir) {
            return ContainerError.InvalidContainerType;
        }

        const total: usize = @intCast(lp.total_length);

        // Read BLIP(index_offset) from start of payload
        const payload = lp.payloadSlice();
        if (payload.len == 0) return ContainerError.UnexpectedEndOfInput;
        const idx_result = blip.decode(payload) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const index_offset = idx_result.value;
        const header_size = lp.val_offset + idx_result.bytes_read;

        // Validate index_offset
        if (index_offset >= total) return ContainerError.InvalidLength;

        // Jump to index section and read N (pair count)
        const idx_start: usize = @intCast(index_offset);
        if (idx_start >= total) return ContainerError.UnexpectedEndOfInput;
        const n_result = blip.decode(buf[idx_start..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };

        return DictReader{
            .lp_view = lp,
            .index_offset = index_offset,
            .count = n_result.value,
            .header_size = header_size,
            .index_start = idx_start + n_result.bytes_read,
        };
    }

    /// Returns the number of key-value pairs in the dictionary.
    pub fn pairCount(self: DictReader) u64 {
        return self.count;
    }

    /// Get the key container bytes at the given pair index.
    /// Returns the full key LP container slice.
    pub fn keyAt(self: DictReader, index: u64) LPContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        const total: usize = @intCast(self.lp_view.total_length);
        var pos: usize = self.index_start;

        // Skip index * 2 BLIP-encoded offsets to get to pair[index]'s key offset
        const skip_count = index * 2;
        for (0..skip_count) |_| {
            const skip_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Decode the key offset
        const key_off_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const key_offset: usize = @intCast(key_off_result.value);

        // Jump to key and parse its LP header to determine extent
        if (key_offset >= total) return ContainerError.IndexOutOfBounds;
        const key_view = try container.parseLPHeader(self.lp_view.buf[key_offset..total]);
        const key_total: usize = @intCast(key_view.total_length);
        return self.lp_view.buf[key_offset .. key_offset + key_total];
    }

    /// Get the value container bytes at the given pair index.
    /// Returns the full value LP container slice.
    pub fn valueAt(self: DictReader, index: u64) LPContainerError![]const u8 {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        const total: usize = @intCast(self.lp_view.total_length);
        var pos: usize = self.index_start;

        // Skip index * 2 BLIP-encoded offsets to get to pair[index]'s key offset
        const skip_count = index * 2;
        for (0..skip_count) |_| {
            const skip_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Skip the key offset
        const key_skip = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        pos += key_skip.bytes_read;

        // Decode the value offset
        const val_off_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const val_offset: usize = @intCast(val_off_result.value);

        // Jump to value and parse its LP header to determine extent
        if (val_offset >= total) return ContainerError.IndexOutOfBounds;
        const val_view = try container.parseLPHeader(self.lp_view.buf[val_offset..total]);
        const val_total: usize = @intCast(val_view.total_length);
        return self.lp_view.buf[val_offset .. val_offset + val_total];
    }

    /// Linear scan to find a key by its value bytes.
    /// Returns the pair index or null if not found.
    pub fn findKey(self: DictReader, key_bytes: []const u8) LPContainerError!?u64 {
        for (0..self.count) |i| {
            const key_container = try self.keyAt(i);
            const extracted = try extractKeyBytes(key_container);
            if (std.mem.eql(u8, extracted, key_bytes)) {
                return i;
            }
        }
        return null;
    }

    /// Verify the checksum of this dict container.
    /// If the container has no CSUM attribute, returns true (nothing to check).
    /// If CSUM is present, recomputes the checksum and compares.
    pub fn verifyChecksum(self: DictReader) LPContainerError!bool {
        const csum_id = self.lp_view.csum_id orelse return true;
        const csum_len = ct.checksumLength(csum_id);
        const total: usize = @intCast(self.lp_view.total_length);
        const csum_offset = total - csum_len;
        return csum_mod.verify(csum_id, self.lp_view.buf[0..csum_offset], self.lp_view.checksumSlice());
    }

    /// Legacy alias: equivalent to verifyChecksum().
    /// Deprecated: use verifyChecksum() instead.
    pub const verifyHash = verifyChecksum;
};

// =============================================================================
// Tests
// =============================================================================

test "empty dict" {
    const allocator = testing.allocator;
    const pairs = [_]KeyValue{};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 0), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());
    // total_length matches buffer length
    try testing.expectEqual(@as(u64, result.len), reader.lp_view.total_length);
}

test "single key-value pair (UTF8 key -> DATA value)" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "name");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, &[_]u8{ 0xDE, 0xAD });
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());

    // Read back the key
    const key_out = try reader.keyAt(0);
    const key_text = try leaf.readUtf8(key_out);
    try testing.expectEqualSlices(u8, "name", key_text);

    // Read back the value
    const val_out = try reader.valueAt(0);
    const val_data = try leaf.readData(val_out);
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

    const val_1 = try leaf.serializeData(allocator, "one");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeData(allocator, "two");
    defer allocator.free(val_2);
    const val_3 = try leaf.serializeData(allocator, "three");
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
    try testing.expect(try reader.verifyChecksum());
}

test "serializeDict rejects out-of-order keys -> KeysNotSorted" {
    const allocator = testing.allocator;
    const key_b = try leaf.serializeUtf8(allocator, "b");
    defer allocator.free(key_b);
    const key_a = try leaf.serializeUtf8(allocator, "a");
    defer allocator.free(key_a);

    const val = try leaf.serializeData(allocator, "x");
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

    const val = try leaf.serializeData(allocator, "x");
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

    const val_1 = try leaf.serializeData(allocator, "one");
    defer allocator.free(val_1);
    const val_2 = try leaf.serializeData(allocator, "two");
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
    const val = try leaf.serializeData(allocator, "v");
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
    const val = try leaf.serializeData(allocator, "v");
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
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.valueAt(1));
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.valueAt(100));
}

test "verifyChecksum returns true for no checksum (default)" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expect(try reader.verifyChecksum());
}

test "dict with BLAKE3-128 checksum" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDictWithOptions(allocator, &pairs, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify elements still accessible
    const key_out = try reader.keyAt(0);
    try testing.expectEqualSlices(u8, "key", try leaf.readUtf8(key_out));
    const val_out = try reader.valueAt(0);
    try testing.expectEqualSlices(u8, "value", try leaf.readData(val_out));
}

test "checksum corruption detection" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDictWithOptions(allocator, &pairs, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    // Corrupt a byte in the data section (not the checksum itself)
    const reader_before = try DictReader.init(result);
    const corrupt_pos = reader_before.lp_view.val_offset + 1;
    result[corrupt_pos] ^= 0xFF;

    const reader = try DictReader.init(result);
    const valid = try reader.verifyChecksum();
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
    try testing.expect(try reader.verifyChecksum());

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

    const val = try leaf.serializeData(allocator, "v");
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

test "extractKeyBytes for DATA key" {
    const allocator = testing.allocator;
    const key = try leaf.serializeData(allocator, &[_]u8{ 0x01, 0x02, 0x03 });
    defer allocator.free(key);

    const bytes = try extractKeyBytes(key);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, bytes);
}

test "dict with many pairs (12+) verifying all are accessible" {
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
    try testing.expect(try reader.verifyChecksum());

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

test "dict with DATA keys" {
    const allocator = testing.allocator;

    // DATA keys: 0x01 < 0x02 < 0x03
    const key_1 = try leaf.serializeData(allocator, &[_]u8{0x01});
    defer allocator.free(key_1);
    const key_2 = try leaf.serializeData(allocator, &[_]u8{0x02});
    defer allocator.free(key_2);
    const key_3 = try leaf.serializeData(allocator, &[_]u8{0x03});
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
    try testing.expect(try reader.verifyChecksum());

    // Verify DATA key bytes
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, try extractKeyBytes(try reader.keyAt(0)));
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, try extractKeyBytes(try reader.keyAt(1)));
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, try extractKeyBytes(try reader.keyAt(2)));
}

test "total_length matches buffer length" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const lp = try container.parseLPHeader(result);
    try testing.expectEqual(@as(u64, result.len), lp.total_length);
    try testing.expectEqual(ContainerTypeId.dict, lp.type_id);
}

// =============================================================================
// DIR container tests
// =============================================================================

test "DIR with pa+xh round-trip (type_id=dir, checksum verifies)" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "pa" < "xh"
    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const key_xh = try leaf.serializeUtf8(allocator, "xh");
    defer allocator.free(key_xh);

    const val_pa = try leaf.serializeUtf8(allocator, "src/lib");
    defer allocator.free(val_pa);
    const hash_bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };
    const val_xh = try leaf.serializeData(allocator, &hash_bytes);
    defer allocator.free(val_xh);

    const pairs = [_]KeyValue{
        .{ .key = key_pa, .value = val_pa },
        .{ .key = key_xh, .value = val_xh },
    };
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    // Verify DIR type_id via LP header
    const lp = try container.parseLPHeader(result);
    try testing.expectEqual(ContainerTypeId.dir, lp.type_id);

    // DictReader should work for DIR type
    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 2), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify keys
    try testing.expect((try reader.findKey("pa")) != null);
    try testing.expect((try reader.findKey("xh")) != null);
}

test "DIR missing pa -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_xh = try leaf.serializeUtf8(allocator, "xh");
    defer allocator.free(key_xh);
    const val = try leaf.serializeData(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_xh, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeDir(allocator, &pairs));
}

test "DIR missing xh -> MissingRequiredKey" {
    const allocator = testing.allocator;

    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const val = try leaf.serializeUtf8(allocator, "some/dir");
    defer allocator.free(val);

    const pairs = [_]KeyValue{
        .{ .key = key_pa, .value = val },
    };
    try testing.expectError(ContainerError.MissingRequiredKey, serializeDir(allocator, &pairs));
}

test "DIR with optional 2-char metadata keys (md, mt, un)" {
    const allocator = testing.allocator;

    // Keys in canonical byte order: "md" < "mt" < "pa" < "un" < "xh"
    const key_md = try leaf.serializeUtf8(allocator, "md");
    defer allocator.free(key_md);
    const key_mt = try leaf.serializeUtf8(allocator, "mt");
    defer allocator.free(key_mt);
    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const key_un = try leaf.serializeUtf8(allocator, "un");
    defer allocator.free(key_un);
    const key_xh = try leaf.serializeUtf8(allocator, "xh");
    defer allocator.free(key_xh);

    var mode_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &mode_bytes, 0o755, .little);
    const val_md = try leaf.serializeData(allocator, &mode_bytes);
    defer allocator.free(val_md);

    var mtime_bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &mtime_bytes, 1708787200_000_000_000, .little);
    const val_mt = try leaf.serializeData(allocator, &mtime_bytes);
    defer allocator.free(val_mt);

    const val_pa = try leaf.serializeUtf8(allocator, "src/lib");
    defer allocator.free(val_pa);
    const val_un = try leaf.serializeUtf8(allocator, "peter");
    defer allocator.free(val_un);
    const val_xh = try leaf.serializeData(allocator, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 });
    defer allocator.free(val_xh);

    const pairs = [_]KeyValue{
        .{ .key = key_md, .value = val_md },
        .{ .key = key_mt, .value = val_mt },
        .{ .key = key_pa, .value = val_pa },
        .{ .key = key_un, .value = val_un },
        .{ .key = key_xh, .value = val_xh },
    };
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 5), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify optional metadata is accessible
    const md_idx = (try reader.findKey("md")).?;
    const md_val = try leaf.readData(try reader.valueAt(md_idx));
    try testing.expectEqual(@as(u16, 0o755), std.mem.readInt(u16, md_val[0..2], .little));

    const un_idx = (try reader.findKey("un")).?;
    const un_val = try leaf.readUtf8(try reader.valueAt(un_idx));
    try testing.expectEqualSlices(u8, "peter", un_val);
}

test "DIR does NOT require content" {
    const allocator = testing.allocator;

    // DIR with just pa + xh should succeed
    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const key_xh = try leaf.serializeUtf8(allocator, "xh");
    defer allocator.free(key_xh);

    const val_pa = try leaf.serializeUtf8(allocator, "mydir");
    defer allocator.free(val_pa);
    const val_xh = try leaf.serializeData(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val_xh);

    const pairs = [_]KeyValue{
        .{ .key = key_pa, .value = val_pa },
        .{ .key = key_xh, .value = val_xh },
    };
    const result = try serializeDir(allocator, &pairs);
    defer allocator.free(result);

    // Verify DIR type_id
    const lp = try container.parseLPHeader(result);
    try testing.expectEqual(ContainerTypeId.dir, lp.type_id);
}

test "DIR with BLAKE3-128 checksum" {
    const allocator = testing.allocator;

    const key_pa = try leaf.serializeUtf8(allocator, "pa");
    defer allocator.free(key_pa);
    const key_xh = try leaf.serializeUtf8(allocator, "xh");
    defer allocator.free(key_xh);

    const val_pa = try leaf.serializeUtf8(allocator, "mydir");
    defer allocator.free(val_pa);
    const val_xh = try leaf.serializeData(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });
    defer allocator.free(val_xh);

    const pairs = [_]KeyValue{
        .{ .key = key_pa, .value = val_pa },
        .{ .key = key_xh, .value = val_xh },
    };
    const result = try serializeDirWithOptions(allocator, &pairs, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expectEqual(@as(u64, 2), reader.pairCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify keys still accessible
    try testing.expect((try reader.findKey("pa")) != null);
    try testing.expect((try reader.findKey("xh")) != null);
}

test "verifyChecksum with corrupted checksum bytes in dict" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "k");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "v");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDictWithOptions(allocator, &pairs, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    // Corrupt the last byte (part of the checksum)
    result[result.len - 1] ^= 0x01;

    const reader = try DictReader.init(result);
    const valid = try reader.verifyChecksum();
    try testing.expect(!valid);
}

test "verifyHash legacy alias works" {
    const allocator = testing.allocator;
    const key = try leaf.serializeUtf8(allocator, "key");
    defer allocator.free(key);
    const val = try leaf.serializeData(allocator, "value");
    defer allocator.free(val);

    const pairs = [_]KeyValue{.{ .key = key, .value = val }};
    const result = try serializeDict(allocator, &pairs);
    defer allocator.free(result);

    const reader = try DictReader.init(result);
    try testing.expect(try reader.verifyHash());
}
