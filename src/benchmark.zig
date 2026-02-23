const std = @import("std");
const blip = @import("blip");

// Benchmark harness for BLIP vs LEB128 vs other encodings.
// Will exercise the Zig module directly (not through C FFI)
// for accurate cycle-level comparison.

pub fn main() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    try stderr.print("BLIP benchmarks — not yet implemented\n", .{});
    try stderr.flush();
}

test "benchmark placeholder" {
    _ = blip;
    try std.testing.expect(true);
}
