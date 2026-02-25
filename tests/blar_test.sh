#!/usr/bin/env bash
set -u

# =============================================================================
# blar integration test suite
# =============================================================================
# Exercises the blar CLI end-to-end: create, list, extract, verify, info, cat,
# tar-style shorthand flags, corruption detection, binary roundtrip, and more.
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

# --------------- 4. Create + list roundtrip (subcommand style) ---------------
ARCHIVE_ROUNDTRIP="$TMPDIR_TEST/roundtrip.blar"
"$BLAR" create -o "$ARCHIVE_ROUNDTRIP" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" 2>/dev/null
LIST_OUT="$("$BLAR" list "$ARCHIVE_ROUNDTRIP" 2>/dev/null)"
# Both files should appear in the listing
if echo "$LIST_OUT" | grep -q "hello.txt" && echo "$LIST_OUT" | grep -q "foo.txt"; then
  pass "create + list roundtrip (subcommand style)"
else
  fail "create + list roundtrip (subcommand style) — listing: $LIST_OUT"
fi

# --------------- 5. Verify valid archive exits 0 ---------------
if "$BLAR" verify "$ARCHIVE_ROUNDTRIP" >/dev/null 2>&1; then
  pass "verify valid archive exits 0"
else
  fail "verify valid archive exits 0 (got exit $?)"
fi

# --------------- 6. Verify corrupt archive exits non-zero ---------------
CORRUPT="$TMPDIR_TEST/corrupt.blar"
cp "$ARCHIVE_ROUNDTRIP" "$CORRUPT"
# Flip a byte near the middle of the archive
FILE_SIZE=$(wc -c < "$CORRUPT" | tr -d ' ')
OFFSET=$(( FILE_SIZE / 2 ))
printf '\xff' | dd of="$CORRUPT" bs=1 seek="$OFFSET" count=1 conv=notrunc 2>/dev/null
if "$BLAR" verify "$CORRUPT" >/dev/null 2>&1; then
  fail "verify corrupt archive exits non-zero (got exit 0)"
else
  pass "verify corrupt archive exits non-zero"
fi

# --------------- 7. Info output shows file count ---------------
INFO_OUT="$("$BLAR" info "$ARCHIVE_ROUNDTRIP" 2>/dev/null)"
if echo "$INFO_OUT" | grep -qE "Files:[[:space:]]+2"; then
  pass "info output shows file count"
else
  fail "info output shows file count — output: $INFO_OUT"
fi

# --------------- 8. Cat file content matches original ---------------
# Paths are now normalized (leading / stripped) in the archive
NORM_PATH="${TMPDIR_TEST#/}/hello.txt"
CAT_OUT="$("$BLAR" cat "$ARCHIVE_ROUNDTRIP" "$NORM_PATH" 2>/dev/null)"
EXPECTED="$(cat "$TMPDIR_TEST/hello.txt")"
if [[ "$CAT_OUT" == "$EXPECTED" ]]; then
  pass "cat file content matches original"
else
  fail "cat file content matches original (expected '$EXPECTED', got '$CAT_OUT')"
fi

# --------------- 9. Cat missing file exits non-zero ---------------
if "$BLAR" cat "$ARCHIVE_ROUNDTRIP" "nonexistent.txt" >/dev/null 2>&1; then
  fail "cat missing file exits non-zero (got exit 0)"
else
  pass "cat missing file exits non-zero"
fi

# --------------- 10. Create + extract roundtrip (diff originals vs extracted) ---------------
EXTRACT_DIR="$TMPDIR_TEST/extracted"
mkdir -p "$EXTRACT_DIR"
ARCHIVE_EXTRACT="$TMPDIR_TEST/extract_test.blar"
"$BLAR" create -o "$ARCHIVE_EXTRACT" \
  "$TMPDIR_TEST/hello.txt" \
  "$TMPDIR_TEST/foo.txt" \
  "$TMPDIR_TEST/sub/dir/nested.txt" 2>/dev/null
"$BLAR" extract "$ARCHIVE_EXTRACT" -C "$EXTRACT_DIR" 2>/dev/null

# blar stores full absolute paths; extract recreates them under the target dir.
# So a file archived as /tmp/xxx/hello.txt extracts to $EXTRACT_DIR/tmp/xxx/hello.txt
EXTRACT_OK=true
for F in "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" "$TMPDIR_TEST/sub/dir/nested.txt"; do
  # Strip leading slash to form the path under the extraction directory
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
ARCHIVE_TAR="$TMPDIR_TEST/tar_style.blar"
"$BLAR" cf "$ARCHIVE_TAR" "$TMPDIR_TEST/hello.txt" 2>/dev/null
TAR_LIST="$("$BLAR" tf "$ARCHIVE_TAR" 2>/dev/null)"
if echo "$TAR_LIST" | grep -q "hello.txt"; then
  pass "tar-style flags: cf/tf work"
else
  fail "tar-style flags: cf/tf work — listing: $TAR_LIST"
fi

# --------------- 12. Tar-style with hyphen: -cf/-tf work ---------------
ARCHIVE_HYPHEN="$TMPDIR_TEST/hyphen_style.blar"
"$BLAR" -cf "$ARCHIVE_HYPHEN" "$TMPDIR_TEST/foo.txt" 2>/dev/null
HYPHEN_LIST="$("$BLAR" -tf "$ARCHIVE_HYPHEN" 2>/dev/null)"
if echo "$HYPHEN_LIST" | grep -q "foo.txt"; then
  pass "tar-style with hyphen: -cf/-tf work"
else
  fail "tar-style with hyphen: -cf/-tf work — listing: $HYPHEN_LIST"
fi

# --------------- 13. Empty archive — create with no files fails ---------------
# blar create with no files exits non-zero (exit 1)
if "$BLAR" create -o "$TMPDIR_TEST/empty.blar" >/dev/null 2>&1; then
  # If it somehow succeeded, check that list shows nothing and verify passes
  EMPTY_LIST="$("$BLAR" list "$TMPDIR_TEST/empty.blar" 2>/dev/null)"
  if [[ -z "$EMPTY_LIST" ]]; then
    EMPTY_VERIFY=true
    "$BLAR" verify "$TMPDIR_TEST/empty.blar" >/dev/null 2>&1 || EMPTY_VERIFY=false
    if $EMPTY_VERIFY; then
      pass "empty archive: list shows nothing, verify passes"
    else
      fail "empty archive: verify failed"
    fi
  else
    fail "empty archive: list was not empty ($EMPTY_LIST)"
  fi
else
  # create with no files is rejected — that's acceptable behavior
  pass "empty archive: create with no files correctly rejected"
fi

# --------------- 14. Unknown command exits non-zero ---------------
if "$BLAR" frobnicate >/dev/null 2>&1; then
  fail "unknown command exits non-zero (got exit 0)"
else
  pass "unknown command exits non-zero"
fi

# --------------- 15. Binary content roundtrip ---------------
ARCHIVE_BIN="$TMPDIR_TEST/binary.blar"
"$BLAR" create -o "$ARCHIVE_BIN" "$TMPDIR_TEST/binary.dat" 2>/dev/null
NORM_BIN="${TMPDIR_TEST#/}/binary.dat"
"$BLAR" cat "$ARCHIVE_BIN" "$NORM_BIN" > "$TMPDIR_TEST/binary_out.dat" 2>/dev/null
if diff -q "$TMPDIR_TEST/binary.dat" "$TMPDIR_TEST/binary_out.dat" >/dev/null 2>&1; then
  pass "binary content roundtrip (cat)"
else
  fail "binary content roundtrip (cat) — files differ"
fi

# Also verify via extract
EXTRACT_BIN_DIR="$TMPDIR_TEST/bin_extracted"
mkdir -p "$EXTRACT_BIN_DIR"
"$BLAR" extract "$ARCHIVE_BIN" -C "$EXTRACT_BIN_DIR" 2>/dev/null
# Paths are now normalized (leading / stripped), so extracted path is relative
BIN_EXTRACTED="$EXTRACT_BIN_DIR/${TMPDIR_TEST#/}/binary.dat"
if [[ -f "$BIN_EXTRACTED" ]] && diff -q "$TMPDIR_TEST/binary.dat" "$BIN_EXTRACTED" >/dev/null 2>&1; then
  pass "binary content roundtrip (extract)"
else
  fail "binary content roundtrip (extract) — files differ or missing (looked at: $BIN_EXTRACTED)"
fi

# --------------- 16. Tar-style Vf works ---------------
if "$BLAR" Vf "$ARCHIVE_ROUNDTRIP" >/dev/null 2>&1; then
  pass "tar-style Vf works"
else
  fail "tar-style Vf works (got exit $?)"
fi

# --------------- 17. Progress suppression — piped stderr has no progress chars ---------------
STDERR_FILE="$TMPDIR_TEST/stderr_capture.txt"
"$BLAR" create -o "$TMPDIR_TEST/progress_test.blar" "$TMPDIR_TEST/hello.txt" 2>"$STDERR_FILE"
# When not connected to a TTY, stderr should have no progress-bar characters
# Common progress indicators: \r, escape sequences (\x1b), percentage signs in
# control sequences, spinner chars. We check for \r and \x1b.
if [[ -s "$STDERR_FILE" ]]; then
  # stderr has content; check if it contains progress-bar indicators
  if perl -ne 'exit 1 if /[\r\x1b]/' "$STDERR_FILE"; then
    pass "progress suppression: no progress-bar chars in piped stderr"
  else
    fail "progress suppression: found progress-bar chars in piped stderr"
  fi
else
  # Empty stderr when piped — perfect
  pass "progress suppression: no progress-bar chars in piped stderr"
fi

# --------------- 18. Create with 2+ inputs and no -o should ERROR ---------------
if "$BLAR" create "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" 2>/dev/null; then
  fail "create with 2 inputs and no -o should error (got exit 0)"
else
  pass "create with 2 inputs and no -o errors"
fi

# --------------- 19. -o flag works in any position ---------------
"$BLAR" create "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/foo.txt" -o "$TMPDIR_TEST/trailing_o.blar" 2>/dev/null
if [[ -f "$TMPDIR_TEST/trailing_o.blar" ]]; then
  TO_LIST="$("$BLAR" list "$TMPDIR_TEST/trailing_o.blar" 2>/dev/null)"
  TO_COUNT=$(echo "$TO_LIST" | wc -l | tr -d ' ')
  if [[ "$TO_COUNT" == "2" ]]; then
    pass "-o flag works after input files"
  else
    fail "-o after inputs: expected 2 files, got $TO_COUNT ($TO_LIST)"
  fi
else
  fail "-o after inputs: archive not created at $TMPDIR_TEST/trailing_o.blar"
fi

# --------------- 20. -o without extension gets .blar appended ---------------
"$BLAR" create -o "$TMPDIR_TEST/noext" "$TMPDIR_TEST/hello.txt" 2>/dev/null
if [[ -f "$TMPDIR_TEST/noext.blar" ]]; then
  pass "-o without extension gets .blar appended"
  rm -f "$TMPDIR_TEST/noext.blar"
else
  fail "-o without extension: expected $TMPDIR_TEST/noext.blar, not found"
fi

# --------------- 21. peek --help shows usage (not "cannot open") ---------------
PEEK_HELP=$("$BLAR" peek --help 2>&1)
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
