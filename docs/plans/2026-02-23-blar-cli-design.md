# blar CLI Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A C CLI binary (`blar`) that exercises the Zig BLIP library through the C FFI, supporting archive create/list/extract/verify/info/cat operations similar to tar.

**Architecture:** C CLI (`src/blar.c`) calls through C FFI boundary (`src/lib.zig` / `src/blip.h`). All encoding/container logic stays in Zig. The CLI handles all I/O, argument parsing, progress display, and error reporting.

**Tech Stack:** C11, POSIX (for `isatty`, `opendir`/`readdir`), Zig build system

---

## CLI Interface

### Binary name: `blar`

### Operations (both subcommand and tar-style, hyphen optional):

| Subcommand | Tar flag | Description |
|------------|----------|-------------|
| `blar create -o out.blar file1 file2 ...` | `blar cf out.blar file1 file2 ...` | Create archive |
| `blar list archive.blar` | `blar tf archive.blar` | List file paths |
| `blar extract archive.blar [-C dir]` | `blar xf archive.blar [-C dir]` | Extract all files |
| `blar verify archive.blar` | `blar Vf archive.blar` | Verify xxHash64 integrity |
| `blar info archive.blar` | `blar If archive.blar` | Show archive metadata |
| `blar cat archive.blar path` | `blar pf archive.blar path` | Print single file to stdout |

### Tar-style flag aliases:
- `c` = create, `t` = list, `x` = extract, `V` = verify, `I` = info, `p` = cat (print)
- `f` = next arg is archive file (required for tar-style)
- Hyphen optional: `blar cf` = `blar -cf`

### Exit codes:
- 0 = success
- 1 = usage error (bad arguments)
- 2 = I/O error (file not found, permission denied, write failure)
- 3 = verification/integrity error (corrupt archive, hash mismatch)

---

## Architecture & FFI

### New FFI functions needed:

```c
// Get file path from archive by index (zero-copy pointer into buf)
int32_t blip_archive_file_path(const uint8_t *buf, size_t buf_len,
                                uint64_t index,
                                const char **out_path, size_t *out_path_len);

// Get file content from archive by index (zero-copy pointer into buf)
int32_t blip_archive_file_content(const uint8_t *buf, size_t buf_len,
                                   uint64_t index,
                                   const uint8_t **out_data, size_t *out_data_len);

// Get file content by path (zero-copy pointer into buf)
int32_t blip_archive_file_content_by_path(const uint8_t *buf, size_t buf_len,
                                           const char *path, size_t path_len,
                                           const uint8_t **out_data, size_t *out_data_len);

// Verify a single file's hash within archive
int32_t blip_archive_file_verify(const uint8_t *buf, size_t buf_len,
                                  uint64_t index);

// Get human-readable error string for an error code
const char *blip_error_string(int32_t error_code);
```

### Error code expansion:

Currently all errors collapse to `-1`. New scheme:

```c
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
```

Existing FFI functions (`blip_encode`, `blip_decode`, etc.) keep returning `-1` for backward compatibility. New functions use the expanded codes.

### Zero-copy design:

Read operations (`file_path`, `file_content`, `file_content_by_path`) return pointers directly into the archive buffer. No allocation or copying needed. The pointers are valid as long as the archive buffer is alive.

---

## Error Handling

### FFI error propagation:
- Each Zig `ContainerError` maps to a specific negative `int32_t` code
- `blip_error_string()` returns a static string for each code (e.g., "hash mismatch", "index out of bounds")
- CLI formats errors with context: `blar: <operation>: <error_string> [detail]`

### CLI error messages:
```
blar: create: cannot open 'missing.txt': No such file or directory
blar: extract: corrupt archive: hash mismatch
blar: cat: file not found in archive: 'nonexistent.txt'
blar: error: expected archive file argument
```

---

## Progress Display

### Interactive terminal detection:
- Check `isatty(STDERR_FILENO)` before showing progress
- Progress always goes to stderr (stdout stays clean for `list`/`cat`)

### Progress bar format (create and extract):
```
[████████░░░░░░░░]  3/7 files   1.2 MB / 4.8 MB
```

### Implementation:
- Track files processed and bytes processed
- Update with `\r` (carriage return) to overwrite in place
- Final line uses `\n` to preserve the completed progress
- When not a tty: no progress output at all (clean for scripting/pipes)
- Bar width: 16 chars fixed (works in narrow terminals)

---

## Build Integration

- New executable target `blar` in `build.zig`: compiles `src/blar.c`, links against `libblip.a`
- Convenience script `./blar` at project root (like `./test`, `./build`)
- Update `flake.nix` packages to include `blar`
- Update README with blar usage section

---

## Testing

### Bash integration tests (`tests/blar_test.sh`):

1. **Create + list roundtrip**: Create archive from test files, list contents, verify all paths present
2. **Create + extract roundtrip**: Create archive, extract to temp dir, `diff` originals vs extracted
3. **Verify valid archive**: Create archive, verify returns exit 0
4. **Verify corrupt archive**: Create archive, flip a byte, verify returns exit 3
5. **Info output**: Create archive, check info output contains file count and sizes
6. **Cat single file**: Create archive, cat a file, compare to original
7. **Cat missing file**: Cat nonexistent path, check exit 3
8. **Tar-style flags**: All operations work with `cf`, `tf`, `xf`, `Vf`, `If`, `pf`
9. **Tar-style without hyphen**: `blar cf` same as `blar -cf`
10. **Empty archive**: Create archive with no files, list shows nothing, verify passes
11. **Bad arguments**: Missing args, unknown flags — check exit 1 and stderr message
12. **Progress suppression**: Pipe stdout, confirm no progress bar in output
13. **Error messages**: Verify error messages are informative and contain context
