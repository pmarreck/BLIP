#!/usr/bin/env bash
# tests/lzma2_test.sh — LZMA2 compression container CLI tests
#
# Tests: -z flag for create, transparent decompression for list/extract/verify/info/cat/peek/poke/to-json

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

# ── blar create -z ───────────────────────────────────────────────────────

# 1. Basic compressed archive creation
"$BLAR" create -z -o "$TMPDIR_TEST/compressed.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
if [ -f "$TMPDIR_TEST/compressed.blar" ]; then
  pass "blar create -z produces output file"
else
  fail "blar create -z produces output file"
fi

# 2. Compressed archive has COMP attribute (0x81 0x10) in v2 LP header
# In v2 LP format, compressed containers use a COMP attribute instead of a type sentinel.
# The first ~15 bytes contain: BLIP(total_length), TYPE attr (0x81 0x01 0x04), COMP attr (0x81 0x10 0x01)
HEADER_HEX=$(xxd -l 15 -p "$TMPDIR_TEST/compressed.blar" | tr -d '\n')
if echo "$HEADER_HEX" | grep -q "8110"; then
  pass "blar create -z: COMP attribute (0x81 0x10) present in LP header"
else
  fail "blar create -z: COMP attribute (0x81 0x10) not found in header (got $HEADER_HEX)"
fi

# 3. Compressed archive is smaller than uncompressed (for text files)
"$BLAR" create -o "$TMPDIR_TEST/uncompressed.blar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
COMP_SIZE=$(wc -c < "$TMPDIR_TEST/compressed.blar" | tr -d ' ')
UNCOMP_SIZE=$(wc -c < "$TMPDIR_TEST/uncompressed.blar" | tr -d ' ')
if [ "$COMP_SIZE" -lt "$UNCOMP_SIZE" ]; then
  pass "blar create -z: compressed smaller than uncompressed ($COMP_SIZE < $UNCOMP_SIZE)"
else
  fail "blar create -z: compressed smaller than uncompressed ($COMP_SIZE >= $UNCOMP_SIZE)"
fi

# ── Transparent decompression: blar list ─────────────────────────────────

# 4. list works on compressed archive
LIST_OUT=$("$BLAR" list "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$LIST_OUT" | grep -q 'hello.txt'; then
  pass "blar list: works on LZMA2 archive"
else
  fail "blar list: works on LZMA2 archive — output: $LIST_OUT"
fi

# 5. list shows all files
if echo "$LIST_OUT" | grep -q 'goodbye.txt'; then
  pass "blar list: shows all files"
else
  fail "blar list: shows all files — output: $LIST_OUT"
fi

# ── Transparent decompression: blar extract ──────────────────────────────

# 6-7. extract works on compressed archive
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

# 8. verify works on compressed archive
VERIFY_OUT=$("$BLAR" verify "$TMPDIR_TEST/compressed.blar" 2>&1)
if echo "$VERIFY_OUT" | grep -q 'OK'; then
  pass "blar verify: passes on LZMA2 archive"
else
  fail "blar verify: passes on LZMA2 archive — output: $VERIFY_OUT"
fi

# ── Transparent decompression: blar info ─────────────────────────────────

# 9. info works on compressed archive
INFO_OUT=$("$BLAR" info "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$INFO_OUT" | grep -q 'hello.txt'; then
  pass "blar info: shows files"
else
  fail "blar info: shows files — output: $INFO_OUT"
fi

# ── Transparent decompression: blar cat ──────────────────────────────────

# 10. cat works on compressed archive
CAT_OUT=$("$BLAR" cat "$TMPDIR_TEST/compressed.blar" "$NORM_HELLO" 2>/dev/null)
if [ "$CAT_OUT" = "hello world" ]; then
  pass "blar cat: correct content from LZMA2 archive"
else
  fail "blar cat: correct content from LZMA2 archive (got: '$CAT_OUT')"
fi

# ── Transparent decompression: blar peek ─────────────────────────────────

# 11. peek works on compressed archive
PEEK_OUT=$("$BLAR" peek "$TMPDIR_TEST/compressed.blar" "[1][0][0][pa]" 2>&1)
if echo "$PEEK_OUT" | grep -q 'hello.txt'; then
  pass "blar peek: works on LZMA2 archive"
else
  fail "blar peek: works on LZMA2 archive — output: $PEEK_OUT"
fi

# ── Transparent decompression: blar to-json ──────────────────────────────

# 12-13. to-json works on compressed archive
JSON_OUT=$("$BLAR" to-json "$TMPDIR_TEST/compressed.blar" 2>/dev/null)
if echo "$JSON_OUT" | jq '.entries | length' > /dev/null 2>&1; then
  pass "blar to-json: valid JSON from LZMA2 archive"
else
  fail "blar to-json: valid JSON from LZMA2 archive"
fi

ENTRY_COUNT=$(echo "$JSON_OUT" | jq '.entries | length')
if [ "$ENTRY_COUNT" -ge 2 ]; then
  pass "blar to-json: shows all entries ($ENTRY_COUNT)"
else
  fail "blar to-json: shows all entries (got $ENTRY_COUNT)"
fi

# ── miniblar create -z ───────────────────────────────────────────────────

# 14. miniblar create -z
"$MINIBLAR" create -z -o "$TMPDIR_TEST/mini_compressed.mblar" "$TMPDIR_TEST/hello.txt" "$TMPDIR_TEST/goodbye.txt" 2>/dev/null
if [ -f "$TMPDIR_TEST/mini_compressed.mblar" ]; then
  pass "miniblar create -z produces output file"
else
  fail "miniblar create -z produces output file"
fi

# 15. miniblar compressed archive has COMP attribute in v2 LP header
MINI_HEADER_HEX=$(xxd -l 15 -p "$TMPDIR_TEST/mini_compressed.mblar" | tr -d '\n')
if echo "$MINI_HEADER_HEX" | grep -q "8110"; then
  pass "miniblar create -z: COMP attribute (0x81 0x10) present in LP header"
else
  fail "miniblar create -z: COMP attribute (0x81 0x10) not found in header (got $MINI_HEADER_HEX)"
fi

# ── Transparent decompression: miniblar ──────────────────────────────────

# 16. miniblar list on compressed
MINI_LIST=$("$MINIBLAR" list "$TMPDIR_TEST/mini_compressed.mblar" 2>/dev/null)
if echo "$MINI_LIST" | grep -q 'hello.txt'; then
  pass "miniblar list: works on LZMA2 archive"
else
  fail "miniblar list: works on LZMA2 archive — output: $MINI_LIST"
fi

# 17. miniblar extract on compressed
MINI_EXTRACT="$TMPDIR_TEST/mini_extract"
mkdir -p "$MINI_EXTRACT"
"$MINIBLAR" extract "$TMPDIR_TEST/mini_compressed.mblar" -C "$MINI_EXTRACT" 2>/dev/null
MINI_EXTRACTED="$MINI_EXTRACT/$NORM_HELLO"
if [ -f "$MINI_EXTRACTED" ] && [ "$(cat "$MINI_EXTRACTED")" = "hello world" ]; then
  pass "miniblar extract: correct content from LZMA2"
else
  fail "miniblar extract: correct content from LZMA2 (file: $MINI_EXTRACTED)"
fi

# 18. miniblar verify on compressed
MINI_VERIFY=$("$MINIBLAR" verify "$TMPDIR_TEST/mini_compressed.mblar" 2>&1)
if echo "$MINI_VERIFY" | grep -q 'OK'; then
  pass "miniblar verify: passes on LZMA2 archive"
else
  fail "miniblar verify: passes on LZMA2 archive — output: $MINI_VERIFY"
fi

# 19. miniblar cat on compressed
MINI_CAT=$("$MINIBLAR" cat "$TMPDIR_TEST/mini_compressed.mblar" "$NORM_HELLO" 2>/dev/null)
if [ "$MINI_CAT" = "hello world" ]; then
  pass "miniblar cat: correct content from LZMA2"
else
  fail "miniblar cat: correct content from LZMA2 (got: '$MINI_CAT')"
fi

# ── Binary content round-trip ────────────────────────────────────────────

# 20. Binary file round-trips through compressed archive
"$BLAR" create -z -o "$TMPDIR_TEST/binary_comp.blar" "$TMPDIR_TEST/random.bin" 2>/dev/null
BINARY_EXTRACT="$TMPDIR_TEST/binary_extract"
mkdir -p "$BINARY_EXTRACT"
"$BLAR" extract "$TMPDIR_TEST/binary_comp.blar" -C "$BINARY_EXTRACT" 2>/dev/null
BINARY_EXTRACTED="$BINARY_EXTRACT/$NORM_RANDOM"
if cmp -s "$TMPDIR_TEST/random.bin" "$BINARY_EXTRACTED"; then
  pass "binary content round-trips through LZMA2"
else
  fail "binary content round-trips through LZMA2 (file: $BINARY_EXTRACTED)"
fi

# ── Uncompressed archives still work ─────────────────────────────────────

# 21. Uncompressed archives are unaffected by read_archive
UNCOMP_LIST=$("$BLAR" list "$TMPDIR_TEST/uncompressed.blar" 2>/dev/null)
if echo "$UNCOMP_LIST" | grep -q 'hello.txt'; then
  pass "uncompressed archive still works with read_archive"
else
  fail "uncompressed archive still works with read_archive"
fi

# ── Help text mentions -z ────────────────────────────────────────────────

# 22. blar --help mentions -z
BLAR_HELP=$("$BLAR" --help 2>&1)
if echo "$BLAR_HELP" | grep -q '\-z'; then
  pass "blar --help mentions -z"
else
  fail "blar --help mentions -z"
fi

# 23. miniblar --help mentions -z
MINI_HELP=$("$MINIBLAR" --help 2>&1)
if echo "$MINI_HELP" | grep -q '\-z'; then
  pass "miniblar --help mentions -z"
else
  fail "miniblar --help mentions -z"
fi

# ── Directory archive with -z (blar only) ────────────────────────────────

# 24. blar create -z with directories
mkdir -p "$TMPDIR_TEST/testdir/subdir"
echo "nested" > "$TMPDIR_TEST/testdir/subdir/file.txt"
echo "top" > "$TMPDIR_TEST/testdir/top.txt"
"$BLAR" create -z -o "$TMPDIR_TEST/dir_comp.blar" "$TMPDIR_TEST/testdir" 2>/dev/null
DIR_LIST=$("$BLAR" list "$TMPDIR_TEST/dir_comp.blar" 2>/dev/null)
if echo "$DIR_LIST" | grep -q 'file.txt'; then
  pass "blar create -z with dirs: list works"
else
  fail "blar create -z with dirs: list works — output: $DIR_LIST"
fi

# 25. extract compressed dir archive
DIR_EXTRACT="$TMPDIR_TEST/dir_extract"
mkdir -p "$DIR_EXTRACT"
"$BLAR" extract "$TMPDIR_TEST/dir_comp.blar" -C "$DIR_EXTRACT" 2>/dev/null
NORM_NESTED="${TMPDIR_TEST#/}/testdir/subdir/file.txt"
DIR_EXTRACTED="$DIR_EXTRACT/$NORM_NESTED"
if [ -f "$DIR_EXTRACTED" ] && [ "$(cat "$DIR_EXTRACTED")" = "nested" ]; then
  pass "blar extract -z dir: nested content correct"
else
  fail "blar extract -z dir: nested content correct (file: $DIR_EXTRACTED)"
fi

# ── Results ──────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
