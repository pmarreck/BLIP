const std = @import("std");
const testing = std.testing;

// Import all encodings
const blip = @import("blip.zig");
const leb128 = @import("leb128.zig");
const protobuf = @import("protobuf_varint.zig");
const asn1 = @import("asn1_length.zig");
const prefix_varint = @import("prefix_varint.zig");
const sqlite = @import("sqlite_varint.zig");

fn fuzzRoundtrip(comptime Enc: type, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [16]u8 = undefined;

    for (0..100_000) |_| {
        const v = random.int(u64);
        const n = Enc.encode(v, &buf) catch continue; // skip values this encoding can't handle
        const result = Enc.decode(buf[0..n]) catch {
            return error.TestUnexpectedResult; // encode succeeded but decode failed = bug
        };
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

test "fuzz BLIP roundtrip 100K" {
    try fuzzRoundtrip(blip, 0xDEADBEEF);
}

test "fuzz LEB128 roundtrip 100K" {
    try fuzzRoundtrip(leb128, 0xCAFEBABE);
}

test "fuzz Protobuf roundtrip 100K" {
    try fuzzRoundtrip(protobuf, 0xFACEFEED);
}

test "fuzz ASN.1 roundtrip 100K" {
    try fuzzRoundtrip(asn1, 0xB16B00B5);
}

test "fuzz PrefixVarint roundtrip 100K" {
    try fuzzRoundtrip(prefix_varint, 0xBAADF00D);
}

test "fuzz SQLite roundtrip 100K" {
    try fuzzRoundtrip(sqlite, 0x8BADF00D);
}

test "fuzz SLEB128 roundtrip 100K" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();
    var buf: [16]u8 = undefined;

    for (0..100_000) |_| {
        const v = random.int(i64);
        const n = leb128.signedEncode(v, &buf) catch continue;
        const result = leb128.signedDecode(buf[0..n]) catch return error.TestUnexpectedResult;
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

test "fuzz Protobuf ZigZag roundtrip 100K" {
    var prng = std.Random.DefaultPrng.init(0xF00DCAFE);
    const random = prng.random();
    var buf: [16]u8 = undefined;

    for (0..100_000) |_| {
        const v = random.int(i64);
        const n = protobuf.signedEncode(v, &buf) catch continue;
        const result = protobuf.signedDecode(buf[0..n]) catch return error.TestUnexpectedResult;
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}
