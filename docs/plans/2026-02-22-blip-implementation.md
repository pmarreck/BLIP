# BLIP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Zig 0.15.2 library implementing BLIP encoding with benchmark suite comparing against 6 other variable-length integer encodings, including bignum arithmetic and random-access file jumping benchmarks.

**Architecture:** Pure Zig core (no I/O) with C FFI boundary. Each encoding is a separate module exposing a common comptime interface. Benchmarks are a separate binary that uses all encodings. CLI calls through C FFI.

**Tech Stack:** Zig 0.15.2, Nix flake for deps, hyperfine for CLI benchmarks, gh for GitHub.

**Key references:**
- `BLIP_SPEC.md` — full encoding specification with worked examples
- `ZIG_RECENT_API_CHANGES_2025.md` — Zig 0.15 API patterns (symlinked)
- `AGENTS.md` — TDD workflow and project conventions (symlinked)

---

### Task 1: Project Scaffolding

**Files:**
- Create: `flake.nix`
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `LICENSE`
- Create: `README.md`
- Create: `src/blip.zig` (stub)
- Create: `src/main.zig` (stub)
- Create: `src/lib.zig` (stub)
- Create: `.gitignore`

**Step 1: Create flake.nix**

```nix
{
  description = "BLIP: Byte Length Integer Prefix encoding";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            hyperfine
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "blip";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          doCheck = true;
          buildPhase = ''
            mkdir -p .cache
            zig build --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -Doptimize=ReleaseFast --prefix $out
          '';
          checkPhase = ''
            zig build test --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache
          '';
        };

        checks.${system}.default = self.packages.${system}.default;
      }
    );
}
```

**Step 2: Create build.zig**

Per Zig 0.15 API: use `b.createModule()`, `root_module`, and `addLibrary(.linkage = .static)`.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // Core library module (shared between lib, exe, tests, benchmarks)
    const blip_module = b.createModule(.{
        .root_source_file = b.path("src/blip.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library with C FFI
    const static_lib = b.addLibrary(.{
        .name = "blip",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
            },
        }),
    });
    b.installArtifact(static_lib);

    // CLI benchmark runner (calls through C FFI)
    const exe = b.addExecutable(.{
        .name = "blip-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(static_lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the benchmark CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Benchmark tests (separate so ./test doesn't run them)
    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "blip", .module = blip_module },
            },
        }),
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const bench_step = b.step("bench", "Run benchmark tests");
    bench_step.dependOn(&run_bench_tests.step);
}
```

**Step 3: Create build.zig.zon**

```zig
.{
    .name = .{ .override = "blip" },
    .version = "0.1.0",
    .fingerprint = .auto,
    .minimum_zig_version = "0.15.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 4: Create LICENSE (MIT)**

```
MIT License

Copyright (c) 2026 Peter Marreck

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**Step 5: Create README.md**

```markdown
# BLIP: Byte Length Integer Prefix

A variable-length integer encoding optimized for CPU-friendly decoding of small values, with a built-in sentinel channel for format extensibility.

See [BLIP_SPEC.md](BLIP_SPEC.md) for the full specification.

## Building

Requires Zig 0.15.2+ or Nix:

    zig build
    zig build test
    zig build bench

Or with Nix:

    nix develop
    zig build

## License

MIT - see [LICENSE](LICENSE)
```

**Step 6: Create stub source files**

`src/blip.zig`:
```zig
//! BLIP: Byte Length Integer Prefix encoding
//! See BLIP_SPEC.md for the full specification.

test {
    // Placeholder - tests will be added in subsequent tasks
}
```

`src/lib.zig`:
```zig
//! C FFI exports for BLIP encoding
const blip = @import("blip");
test {
    _ = blip;
}
```

`src/main.zig`:
```zig
const std = @import("std");
pub fn main() !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    if (comptime @import("builtin").mode == .Debug) {
        try stderr.print("\x1b[33mDEBUG BUILD\x1b[0m\n", .{});
    }
    try stderr.print("BLIP benchmark runner - not yet implemented\n", .{});
    try stderr.flush();
}
```

`src/benchmark.zig`:
```zig
//! Benchmark suite for BLIP vs other encodings
const blip = @import("blip");
test "placeholder" {
    _ = blip;
}
```

**Step 7: Create .gitignore**

```
zig-out/
.zig-cache/
.cache/
result
```

**Step 8: Create build and test scripts**

`build` (executable):
```bash
#!/usr/bin/env bash
set -euo pipefail

mode="ReleaseFast"
for arg in "$@"; do
	case "$arg" in
		--test) mode="Debug"; exec nix develop -c zig build test -Doptimize=Debug;;
		--debug) mode="Debug";;
	esac
done

exec nix develop -c zig build -Doptimize="$mode"
```

`test` (executable):
```bash
#!/usr/bin/env bash
set -euo pipefail
nix develop -c zig build test -Doptimize=Debug
echo "All tests passed."
```

`bm` (executable):
```bash
#!/usr/bin/env bash
set -euo pipefail

# Ensure we're NOT in debug mode
output=$(nix develop -c zig build run -Doptimize=ReleaseFast -- --about 2>&1 || true)
if echo "$output" | grep -q "DEBUG BUILD"; then
	echo "ERROR: benchmark must not run on debug build" >&2
	exit 1
fi

nix develop -c zig build bench -Doptimize=ReleaseFast
```

**Step 9: Verify build compiles**

Run: `nix develop -c zig build test`
Expected: PASS (placeholder tests)

**Step 10: Commit**

```bash
jj describe -m "Initial project scaffolding: flake.nix, build.zig, stubs, LICENSE"
jj new
```

---

### Task 2: Create GitHub Repo and Push

**Step 1: Create repo on GitHub**

```bash
gh repo create pmarreck/BLIP --public --description "BLIP: Byte Length Integer Prefix - a variable-length integer encoding" --license mit
```

**Step 2: Add remote and push**

```bash
jj git remote add origin git@github.com:pmarreck/BLIP.git
jj bookmark create yolo -r @-
jj git push -b yolo --allow-new
```

---

### Task 3: BLIP Core Encode/Decode (TDD)

**Files:**
- Create/modify: `src/blip.zig`

This is the heart of the project. Follow spec examples exactly.

**Step 1: Write failing tests for immediate mode (0-127)**

```zig
const std = @import("std");
const testing = std.testing;

// -- Tests at bottom of blip.zig --

test "encode immediate 0" {
    var buf: [16]u8 = undefined;
    const n = try encode(0, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x00), buf[0]);
}

test "encode immediate 42" {
    var buf: [16]u8 = undefined;
    const n = try encode(42, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x2A), buf[0]);
}

test "encode immediate 127" {
    var buf: [16]u8 = undefined;
    const n = try encode(127, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x7F), buf[0]);
}

test "decode immediate 0" {
    const result = try decode(&[_]u8{0x00});
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "decode immediate 127" {
    const result = try decode(&[_]u8{0x7F});
    try testing.expectEqual(@as(u64, 127), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}
```

**Step 2: Run tests, verify they fail**

Run: `nix develop -c zig build test`
Expected: FAIL — `encode` and `decode` not defined

**Step 3: Implement immediate mode**

```zig
pub const DecodeResult = struct {
    value: u64,
    bytes_read: usize,
};

pub const Error = error{
    BufferTooSmall,
    UnexpectedEndOfInput,
};

/// Encode a u64 value in BLIP format. Returns number of bytes written.
pub fn encode(value: u64, buf: []u8) Error!usize {
    if (value < 128) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }
    // length-prefixed mode — placeholder, will be implemented next
    _ = buf;
    return error.BufferTooSmall;
}

/// Decode a BLIP-encoded value from a buffer. Returns value and bytes consumed.
pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return error.UnexpectedEndOfInput;
    const byte = buf[0];
    if (byte & 0x80 == 0) {
        return .{ .value = byte, .bytes_read = 1 };
    }
    // length-prefixed mode — placeholder
    return error.UnexpectedEndOfInput;
}
```

**Step 4: Run tests, verify they pass**

Run: `nix develop -c zig build test`
Expected: PASS

**Step 5: Write failing tests for length-prefixed mode**

From spec worked examples:

```zig
test "encode 128 -> [0x81, 0x80]" {
    var buf: [16]u8 = undefined;
    const n = try encode(128, &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, buf[0..n]);
}

test "encode 200 -> [0x81, 0xC8]" {
    var buf: [16]u8 = undefined;
    const n = try encode(200, &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xC8 }, buf[0..n]);
}

test "encode 255 -> [0x81, 0xFF]" {
    var buf: [16]u8 = undefined;
    const n = try encode(255, &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0xFF }, buf[0..n]);
}

test "encode 256 -> [0x82, 0x00, 0x01]" {
    var buf: [16]u8 = undefined;
    const n = try encode(256, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x00, 0x01 }, buf[0..n]);
}

test "encode 1000 -> [0x82, 0xE8, 0x03]" {
    var buf: [16]u8 = undefined;
    const n = try encode(1000, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xE8, 0x03 }, buf[0..n]);
}

test "encode 50000 -> [0x82, 0x50, 0xC3]" {
    var buf: [16]u8 = undefined;
    const n = try encode(50000, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0x50, 0xC3 }, buf[0..n]);
}

test "encode 65535 -> [0x82, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const n = try encode(65535, &buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x82, 0xFF, 0xFF }, buf[0..n]);
}

test "encode 65536 -> [0x83, 0x00, 0x00, 0x01]" {
    var buf: [16]u8 = undefined;
    const n = try encode(65536, &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x00, 0x00, 0x01 }, buf[0..n]);
}

test "encode 5000000 -> [0x83, 0x40, 0x4B, 0x4C]" {
    var buf: [16]u8 = undefined;
    const n = try encode(5000000, &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x40, 0x4B, 0x4C }, buf[0..n]);
}

test "encode 2^32-1 -> [0x84, 0xFF, 0xFF, 0xFF, 0xFF]" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x84, 0xFF, 0xFF, 0xFF, 0xFF }, buf[0..n]);
}

test "encode 2^64-1 -> [0x88, 0xFF x8]" {
    var buf: [16]u8 = undefined;
    const n = try encode(0xFFFFFFFFFFFFFFFF, &buf);
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, buf[0..n]);
}

test "roundtrip all spec examples" {
    const values = [_]u64{ 0, 42, 127, 128, 200, 255, 256, 1000, 50000, 65535, 65536, 5000000, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
    for (values) |v| {
        var buf: [16]u8 = undefined;
        const n = try encode(v, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}
```

**Step 6: Run tests, verify they fail**

**Step 7: Implement full length-prefixed encode/decode**

```zig
/// Returns the minimum number of bytes needed to represent value.
fn byteWidth(value: u64) usize {
    if (value == 0) return 0;
    return @as(usize, 8) - @as(usize, @clz(value)) / 8;
    // More precisely: ceiling of (bit_width / 8)
}

/// Alternative: count bytes needed
fn minBytes(value: u64) usize {
    if (value == 0) return 1; // L=1 for value 128-255 range, but 0 is immediate
    var v = value;
    var count: usize = 0;
    while (v != 0) : (v >>= 8) {
        count += 1;
    }
    return count;
}

pub fn encode(value: u64, buf: []u8) Error!usize {
    if (value < 128) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @intCast(value);
        return 1;
    }

    const L = minBytes(value);
    // For u64, L is at most 8, which fits in 6 bits (L < 64), so no continuation needed
    if (buf.len < 1 + L) return error.BufferTooSmall;

    // Header byte: bit 7 = 1, C = 0, bits 5-0 = L
    buf[0] = 0x80 | @as(u8, @intCast(L));

    // Write value as little-endian
    const value_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, value));
    @memcpy(buf[1..][0..L], value_bytes[0..L]);

    return 1 + L;
}

pub fn decode(buf: []const u8) Error!DecodeResult {
    if (buf.len == 0) return error.UnexpectedEndOfInput;
    const byte = buf[0];

    if (byte & 0x80 == 0) {
        // Immediate mode
        return .{ .value = byte, .bytes_read = 1 };
    }

    // Length-prefixed mode
    var L: usize = undefined;
    var header_size: usize = 1;

    if (byte & 0x40 == 0) {
        // C = 0: L is bits 5-0
        L = byte & 0x3F;
    } else {
        // C = 1: L has continuation bytes
        L = byte & 0x3F;
        var shift: u6 = 6;
        while (true) {
            if (header_size >= buf.len) return error.UnexpectedEndOfInput;
            const next = buf[header_size];
            header_size += 1;
            L |= @as(usize, next & 0x7F) << shift;
            if (next & 0x80 == 0) break;
            shift +|= 7;
        }
    }

    if (L == 0) return .{ .value = 0, .bytes_read = header_size };
    if (buf.len < header_size + L) return error.UnexpectedEndOfInput;

    // Read L bytes as little-endian u64
    if (L > 8) return error.BufferTooSmall; // u64 max
    var value_bytes: [8]u8 = .{0} ** 8;
    @memcpy(value_bytes[0..L], buf[header_size..][0..L]);
    const value = std.mem.littleToNative(u64, @bitCast(value_bytes));

    return .{ .value = value, .bytes_read = header_size + L };
}
```

**Step 8: Run tests, verify they pass**

**Step 9: Add sentinel detection test**

```zig
test "detect sentinel: 0x81 0x00 is sentinel, not value 0" {
    // 0x81 0x00 = L=1, value byte = 0x00 → value 0, but 0 fits in immediate
    // This is an overlong encoding = sentinel
    const result = try decode(&[_]u8{ 0x81, 0x00 });
    try testing.expectEqual(@as(u64, 0), result.value);
    try testing.expectEqual(@as(usize, 2), result.bytes_read);
    // Sentinel check: value < 128 but L=1 means overlong
    try testing.expect(isSentinel(&[_]u8{ 0x81, 0x00 }));
}

test "detect sentinel: 0x81 0x7F is sentinel" {
    try testing.expect(isSentinel(&[_]u8{ 0x81, 0x7F }));
}

test "not sentinel: 0x81 0x80 is value 128" {
    try testing.expect(!isSentinel(&[_]u8{ 0x81, 0x80 }));
}
```

**Step 10: Implement isSentinel**

```zig
/// Returns true if the encoded bytes represent a sentinel (overlong encoding
/// where value 0-127 is encoded in length-prefixed mode instead of immediate).
pub fn isSentinel(buf: []const u8) bool {
    if (buf.len < 2) return false;
    // Must be length-prefixed with L=1 and value byte < 0x80
    return buf[0] == 0x81 and buf[1] < 0x80;
}
```

**Step 11: Run all tests, verify pass**

**Step 12: Commit**

```bash
jj describe -m "Implement BLIP core encode/decode with all spec examples passing"
jj new
```

---

### Task 4: LEB128 and SLEB128

**Files:**
- Create: `src/leb128.zig`
- Modify: `src/blip.zig` (add test import)

**Step 1: Write failing tests**

```zig
// src/leb128.zig
const std = @import("std");
const testing = std.testing;

test "LEB128 encode 0 -> [0x00]" {
    var buf: [16]u8 = undefined;
    const n = try encode(0, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, buf[0..n]);
}

test "LEB128 encode 127 -> [0x7F]" {
    var buf: [16]u8 = undefined;
    const n = try encode(127, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf[0..n]);
}

test "LEB128 encode 128 -> [0x80, 0x01]" {
    var buf: [16]u8 = undefined;
    const n = try encode(128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, buf[0..n]);
}

test "LEB128 encode 300 -> [0xAC, 0x02]" {
    var buf: [16]u8 = undefined;
    const n = try encode(300, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAC, 0x02 }, buf[0..n]);
}

test "LEB128 encode 16383 -> [0xFF, 0x7F]" {
    var buf: [16]u8 = undefined;
    const n = try encode(16383, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x7F }, buf[0..n]);
}

test "LEB128 encode 16384 -> [0x80, 0x80, 0x01]" {
    var buf: [16]u8 = undefined;
    const n = try encode(16384, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80, 0x01 }, buf[0..n]);
}

test "LEB128 roundtrip" {
    const values = [_]u64{ 0, 1, 127, 128, 255, 256, 300, 16383, 16384, 65535, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF };
    for (values) |v| {
        var buf: [16]u8 = undefined;
        const n = try encode(v, &buf);
        const result = try decode(buf[0..n]);
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}

// SLEB128 tests
test "SLEB128 encode -1 -> [0x7F]" {
    var buf: [16]u8 = undefined;
    const n = try signedEncode(-1, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf[0..n]);
}

test "SLEB128 encode -128 -> [0x80, 0x7F]" {
    var buf: [16]u8 = undefined;
    const n = try signedEncode(-128, &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x7F }, buf[0..n]);
}

test "SLEB128 roundtrip signed" {
    const values = [_]i64{ 0, 1, -1, 63, -64, 64, -65, 127, -128, 128, -129, 8191, -8192, 0x7FFFFFFFFFFFFFFF, -0x7FFFFFFFFFFFFFFF - 1 };
    for (values) |v| {
        var buf: [16]u8 = undefined;
        const n = try signedEncode(v, &buf);
        const result = try signedDecode(buf[0..n]);
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.bytes_read);
    }
}
```

**Step 2: Run tests, verify fail**

**Step 3: Implement LEB128 + SLEB128**

```zig
pub const DecodeResult = struct { value: u64, bytes_read: usize };
pub const SignedDecodeResult = struct { value: i64, bytes_read: usize };
pub const Error = error{ BufferTooSmall, UnexpectedEndOfInput, Overflow };

pub fn encode(value: u64, buf: []u8) Error!usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.BufferTooSmall;
        const byte: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn decode(buf: []const u8) Error!DecodeResult {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (buf, 0..) |byte, i| {
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            return .{ .value = value, .bytes_read = i + 1 };
        }
        shift = std.math.add(u6, shift, 7) catch return error.Overflow;
    }
    return error.UnexpectedEndOfInput;
}

pub fn signedEncode(value: i64, buf: []u8) Error!usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.BufferTooSmall;
        const byte: u8 = @intCast(@as(u7, @truncate(@as(u64, @bitCast(v)))));
        v >>= 7; // arithmetic shift
        if ((v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0)) {
            buf[i] = byte;
            return i + 1;
        }
        buf[i] = byte | 0x80;
        i += 1;
    }
}

pub fn signedDecode(buf: []const u8) Error!SignedDecodeResult {
    var value: i64 = 0;
    var shift: u6 = 0;
    for (buf, 0..) |byte, i| {
        value |= @as(i64, @as(u64, byte & 0x7F)) << shift;
        if (byte & 0x80 == 0) {
            // Sign extend
            if (shift < 63 and byte & 0x40 != 0) {
                value |= @as(i64, -1) << (shift + 7);
            }
            return .{ .value = value, .bytes_read = i + 1 };
        }
        shift = std.math.add(u6, shift, 7) catch return error.Overflow;
    }
    return error.UnexpectedEndOfInput;
}
```

**Step 4: Run tests, verify pass**

**Step 5: Commit**

```bash
jj describe -m "Implement LEB128 and SLEB128 encode/decode"
jj new
```

---

### Task 5: Protobuf Varint + ZigZag

**Files:**
- Create: `src/protobuf_varint.zig`

Same structure as LEB128 (it IS LEB128 for unsigned), plus ZigZag for signed. The unsigned encode/decode can delegate to or duplicate leb128.

```zig
// ZigZag encoding: (n << 1) ^ (n >> 63)
pub fn zigzagEncode(value: i64) u64 {
    const v: u64 = @bitCast(value);
    return (v << 1) ^ @as(u64, @bitCast(@as(i64, @bitCast(v)) >> 63));
}

pub fn zigzagDecode(value: u64) i64 {
    return @as(i64, @bitCast((value >> 1) ^ (~(value & 1) +% 1)));
}
```

Tests: roundtrip ZigZag for values {0, -1, 1, -2, 2, 2147483647, -2147483648}.

**Commit:** `"Implement Protobuf varint with ZigZag signed encoding"`

---

### Task 6: ASN.1 BER Length Encoding

**Files:**
- Create: `src/asn1_length.zig`

Key difference from BLIP: big-endian payload, L limited to 126.

```zig
pub fn encode(value: u64, buf: []u8) Error!usize {
    if (value < 128) {
        buf[0] = @intCast(value);
        return 1;
    }
    const L = minBytes(value);
    if (L > 126) return error.Overflow;
    buf[0] = 0x80 | @as(u8, @intCast(L));
    // Write big-endian
    var v = value;
    var i = L;
    while (i > 0) {
        i -= 1;
        buf[1 + i] = @intCast(v & 0xFF);
        v >>= 8;
    }
    return 1 + L;
}
```

Tests: roundtrip for {0, 127, 128, 255, 256, 65535, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF}.

**Commit:** `"Implement ASN.1 BER length encoding"`

---

### Task 7: PrefixVarint

**Files:**
- Create: `src/prefix_varint.zig`

Count leading 1-bits to determine byte count. Remaining bits + continuation bytes = value.

Tests: roundtrip for same value set. Verify 0-127 = 1 byte, 128-16383 = 2 bytes.

**Commit:** `"Implement PrefixVarint encoding"`

---

### Task 8: SQLite Varint

**Files:**
- Create: `src/sqlite_varint.zig`

Multiple thresholds: 0-240 = 1 byte, 241-248 = 2 bytes, 249 = 3 bytes, 250-255 = N+1 bytes big-endian.

Tests: roundtrip + verify 0-240 all encode as 1 byte.

**Commit:** `"Implement SQLite varint encoding"`

---

### Task 9: Common Encoding Interface

**Files:**
- Create: `src/encoding.zig`

Comptime generic that wraps each encoding with a uniform interface:

```zig
pub fn Encoding(comptime T: type) type {
    return struct {
        pub const name = T.name;

        pub fn encode(value: u64, buf: []u8) !usize {
            return T.encode(value, buf);
        }

        pub fn decode(buf: []const u8) !T.DecodeResult {
            return T.decode(buf);
        }
    };
}

pub const all_encodings = .{
    @import("blip.zig"),
    @import("leb128.zig"),
    @import("protobuf_varint.zig"),
    @import("asn1_length.zig"),
    @import("prefix_varint.zig"),
    @import("sqlite_varint.zig"),
};
```

Test: verify all encodings roundtrip correctly for the standard value set.

**Commit:** `"Add common encoding interface with comptime generics"`

---

### Task 10: C FFI for BLIP

**Files:**
- Modify: `src/lib.zig`
- Create: `src/blip.h`

```zig
// src/lib.zig
const blip = @import("blip");

export fn blip_encode(value: u64, out_buf: [*]u8, out_cap: usize) callconv(.c) i32 {
    const buf = out_buf[0..out_cap];
    const n = blip.encode(value, buf) catch return -1;
    return @intCast(n);
}

export fn blip_decode(encoded: [*]const u8, encoded_len: usize, out_value: *u64) callconv(.c) i32 {
    const buf = encoded[0..encoded_len];
    const result = blip.decode(buf) catch return -1;
    out_value.* = result.value;
    return @intCast(result.bytes_read);
}

export fn blip_is_sentinel(encoded: [*]const u8, encoded_len: usize) callconv(.c) bool {
    return blip.isSentinel(encoded[0..encoded_len]);
}
```

Test: build static lib, verify symbols exist.

**Commit:** `"Add C FFI exports for BLIP"`

---

### Task 11: CLI Entry Point (Through C FFI)

**Files:**
- Modify: `src/main.zig`

The CLI calls through the C FFI to demonstrate dogfooding. It provides `--about`, `-h`/`--help`, and runs a quick self-test.

**Commit:** `"Add CLI entry point calling through C FFI"`

---

### Task 12: Bignum Direct LE Arithmetic

**Files:**
- Create: `src/bignum.zig`

Two operations on raw LE byte slices:

```zig
/// Add two LE byte slices, writing result to out. Returns bytes used.
/// This is the "direct encoded arithmetic" that BLIP enables — no decode needed,
/// just operate on the raw LE payload bytes.
pub fn addLE(a: []const u8, b: []const u8, out: []u8) !usize {
    const max_len = @max(a.len, b.len);
    if (out.len < max_len + 1) return error.BufferTooSmall;
    var carry: u16 = 0;
    for (0..max_len + 1) |i| {
        const av: u16 = if (i < a.len) a[i] else 0;
        const bv: u16 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        out[i] = @intCast(sum & 0xFF);
        carry = sum >> 8;
    }
    // Trim trailing zeros
    var len = max_len + 1;
    while (len > 1 and out[len - 1] == 0) len -= 1;
    return len;
}

/// Multiply two LE byte slices (schoolbook multiplication).
pub fn mulLE(a: []const u8, b: []const u8, out: []u8) !usize {
    const max_len = a.len + b.len;
    if (out.len < max_len) return error.BufferTooSmall;
    @memset(out[0..max_len], 0);
    for (a, 0..) |av, i| {
        var carry: u16 = 0;
        for (b, 0..) |bv, j| {
            const prod = @as(u16, av) * @as(u16, bv) + out[i + j] + carry;
            out[i + j] = @intCast(prod & 0xFF);
            carry = prod >> 8;
        }
        if (carry > 0) out[i + b.len] = @intCast(carry);
    }
    var len = max_len;
    while (len > 1 and out[len - 1] == 0) len -= 1;
    return len;
}
```

Tests: verify `addLE(255_LE, 1_LE) = 256_LE`, `mulLE(256_LE, 256_LE) = 65536_LE`, etc.

**Commit:** `"Implement direct LE arithmetic for BLIP bignum benchmark"`

---

### Task 13: Benchmark Harness — Throughput

**Files:**
- Create: `src/benchmark.zig`

Uses `std.time.Timer` for precise timing. Iterates all encodings, all distributions.

```zig
fn benchEncodeDecode(comptime Enc: type, values: []const u64) !struct { encode_ns: u64, decode_ns: u64 } {
    var buf: [16]u8 = undefined;
    var timer = try std.time.Timer.start();

    // Encode
    for (values) |v| {
        _ = Enc.encode(v, &buf) catch continue;
    }
    const encode_ns = timer.read();

    // Decode
    timer.reset();
    for (values) |v| {
        const n = Enc.encode(v, &buf) catch continue;
        _ = Enc.decode(buf[0..n]) catch continue;
    }
    const decode_ns = timer.read();

    return .{ .encode_ns = encode_ns, .decode_ns = decode_ns };
}
```

Prints results as a table to stderr. JSON output with `--json` flag.

**Commit:** `"Add throughput benchmark for all encodings"`

---

### Task 14: Benchmark Harness — Bignum Math

Two sub-benchmarks in the same file:

1. **Roundtrip**: For each encoding, decode two 128-bit values, add via `std.math.big.int`, re-encode. Time the full cycle.
2. **Direct LE**: For BLIP, extract payload bytes, call `addLE`/`mulLE` directly. For others, must decode to bytes, operate, re-encode.

**Commit:** `"Add bignum math benchmark (roundtrip + direct LE)"`

---

### Task 15: Benchmark Harness — Random-Access Jumping

**Files:**
- Modify: `src/benchmark.zig`

**Step 1: Sparse file generation**

Create `$TMPDIR/blip_bench_sparse.bin` deterministically (seeded PRNG). For each encoding, write a chain of ~10,000 encoded offsets at scattered positions across a 1GB address space. Each offset points to the next entry.

```zig
fn generateSparseFile(path: []const u8) !void {
    // Check if already exists with correct magic
    if (std.fs.cwd().openFile(path, .{})) |f| {
        // Read magic header to verify
        var magic: [8]u8 = undefined;
        _ = f.read(&magic) catch {};
        f.close();
        if (std.mem.eql(u8, &magic, "BLIPbm01")) return; // already generated
    } else |_| {}

    // Generate...
}
```

**Step 2: Jump chain benchmark**

```zig
fn benchJumpChain(file: std.fs.File, chain_start: u64, comptime Enc: type, n_jumps: usize) !u64 {
    var timer = try std.time.Timer.start();
    var offset = chain_start;
    var buf: [16]u8 = undefined;
    for (0..n_jumps) |_| {
        _ = try file.pread(&buf, offset);
        const result = try Enc.decode(&buf);
        offset = result.value;
    }
    return timer.read();
}
```

**Commit:** `"Add random-access jump chain benchmark"`

---

### Task 16: Fuzz Tests

**Files:**
- Create: `src/fuzz.zig`

For each encoding, fuzz the roundtrip: random u64 -> encode -> decode -> assert equal.

```zig
test "fuzz BLIP roundtrip" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();
    for (0..100_000) |_| {
        const v = random.int(u64);
        var buf: [16]u8 = undefined;
        const n = try blip.encode(v, &buf);
        const result = try blip.decode(buf[0..n]);
        try testing.expectEqual(v, result.value);
    }
}
```

**Commit:** `"Add fuzz roundtrip tests for all encodings"`

---

### Task 17: PLAN.md, CODE_MINIMAP.md, Final Push

**Files:**
- Create: `PLAN.md`
- Create: `CODE_MINIMAP.md`
- Push to GitHub

**Commit:** `"Add project documentation and push to GitHub"`

```bash
jj git push -b yolo
```

---

That's the full plan. 17 tasks, TDD throughout, frequent commits.

**Plan complete and saved to `docs/plans/2026-02-22-blip-implementation.md`. Two execution options:**

**1. Subagent-Driven (this session)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach, Peter?