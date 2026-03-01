#!/usr/bin/env bash
# tests/lz4_test.sh — LZ4 compression container CLI tests
#
# Tests: -z lz4 flag for create, transparent decompression for list/extract/verify/info/cat/peek/to-json
# Also tests: miniblar equivalents, binary round-trip, from-json -z lz4

set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ── Build ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLAR="$PROJECT_DIR/zig-out/bin/blar"
MINIBLAR="$PROJECT_DIR/zig-out/bin/miniblar"

echo "Building blar and miniblar..."
(cd "$PROJECT_DIR" && zig build 2>/dev/null) || { echo "FATAL: build failed"; exit 1; }

# ── Setup ────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

echo "hello world" > "$TMPDIR_TEST/hello.txt"
echo "goodbye world" > "$TMPDIR_TEST/goodbye.txt"
dd if=/dev/urandom bs=1024 count=10 of="$TMPDIR_TEST/random.bin" 2>/dev/null

# Normalized paths (leading / stripped) — matches how blar stores them
NORM_HELLO="${TMPDIR_TEST#/}/hello.txt"
NORM_GOODBYE="${TMPDIR_TEST#/}/goodbye.txt"
NORM_RANDOM="${TMPDIR_TEST#/}/random.bin"

# ── blar create -z lz4 ──────────────────────────────────────────────────

# 1. Basic compressed archive creation
"$BLAR" create -z lz4 -o "$TMPDIR_TEST/compressed.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
if [ -f "$TMPDIR_TEST/compressed.blar" ]; then
  pass "blar create -z lz4 produces output file"
else
  fail "blar create -z lz4 produces output file"
fi

# 2. Compressed archive has COMP attribute (0x81 0x10) in v2 LP header
HEADER_HEX=$(xxd -l 15 -p "$TMPDIR_TEST/compressed.blar" | tr -d '\n')
if echo "$HEADER_HEX" | grep -q "8110"; then
  pass "blar create -z lz4: COMP attribute (0x81 0x10) present in LP header"
else
  fail "blar create -z lz4: COMP attribute (0x81 0x10) not found in header (got $HEADER_HEX)"
fi

# 3. COMP value is 0x03 (lz4), not 0x01 (lzma2) or 0x02 (bzip2)
# In the LP header, COMP sigil (0x81 0x10) is followed by the algo ID
if echo "$HEADER_HEX" | grep -q "811003"; then
  pass "blar create -z lz4: COMP=lz4 (0x03) in header"
else
  fail "blar create -z lz4: COMP=lz4 (0x03) not found (got $HEADER_HEX)"
fi

# ── Transparent decompression: blar list ─────────────────────────────────

# 4. list works on lz4 archive
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$LIST_OUT" | grep -q 'hello.txt'; then
  pass "blar list: works on lz4 archive"
else
  fail "blar list: works on lz4 archive — output: $LIST_OUT"
fi

# 5. list shows all files
if echo "$LIST_OUT" | grep -q 'goodbye.txt'; then
  pass "blar list: shows all files"
else
  fail "blar list: shows all files — output: $LIST_OUT"
fi

# ── Transparent decompression: blar extract ──────────────────────────────

# 6-7. extract works on lz4 archive
EXTRACT_DIR="$TMPDIR_TEST/extract_out"
mkdir -p "$EXTRACT_DIR"
"$BLAR" extract "$TMPDIR_TEST/compressed.blar" -C "$EXTRACT_DIR" 2>/dev/null

EXTRACTED_HELLO="$EXTRACT_DIR/$NORM_HELLO"
if [ -f "$EXTRACTED_HELLO" ] && [ "$(cat "$EXTRACTED_HELLO")" = "hello world" ]; then
  pass "blar extract: hello.txt content correct"
else
  fail "blar extract: hello.txt content correct (file: $EXTRACTED_HELLO)"
fi

EXTRACTED_GOODBYE="$EXTRACT_DIR/$NORM_GOODBYE"
if [ -f "$EXTRACTED_GOODBYE" ] && [ "$(cat "$EXTRACTED_GOODBYE")" = "goodbye world" ]; then
  pass "blar extract: goodbye.txt content correct"
else
  fail "blar extract: goodbye.txt content correct (file: $EXTRACTED_GOODBYE)"
fi

# ── Transparent decompression: blar verify ───────────────────────────────

# 8. verify works on lz4 archive
VERIFY_OUT=$("$BLAR" verify "$TMPDIR_TEST/compressed.blar" 2>&1)
if echo "$VERIFY_OUT" | grep -q 'OK'; then
  pass "blar verify: passes on lz4 archive"
else
  fail "blar verify: passes on lz4 archive — output: $VERIFY_OUT"
fi

# ── Transparent decompression: blar info ─────────────────────────────────

# 9. info works on lz4 archive
INFO_OUT=$("$BLAR" info "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$INFO_OUT" | grep -q 'hello.txt'; then
  pass "blar info: shows files"
else
  fail "blar info: shows files — output: $INFO_OUT"
fi

# ── Transparent decompression: blar cat ──────────────────────────────────

# 10. cat works on lz4 archive
CAT_OUT=$("$BLAR" cat "$TMPDIR_TEST/compressed.blar" "$NORM_HELLO" 2>/dev/null)
if [ "$CAT_OUT" = "hello world" ]; then
  pass "blar cat: correct content from lz4 archive"
else
  fail "blar cat: correct content from lz4 archive (got: '$CAT_OUT')"
fi

# ── Transparent decompression: blar peek ─────────────────────────────────

# 11. peek works on lz4 archive
PEEK_OUT=$("$BLAR" peek "$TMPDIR_TEST/compressed.blar" "[1][0][0][pa]" 2>&1)
if echo "$PEEK_OUT" | grep -q 'hello.txt'; then
  pass "blar peek: works on lz4 archive"
else
  fail "blar peek: works on lz4 archive — output: $PEEK_OUT"
fi

# ── Transparent decompression: blar to-json ──────────────────────────────

# 12-13. to-json works on lz4 archive
JSON_OUT=$("$BLAR" to-json "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$JSON_OUT" | jq '.entries | length' > /dev/null 2>&1; then
  pass "blar to-json: valid JSON from lz4 archive"
else
  fail "blar to-json: valid JSON from lz4 archive"
fi

ENTRY_COUNT=$(echo "$JSON_OUT" | jq '.entries | length')
if [ "$ENTRY_COUNT" -ge 2 ]; then
  pass "blar to-json: shows all entries ($ENTRY_COUNT)"
else
  fail "blar to-json: shows all entries (got $ENTRY_COUNT)"
fi

# ── miniblar create -z lz4 ──────────────────────────────────────────────

# 14. miniblar create -z lz4
"$MINIBLAR" create -z lz4 -o "$TMPDIR_TEST/mini_compressed.mblar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
if [ -f "$TMPDIR_TEST/mini_compressed.mblar" ]; then
  pass "miniblar create -z lz4 produces output file"
else
  fail "miniblar create -z lz4 produces output file"
fi

# 15. miniblar compressed archive has COMP=lz4 in v2 LP header
MINI_HEADER_HEX=$(xxd -l 15 -p "$TMPDIR_TEST/mini_compressed.mblar" | tr -d '\n')
if echo "$MINI_HEADER_HEX" | grep -q "811003"; then
  pass "miniblar create -z lz4: COMP=lz4 (0x03) in header"
else
  fail "miniblar create -z lz4: COMP=lz4 (0x03) not found in header (got $MINI_HEADER_HEX)"
fi

# ── Transparent decompression: miniblar ──────────────────────────────────

# 16. miniblar list on lz4 compressed
MINI_LIST=$("$MINIBLAR" list "$TMPDIR_TEST/mini_compressed.mblar" 2>/dev/null)
if echo "$MINI_LIST" | grep -q 'hello.txt'; then
  pass "miniblar list: works on lz4 archive"
else
  fail "miniblar list: works on lz4 archive — output: $MINI_LIST"
fi

# 17. miniblar extract on lz4 compressed
MINI_EXTRACT="$TMPDIR_TEST/mini_extract"
mkdir -p "$MINI_EXTRACT"
"$MINIBLAR" extract "$TMPDIR_TEST/mini_compressed.mblar" -C "$MINI_EXTRACT" 2>/dev/null
MINI_EXTRACTED="$MINI_EXTRACT/$NORM_HELLO"
if [ -f "$MINI_EXTRACTED" ] && [ "$(cat "$MINI_EXTRACTED")" = "hello world" ]; then
  pass "miniblar extract: correct content from lz4"
else
  fail "miniblar extract: correct content from lz4 (file: $MINI_EXTRACTED)"
fi

# 18. miniblar verify on lz4 compressed
MINI_VERIFY=$("$MINIBLAR" verify "$TMPDIR_TEST/mini_compressed.mblar" 2>&1)
if echo "$MINI_VERIFY" | grep -q 'OK'; then
  pass "miniblar verify: passes on lz4 archive"
else
  fail "miniblar verify: passes on lz4 archive — output: $MINI_VERIFY"
fi

# 19. miniblar cat on lz4 compressed
MINI_CAT=$("$MINIBLAR" cat "$TMPDIR_TEST/mini_compressed.mblar" "$NORM_HELLO" 2>/dev/null)
if [ "$MINI_CAT" = "hello world" ]; then
  pass "miniblar cat: correct content from lz4"
else
  fail "miniblar cat: correct content from lz4 (got: '$MINI_CAT')"
fi

# ── Binary content round-trip ────────────────────────────────────────────

# 20. Binary file round-trips through lz4 compressed archive
"$BLAR" create -z lz4 -o "$TMPDIR_TEST/binary_comp.blar" "$TMPDIR_TEST/random.bin" 2>/dev/null
BINARY_EXTRACT="$TMPDIR_TEST/binary_extract"
mkdir -p "$BINARY_EXTRACT"
"$BLAR" extract "$TMPDIR_TEST/binary_comp.blar" -C "$BINARY_EXTRACT" 2>/dev/null
BINARY_EXTRACTED="$BINARY_EXTRACT/$NORM_RANDOM"
if cmp -s "$TMPDIR_TEST/random.bin" "$BINARY_EXTRACTED"; then
  pass "binary content round-trips through lz4"
else
  fail "binary content round-trips through lz4 (file: $BINARY_EXTRACTED)"
fi

# ── Help text mentions lz4 ──────────────────────────────────────────────

# 21. blar --help mentions lz4
BLAR_HELP=$("$BLAR" --help 2>&1)
if echo "$BLAR_HELP" | grep -q 'lz4'; then
  pass "blar --help mentions lz4"
else
  fail "blar --help mentions lz4"
fi

# 22. miniblar --help mentions lz4
MINI_HELP=$("$MINIBLAR" --help 2>&1)
if echo "$MINI_HELP" | grep -q 'lz4'; then
  pass "miniblar --help mentions lz4"
else
  fail "miniblar --help mentions lz4"
fi

# ── Directory archive with -z lz4 (blar only) ───────────────────────────

# 23. blar create -z lz4 with directories
mkdir -p "$TMPDIR_TEST/testdir/subdir"
echo "nested" > "$TMPDIR_TEST/testdir/subdir/file.txt"
echo "top" > "$TMPDIR_TEST/testdir/top.txt"
"$BLAR" create -z lz4 -o "$TMPDIR_TEST/dir_comp.blar" "$TMPDIR_TEST/testdir" 2>/dev/null
DIR_LIST=$("$BLAR" list "$TMPDIR_TEST/dir_comp.blar" 2>/dev/null)
if echo "$DIR_LIST" | grep -q 'file.txt'; then
  pass "blar create -z lz4 with dirs: list works"
else
  fail "blar create -z lz4 with dirs: list works — output: $DIR_LIST"
fi

# 24. extract lz4 compressed dir archive
DIR_EXTRACT="$TMPDIR_TEST/dir_extract"
mkdir -p "$DIR_EXTRACT"
"$BLAR" extract "$TMPDIR_TEST/dir_comp.blar" -C "$DIR_EXTRACT" 2>/dev/null
NORM_NESTED="${TMPDIR_TEST#/}/testdir/subdir/file.txt"
DIR_EXTRACTED="$DIR_EXTRACT/$NORM_NESTED"
if [ -f "$DIR_EXTRACTED" ] && [ "$(cat "$DIR_EXTRACTED")" = "nested" ]; then
  pass "blar extract -z lz4 dir: nested content correct"
else
  fail "blar extract -z lz4 dir: nested content correct (file: $DIR_EXTRACTED)"
fi

# ── from-json with -z lz4 ───────────────────────────────────────────────

# 25. from-json with -z lz4 creates an lz4-compressed archive
"$BLAR" to-json "$TMPDIR_TEST/compressed.blar" > "$TMPDIR_TEST/archive.json" 2>/dev/null
"$BLAR" from-json -z lz4 -o "$TMPDIR_TEST/from_json_lz4.blar" "$TMPDIR_TEST/archive.json" 2>/dev/null
FJ_HEADER=$(xxd -l 15 -p "$TMPDIR_TEST/from_json_lz4.blar" | tr -d '\n')
if echo "$FJ_HEADER" | grep -q "811003"; then
  pass "from-json -z lz4 creates lz4-compressed archive"
else
  fail "from-json -z lz4 creates lz4-compressed archive — got $FJ_HEADER"
fi

# 26. from-json -z lz4 archive round-trips
FJ_LIST=$("$BLAR" list "$TMPDIR_TEST/from_json_lz4.blar" 2>/dev/null)
if echo "$FJ_LIST" | grep -q 'hello.txt'; then
  pass "from-json -z lz4: list works after round-trip"
else
  fail "from-json -z lz4: list works after round-trip — output: $FJ_LIST"
fi

# ── Results ──────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
