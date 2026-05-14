//! PrintableBinary CLI - Thin I/O adapter around the core library
//!
//! This is a hexagonal architecture adapter that handles:
//! - Command line argument parsing
//! - File/stdin reading
//! - Stdout/stderr writing
//! - Exit codes
//!
//! All encoding/decoding logic is in the core library.

const std = @import("std");
const pb = @import("printable_binary");

const Options = struct {
    decode_mode: bool = false,
    passthrough_mode: bool = false,
    spaces_mode: bool = false,
    tabs_mode: bool = false,
    crlf_mode: bool = false,
    strip_whitespace: bool = false,
    format_mode: bool = false,
    format_group: usize = 8,
    format_groups_per_line: usize = 10,
    help_mode: bool = false,
    mappings_mode: MappingsMode = .none,
    input_file: ?[]const u8 = null,
    preserve_chars: ?[]const u8 = null, // null = not set, allocated if set
    range_start: ?i64 = null,
    range_end: ?i64 = null,
    no_double_encode_check: bool = false,
    hexlike: bool = false,
};

const MappingsMode = enum { none, table, json, csv };

// ============================================================================
// I/O Adapters (Zig 0.16 std.Io)
// ============================================================================

fn readInput(io: std.Io, allocator: std.mem.Allocator, file_path: ?[]const u8) ![]u8 {
    if (file_path) |path| {
        if (!std.mem.eql(u8, path, "-")) {
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            var rd_buf: [4096]u8 = undefined;
            var rd = file.reader(io, &rd_buf);
            return try rd.interface.allocRemaining(allocator, .unlimited);
        }
    }
    const stdin = std.Io.File.stdin();
    var rd_buf: [4096]u8 = undefined;
    var rd = stdin.reader(io, &rd_buf);
    return try rd.interface.allocRemaining(allocator, .unlimited);
}

fn writeOutput(io: std.Io, data: []const u8, to_stderr: bool) !void {
    var buf: [4096]u8 = undefined;
    if (to_stderr) {
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    } else {
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll(data);
        try w.interface.flush();
    }
}

const G_ENV = struct {
    var mute: bool = false;
};

fn writeStats(comptime fmt: []const u8, args: anytype) void {
    if (G_ENV.mute) return;
    // Use unbuffered direct write for stderr messages
    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    _ = std.posix.system.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

// ============================================================================
// Argument Parsing (I/O boundary - reads from OS)
// ============================================================================

fn parseFormatSpec(spec: []const u8) !struct { group: usize, per_line: usize } {
    var it = std.mem.splitScalar(u8, spec, 'x');
    const group_str = it.next() orelse return error.InvalidFormat;
    const per_line_str = it.next() orelse return error.InvalidFormat;
    if (it.next() != null) return error.InvalidFormat;

    const group = std.fmt.parseInt(usize, group_str, 10) catch return error.InvalidFormat;
    const per_line = std.fmt.parseInt(usize, per_line_str, 10) catch return error.InvalidFormat;

    if (group == 0 or per_line == 0) return error.InvalidFormat;
    return .{ .group = group, .per_line = per_line };
}

// Parse offset value (supports hex 0x prefix and decimal, optionally negative)
fn parseOffsetValue(s: []const u8) !i64 {
    if (s.len == 0) return error.InvalidFormat;
    if (s[0] == '-') {
        // Negative value
        const abs = try parseOffsetValue(s[1..]);
        return -abs;
    }
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        const val = std.fmt.parseInt(u64, s[2..], 16) catch return error.InvalidFormat;
        return @intCast(val);
    }
    const val = std.fmt.parseInt(i64, s, 10) catch return error.InvalidFormat;
    return val;
}

// Parse range spec "X-Y", "-Y", "X-"
fn parseRangeSpec(spec: []const u8) !struct { start: ?i64, end: ?i64 } {
    if (spec.len == 0) return error.InvalidFormat;

    // Find separator hyphen (not inside hex prefix)
    var sep_idx: ?usize = null;
    var i: usize = 0;
    // Skip hex prefix if present
    if (spec.len > 2 and spec[0] == '0' and (spec[1] == 'x' or spec[1] == 'X')) {
        i = 2;
        while (i < spec.len and std.ascii.isHex(spec[i])) : (i += 1) {}
    } else {
        while (i < spec.len and std.ascii.isDigit(spec[i])) : (i += 1) {}
    }
    if (i < spec.len and spec[i] == '-') {
        sep_idx = i;
    } else if (spec[0] == '-') {
        sep_idx = 0;
    } else {
        return error.InvalidFormat;
    }

    const sep = sep_idx.?;
    var start: ?i64 = null;
    var end_val: ?i64 = null;

    if (sep > 0) {
        start = try parseOffsetValue(spec[0..sep]);
    }
    if (sep + 1 < spec.len) {
        end_val = try parseOffsetValue(spec[sep + 1 ..]);
    }

    return .{ .start = start, .end = end_val };
}

// Check if string looks like a positional range
fn isPositionalRange(s: []const u8) bool {
    if (s.len == 0 or s[0] == '-') return false;
    var i: usize = 0;
    // Skip hex prefix or digits
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        i = 2;
        while (i < s.len and std.ascii.isHex(s[i])) : (i += 1) {}
    } else if (std.ascii.isDigit(s[0])) {
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    } else {
        return false;
    }
    return i < s.len and s[i] == '-';
}

fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            if (i + 1 < args.len) opts.input_file = try allocator.dupe(u8, args[i + 1]);
            break;
        }

        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            if (isPositionalRange(arg)) {
                if (parseRangeSpec(arg)) |parsed| {
                    if (parsed.start) |s| opts.range_start = s;
                    if (parsed.end) |e| opts.range_end = e;
                    continue;
                } else |_| {}
            }
            if (opts.input_file != null) return error.MultipleInputFiles;
            opts.input_file = try allocator.dupe(u8, arg);
            continue;
        }

        if (arg.len > 1 and arg[1] == '-') {
            const name = arg[2..];
            if (std.mem.startsWith(u8, name, "format=")) {
                const parsed = try parseFormatSpec(name[7..]);
                opts.format_mode = true;
                opts.format_group = parsed.group;
                opts.format_groups_per_line = parsed.per_line;
            } else if (std.mem.startsWith(u8, name, "preserve=")) {
                opts.preserve_chars = try allocator.dupe(u8, name[9..]);
            } else if (std.mem.eql(u8, name, "preserve")) {
                // --preserve CHARS (space-separated)
                if (i + 1 < args.len) {
                    i += 1;
                    opts.preserve_chars = try allocator.dupe(u8, args[i]);
                } else {
                    return error.MissingValue;
                }
            } else if (std.mem.eql(u8, name, "decode")) {
                opts.decode_mode = true;
            } else if (std.mem.eql(u8, name, "passthrough")) {
                opts.passthrough_mode = true;
            } else if (std.mem.eql(u8, name, "spaces")) {
                opts.spaces_mode = true;
            } else if (std.mem.eql(u8, name, "tabs")) {
                opts.tabs_mode = true;
            } else if (std.mem.eql(u8, name, "crlf")) {
                opts.crlf_mode = true;
            } else if (std.mem.eql(u8, name, "preserve-whitespace")) {
                opts.spaces_mode = true;
                opts.tabs_mode = true;
                opts.crlf_mode = true;
            } else if (std.mem.eql(u8, name, "strip-whitespace")) {
                opts.strip_whitespace = true;
            } else if (std.mem.eql(u8, name, "range")) {
                if (i + 1 < args.len) {
                    i += 1;
                    const parsed = parseRangeSpec(args[i]) catch return error.InvalidFormat;
                    if (parsed.start) |s| opts.range_start = s;
                    if (parsed.end) |e| opts.range_end = e;
                } else {
                    return error.MissingValue;
                }
            } else if (std.mem.startsWith(u8, name, "range=")) {
                const parsed = parseRangeSpec(name[6..]) catch return error.InvalidFormat;
                if (parsed.start) |s| opts.range_start = s;
                if (parsed.end) |e| opts.range_end = e;
            } else if (std.mem.eql(u8, name, "start")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.range_start = parseOffsetValue(args[i]) catch return error.InvalidFormat;
                } else {
                    return error.MissingValue;
                }
            } else if (std.mem.startsWith(u8, name, "start=")) {
                opts.range_start = parseOffsetValue(name[6..]) catch return error.InvalidFormat;
            } else if (std.mem.eql(u8, name, "end")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opts.range_end = parseOffsetValue(args[i]) catch return error.InvalidFormat;
                } else {
                    return error.MissingValue;
                }
            } else if (std.mem.startsWith(u8, name, "end=")) {
                opts.range_end = parseOffsetValue(name[4..]) catch return error.InvalidFormat;
            } else if (std.mem.eql(u8, name, "format")) {
                opts.format_mode = true;
            } else if (std.mem.eql(u8, name, "mappings")) {
                opts.mappings_mode = .table;
            } else if (std.mem.eql(u8, name, "mappings-json")) {
                opts.mappings_mode = .json;
            } else if (std.mem.eql(u8, name, "mappings-csv")) {
                opts.mappings_mode = .csv;
            } else if (std.mem.eql(u8, name, "no-double-encode-check")) {
                opts.no_double_encode_check = true;
            } else if (std.mem.eql(u8, name, "hexlike")) {
                opts.hexlike = true;
            } else if (std.mem.eql(u8, name, "help")) {
                opts.help_mode = true;
            } else {
                return error.UnknownOption;
            }
        } else {
            // Short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'd' => opts.decode_mode = true,
                    'p' => opts.passthrough_mode = true,
                    's' => opts.spaces_mode = true,
                    't' => opts.tabs_mode = true,
                    'n' => opts.crlf_mode = true,
                    'w' => {
                        opts.spaces_mode = true;
                        opts.tabs_mode = true;
                        opts.crlf_mode = true;
                    },
                    'S' => opts.strip_whitespace = true,
                    'X' => opts.hexlike = true,
                    'h' => opts.help_mode = true,
                    'f' => {
                        if (j + 1 < arg.len) {
                            const parsed = parseFormatSpec(arg[j + 1 ..]) catch return error.InvalidFormat;
                            opts.format_mode = true;
                            opts.format_group = parsed.group;
                            opts.format_groups_per_line = parsed.per_line;
                            break;
                        } else {
                            opts.format_mode = true;
                        }
                    },
                    'P' => {
                        if (j + 1 < arg.len) {
                            opts.preserve_chars = try allocator.dupe(u8, arg[j + 1 ..]);
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            opts.preserve_chars = try allocator.dupe(u8, args[i]);
                        } else {
                            return error.MissingValue;
                        }
                    },
                    else => return error.UnknownOption,
                }
            }
        }
    }
    return opts;
}

// ============================================================================
// Output Formatting (uses core library, writes to I/O)
// ============================================================================

fn printUsage(io: std.Io) void {
    const help =
        \\PrintableBinary Zig - Encode binary data as printable UTF-8 and decode it back
        \\
        \\Usage: printable-binary-zig [options] [file]
        \\
        \\Options:
        \\  -d, --decode       Decode mode (default is encode mode)
        \\  -p, --passthrough  Pass input to stdout unchanged, send encoded data to stderr
        \\
        \\Encoding modes:
        \\  -X, --hexlike      Hexlike mode: passthrough ASCII stays as-is, all other bytes
        \\                     shown as uppercase hex runs prefixed by Οχ (Greek Omicron+Chi,
        \\                     NOT ASCII 0x — beware when copying hex for other purposes).
        \\                     Use with -d to decode hexlike-encoded data back to binary.
        \\
        \\Encode options (preserve literal characters instead of encoding):
        \\  -s, --spaces       Preserve literal spaces (don't encode to visible glyph)
        \\  -t, --tabs         Preserve literal tabs (don't encode to visible glyph)
        \\  -n, --crlf         Preserve literal CR/LF (don't encode to visible glyph)
        \\  -w, --preserve-whitespace  Shorthand for -stn (preserve all whitespace)
        \\  -P, --preserve=CHARS       Preserve specific characters
        \\
        \\Range options (select byte range from input before processing):
        \\  --range X-Y              Byte range, 0-indexed inclusive (e.g., --range 0-9)
        \\  --start X                Start offset (negative = from end, like xxd -s)
        \\  --end Y                  End offset (inclusive)
        \\  X-Y (positional)         Shorthand for --range X-Y
        \\  Hex offsets supported: --range 0x0A-0xFF
        \\  Omitted bounds: --range -9 (first 10 bytes), --range 10- (byte 10 to EOF)
        \\
        \\Encode detection:
        \\  --no-double-encode-check   Skip detection of already-encoded input
        \\
        \\Decode options:
        \\  -S, --strip-whitespace     Strip whitespace before decoding (for formatted input)
        \\
        \\Format and output options:
        \\  -f[=NxM], --format[=NxM]   Format output in groups
        \\                              Default: 8x10 (groups of 8 chars, 10 groups per line)
        \\  --mappings         Show the byte-to-character mapping table
        \\  --mappings-json    Output mappings as JSON
        \\  --mappings-csv     Output mappings as CSV
        \\  -h, --help         Show this help
        \\
        \\If no file is specified, input is read from stdin.
        \\
    ;
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.writeAll(help) catch {};
    w.interface.flush() catch {};
}

// ASCII names for control characters and special bytes
const ascii_names = [_][]const u8{
    "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL",
    "BS", "TAB", "LF", "VT", "FF", "CR", "SO", "SI",
    "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB",
    "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US",
    "SPACE", "!", "\"", "#", "$", "%", "&", "'",
    "(", ")", "*", "+", ",", "-", ".", "/",
    "0", "1", "2", "3", "4", "5", "6", "7",
    "8", "9", ":", ";", "<", "=", ">", "?",
    "@", "A", "B", "C", "D", "E", "F", "G",
    "H", "I", "J", "K", "L", "M", "N", "O",
    "P", "Q", "R", "S", "T", "U", "V", "W",
    "X", "Y", "Z", "[", "\\", "]", "^", "_",
    "`", "a", "b", "c", "d", "e", "f", "g",
    "h", "i", "j", "k", "l", "m", "n", "o",
    "p", "q", "r", "s", "t", "u", "v", "w",
    "x", "y", "z", "{", "|", "}", "~", "DEL",
};

fn writeStdoutRaw(data: []const u8) void {
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderrRaw(data: []const u8) void {
    _ = std.posix.system.write(std.posix.STDERR_FILENO, data.ptr, data.len);
}

fn printMappings(mode: MappingsMode) !void {
    var line_buf: [256]u8 = undefined;
    switch (mode) {
        .table => {
            writeStdoutRaw("Byte   Dec   ASCII        Mapping\n");
            for (0..256) |i| {
                const ascii_name = if (i < 128) ascii_names[i] else "";
                const line = std.fmt.bufPrint(&line_buf, "0x{X:0>2}   {d:<5} {s:<12} {s}\n", .{
                    i, i, ascii_name, pb.character_map[i],
                }) catch continue;
                writeStdoutRaw(line);
            }
        },
        .json => {
            writeStdoutRaw("[\n");
            for (0..256) |i| {
                const raw_ascii = if (i < 128) ascii_names[i] else "";
                // Escape special JSON characters
                const ascii_escaped = if (std.mem.eql(u8, raw_ascii, "\""))
                    "\\\""
                else if (std.mem.eql(u8, raw_ascii, "\\"))
                    "\\\\"
                else
                    raw_ascii;
                const line = std.fmt.bufPrint(&line_buf, "  {{\"byte\": {d}, \"ascii\": \"{s}\", \"mapping\": \"{s}\"}}{s}\n", .{
                    i, ascii_escaped, pb.character_map[i], if (i < 255) "," else "",
                }) catch continue;
                writeStdoutRaw(line);
            }
            writeStdoutRaw("]\n");
        },
        .csv => {
            writeStdoutRaw("byte,hex,dec,ascii,mapping\n");
            for (0..256) |i| {
                const raw_ascii = if (i < 128) ascii_names[i] else "";
                const line = std.fmt.bufPrint(&line_buf, "{d},0x{X:0>2},{d},\"{s}\",\"{s}\"\n", .{
                    i, i, i, raw_ascii, pb.character_map[i],
                }) catch continue;
                writeStdoutRaw(line);
            }
        },
        .none => {},
    }
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Set up mute-stats env flag for writeStats
    if (init.environ_map.get("PRINTABLE_BINARY_MUTE_STATS")) |v| {
        if (v.len > 0 and v[0] == '1') G_ENV.mute = true;
    }

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const opts = parseArgs(allocator, args) catch |err| {
        switch (err) {
            error.UnknownOption => writeStats("Error: Unknown option\n", .{}),
            error.InvalidFormat => writeStats("Error: Invalid format specification\n", .{}),
            error.MissingValue => writeStats("Error: Missing value for option\n", .{}),
            error.MultipleInputFiles => writeStats("Error: Multiple input files specified\n", .{}),
            else => writeStats("Error parsing arguments: {}\n", .{err}),
        }
        std.process.exit(1);
    };
    // Free allocated strings on exit
    defer if (opts.input_file) |f| allocator.free(f);
    defer if (opts.preserve_chars) |p| allocator.free(p);

    if (opts.help_mode) {
        printUsage(io);
        return;
    }

    if (opts.mappings_mode != .none) {
        try printMappings(opts.mappings_mode);
        return;
    }

    // Read input (I/O boundary)
    const raw_input = readInput(io, allocator, opts.input_file) catch |err| {
        writeStats("Error reading input: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(raw_input);

    // Apply byte range if specified (policy logic lives in core library)
    var input: []const u8 = raw_input;
    if (opts.range_start != null or opts.range_end != null) {
        const range = pb.applyRange(raw_input.len, opts.range_start, opts.range_end);
        switch (range.warning) {
            .start_exceeds_input => writeStats("Warning: start offset {d} exceeds input size {d}\n", .{
                opts.range_start orelse 0, raw_input.len,
            }),
            .empty_range => writeStats("Warning: start offset exceeds end offset, empty range\n", .{}),
            .end_clamped => writeStats("Warning: end offset {d} exceeds input size {d}, clamping to {d}\n", .{
                opts.range_end orelse 0, raw_input.len, raw_input.len - 1,
            }),
            .none => {},
        }
        input = raw_input[range.offset .. range.offset + range.length];
    }

    if (opts.decode_mode) {
        // Decode mode - call core library
        if (opts.passthrough_mode) {
            writeStats("Warning: --passthrough ignored in decode mode\n", .{});
        }

        if (opts.hexlike) {
            // Hexlike decode
            const dr = pb.hexlikeDecode(allocator, input, .{
                .spaces = opts.spaces_mode,
            }) catch |err| {
                writeStats("Decode error: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(dr.data);

            // Warn if no Οχ sequences found
            if (!dr.found_hex) {
                writeStderrRaw("Warning: no hexlike (\xCE\x9F\xCF\x87) sequences found in input\n");
            }

            // Warn if PB-style encoding detected
            const de_info = pb.detectDoubleEncode(input, 0.05);
            if (de_info.detected != 0) {
                writeStderrRaw("Warning: input appears to contain standard printable-binary encoding\n");
            }

            writeStats("Decoding mode: Input size is {d} bytes\n", .{input.len});
            writeStats("Decoded result size: {d} bytes\n", .{dr.data.len});
            try writeOutput(io, dr.data, false);
        } else {
            // Regular PB decode

            // Warn about spaces after newlines in spaces + strip-whitespace mode
            // (two consecutive spaces after newline suggests indentation being treated as data)
            if (opts.spaces_mode and opts.strip_whitespace) {
                var prev1: u8 = 0;
                var prev2: u8 = 0;
                for (input) |c| {
                    if (c == ' ' and prev1 == ' ' and (prev2 == '\n' or prev2 == '\r')) {
                        writeStats("Warning: spaces after newline are treated as data in --spaces mode\n", .{});
                        break;
                    }
                    prev2 = prev1;
                    prev1 = c;
                }
            }

            // Warn if hexlike encoding detected in regular PB decode
            if (pb.detectHexlike(input)) {
                writeStderrRaw("Warning: input appears to contain hexlike (\xCE\x9F\xCF\x87) encoding; use --hexlike -d to decode\n");
            }

            const decoded = pb.decode(allocator, input, .{
                .spaces = opts.spaces_mode,
                .strip_whitespace = opts.strip_whitespace,
            }) catch |err| {
                writeStats("Decode error: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(decoded);

            writeStats("Decoding mode: Input size is {d} bytes\n", .{input.len});
            writeStats("Decoded result size: {d} bytes\n", .{decoded.len});
            try writeOutput(io, decoded, false);
        }
    } else {
        // Encode mode - check for double-encoding first
        if (!opts.no_double_encode_check) {
            const de_info = pb.detectDoubleEncode(input, 0.05);
            if (de_info.detected != 0) {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Warning: Input appears to already be printable-binary encoded ({d:.1}% detection).\n         Use --no-double-encode-check to suppress this warning.\n", .{de_info.confidence * 100.0}) catch unreachable;
                writeStderrRaw(msg);
            }
        }

        if (opts.passthrough_mode) {
            try writeOutput(io, input, false);
        }

        if (opts.hexlike) {
            // Hexlike encode
            const encoded = pb.hexlikeEncode(allocator, input, .{
                .spaces = opts.spaces_mode,
            }) catch |err| {
                writeStats("Encode error: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(encoded);

            writeStats("Encoded {d} bytes of input to {d} bytes\n", .{ input.len, encoded.len });
            try writeOutput(io, encoded, opts.passthrough_mode);
        } else {
            // Regular PB encode
            const encoded = pb.encode(allocator, input, .{
                .spaces = opts.spaces_mode,
                .tabs = opts.tabs_mode,
                .crlf = opts.crlf_mode,
                .preserve_chars = opts.preserve_chars orelse &.{},
            }) catch |err| {
                writeStats("Encode error: {}\n", .{err});
                std.process.exit(1);
            };
            defer allocator.free(encoded);

            var output = encoded;
            var formatted: ?[]u8 = null;
            defer if (formatted) |f| allocator.free(f);

            if (opts.format_mode) {
                formatted = pb.format(allocator, encoded, .{
                    .group_size = opts.format_group,
                    .groups_per_line = opts.format_groups_per_line,
                    .use_tabs = opts.spaces_mode,
                }) catch |err| {
                    writeStats("Format error: {}\n", .{err});
                    std.process.exit(1);
                };
                output = formatted.?;
            }

            writeStats("Encoded {d} bytes of input to {d} bytes\n", .{ input.len, output.len });
            try writeOutput(io, output, opts.passthrough_mode);
        }
    }
}
