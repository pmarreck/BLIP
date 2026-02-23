const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    if (builtin.mode == .Debug) {
        try stderr.print("\x1b[33mWARNING: debug build — benchmarks will not be representative\x1b[0m\n", .{});
    }

    try stderr.print("BLIP benchmark runner — not yet implemented\n", .{});
    try stderr.flush();
}
