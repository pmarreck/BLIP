//! Value classification at DICT-value / ARRAY-element positions.
//!
//! Implements the BLIP_WIRE_SPEC §Scalar values classifier: a value's exact
//! byte span is one of a scalar sentinel (TRUE/FALSE/NIL), a well-formed LP
//! container, or a bare BLIP integer. This is what makes integers self-describing
//! on the wire (→ readable JSON numbers) rather than opaque byte-leaves.
//!
//! Key technique: a 3-rule classifier proven mutually-exclusive because an LP
//! container must carry `BLIP(total)==span_len` immediately followed by the
//! `0x81 0x01` TYPE sentinel, while a canonical bare integer consumes its entire
//! span as one varint (leaving no room for a TYPE sentinel) and a scalar sentinel
//! is exactly 2 bytes.

const std = @import("std");
const blip = @import("blip.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const testing = std.testing;

/// A classified value at a container-value position.
pub const ClassifiedValue = union(enum) {
    integer: u64, // bare BLIP integer (u64 domain; >u64 is a future big-int case)
    boolean: bool, // TRUE / FALSE scalar sentinel
    nil, // NIL scalar sentinel
    container: container.LPContainerView, // an LP container (ARRAY/DICT/UTF8/DATA/…)
};

pub const ValueError = error{
    EmptyValue,
    TrailingBytes,
    ReservedSentinel,
} || blip.Error || container.ContainerError;

/// Classify a value's exact byte span `v` per BLIP_WIRE_SPEC §Scalar values.
pub fn classify(v: []const u8) ValueError!ClassifiedValue {
    if (v.len == 0) return error.EmptyValue;

    // Rule 1: a scalar sentinel is exactly `0x81` followed by a byte < 0x80
    // (an overlong L=1,E=0 encoding). Only 7C/7D/7E are the TRUE/FALSE/NIL
    // data scalars; the rest of that range is reserved (app sentinels, VAL sigil).
    if (v.len == 2 and v[0] == 0x81 and v[1] < 0x80) {
        return switch (v[1]) {
            0x7C => .{ .boolean = true },
            0x7D => .{ .boolean = false },
            0x7E => .nil,
            else => error.ReservedSentinel,
        };
    }

    // Rule 2: a well-formed LP container — parseLPHeader validates the TYPE
    // sentinel; require the declared total to cover exactly this span.
    if (container.parseLPHeader(v)) |view| {
        if (view.total_length == v.len) return .{ .container = view };
    } else |_| {}

    // Rule 3: a bare BLIP integer must consume exactly the whole span.
    const dr = try blip.decode(v);
    if (dr.bytes_read != v.len) return error.TrailingBytes;
    return .{ .integer = dr.value };
}

// =============================================================================
// Tests — the classifier as a set-classifier (MFIC)
// =============================================================================

const leaf = @import("leaf.zig");
const array = @import("array.zig");
const dict = @import("dict.zig");

test "classify: scalar sentinels TRUE/FALSE/NIL" {
    try testing.expectEqual(ClassifiedValue{ .boolean = true }, try classify(&[_]u8{ 0x81, 0x7C }));
    try testing.expectEqual(ClassifiedValue{ .boolean = false }, try classify(&[_]u8{ 0x81, 0x7D }));
    try testing.expectEqual(ClassifiedValue.nil, try classify(&[_]u8{ 0x81, 0x7E }));
}

test "classify: bare integers across ranges" {
    var buf: [16]u8 = undefined;
    const cases = [_]u64{ 0, 1, 42, 124, 127, 128, 200, 255, 256, 1000, 65535, 65536, 4294967295, 4294967296, std.math.maxInt(u64) };
    for (cases) |val| {
        const n = try blip.encode(val, &buf);
        const c = try classify(buf[0..n]);
        try testing.expectEqual(ClassifiedValue{ .integer = val }, c);
    }
}

test "classify: MFIC boundary — canonical 124 is an integer, 0x81 0x7C is the TRUE sentinel" {
    var buf: [4]u8 = undefined;
    const n = try blip.encode(124, &buf); // canonical immediate 0x7C
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(ClassifiedValue{ .integer = 124 }, try classify(buf[0..n]));
    // the overlong 2-byte form is the sentinel, never the integer 124
    try testing.expectEqual(ClassifiedValue{ .boolean = true }, try classify(&[_]u8{ 0x81, 0x7C }));
}

test "classify: LP containers (UTF8/DATA/ARRAY/DICT)" {
    const a = testing.allocator;
    const u = try leaf.serializeUtf8(a, "hi");
    defer a.free(u);
    const d = try leaf.serializeData(a, &[_]u8{ 0xDE, 0xAD });
    defer a.free(d);
    switch (try classify(u)) {
        .container => |view| try testing.expectEqual(ct.ContainerTypeId.utf8, view.type_id),
        else => return error.TestUnexpectedResult,
    }
    switch (try classify(d)) {
        .container => |view| try testing.expectEqual(ct.ContainerTypeId.data, view.type_id),
        else => return error.TestUnexpectedResult,
    }
    const arr = try array.serializeArray(a, &.{ u, d });
    defer a.free(arr);
    switch (try classify(arr)) {
        .container => |view| try testing.expectEqual(ct.ContainerTypeId.array, view.type_id),
        else => return error.TestUnexpectedResult,
    }
}

test "classify: errors — empty, trailing bytes, reserved sentinel" {
    try testing.expectError(error.EmptyValue, classify(&[_]u8{}));
    // canonical integer 5 with a stray trailing byte
    try testing.expectError(error.TrailingBytes, classify(&[_]u8{ 0x05, 0xFF }));
    // 0x81 0x00 is an application sentinel, not a valid data value here
    try testing.expectError(error.ReservedSentinel, classify(&[_]u8{ 0x81, 0x00 }));
    // 0x81 0x7F is the VAL sigil, reserved
    try testing.expectError(error.ReservedSentinel, classify(&[_]u8{ 0x81, 0x7F }));
}

test "classify: MFIC sweep over 0x81 0xNN (NN < 0x80) — exactly 7C/7D/7E are scalars, rest reserved" {
    var nn: u8 = 0x00;
    while (nn < 0x80) : (nn += 1) {
        const v = [_]u8{ 0x81, nn };
        const res = classify(&v);
        switch (nn) {
            0x7C => try testing.expectEqual(ClassifiedValue{ .boolean = true }, try res),
            0x7D => try testing.expectEqual(ClassifiedValue{ .boolean = false }, try res),
            0x7E => try testing.expectEqual(ClassifiedValue.nil, try res),
            else => try testing.expectError(error.ReservedSentinel, res),
        }
    }
}

test "classify: end-to-end over ARRAY elements (bare integer + container)" {
    const a = testing.allocator;
    var ibuf: [16]u8 = undefined;
    const int_elem = ibuf[0..try blip.encode(42, &ibuf)];
    const utf = try leaf.serializeUtf8(a, "x");
    defer a.free(utf);
    const arr = try array.serializeArray(a, &.{ int_elem, utf });
    defer a.free(arr);

    const reader = try array.ArrayReader.init(arr);
    try testing.expectEqual(ClassifiedValue{ .integer = 42 }, try classify(try reader.elementBytesAt(0)));
    switch (try classify(try reader.elementBytesAt(1))) {
        .container => |view| try testing.expectEqual(ct.ContainerTypeId.utf8, view.type_id),
        else => return error.TestUnexpectedResult,
    }
}
