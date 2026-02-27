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

/// Serialize an ordered array of pre-serialized LP container elements with a
/// specified container type and LP options (including optional checksum).
///
/// v2 LP layout:
///   [BLIP(total)] [TYPE attr] [opt CSUM attr] [VAL sentinel]
///   [BLIP(index_offset)] [elements...] [INDEX_SECTION] [checksum?]
///
/// The VAL payload is: [BLIP(index_offset)] [elements...] [INDEX_SECTION]
/// Checksum bytes (if any) are appended after the index section, still inside
/// the container's total length.
///
/// Each element in `elements` must already be a complete LP container.
/// Caller owns returned memory.
pub fn serializeArrayLike(
    allocator: Allocator,
    elements: []const []const u8,
    type_id: ContainerTypeId,
    options: LPOptions,
) (Allocator.Error || LPContainerError)![]u8 {
    const n: u64 = elements.len;
    const csum_size: u64 = if (options.csum_id) |id| ct.checksumLength(id) else 0;

    // Compute total data size (sum of all element byte lengths)
    var data_size: u64 = 0;
    for (elements) |elem| {
        data_size += elem.len;
    }

    // Stack buffer for element offsets; use heap if too many
    var offsets_stack: [1024]u64 = undefined;
    var heap_offsets: ?[]u64 = null;
    defer if (heap_offsets) |ho| allocator.free(ho);

    const offset_storage: []u64 = if (elements.len <= 1024)
        offsets_stack[0..elements.len]
    else blk: {
        heap_offsets = try allocator.alloc(u64, elements.len);
        break :blk heap_offsets.?;
    };

    // Fixpoint iteration to resolve self-referential sizes.
    //
    // For a given I_size (BLIP encoding size of index_offset):
    //   1. Compute element offsets: offset[k] = val_offset + I_size + cumulative[k]
    //   2. index_section_size = BLIP(N) + sum(BLIP(offset[k]))
    //   3. val_payload_size = I_size + data_size + index_section_size
    //   4. total = computeLPLength(type_id, val_payload_size, options)
    //   5. val_offset = total - val_payload_size - csum_size
    //   6. index_offset = val_offset + I_size + data_size
    //   7. I_size_new = BLIP_size(index_offset)
    //
    // We iterate until I_size stabilizes. Within each outer iteration we also
    // iterate on val_offset since it feeds back into element offsets.

    var I_size: usize = 1;
    var total: u64 = undefined;
    var index_offset: u64 = undefined;

    for (0..10) |_| {
        // Start with an estimated val_offset (use 0 initially, will converge)
        var val_offset: u64 = 0;

        // Inner loop: converge on val_offset for the current I_size
        for (0..10) |_| {
            // Compute element offsets from container start
            var running_offset: u64 = val_offset + I_size;
            for (elements, 0..) |elem, k| {
                offset_storage[k] = running_offset;
                running_offset += elem.len;
            }
            index_offset = running_offset;

            // Compute index section size
            var index_section_size: u64 = blip.encodedSize(n);
            for (offset_storage[0..elements.len]) |off| {
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

/// Serialize an ordered array of pre-serialized LP container elements.
/// Each element in `elements` must already be a complete LP container.
/// No checksum by default (inner container convention).
/// Caller owns returned memory.
pub fn serializeArray(allocator: Allocator, elements: []const []const u8) (Allocator.Error || LPContainerError)![]u8 {
    return serializeArrayLike(allocator, elements, .array, .{});
}

/// Serialize an ordered array with custom LP options (e.g., checksum).
/// Caller owns returned memory.
pub fn serializeArrayWithOptions(allocator: Allocator, elements: []const []const u8, options: LPOptions) (Allocator.Error || LPContainerError)![]u8 {
    return serializeArrayLike(allocator, elements, .array, options);
}

/// Reader for an ARRAY container in v2 LP format.
/// Provides random access to elements via the index section.
pub const ArrayReader = struct {
    lp_view: LPContainerView,
    index_offset: u64,
    count: u64,
    /// Byte offset from container start to the first element (after BLIP(index_offset))
    header_size: usize,

    /// Parse an ARRAY container from a buffer.
    /// buf must start at the container's first byte (BLIP total_length).
    pub fn init(buf: []const u8) LPContainerError!ArrayReader {
        const lp = try container.parseLPHeader(buf);
        if (lp.type_id != .array and lp.type_id != .file) return ContainerError.InvalidContainerType;

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

        // Read count from index section (at buf[index_offset..])
        const idx_start: usize = @intCast(index_offset);
        if (idx_start >= total) return ContainerError.UnexpectedEndOfInput;
        const n_result = blip.decode(buf[idx_start..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };

        return ArrayReader{
            .lp_view = lp,
            .index_offset = index_offset,
            .count = n_result.value,
            .header_size = header_size,
        };
    }

    /// Returns the number of elements in the array.
    pub fn elementCount(self: ArrayReader) u64 {
        return self.count;
    }

    /// Random access: read element at the given index.
    /// Returns an LPContainerView of the element.
    pub fn elementAt(self: ArrayReader, index: u64) LPContainerError!LPContainerView {
        if (index >= self.count) return ContainerError.IndexOutOfBounds;

        const total: usize = @intCast(self.lp_view.total_length);
        var pos: usize = @intCast(self.index_offset);

        // Skip past BLIP(N)
        const n_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        pos += n_result.bytes_read;

        // Skip `index` offset entries
        for (0..index) |_| {
            const skip_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
                error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
                error.Overflow => return ContainerError.Overflow,
                error.BufferTooSmall => return ContainerError.BufferTooSmall,
            };
            pos += skip_result.bytes_read;
        }

        // Decode the target offset
        const off_result = blip.decode(self.lp_view.buf[pos..total]) catch |e| switch (e) {
            error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
            error.Overflow => return ContainerError.Overflow,
            error.BufferTooSmall => return ContainerError.BufferTooSmall,
        };
        const elem_offset: usize = @intCast(off_result.value);

        // Jump to element and parse its LP header
        if (elem_offset >= total) return ContainerError.IndexOutOfBounds;
        return container.parseLPHeader(self.lp_view.buf[elem_offset..total]);
    }

    /// Verify the checksum of this array container.
    /// If the container has no CSUM attribute, returns true (nothing to check).
    /// If CSUM is present, recomputes the checksum and compares.
    pub fn verifyChecksum(self: ArrayReader) LPContainerError!bool {
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

test "empty array: serialize and read back (count=0)" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 0), reader.elementCount());
    try testing.expectEqual(@as(u64, result.len), reader.lp_view.total_length);
}

test "single UTF8 element round-trip" {
    const allocator = testing.allocator;
    const hello = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(hello);

    const elements = [_][]const u8{hello};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.elementCount());

    // Read back the element
    const view = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, view.type_id);
    try testing.expectEqualSlices(u8, "hello", view.payloadSlice());
}

test "multiple mixed elements (UTF8 + DATA) round-trip" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeData(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "gamma");
    defer allocator.free(elem2);

    const elements = [_][]const u8{ elem0, elem1, elem2 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 3), reader.elementCount());
}

test "elementAt for each index in multi-element array" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "alpha");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeData(allocator, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    defer allocator.free(elem1);
    const elem2 = try leaf.serializeUtf8(allocator, "gamma");
    defer allocator.free(elem2);

    const elements = [_][]const u8{ elem0, elem1, elem2 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);

    // Element 0: UTF8 "alpha"
    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, v0.type_id);
    try testing.expectEqualSlices(u8, "alpha", v0.payloadSlice());

    // Element 1: DATA 0xDEADBEEF
    const v1 = try reader.elementAt(1);
    try testing.expectEqual(ContainerTypeId.data, v1.type_id);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, v1.payloadSlice());

    // Element 2: UTF8 "gamma"
    const v2 = try reader.elementAt(2);
    try testing.expectEqual(ContainerTypeId.utf8, v2.type_id);
    try testing.expectEqualSlices(u8, "gamma", v2.payloadSlice());
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

test "verifyChecksum returns true for no checksum (inner container default)" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "check");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeData(allocator, "hash");
    defer allocator.free(elem1);

    const elements = [_][]const u8{ elem0, elem1 };
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expect(try reader.verifyChecksum());
}

test "array with BLAKE3-128 checksum" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "checked");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeData(allocator, "data");
    defer allocator.free(elem1);

    const elements = [_][]const u8{ elem0, elem1 };
    const result = try serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 2), reader.elementCount());
    try testing.expect(try reader.verifyChecksum());

    // Verify elements still accessible
    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, v0.type_id);
    try testing.expectEqualSlices(u8, "checked", v0.payloadSlice());

    const v1 = try reader.elementAt(1);
    try testing.expectEqual(ContainerTypeId.data, v1.type_id);
    try testing.expectEqualSlices(u8, "data", v1.payloadSlice());
}

test "checksum corruption detection" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "integrity");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    // Corrupt a byte in the data section (not the checksum itself)
    const reader_before = try ArrayReader.init(result);
    // Flip a byte in the payload region
    const corrupt_pos = reader_before.lp_view.val_offset + 1;
    result[corrupt_pos] ^= 0xFF;

    const reader = try ArrayReader.init(result);
    const valid = try reader.verifyChecksum();
    try testing.expect(!valid);
}

test "nested arrays (array inside array)" {
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
    try testing.expect(try outer_reader.verifyChecksum());

    // Element 0 is UTF8 "outer"
    const v0 = try outer_reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, v0.type_id);
    try testing.expectEqualSlices(u8, "outer", v0.payloadSlice());

    // Element 1 is an ARRAY
    const v1 = try outer_reader.elementAt(1);
    try testing.expectEqual(ContainerTypeId.array, v1.type_id);

    // Parse the inner array from v1's buffer
    const inner_reader = try ArrayReader.init(v1.buf);
    try testing.expectEqual(@as(u64, 1), inner_reader.elementCount());
    try testing.expect(try inner_reader.verifyChecksum());

    const inner_v0 = try inner_reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, inner_v0.type_id);
    try testing.expectEqualSlices(u8, "nested", inner_v0.payloadSlice());
}

test "large element count (50+ elements)" {
    const allocator = testing.allocator;

    const n = 50;
    var elem_bufs: [n][]u8 = undefined;
    var elem_count: usize = 0;
    defer {
        for (elem_bufs[0..elem_count]) |buf| allocator.free(buf);
    }

    for (0..n) |i| {
        var data: [8]u8 = undefined;
        for (&data, 0..) |*b, j| {
            b.* = @intCast((i + j) % 256);
        }
        elem_bufs[elem_count] = try leaf.serializeData(allocator, &data);
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
    try testing.expect(try reader.verifyChecksum());

    // Spot-check first and last elements
    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.data, v0.type_id);

    const v49 = try reader.elementAt(49);
    try testing.expectEqual(ContainerTypeId.data, v49.type_id);
}

test "serializeArrayLike with .file type" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArrayLike(allocator, &elements, .file, .{});
    defer allocator.free(result);

    // Parse as LP and verify type_id is .file
    const lp = try container.parseLPHeader(result);
    try testing.expectEqual(ContainerTypeId.file, lp.type_id);

    // ArrayReader should accept .file type
    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.elementCount());
    try testing.expect(try reader.verifyChecksum());

    // Read back element
    const view = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, view.type_id);
    try testing.expectEqualSlices(u8, "hello", view.payloadSlice());
}

test "ArrayReader rejects non-array container" {
    const allocator = testing.allocator;
    const utf8_buf = try leaf.serializeUtf8(allocator, "not an array");
    defer allocator.free(utf8_buf);

    try testing.expectError(ContainerError.InvalidContainerType, ArrayReader.init(utf8_buf));
}

test "BLIP boundary crossing (total > 128)" {
    const allocator = testing.allocator;

    // Create enough small elements so total crosses the 128-byte BLIP boundary
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
    try testing.expect(try reader.verifyChecksum());

    // Verify each element
    for (0..25) |i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerTypeId.utf8, v.type_id);
        try testing.expectEqualSlices(u8, "x", v.payloadSlice());
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
    try testing.expect(try reader.verifyChecksum());

    for (texts, 0..) |text, i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerTypeId.utf8, v.type_id);
        try testing.expectEqualSlices(u8, text, v.payloadSlice());
    }
}

test "five DATA elements round-trip" {
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
        serialized[count] = try leaf.serializeData(allocator, d);
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
    try testing.expect(try reader.verifyChecksum());

    for (data, 0..) |d, i| {
        const v = try reader.elementAt(@intCast(i));
        try testing.expectEqual(ContainerTypeId.data, v.type_id);
        try testing.expectEqualSlices(u8, d, v.payloadSlice());
    }
}

test "elementAt on empty array returns IndexOutOfBounds" {
    const allocator = testing.allocator;
    const elements = [_][]const u8{};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectError(ContainerError.IndexOutOfBounds, reader.elementAt(0));
}

test "verifyChecksum with corrupted checksum bytes" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "test");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .blake3_128 });
    defer allocator.free(result);

    // Corrupt the last byte (part of the checksum)
    result[result.len - 1] ^= 0x01;

    const reader = try ArrayReader.init(result);
    const valid = try reader.verifyChecksum();
    try testing.expect(!valid);
}

test "deeply nested arrays (3 levels)" {
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
    try testing.expect(try r3.verifyChecksum());

    const v3 = try r3.elementAt(0);
    try testing.expectEqual(ContainerTypeId.array, v3.type_id);
}

test "serializeArrayLike with .file type multi-element round-trip" {
    const allocator = testing.allocator;
    const elem0 = try leaf.serializeUtf8(allocator, "metadata");
    defer allocator.free(elem0);
    const elem1 = try leaf.serializeData(allocator, "content");
    defer allocator.free(elem1);

    const elements = [_][]const u8{ elem0, elem1 };
    const result = try serializeArrayLike(allocator, &elements, .file, .{});
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 2), reader.elementCount());
    try testing.expect(try reader.verifyChecksum());

    const v0 = try reader.elementAt(0);
    try testing.expectEqualSlices(u8, "metadata", v0.payloadSlice());
    const v1 = try reader.elementAt(1);
    try testing.expectEqualSlices(u8, "content", v1.payloadSlice());
}

test "array total_length matches buffer length" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "hello");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArray(allocator, &elements);
    defer allocator.free(result);

    const lp = try container.parseLPHeader(result);
    try testing.expectEqual(@as(u64, result.len), lp.total_length);
}

test "array with xxHash64 checksum" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "hashed");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .xxhash64 });
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.elementCount());
    try testing.expect(try reader.verifyChecksum());

    const v0 = try reader.elementAt(0);
    try testing.expectEqual(ContainerTypeId.utf8, v0.type_id);
    try testing.expectEqualSlices(u8, "hashed", v0.payloadSlice());
}

test "array with CRC32 checksum" {
    const allocator = testing.allocator;
    const elem = try leaf.serializeUtf8(allocator, "crc");
    defer allocator.free(elem);

    const elements = [_][]const u8{elem};
    const result = try serializeArrayWithOptions(allocator, &elements, .{ .csum_id = .crc32 });
    defer allocator.free(result);

    const reader = try ArrayReader.init(result);
    try testing.expectEqual(@as(u64, 1), reader.elementCount());
    try testing.expect(try reader.verifyChecksum());
}
