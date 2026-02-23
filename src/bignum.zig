const std = @import("std");

/// Errors for bignum LE arithmetic operations.
pub const Error = error{BufferTooSmall};

/// Add two LE byte slices with carry propagation. Returns bytes used in result.
/// This is the "direct encoded arithmetic" that BLIP enables —
/// you can operate directly on the payload bytes without decoding.
pub fn addLE(a: []const u8, b: []const u8, out: []u8) Error!usize {
    const max_len = @max(a.len, b.len);
    // Result can be at most one byte longer than the longer input (carry)
    if (out.len < max_len + 1) return Error.BufferTooSmall;

    var carry: u16 = 0;
    var i: usize = 0;
    while (i < max_len or carry != 0) : (i += 1) {
        if (i >= out.len) return Error.BufferTooSmall;
        const av: u16 = if (i < a.len) a[i] else 0;
        const bv: u16 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        out[i] = @intCast(sum & 0xFF);
        carry = sum >> 8;
    }

    // Trim trailing zeros, but keep at least one byte
    var result_len = i;
    while (result_len > 1 and out[result_len - 1] == 0) {
        result_len -= 1;
    }

    return result_len;
}

/// Multiply two LE byte slices (schoolbook O(n*m)). Returns bytes used in result.
pub fn mulLE(a: []const u8, b: []const u8, out: []u8) Error!usize {
    const max_result_len = a.len + b.len;
    if (out.len < max_result_len) return Error.BufferTooSmall;

    // Zero out the result buffer
    @memset(out[0..max_result_len], 0);

    // Schoolbook multiplication
    for (0..a.len) |i| {
        var carry: u16 = 0;
        for (0..b.len) |j| {
            const product = @as(u16, a[i]) * @as(u16, b[j]) + @as(u16, out[i + j]) + carry;
            out[i + j] = @intCast(product & 0xFF);
            carry = product >> 8;
        }
        if (carry > 0) {
            out[i + b.len] += @intCast(carry);
        }
    }

    // Trim trailing zeros, but keep at least one byte
    var result_len = max_result_len;
    while (result_len > 1 and out[result_len - 1] == 0) {
        result_len -= 1;
    }

    return result_len;
}

/// Compare two LE byte slices. Returns .lt, .eq, or .gt.
pub fn compareLE(a: []const u8, b: []const u8) std.math.Order {
    // Find effective lengths (ignoring trailing zeros)
    var a_eff = a.len;
    while (a_eff > 0 and a[a_eff - 1] == 0) {
        a_eff -= 1;
    }
    var b_eff = b.len;
    while (b_eff > 0 and b[b_eff - 1] == 0) {
        b_eff -= 1;
    }

    // Compare effective lengths first
    if (a_eff != b_eff) {
        return if (a_eff < b_eff) .lt else .gt;
    }

    // Same effective length: compare from most significant byte down
    if (a_eff == 0) return .eq;

    var i = a_eff;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) {
            return if (a[i] < b[i]) .lt else .gt;
        }
    }

    return .eq;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

// ---------------------------------------------------------------------------
// addLE tests
// ---------------------------------------------------------------------------

test "addLE: 255 + 1 = 256" {
    var out: [16]u8 = undefined;
    const n = try addLE(&[_]u8{0xFF}, &[_]u8{0x01}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, out[0..n]);
}

test "addLE: 256 + 256 = 512" {
    var out: [16]u8 = undefined;
    const n = try addLE(&[_]u8{ 0x00, 0x01 }, &[_]u8{ 0x00, 0x01 }, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02 }, out[0..n]);
}

test "addLE: 65535 + 1 = 65536" {
    var out: [16]u8 = undefined;
    const n = try addLE(&[_]u8{ 0xFF, 0xFF }, &[_]u8{0x01}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01 }, out[0..n]);
}

test "addLE: 1000 + 64536 = 65536" {
    var out: [16]u8 = undefined;
    // 1000 LE = [0xE8, 0x03], 64536 LE = [0x18, 0xFC]
    const n = try addLE(&[_]u8{ 0xE8, 0x03 }, &[_]u8{ 0x18, 0xFC }, &out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01 }, out[0..n]);
}

test "addLE: 0 + 0 = 0" {
    var out: [16]u8 = undefined;
    const n = try addLE(&[_]u8{0x00}, &[_]u8{0x00}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, out[0..n]);
}

test "addLE: 0 + 1 = 1" {
    var out: [16]u8 = undefined;
    const n = try addLE(&[_]u8{0x00}, &[_]u8{0x01}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, out[0..n]);
}

test "addLE: identity (a + 0 = a)" {
    var out: [16]u8 = undefined;
    const a = [_]u8{ 0xE8, 0x03 }; // 1000
    const n = try addLE(&a, &[_]u8{0x00}, &out);
    try testing.expectEqualSlices(u8, &a, out[0..n]);
}

test "addLE: commutativity" {
    var out1: [16]u8 = undefined;
    var out2: [16]u8 = undefined;
    const a = [_]u8{ 0xFF, 0x01 }; // 511
    const b = [_]u8{ 0x42, 0x03 }; // 834
    const n1 = try addLE(&a, &b, &out1);
    const n2 = try addLE(&b, &a, &out2);
    try testing.expectEqualSlices(u8, out1[0..n1], out2[0..n2]);
}

// ---------------------------------------------------------------------------
// mulLE tests
// ---------------------------------------------------------------------------

test "mulLE: 256 * 256 = 65536" {
    var out: [16]u8 = undefined;
    // 256 LE = [0x00, 0x01]
    const n = try mulLE(&[_]u8{ 0x00, 0x01 }, &[_]u8{ 0x00, 0x01 }, &out);
    // 65536 = 0x10000 LE trimmed = [0x00, 0x00, 0x01]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01 }, out[0..n]);
}

test "mulLE: 255 * 255 = 65025" {
    var out: [16]u8 = undefined;
    const n = try mulLE(&[_]u8{0xFF}, &[_]u8{0xFF}, &out);
    // 65025 = 0xFE01 LE = [0x01, 0xFE]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0xFE }, out[0..n]);
}

test "mulLE: 1000 * 1000 = 1000000" {
    var out: [16]u8 = undefined;
    // 1000 LE = [0xE8, 0x03]
    const n = try mulLE(&[_]u8{ 0xE8, 0x03 }, &[_]u8{ 0xE8, 0x03 }, &out);
    // 1000000 = 0x0F4240 LE = [0x40, 0x42, 0x0F]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x40, 0x42, 0x0F }, out[0..n]);
}

test "mulLE: anything * 0 = 0" {
    var out: [16]u8 = undefined;
    const n = try mulLE(&[_]u8{ 0xE8, 0x03 }, &[_]u8{0x00}, &out);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, out[0..n]);
}

test "mulLE: anything * 1 = identity" {
    var out: [16]u8 = undefined;
    const a = [_]u8{ 0xE8, 0x03 }; // 1000
    const n = try mulLE(&a, &[_]u8{0x01}, &out);
    try testing.expectEqualSlices(u8, &a, out[0..n]);
}

test "mulLE: commutativity" {
    var out1: [16]u8 = undefined;
    var out2: [16]u8 = undefined;
    const a = [_]u8{ 0xFF, 0x01 }; // 511
    const b = [_]u8{ 0x42, 0x03 }; // 834
    const n1 = try mulLE(&a, &b, &out1);
    const n2 = try mulLE(&b, &a, &out2);
    try testing.expectEqualSlices(u8, out1[0..n1], out2[0..n2]);
}

test "mulLE: 2 * 128 = 256" {
    var out: [16]u8 = undefined;
    const n = try mulLE(&[_]u8{0x02}, &[_]u8{0x80}, &out);
    // 256 LE = [0x00, 0x01]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01 }, out[0..n]);
}

// ---------------------------------------------------------------------------
// compareLE tests
// ---------------------------------------------------------------------------

test "compareLE: equal values" {
    try testing.expectEqual(std.math.Order.eq, compareLE(&[_]u8{ 0xE8, 0x03 }, &[_]u8{ 0xE8, 0x03 }));
}

test "compareLE: less than" {
    // 255 < 256
    try testing.expectEqual(std.math.Order.lt, compareLE(&[_]u8{0xFF}, &[_]u8{ 0x00, 0x01 }));
}

test "compareLE: greater than" {
    // 256 > 255
    try testing.expectEqual(std.math.Order.gt, compareLE(&[_]u8{ 0x00, 0x01 }, &[_]u8{0xFF}));
}

test "compareLE: same effective length, different values" {
    // 1000 (0xE8, 0x03) vs 999 (0xE7, 0x03)
    try testing.expectEqual(std.math.Order.gt, compareLE(&[_]u8{ 0xE8, 0x03 }, &[_]u8{ 0xE7, 0x03 }));
    try testing.expectEqual(std.math.Order.lt, compareLE(&[_]u8{ 0xE7, 0x03 }, &[_]u8{ 0xE8, 0x03 }));
}

test "compareLE: trailing zeros are ignored" {
    // [0x01, 0x00] should equal [0x01]
    try testing.expectEqual(std.math.Order.eq, compareLE(&[_]u8{ 0x01, 0x00 }, &[_]u8{0x01}));
}

test "compareLE: both zero" {
    try testing.expectEqual(std.math.Order.eq, compareLE(&[_]u8{0x00}, &[_]u8{0x00}));
}

test "compareLE: zero vs non-zero" {
    try testing.expectEqual(std.math.Order.lt, compareLE(&[_]u8{0x00}, &[_]u8{0x01}));
    try testing.expectEqual(std.math.Order.gt, compareLE(&[_]u8{0x01}, &[_]u8{0x00}));
}

// ---------------------------------------------------------------------------
// Buffer too small tests
// ---------------------------------------------------------------------------

test "addLE: buffer too small returns error" {
    var out: [1]u8 = undefined;
    const result = addLE(&[_]u8{0xFF}, &[_]u8{0x01}, &out);
    try testing.expectError(Error.BufferTooSmall, result);
}

test "mulLE: buffer too small returns error" {
    var out: [1]u8 = undefined;
    const result = mulLE(&[_]u8{ 0x00, 0x01 }, &[_]u8{ 0x00, 0x01 }, &out);
    try testing.expectError(Error.BufferTooSmall, result);
}
