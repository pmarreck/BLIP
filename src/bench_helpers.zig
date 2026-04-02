//! Shared benchmark helpers — JSONL logging, baseline comparison, regression detection.
//! Used by both microbenchmarks (in test suite) and the full benchmark suite.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BenchResult = struct {
    name: []const u8,
    ns_per_op: u64,
    throughput_mb_s: ?f64 = null,
    iterations: ?u64 = null,
    timestamp: i64,
};

/// Append a benchmark result to a JSONL file.
pub fn appendJsonl(path: []const u8, result: BenchResult) !void {
    const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try std.json.stringify(result, .{}, file.writer());
    try file.writer().writeByte('\n');
}

/// Load the baseline (median of last 5) for a named benchmark from JSONL.
pub fn loadBaseline(
    path: []const u8,
    name: []const u8,
    allocator: Allocator,
) !?u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var last_values: [5]u64 = undefined;
    var count: usize = 0;
    var buf: [4096]u8 = undefined;
    const reader = file.reader();
    while (true) {
        const line = reader.readUntilDelimiterOrEof(&buf, '\n') catch break;
        if (line == null) break;
        const parsed = std.json.parseFromSlice(
            BenchResult,
            allocator,
            line.?,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.name, name)) {
            last_values[count % 5] = parsed.value.ns_per_op;
            count += 1;
        }
    }
    if (count == 0) return null;
    const n = @min(count, 5);
    var slice = last_values[0..n];
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
    return slice[n / 2];
}

/// Run a benchmark: warm up, measure, compute stats.
pub fn runBench(
    name: []const u8,
    iterations: u64,
    input_bytes: ?u64,
    func: *const fn () void,
) BenchResult {
    // Warm up (10% of iterations, minimum 10)
    const warmup = @max(iterations / 10, 10);
    for (0..warmup) |_| func();

    var timer = std.time.Timer.start() catch @panic("Timer.start failed");
    _ = timer.lap();
    for (0..iterations) |_| func();
    const elapsed_ns = timer.read();

    const ns_per_op = elapsed_ns / iterations;
    const throughput: ?f64 = if (input_bytes) |bytes|
        @as(f64, @floatFromInt(bytes * iterations)) /
            (@as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s) /
            (1024.0 * 1024.0)
    else
        null;

    return .{
        .name = name,
        .ns_per_op = ns_per_op,
        .throughput_mb_s = throughput,
        .iterations = iterations,
        .timestamp = std.time.timestamp(),
    };
}

/// Check a result against baseline. Returns true if regression detected.
pub fn checkRegression(
    result: BenchResult,
    baseline_ns: ?u64,
    stderr: anytype,
) bool {
    if (baseline_ns) |base_ns| {
        const ratio = @as(f64, @floatFromInt(result.ns_per_op)) /
            @as(f64, @floatFromInt(base_ns));
        if (ratio > 1.15) {
            stderr.print(
                "\n*** PERF REGRESSION: {s} -- {d} ns/op vs baseline {d} ns/op (+{d:.1}%) ***\n",
                .{ result.name, result.ns_per_op, base_ns, (ratio - 1.0) * 100.0 },
            ) catch {};
            return true;
        }
        if (ratio < 0.85) {
            stderr.print(
                "\n>>> PERF IMPROVEMENT: {s} -- {d} ns/op vs baseline {d} ns/op ({d:.1}%) <<<\n",
                .{ result.name, result.ns_per_op, base_ns, (ratio - 1.0) * 100.0 },
            ) catch {};
        }
    }
    return false;
}

/// Format ns/op for human display.
pub fn formatNsPerOp(ns: u64) [32]u8 {
    var buf: [32]u8 = undefined;
    if (ns >= 1_000_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2}s", .{@as(f64, @floatFromInt(ns)) / 1e9}) catch {};
    } else if (ns >= 1_000_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1e6}) catch {};
    } else if (ns >= 1_000) {
        _ = std.fmt.bufPrint(&buf, "{d:.2}µs", .{@as(f64, @floatFromInt(ns)) / 1e3}) catch {};
    } else {
        _ = std.fmt.bufPrint(&buf, "{d}ns", .{ns}) catch {};
    }
    return buf;
}
