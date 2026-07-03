//! Generic lossless container↔JSON codec (BLIP_WIRE_SPEC §Human-Readable Representation).
//!
//! `toJson` walks a BLIP value and projects it to JSON using the pinned tag
//! vocabulary — `$int` for integers past 2^53-1, `$b` for DATA byte-leaves
//! (printable-binary), `$blip` as the universal escape for any container the
//! structural walk doesn't descend into — with natural JSON everywhere else.
//! For canonical wire the `wire → JSON → wire` round-trip is byte-identical,
//! which is the differential/MFIC oracle (== validate-serve `--verify-mapping`).

const std = @import("std");
const blip = @import("blip.zig");
const value = @import("value.zig");
const container = @import("container.zig");
const ct = @import("container_types.zig");
const leaf = @import("leaf.zig");
const array = @import("array.zig");
const dict = @import("dict.zig");
const pb = @import("printable_binary");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const JsonError = value.ValueError || Allocator.Error;

/// JSON's largest exactly-representable integer, 2^53-1. Larger BLIP integers
/// project to `{"$int":"…"}` to avoid f64 precision loss.
pub const SAFE_INT_MAX: u64 = (@as(u64, 1) << 53) - 1;

/// Project a BLIP value (its exact byte span) to a JSON string. Caller owns it.
pub fn toJson(allocator: Allocator, buf: []const u8) JsonError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeValue(allocator, &out, buf);
    return out.toOwnedSlice(allocator);
}

fn writeValue(allocator: Allocator, out: *std.ArrayList(u8), v: []const u8) JsonError!void {
    switch (try value.classify(v)) {
        .integer => |n| {
            var nb: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{n}) catch unreachable;
            if (n <= SAFE_INT_MAX) {
                try out.appendSlice(allocator, s);
            } else {
                try out.appendSlice(allocator, "{\"$int\":\"");
                try out.appendSlice(allocator, s);
                try out.appendSlice(allocator, "\"}");
            }
        },
        .boolean => |bl| try out.appendSlice(allocator, if (bl) "true" else "false"),
        .nil => try out.appendSlice(allocator, "null"),
        .container => |view| try writeContainer(allocator, out, v, view),
    }
}

fn writeContainer(allocator: Allocator, out: *std.ArrayList(u8), full: []const u8, view: container.LPContainerView) JsonError!void {
    switch (view.type_id) {
        .utf8 => try writeJsonString(allocator, out, try leaf.readUtf8(full)),
        .data => try writeTagged(allocator, out, "$b", try leaf.readData(full)),
        .array, .file => {
            var reader = try array.ArrayReader.init(full);
            try out.append(allocator, '[');
            var i: u64 = 0;
            while (i < reader.elementCount()) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try writeValue(allocator, out, try reader.elementBytesAt(i));
            }
            try out.append(allocator, ']');
        },
        .dict, .map, .dir => {
            var reader = try dict.DictReader.init(full);
            try out.append(allocator, '{');
            var i: u64 = 0;
            while (i < reader.pairCount()) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try writeJsonString(allocator, out, try dict.extractKeyBytes(try reader.keyAt(i)));
                try out.append(allocator, ':');
                try writeValue(allocator, out, try reader.valueAt(i));
            }
            try out.append(allocator, '}');
        },
        // any other container (e.g. SEGMENT) → universal $blip escape
        else => try writeTagged(allocator, out, "$blip", full),
    }
}

/// Emit `{"<tag>":"<printable-binary of bytes>"}`.
fn writeTagged(allocator: Allocator, out: *std.ArrayList(u8), tag: []const u8, bytes: []const u8) JsonError!void {
    const pbs = try pb.encode(allocator, bytes, .{});
    defer allocator.free(pbs);
    try out.appendSlice(allocator, "{\"");
    try out.appendSlice(allocator, tag);
    try out.appendSlice(allocator, "\":\"");
    try out.appendSlice(allocator, pbs);
    try out.appendSlice(allocator, "\"}");
}

/// Write `str` as a JSON-escaped double-quoted string (assumes valid UTF-8).
fn writeJsonString(allocator: Allocator, out: *std.ArrayList(u8), str: []const u8) JsonError!void {
    try out.append(allocator, '"');
    for (str) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    var esc: [6]u8 = undefined;
                    const e = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(allocator, e);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

// =============================================================================
// Tests
// =============================================================================

fn expectJson(expected: []const u8, buf: []const u8) !void {
    const got = try toJson(testing.allocator, buf);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "toJson: bare integers as JSON numbers" {
    var b: [16]u8 = undefined;
    try expectJson("0", b[0..try blip.encode(0, &b)]);
    try expectJson("42", b[0..try blip.encode(42, &b)]);
    try expectJson("65535", b[0..try blip.encode(65535, &b)]);
    try expectJson("9007199254740991", b[0..try blip.encode(SAFE_INT_MAX, &b)]);
}

test "toJson: integers past 2^53-1 become $int tagged strings" {
    var b: [16]u8 = undefined;
    try expectJson("{\"$int\":\"9007199254740992\"}", b[0..try blip.encode(SAFE_INT_MAX + 1, &b)]);
    try expectJson("{\"$int\":\"18446744073709551615\"}", b[0..try blip.encode(std.math.maxInt(u64), &b)]);
}

test "toJson: sentinels" {
    try expectJson("true", &[_]u8{ 0x81, 0x7C });
    try expectJson("false", &[_]u8{ 0x81, 0x7D });
    try expectJson("null", &[_]u8{ 0x81, 0x7E });
}

test "toJson: UTF8 string with escapes" {
    const u = try leaf.serializeUtf8(testing.allocator, "a\"b\n\t");
    defer testing.allocator.free(u);
    try expectJson("\"a\\\"b\\n\\t\"", u);
}

test "toJson: DATA leaf -> $b printable-binary" {
    const a = testing.allocator;
    const bytes = [_]u8{ 0x00, 0xFF, 0x1F };
    const d = try leaf.serializeData(a, &bytes);
    defer a.free(d);
    const pbs = try pb.encode(a, &bytes, .{});
    defer a.free(pbs);
    const expected = try std.fmt.allocPrint(a, "{{\"$b\":\"{s}\"}}", .{pbs});
    defer a.free(expected);
    try expectJson(expected, d);
}

test "toJson: array of a bare int and a string" {
    const a = testing.allocator;
    var b: [16]u8 = undefined;
    const one = b[0..try blip.encode(1, &b)];
    const ux = try leaf.serializeUtf8(a, "x");
    defer a.free(ux);
    const arr = try array.serializeArray(a, &.{ one, ux });
    defer a.free(arr);
    try expectJson("[1,\"x\"]", arr);
}

test "toJson: dict with a bare-scalar value {n:5}" {
    const a = testing.allocator;
    var b: [16]u8 = undefined;
    const kn = try leaf.serializeUtf8(a, "n");
    defer a.free(kn);
    const v5 = b[0..try blip.encode(5, &b)];
    const d1 = try dict.serializeDict(a, &.{.{ .key = kn, .value = v5 }});
    defer a.free(d1);
    try expectJson("{\"n\":5}", d1);
}

test "toJson: dict with a nested array of sentinels {a:[true,null]}" {
    const a = testing.allocator;
    const inner = try array.serializeArray(a, &.{ &[_]u8{ 0x81, 0x7C }, &[_]u8{ 0x81, 0x7E } });
    defer a.free(inner);
    try expectJson("[true,null]", inner);
    const ka = try leaf.serializeUtf8(a, "a");
    defer a.free(ka);
    const d2 = try dict.serializeDict(a, &.{.{ .key = ka, .value = inner }});
    defer a.free(d2);
    try expectJson("{\"a\":[true,null]}", d2);
}
