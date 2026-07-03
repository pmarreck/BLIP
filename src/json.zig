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
const segmentation = @import("segmentation.zig");
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
    // Only descend structurally into the types whose JSON round-trips byte-identically
    // (ARRAY, DICT, UTF8, DATA). Every other container — MAP (insertion order), FILE/DIR
    // (archive types), SEGMENT, or any unknown type — is escaped losslessly via $blip so
    // its exact bytes (and type) survive the round-trip.
    switch (view.type_id) {
        .utf8 => try writeJsonString(allocator, out, try leaf.readUtf8(full)),
        .data => try writeTagged(allocator, out, "$b", try leaf.readData(full)),
        .array => {
            var reader = try array.ArrayReader.init(full);
            try out.append(allocator, '[');
            var i: u64 = 0;
            while (i < reader.elementCount()) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                try writeValue(allocator, out, try reader.elementBytesAt(i));
            }
            try out.append(allocator, ']');
        },
        .dict => {
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

pub const FromJsonError = Allocator.Error || value.ValueError ||
    error{ InvalidJson, InvalidTag, InvalidNumber, NegativeUnsupported, FloatUnsupported, InvalidPrintableBinary };

/// Build a canonical BLIP value from a JSON string (inverse of toJson). Caller owns it.
pub fn fromJson(allocator: Allocator, json: []const u8) FromJsonError![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    return buildValue(allocator, parsed.value);
}

fn buildValue(allocator: Allocator, v: std.json.Value) FromJsonError![]u8 {
    return switch (v) {
        .null => allocator.dupe(u8, &[_]u8{ 0x81, 0x7E }), // NIL
        .bool => |b| allocator.dupe(u8, if (b) &[_]u8{ 0x81, 0x7C } else &[_]u8{ 0x81, 0x7D }),
        .integer => |i| if (i < 0) error.NegativeUnsupported else encodeBareInt(allocator, @intCast(i)),
        .number_string => |s| encodeBareInt(allocator, std.fmt.parseInt(u64, s, 10) catch return error.InvalidNumber),
        .float => error.FloatUnsupported, // v1: floats travel as UTF8 decimal strings, not raw JSON numbers
        .string => |s| leaf.serializeUtf8(allocator, s),
        .array => |arr| buildArray(allocator, arr),
        .object => |obj| buildObject(allocator, obj),
    };
}

fn encodeBareInt(allocator: Allocator, n: u64) FromJsonError![]u8 {
    var buf: [16]u8 = undefined;
    const len = try blip.encode(n, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn buildArray(allocator: Allocator, arr: std.json.Array) FromJsonError![]u8 {
    var elems: std.ArrayList([]const u8) = .empty;
    defer {
        for (elems.items) |e| allocator.free(e);
        elems.deinit(allocator);
    }
    for (arr.items) |item| try elems.append(allocator, try buildValue(allocator, item));
    return array.serializeArray(allocator, elems.items);
}

fn keyLessThan(keys: [][]const u8, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, keys[a], keys[b]);
}

fn buildObject(allocator: Allocator, obj: std.json.ObjectMap) FromJsonError![]u8 {
    // Reserved single-key tags (recognized only as the sole key).
    if (obj.count() == 1) {
        const k = obj.keys()[0];
        const val = obj.get(k).?;
        if (std.mem.eql(u8, k, "$int")) {
            const s = if (val == .string) val.string else return error.InvalidTag;
            return encodeBareInt(allocator, std.fmt.parseInt(u64, s, 10) catch return error.InvalidNumber);
        } else if (std.mem.eql(u8, k, "$b")) {
            const s = if (val == .string) val.string else return error.InvalidTag;
            const raw = pb.decode(allocator, s, .{}) catch return error.InvalidPrintableBinary;
            defer allocator.free(raw);
            return leaf.serializeData(allocator, raw);
        } else if (std.mem.eql(u8, k, "$blip")) {
            const s = if (val == .string) val.string else return error.InvalidTag;
            return pb.decode(allocator, s, .{}) catch return error.InvalidPrintableBinary; // raw container bytes, spliced in
        }
        // else: a genuine single-key dict — fall through
    }

    // A DICT: build key containers + value wire, then sort by key into canonical order.
    const n = obj.count();
    const keys = obj.keys();
    var order = try allocator.alloc(usize, n);
    defer allocator.free(order);
    for (0..n) |i| order[i] = i;
    std.sort.pdq(usize, order, keys, keyLessThan);

    var pairs = try allocator.alloc(dict.KeyValue, n);
    defer allocator.free(pairs);
    // Track every allocation so we can free after serializeDict copies them.
    var built: std.ArrayList([]const u8) = .empty;
    defer {
        for (built.items) |x| allocator.free(x);
        built.deinit(allocator);
    }
    for (order, 0..) |orig, out_i| {
        const key_str = keys[orig];
        const key_c = try leaf.serializeUtf8(allocator, key_str);
        try built.append(allocator, key_c);
        const val_wire = try buildValue(allocator, obj.get(key_str).?);
        try built.append(allocator, val_wire);
        pairs[out_i] = .{ .key = key_c, .value = val_wire };
    }
    return dict.serializeDict(allocator, pairs);
}

// =============================================================================
// Tests
// =============================================================================

fn expectJson(expected: []const u8, buf: []const u8) !void {
    const got = try toJson(testing.allocator, buf);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// MFIC oracle: for canonical wire, `wire → JSON → wire` must be byte-identical.
fn expectRoundTrip(wire: []const u8) !void {
    const a = testing.allocator;
    const json = try toJson(a, wire);
    defer a.free(json);
    const back = try fromJson(a, json);
    defer a.free(back);
    try testing.expectEqualSlices(u8, wire, back);
}

test "roundtrip: bare integers (small and $int-tagged)" {
    var b: [16]u8 = undefined;
    const cases = [_]u64{ 0, 1, 42, 127, 128, 65535, 65536, SAFE_INT_MAX, SAFE_INT_MAX + 1, std.math.maxInt(u64) };
    for (cases) |val| try expectRoundTrip(b[0..try blip.encode(val, &b)]);
}

test "roundtrip: sentinels" {
    try expectRoundTrip(&[_]u8{ 0x81, 0x7C });
    try expectRoundTrip(&[_]u8{ 0x81, 0x7D });
    try expectRoundTrip(&[_]u8{ 0x81, 0x7E });
}

test "roundtrip: UTF8 strings incl. escapes" {
    const a = testing.allocator;
    for ([_][]const u8{ "", "hello", "a\"b\\c\n\t\r", "unicode: café ☕" }) |s| {
        const u = try leaf.serializeUtf8(a, s);
        defer a.free(u);
        try expectRoundTrip(u);
    }
}

test "roundtrip: DATA byte-leaf (arbitrary bytes)" {
    const a = testing.allocator;
    const bytes = [_]u8{ 0x00, 0xFF, 0x1F, 0x1E, 0x80, 0x7F, 0x0A };
    const d = try leaf.serializeData(a, &bytes);
    defer a.free(d);
    try expectRoundTrip(d);
}

test "roundtrip: array of mixed scalars and a container" {
    const a = testing.allocator;
    var b: [16]u8 = undefined;
    const one = b[0..try blip.encode(1, &b)];
    const ux = try leaf.serializeUtf8(a, "x");
    defer a.free(ux);
    const arr = try array.serializeArray(a, &.{ one, ux, &[_]u8{ 0x81, 0x7C }, &[_]u8{ 0x81, 0x7E } });
    defer a.free(arr);
    try expectRoundTrip(arr);
}

test "roundtrip: dict with sorted keys, scalar + string values" {
    const a = testing.allocator;
    var b: [16]u8 = undefined;
    const kn = try leaf.serializeUtf8(a, "n");
    defer a.free(kn);
    const ks = try leaf.serializeUtf8(a, "s");
    defer a.free(ks);
    const v5 = b[0..try blip.encode(5, &b)];
    const vs = try leaf.serializeUtf8(a, "hi");
    defer a.free(vs);
    // keys "n" < "s" are canonically ordered
    const d = try dict.serializeDict(a, &.{ .{ .key = kn, .value = v5 }, .{ .key = ks, .value = vs } });
    defer a.free(d);
    try expectRoundTrip(d);
}

test "roundtrip: MAP / FILE / DIR / SEGMENT preserve type (lossless via \\$blip)" {
    const a = testing.allocator;
    var b: [16]u8 = undefined;

    // MAP with UNSORTED keys (z before a) — must NOT collapse to a sorted DICT
    const kz = try leaf.serializeUtf8(a, "z");
    defer a.free(kz);
    const ka = try leaf.serializeUtf8(a, "a");
    defer a.free(ka);
    const v9 = b[0..try blip.encode(9, &b)];
    const map = try dict.serializeMap(a, &.{ .{ .key = kz, .value = v9 }, .{ .key = ka, .value = v9 } });
    defer a.free(map);
    try expectRoundTrip(map);

    // FILE (ARRAY layout, type 5) — must NOT collapse to ARRAY
    const fe = try leaf.serializeUtf8(a, "meta");
    defer a.free(fe);
    const file = try array.serializeArrayLike(a, &.{fe}, .file, .{});
    defer a.free(file);
    try expectRoundTrip(file);

    // DIR (type 7, required keys pa+xh) — must NOT collapse to DICT
    const kpa = try leaf.serializeUtf8(a, "pa");
    defer a.free(kpa);
    const vpa = try leaf.serializeUtf8(a, "src");
    defer a.free(vpa);
    const kxh = try leaf.serializeUtf8(a, "xh");
    defer a.free(kxh);
    const vxh = try leaf.serializeData(a, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    defer a.free(vxh);
    const dir = try dict.serializeDir(a, &.{ .{ .key = kpa, .value = vpa }, .{ .key = kxh, .value = vxh } });
    defer a.free(dir);
    try expectRoundTrip(dir);

    // SEGMENT (type 9) — already escapes via $blip
    const seg = try segmentation.serializeSegment(a, 1, 1, 1, "payload", null);
    defer a.free(seg);
    try expectRoundTrip(seg);
}

/// Generate a random canonical BLIP value (for the property-based round-trip sweep).
/// Leaves at depth 0; arrays/dicts allowed deeper. Keys are lowercase ASCII (unique,
/// sorted) and avoid the `$` reserved-tag namespace. UTF8 content is ASCII (valid
/// UTF-8, exercises escaping); DATA content is arbitrary bytes.
fn genValue(allocator: Allocator, rand: std.Random, depth: u8) anyerror![]u8 {
    const max_kind: u8 = if (depth == 0) 4 else 6;
    switch (rand.uintLessThan(u8, max_kind)) {
        0 => { // bare integer (full u64 range → exercises $int)
            var buf: [16]u8 = undefined;
            return allocator.dupe(u8, buf[0..try blip.encode(rand.int(u64), &buf)]);
        },
        1 => return allocator.dupe(u8, &[_]u8{ 0x81, 0x7C + rand.uintLessThan(u8, 3) }), // TRUE/FALSE/NIL
        2 => { // UTF8 (ASCII content)
            const s = try allocator.alloc(u8, rand.uintLessThan(usize, 12));
            defer allocator.free(s);
            for (s) |*c| c.* = rand.uintLessThan(u8, 0x80);
            return leaf.serializeUtf8(allocator, s);
        },
        3 => { // DATA (arbitrary bytes)
            const s = try allocator.alloc(u8, rand.uintLessThan(usize, 12));
            defer allocator.free(s);
            rand.bytes(s);
            return leaf.serializeData(allocator, s);
        },
        4 => { // ARRAY
            var elems: std.ArrayList([]const u8) = .empty;
            defer {
                for (elems.items) |e| allocator.free(e);
                elems.deinit(allocator);
            }
            for (0..rand.uintLessThan(usize, 5)) |_| try elems.append(allocator, try genValue(allocator, rand, depth - 1));
            return array.serializeArray(allocator, elems.items);
        },
        else => { // DICT — unique, canonically-sorted keys
            var raw_keys: std.ArrayList([]u8) = .empty;
            defer {
                for (raw_keys.items) |k| allocator.free(k);
                raw_keys.deinit(allocator);
            }
            for (0..rand.uintLessThan(usize, 5)) |_| {
                const k = try allocator.alloc(u8, 1 + rand.uintLessThan(usize, 3));
                for (k) |*c| c.* = 'a' + rand.uintLessThan(u8, 26);
                try raw_keys.append(allocator, k);
            }
            std.sort.pdq([]u8, raw_keys.items, {}, struct {
                fn lt(_: void, a: []u8, bb: []u8) bool {
                    return std.mem.lessThan(u8, a, bb);
                }
            }.lt);
            var pairs: std.ArrayList(dict.KeyValue) = .empty;
            var built: std.ArrayList([]const u8) = .empty;
            defer {
                for (built.items) |x| allocator.free(x);
                built.deinit(allocator);
                pairs.deinit(allocator);
            }
            var prev: ?[]const u8 = null;
            for (raw_keys.items) |k| {
                if (prev) |p| if (std.mem.eql(u8, p, k)) continue;
                prev = k;
                const kc = try leaf.serializeUtf8(allocator, k);
                try built.append(allocator, kc);
                const v = try genValue(allocator, rand, depth - 1);
                try built.append(allocator, v);
                try pairs.append(allocator, .{ .key = kc, .value = v });
            }
            return dict.serializeDict(allocator, pairs.items);
        },
    }
}

test "roundtrip: property sweep over 3000 random container trees (seeded)" {
    var prng = std.Random.DefaultPrng.init(0xB11D_5EED_C0DEC);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        const wire = try genValue(testing.allocator, rand, 4);
        defer testing.allocator.free(wire);
        try expectRoundTrip(wire);
    }
}

test "roundtrip: nested dict/array" {
    const a = testing.allocator;
    // {"a":[true,null], "b": {"c": 9007199254740992}}
    const inner_arr = try array.serializeArray(a, &.{ &[_]u8{ 0x81, 0x7C }, &[_]u8{ 0x81, 0x7E } });
    defer a.free(inner_arr);
    var b: [16]u8 = undefined;
    const kc = try leaf.serializeUtf8(a, "c");
    defer a.free(kc);
    const vbig = b[0..try blip.encode(SAFE_INT_MAX + 1, &b)];
    const inner_dict = try dict.serializeDict(a, &.{.{ .key = kc, .value = vbig }});
    defer a.free(inner_dict);
    const ka = try leaf.serializeUtf8(a, "a");
    defer a.free(ka);
    const kb = try leaf.serializeUtf8(a, "b");
    defer a.free(kb);
    const d = try dict.serializeDict(a, &.{ .{ .key = ka, .value = inner_arr }, .{ .key = kb, .value = inner_dict } });
    defer a.free(d);
    try expectRoundTrip(d);
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
