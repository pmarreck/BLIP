const std = @import("std");
const blip = @import("blip.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

pub const ContainerType = ct.ContainerType;
pub const typeSentinel = ct.typeSentinel;
pub const parseType = ct.parseType;

pub const ContainerError = error{
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
};

/// Result of parsing a container header.
pub const ContainerView = struct {
    container_type: ContainerType,
    total_length: u64,
    /// Byte offset where the value payload starts (after type + length)
    value_offset: usize,
    /// The full container buffer (from container start through total_length)
    buf: []const u8,

    /// Returns the value payload slice.
    pub fn valueSlice(self: ContainerView) []const u8 {
        return self.buf[self.value_offset..@intCast(self.total_length)];
    }
};

/// Compute total container size given value payload size.
/// Solves: total = 2 (type sentinel) + blip_encoded_size(total) + v_size
pub fn computeTotalLength(v_size: u64) u64 {
    const base: u64 = 2 + v_size;
    for (1..10) |l_bytes| {
        const total = base + l_bytes;
        if (blip.encodedSize(total) == l_bytes) return total;
    }
    unreachable;
}

/// Write a container header (type sentinel + BLIP total length).
/// Returns number of bytes written (2 + BLIP encoding of total).
pub fn writeHeader(container_type: ContainerType, total_length: u64, buf: []u8) ContainerError!usize {
    if (buf.len < 2) return ContainerError.BufferTooSmall;
    const sentinel = ct.typeSentinel(container_type);
    buf[0] = sentinel[0];
    buf[1] = sentinel[1];
    const len_bytes = blip.encode(total_length, buf[2..]) catch return ContainerError.BufferTooSmall;
    return 2 + len_bytes;
}

/// Parse a container header from a buffer.
/// buf must start at the container's first byte (type sentinel).
pub fn parseHeader(buf: []const u8) ContainerError!ContainerView {
    if (buf.len < 3) return ContainerError.UnexpectedEndOfInput;
    const container_type = ct.parseType(buf) orelse return ContainerError.InvalidContainerType;
    const len_result = blip.decode(buf[2..]) catch |e| switch (e) {
        error.UnexpectedEndOfInput => return ContainerError.UnexpectedEndOfInput,
        error.Overflow => return ContainerError.Overflow,
        error.BufferTooSmall => return ContainerError.BufferTooSmall,
    };
    const total_length = len_result.value;
    const value_offset: usize = 2 + len_result.bytes_read;
    if (total_length > buf.len) return ContainerError.LengthExceedsBounds;
    if (total_length < value_offset) return ContainerError.InvalidLength;
    return ContainerView{
        .container_type = container_type,
        .total_length = total_length,
        .value_offset = value_offset,
        .buf = buf,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "computeTotalLength for empty value" {
    // total = 2 (type) + 1 (BLIP(3)) + 0 (value) = 3
    try testing.expectEqual(@as(u64, 3), computeTotalLength(0));
}

test "computeTotalLength for 5-byte value (hello)" {
    // total = 2 + 1 (BLIP(8)) + 5 = 8
    try testing.expectEqual(@as(u64, 8), computeTotalLength(5));
}

test "computeTotalLength at BLIP boundary" {
    // v_size = 125: base = 127, try l=1: total=128, encodedSize(128)=2, no.
    //                            try l=2: total=129, encodedSize(129)=2, yes!
    try testing.expectEqual(@as(u64, 129), computeTotalLength(125));
}

test "computeTotalLength for large value" {
    // v_size = 65535
    const total = computeTotalLength(65535);
    try testing.expectEqual(total, 2 + blip.encodedSize(total) + 65535);
}

test "writeHeader + parseHeader roundtrip" {
    var buf: [64]u8 = undefined;
    const v_size: u64 = 5; // e.g. "hello"
    const total = computeTotalLength(v_size);
    const written = try writeHeader(.utf8, total, &buf);
    const view = try parseHeader(&buf);
    try testing.expectEqual(ContainerType.utf8, view.container_type);
    try testing.expectEqual(total, view.total_length);
    try testing.expectEqual(written, view.value_offset);
}

test "parseHeader rejects invalid type" {
    const result = parseHeader(&[_]u8{ 0x81, 0x00, 0x05 }); // PAD_END, not a container
    try testing.expectError(ContainerError.InvalidContainerType, result);
}

test "parseHeader rejects truncated buffer" {
    const result = parseHeader(&[_]u8{ 0x81, 0x03 }); // no length
    try testing.expectError(ContainerError.UnexpectedEndOfInput, result);
}

test "parseHeader rejects length exceeding buffer" {
    // Claims total=100 but buffer is only 5 bytes
    const result = parseHeader(&[_]u8{ 0x81, 0x03, 0x64, 0x00, 0x00 });
    try testing.expectError(ContainerError.LengthExceedsBounds, result);
}

test {
    _ = @import("container_types.zig");
}
