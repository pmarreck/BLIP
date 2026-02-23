const std = @import("std");
const builtin = @import("builtin");

// C FFI declarations — main.zig links against the static lib,
// so it accesses BLIP through the C FFI symbols.
// Do NOT @import("blip") — the point is to dogfood the C FFI.
extern fn blip_encode(value: u64, out_buf: [*]u8, out_cap: usize) i32;
extern fn blip_decode(encoded: [*]const u8, encoded_len: usize, out_value: *u64) i32;
extern fn blip_is_sentinel(encoded: [*]const u8, encoded_len: usize) bool;
extern fn blip_encoded_size(value: u64) i32;

fn archName() []const u8 {
    return @tagName(builtin.cpu.arch);
}

fn osName() []const u8 {
    return @tagName(builtin.os.tag);
}

pub fn main() !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    if (builtin.mode == .Debug) {
        try stderr.print("\x1b[33mWARNING: debug build \xe2\x80\x94 benchmarks will not be representative\x1b[0m\n", .{});
    }

    // Parse args
    var args = std.process.args();
    _ = args.next(); // skip program name

    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--about")) {
            try stdout.print("BLIP v0.1.0 {s}-{s}\n", .{ archName(), osName() });
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.print(
                \\Usage: blip-bench [OPTIONS]
                \\
                \\Options:
                \\  --about    Print version and platform info
                \\  -h, --help Print this help message
                \\
                \\Default: run quick self-test through C FFI
                \\
            , .{});
            try stdout.flush();
            return;
        }
    }

    // Default action: quick self-test calling through C FFI
    try stdout.print("BLIP C FFI self-test\n", .{});

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test 1: encode/decode roundtrip for small values
    {
        const test_values = [_]u64{ 0, 1, 42, 127, 128, 255, 256, 1000, 65535, 65536, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
        for (test_values) |value| {
            var buf: [16]u8 = undefined;
            const enc_len = blip_encode(value, &buf, buf.len);
            if (enc_len < 0) {
                try stdout.print("  FAIL: blip_encode({d}) returned error\n", .{value});
                failed += 1;
                continue;
            }

            var decoded: u64 = undefined;
            const dec_len = blip_decode(&buf, @intCast(enc_len), &decoded);
            if (dec_len < 0) {
                try stdout.print("  FAIL: blip_decode failed for value {d}\n", .{value});
                failed += 1;
                continue;
            }

            if (decoded != value) {
                try stdout.print("  FAIL: roundtrip {d} != {d}\n", .{ value, decoded });
                failed += 1;
                continue;
            }

            if (dec_len != enc_len) {
                try stdout.print("  FAIL: bytes_read {d} != bytes_written {d}\n", .{ dec_len, enc_len });
                failed += 1;
                continue;
            }
            passed += 1;
        }
    }

    // Test 2: blip_encoded_size matches actual encoding
    {
        const test_values = [_]u64{ 0, 127, 128, 255, 256, 65535, 0xFFFFFFFF };
        for (test_values) |value| {
            var buf: [16]u8 = undefined;
            const actual = blip_encode(value, &buf, buf.len);
            const predicted = blip_encoded_size(value);
            if (actual != predicted) {
                try stdout.print("  FAIL: encoded_size({d}): predicted {d}, actual {d}\n", .{ value, predicted, actual });
                failed += 1;
            } else {
                passed += 1;
            }
        }
    }

    // Test 3: sentinel detection
    {
        // Encode sentinel-like value (0x81, 0x00) manually
        const sentinel = [_]u8{ 0x81, 0x00 };
        if (blip_is_sentinel(&sentinel, sentinel.len)) {
            passed += 1;
        } else {
            try stdout.print("  FAIL: sentinel not detected\n", .{});
            failed += 1;
        }

        // Non-sentinel: immediate value
        const non_sentinel = [_]u8{0x00};
        if (!blip_is_sentinel(&non_sentinel, non_sentinel.len)) {
            passed += 1;
        } else {
            try stdout.print("  FAIL: false sentinel detected\n", .{});
            failed += 1;
        }

        // Non-sentinel: valid L=1 encoding of 128
        const valid_l1 = [_]u8{ 0x81, 0x80 };
        if (!blip_is_sentinel(&valid_l1, valid_l1.len)) {
            passed += 1;
        } else {
            try stdout.print("  FAIL: valid L=1 encoding falsely detected as sentinel\n", .{});
            failed += 1;
        }
    }

    try stdout.print("{d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        try stdout.flush();
        try stderr.print("SELF-TEST FAILED\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    try stdout.print("All C FFI self-tests passed.\n", .{});
    try stdout.flush();
    try stderr.flush();
}
