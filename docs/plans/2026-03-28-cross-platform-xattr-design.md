# Cross-Platform Xattr & Resource Fork Handling

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make xattr and resource fork data survive cross-platform round-trips (macOS ↔ Linux ↔ Windows) without silent data loss, with testable platform abstraction.

**Architecture:** Replace compile-time `#ifdef` platform detection with a runtime capability struct that defaults to the real platform but can be injected in tests. Add xattr name mapping (macOS ↔ Linux conventions) and AppleDouble `._filename` sidecar support as a fallback for resource forks on non-HFS+ filesystems.

**Tech Stack:** C (blar_common.h, blar.c, miniblar.c), shell integration tests.

---

### Task 1: Extract platform_caps_t abstraction

**Files:**
- Modify: `src/blar_common.h`

**Step 1: Write the failing test**

Create `tests/xattr_platform_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
BLAR="${BLAR:-$PWD/zig-out/bin/blar}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create a file with an xattr
echo "hello" > "$TMPDIR/test.txt"
# Set xattr if supported (skip test gracefully if not)
if ! xattr -w user.test.key "test_value" "$TMPDIR/test.txt" 2>/dev/null && \
   ! attr -s test.key -V "test_value" "$TMPDIR/test.txt" 2>/dev/null && \
   ! setfattr -n user.test.key -v "test_value" "$TMPDIR/test.txt" 2>/dev/null; then
    echo "SKIP: xattr not supported on this filesystem"
    exit 0
fi

# Archive and extract — xattr should survive
$BLAR create -o "$TMPDIR/test.blar" "$TMPDIR/test.txt"
mkdir -p "$TMPDIR/out"
$BLAR extract "$TMPDIR/test.blar" -C "$TMPDIR/out"

# Verify xattr survived
if xattr -p user.test.key "$TMPDIR/out/test.txt" 2>/dev/null | grep -q "test_value"; then
    echo "PASS: xattr round-trip"
elif getfattr -n user.test.key "$TMPDIR/out/test.txt" 2>/dev/null | grep -q "test_value"; then
    echo "PASS: xattr round-trip"
else
    echo "FAIL: xattr not preserved"
    exit 1
fi
```

**Step 2: Run test to verify current behavior works (baseline)**

Run: `nix develop -c bash tests/xattr_platform_test.sh`
Expected: PASS (xattrs already work on the native platform)

**Step 3: Define platform_caps_t struct**

Add to `blar_common.h` before `write_file_xattrs`:

```c
/* Platform capability flags for cross-platform xattr/resource fork handling.
 * Defaults to compile-time detection; can be overridden for testing. */
typedef struct {
    bool has_xattr;           /* Can read/write extended attributes */
    bool has_resource_fork;   /* Can write com.apple.ResourceFork xattr (macOS) */
    bool use_apple_double;    /* Write ._filename sidecars for resource forks */
    /* Map an xattr name from archive format to platform format.
     * Returns a static or malloc'd string. NULL = identity mapping.
     * If malloc'd, caller must free. Set free_mapped_name = true. */
    const char *(*map_xattr_name)(const char *name, size_t name_len,
                                   size_t *out_len, bool *free_mapped_name);
} platform_caps_t;

static platform_caps_t platform_caps_default(void) {
    platform_caps_t caps = {0};
#ifdef HAVE_XATTR
    caps.has_xattr = true;
#endif
#ifdef __APPLE__
    caps.has_resource_fork = true;
#endif
    return caps;
}
```

**Step 4: Update write_file_xattrs signature**

Change:
```c
static void write_file_xattrs(const char *path,
                                const blip_xattr_entry *xattrs, size_t count,
                                const uint8_t *resource_fork, size_t resource_fork_len)
```
To:
```c
static void write_file_xattrs(const char *path,
                                const blip_xattr_entry *xattrs, size_t count,
                                const uint8_t *resource_fork, size_t resource_fork_len,
                                const platform_caps_t *caps)
```

If `caps` is NULL, use `platform_caps_default()`. Replace all `#ifdef` branches with runtime `if (caps->has_xattr)` / `if (caps->has_resource_fork)` checks.

**Step 5: Update all call sites**

In `blar.c` and `miniblar.c`, pass `NULL` for caps (use defaults). Search for `write_file_xattrs(` and add the extra parameter.

**Step 6: Build and verify tests still pass**

Run: `nix develop -c zig build && nix develop -c bash tests/xattr_platform_test.sh`
Expected: PASS (behavior unchanged, just refactored)

**Step 7: Commit**

```bash
git add src/blar_common.h src/blar.c src/miniblar.c tests/xattr_platform_test.sh
git commit -m "refactor: extract platform_caps_t for testable xattr handling"
```

---

### Task 2: Cross-platform xattr name mapping

**Files:**
- Modify: `src/blar_common.h`

**Step 1: Write the failing test**

Add to `tests/xattr_platform_test.sh`:
```bash
# Test: xattr name mapping function
# This tests the C-level mapping via a small test program or via
# archive inspection (peek the xattr names in the archive)

# Create file with macOS-style xattr name on Linux (user. prefix required)
if [ "$(uname)" = "Linux" ]; then
    echo "linux xattr test" > "$TMPDIR/linux_xa.txt"
    setfattr -n user.com.apple.quarantine -v "test" "$TMPDIR/linux_xa.txt" 2>/dev/null || true
    $BLAR create -o "$TMPDIR/linux_xa.blar" "$TMPDIR/linux_xa.txt"
    # Archive should store without user. prefix (canonical macOS name)
    # Verify via to-json
    $BLAR to-json "$TMPDIR/linux_xa.blar" | grep -q "com.apple.quarantine" && \
        echo "PASS: Linux xattr name stored in canonical form" || \
        echo "FAIL: xattr name not canonicalized"
fi
```

**Step 2: Implement xattr name mapping functions**

```c
/* Map xattr name from platform format to archive (canonical) format.
 * Archive uses macOS conventions (no user. prefix for well-known names).
 * Linux requires user. prefix for user namespace xattrs. */
static const char *xattr_name_to_archive(const char *name, size_t len,
                                          size_t *out_len) {
    /* Linux: strip "user." prefix for com.apple.* names */
    if (len > 5 && memcmp(name, "user.", 5) == 0) {
        /* Only strip for names that are recognizably macOS xattrs */
        if (len > 15 && memcmp(name + 5, "com.apple.", 10) == 0) {
            *out_len = len - 5;
            return name + 5;
        }
    }
    *out_len = len;
    return name;
}

/* Map xattr name from archive (canonical) format to platform format.
 * Returns pointer to static or input string (never needs freeing). */
static const char *xattr_name_from_archive(const char *name, size_t len,
                                            char *buf, size_t buf_cap,
                                            size_t *out_len) {
#ifdef __APPLE__
    /* macOS: use name as-is (archive uses macOS conventions) */
    *out_len = len;
    return name;
#else
    /* Linux: add "user." prefix for com.apple.* names that lack it */
    if (len >= 10 && memcmp(name, "com.apple.", 10) == 0) {
        if (5 + len < buf_cap) {
            memcpy(buf, "user.", 5);
            memcpy(buf + 5, name, len);
            buf[5 + len] = '\0';
            *out_len = 5 + len;
            return buf;
        }
    }
    /* Other names: pass through */
    *out_len = len;
    return name;
#endif
}
```

**Step 3: Wire mapping into read_file_xattrs and write_file_xattrs**

- `read_file_xattrs`: Apply `xattr_name_to_archive()` when storing names
- `write_file_xattrs`: Apply `xattr_name_from_archive()` when restoring names

**Step 4: Build and test**

Run: `nix develop -c zig build && nix develop -c bash tests/xattr_platform_test.sh`

**Step 5: Commit**

```bash
git commit -m "feat: cross-platform xattr name mapping (macOS ↔ Linux)"
```

---

### Task 3: AppleDouble resource fork sidecar fallback

**Files:**
- Modify: `src/blar_common.h`

**Step 1: Write the failing test**

```bash
# Test: resource fork extracted as AppleDouble on non-macOS
# Create an archive with a resource fork (on macOS, or via poke)
# Extract with --apple-double flag
# Verify ._filename sidecar exists and contains the data

# We can test this even on macOS by forcing the flag
echo "main data" > "$TMPDIR/rf_test.txt"
# ... (create archive with resource fork via macOS xattr or poke)

$BLAR extract "$TMPDIR/rf_test.blar" -C "$TMPDIR/rf_out" --apple-double
test -f "$TMPDIR/rf_out/._rf_test.txt" || { echo "FAIL: AppleDouble sidecar missing"; exit 1; }
echo "PASS: AppleDouble resource fork sidecar created"
```

**Step 2: Implement AppleDouble writer**

AppleDouble format (minimal, for resource fork only):
```
Offset  Size  Field
0       4     Magic: 0x00051607
4       4     Version: 0x00020000
8       16    Filler (zeros)
24      2     Entry count: 1
26      4     Entry ID: 2 (resource fork)
30      4     Offset: 38
34      4     Length: N
38      N     Resource fork data
```

```c
static bool write_apple_double(const char *path,
                                const uint8_t *resource_fork, size_t len) {
    /* Build ._filename path */
    /* ... */
    /* Write AppleDouble header + resource fork data */
    /* ... */
}
```

**Step 3: Implement AppleDouble reader (for archiving)**

```c
static bool read_apple_double(const char *path,
                               uint8_t **out_resource_fork, size_t *out_len) {
    /* Check for ._filename sidecar */
    /* Parse AppleDouble header, extract resource fork entry */
    /* ... */
}
```

**Step 4: Wire into extraction and archiving**

- In `write_file_xattrs`: if `caps->use_apple_double && resource_fork`, call `write_apple_double()`
- In `read_file_xattrs`: check for `._filename` sidecar, read resource fork from it
- Add `--apple-double` CLI flag to blar extract

**Step 5: Build and test**

**Step 6: Commit**

```bash
git commit -m "feat: AppleDouble ._filename sidecar for resource forks on non-HFS+"
```

---

### Task 4: Platform injection for unit testing

**Files:**
- Modify: `src/blar_common.h`
- Create: `tests/xattr_crossplatform_test.sh`

**Step 1: Write comprehensive cross-platform simulation tests**

```bash
# Test matrix (simulated via platform_caps_t injection):
# 1. macOS archive → "Linux" extract: resource fork → warning + user. prefix xattrs
# 2. macOS archive → "Windows" extract: resource fork → warning, xattrs → warning
# 3. macOS archive → "Linux+AppleDouble" extract: resource fork → ._filename
# 4. Linux archive → "macOS" extract: user.com.apple.* → com.apple.* (strip prefix)
# 5. Round-trip: macOS → archive → "Linux" → re-archive → "macOS" → verify data intact
```

Since these need C-level platform injection, implement as a small test harness program (`tests/xattr_test_harness.c`) that links against libblip and exercises `write_file_xattrs` with fake caps. Or, test via archive manipulation: create archives with known xattr data using `poke`, extract on the real platform, verify behavior.

**Step 2: Implement and verify**

**Step 3: Commit**

```bash
git commit -m "test: cross-platform xattr simulation tests"
```

---

## Summary

| Task | Description | Dependencies |
|------|-------------|--------------|
| 1 | Extract platform_caps_t abstraction | None |
| 2 | Cross-platform xattr name mapping | Task 1 |
| 3 | AppleDouble resource fork sidecar | Task 1 |
| 4 | Platform injection tests | Tasks 1-3 |

Tasks 2 and 3 are independent of each other (both depend on Task 1).
