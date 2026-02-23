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

/// Serialize an ordered array of pre-serialized container elements.
/// Each element in `elements` must already be a complete TLV container (e.g.,
/// the output of leaf.serializeUtf8, leaf.serializeRaw, or serializeArray).
/// Caller owns returned memory.
pub fn serializeArray(allocator: Allocator, elements: []const []const u8) (Allocator.Error || ContainerError)![]u8 {
    const n: u64 = elements.len;

    // Compute total data size (sum of all element byte lengths)
    var data_size: u64 = 0;
    for (elements) |elem| {
        data_size += elem.len;
    }

    // Fixpoint iteration to determine S (total encoding size) and I (index_offset encoding size)
    var S: usize = 1; // initial guess for blip.encodedSize(total)
    var I: usize = 1; // initial guess for blip.encodedSize(index_offset)

    var total: u64 = undefined;
    var index_offset: u64 = undefined;
    var offsets: [1024]u64 = undefined; // stack buffer for element offsets; will use allocator if needed
    var heap_offsets: ?[]u64 = null;
    defer if (heap_offsets) |ho| allocator.free(ho);

    // Get offset storage
    const offset_storage: []u64 = if (elements.len <= 1024)
        offsets[0..elements.len]
    else blk: {
        heap_offsets = try allocator.alloc(u64, elements.len);
        break :blk heap_offsets.?;
    };

    for (0..10) |_| {
        const header_size: u64 = 2 + S + I;

        // Compute element offsets from container start
        var running_offset: u64 = header_size;
        for (elements, 0..) |elem, k| {
            offset_storage[k] = running_offset;
            running_offset += elem.len;
        }

        index_offset = running_offset; // = header_size + data_size

        // Compute index section size: BLIP(N) + sum of BLIP(off_k)
        var index_size: u64 = blip.encodedSize(n);
        for (offset_storage[0..elements.len]) |off| {
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

    // Write type sentinel (ARRAY = 0x81 0x01)
    const sentinel = ct.typeSentinel(.array);
    buf[pos] = sentinel[0];
    buf[pos + 1] = sentinel[1];
    pos += 2;

    // Write BLIP(total)
    const total_written = blip.encode(total, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += total_written;

    // Write BLIP(index_offset)
    const idx_off_written = blip.encode(index_offset, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += idx_off_written;

    // Write data section (all elements)
    for (elements) |elem| {
        @memcpy(buf[pos..][0..elem.len], elem);
        pos += elem.len;
    }

    // Write index section: BLIP(N), then BLIP(off_0), BLIP(off_1), ...
    const n_written = blip.encode(n, buf[pos..]) catch return ContainerError.BufferTooSmall;
    pos += n_written;

    for (offset_storage[0..elements.len]) |off| {
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

/// Reader for an ARRAY container. Provides random access to elements via the index.
pub const ArrayReader = struct {
    buf: []const u8,
    total_length: u64,
    header_size: usize,
    index_offset: u64,
    count: u64,

    /// Parse an ARRAY container from a buffer.
    /// buf must start at the container's first byte (type sentinel).
    pub fn init(buf: []const u8) ContainerError!ArrayReader {
        // Parse outer header: type + total_length
        const view = try container.parseHeader(buf);
        if (view.container_type != .array) return ContainerError.InvalidContainerType;

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

        // Jump to index section and read N (element count)
        const idx_start: usize = @intCast(index_offset);
        if (idx_start >= total_length) return ContainerError.UnexpectedEndOfInput;
        const n_result = blip.decode(buf[idx_start..@intCast(total_length)]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };

        return ArrayReader{
            .buf = buf,
            .total_length = total_length,
            .header_size = header_size,
            .index_offset = index_offset,
            .count = n_result.value,
        };
    }

    /// Returns the number of elements in the array.
    pub fn elementCount(self: ArrayReader) u64 {
        return self.count;
    }

    /// Random access: read element at the given index.
    /// Returns a ContainerView of the element's TLV.
    pub fn elementAt(self: ArrayReader, index: u64) ContainerError!container.ContainerView {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        // Walk the index section: start at index_offset, skip past BLIP(N),
        // then skip `index` BLIP-encoded offsets, decode the target offset.
        const total: usize = @intCast(self.total_length);
        var pos: usize = @intCast(self.index_offset);

        // Skip past BLIP(N)
        const n_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        pos += n_result.bytes_read;

        // Skip `index` offset entries
        for (0..index) |_| {
            const skip_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Decode the target offset
        const off_result = blip.decode(self.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const elem_offset: usize = @intCast(off_result.value);

        // Jump to element and parse its header
        if (elem_offset >= total) return ContainerError.IndexOutOfBounds;
        return container.parseHeader(self.buf[elem_offset..total]);
    }

    /// Verify the xxHash64 integrity check.
    /// Returns true if the stored hash matches the computed hash.
    pub fn verifyHash(self: ArrayReader) ContainerError!bool {
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

test "empty array: serialize and verify structure" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    // Should start with ARRAY sentinel
    try testing.expectEqual(@as(u8, 0x81), result[0]);
    try testing.expectEqual(@as(u8, 0x01), result[1]);

    // Parse and verify
    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 0), reader.elementCount());
}

test "empty array: total length is correct" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, result.len), reader.total_length);
}

test "empty array: verify hash" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expect(try reader.verifyHash());
}

test "empty array: round-trip" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 0), reader.elementCount());
    try testing.expect(try reader.verifyHash());
}

test "single element array: serialize with one UTF8 element" {
    const allocator = testing.allocator;
    const hello = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(hello);

    const elements = [_][]const u8{hello};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.elementCount());
    try testing.expect(try reader.verifyHash());

    // Read back the element
    const view = try reader.elementAt(0);
    try testing.expectEqual(ContainerType.utf8, view.container_type);
    try testing.expectEqualSlices(u8, "hello", view.valueSlice());
}

test "multiple elements: serialize with mixed UTF8/RAW" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeRaw(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "gamma");
    defer allocator.free(elem2);

    const elements = [_][]const u8{ elem0, elem1, elem2 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.elementCount());
    try testing.expect(try reader.verifyHash());
}

test "elementAt for each index in multi-element array" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeRaw(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "gamma");
    defer allocator.free(elem2);

    const elements = [_][]const u8{ elem0, elem1, elem2 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);

    // Element 0: UTF8 "alpha"
    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerType.utf8, v0.container_type);
    try testing.expectEqualSlices(u8, "alpha", v0.valueSlice());

    // Element 1: RAW 0xDEADBEEF
    const v1 = try reader.elementAt(1);
    try testing.expectEqual(ContainerType.raw, v1.container_type);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, v1.valueSlice());

    // Element 2: UTF8 "gamma"
    const v2 = try reader.elementAt(2);
    try testing.expectEqual(ContainerType.utf8, v2.container_type);
    try testing.expectEqualSlices(u8, "gamma", v2.valueSlice());
}

test "elementAt out of bounds returns IndexOutOfBounds" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "only");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.elementAt(1));
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.elementAt(100));
}

test "verifyHash returns true for valid array" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "check");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeRaw(allocator, "hash");
    defer allocator.free(elem1);

    const elements = [_][]const u8{ elem0, elem1 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expect(try reader.verifyHash());
}

test "verifyHash detects corruption" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "integrity");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    // Corrupt a byte in the data section (not the hash itself)
    // The data starts after sentinel(2) + BLIP(total) + BLIP(index_offset)
    // Flip a byte somewhere in the middle
    const corrupt_pos = result.len / 2;
    result[corrupt_pos] ^= 0xFF;

    const reader = try ArrayReader.init(result);
    const valid = try reader.verifyHash();
    try testing.expect(!valid);
}

test "nested array: array containing another array" {
    const allocator = testing.allocator;

    // Inner array with one element
    const inner_elem = try leaf.serializeUtf8(allocator, "nested");
    defer allocator.free(inner_elem);
    const inner_elements = [_][]const u8{inner_elem};
    const inner_array = try serializeArray(allocator, &inner_elements);
    defer allocator.free(inner_array);

    // Outer array with the inner array as an element plus a leaf
    const outer_leaf = try leaf.serializeUtf8(allocator, "outer");
    defer allocator.free(outer_leaf);
    const outer_elements = [_][]const u8{ outer_leaf, inner_array };
    const result = try serializeArray(allocator, &outer_elements);
    defer allocator.free(result);

    // Read outer array
    const outer_reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 2), outer_reader.elementCount());
    try testing.expect(try outer_reader.verifyHash());

    // Element 0 is UTF8 "outer"
    const v0 = try outer_reader.elementAt(0);
    try testing.expectEqual(ContainerType.utf8, v0.container_type);
    try testing.expectEqualSlices(u8, "outer", v0.valueSlice());

    // Element 1 is an ARRAY
    const v1 = try outer_reader.elementAt(1);
    try testing.expectEqual(ContainerType.array, v1.container_type);

    // Parse the inner array from the outer buffer at the right offset
    const inner_buf = result[@intCast(v1.buf.ptr - result.ptr)..@intCast(v1.total_length + @as(u64, @intCast(v1.buf.ptr - result.ptr)))];
    const inner_reader = try ArrayReader.init(inner_buf);
    try testing.expectEqual(@as(u64, 1), inner_reader.elementCount());
    try testing.expect(try inner_reader.verifyHash());

    const inner_v0 = try inner_reader.elementAt(0);
    try testing.expectEqual(ContainerType.utf8, inner_v0.container_type);
    try testing.expectEqualSlices(u8, "nested", inner_v0.valueSlice());
}

test "self-referential length at BLIP boundary" {
    const allocator = testing.allocator;

    // Create enough small elements so total crosses the 128-byte BLIP boundary
    // Each UTF8 element "x" is 3+1 = 4 bytes (sentinel 2 + length 1 + "x" 1 = 4)
    // Actually: total = header + data + index + hash
    // With ~20 small elements we should be well past 128 bytes
    var elem_bufs: [25][]u8 = undefined;
    var elem_count: usize = 0;

    defer {
        for (elem_bufs[0..elem_count]) |buf| {
            allocator.free(buf);
        }
    }

    for (0..25) |_| {
        elem_bufs[elem_count] = try leaf.serializeUtf8(allocator, "x");
        elem_count += 1;
    }

    var elements: [25][]const u8 = undefined;
    for (elem_bufs[0..elem_count], 0..) |buf, i| {
        elements[i] = buf;
    }

    const result = try serializeArray(allocator, elements[0..elem_count]);
    defer allocator.free(result);

    // Verify total is > 128 (crosses BLIP boundary)
    try testing.expect(result.len > 128);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 25), reader.elementCount());
    try testing.expect(try reader.verifyHash());

    // Verify each element
    for (0..25) |i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerType.utf8, v.container_type);
        try testing.expectEqualSlices(u8, "x", v.valueSlice());
    }
}

test "round-trip: serialize N elements then read back and compare" {
    const allocator = testing.allocator;

    const texts = [_][]const u8{
        "first",
        "second",
        "third",
        "fourth",
        "fifth",
    };

    var serialized: [5][]u8 = undefined;
    var count: usize = 0;
    defer {
        for (serialized[0..count]) |s| allocator.free(s);
    }

    for (texts) |text| {
        serialized[count] = try leaf.serializeUtf8(allocator, text);
        count += 1;
    }

    var elements: [5][]const u8 = undefined;
    for (serialized[0..count], 0..) |s, i| {
        elements[i] = s;
    }

    const result = try serializeArray(allocator, elements[0..count]);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 5), reader.elementCount());
    try testing.expect(try reader.verifyHash());

    for (texts, 0..) |text, i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerType.utf8, v.container_type);
        try testing.expectEqualSlices(u8, text, v.valueSlice());
    }
}

test "five RAW elements round-trip" {
    const allocator = testing.allocator;

    const data = [_][]const u8{
        &[_]u8{ 0x01, 0x02, 0x03 },
        &[_]u8{0xFF},
        &[_]u8{ 0x00, 0x00, 0x00, 0x00 },
        &[_]u8{ 0xAA, 0xBB },
        &[_]u8{},
    };

    var serialized: [5][]u8 = undefined;
    var count: usize = 0;
    defer {
        for (serialized[0..count]) |s| allocator.free(s);
    }

    for (data) |d| {
        serialized[count] = try leaf.serializeRaw(allocator, d);
        count += 1;
    }

    var elements: [5][]const u8 = undefined;
    for (serialized[0..count], 0..) |s, i| {
        elements[i] = s;
    }

    const result = try serializeArray(allocator, elements[0..count]);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 5), reader.elementCount());
    try testing.expect(try reader.verifyHash());

    for (data, 0..) |d, i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerType.raw, v.container_type);
        try testing.expectEqualSlices(u8, d, v.valueSlice());
    }
}

test "array reader rejects non-array container" {
    const allocator = testing.allocator;
    const utf8_buf = try leaf.serializeUtf8(allocator, "not an array");
    defer allocator.free(utf8_buf);

    try testing.expectError(ContainerError.InvalidContainerType, ArrayReader.init(utf8_buf));
}

test "elementAt on empty array returns IndexOutOfBounds" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.elementAt(0));
}

test "verifyHash with corrupted hash bytes" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    // Corrupt the last byte (part of the hash)
    result[result.len - 1] ^= 0x01;

    const reader = try ArrayReader.init(result);
    const valid = try reader.verifyHash();
    try testing.expect(!valid);
}

test "large element count exercises BLIP encoding for offsets" {
    const allocator = testing.allocator;

    // Use 50 elements to exercise bigger offset values
    const n = 50;
    var elem_bufs: [n][]u8 = undefined;
    var elem_count: usize = 0;
    defer {
        for (elem_bufs[0..elem_count]) |buf| allocator.free(buf);
    }

    for (0..n) |i| {
        // Create varying-size elements
        var data: [8]u8 = undefined;
        for (&data, 0..) |*b, j| {
            b.* = @intCast((i + j) % 256);
        }
        elem_bufs[elem_count] = try leaf.serializeRaw(allocator, &data);
        elem_count += 1;
    }

    var elements: [n][]const u8 = undefined;
    for (elem_bufs[0..elem_count], 0..) |buf, i| {
        elements[i] = buf;
    }

    const result = try serializeArray(allocator, elements[0..elem_count]);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, n), reader.elementCount());
    try testing.expect(try reader.verifyHash());

    // Spot-check a few elements
    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerType.raw, v0.container_type);

    const v49 = try reader.elementAt(49);
    try testing.expectEqual(ContainerType.raw, v49.container_type);
}

test "deeply nested arrays" {
    const allocator = testing.allocator;

    // Build 3 levels of nesting: array(array(array(leaf)))
    const inner_leaf = try leaf.serializeUtf8(allocator, "deep");
    defer allocator.free(inner_leaf);

    const level1_elems = [_][]const u8{inner_leaf};
    const level1 = try serializeArray(allocator, &level1_elems);
    defer allocator.free(level1);

    const level2_elems = [_][]const u8{level1};
    const level2 = try serializeArray(allocator, &level2_elems);
    defer allocator.free(level2);

    const level3_elems = [_][]const u8{level2};
    const result = try serializeArray(allocator, &level3_elems);
    defer allocator.free(result);

    // Navigate down
    const r3 = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), r3.elementCount());
    try testing.expect(try r3.verifyHash());

    const v3 = try r3.elementAt(0);
    try testing.expectEqual(ContainerType.array, v3.container_type);
}

test "array total_length matches buffer length" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    // Decode the total length from the buffer
    const len_result = blip.decode(result[2..]) catch unreachable;
    try testing.expectEqual(@as(u64, result.len), len_result.value);
}
