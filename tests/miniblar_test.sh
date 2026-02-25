#!/usr/bin/env bash
set -u

# =============================================================================
# miniblar integration test suite
# =============================================================================
# Exercises the miniblar CLI end-to-end: create, list, extract, verify, info,
# cat, tar-style shorthand flags, corruption detection, binary roundtrip,
# directory rejection, and more.
# =============================================================================

# --------------- paths ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MINIBLAR="$PROJECT_DIR/zig-out/bin/miniblar"

# --------------- build ---------------
echo "Building miniblar..."
(cd "$PROJECT_DIR" && nix develop -c zig build -Doptimize=ReleaseFast) \
  || { echo "FATAL: build failed"; exit 1; }

if [[ ! -x "$MINIBLAR" ]]; then
  echo "FATAL: miniblar binary not found at $MINIBLAR"
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
# Text files
echo "hello world" > "$TMPDIR_TEST/hello.txt"
echo "foo bar baz" > "$TMPDIR_TEST/foo.txt"

# Nested directory
mkdir -p "$TMPDIR_TEST/sub/dir"
echo "nested content here" > "$TMPDIR_TEST/sub/dir/nested.txt"

# Binary file (256 bytes of pseudorandom data)
dd if=/dev/urandom of="$TMPDIR_TEST/binary.dat" bs=256 count=1 2>/dev/null

# =============================================================================
# Tests
# =============================================================================

# --------------- 1. --help exits 0 ---------------
if "$MINIBLAR" --help >/dev/null 2>&1; then
  pass "--help exits 0"
else
  fail "--help exits 0 (got exit $?)"
fi

# --------------- 2. --version contains 'miniblar' ---------------
VERSION_OUT="$("$MINIBLAR" --version 2>&1)"
if echo "$VERSION_OUT" | grep -qi "miniblar"; then
  pass "--version contains 'miniblar'"
else
  fail "--version contains 'miniblar' (got: $VERSION_OUT)"
fi

# --------------- 3. No args exits non-zero ---------------
if "$MINIBLAR" >/dev/null 2>&1; then
  fail "no args exits non-zero (got exit 0)"
else
  pass "no args exits non-zero"
fi

# --------------- 4. Create + list roundtrip (subcommand style) ---------------
ARCHIVE_ROUNDTRIP="$TMPDIR_TEST/roundtrip.mblar"
"$MINIBLAR" create -o "$ARCHIVE_ROUNDTRIP" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" 2>/dev/null
LIST_OUT="$("$MINIBLAR" list "$ARCHIVE_ROUNDTRIP" 2>/dev/null)"
if echo "$LIST_OUT" | grep -q "hello.txt" && echo "$LIST_OUT" | grep -q "foo.txt"; then
  pass "create + list roundtrip (subcommand style)"
else
  fail "create + list roundtrip (subcommand style) — listing: $LIST_OUT"
fi

# --------------- 5. Verify valid archive exits 0 ---------------
if "$MINIBLAR" verify "$ARCHIVE_ROUNDTRIP" >/dev/null 2>&1; then
  pass "verify valid archive exits 0"
else
  fail "verify valid archive exits 0 (got exit $?)"
fi

# --------------- 6. Verify corrupt archive exits non-zero ---------------
CORRUPT="$TMPDIR_TEST/corrupt.mblar"
cp "$ARCHIVE_ROUNDTRIP" "$CORRUPT"
FILE_SIZE=$(wc -c < "$CORRUPT" | tr -d ' ')
OFFSET=$(( FILE_SIZE / 2 ))
printf '\xff' | dd of="$CORRUPT" bs=1 seek="$OFFSET" count=1 conv=notrunc 2>/dev/null
if "$MINIBLAR" verify "$CORRUPT" >/dev/null 2>&1; then
  fail "verify corrupt archive exits non-zero (got exit 0)"
else
  pass "verify corrupt archive exits non-zero"
fi

# --------------- 7. Info output shows file count ---------------
INFO_OUT="$("$MINIBLAR" info "$ARCHIVE_ROUNDTRIP" 2>/dev/null)"
if echo "$INFO_OUT" | grep -qE "Files:[[:space:]]+2"; then
  pass "info output shows file count"
else
  fail "info output shows file count — output: $INFO_OUT"
fi

# --------------- 8. Cat file content matches original ---------------
# Paths are now normalized (leading / stripped) in the archive
NORM_PATH="${TMPDIR_TEST#/}/hello.txt"
CAT_OUT="$("$MINIBLAR" cat "$ARCHIVE_ROUNDTRIP" "$NORM_PATH" 2>/dev/null)"
EXPECTED="$(cat "$TMPDIR_TEST/hello.txt")"
if [[ "$CAT_OUT" == "$EXPECTED" ]]; then
  pass "cat file content matches original"
else
  fail "cat file content matches original (expected '$EXPECTED', got '$CAT_OUT')"
fi

# --------------- 9. Cat missing file exits non-zero ---------------
if "$MINIBLAR" cat "$ARCHIVE_ROUNDTRIP" "nonexistent.txt" >/dev/null 2>&1; then
  fail "cat missing file exits non-zero (got exit 0)"
else
  pass "cat missing file exits non-zero"
fi

# --------------- 10. Create + extract roundtrip (diff originals vs extracted) ---------------
EXTRACT_DIR="$TMPDIR_TEST/extracted"
mkdir -p "$EXTRACT_DIR"
ARCHIVE_EXTRACT="$TMPDIR_TEST/extract_test.mblar"
"$MINIBLAR" create -o "$ARCHIVE_EXTRACT" \
  "$TMPDIR_TEST/hello.txt" \
  "$TMPDIR_TEST/foo.txt" \
  "$TMPDIR_TEST/sub/dir/nested.txt" 2>/dev/null
"$MINIBLAR" extract "$ARCHIVE_EXTRACT" -C "$EXTRACT_DIR" 2>/dev/null

EXTRACT_OK=true
for F in "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" "$TMPDIR_TEST/sub/dir/nested.txt"; do
  ARCHIVED_PATH="${F#/}"
  EXTRACTED_FILE="$EXTRACT_DIR/$ARCHIVED_PATH"
  if [[ ! -f "$EXTRACTED_FILE" ]]; then
    EXTRACT_OK=false
    break
  fi
  if ! diff -q "$F" "$EXTRACTED_FILE" >/dev/null 2>&1; then
    EXTRACT_OK=false
    break
  fi
done

if $EXTRACT_OK; then
  pass "create + extract roundtrip (diff originals vs extracted)"
else
  fail "create + extract roundtrip (diff originals vs extracted)"
fi

# --------------- 11. Tar-style flags: cf/tf work ---------------
ARCHIVE_TAR="$TMPDIR_TEST/tar_style.mblar"
"$MINIBLAR" cf "$ARCHIVE_TAR" "$TMPDIR_TEST/hello.txt" 2>/dev/null
TAR_LIST="$("$MINIBLAR" tf "$ARCHIVE_TAR" 2>/dev/null)"
if echo "$TAR_LIST" | grep -q "hello.txt"; then
  pass "tar-style flags: cf/tf work"
else
  fail "tar-style flags: cf/tf work — listing: $TAR_LIST"
fi

# --------------- 12. Tar-style with hyphen: -cf/-tf work ---------------
ARCHIVE_HYPHEN="$TMPDIR_TEST/hyphen_style.mblar"
"$MINIBLAR" -cf "$ARCHIVE_HYPHEN" "$TMPDIR_TEST/foo.txt" 2>/dev/null
HYPHEN_LIST="$("$MINIBLAR" -tf "$ARCHIVE_HYPHEN" 2>/dev/null)"
if echo "$HYPHEN_LIST" | grep -q "foo.txt"; then
  pass "tar-style with hyphen: -cf/-tf work"
else
  fail "tar-style with hyphen: -cf/-tf work — listing: $HYPHEN_LIST"
fi

# --------------- 13. Empty archive — create with no files fails ---------------
if "$MINIBLAR" create -o "$TMPDIR_TEST/empty.mblar" >/dev/null 2>&1; then
  EMPTY_LIST="$("$MINIBLAR" list "$TMPDIR_TEST/empty.mblar" 2>/dev/null)"
  if [[ -z "$EMPTY_LIST" ]]; then
    EMPTY_VERIFY=true
    "$MINIBLAR" verify "$TMPDIR_TEST/empty.mblar" >/dev/null 2>&1 || EMPTY_VERIFY=false
    if $EMPTY_VERIFY; then
      pass "empty archive: list shows nothing, verify passes"
    else
      fail "empty archive: verify failed"
    fi
  else
    fail "empty archive: list was not empty ($EMPTY_LIST)"
  fi
else
  pass "empty archive: create with no files correctly rejected"
fi

# --------------- 14. Unknown command exits non-zero ---------------
if "$MINIBLAR" frobnicate >/dev/null 2>&1; then
  fail "unknown command exits non-zero (got exit 0)"
else
  pass "unknown command exits non-zero"
fi

# --------------- 15. Binary content roundtrip ---------------
ARCHIVE_BIN="$TMPDIR_TEST/binary.mblar"
"$MINIBLAR" create -o "$ARCHIVE_BIN" "$TMPDIR_TEST/binary.dat" 2>/dev/null
NORM_BIN="${TMPDIR_TEST#/}/binary.dat"
"$MINIBLAR" cat "$ARCHIVE_BIN" "$NORM_BIN" > "$TMPDIR_TEST/binary_out.dat" 2>/dev/null
if diff -q "$TMPDIR_TEST/binary.dat" "$TMPDIR_TEST/binary_out.dat" >/dev/null 2>&1; then
  pass "binary content roundtrip (cat)"
else
  fail "binary content roundtrip (cat) — files differ"
fi

EXTRACT_BIN_DIR="$TMPDIR_TEST/bin_extracted"
mkdir -p "$EXTRACT_BIN_DIR"
"$MINIBLAR" extract "$ARCHIVE_BIN" -C "$EXTRACT_BIN_DIR" 2>/dev/null
BIN_EXTRACTED="$EXTRACT_BIN_DIR/${TMPDIR_TEST#/}/binary.dat"
if [[ -f "$BIN_EXTRACTED" ]] && diff -q "$TMPDIR_TEST/binary.dat" "$BIN_EXTRACTED" >/dev/null 2>&1; then
  pass "binary content roundtrip (extract)"
else
  fail "binary content roundtrip (extract) — files differ or missing (looked at: $BIN_EXTRACTED)"
fi

# --------------- 16. Tar-style Vf works ---------------
if "$MINIBLAR" Vf "$ARCHIVE_ROUNDTRIP" >/dev/null 2>&1; then
  pass "tar-style Vf works"
else
  fail "tar-style Vf works (got exit $?)"
fi

# --------------- 17. Progress suppression — piped stderr has no progress chars ---------------
STDERR_FILE="$TMPDIR_TEST/stderr_capture.txt"
"$MINIBLAR" create -o "$TMPDIR_TEST/progress_test.mblar" "$TMPDIR_TEST/hello.txt" 2>"$STDERR_FILE"
if [[ -s "$STDERR_FILE" ]]; then
  if perl -ne 'exit 1 if /[\r\x1b]/' "$STDERR_FILE"; then
    pass "progress suppression: no progress-bar chars in piped stderr"
  else
    fail "progress suppression: found progress-bar chars in piped stderr"
  fi
else
  pass "progress suppression: no progress-bar chars in piped stderr"
fi

# --------------- 18. Reject directory arguments ---------------
if "$MINIBLAR" create -o "$TMPDIR_TEST/dir_reject.mblar" "$TMPDIR_TEST/sub" 2>/dev/null; then
  fail "miniblar rejects directory arguments (got exit 0)"
else
  pass "miniblar rejects directory arguments"
fi

# --------------- 19. Create with 2 files and no -o archives BOTH files ---------------
echo -n "aaa" > "$TMPDIR_TEST/one.txt"
echo -n "bbb" > "$TMPDIR_TEST/two.txt"
"$MINIBLAR" create -o "$TMPDIR_TEST/both.mblar" "$TMPDIR_TEST/one.txt" "$TMPDIR_TEST/two.txt" 2>/dev/null
BOTH_LIST="$("$MINIBLAR" list "$TMPDIR_TEST/both.mblar" 2>/dev/null)"
BOTH_COUNT=$(echo "$BOTH_LIST" | wc -l | tr -d ' ')
if [[ "$BOTH_COUNT" == "2" ]]; then
  pass "create with 2 files archives both files"
else
  fail "create with 2 files archives both files (got $BOTH_COUNT lines: $BOTH_LIST)"
fi

# --------------- 20. Create with 2+ files and no -o flag should ERROR ---------------
# Multiple inputs require -o to specify the output archive name.
if "$MINIBLAR" create "$TMPDIR_TEST/one.txt" "$TMPDIR_TEST/two.txt" 2>/dev/null; then
  fail "create with 2 files and no -o should error (got exit 0)"
else
  pass "create with 2 files and no -o errors"
fi

# --------------- 21. Create with spaces in filenames ---------------
echo -n "spaced" > "$TMPDIR_TEST/file with spaces.txt"
echo -n "also spaced" > "$TMPDIR_TEST/another file.txt"
"$MINIBLAR" create -o "$TMPDIR_TEST/spaces.mblar" \
  "$TMPDIR_TEST/file with spaces.txt" \
  "$TMPDIR_TEST/another file.txt" 2>/dev/null
SPACES_LIST="$("$MINIBLAR" list "$TMPDIR_TEST/spaces.mblar" 2>/dev/null)"
SPACES_COUNT=$(echo "$SPACES_LIST" | wc -l | tr -d ' ')
if [[ "$SPACES_COUNT" == "2" ]]; then
  pass "create with spaces in filenames archives both"
else
  fail "create with spaces in filenames (got $SPACES_COUNT lines: $SPACES_LIST)"
fi

# --------------- 22. -o flag works in any position ---------------
"$MINIBLAR" create "$TMPDIR_TEST/one.txt" "$TMPDIR_TEST/two.txt" -o "$TMPDIR_TEST/trailing_o.mblar" 2>/dev/null
if [[ -f "$TMPDIR_TEST/trailing_o.mblar" ]]; then
  TO_LIST="$("$MINIBLAR" list "$TMPDIR_TEST/trailing_o.mblar" 2>/dev/null)"
  TO_COUNT=$(echo "$TO_LIST" | wc -l | tr -d ' ')
  if [[ "$TO_COUNT" == "2" ]]; then
    pass "-o flag works after input files"
  else
    fail "-o after inputs: expected 2 files, got $TO_COUNT ($TO_LIST)"
  fi
else
  fail "-o after inputs: archive not created at $TMPDIR_TEST/trailing_o.mblar"
fi

# --------------- 23. -o without extension gets .mblar appended ---------------
"$MINIBLAR" create -o "$TMPDIR_TEST/noext" "$TMPDIR_TEST/one.txt" 2>/dev/null
if [[ -f "$TMPDIR_TEST/noext.mblar" ]]; then
  pass "-o without extension gets .mblar appended"
  rm -f "$TMPDIR_TEST/noext.mblar"
else
  fail "-o without extension: expected $TMPDIR_TEST/noext.mblar, not found"
fi

# --------------- 24. peek --help shows usage (not "cannot open") ---------------
PEEK_HELP=$("$MINIBLAR" peek --help 2>&1)
if echo "$PEEK_HELP" | grep -qi "usage\|navigation\|path\|accessor"; then
  pass "peek --help shows usage info"
else
  fail "peek --help: got '$PEEK_HELP'"
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
