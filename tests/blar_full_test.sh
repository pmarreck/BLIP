#!/usr/bin/env bash
set -u

# =============================================================================
# blar full integration test suite
# =============================================================================
# Tests the full blar CLI with directory support, metadata, and Merkle hashing.
# =============================================================================

# --------------- paths ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"

# --------------- build ---------------
echo "Building blar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$BLAR" ]]; then
  echo "FATAL: blar binary not found at $BLAR"
  exit 1
fi

# --------------- temp dir + cleanup ---------------
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --------------- counters ---------------
PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

# --------------- create test fixtures ---------------
# Create a directory tree
mkdir -p "$TMPDIR_TEST/myproject/src"
mkdir -p "$TMPDIR_TEST/myproject/docs"
echo "hello world" > "$TMPDIR_TEST/myproject/README.md"
echo "fn main() void {}" > "$TMPDIR_TEST/myproject/src/main.zig"
echo "const x = 42;" > "$TMPDIR_TEST/myproject/src/lib.zig"
echo "# Design doc" > "$TMPDIR_TEST/myproject/docs/design.md"

# Set specific permissions on a file for testing
chmod 755 "$TMPDIR_TEST/myproject/src/main.zig"

# Binary file
dd if=/dev/urandom of="$TMPDIR_TEST/myproject/binary.dat" bs=256 count=1 2>/dev/null

# Simple text files for basic tests
echo "hello world" > "$TMPDIR_TEST/hello.txt"
echo "foo bar baz" > "$TMPDIR_TEST/foo.txt"

# =============================================================================
# Tests
# =============================================================================

# --------------- 1. --help exits 0 ---------------
if "$BLAR" --help >/dev/null 2>&1; then
  pass "--help exits 0"
else
  fail "--help exits 0 (got exit $?)"
fi

# --------------- 2. --version contains 'blar' ---------------
VERSION_OUT="$("$BLAR" --version 2>&1)"
if echo "$VERSION_OUT" | grep -qi "blar"; then
  pass "--version contains 'blar'"
else
  fail "--version contains 'blar' (got: $VERSION_OUT)"
fi

# --------------- 3. No args exits non-zero ---------------
if "$BLAR" >/dev/null 2>&1; then
  fail "no args exits non-zero (got exit 0)"
else
  pass "no args exits non-zero"
fi

# --------------- 4. Create archive from directory tree ---------------
ARCHIVE_DIR="$TMPDIR_TEST/myproject.blar"
"$BLAR" create -o "$ARCHIVE_DIR" "$TMPDIR_TEST/myproject" 2>/dev/null
if [[ -f "$ARCHIVE_DIR" ]]; then
  pass "create archive from directory tree"
else
  fail "create archive from directory tree — archive not created"
fi

# --------------- 5. List shows DIR entries with 'd' prefix ---------------
LIST_OUT="$("$BLAR" list "$ARCHIVE_DIR" 2>/dev/null)"
if echo "$LIST_OUT" | grep -q "^d "; then
  pass "list shows DIR entries with 'd' prefix"
else
  fail "list shows DIR entries with 'd' prefix — output: $LIST_OUT"
fi

# --------------- 6. List shows FILE entries with '-' prefix ---------------
if echo "$LIST_OUT" | grep -q "^- "; then
  pass "list shows FILE entries with '-' prefix"
else
  fail "list shows FILE entries with '-' prefix — output: $LIST_OUT"
fi

# --------------- 7. Verify works with mixed FILE/DIR archives ---------------
if "$BLAR" verify "$ARCHIVE_DIR" >/dev/null 2>&1; then
  pass "verify works with mixed FILE/DIR archives"
else
  fail "verify works with mixed FILE/DIR archives (got exit $?)"
fi

# --------------- 8. Info reports file count + directory count ---------------
INFO_OUT="$("$BLAR" info "$ARCHIVE_DIR" 2>/dev/null)"
if echo "$INFO_OUT" | grep -qE "Files:" && echo "$INFO_OUT" | grep -qE "Directories:"; then
  pass "info reports file count and directory count"
else
  fail "info reports file count and directory count — output: $INFO_OUT"
fi

# --------------- 9. Extract restores directory structure ---------------
EXTRACT_DIR="$TMPDIR_TEST/extracted"
mkdir -p "$EXTRACT_DIR"
"$BLAR" extract "$ARCHIVE_DIR" -C "$EXTRACT_DIR" 2>/dev/null

# Check that directory structure exists
NORM_BASE="$(echo "$TMPDIR_TEST/myproject" | sed 's|^\./||; s|^/||')"
if [[ -d "$EXTRACT_DIR/$NORM_BASE/src" ]] && [[ -d "$EXTRACT_DIR/$NORM_BASE/docs" ]]; then
  pass "extract restores directory structure"
else
  fail "extract restores directory structure — expected $EXTRACT_DIR/$NORM_BASE/src and docs"
fi

# --------------- 10. Extract restores file content ---------------
EXTRACTED_MAIN="$EXTRACT_DIR/$NORM_BASE/src/main.zig"
if [[ -f "$EXTRACTED_MAIN" ]]; then
  ORIGINAL="$(cat "$TMPDIR_TEST/myproject/src/main.zig")"
  EXTRACTED="$(cat "$EXTRACTED_MAIN")"
  if [[ "$ORIGINAL" == "$EXTRACTED" ]]; then
    pass "extract restores file content"
  else
    fail "extract restores file content — content mismatch"
  fi
else
  fail "extract restores file content — file not found at $EXTRACTED_MAIN"
fi

# --------------- 11. Tar-style flags work for create/list ---------------
ARCHIVE_TAR="$TMPDIR_TEST/tar_style.blar"
"$BLAR" cf "$ARCHIVE_TAR" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" 2>/dev/null
TAR_LIST="$("$BLAR" tf "$ARCHIVE_TAR" 2>/dev/null)"
if echo "$TAR_LIST" | grep -q "hello.txt" && echo "$TAR_LIST" | grep -q "foo.txt"; then
  pass "tar-style flags cf/tf work"
else
  fail "tar-style flags cf/tf work — listing: $TAR_LIST"
fi

# --------------- 12. Tar-style Vf works ---------------
if "$BLAR" Vf "$ARCHIVE_TAR" >/dev/null 2>&1; then
  pass "tar-style Vf works"
else
  fail "tar-style Vf works (got exit $?)"
fi

# --------------- 13. Cat file content ---------------
# Paths are now normalized (leading / stripped) in the archive
NORM_HELLO="${TMPDIR_TEST#/}/hello.txt"
CAT_OUT="$("$BLAR" cat "$ARCHIVE_TAR" "$NORM_HELLO" 2>/dev/null)"
EXPECTED="$(cat "$TMPDIR_TEST/hello.txt")"
if [[ "$CAT_OUT" == "$EXPECTED" ]]; then
  pass "cat file content matches original"
else
  fail "cat file content matches original (expected '$EXPECTED', got '$CAT_OUT')"
fi

# --------------- 14. Binary content roundtrip ---------------
ARCHIVE_BIN="$TMPDIR_TEST/binary.blar"
"$BLAR" create -o "$ARCHIVE_BIN" "$TMPDIR_TEST/myproject/binary.dat" 2>/dev/null
NORM_BINARY="${TMPDIR_TEST#/}/myproject/binary.dat"
"$BLAR" cat "$ARCHIVE_BIN" "$NORM_BINARY" > "$TMPDIR_TEST/binary_out.dat" 2>/dev/null
if diff -q "$TMPDIR_TEST/myproject/binary.dat" "$TMPDIR_TEST/binary_out.dat" >/dev/null 2>&1; then
  pass "binary content roundtrip"
else
  fail "binary content roundtrip — files differ"
fi

# --------------- 15. Corrupt archive detection ---------------
CORRUPT="$TMPDIR_TEST/corrupt.blar"
cp "$ARCHIVE_DIR" "$CORRUPT"
FILE_SIZE=$(wc -c < "$CORRUPT" | tr -d ' ')
OFFSET=$(( FILE_SIZE / 2 ))
printf '\xff' | dd of="$CORRUPT" bs=1 seek="$OFFSET" count=1 conv=notrunc 2>/dev/null
if "$BLAR" verify "$CORRUPT" >/dev/null 2>&1; then
  fail "verify corrupt archive exits non-zero (got exit 0)"
else
  pass "verify corrupt archive exits non-zero"
fi

# --------------- 16. Unknown command exits non-zero ---------------
if "$BLAR" frobnicate >/dev/null 2>&1; then
  fail "unknown command exits non-zero (got exit 0)"
else
  pass "unknown command exits non-zero"
fi

# --------------- 17. Progress suppression ---------------
STDERR_FILE="$TMPDIR_TEST/stderr_capture.txt"
"$BLAR" create -o "$TMPDIR_TEST/progress_test.blar" "$TMPDIR_TEST/hello.txt" 2>"$STDERR_FILE"
if [[ -s "$STDERR_FILE" ]]; then
  if perl -ne 'exit 1 if /[\r\x1b]/' "$STDERR_FILE"; then
    pass "progress suppression: no progress-bar chars in piped stderr"
  else
    fail "progress suppression: found progress-bar chars in piped stderr"
  fi
else
  pass "progress suppression: no progress-bar chars in piped stderr"
fi

# --------------- 18. Default output name ---------------
cd "$TMPDIR_TEST"
"$BLAR" create myproject 2>/dev/null
if [[ -f "$TMPDIR_TEST/myproject.blar" ]]; then
  pass "default output name: blar create mydir -> mydir.blar"
else
  fail "default output name: blar create mydir -> mydir.blar (file not found)"
fi
cd "$PROJECT_DIR"

# --------------- 19. Xattr round-trip (macOS only) ---------------
if [[ "$(uname)" == "Darwin" ]]; then
  XATTR_DIR="$TMPDIR_TEST/xattr_test"
  mkdir -p "$XATTR_DIR"
  echo "xattr test content" > "$XATTR_DIR/xfile.txt"
  xattr -w user.test_blip "hello_xattr" "$XATTR_DIR/xfile.txt"

  XATTR_ARCHIVE="$TMPDIR_TEST/xattr_test.blar"
  "$BLAR" create -o "$XATTR_ARCHIVE" "$XATTR_DIR" 2>/dev/null

  XATTR_EXTRACT="$TMPDIR_TEST/xattr_extracted"
  mkdir -p "$XATTR_EXTRACT"
  "$BLAR" extract "$XATTR_ARCHIVE" -C "$XATTR_EXTRACT" 2>/dev/null

  # Find the extracted file (path is normalized, leading / stripped)
  NORM_XATTR_PATH="$(echo "$XATTR_DIR/xfile.txt" | sed 's|^/||')"
  XATTR_OUT="$XATTR_EXTRACT/$NORM_XATTR_PATH"

  if [[ -f "$XATTR_OUT" ]]; then
    XATTR_VAL="$(xattr -p user.test_blip "$XATTR_OUT" 2>/dev/null)"
    if [[ "$XATTR_VAL" == "hello_xattr" ]]; then
      pass "xattr round-trip preserves user.test_blip"
    else
      fail "xattr round-trip: expected 'hello_xattr', got '$XATTR_VAL'"
    fi
  else
    fail "xattr round-trip: extracted file not found at $XATTR_OUT"
  fi
else
  echo "SKIP: xattr round-trip (macOS only)"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
