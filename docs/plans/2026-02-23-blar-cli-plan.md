# blar CLI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a C CLI binary (`blar`) that exercises the Zig BLIP container library through the C FFI, supporting tar-like archive operations with rich error reporting and interactive progress display.

**Architecture:** `src/blar.c` (C11/POSIX) calls through C FFI in `src/lib.zig` / `src/blip.h`. All encoding/container logic stays in Zig. The CLI handles I/O, arg parsing, progress display, and error reporting. New FFI functions provide zero-copy access to archive contents.

**Tech Stack:** C11, POSIX (`isatty`, `opendir`/`readdir`, `stat`), Zig build system, existing BLIP container library

**Design doc:** `docs/plans/2026-02-23-blar-cli-design.md`

---

### Task 1: Expand FFI Error Codes

Add typed error codes to the C FFI so errors propagate with detail rather than collapsing to `-1`.

**Files:**
- Modify: `src/blip.h`
- Modify: `src/lib.zig`

**Step 1: Add error code defines to blip.h**

Add these defines and the `blip_error_string` declaration to `src/blip.h`, right after the existing `#include` lines and before `#ifdef __cplusplus`:

```c
/* Error codes for new archive access functions.
 * Legacy functions (blip_encode, blip_decode, etc.) still return -1 on error. */
#define BLIP_OK                    0
#define BLIP_ERR_INVALID_TYPE     -1
#define BLIP_ERR_INVALID_LENGTH   -2
#define BLIP_ERR_BOUNDS           -3
#define BLIP_ERR_MISSING_KEY      -4
#define BLIP_ERR_DUPLICATE_KEY    -5
#define BLIP_ERR_KEYS_NOT_SORTED  -6
#define BLIP_ERR_HASH_MISMATCH    -7
#define BLIP_ERR_INDEX_OOB        -8
#define BLIP_ERR_INVALID_MAGIC    -9
#define BLIP_ERR_BUFFER_TOO_SMALL -10
#define BLIP_ERR_UNEXPECTED_EOF   -11
#define BLIP_ERR_OVERFLOW         -12
#define BLIP_ERR_ALLOC            -13
#define BLIP_ERR_NOT_FOUND        -14
#define BLIP_ERR_UNKNOWN          -99

/* Get a human-readable error string for an error code. */
const char *blip_error_string(int32_t error_code);
```

**Step 2: Implement `blip_error_string` and the error mapping helper in lib.zig**

Add to `src/lib.zig` after the existing imports:

```zig
const ContainerError = blip.mini_blip_mod.ContainerError;

/// Map a ContainerError to a C FFI error code.
fn containerErrorCode(err: ContainerError) i32 {
    return switch (err) {
        error.InvalidContainerType => -1,
        error.InvalidLength => -2,
        error.LengthExceedsBounds => -3,
        error.MissingRequiredKey => -4,
        error.DuplicateKey => -5,
        error.KeysNotSorted => -6,
        error.HashMismatch => -7,
        error.IndexOutOfBounds => -8,
        error.InvalidMagic => -9,
        error.BufferTooSmall => -10,
        error.UnexpectedEndOfInput => -11,
        error.Overflow => -12,
    };
}

export fn blip_error_string(error_code: i32) callconv(.c) [*:0]const u8 {
    return switch (error_code) {
        0 => "success",
        -1 => "invalid container type",
        -2 => "invalid length",
        -3 => "length exceeds bounds",
        -4 => "missing required key",
        -5 => "duplicate key",
        -6 => "keys not sorted",
        -7 => "hash mismatch",
        -8 => "index out of bounds",
        -9 => "invalid magic",
        -10 => "buffer too small",
        -11 => "unexpected end of input",
        -12 => "overflow",
        -13 => "allocation failure",
        -14 => "not found",
        else => "unknown error",
    };
}
```

**Step 3: Add a test for blip_error_string**

Add to the test section of `src/lib.zig`:

```zig
test "C FFI: blip_error_string returns correct strings" {
    const ok_str = std.mem.span(blip_error_string(0));
    try std.testing.expectEqualSlices(u8, "success", ok_str);

    const hash_str = std.mem.span(blip_error_string(-7));
    try std.testing.expectEqualSlices(u8, "hash mismatch", hash_str);

    const unknown_str = std.mem.span(blip_error_string(-50));
    try std.testing.expectEqualSlices(u8, "unknown error", unknown_str);
}
```

**Step 4: Run tests**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass including the new error string test.

**Step 5: Commit**

```bash
git add src/blip.h src/lib.zig
git commit -m "Add typed FFI error codes and blip_error_string"
```

---

### Task 2: New FFI Archive Access Functions

Add zero-copy FFI functions for reading file paths, content, and per-file verification from archives.

**Files:**
- Modify: `src/lib.zig`
- Modify: `src/blip.h`

**Step 1: Write failing tests for the new FFI functions**

Add to the test section of `src/lib.zig`:

```zig
test "C FFI: blip_archive_file_path returns correct paths" {
    const c_files = [_]CFileEntry{
        .{ .path = "alpha.txt", .path_len = 9, .content = "aaa", .content_len = 3 },
        .{ .path = "beta.txt", .path_len = 8, .content = "bbb", .content_len = 3 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Files are sorted: "alpha.txt" < "beta.txt"
    var path_ptr: [*]const u8 = undefined;
    var path_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 0, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "alpha.txt", path_ptr[0..path_len]);

    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_path(out_buf, out_len, 1, &path_ptr, &path_len));
    try std.testing.expectEqualSlices(u8, "beta.txt", path_ptr[0..path_len]);

    // Out of bounds
    try std.testing.expectEqual(@as(i32, -8), blip_archive_file_path(out_buf, out_len, 2, &path_ptr, &path_len));
}

test "C FFI: blip_archive_file_content returns correct data" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "hello world", .content_len = 11 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content(out_buf, out_len, 0, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "hello world", data_ptr[0..data_len]);
}

test "C FFI: blip_archive_file_content_by_path finds file" {
    const c_files = [_]CFileEntry{
        .{ .path = "a.txt", .path_len = 5, .content = "aaa", .content_len = 3 },
        .{ .path = "b.txt", .path_len = 5, .content = "bbb", .content_len = 3 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 2, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    var data_ptr: [*]const u8 = undefined;
    var data_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_content_by_path(out_buf, out_len, "b.txt", 5, &data_ptr, &data_len));
    try std.testing.expectEqualSlices(u8, "bbb", data_ptr[0..data_len]);

    // Not found
    try std.testing.expectEqual(@as(i32, -14), blip_archive_file_content_by_path(out_buf, out_len, "nope", 4, &data_ptr, &data_len));
}

test "C FFI: blip_archive_file_verify checks per-file hash" {
    const c_files = [_]CFileEntry{
        .{ .path = "test.txt", .path_len = 8, .content = "data", .content_len = 4 },
    };
    var out_buf: [*]u8 = undefined;
    var out_len: usize = undefined;
    try std.testing.expectEqual(@as(i32, 0), blip_archive_create(&c_files, 1, &out_buf, &out_len));
    defer blip_free(out_buf, out_len);

    // Valid file should verify
    try std.testing.expectEqual(@as(i32, 0), blip_archive_file_verify(out_buf, out_len, 0));

    // Out of bounds
    try std.testing.expectEqual(@as(i32, -8), blip_archive_file_verify(out_buf, out_len, 1));
}
```

**Step 2: Run tests to verify they fail**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: FAIL — `blip_archive_file_path`, `blip_archive_file_content`, `blip_archive_file_content_by_path`, `blip_archive_file_verify` are not defined.

**Step 3: Implement the new FFI functions in lib.zig**

Add to `src/lib.zig` after the existing `blip_free` function:

```zig
const leaf = blip.mini_blip_mod.leaf;
const dict_mod = blip.mini_blip_mod.dict_mod;

/// Get the file path at the given index in a BLIP archive.
/// Returns BLIP_OK (0) on success, or a negative error code.
/// out_path/out_path_len point into buf (zero-copy).
export fn blip_archive_file_path(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_path: *[*]const u8,
    out_path_len: *usize,
) callconv(.c) i32 {
    const archive_buf = buf[0..buf_len];
    const reader = mini_blip.ArchiveReader.init(archive_buf) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);
    const path_idx = file_reader.findKey("path") catch |e| return containerErrorCode(e);
    const idx = path_idx orelse return -14; // NOT_FOUND
    const path_container = file_reader.valueAt(idx) catch |e| return containerErrorCode(e);
    const path_val = leaf.readUtf8(path_container) catch |e| return containerErrorCode(e);
    out_path.* = path_val.ptr;
    out_path_len.* = path_val.len;
    return 0;
}

/// Get the file content at the given index in a BLIP archive.
/// Returns BLIP_OK (0) on success, or a negative error code.
/// out_data/out_data_len point into buf (zero-copy).
export fn blip_archive_file_content(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const archive_buf = buf[0..buf_len];
    const reader = mini_blip.ArchiveReader.init(archive_buf) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);
    const bina_idx = file_reader.findKey("bina") catch |e| return containerErrorCode(e);
    const idx = bina_idx orelse return -14; // NOT_FOUND
    const bina_container = file_reader.valueAt(idx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);
    out_data.* = bina_val.ptr;
    out_data_len.* = bina_val.len;
    return 0;
}

/// Get file content by path in a BLIP archive.
/// Returns BLIP_OK (0) on success, -14 (NOT_FOUND) if path not in archive.
/// out_data/out_data_len point into buf (zero-copy).
export fn blip_archive_file_content_by_path(
    buf: [*]const u8,
    buf_len: usize,
    path: [*]const u8,
    path_len: usize,
    out_data: *[*]const u8,
    out_data_len: *usize,
) callconv(.c) i32 {
    const archive_buf = buf[0..buf_len];
    const path_str = path[0..path_len];
    const reader = mini_blip.ArchiveReader.init(archive_buf) catch |e| return containerErrorCode(e);
    const file_reader_opt = reader.findFile(path_str) catch |e| return containerErrorCode(e);
    const file_reader = file_reader_opt orelse return -14; // NOT_FOUND
    const bina_idx = file_reader.findKey("bina") catch |e| return containerErrorCode(e);
    const idx = bina_idx orelse return -14;
    const bina_container = file_reader.valueAt(idx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);
    out_data.* = bina_val.ptr;
    out_data_len.* = bina_val.len;
    return 0;
}

/// Verify a single file's xh64 hash within a BLIP archive.
/// Returns BLIP_OK (0) if hash matches, -7 (HASH_MISMATCH) if not.
export fn blip_archive_file_verify(
    buf: [*]const u8,
    buf_len: usize,
    index: u64,
) callconv(.c) i32 {
    const archive_buf = buf[0..buf_len];
    const reader = mini_blip.ArchiveReader.init(archive_buf) catch |e| return containerErrorCode(e);
    const file_reader = reader.fileAt(index) catch |e| return containerErrorCode(e);

    // Get stored xh64
    const xh64_idx = file_reader.findKey("xh64") catch |e| return containerErrorCode(e);
    const idx = xh64_idx orelse return -14;
    const xh64_container = file_reader.valueAt(idx) catch |e| return containerErrorCode(e);
    const xh64_val = leaf.readRaw(xh64_container) catch |e| return containerErrorCode(e);
    if (xh64_val.len != 8) return -2; // INVALID_LENGTH

    const stored_hash = std.mem.readInt(u64, xh64_val[0..8], .little);

    // Get content and recompute
    const bina_idx = file_reader.findKey("bina") catch |e| return containerErrorCode(e);
    const bidx = bina_idx orelse return -14;
    const bina_container = file_reader.valueAt(bidx) catch |e| return containerErrorCode(e);
    const bina_val = leaf.readRaw(bina_container) catch |e| return containerErrorCode(e);

    const computed_hash = std.hash.XxHash64.hash(0, bina_val);
    if (computed_hash != stored_hash) return -7; // HASH_MISMATCH
    return 0;
}
```

**Step 4: Add the new function declarations to blip.h**

Add before the closing `#ifdef __cplusplus`:

```c
/* Get file path from archive by index (zero-copy pointer into buf).
 * Returns BLIP_OK on success, negative error code on failure. */
int32_t blip_archive_file_path(const uint8_t *buf, size_t buf_len,
                                uint64_t index,
                                const char **out_path, size_t *out_path_len);

/* Get file content from archive by index (zero-copy pointer into buf).
 * Returns BLIP_OK on success, negative error code on failure. */
int32_t blip_archive_file_content(const uint8_t *buf, size_t buf_len,
                                   uint64_t index,
                                   const uint8_t **out_data, size_t *out_data_len);

/* Get file content by path (zero-copy pointer into buf).
 * Returns BLIP_OK on success, BLIP_ERR_NOT_FOUND if path not in archive. */
int32_t blip_archive_file_content_by_path(const uint8_t *buf, size_t buf_len,
                                           const char *path, size_t path_len,
                                           const uint8_t **out_data, size_t *out_data_len);

/* Verify a single file's xh64 hash within archive.
 * Returns BLIP_OK if valid, BLIP_ERR_HASH_MISMATCH if not. */
int32_t blip_archive_file_verify(const uint8_t *buf, size_t buf_len,
                                  uint64_t index);
```

**Step 5: Run tests**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add src/lib.zig src/blip.h
git commit -m "Add FFI functions for archive file access and verification"
```

---

### Task 3: Expose re-exports for leaf and dict_mod through blip.zig

The FFI functions in lib.zig need to access `leaf` and `dict_mod` through the `blip` module. Currently `mini_blip_mod` is re-exported from `blip.zig`, but we need `leaf` and `dict_mod` accessible too.

**Files:**
- Modify: `src/mini_blip.zig` — verify `leaf` and `dict_mod` are `pub`

**Step 1: Check and fix visibility**

In `src/mini_blip.zig`, the imports of `leaf` and `dict_mod` are currently private (`const`). They need to be `pub const` so that `lib.zig` can access them through `blip.mini_blip_mod.leaf` and `blip.mini_blip_mod.dict_mod`.

Change in `src/mini_blip.zig`:
```zig
// Change these from:
const leaf = @import("leaf.zig");
const dict_mod = @import("dict.zig");
// To:
pub const leaf = @import("leaf.zig");
pub const dict_mod = @import("dict.zig");
```

Note: `dict_mod` is already `pub` (used by `FileEntry`'s type). Verify `leaf` is also `pub`. If not, make it `pub`.

**Step 2: Run tests**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests still pass.

**Step 3: Commit**

```bash
git add src/mini_blip.zig
git commit -m "Make leaf and dict_mod public in mini_blip for FFI access"
```

---

### Task 4: Add blar Build Target

Add `blar` as a C executable target in `build.zig` that links against the BLIP static library.

**Files:**
- Modify: `build.zig`
- Create: `src/blar.c` (minimal stub to verify build)

**Step 1: Create minimal blar.c stub**

Create `src/blar.c` with just enough to verify the build works:

```c
#include "blip.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    printf("blar: BLIP archive tool (stub)\n");
    return 0;
}
```

**Step 2: Add blar target to build.zig**

Add after the existing `exe` (blip-bench) section and before the run step:

```zig
    // blar CLI — C executable that calls BLIP through C FFI
    const blar = b.addExecutable(.{
        .name = "blar",
        .target = target,
        .optimize = optimize,
    });
    blar.addCSourceFile(.{
        .file = b.path("src/blar.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    blar.linkLibrary(static_lib);
    blar.addIncludePath(b.path("src"));
    blar.linkLibC();
    b.installArtifact(blar);

    // blar run step
    const blar_run = b.addRunArtifact(blar);
    blar_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        blar_run.addArgs(args);
    }
    const blar_step = b.step("blar", "Run the blar CLI");
    blar_step.dependOn(&blar_run.step);
```

**Step 3: Verify it builds**

Run: `nix develop -c zig build -Doptimize=ReleaseFast`
Expected: Builds successfully. `zig-out/bin/blar` exists.

**Step 4: Verify stub runs**

Run: `nix develop -c zig build blar -Doptimize=ReleaseFast`
Expected: Prints "blar: BLIP archive tool (stub)"

**Step 5: Commit**

```bash
git add src/blar.c build.zig
git commit -m "Add blar C executable build target (stub)"
```

---

### Task 5: Implement blar Argument Parsing

Implement the full argument parsing for blar: subcommand style AND tar-style flags with optional hyphen.

**Files:**
- Modify: `src/blar.c`

**Step 1: Implement argument parsing and usage/help**

Replace `src/blar.c` with the full argument parsing implementation:

```c
#include "blip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Exit codes */
#define EXIT_OK      0
#define EXIT_USAGE   1
#define EXIT_IO      2
#define EXIT_VERIFY  3

typedef enum {
    OP_NONE,
    OP_CREATE,
    OP_LIST,
    OP_EXTRACT,
    OP_VERIFY,
    OP_INFO,
    OP_CAT
} operation_t;

static void print_usage(FILE *out) {
    fprintf(out,
        "Usage: blar <command> [options] [files...]\n"
        "\n"
        "Commands:\n"
        "  create  -o <archive> <file>...   Create archive from files\n"
        "  list    <archive>                List files in archive\n"
        "  extract <archive> [-C <dir>]     Extract files from archive\n"
        "  verify  <archive>                Verify archive integrity\n"
        "  info    <archive>                Show archive metadata\n"
        "  cat     <archive> <path>         Print file content to stdout\n"
        "\n"
        "Tar-style (hyphen optional):\n"
        "  blar cf  <archive> <file>...     Create\n"
        "  blar tf  <archive>               List\n"
        "  blar xf  <archive> [-C <dir>]    Extract\n"
        "  blar Vf  <archive>               Verify\n"
        "  blar If  <archive>               Info\n"
        "  blar pf  <archive> <path>        Cat (print)\n"
        "\n"
        "Options:\n"
        "  -o <file>    Output archive file (create mode)\n"
        "  -C <dir>     Extract to directory (extract mode)\n"
        "  -h, --help   Show this help\n"
        "  --version    Show version\n"
    );
}

/* Parse tar-style flags like "cf", "-cf", "tf", "-tf", etc.
 * Returns the operation, or OP_NONE if not a tar-style flag string. */
static operation_t parse_tar_flags(const char *arg) {
    const char *p = arg;
    if (*p == '-') p++;  /* skip optional hyphen */

    operation_t op = OP_NONE;
    int has_f = 0;

    while (*p) {
        switch (*p) {
            case 'c': op = OP_CREATE;  break;
            case 't': op = OP_LIST;    break;
            case 'x': op = OP_EXTRACT; break;
            case 'V': op = OP_VERIFY;  break;
            case 'I': op = OP_INFO;    break;
            case 'p': op = OP_CAT;     break;
            case 'f': has_f = 1;       break;
            default:  return OP_NONE;  /* unknown flag */
        }
        p++;
    }

    /* Must have both an operation and 'f' */
    if (op != OP_NONE && has_f) return op;
    return OP_NONE;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage(stderr);
        return EXIT_USAGE;
    }

    /* Check for --help, -h, --version */
    if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        print_usage(stdout);
        return EXIT_OK;
    }
    if (strcmp(argv[1], "--version") == 0) {
        printf("blar 0.1.0 (BLIP archive tool)\n");
        return EXIT_OK;
    }

    operation_t op = OP_NONE;
    const char *archive_path = NULL;
    const char *extract_dir = NULL;
    const char *cat_path = NULL;
    const char *output_path = NULL;
    char **input_files = NULL;
    int input_file_count = 0;
    int arg_idx = 2;

    /* Try subcommand-style first */
    if (strcmp(argv[1], "create") == 0) {
        op = OP_CREATE;
    } else if (strcmp(argv[1], "list") == 0) {
        op = OP_LIST;
    } else if (strcmp(argv[1], "extract") == 0) {
        op = OP_EXTRACT;
    } else if (strcmp(argv[1], "verify") == 0) {
        op = OP_VERIFY;
    } else if (strcmp(argv[1], "info") == 0) {
        op = OP_INFO;
    } else if (strcmp(argv[1], "cat") == 0) {
        op = OP_CAT;
    }

    /* Try tar-style if subcommand didn't match */
    if (op == OP_NONE) {
        op = parse_tar_flags(argv[1]);
        if (op == OP_NONE) {
            fprintf(stderr, "blar: unknown command '%s'\n", argv[1]);
            print_usage(stderr);
            return EXIT_USAGE;
        }
        /* In tar-style, next arg after flags is the archive */
        if (arg_idx < argc) {
            archive_path = argv[arg_idx++];
        }
    }

    /* Parse remaining args based on operation */
    if (op == OP_CREATE) {
        /* Subcommand style: create -o <archive> <files...> */
        /* Tar style: archive already set, rest are files */
        while (arg_idx < argc) {
            if (strcmp(argv[arg_idx], "-o") == 0) {
                arg_idx++;
                if (arg_idx >= argc) {
                    fprintf(stderr, "blar: -o requires an argument\n");
                    return EXIT_USAGE;
                }
                output_path = argv[arg_idx++];
            } else {
                break;
            }
        }
        /* If tar-style, archive_path was already set; use it as output */
        if (output_path == NULL && archive_path != NULL) {
            output_path = archive_path;
        }
        /* If subcommand style without -o and no archive_path, first remaining is archive */
        if (output_path == NULL) {
            fprintf(stderr, "blar: create: missing output file (-o <archive>)\n");
            return EXIT_USAGE;
        }
        input_files = &argv[arg_idx];
        input_file_count = argc - arg_idx;
    } else {
        /* All other ops: next arg is the archive (if not already set from tar-style) */
        if (archive_path == NULL) {
            if (arg_idx >= argc) {
                fprintf(stderr, "blar: %s: missing archive file argument\n", argv[1]);
                return EXIT_USAGE;
            }
            archive_path = argv[arg_idx++];
        }

        if (op == OP_EXTRACT) {
            while (arg_idx < argc) {
                if (strcmp(argv[arg_idx], "-C") == 0) {
                    arg_idx++;
                    if (arg_idx >= argc) {
                        fprintf(stderr, "blar: -C requires an argument\n");
                        return EXIT_USAGE;
                    }
                    extract_dir = argv[arg_idx++];
                } else {
                    fprintf(stderr, "blar: extract: unexpected argument '%s'\n", argv[arg_idx]);
                    return EXIT_USAGE;
                }
            }
        } else if (op == OP_CAT) {
            if (arg_idx >= argc) {
                fprintf(stderr, "blar: cat: missing file path argument\n");
                return EXIT_USAGE;
            }
            cat_path = argv[arg_idx++];
        }
    }

    /* Dispatch to operation (stubs for now) */
    switch (op) {
        case OP_CREATE:
            fprintf(stderr, "blar: create: not yet implemented\n");
            (void)output_path;
            (void)input_files;
            (void)input_file_count;
            return EXIT_USAGE;
        case OP_LIST:
            fprintf(stderr, "blar: list: not yet implemented\n");
            (void)archive_path;
            return EXIT_USAGE;
        case OP_EXTRACT:
            fprintf(stderr, "blar: extract: not yet implemented\n");
            (void)extract_dir;
            return EXIT_USAGE;
        case OP_VERIFY:
            fprintf(stderr, "blar: verify: not yet implemented\n");
            return EXIT_USAGE;
        case OP_INFO:
            fprintf(stderr, "blar: info: not yet implemented\n");
            return EXIT_USAGE;
        case OP_CAT:
            fprintf(stderr, "blar: cat: not yet implemented\n");
            (void)cat_path;
            return EXIT_USAGE;
        default:
            print_usage(stderr);
            return EXIT_USAGE;
    }
}
```

**Step 2: Build and verify arg parsing works**

Run: `nix develop -c zig build -Doptimize=ReleaseFast`

Then test manually:
```bash
./zig-out/bin/blar --help        # should print usage, exit 0
./zig-out/bin/blar --version     # should print version, exit 0
./zig-out/bin/blar               # should print usage to stderr, exit 1
./zig-out/bin/blar create        # should say missing output file, exit 1
./zig-out/bin/blar list          # should say missing archive, exit 1
./zig-out/bin/blar tf            # should say missing archive (tar-style), exit 1
./zig-out/bin/blar bogus         # should say unknown command, exit 1
```

**Step 3: Commit**

```bash
git add src/blar.c
git commit -m "Implement blar argument parsing (subcommand + tar-style)"
```

---

### Task 6: Implement blar Operations (create, list, verify, info, cat, extract)

Implement all six archive operations with progress display and error handling.

**Files:**
- Modify: `src/blar.c`

**Step 1: Add helper functions and implement all operations**

Add these helper functions and replace the operation dispatch stubs:

```c
#include <sys/stat.h>
#include <errno.h>
#include <libgen.h>

/* ----- Progress bar ----- */

typedef struct {
    int is_tty;
    uint64_t total_files;
    uint64_t total_bytes;
    uint64_t files_done;
    uint64_t bytes_done;
} progress_t;

static void progress_init(progress_t *p, uint64_t total_files, uint64_t total_bytes) {
    p->is_tty = isatty(STDERR_FILENO);
    p->total_files = total_files;
    p->total_bytes = total_bytes;
    p->files_done = 0;
    p->bytes_done = 0;
}

static void progress_update(progress_t *p, uint64_t file_bytes) {
    p->files_done++;
    p->bytes_done += file_bytes;
    if (!p->is_tty) return;

    /* Bar: [████████░░░░░░░░] */
    int bar_width = 16;
    double frac = p->total_bytes > 0
        ? (double)p->bytes_done / (double)p->total_bytes
        : (p->total_files > 0 ? (double)p->files_done / (double)p->total_files : 1.0);
    int filled = (int)(frac * bar_width);
    if (filled > bar_width) filled = bar_width;

    fprintf(stderr, "\r[");
    for (int i = 0; i < bar_width; i++) {
        fprintf(stderr, "%s", i < filled ? "\xe2\x96\x88" : "\xe2\x96\x91");
    }

    /* Format bytes */
    const char *unit = "B";
    double done_d = (double)p->bytes_done;
    double total_d = (double)p->total_bytes;
    if (total_d >= 1048576.0) {
        done_d /= 1048576.0; total_d /= 1048576.0; unit = "MB";
    } else if (total_d >= 1024.0) {
        done_d /= 1024.0; total_d /= 1024.0; unit = "KB";
    }

    fprintf(stderr, "]  %llu/%llu files   %.1f / %.1f %s",
        (unsigned long long)p->files_done,
        (unsigned long long)p->total_files,
        done_d, total_d, unit);
}

static void progress_finish(progress_t *p) {
    if (!p->is_tty) return;
    progress_update(p, 0);  /* final redraw */
    p->files_done = p->total_files;  /* ensure 100% */
    fprintf(stderr, "\n");
}

/* ----- File I/O helpers ----- */

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    if (len < 0) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc((size_t)len);
    if (!buf) { fclose(f); return NULL; }
    if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    *out_len = (size_t)len;
    return buf;
}

static int write_file(const char *path, const uint8_t *data, size_t len) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    if (len > 0 && fwrite(data, 1, len, f) != len) {
        fclose(f); return -1;
    }
    fclose(f);
    return 0;
}

/* Recursively create directories for a file path */
static int mkdirs(const char *file_path) {
    char *path_copy = strdup(file_path);
    if (!path_copy) return -1;

    /* Walk through path components, creating each directory */
    for (char *p = path_copy + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(path_copy, 0755) != 0 && errno != EEXIST) {
                free(path_copy);
                return -1;
            }
            *p = '/';
        }
    }
    free(path_copy);
    return 0;
}

/* ----- Operations ----- */

static int do_create(const char *output_path, char **files, int file_count) {
    if (file_count == 0) {
        /* Create empty archive */
        blip_file_entry *entries = NULL;
        uint8_t *archive = NULL;
        size_t archive_len = 0;
        int32_t rc = blip_archive_create(entries, 0, &archive, &archive_len);
        if (rc != 0) {
            fprintf(stderr, "blar: create: %s\n", blip_error_string(rc));
            return EXIT_VERIFY;
        }
        if (write_file(output_path, archive, archive_len) != 0) {
            fprintf(stderr, "blar: create: cannot write '%s': %s\n", output_path, strerror(errno));
            blip_free(archive, archive_len);
            return EXIT_IO;
        }
        blip_free(archive, archive_len);
        return EXIT_OK;
    }

    /* Read all input files */
    blip_file_entry *entries = calloc((size_t)file_count, sizeof(blip_file_entry));
    if (!entries) {
        fprintf(stderr, "blar: create: allocation failure\n");
        return EXIT_IO;
    }

    /* Track total bytes for progress */
    uint64_t total_bytes = 0;
    for (int i = 0; i < file_count; i++) {
        size_t len = 0;
        uint8_t *data = read_file(files[i], &len);
        if (!data) {
            fprintf(stderr, "blar: create: cannot open '%s': %s\n", files[i], strerror(errno));
            /* Clean up already-read files */
            for (int j = 0; j < i; j++) {
                free((void *)entries[j].content);
            }
            free(entries);
            return EXIT_IO;
        }
        entries[i].path = files[i];
        entries[i].path_len = strlen(files[i]);
        entries[i].content = data;
        entries[i].content_len = len;
        total_bytes += len;
    }

    /* Show progress for reading */
    progress_t prog;
    progress_init(&prog, (uint64_t)file_count, total_bytes);
    for (int i = 0; i < file_count; i++) {
        progress_update(&prog, entries[i].content_len);
    }

    uint8_t *archive = NULL;
    size_t archive_len = 0;
    int32_t rc = blip_archive_create(entries, (size_t)file_count, &archive, &archive_len);

    /* Clean up input data */
    for (int i = 0; i < file_count; i++) {
        free((void *)entries[i].content);
    }
    free(entries);

    if (rc != 0) {
        fprintf(stderr, "blar: create: %s\n", blip_error_string(rc));
        progress_finish(&prog);
        return EXIT_VERIFY;
    }

    if (write_file(output_path, archive, archive_len) != 0) {
        fprintf(stderr, "blar: create: cannot write '%s': %s\n", output_path, strerror(errno));
        blip_free(archive, archive_len);
        progress_finish(&prog);
        return EXIT_IO;
    }

    progress_finish(&prog);
    blip_free(archive, archive_len);
    return EXIT_OK;
}

static int do_list(const char *archive_path) {
    size_t len = 0;
    uint8_t *buf = read_file(archive_path, &len);
    if (!buf) {
        fprintf(stderr, "blar: list: cannot open '%s': %s\n", archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, len, &count);
    if (rc != 0) {
        fprintf(stderr, "blar: list: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, len, i, &path, &path_len);
        if (rc != 0) {
            fprintf(stderr, "blar: list: file %llu: %s\n", (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }
        printf("%.*s\n", (int)path_len, path);
    }

    free(buf);
    return EXIT_OK;
}

static int do_extract(const char *archive_path, const char *extract_dir) {
    size_t len = 0;
    uint8_t *buf = read_file(archive_path, &len);
    if (!buf) {
        fprintf(stderr, "blar: extract: cannot open '%s': %s\n", archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, len, &count);
    if (rc != 0) {
        fprintf(stderr, "blar: extract: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    /* Compute total bytes for progress */
    uint64_t total_bytes = 0;
    for (uint64_t i = 0; i < count; i++) {
        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, len, i, &data, &data_len);
        if (rc == 0) total_bytes += data_len;
    }

    progress_t prog;
    progress_init(&prog, count, total_bytes);

    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        rc = blip_archive_file_path(buf, len, i, &path, &path_len);
        if (rc != 0) {
            fprintf(stderr, "blar: extract: file %llu: %s\n", (unsigned long long)i, blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }

        const uint8_t *data = NULL;
        size_t data_len = 0;
        rc = blip_archive_file_content(buf, len, i, &data, &data_len);
        if (rc != 0) {
            fprintf(stderr, "blar: extract: file '%.*s': %s\n", (int)path_len, path, blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }

        /* Build output path */
        char out_path[4096];
        if (extract_dir) {
            snprintf(out_path, sizeof(out_path), "%s/%.*s", extract_dir, (int)path_len, path);
        } else {
            snprintf(out_path, sizeof(out_path), "%.*s", (int)path_len, path);
        }

        /* Create directories */
        if (mkdirs(out_path) != 0) {
            fprintf(stderr, "blar: extract: cannot create directory for '%s': %s\n", out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        if (write_file(out_path, data, data_len) != 0) {
            fprintf(stderr, "blar: extract: cannot write '%s': %s\n", out_path, strerror(errno));
            free(buf);
            return EXIT_IO;
        }

        progress_update(&prog, data_len);
    }

    progress_finish(&prog);
    free(buf);
    return EXIT_OK;
}

static int do_verify(const char *archive_path) {
    size_t len = 0;
    uint8_t *buf = read_file(archive_path, &len);
    if (!buf) {
        fprintf(stderr, "blar: verify: cannot open '%s': %s\n", archive_path, strerror(errno));
        return EXIT_IO;
    }

    /* Verify outer archive hash */
    if (!blip_archive_verify(buf, len)) {
        fprintf(stderr, "blar: verify: archive hash mismatch\n");
        free(buf);
        return EXIT_VERIFY;
    }

    /* Verify each file's xh64 */
    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, len, &count);
    if (rc != 0) {
        fprintf(stderr, "blar: verify: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    for (uint64_t i = 0; i < count; i++) {
        rc = blip_archive_file_verify(buf, len, i);
        if (rc != 0) {
            const char *path = NULL;
            size_t path_len = 0;
            blip_archive_file_path(buf, len, i, &path, &path_len);
            fprintf(stderr, "blar: verify: file '%.*s': %s\n",
                    (int)(path ? path_len : 0),
                    path ? path : "(unknown)",
                    blip_error_string(rc));
            free(buf);
            return EXIT_VERIFY;
        }
    }

    printf("OK: %llu files verified\n", (unsigned long long)count);
    free(buf);
    return EXIT_OK;
}

static int do_info(const char *archive_path) {
    size_t len = 0;
    uint8_t *buf = read_file(archive_path, &len);
    if (!buf) {
        fprintf(stderr, "blar: info: cannot open '%s': %s\n", archive_path, strerror(errno));
        return EXIT_IO;
    }

    uint64_t count = 0;
    int32_t rc = blip_archive_file_count(buf, len, &count);
    if (rc != 0) {
        fprintf(stderr, "blar: info: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    printf("Archive: %s\n", archive_path);
    printf("Size:    %zu bytes\n", len);
    printf("Files:   %llu\n", (unsigned long long)count);

    /* Per-file info */
    uint64_t total_content = 0;
    for (uint64_t i = 0; i < count; i++) {
        const char *path = NULL;
        size_t path_len = 0;
        const uint8_t *data = NULL;
        size_t data_len = 0;

        blip_archive_file_path(buf, len, i, &path, &path_len);
        blip_archive_file_content(buf, len, i, &data, &data_len);

        printf("  %.*s  (%zu bytes)\n", (int)path_len, path, data_len);
        total_content += data_len;
    }
    printf("Total content: %llu bytes\n", (unsigned long long)total_content);

    bool valid = blip_archive_verify(buf, len);
    printf("Integrity: %s\n", valid ? "OK" : "FAILED");

    free(buf);
    return valid ? EXIT_OK : EXIT_VERIFY;
}

static int do_cat(const char *archive_path, const char *file_path) {
    size_t len = 0;
    uint8_t *buf = read_file(archive_path, &len);
    if (!buf) {
        fprintf(stderr, "blar: cat: cannot open '%s': %s\n", archive_path, strerror(errno));
        return EXIT_IO;
    }

    const uint8_t *data = NULL;
    size_t data_len = 0;
    int32_t rc = blip_archive_file_content_by_path(
        buf, len, file_path, strlen(file_path), &data, &data_len);
    if (rc == -14) {
        fprintf(stderr, "blar: cat: file not found in archive: '%s'\n", file_path);
        free(buf);
        return EXIT_VERIFY;
    }
    if (rc != 0) {
        fprintf(stderr, "blar: cat: %s\n", blip_error_string(rc));
        free(buf);
        return EXIT_VERIFY;
    }

    if (data_len > 0) {
        fwrite(data, 1, data_len, stdout);
    }

    free(buf);
    return EXIT_OK;
}
```

Then update the switch statement at the end of `main()` to call the real implementations:

```c
    switch (op) {
        case OP_CREATE:  return do_create(output_path, input_files, input_file_count);
        case OP_LIST:    return do_list(archive_path);
        case OP_EXTRACT: return do_extract(archive_path, extract_dir);
        case OP_VERIFY:  return do_verify(archive_path);
        case OP_INFO:    return do_info(archive_path);
        case OP_CAT:     return do_cat(archive_path, cat_path);
        default:
            print_usage(stderr);
            return EXIT_USAGE;
    }
```

**Step 2: Build**

Run: `nix develop -c zig build -Doptimize=ReleaseFast`
Expected: Builds successfully.

**Step 3: Quick manual smoke test**

```bash
echo "Hello, world!" > /tmp/test_hello.txt
echo "Goodbye!" > /tmp/test_bye.txt
./zig-out/bin/blar create -o /tmp/test.blar /tmp/test_hello.txt /tmp/test_bye.txt
./zig-out/bin/blar list /tmp/test.blar
./zig-out/bin/blar verify /tmp/test.blar
./zig-out/bin/blar info /tmp/test.blar
./zig-out/bin/blar cat /tmp/test.blar /tmp/test_hello.txt
./zig-out/bin/blar tf /tmp/test.blar
```

**Step 4: Commit**

```bash
git add src/blar.c
git commit -m "Implement all blar operations: create, list, extract, verify, info, cat"
```

---

### Task 7: Convenience Script and Flake Update

Create the `./blar` convenience script and update `flake.nix`.

**Files:**
- Create: `blar` (project root convenience script)
- Modify: `flake.nix`

**Step 1: Create the convenience script**

Create `blar` at the project root:

```bash
#!/usr/bin/env bash
set -euo pipefail
nix develop -c zig build blar -Doptimize=ReleaseFast -- "$@"
```

Then make it executable: `chmod +x blar`

**Step 2: Update flake.nix to include blar in the package**

The existing `flake.nix` builds with `zig build --prefix $out` which will already include `blar` since we added `b.installArtifact(blar)` in `build.zig`. No change needed to `flake.nix`.

Verify: `nix develop -c zig build -Doptimize=ReleaseFast && ls -la zig-out/bin/blar`

**Step 3: Commit**

```bash
git add blar
git commit -m "Add blar convenience script"
```

---

### Task 8: Bash Integration Tests

Write comprehensive Bash tests for the blar CLI.

**Files:**
- Create: `tests/blar_test.sh`

**Step 1: Write the test script**

Create `tests/blar_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Build blar
BLAR="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/blar"
cd "$(dirname "$0")/.."
nix develop -c zig build -Doptimize=ReleaseFast

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Create test files
echo "Hello, world!" > "$TMPDIR/hello.txt"
echo "Goodbye, world!" > "$TMPDIR/goodbye.txt"
mkdir -p "$TMPDIR/sub"
echo "nested content" > "$TMPDIR/sub/nested.txt"
printf '\x00\x01\x02\xff' > "$TMPDIR/binary.bin"

echo "=== blar integration tests ==="

# --- Test 1: --help ---
echo "Test 1: --help"
if "$BLAR" --help >/dev/null 2>&1; then
    pass "--help exits 0"
else
    fail "--help should exit 0"
fi

# --- Test 2: --version ---
echo "Test 2: --version"
if "$BLAR" --version | grep -q "blar"; then
    pass "--version contains 'blar'"
else
    fail "--version should contain 'blar'"
fi

# --- Test 3: no args -> usage error ---
echo "Test 3: no args"
if ! "$BLAR" 2>/dev/null; then
    pass "no args exits non-zero"
else
    fail "no args should exit non-zero"
fi

# --- Test 4: create + list roundtrip (subcommand style) ---
echo "Test 4: create + list roundtrip"
"$BLAR" create -o "$TMPDIR/test.blar" "$TMPDIR/hello.txt" "$TMPDIR/goodbye.txt" 2>/dev/null
LIST=$("$BLAR" list "$TMPDIR/test.blar")
if echo "$LIST" | grep -q "hello.txt" && echo "$LIST" | grep -q "goodbye.txt"; then
    pass "create + list roundtrip"
else
    fail "create + list should show both files; got: $LIST"
fi

# --- Test 5: verify valid archive ---
echo "Test 5: verify valid"
if "$BLAR" verify "$TMPDIR/test.blar" >/dev/null 2>&1; then
    pass "verify valid archive"
else
    fail "verify should succeed on valid archive"
fi

# --- Test 6: verify corrupt archive ---
echo "Test 6: verify corrupt"
cp "$TMPDIR/test.blar" "$TMPDIR/corrupt.blar"
# Flip a byte in the middle
python3 -c "
import sys
with open(sys.argv[1], 'r+b') as f:
    data = bytearray(f.read())
    mid = len(data) // 2
    data[mid] ^= 0xFF
    f.seek(0)
    f.write(data)
" "$TMPDIR/corrupt.blar" 2>/dev/null || dd if=/dev/urandom bs=1 count=1 seek=$(($(wc -c < "$TMPDIR/corrupt.blar") / 2)) of="$TMPDIR/corrupt.blar" conv=notrunc 2>/dev/null
if ! "$BLAR" verify "$TMPDIR/corrupt.blar" >/dev/null 2>&1; then
    pass "verify detects corruption"
else
    fail "verify should fail on corrupt archive"
fi

# --- Test 7: info ---
echo "Test 7: info"
INFO=$("$BLAR" info "$TMPDIR/test.blar")
if echo "$INFO" | grep -q "Files:" && echo "$INFO" | grep -q "2"; then
    pass "info shows file count"
else
    fail "info should show file count; got: $INFO"
fi

# --- Test 8: cat ---
echo "Test 8: cat"
CATOUT=$("$BLAR" cat "$TMPDIR/test.blar" "$TMPDIR/hello.txt")
EXPECTED=$(cat "$TMPDIR/hello.txt")
if [ "$CATOUT" = "$EXPECTED" ]; then
    pass "cat file content matches"
else
    fail "cat content mismatch: expected '$EXPECTED', got '$CATOUT'"
fi

# --- Test 9: cat missing file ---
echo "Test 9: cat missing"
if ! "$BLAR" cat "$TMPDIR/test.blar" "nonexistent.txt" 2>/dev/null; then
    pass "cat missing file exits non-zero"
else
    fail "cat missing file should exit non-zero"
fi

# --- Test 10: create + extract roundtrip ---
echo "Test 10: extract roundtrip"
"$BLAR" create -o "$TMPDIR/extract_test.blar" "$TMPDIR/hello.txt" "$TMPDIR/goodbye.txt" 2>/dev/null
mkdir -p "$TMPDIR/extracted"
"$BLAR" extract "$TMPDIR/extract_test.blar" -C "$TMPDIR/extracted" 2>/dev/null
# The extracted files should have the full paths from the archive
if diff "$TMPDIR/hello.txt" "$TMPDIR/extracted/$TMPDIR/hello.txt" >/dev/null 2>&1 && \
   diff "$TMPDIR/goodbye.txt" "$TMPDIR/extracted/$TMPDIR/goodbye.txt" >/dev/null 2>&1; then
    pass "extract roundtrip matches"
else
    fail "extracted files don't match originals"
fi

# --- Test 11: tar-style flags ---
echo "Test 11: tar-style flags"
"$BLAR" cf "$TMPDIR/tar_test.blar" "$TMPDIR/hello.txt" 2>/dev/null
TARLIST=$("$BLAR" tf "$TMPDIR/tar_test.blar")
if echo "$TARLIST" | grep -q "hello.txt"; then
    pass "tar-style cf/tf works"
else
    fail "tar-style cf/tf failed; got: $TARLIST"
fi

# --- Test 12: tar-style without hyphen ---
echo "Test 12: tar-style without hyphen"
"$BLAR" -cf "$TMPDIR/tar_test2.blar" "$TMPDIR/hello.txt" 2>/dev/null
TARLIST2=$("$BLAR" -tf "$TMPDIR/tar_test2.blar")
if echo "$TARLIST2" | grep -q "hello.txt"; then
    pass "tar-style -cf/-tf works"
else
    fail "tar-style -cf/-tf failed; got: $TARLIST2"
fi

# --- Test 13: empty archive ---
echo "Test 13: empty archive"
"$BLAR" create -o "$TMPDIR/empty.blar" 2>/dev/null
EMPTY_LIST=$("$BLAR" list "$TMPDIR/empty.blar")
if [ -z "$EMPTY_LIST" ]; then
    pass "empty archive lists nothing"
else
    fail "empty archive should list nothing; got: $EMPTY_LIST"
fi
if "$BLAR" verify "$TMPDIR/empty.blar" >/dev/null 2>&1; then
    pass "empty archive verifies"
else
    fail "empty archive should verify"
fi

# --- Test 14: unknown command ---
echo "Test 14: unknown command"
if ! "$BLAR" bogus 2>/dev/null; then
    pass "unknown command exits non-zero"
else
    fail "unknown command should exit non-zero"
fi

# --- Test 15: binary content ---
echo "Test 15: binary content"
"$BLAR" create -o "$TMPDIR/bin_test.blar" "$TMPDIR/binary.bin" 2>/dev/null
"$BLAR" cat "$TMPDIR/bin_test.blar" "$TMPDIR/binary.bin" > "$TMPDIR/bin_out.bin"
if diff "$TMPDIR/binary.bin" "$TMPDIR/bin_out.bin" >/dev/null 2>&1; then
    pass "binary content roundtrip"
else
    fail "binary content mismatch"
fi

# --- Test 16: verify tar-style Vf ---
echo "Test 16: tar-style Vf"
if "$BLAR" Vf "$TMPDIR/test.blar" >/dev/null 2>&1; then
    pass "tar-style Vf works"
else
    fail "tar-style Vf should work"
fi

# --- Test 17: progress suppression when piped ---
echo "Test 17: progress suppression"
# When stdout is piped, stderr should have no progress bar
OUTPUT=$("$BLAR" list "$TMPDIR/test.blar" 2>"$TMPDIR/stderr_out.txt")
if ! grep -q '█' "$TMPDIR/stderr_out.txt" 2>/dev/null; then
    pass "no progress bar when piped (list)"
else
    fail "progress bar should not appear when piped"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
```

Make executable: `chmod +x tests/blar_test.sh`

**Step 2: Run the tests**

Run: `./tests/blar_test.sh`
Expected: All tests pass. If any fail, fix the issues in `src/blar.c` and re-run.

**Step 3: Commit**

```bash
git add tests/blar_test.sh
git commit -m "Add blar integration test suite (17 tests)"
```

---

### Task 9: Update Documentation

Update README and CODE_MINIMAP to include blar.

**Files:**
- Modify: `README.md`
- Modify: `CODE_MINIMAP.md`
- Modify: `PLAN.md`

**Step 1: Add blar section to README.md**

Add after the "C FFI" section and before "License":

```markdown
## blar: BLIP Archive Tool

`blar` is a CLI for creating, inspecting, and extracting BLIP archives — similar to `tar`.

### Usage

```bash
# Create an archive
blar create -o archive.blar file1.txt file2.txt dir/file3.txt

# List files
blar list archive.blar

# Extract all files
blar extract archive.blar -C output_dir/

# Verify integrity (outer + per-file xxHash64)
blar verify archive.blar

# Show metadata
blar info archive.blar

# Print single file to stdout
blar cat archive.blar path/to/file.txt
```

### Tar-style shortcuts (hyphen optional)

```bash
blar cf archive.blar file1.txt    # create
blar tf archive.blar              # list
blar xf archive.blar              # extract
blar Vf archive.blar              # verify
blar If archive.blar              # info
blar pf archive.blar file.txt     # cat (print)
```
```

**Step 2: Add blar to CODE_MINIMAP.md**

Add at the end:

```markdown
## src/blar.c
C CLI for BLIP archives (calls through C FFI).
- `do_create` — read files, call `blip_archive_create`, write archive
- `do_list` — print file paths from archive
- `do_extract` — extract files to disk with directory creation
- `do_verify` — verify outer hash + per-file xh64
- `do_info` — print archive metadata (file count, sizes, integrity)
- `do_cat` — print single file content to stdout
- Progress bar on stderr when connected to interactive terminal

## tests/blar_test.sh
Bash integration tests for blar CLI (17 tests).
```

**Step 3: Update PLAN.md**

Add to the Completed section:

```markdown
- [x] blar CLI — C archive tool (create/list/extract/verify/info/cat)
- [x] FFI expansion (file_path, file_content, file_verify, error_string)
- [x] blar integration tests (17 tests)
```

**Step 4: Commit**

```bash
git add README.md CODE_MINIMAP.md PLAN.md
git commit -m "Document blar CLI in README, CODE_MINIMAP, and PLAN"
```

---

### Task 10: Final Verification

Run all tests — both Zig unit tests and Bash integration tests.

**Files:** None (verification only)

**Step 1: Run Zig tests**

Run: `nix develop -c zig build test -Doptimize=Debug`
Expected: All tests pass (447+ including new FFI tests).

**Step 2: Run blar integration tests**

Run: `./tests/blar_test.sh`
Expected: All 17 tests pass.

**Step 3: Build ReleaseFast and verify binary works**

Run: `nix develop -c zig build -Doptimize=ReleaseFast && ./zig-out/bin/blar --version`
Expected: Prints version.

**Step 4: Push**

```bash
git push origin yolo
```
